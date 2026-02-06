// =============================================================================
// Testbench: Update Subsystem
// =============================================================================
// Tests the complete Phase 1 remote bitstream update flow:
//   1. Reset and initialization
//   2. Header reception and parsing
//   3. Governance approval (k-of-n threshold)
//   4. ML-DSA-87 signature verification (via TSSP)
//   5. Flash write and slot swap
//   6. Watchdog boot monitoring
//   7. End-to-end completion verification
// =============================================================================

`timescale 1ns/1ps

module update_tb;

    // =========================================================================
    // PARAMETERS
    // =========================================================================

    parameter CLK_PERIOD  = 20;   // 50 MHz
    parameter HEADER_SIZE = 64;
    parameter PAYLOAD_SIZE = 256;

    // Orchestration states (mirror update_top)
    localparam O_IDLE      = 4'd0;
    localparam O_RECEIVING = 4'd1;
    localparam O_GOVERNANCE= 4'd2;
    localparam O_VERIFY    = 4'd3;
    localparam O_WRITING   = 4'd4;
    localparam O_SWAPPING  = 4'd5;
    localparam O_DONE      = 4'd6;
    localparam O_ERROR     = 4'd7;

    // =========================================================================
    // DUT SIGNALS
    // =========================================================================

    reg         clk;
    reg         rst_n;

    // Data input
    reg  [7:0]  rx_data;
    reg         rx_valid;
    wire        rx_ready;
    reg         rx_last;

    // Flash
    wire        flash_cs_n;
    wire        flash_sclk;
    wire        flash_mosi;
    reg         flash_miso;

    // TSSP
    wire        tssp_req_valid;
    wire [7:0]  tssp_req_cmd;
    wire [255:0] tssp_req_hash;
    reg         tssp_req_ready;
    reg         tssp_resp_valid;
    reg         tssp_resp_pass;
    reg  [7:0]  tssp_resp_status;

    // Governance
    reg         approval_valid;
    reg  [7:0]  approval_signer_id;
    reg  [127:0] approval_hash;

    // Control
    reg         update_enable;
    reg         update_abort;
    reg         use_tssp;
    reg         heartbeat;
    reg         boot_complete;

    // Status
    wire [3:0]  update_state;
    wire        update_busy;
    wire        update_done;
    wire        update_error;
    wire [7:0]  update_error_code;
    wire [31:0] bytes_transferred;
    wire        active_slot;
    wire [31:0] active_version;
    wire        rollback_occurred;
    wire        watchdog_active;
    wire [7:0]  governance_approvals;

    // =========================================================================
    // DUT INSTANTIATION
    // =========================================================================

    update_top #(
        .GOVERNANCE_K (3),  // Reduced for testing (3-of-5)
        .GOVERNANCE_N (5)
    ) dut (
        .clk                (clk),
        .rst_n              (rst_n),
        .rx_data            (rx_data),
        .rx_valid           (rx_valid),
        .rx_ready           (rx_ready),
        .rx_last            (rx_last),
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
        .heartbeat          (heartbeat),
        .boot_complete      (boot_complete),
        .update_state       (update_state),
        .update_busy        (update_busy),
        .update_done        (update_done),
        .update_error       (update_error),
        .update_error_code  (update_error_code),
        .bytes_transferred  (bytes_transferred),
        .active_slot        (active_slot),
        .active_version     (active_version),
        .rollback_occurred  (rollback_occurred),
        .watchdog_active    (watchdog_active),
        .governance_approvals (governance_approvals)
    );

    // =========================================================================
    // CLOCK GENERATION
    // =========================================================================

    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // =========================================================================
    // CRC32 FUNCTION (IEEE 802.3, polynomial 0xEDB88320 reflected)
    // =========================================================================
    // Matches the implementation in bitstream_rx.v exactly.

    function [31:0] crc32_byte;
        input [31:0] crc_in;
        input [7:0]  data_in;
        reg [31:0] c;
        reg [7:0]  d;
        integer k;
        begin
            c = crc_in;
            d = data_in;
            for (k = 0; k < 8; k = k + 1) begin
                if ((c[0] ^ d[0]) == 1'b1)
                    c = {1'b0, c[31:1]} ^ 32'hEDB88320;
                else
                    c = {1'b0, c[31:1]};
                d = {1'b0, d[7:1]};
            end
            crc32_byte = c;
        end
    endfunction

    // =========================================================================
    // PRE-COMPUTE PAYLOAD CRC
    // =========================================================================
    // Payload is bytes 0x00 through 0xFF (256 bytes).

    reg [31:0] payload_crc;
    integer ci;
    initial begin
        payload_crc = 32'hFFFFFFFF;
        for (ci = 0; ci < PAYLOAD_SIZE; ci = ci + 1) begin
            payload_crc = crc32_byte(payload_crc, ci[7:0]);
        end
        payload_crc = ~payload_crc;
    end

    // =========================================================================
    // TEST HELPERS
    // =========================================================================

    integer test_pass_count;
    integer test_fail_count;
    integer i;

    task reset;
        begin
            rst_n           <= 0;
            rx_data         <= 0;
            rx_valid        <= 0;
            rx_last         <= 0;
            flash_miso      <= 0;
            tssp_req_ready  <= 0;
            tssp_resp_valid <= 0;
            tssp_resp_pass  <= 0;
            tssp_resp_status <= 0;
            approval_valid  <= 0;
            approval_signer_id <= 0;
            approval_hash   <= 0;
            update_enable   <= 0;
            update_abort    <= 0;
            use_tssp        <= 1;
            heartbeat       <= 0;
            boot_complete   <= 0;
            #(CLK_PERIOD * 10);
            rst_n <= 1;
            #(CLK_PERIOD * 5);
        end
    endtask

    // Send a single byte on the rx interface with AXI-Stream handshake.
    // Drives signals at negedge so DUT reliably samples at posedge.
    integer byte_count;
    integer wait_count;
    task send_byte;
        input [7:0] data;
        input        last;
        begin
            // Drive data at negedge (stable by next posedge)
            @(negedge clk);
            rx_data  = data;
            rx_valid = 1;
            rx_last  = last;

            // Wait for handshake (valid & ready both high at posedge)
            wait_count = 0;
            @(posedge clk);
            while (!rx_ready && wait_count < 5000) begin
                @(posedge clk);
                wait_count = wait_count + 1;
            end

            if (wait_count >= 5000) begin
                $display("  FAIL: send_byte stuck at byte %0d (waited %0d cycles)",
                         byte_count, wait_count);
                test_fail_count = test_fail_count + 1;
            end

            // Deassert at negedge
            @(negedge clk);
            rx_valid = 0;
            rx_last  = 0;
            byte_count = byte_count + 1;
        end
    endtask

    // Send a 64-byte header
    // Buffer layout (MSB-first packing in bitstream_rx):
    //   header_buffer[511:480] = bytes 0-3   = Version
    //   header_buffer[479:448] = bytes 4-7   = Reserved
    //   header_buffer[447:416] = bytes 8-11  = Size
    //   header_buffer[415:384] = bytes 12-15 = CRC32
    //   header_buffer[383:128] = bytes 16-47 = Signature (32 bytes)
    //   header_buffer[127:0]   = bytes 48-63 = Gov hash (16 bytes)
    task send_header;
        input [31:0] version;
        input [31:0] size;
        input [31:0] crc32;
        begin
            // Bytes 0-3: Version (big-endian)
            send_byte(version[31:24], 0);
            send_byte(version[23:16], 0);
            send_byte(version[15:8],  0);
            send_byte(version[7:0],   0);

            // Bytes 4-7: Reserved
            for (i = 0; i < 4; i = i + 1) begin
                send_byte(8'h00, 0);
            end

            // Bytes 8-11: Size (big-endian)
            send_byte(size[31:24], 0);
            send_byte(size[23:16], 0);
            send_byte(size[15:8],  0);
            send_byte(size[7:0],   0);

            // Bytes 12-15: CRC32
            send_byte(crc32[31:24], 0);
            send_byte(crc32[23:16], 0);
            send_byte(crc32[15:8],  0);
            send_byte(crc32[7:0],   0);

            // Bytes 16-47: Signature (32 bytes of 0xAA)
            for (i = 0; i < 32; i = i + 1) begin
                send_byte(8'hAA, 0);
            end

            // Bytes 48-63: Governance hash (16 bytes of 0xBB)
            for (i = 0; i < 16; i = i + 1) begin
                send_byte(8'hBB, 0);
            end
        end
    endtask

    // Submit governance approval
    task submit_approval;
        input [7:0] signer_id;
        begin
            @(posedge clk);
            approval_valid     <= 1;
            approval_signer_id <= signer_id;
            approval_hash      <= {signer_id, 120'd0};
            @(posedge clk);
            approval_valid <= 0;
            #(CLK_PERIOD * 2);
        end
    endtask

    // Respond to TSSP verification request
    // Uses negedge-aligned blocking assignments to avoid NBA race conditions
    // with the DUT's posedge-sampled inputs.
    integer tssp_wait;
    task tssp_respond;
        input pass;
        begin
            // Wait for TSSP request with timeout
            tssp_wait = 0;
            while (!tssp_req_valid && tssp_wait < 10000) begin
                @(posedge clk);
                tssp_wait = tssp_wait + 1;
            end

            if (tssp_req_valid) begin
                $display("  TSSP request received after %0d cycles (cmd=0x%02h)",
                         tssp_wait, tssp_req_cmd);

                // Accept the request (set at negedge so DUT sees it at next posedge)
                @(negedge clk);
                tssp_req_ready = 1;
                @(posedge clk);     // DUT samples req_ready=1 here
                @(negedge clk);
                tssp_req_ready = 0;

                // Simulate crypto verification time (~10 cycles)
                repeat(10) @(posedge clk);

                // Send response (set at negedge so DUT sees it at next posedge)
                @(negedge clk);
                tssp_resp_valid  = 1;
                tssp_resp_pass   = pass;
                tssp_resp_status = pass ? 8'h00 : 8'hFF;
                @(posedge clk);     // DUT samples resp_valid=1 here
                @(posedge clk);     // Hold one extra cycle for safety
                @(negedge clk);
                tssp_resp_valid  = 0;

                $display("  TSSP verification complete (pass=%0b)", pass);
            end else begin
                $display("  FAIL: TSSP request not received (timeout %0d cycles)",
                         tssp_wait);
                test_fail_count = test_fail_count + 1;
            end
        end
    endtask

    // Wait for a specific orchestration state with timeout
    integer state_wait;
    task wait_for_state;
        input [3:0] target_state;
        input integer max_cycles;
        begin
            state_wait = 0;
            while (update_state != target_state && state_wait < max_cycles) begin
                @(posedge clk);
                state_wait = state_wait + 1;
            end
            if (state_wait >= max_cycles) begin
                $display("  FAIL: Timed out waiting for state %0d (stuck at %0d after %0d cycles)",
                         target_state, update_state, state_wait);
                test_fail_count = test_fail_count + 1;
            end
        end
    endtask

    task check;
        input        condition;
        input [639:0] message;  // wider for longer messages
        begin
            if (condition) begin
                $display("  PASS: %0s", message);
                test_pass_count = test_pass_count + 1;
            end else begin
                $display("  FAIL: %0s", message);
                test_fail_count = test_fail_count + 1;
            end
        end
    endtask

    // =========================================================================
    // TEST SCENARIOS
    // =========================================================================

    initial begin
        $dumpfile("build/update_tb.vcd");
        $dumpvars(0, update_tb);

        test_pass_count = 0;
        test_fail_count = 0;

        $display("");
        $display("==========================================================");
        $display("  nexus-mppt-hdl Update Subsystem Testbench");
        $display("  Phase 1: Remote Bitstream Update");
        $display("==========================================================");
        $display("");
        $display("  Payload CRC32: 0x%08h", payload_crc);
        $display("");

        // =====================================================================
        // TEST 1: Reset and Initialization
        // =====================================================================
        $display("[TEST 1] Reset and Initialization");
        reset;
        check(!update_busy,       "Not busy after reset");
        check(!update_error,      "No error after reset");
        check(!update_done,       "Not done after reset");
        check(active_slot == 0,   "Active slot is A after reset");
        check(update_state == O_IDLE, "Orchestration in IDLE");
        $display("");

        // =====================================================================
        // TEST 2: Enable Update, Send Header
        // =====================================================================
        $display("[TEST 2] Header Reception");
        update_enable <= 1;
        #(CLK_PERIOD * 5);

        check(update_state == O_RECEIVING, "Transitioned to RECEIVING");
        check(rx_ready, "RX ready for header data");

        // Send a valid header: version=1, size=256 bytes, crc=computed
        byte_count = 0;
        send_header(32'd1, PAYLOAD_SIZE, payload_crc);

        $display("  %0d header bytes sent", byte_count);

        // Wait for header to be parsed and orchestration to advance
        #(CLK_PERIOD * 5);
        check(update_busy, "Busy during update");
        check(update_state == O_GOVERNANCE || update_state == O_VERIFY,
              "Advanced past RECEIVING after header");
        $display("");

        // =====================================================================
        // TEST 3: Governance Approval (3-of-5)
        // =====================================================================
        $display("[TEST 3] Governance Approval (3-of-5)");

        // Submit 3 approvals from signers 0, 1, 2
        submit_approval(8'd0);
        submit_approval(8'd1);
        submit_approval(8'd2);

        // Wait for governance to complete and orch to advance
        wait_for_state(O_VERIFY, 1000);

        check(governance_approvals >= 3, "3 governance approvals counted");
        check(update_state == O_VERIFY, "Transitioned to VERIFY");
        $display("");

        // =====================================================================
        // TEST 4: ML-DSA-87 Signature Verification (TSSP)
        // =====================================================================
        $display("[TEST 4] ML-DSA-87 Signature Verification (TSSP)");

        // The ml_dsa87_verify module should have already sent a TSSP request
        // (hash-only mode, skipping sig loading). Respond with pass.
        tssp_respond(1);

        // Debug: trace ml_dsa87 and orchestration state after TSSP
        $display("  DEBUG: ml_dsa87_state=%0d verify_done=%0b verify_pass=%0b",
                 dut.u_ml_dsa87.state, dut.u_ml_dsa87.verify_done,
                 dut.u_ml_dsa87.verify_pass);
        $display("  DEBUG: orch_state=%0d", dut.orch_state);

        // Wait for verification to complete and orch to advance
        wait_for_state(O_WRITING, 1000);

        check(update_state == O_WRITING, "Transitioned to WRITING");
        $display("");

        // =====================================================================
        // TEST 5: Flash Write (256 payload bytes)
        // =====================================================================
        $display("[TEST 5] Flash Write (%0d bytes)", PAYLOAD_SIZE);

        // Small delay for flash erase to complete (simulated ~16 cycles)
        #(CLK_PERIOD * 50);

        // Send payload bytes (0x00 through 0xFF)
        byte_count = 0;
        for (i = 0; i < PAYLOAD_SIZE; i = i + 1) begin
            send_byte(i[7:0], (i == PAYLOAD_SIZE - 1));
        end

        $display("  %0d payload bytes sent", byte_count);

        // Wait for flash write to complete and orch to reach DONE
        wait_for_state(O_DONE, 5000);

        check(update_done, "Update completed successfully");
        check(!update_error, "No error during update");
        check(bytes_transferred > 0, "Bytes transferred > 0");
        $display("  Bytes transferred: %0d", bytes_transferred);
        $display("  Active slot: %0s", active_slot ? "B" : "A");
        $display("");

        // =====================================================================
        // TEST 6: Watchdog Boot Monitoring
        // =====================================================================
        $display("[TEST 6] Watchdog Boot Monitoring");

        // The watchdog should be tracking the boot of the new bitstream
        $display("  Watchdog active: %0b", watchdog_active);

        // Simulate successful boot: assert boot_complete for one cycle
        #(CLK_PERIOD * 10);
        boot_complete <= 1;
        @(posedge clk);
        boot_complete <= 0;
        #(CLK_PERIOD * 10);

        $display("  Watchdog active after boot_complete: %0b", watchdog_active);
        check(!rollback_occurred, "No rollback occurred");
        $display("");

        // =====================================================================
        // TEST 7: Clean Shutdown
        // =====================================================================
        $display("[TEST 7] Clean Shutdown");

        update_enable <= 0;
        #(CLK_PERIOD * 20);

        check(update_state == O_IDLE, "Returned to IDLE after disable");
        check(!update_busy, "Not busy after shutdown");
        $display("");

        // =====================================================================
        // RESULTS
        // =====================================================================
        $display("==========================================================");
        $display("  Test Results: %0d PASS, %0d FAIL",
                 test_pass_count, test_fail_count);
        $display("==========================================================");
        $display("");

        if (test_fail_count == 0)
            $display("  ALL TESTS PASSED");
        else
            $display("  SOME TESTS FAILED");

        $display("");
        $finish;
    end

    // =========================================================================
    // TIMEOUT WATCHDOG (prevent hung simulation)
    // =========================================================================

    initial begin
        #(CLK_PERIOD * 500_000);
        $display("");
        $display("ERROR: Simulation timeout!");
        $display("  Final state: %0d", update_state);
        $display("  update_busy: %0b", update_busy);
        $display("  update_error: %0b", update_error);
        $display("");
        $finish;
    end

endmodule
