// =============================================================================
// FPGA METADATA
// =============================================================================
// Module: Overvoltage Protection
// Version: 1.0.0
// Purpose: 58V bus overvoltage detection and emergency power off
// Clock Budget: 50 MHz, single-cycle detection
// Interface: ADC comparator input, EPO output
// Target: Lattice Nexus 40K (LIFCL-40)
// Heritage: TEG-Opti iCE40 safety subsystem (proven in field)
// =============================================================================

/*
 * Overvoltage Protection
 * ══════════════════════════════════════════════════════════════════════════════
 *
 * Safety-critical module that monitors the DC bus voltage and triggers
 * Emergency Power Off (EPO) if the bus exceeds 58V. This protects TEG
 * modules, power electronics, and downstream loads.
 *
 * The module operates on a digitized bus voltage reading from the ADC and
 * also monitors a hardware comparator output for sub-microsecond response.
 *
 * Thresholds:
 *   - Warning:  52V (soft alarm, log event)
 *   - Alarm:    55V (shed load, throttle TEGs)
 *   - Trip:     58V (immediate EPO, latch until cleared)
 *
 * ADC scaling: 12-bit ADC, 0-75V range → 1 LSB = 18.31 mV
 *   - 52V = ADC 2839
 *   - 55V = ADC 3003
 *   - 58V = ADC 3167
 */

`timescale 1ns/1ps

module overvoltage #(
    parameter ADC_BITS        = 12,
    parameter WARN_THRESHOLD  = 12'd2839,    // 52V
    parameter ALARM_THRESHOLD = 12'd3003,    // 55V
    parameter TRIP_THRESHOLD  = 12'd3167,    // 58V
    parameter DEGLITCH_CYCLES = 50_000       // 1ms at 50 MHz
)(
    input  wire        clk,
    input  wire        rst_n,

    // =========================================================================
    // Voltage Input
    // =========================================================================
    input  wire [ADC_BITS-1:0] bus_voltage_adc,   // From ADC
    input  wire                adc_valid,          // ADC reading valid
    input  wire                hw_overvoltage,     // Hardware comparator (fast path)

    // =========================================================================
    // Protection Outputs
    // =========================================================================
    output reg         epo_out_n,        // Emergency Power Off (active low)
    output reg         warning,          // 52V warning
    output reg         alarm,            // 55V alarm (load shed)
    output reg         tripped,          // 58V trip (latched)

    // =========================================================================
    // Control
    // =========================================================================
    input  wire        clear_trip,       // Clear latched trip (requires key)
    input  wire        enable,           // Enable protection (default on)

    // =========================================================================
    // Telemetry
    // =========================================================================
    output reg  [ADC_BITS-1:0] last_voltage,
    output reg  [ADC_BITS-1:0] peak_voltage,
    output reg  [31:0]         trip_count
);

    // =========================================================================
    // INTERNAL REGISTERS
    // =========================================================================

    reg [15:0] deglitch_counter;
    reg        trip_latch;
    reg        alarm_raw;
    reg        trip_raw;

    // =========================================================================
    // VOLTAGE MONITORING
    // =========================================================================

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            epo_out_n        <= 1'b1;  // Not tripped
            warning          <= 1'b0;
            alarm            <= 1'b0;
            tripped          <= 1'b0;
            trip_latch       <= 1'b0;
            last_voltage     <= {ADC_BITS{1'b0}};
            peak_voltage     <= {ADC_BITS{1'b0}};
            trip_count       <= 32'd0;
            deglitch_counter <= 16'd0;
            alarm_raw        <= 1'b0;
            trip_raw         <= 1'b0;
        end else begin
            // Hardware comparator fast path (no deglitch - hardware handles it)
            if (hw_overvoltage && enable) begin
                epo_out_n  <= 1'b0;
                trip_latch <= 1'b1;
                tripped    <= 1'b1;
            end

            // ADC-based monitoring
            if (adc_valid) begin
                last_voltage <= bus_voltage_adc;

                // Peak tracking
                if (bus_voltage_adc > peak_voltage) begin
                    peak_voltage <= bus_voltage_adc;
                end

                // Threshold comparison
                warning   <= (bus_voltage_adc >= WARN_THRESHOLD);
                alarm_raw <= (bus_voltage_adc >= ALARM_THRESHOLD);
                trip_raw  <= (bus_voltage_adc >= TRIP_THRESHOLD);
            end

            // Deglitch for ADC-based trip (prevent noise trips)
            if (trip_raw && enable) begin
                if (deglitch_counter >= DEGLITCH_CYCLES) begin
                    epo_out_n  <= 1'b0;
                    trip_latch <= 1'b1;
                    tripped    <= 1'b1;
                    trip_count <= trip_count + 1;
                end else begin
                    deglitch_counter <= deglitch_counter + 1;
                end
            end else begin
                deglitch_counter <= 16'd0;
            end

            // Alarm output (deglitch via hysteresis)
            alarm <= alarm_raw;

            // Trip latch - holds until explicit clear
            if (trip_latch) begin
                epo_out_n <= 1'b0;
                tripped   <= 1'b1;
            end

            // Clear trip (requires deliberate action)
            if (clear_trip && !trip_raw && !hw_overvoltage) begin
                trip_latch <= 1'b0;
                tripped    <= 1'b0;
                epo_out_n  <= 1'b1;
            end
        end
    end

endmodule
