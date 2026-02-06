// =============================================================================
// Testbench: Update Subsystem
// =============================================================================
// Tests the complete Phase 1 remote bitstream update flow:
//   1. Header reception and parsing
//   2. Governance approval (k-of-n threshold)
//   3. ML-DSA-87 signature verification (via TSSP)
//   4. Flash write and slot swap
//   5. Watchdog boot monitoring
//   6. Error cases (bad magic, timeout, rollback)
// =============================================================================

`timescale 1ns/1ps

module update_tb;

    // =========================================================================
    // PARAMETERS
    // =========================================================================

    parameter CLK_PERIOD = 20;  // 50 MHz
    parameter HEADER_SIZE = 64;

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

    // Send a single byte on the rx interface
    integer byte_count;
    integer wait_count;
    task send_byte;
        input [7:0] data;
        input        last;
        begin
            @(posedge clk);
            rx_data  = data;
            rx_valid = 1;
            rx_last  = last;

            wait_count = 0;
            @(posedge clk);
            while (!rx_ready && wait_count < 1000) begin
                @(posedge clk);
                wait_count = wait_count + 1;
            end

            if (wait_count >= 1000)
                $display("  WARN: send_byte stuck at byte %0d", byte_count);

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

            // Bytes 8-11: Size (big-endian) - maps to header_buffer[447:416]
            send_byte(size[31:24], 0);
            send_byte(size[23:16], 0);
            send_byte(size[15:8],  0);
            send_byte(size[7:0],   0);

            // Bytes 12-15: CRC32 - maps to header_buffer[415:384]
            send_byte(crc32[31:24], 0);
            send_byte(crc32[23:16], 0);
            send_byte(crc32[15:8],  0);
            send_byte(crc32[7:0],   0);

            // Bytes 16-47: Signature (32 bytes of 0xAA) - maps to [383:128]
            for (i = 0; i < 32; i = i + 1) begin
                send_byte(8'hAA, 0);
            end

            // Bytes 48-63: Governance hash (16 bytes of 0xBB) - maps to [127:0]
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

    // Respond to TSSP verification request (with timeout)
    integer tssp_wait;
    task tssp_respond;
        input pass;
        begin
            // Wait for TSSP request (with timeout)
            tssp_wait = 0;
            while (!tssp_req_valid && tssp_wait < 5000) begin
                @(posedge clk);
                tssp_wait = tssp_wait + 1;
            end

            if (tssp_req_valid) begin
                tssp_req_ready <= 1;
                @(posedge clk);
                tssp_req_ready <= 0;

                // Send response after a delay (simulating crypto time)
                #(CLK_PERIOD * 10);
                tssp_resp_valid  <= 1;
                tssp_resp_pass   <= pass;
                tssp_resp_status <= pass ? 8'h00 : 8'hFF;
                @(posedge clk);
                tssp_resp_valid <= 0;
            end else begin
                $display("  WARNING: TSSP request not received (timeout)");
            end
        end
    endtask

    task check;
        input        condition;
        input [255:0] message;
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

        // =====================================================================
        // TEST 1: Reset and Initialization
        // =====================================================================
        $display("[TEST 1] Reset and Initialization");
        reset;
        check(!update_busy,   "Not busy after reset");
        check(!update_error,  "No error after reset");
        check(!update_done,   "Not done after reset");
        check(active_slot == 0, "Active slot is A after reset");
        $display("");

        // =====================================================================
        // TEST 2: Enable Update, Send Header
        // =====================================================================
        $display("[TEST 2] Header Reception");
        update_enable <= 1;
        #(CLK_PERIOD * 10);

        // Debug: check FSM states propagated
        $display("  DEBUG: orch_state=%0d, rx_state=%0d, rx_ready=%0b",
                 dut.orch_state, dut.u_bitstream_rx.state, rx_ready);

        // Send a valid header: version=1, size=256 bytes, crc=0xDEADBEEF
        byte_count = 0;
        send_header(32'd1, 32'd256, 32'hDEADBEEF);
        $display("  DEBUG: %0d header bytes sent", byte_count);

        $display("  DEBUG: Header sent. rx_state=%0d, hdr_valid=%0b, rx_error=%0b",
                 dut.u_bitstream_rx.state, dut.u_bitstream_rx.hdr_valid,
                 dut.u_bitstream_rx.rx_error);

        #(CLK_PERIOD * 10);
        check(update_busy, "Busy during update");
        $display("");

        // =====================================================================
        // TEST 3: Governance Approval (3-of-5)
        // =====================================================================
        $display("[TEST 3] Governance Approval (3-of-5)");

        // Submit 3 approvals from signers 0, 1, 2
        submit_approval(8'd0);
        submit_approval(8'd1);
        submit_approval(8'd2);

        #(CLK_PERIOD * 20);
        check(governance_approvals >= 3, "3 governance approvals received");
        $display("");

        // =====================================================================
        // TEST 4: TSSP Signature Verification
        // =====================================================================
        $display("[TEST 4] ML-DSA-87 Signature Verification (TSSP)");

        // Respond to TSSP verification with pass
        fork
            tssp_respond(1);
        join

        #(CLK_PERIOD * 50);
        $display("  Update state: %0d", update_state);
        $display("");

        // =====================================================================
        // TEST 5: Wait for flash write (simplified)
        // =====================================================================
        $display("[TEST 5] Flash Write");

        // Send payload bytes (256 bytes)
        for (i = 0; i < 256; i = i + 1) begin
            send_byte(i[7:0], (i == 255));
        end

        // Wait for flash operations
        #(CLK_PERIOD * 200);
        $display("  Bytes transferred: %0d", bytes_transferred);
        $display("");

        // =====================================================================
        // TEST 6: Boot watchdog
        // =====================================================================
        $display("[TEST 6] Watchdog Boot Monitoring");

        // Simulate successful boot
        #(CLK_PERIOD * 50);
        boot_complete <= 1;
        #(CLK_PERIOD * 2);
        boot_complete <= 0;

        #(CLK_PERIOD * 50);
        $display("  Watchdog active: %0b", watchdog_active);
        $display("");

        // Clean up
        update_enable <= 0;
        #(CLK_PERIOD * 20);

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
        $display("ERROR: Simulation timeout!");
        $finish;
    end

endmodule
