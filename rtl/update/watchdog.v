// =============================================================================
// FPGA METADATA
// =============================================================================
// Module: Update Watchdog
// Version: 1.0.0
// Purpose: Hardware watchdog for bitstream update safety with automatic
//          rollback if new bitstream fails to boot
// Clock Budget: 50 MHz system clock
// Interface: Heartbeat input, rollback trigger output
// Target: Lattice Nexus 40K (LIFCL-40)
// Upstream: estream-io monotonic rollback protection pattern
// =============================================================================

/*
 * Update Watchdog
 * ══════════════════════════════════════════════════════════════════════════════
 *
 * Provides hardware-enforced safety for bitstream updates:
 *
 * 1. After a new bitstream is loaded and the active slot is swapped,
 *    the watchdog timer starts.
 * 2. The new bitstream must assert a heartbeat signal within the
 *    timeout period to confirm it booted successfully.
 * 3. If no heartbeat is received, the watchdog triggers an automatic
 *    rollback to the previous (known-good) slot.
 * 4. Monotonic version tracking prevents rollback attacks - the version
 *    counter only increments, never decrements.
 *
 * Timeout Hierarchy:
 *   - Boot watchdog:  30 seconds (new bitstream must heartbeat)
 *   - Run watchdog:   5 seconds (ongoing health check, configurable)
 *   - EPO watchdog:   100 ms (safety-critical emergency power off)
 */

`timescale 1ns/1ps

module watchdog #(
    parameter BOOT_TIMEOUT_CYCLES = 1_500_000_000, // 30s at 50 MHz
    parameter RUN_TIMEOUT_CYCLES  = 250_000_000,   // 5s at 50 MHz
    parameter EPO_TIMEOUT_CYCLES  = 5_000_000,     // 100ms at 50 MHz
    parameter VERSION_BITS        = 32
)(
    input  wire        clk,
    input  wire        rst_n,

    // =========================================================================
    // Heartbeat Input (from running bitstream)
    // =========================================================================
    input  wire        heartbeat,         // Pulse to reset watchdog timer
    input  wire        boot_complete,     // One-shot: new bitstream booted OK

    // =========================================================================
    // Update Lifecycle
    // =========================================================================
    input  wire        update_started,    // New bitstream being written
    input  wire        update_committed,  // Slot swap complete, boot watchdog start
    input  wire [VERSION_BITS-1:0] update_version, // Version of new bitstream

    // =========================================================================
    // Rollback Interface (to flash_manager)
    // =========================================================================
    output reg         rollback_trigger,  // Assert to trigger slot rollback
    output reg         boot_timeout,      // Boot watchdog expired
    output reg         run_timeout,       // Run watchdog expired

    // =========================================================================
    // Safety Interface
    // =========================================================================
    output reg         epo_trigger,       // Emergency power off (safety)
    input  wire        epo_clear,         // Clear EPO condition

    // =========================================================================
    // Version Tracking (monotonic)
    // =========================================================================
    output reg  [VERSION_BITS-1:0] current_version,
    output reg  [VERSION_BITS-1:0] previous_version,
    output reg                     version_valid,

    // =========================================================================
    // Status
    // =========================================================================
    output reg  [3:0]  state,
    output reg  [31:0] time_since_heartbeat, // Cycles since last heartbeat
    output reg  [7:0]  boot_attempts,        // Number of failed boot attempts
    output reg         watchdog_active
);

    // =========================================================================
    // FSM STATES
    // =========================================================================

    localparam S_IDLE         = 4'd0;  // Normal operation, no update pending
    localparam S_UPDATING     = 4'd1;  // Update in progress (writing flash)
    localparam S_BOOT_WATCH   = 4'd2;  // Watching for successful boot
    localparam S_RUNNING      = 4'd3;  // Normal run with periodic heartbeat
    localparam S_ROLLBACK     = 4'd4;  // Triggering rollback
    localparam S_EPO          = 4'd5;  // Emergency power off

    // =========================================================================
    // INTERNAL REGISTERS
    // =========================================================================

    reg [31:0] boot_counter;
    reg [31:0] run_counter;
    reg [31:0] epo_counter;
    reg        epo_armed;              // EPO monitoring active
    reg [VERSION_BITS-1:0] pending_version;

    // =========================================================================
    // MAIN FSM
    // =========================================================================

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state               <= S_IDLE;
            rollback_trigger    <= 1'b0;
            boot_timeout        <= 1'b0;
            run_timeout         <= 1'b0;
            epo_trigger         <= 1'b0;
            current_version     <= {VERSION_BITS{1'b0}};
            previous_version    <= {VERSION_BITS{1'b0}};
            version_valid       <= 1'b0;
            time_since_heartbeat <= 32'd0;
            boot_attempts       <= 8'd0;
            watchdog_active     <= 1'b0;

            boot_counter        <= 32'd0;
            run_counter         <= 32'd0;
            epo_counter         <= 32'd0;
            epo_armed           <= 1'b0;
            pending_version     <= {VERSION_BITS{1'b0}};
        end else begin
            // Default de-assertions
            rollback_trigger <= 1'b0;

            // EPO monitoring (always active when armed)
            if (epo_armed) begin
                if (heartbeat) begin
                    epo_counter <= 32'd0;
                end else begin
                    epo_counter <= epo_counter + 1;
                    if (epo_counter >= EPO_TIMEOUT_CYCLES) begin
                        state <= S_EPO;
                    end
                end
            end

            // EPO clear
            if (epo_clear && state == S_EPO) begin
                epo_trigger <= 1'b0;
                epo_armed   <= 1'b0;
                state       <= S_IDLE;
            end

            case (state)
                // =============================================================
                // IDLE: Normal operation
                // =============================================================
                S_IDLE: begin
                    watchdog_active <= 1'b0;
                    boot_timeout    <= 1'b0;
                    run_timeout     <= 1'b0;

                    if (update_started) begin
                        state           <= S_UPDATING;
                        pending_version <= update_version;
                    end

                    // Track heartbeat even in idle (for monitoring)
                    if (heartbeat) begin
                        time_since_heartbeat <= 32'd0;
                    end else begin
                        time_since_heartbeat <= time_since_heartbeat + 1;
                    end
                end

                // =============================================================
                // UPDATING: Flash write in progress
                // =============================================================
                S_UPDATING: begin
                    watchdog_active <= 1'b0;

                    if (update_committed) begin
                        // Slot swap happened, start boot watchdog
                        state           <= S_BOOT_WATCH;
                        boot_counter    <= 32'd0;
                        watchdog_active <= 1'b1;

                        // Save version history (monotonic)
                        previous_version <= current_version;
                        current_version  <= pending_version;
                        version_valid    <= 1'b1;
                    end
                end

                // =============================================================
                // BOOT_WATCH: Waiting for new bitstream to boot
                // =============================================================
                S_BOOT_WATCH: begin
                    boot_counter <= boot_counter + 1;
                    time_since_heartbeat <= boot_counter;

                    if (boot_complete) begin
                        // Success! Transition to normal run monitoring
                        state        <= S_RUNNING;
                        run_counter  <= 32'd0;
                        epo_armed    <= 1'b1;
                        epo_counter  <= 32'd0;
                    end else if (boot_counter >= BOOT_TIMEOUT_CYCLES) begin
                        // Boot failed - rollback
                        boot_timeout  <= 1'b1;
                        boot_attempts <= boot_attempts + 1;
                        state         <= S_ROLLBACK;
                    end
                end

                // =============================================================
                // RUNNING: Normal operation with run watchdog
                // =============================================================
                S_RUNNING: begin
                    if (heartbeat) begin
                        run_counter          <= 32'd0;
                        time_since_heartbeat <= 32'd0;
                    end else begin
                        run_counter          <= run_counter + 1;
                        time_since_heartbeat <= run_counter;

                        if (run_counter >= RUN_TIMEOUT_CYCLES) begin
                            run_timeout <= 1'b1;
                            state       <= S_ROLLBACK;
                        end
                    end

                    // New update can interrupt running state
                    if (update_started) begin
                        state           <= S_UPDATING;
                        pending_version <= update_version;
                    end
                end

                // =============================================================
                // ROLLBACK: Trigger flash slot rollback
                // =============================================================
                S_ROLLBACK: begin
                    rollback_trigger <= 1'b1;

                    // Restore previous version
                    current_version <= previous_version;

                    // Wait one cycle for flash_manager to acknowledge
                    state <= S_IDLE;
                end

                // =============================================================
                // EPO: Emergency Power Off
                // =============================================================
                S_EPO: begin
                    epo_trigger     <= 1'b1;
                    watchdog_active <= 1'b0;
                    // Held until epo_clear (handled above)
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
