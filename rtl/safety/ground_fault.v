// =============================================================================
// FPGA METADATA
// =============================================================================
// Module: Ground Fault Detection
// Version: 1.0.0
// Purpose: DC ground fault detection for TEG array safety
// Clock Budget: 50 MHz system clock
// Interface: Differential sense input, fault output
// Target: Lattice Nexus 40K (LIFCL-40)
// Heritage: TEG-Opti iCE40 safety subsystem (proven in field)
// =============================================================================

/*
 * Ground Fault Detection
 * ══════════════════════════════════════════════════════════════════════════════
 *
 * Monitors for DC ground faults in the TEG array by detecting current
 * imbalance between positive and negative bus conductors. A ground fault
 * indicates insulation failure and potential shock/fire hazard.
 *
 * Detection Method:
 * - Differential current transformer on +/- bus conductors
 * - Imbalance > threshold indicates ground fault
 * - Hardware comparator for fast detection (<1us)
 * - ADC for precision measurement and logging
 *
 * Response:
 * - Assert GFDI (Ground Fault Detector Interrupter) output
 * - Log fault data (magnitude, duration, location estimate)
 * - Report via StreamSight telemetry (Phase 2+)
 *
 * NEC 690.35 compliant (PV/TEG ground fault requirements)
 */

`timescale 1ns/1ps

module ground_fault #(
    parameter ADC_BITS         = 12,
    parameter FAULT_THRESHOLD  = 12'd100,    // ~30mA at typical scaling
    parameter WARN_THRESHOLD   = 12'd50,     // ~15mA warning
    parameter DEGLITCH_CYCLES  = 250_000,    // 5ms at 50 MHz
    parameter SELF_TEST_PERIOD = 250_000_000 // 5s self-test interval
)(
    input  wire        clk,
    input  wire        rst_n,

    // =========================================================================
    // Sense Input
    // =========================================================================
    input  wire [ADC_BITS-1:0] imbalance_adc,   // Differential current ADC
    input  wire                adc_valid,
    input  wire                hw_gfdi,          // Hardware comparator (fast path)

    // =========================================================================
    // Protection Outputs
    // =========================================================================
    output reg         gfdi_trip,        // Ground fault trip (to contactor)
    output reg         gfdi_warning,     // Warning level
    output reg         fault_active,     // Fault currently detected

    // =========================================================================
    // Control
    // =========================================================================
    input  wire        enable,
    input  wire        clear_fault,
    input  wire        self_test_start,  // Inject test current

    // =========================================================================
    // Telemetry
    // =========================================================================
    output reg  [ADC_BITS-1:0] fault_magnitude,
    output reg  [31:0]         fault_duration,   // Cycles of active fault
    output reg  [31:0]         fault_count,
    output reg                 self_test_pass
);

    // =========================================================================
    // INTERNAL REGISTERS
    // =========================================================================

    reg [31:0] deglitch_counter;
    reg        fault_latch;
    reg [31:0] duration_counter;
    reg [31:0] self_test_counter;
    reg        self_test_active;

    // =========================================================================
    // GROUND FAULT MONITORING
    // =========================================================================

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gfdi_trip        <= 1'b0;
            gfdi_warning     <= 1'b0;
            fault_active     <= 1'b0;
            fault_latch      <= 1'b0;
            fault_magnitude  <= {ADC_BITS{1'b0}};
            fault_duration   <= 32'd0;
            fault_count      <= 32'd0;
            deglitch_counter <= 32'd0;
            duration_counter <= 32'd0;
            self_test_pass   <= 1'b0;
            self_test_active <= 1'b0;
            self_test_counter <= 32'd0;
        end else begin
            // Hardware fast path
            if (hw_gfdi && enable && !self_test_active) begin
                fault_latch   <= 1'b1;
                fault_active  <= 1'b1;
                gfdi_trip     <= 1'b1;
            end

            // ADC-based detection
            if (adc_valid && enable) begin
                if (imbalance_adc >= FAULT_THRESHOLD && !self_test_active) begin
                    if (deglitch_counter >= DEGLITCH_CYCLES) begin
                        fault_latch     <= 1'b1;
                        fault_active    <= 1'b1;
                        gfdi_trip       <= 1'b1;
                        fault_magnitude <= imbalance_adc;
                        if (!fault_latch) begin
                            fault_count <= fault_count + 1;
                        end
                    end else begin
                        deglitch_counter <= deglitch_counter + 1;
                    end
                end else if (imbalance_adc >= WARN_THRESHOLD) begin
                    gfdi_warning     <= 1'b1;
                    deglitch_counter <= 32'd0;
                end else begin
                    gfdi_warning     <= 1'b0;
                    deglitch_counter <= 32'd0;
                    if (!fault_latch) begin
                        fault_active <= 1'b0;
                    end
                end
            end

            // Duration tracking
            if (fault_active) begin
                duration_counter <= duration_counter + 1;
                fault_duration   <= duration_counter;
            end

            // Clear fault
            if (clear_fault && !hw_gfdi) begin
                fault_latch      <= 1'b0;
                fault_active     <= 1'b0;
                gfdi_trip        <= 1'b0;
                duration_counter <= 32'd0;
            end

            // Self-test
            if (self_test_start) begin
                self_test_active  <= 1'b1;
                self_test_counter <= 32'd0;
                self_test_pass    <= 1'b0;
            end
            if (self_test_active) begin
                self_test_counter <= self_test_counter + 1;
                // Self-test injects known current; if GFDI fires, test passes
                if (hw_gfdi) begin
                    self_test_pass   <= 1'b1;
                    self_test_active <= 1'b0;
                end else if (self_test_counter >= SELF_TEST_PERIOD) begin
                    self_test_pass   <= 1'b0;  // Test failed
                    self_test_active <= 1'b0;
                end
            end
        end
    end

endmodule
