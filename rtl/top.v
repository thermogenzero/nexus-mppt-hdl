// =============================================================================
// FPGA METADATA
// =============================================================================
// Module: Nexus MPPT Top Level
// Version: 1.0.0 (Phase 1 - Remote Bitstream Update)
// Purpose: Top-level integration of all nexus-mppt-hdl subsystems
// Clock Budget: 50 MHz system clock
// Target: Lattice Nexus 40K (LIFCL-40)
// =============================================================================

/*
 * Nexus MPPT Top Level
 * ══════════════════════════════════════════════════════════════════════════════
 *
 * Top-level module for the Nexus 40K MPPT controller. Currently implements
 * Phase 1 (Remote Bitstream Update) and Safety subsystems. Later phases
 * will add PoVC (Phase 2), estream Protocol (Phase 3), 108-channel MPPT
 * (Phase 4), and SCADA/Console (Phase 5).
 *
 * ┌─────────────────────────────────────────────────────────────────────────┐
 * │                    NEXUS-MPPT TOP LEVEL                                  │
 * │                                                                          │
 * │  ┌─────────────────────────────────────────────────────────────────┐    │
 * │  │                 Update Subsystem (Phase 1) ✓                     │    │
 * │  │  bitstream_rx → governance → ml_dsa87 → flash_mgr → watchdog    │    │
 * │  └─────────────────────────────────────────────────────────────────┘    │
 * │                                                                          │
 * │  ┌─────────────────────────────────────────────────────────────────┐    │
 * │  │                 Safety Subsystem ✓                               │    │
 * │  │  overvoltage (58V protection) + ground_fault (GFDI)              │    │
 * │  └─────────────────────────────────────────────────────────────────┘    │
 * │                                                                          │
 * │  ┌─────────────────────────────────────────────────────────────────┐    │
 * │  │                 MPPT Subsystem (Phase 4)                         │    │
 * │  │  [Not yet implemented - 108 channel P&O]                         │    │
 * │  └─────────────────────────────────────────────────────────────────┘    │
 * │                                                                          │
 * │  ┌─────────────────────────────────────────────────────────────────┐    │
 * │  │                 PoVC Subsystem (Phase 2)                         │    │
 * │  │  [Not yet implemented - Merkle witness + attestation]            │    │
 * │  └─────────────────────────────────────────────────────────────────┘    │
 * │                                                                          │
 * │  ┌─────────────────────────────────────────────────────────────────┐    │
 * │  │                 estream Protocol (Phase 3)                       │    │
 * │  │  [Not yet implemented - wire encoder + discovery]                │    │
 * │  └─────────────────────────────────────────────────────────────────┘    │
 * │                                                                          │
 * └─────────────────────────────────────────────────────────────────────────┘
 */

`timescale 1ns/1ps

module top (
    // =========================================================================
    // Clock and Reset
    // =========================================================================
    input  wire        clk_50mhz,
    input  wire        rst_n,

    // =========================================================================
    // SPI Flash (Dual-Slot Bitstream Storage)
    // =========================================================================
    output wire        flash_cs_n,
    output wire        flash_sclk,
    output wire        flash_mosi,
    input  wire        flash_miso,

    // =========================================================================
    // Status LEDs
    // =========================================================================
    output reg         led_heartbeat,
    output reg         led_update,
    output reg         led_error,

    // =========================================================================
    // Safety Outputs
    // =========================================================================
    output wire        epo_out_n,
    input  wire        gfdi_sense,

    // =========================================================================
    // Serial / Wire Protocol Input (Phase 1: serial bridge, Phase 3: Ethernet)
    // =========================================================================
    input  wire [7:0]  ext_rx_data,
    input  wire        ext_rx_valid,
    output wire        ext_rx_ready,
    input  wire        ext_rx_last,

    // =========================================================================
    // TSSP Interface (to estream Node)
    // =========================================================================
    output wire        tssp_req_valid,
    output wire [7:0]  tssp_req_cmd,
    output wire [255:0] tssp_req_hash,
    input  wire        tssp_req_ready,
    input  wire        tssp_resp_valid,
    input  wire        tssp_resp_pass,
    input  wire [7:0]  tssp_resp_status,

    // =========================================================================
    // Governance Approvals
    // =========================================================================
    input  wire        approval_valid,
    input  wire [7:0]  approval_signer_id,
    input  wire [127:0] approval_hash,

    // =========================================================================
    // Control
    // =========================================================================
    input  wire        update_enable,
    input  wire        update_abort,
    input  wire        use_tssp,
    input  wire        boot_complete,

    // =========================================================================
    // ADC Input (Phase 4: MPPT, Phase 1: safety only)
    // =========================================================================
    input  wire [11:0] bus_voltage_adc,
    input  wire        adc_valid,
    input  wire [11:0] gfdi_adc,
    input  wire        gfdi_adc_valid
);

    // =========================================================================
    // INTERNAL WIRES
    // =========================================================================

    wire        update_busy;
    wire        update_done;
    wire        update_error_w;
    wire        active_slot;
    wire [31:0] active_version;
    wire        rollback_occurred;
    wire        watchdog_active_w;

    // Safety
    wire        ov_warning;
    wire        ov_alarm;
    wire        ov_tripped;
    wire        gf_trip;
    wire        gf_warning;

    // Heartbeat generator
    reg [25:0]  heartbeat_counter;
    wire        heartbeat_pulse;

    // =========================================================================
    // HEARTBEAT GENERATOR (1 Hz blink, confirms FPGA is alive)
    // =========================================================================

    always @(posedge clk_50mhz or negedge rst_n) begin
        if (!rst_n) begin
            heartbeat_counter <= 26'd0;
            led_heartbeat     <= 1'b0;
        end else begin
            heartbeat_counter <= heartbeat_counter + 1;
            if (heartbeat_counter == 26'd49_999_999) begin
                heartbeat_counter <= 26'd0;
                led_heartbeat     <= ~led_heartbeat;
            end
        end
    end

    assign heartbeat_pulse = (heartbeat_counter == 26'd0);

    // =========================================================================
    // LED STATUS DRIVERS
    // =========================================================================

    always @(posedge clk_50mhz or negedge rst_n) begin
        if (!rst_n) begin
            led_update <= 1'b0;
            led_error  <= 1'b0;
        end else begin
            led_update <= update_busy;
            led_error  <= update_error_w | ov_tripped | gf_trip;
        end
    end

    // =========================================================================
    // UPDATE SUBSYSTEM (Phase 1)
    // =========================================================================

    update_top #(
        .GOVERNANCE_K (5),
        .GOVERNANCE_N (9)
    ) u_update (
        .clk                (clk_50mhz),
        .rst_n              (rst_n),
        .rx_data            (ext_rx_data),
        .rx_valid           (ext_rx_valid),
        .rx_ready           (ext_rx_ready),
        .rx_last            (ext_rx_last),
        .flash_cs_n         (flash_cs_n),
        .flash_sclk         (flash_sclk),
        .flash_mosi         (flash_mosi),
        .flash_miso         (flash_miso),
        .tssp_req_valid     (tssp_req_valid),
        .tssp_req_cmd       (tssp_req_cmd),
        .tssp_req_hash      (tssp_req_hash),
        .tssp_req_ready     (tssp_req_ready),
        .tssp_resp_valid    (tssp_resp_valid),
        .tssp_resp_pass     (tssp_resp_pass),
        .tssp_resp_status   (tssp_resp_status),
        .approval_valid     (approval_valid),
        .approval_signer_id (approval_signer_id),
        .approval_hash      (approval_hash),
        .update_enable      (update_enable),
        .update_abort       (update_abort),
        .use_tssp           (use_tssp),
        .heartbeat          (heartbeat_pulse),
        .boot_complete      (boot_complete),
        .update_state       (),
        .update_busy        (update_busy),
        .update_done        (update_done),
        .update_error       (update_error_w),
        .update_error_code  (),
        .bytes_transferred  (),
        .active_slot        (active_slot),
        .active_version     (active_version),
        .rollback_occurred  (rollback_occurred),
        .watchdog_active    (watchdog_active_w),
        .governance_approvals ()
    );

    // =========================================================================
    // SAFETY SUBSYSTEM
    // =========================================================================

    overvoltage u_overvoltage (
        .clk              (clk_50mhz),
        .rst_n            (rst_n),
        .bus_voltage_adc  (bus_voltage_adc),
        .adc_valid        (adc_valid),
        .hw_overvoltage   (1'b0),       // Hardware comparator (connect to pin)
        .epo_out_n        (epo_out_n),
        .warning          (ov_warning),
        .alarm            (ov_alarm),
        .tripped          (ov_tripped),
        .clear_trip       (1'b0),       // TODO: connect to control register
        .enable           (1'b1),
        .last_voltage     (),
        .peak_voltage     (),
        .trip_count       ()
    );

    ground_fault u_ground_fault (
        .clk              (clk_50mhz),
        .rst_n            (rst_n),
        .imbalance_adc    (gfdi_adc),
        .adc_valid        (gfdi_adc_valid),
        .hw_gfdi          (gfdi_sense),
        .gfdi_trip        (gf_trip),
        .gfdi_warning     (gf_warning),
        .fault_active     (),
        .enable           (1'b1),
        .clear_fault      (1'b0),
        .self_test_start  (1'b0),
        .fault_magnitude  (),
        .fault_duration   (),
        .fault_count      (),
        .self_test_pass   ()
    );

endmodule
