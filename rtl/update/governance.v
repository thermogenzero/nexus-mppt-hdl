// =============================================================================
// FPGA METADATA
// =============================================================================
// Module: Governance Threshold Checker
// Version: 1.0.0
// Purpose: k-of-n threshold approval for bitstream deployments
// Clock Budget: Single cycle check after signatures collected
// Interface: Approval accumulator with threshold comparison
// Target: Lattice Nexus 40K (LIFCL-40)
// Upstream: Based on estream-io governance model (k-of-n, default 5-of-9)
// =============================================================================

/*
 * Governance Threshold Checker
 * ══════════════════════════════════════════════════════════════════════════════
 *
 * Implements k-of-n threshold approval required before a bitstream update
 * can be deployed. Approval signatures are collected from authorized signers
 * and counted. Deployment proceeds only when k approvals are reached.
 *
 * Approval Process:
 * 1. Deployment request issued with bitstream ID + target
 * 2. Governance module publishes approval request
 * 3. Authorized signers submit ML-DSA-87 signed approvals
 * 4. Module counts valid approvals
 * 5. When count >= k, approval granted
 *
 * In standalone mode (no estream Node):
 * - Approvals can be pre-loaded from FRAM
 * - Supports offline governance with time-limited approvals
 *
 * Signer Registry:
 * - Up to N_MAX public key hashes stored in eFuse/OTP
 * - Each signer identified by 8-bit index
 * - Duplicate approvals rejected
 */

`timescale 1ns/1ps

module governance #(
    parameter K_THRESHOLD = 5,     // Minimum approvals required
    parameter N_SIGNERS   = 9,     // Total authorized signers
    parameter N_MAX       = 16,    // Max signer slots
    parameter HASH_BITS   = 128,   // Truncated public key hash
    parameter APPROVAL_TIMEOUT = 500_000_000  // 10 seconds at 50 MHz
)(
    input  wire        clk,
    input  wire        rst_n,

    // =========================================================================
    // Approval Request
    // =========================================================================
    input  wire              check_start,
    input  wire [5:0]        bitstream_id,
    input  wire [7:0]        target_tier,
    input  wire [31:0]       target_version,

    // =========================================================================
    // Approval Input (from TSSP/serial/FRAM)
    // =========================================================================
    input  wire              approval_valid,
    input  wire [7:0]        approval_signer_id,   // Signer index (0 to N-1)
    input  wire [HASH_BITS-1:0] approval_hash,     // Hash of signed approval
    output reg               approval_ack,
    output reg               approval_reject,      // Duplicate or invalid signer

    // =========================================================================
    // Pre-loaded Approvals (from FRAM for offline governance)
    // =========================================================================
    input  wire              preload_valid,
    input  wire [7:0]        preload_signer_id,
    input  wire [HASH_BITS-1:0] preload_hash,
    input  wire [31:0]       preload_expiry,       // Approval expiry timestamp
    input  wire [31:0]       current_timestamp,

    // =========================================================================
    // Result
    // =========================================================================
    output reg               approved,
    output reg               denied,
    output reg               check_done,
    output reg  [7:0]        approver_count,
    output reg  [N_MAX-1:0]  approver_bitmap,      // Which signers approved

    // =========================================================================
    // Configuration (loaded from eFuse/OTP at init)
    // =========================================================================
    input  wire [7:0]        cfg_k_threshold,      // Runtime k override
    input  wire [7:0]        cfg_n_signers,         // Runtime n override
    input  wire              cfg_override_valid,

    // =========================================================================
    // Status
    // =========================================================================
    output reg  [3:0]        state,
    output reg               busy,
    output reg               timeout_flag
);

    // =========================================================================
    // FSM STATES
    // =========================================================================

    localparam S_IDLE           = 4'd0;
    localparam S_COLLECTING     = 4'd1;  // Collecting approvals
    localparam S_CHECK          = 4'd2;  // Check if threshold met
    localparam S_APPROVED       = 4'd3;
    localparam S_DENIED         = 4'd4;
    localparam S_TIMEOUT        = 4'd5;

    // =========================================================================
    // INTERNAL REGISTERS
    // =========================================================================

    reg [7:0]  effective_k;
    reg [7:0]  effective_n;
    reg [31:0] timeout_counter;

    // Signer tracking
    reg [N_MAX-1:0] signer_seen;  // Bitmap of which signers have approved

    // =========================================================================
    // MAIN FSM
    // =========================================================================

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= S_IDLE;
            approved        <= 1'b0;
            denied          <= 1'b0;
            check_done      <= 1'b0;
            approver_count  <= 8'd0;
            approver_bitmap <= {N_MAX{1'b0}};
            approval_ack    <= 1'b0;
            approval_reject <= 1'b0;
            busy            <= 1'b0;
            timeout_flag    <= 1'b0;

            effective_k     <= K_THRESHOLD[7:0];
            effective_n     <= N_SIGNERS[7:0];
            timeout_counter <= 32'd0;
            signer_seen     <= {N_MAX{1'b0}};
        end else begin
            // Default de-assertions
            approval_ack    <= 1'b0;
            approval_reject <= 1'b0;

            // Runtime configuration override
            if (cfg_override_valid) begin
                effective_k <= cfg_k_threshold;
                effective_n <= cfg_n_signers;
            end

            case (state)
                // =============================================================
                // IDLE
                // =============================================================
                S_IDLE: begin
                    approved    <= 1'b0;
                    denied      <= 1'b0;
                    check_done  <= 1'b0;
                    busy        <= 1'b0;
                    timeout_flag <= 1'b0;

                    if (check_start) begin
                        state           <= S_COLLECTING;
                        busy            <= 1'b1;
                        approver_count  <= 8'd0;
                        approver_bitmap <= {N_MAX{1'b0}};
                        signer_seen     <= {N_MAX{1'b0}};
                        timeout_counter <= 32'd0;
                    end
                end

                // =============================================================
                // COLLECTING: Accept approval submissions
                // =============================================================
                S_COLLECTING: begin
                    timeout_counter <= timeout_counter + 1;

                    // Accept pre-loaded approvals (from FRAM)
                    if (preload_valid) begin
                        if (preload_signer_id < effective_n &&
                            !signer_seen[preload_signer_id] &&
                            (preload_expiry == 32'd0 || preload_expiry > current_timestamp)) begin
                            signer_seen[preload_signer_id]     <= 1'b1;
                            approver_bitmap[preload_signer_id] <= 1'b1;
                            approver_count <= approver_count + 1;
                        end
                    end

                    // Accept live approvals
                    if (approval_valid) begin
                        if (approval_signer_id >= effective_n) begin
                            // Invalid signer ID
                            approval_reject <= 1'b1;
                        end else if (signer_seen[approval_signer_id]) begin
                            // Duplicate approval
                            approval_reject <= 1'b1;
                        end else begin
                            // Valid new approval
                            signer_seen[approval_signer_id]     <= 1'b1;
                            approver_bitmap[approval_signer_id] <= 1'b1;
                            approver_count  <= approver_count + 1;
                            approval_ack    <= 1'b1;
                        end
                    end

                    // Check threshold
                    if (approver_count >= effective_k) begin
                        state <= S_APPROVED;
                    end else if (timeout_counter >= APPROVAL_TIMEOUT) begin
                        state <= S_TIMEOUT;
                    end
                end

                // =============================================================
                // CHECK: Final threshold comparison (not used in streaming mode)
                // =============================================================
                S_CHECK: begin
                    if (approver_count >= effective_k) begin
                        state <= S_APPROVED;
                    end else begin
                        state <= S_DENIED;
                    end
                end

                // =============================================================
                // APPROVED
                // =============================================================
                S_APPROVED: begin
                    approved   <= 1'b1;
                    check_done <= 1'b1;
                    busy       <= 1'b0;
                    if (!check_start) begin
                        state <= S_IDLE;
                    end
                end

                // =============================================================
                // DENIED
                // =============================================================
                S_DENIED: begin
                    denied     <= 1'b1;
                    check_done <= 1'b1;
                    busy       <= 1'b0;
                    if (!check_start) begin
                        state <= S_IDLE;
                    end
                end

                // =============================================================
                // TIMEOUT
                // =============================================================
                S_TIMEOUT: begin
                    timeout_flag <= 1'b1;
                    denied       <= 1'b1;
                    check_done   <= 1'b1;
                    busy         <= 1'b0;
                    if (!check_start) begin
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
