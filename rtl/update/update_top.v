// =============================================================================
// FPGA METADATA
// =============================================================================
// Module: Update Subsystem Top Level
// Version: 1.0.0
// Purpose: Integrates all Phase 1 remote bitstream update modules
// Clock Budget: 50 MHz system clock
// Interface: Wire protocol input, SPI flash output, status
// Target: Lattice Nexus 40K (LIFCL-40)
// =============================================================================

/*
 * Update Subsystem Top Level
 * ══════════════════════════════════════════════════════════════════════════════
 *
 * Orchestrates the complete remote bitstream update flow:
 *
 *  1. bitstream_rx:     Receive and parse update packet
 *  2. governance:       Verify k-of-n approval threshold
 *  3. ml_dsa87_verify:  Verify post-quantum signature
 *  4. flash_manager:    Write to inactive slot, swap on success
 *  5. watchdog:         Monitor boot, rollback on failure
 *
 * Data Flow:
 * ┌──────────┐    ┌───────────┐    ┌────────────┐    ┌──────────────┐
 * │ Wire     │───▶│ Bitstream │───▶│ Flash      │───▶│ Watchdog     │
 * │ Protocol │    │ RX        │    │ Manager    │    │ (boot watch) │
 * └──────────┘    └─────┬─────┘    └────────────┘    └──────────────┘
 *                       │ header
 *                       ▼
 *               ┌───────────────┐
 *               │  Governance   │
 *               │  (k-of-n)    │
 *               └───────┬───────┘
 *                       │ approved
 *                       ▼
 *               ┌───────────────┐
 *               │  ML-DSA-87   │
 *               │  Verify      │
 *               └───────────────┘
 */

`timescale 1ns/1ps

module update_top #(
    parameter GOVERNANCE_K = 5,
    parameter GOVERNANCE_N = 9
)(
    input  wire        clk,
    input  wire        rst_n,

    // =========================================================================
    // External Data Input (from estream wire protocol or serial bridge)
    // =========================================================================
    input  wire [7:0]  rx_data,
    input  wire        rx_valid,
    output wire        rx_ready,
    input  wire        rx_last,

    // =========================================================================
    // SPI Flash Interface
    // =========================================================================
    output wire        flash_cs_n,
    output wire        flash_sclk,
    output wire        flash_mosi,
    input  wire        flash_miso,

    // =========================================================================
    // TSSP Interface (to estream Node for ML-DSA-87 verification)
    // =========================================================================
    output wire        tssp_req_valid,
    output wire [7:0]  tssp_req_cmd,
    output wire [255:0] tssp_req_hash,
    input  wire        tssp_req_ready,
    input  wire        tssp_resp_valid,
    input  wire        tssp_resp_pass,
    input  wire [7:0]  tssp_resp_status,

    // =========================================================================
    // Governance Approval Input
    // =========================================================================
    input  wire        approval_valid,
    input  wire [7:0]  approval_signer_id,
    input  wire [127:0] approval_hash,

    // =========================================================================
    // Control
    // =========================================================================
    input  wire        update_enable,     // Enable update reception
    input  wire        update_abort,      // Abort current update
    input  wire        use_tssp,          // Use T0 PRIME for verification
    input  wire        heartbeat,         // Heartbeat from running bitstream
    input  wire        boot_complete,     // New bitstream booted OK

    // =========================================================================
    // Status
    // =========================================================================
    output wire [3:0]  update_state,
    output wire        update_busy,
    output wire        update_done,
    output wire        update_error,
    output wire [7:0]  update_error_code,
    output wire [31:0] bytes_transferred,
    output wire        active_slot,
    output wire [31:0] active_version,
    output wire        rollback_occurred,
    output wire        watchdog_active,
    output wire [7:0]  governance_approvals
);

    // =========================================================================
    // INTERNAL WIRES
    // =========================================================================

    // bitstream_rx → flash_manager data path
    wire [7:0]  rx_to_flash_data;
    wire        rx_to_flash_valid;
    wire        rx_to_flash_ready;
    wire        rx_to_flash_last;

    // bitstream_rx parsed header outputs
    wire [31:0] hdr_version;
    wire [31:0] hdr_size;
    wire [31:0] hdr_crc32;
    wire [255:0] hdr_signature;
    wire [127:0] hdr_gov_hash;
    wire        hdr_valid;

    // bitstream_rx status
    wire [3:0]  rx_state;
    wire        rx_active;
    wire        rx_done;
    wire        rx_error;
    wire [7:0]  rx_error_code;

    // governance status
    wire        gov_approved;
    wire        gov_denied;
    wire        gov_done;
    wire [7:0]  gov_approver_count;
    wire        gov_busy;

    // ml_dsa87_verify status
    wire        verify_done;
    wire        verify_pass;
    wire        verify_error;
    wire        verify_busy;

    // flash_manager status
    wire [3:0]  flash_state;
    wire        flash_busy;
    wire        flash_write_done;
    wire        flash_write_error;
    wire [31:0] flash_bytes_written;
    wire [31:0] flash_version_a;
    wire [31:0] flash_version_b;

    // watchdog outputs
    wire        wdg_rollback;
    wire        wdg_boot_timeout;
    wire        wdg_run_timeout;
    wire [31:0] wdg_current_version;
    wire        wdg_active;

    // =========================================================================
    // UPDATE ORCHESTRATION FSM
    // =========================================================================

    reg [3:0]  orch_state;
    reg        rx_enable_reg;
    reg        flash_write_start;
    reg        flash_swap;
    reg        verify_start_reg;
    reg        gov_check_start;
    reg        update_committed;

    localparam O_IDLE        = 4'd0;
    localparam O_RECEIVING   = 4'd1;  // Receiving header
    localparam O_GOVERNANCE  = 4'd2;  // Checking governance
    localparam O_VERIFY      = 4'd3;  // Verifying signature
    localparam O_WRITING     = 4'd4;  // Writing to flash
    localparam O_SWAPPING    = 4'd5;  // Swapping active slot
    localparam O_DONE        = 4'd6;
    localparam O_ERROR       = 4'd7;

    assign update_state      = orch_state;
    assign update_busy       = (orch_state != O_IDLE);
    assign update_done       = (orch_state == O_DONE);
    assign update_error      = (orch_state == O_ERROR);
    assign update_error_code = rx_error_code;
    assign bytes_transferred = flash_bytes_written;
    assign active_version    = wdg_current_version;
    assign rollback_occurred = wdg_rollback;
    assign watchdog_active   = wdg_active;
    assign governance_approvals = gov_approver_count;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            orch_state       <= O_IDLE;
            rx_enable_reg    <= 1'b0;
            flash_write_start <= 1'b0;
            flash_swap       <= 1'b0;
            verify_start_reg <= 1'b0;
            gov_check_start  <= 1'b0;
            update_committed <= 1'b0;
        end else begin
            // Default de-assertions
            flash_write_start <= 1'b0;
            flash_swap        <= 1'b0;
            verify_start_reg  <= 1'b0;
            gov_check_start   <= 1'b0;
            update_committed  <= 1'b0;

            if (update_abort) begin
                orch_state    <= O_IDLE;
                rx_enable_reg <= 1'b0;
            end

            case (orch_state)
                O_IDLE: begin
                    if (update_enable) begin
                        orch_state    <= O_RECEIVING;
                        rx_enable_reg <= 1'b1;
                    end
                end

                O_RECEIVING: begin
                    // Wait for header to be parsed
                    if (hdr_valid) begin
                        rx_enable_reg   <= 1'b0;
                        orch_state      <= O_GOVERNANCE;
                        gov_check_start <= 1'b1;
                    end else if (rx_error) begin
                        orch_state <= O_ERROR;
                    end
                end

                O_GOVERNANCE: begin
                    if (gov_approved) begin
                        orch_state       <= O_VERIFY;
                        verify_start_reg <= 1'b1;
                    end else if (gov_denied) begin
                        orch_state <= O_ERROR;
                    end
                end

                O_VERIFY: begin
                    if (verify_done && verify_pass) begin
                        // Auth passed - resume payload reception and start writing
                        orch_state        <= O_WRITING;
                        rx_enable_reg     <= 1'b1;  // Resume rx for payload
                        flash_write_start <= 1'b1;
                    end else if (verify_done && !verify_pass) begin
                        orch_state <= O_ERROR;
                    end else if (verify_error) begin
                        orch_state <= O_ERROR;
                    end
                end

                O_WRITING: begin
                    if (flash_write_done) begin
                        orch_state <= O_SWAPPING;
                        flash_swap <= 1'b1;
                    end else if (flash_write_error) begin
                        orch_state <= O_ERROR;
                    end
                end

                O_SWAPPING: begin
                    if (flash_write_done) begin
                        update_committed <= 1'b1;
                        orch_state       <= O_DONE;
                        rx_enable_reg    <= 1'b0;
                    end
                end

                O_DONE: begin
                    if (!update_enable) begin
                        orch_state <= O_IDLE;
                    end
                end

                O_ERROR: begin
                    rx_enable_reg <= 1'b0;
                    if (!update_enable) begin
                        orch_state <= O_IDLE;
                    end
                end

                default: orch_state <= O_IDLE;
            endcase
        end
    end

    // =========================================================================
    // MODULE INSTANTIATIONS
    // =========================================================================

    bitstream_rx u_bitstream_rx (
        .clk            (clk),
        .rst_n          (rst_n),
        .s_axis_tdata   (rx_data),
        .s_axis_tvalid  (rx_valid),
        .s_axis_tready  (rx_ready),
        .s_axis_tlast   (rx_last),
        .m_axis_tdata   (rx_to_flash_data),
        .m_axis_tvalid  (rx_to_flash_valid),
        .m_axis_tready  (rx_to_flash_ready),
        .m_axis_tlast   (rx_to_flash_last),
        .hdr_version    (hdr_version),
        .hdr_size       (hdr_size),
        .hdr_crc32      (hdr_crc32),
        .hdr_signature  (hdr_signature),
        .hdr_gov_hash   (hdr_gov_hash),
        .hdr_valid      (hdr_valid),
        .rx_enable      (rx_enable_reg),
        .rx_abort       (update_abort),
        .state          (rx_state),
        .rx_active      (rx_active),
        .rx_done        (rx_done),
        .rx_error       (rx_error),
        .rx_error_code  (rx_error_code),
        .bytes_received (),
        .crc_computed   ()
    );

    governance #(
        .K_THRESHOLD (GOVERNANCE_K),
        .N_SIGNERS   (GOVERNANCE_N)
    ) u_governance (
        .clk                (clk),
        .rst_n              (rst_n),
        .check_start        (gov_check_start),
        .bitstream_id       (6'd0),
        .target_tier        (8'd0),
        .target_version     (hdr_version),
        .approval_valid     (approval_valid),
        .approval_signer_id (approval_signer_id),
        .approval_hash      (approval_hash),
        .approval_ack       (),
        .approval_reject    (),
        .preload_valid      (1'b0),
        .preload_signer_id  (8'd0),
        .preload_hash       (128'd0),
        .preload_expiry     (32'd0),
        .current_timestamp  (32'd0),
        .approved           (gov_approved),
        .denied             (gov_denied),
        .check_done         (gov_done),
        .approver_count     (gov_approver_count),
        .approver_bitmap    (),
        .cfg_k_threshold    (8'd0),
        .cfg_n_signers      (8'd0),
        .cfg_override_valid (1'b0),
        .state              (),
        .busy               (gov_busy),
        .timeout_flag       ()
    );

    ml_dsa87_verify u_ml_dsa87 (
        .clk             (clk),
        .rst_n           (rst_n),
        .verify_start    (verify_start_reg),
        .msg_hash        (hdr_signature),
        .verify_done     (verify_done),
        .verify_pass     (verify_pass),
        .verify_error    (verify_error),
        .sig_data        (8'd0),
        .sig_valid       (1'b0),
        .sig_ready       (),
        .sig_last        (1'b0),
        .use_tssp        (use_tssp),
        .key_slot        (8'd0),
        .tssp_req_valid  (tssp_req_valid),
        .tssp_req_cmd    (tssp_req_cmd),
        .tssp_req_hash   (tssp_req_hash),
        .tssp_req_ready  (tssp_req_ready),
        .tssp_resp_valid (tssp_resp_valid),
        .tssp_resp_pass  (tssp_resp_pass),
        .tssp_resp_status(tssp_resp_status),
        .crypto_cs_n     (),
        .crypto_sclk     (),
        .crypto_mosi     (),
        .crypto_miso     (1'b0),
        .state           (),
        .busy            (verify_busy)
    );

    flash_manager u_flash_manager (
        .clk            (clk),
        .rst_n          (rst_n),
        .s_axis_tdata   (rx_to_flash_data),
        .s_axis_tvalid  (rx_to_flash_valid),
        .s_axis_tready  (rx_to_flash_ready),
        .s_axis_tlast   (rx_to_flash_last),
        .flash_cs_n     (flash_cs_n),
        .flash_sclk     (flash_sclk),
        .flash_mosi     (flash_mosi),
        .flash_miso     (flash_miso),
        .write_start    (flash_write_start),
        .write_size     (hdr_size),
        .write_version  (hdr_version),
        .swap_slots     (flash_swap),
        .rollback       (wdg_rollback),
        .state          (flash_state),
        .busy           (flash_busy),
        .write_done     (flash_write_done),
        .write_error    (flash_write_error),
        .error_code     (),
        .active_slot    (active_slot),
        .version_a      (flash_version_a),
        .version_b      (flash_version_b),
        .bytes_written  (flash_bytes_written),
        .active_version ()
    );

    watchdog u_watchdog (
        .clk                  (clk),
        .rst_n                (rst_n),
        .heartbeat            (heartbeat),
        .boot_complete        (boot_complete),
        .update_started       (flash_write_start),
        .update_committed     (update_committed),
        .update_version       (hdr_version),
        .rollback_trigger     (wdg_rollback),
        .boot_timeout         (wdg_boot_timeout),
        .run_timeout          (wdg_run_timeout),
        .epo_trigger          (),
        .epo_clear            (1'b0),
        .current_version      (wdg_current_version),
        .previous_version     (),
        .version_valid        (),
        .state                (),
        .time_since_heartbeat (),
        .boot_attempts        (),
        .watchdog_active      (wdg_active)
    );

endmodule
