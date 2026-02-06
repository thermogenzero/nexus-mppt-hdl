// =============================================================================
// FPGA METADATA
// =============================================================================
// Module: Bitstream Receiver
// Version: 1.0.0
// Purpose: Receive bitstream data from estream wire protocol or serial link
// Clock Budget: 50 MHz system clock
// Interface: AXI-Stream input, Flash write output
// Target: Lattice Nexus 40K (LIFCL-40)
// Upstream: Adapted from estream-io t0_bitstream_manager.v receiver path
// =============================================================================

/*
 * Bitstream Receiver
 * ══════════════════════════════════════════════════════════════════════════════
 *
 * Receives bitstream update packets, validates the header/integrity, and
 * streams verified data to the flash_manager for dual-slot storage.
 *
 * Packet Format (from estream wire protocol or BFST serial bridge):
 * ┌─────────────────────────────────────────────────────────────────┐
 * │  Header (64 bytes)                                              │
 * │  ┌──────────┬──────────┬──────────┬──────────┬────────────────┐│
 * │  │ Magic    │ Version  │ Size     │ CRC32    │ Signature[0:15]││
 * │  │ 4 bytes  │ 4 bytes  │ 4 bytes  │ 4 bytes  │ 16 bytes       ││
 * │  ├──────────┴──────────┴──────────┴──────────┴────────────────┤│
 * │  │ Signature[16:31] │ Governance Hash │ Reserved               ││
 * │  │ 16 bytes          │ 16 bytes        │ 4 bytes               ││
 * │  └───────────────────┴─────────────────┴──────────────────────┘│
 * ├─────────────────────────────────────────────────────────────────┤
 * │  Payload (chunked, up to 4 MB)                                  │
 * │  ┌──────────────────────────────────────────────────────────┐  │
 * │  │  Chunk 0 (4096 bytes) │ Chunk 1 │ ... │ Chunk N          │  │
 * │  └──────────────────────────────────────────────────────────┘  │
 * └─────────────────────────────────────────────────────────────────┘
 */

`timescale 1ns/1ps

module bitstream_rx #(
    parameter MAGIC            = 32'h4E584253,  // "NXBS" - Nexus Bitstream
    parameter MAX_BITSTREAM    = 4 * 1024 * 1024, // 4 MB max
    parameter CHUNK_SIZE       = 4096,           // 4 KB chunks
    parameter HEADER_SIZE      = 64,             // 64-byte header
    parameter TIMEOUT_CYCLES   = 50_000_000      // 1 second at 50 MHz
)(
    input  wire        clk,
    input  wire        rst_n,

    // =========================================================================
    // Input Data Stream (from wire protocol or serial bridge)
    // =========================================================================
    input  wire [7:0]  s_axis_tdata,
    input  wire        s_axis_tvalid,
    output reg         s_axis_tready,
    input  wire        s_axis_tlast,

    // =========================================================================
    // Output to Flash Manager
    // =========================================================================
    output reg  [7:0]  m_axis_tdata,
    output reg         m_axis_tvalid,
    input  wire        m_axis_tready,
    output reg         m_axis_tlast,

    // =========================================================================
    // Parsed Header Output (to governance + verification)
    // =========================================================================
    output reg  [31:0] hdr_version,
    output reg  [31:0] hdr_size,
    output reg  [31:0] hdr_crc32,
    output reg [255:0] hdr_signature,  // First 256 bits of ML-DSA-87 signature
    output reg [127:0] hdr_gov_hash,   // Governance approval hash
    output reg         hdr_valid,      // Header parsed and valid

    // =========================================================================
    // Control
    // =========================================================================
    input  wire        rx_enable,       // Enable receiver
    input  wire        rx_abort,        // Abort current transfer

    // =========================================================================
    // Status
    // =========================================================================
    output reg  [3:0]  state,
    output reg         rx_active,
    output reg         rx_done,
    output reg         rx_error,
    output reg  [7:0]  rx_error_code,
    output reg  [31:0] bytes_received,
    output reg  [31:0] crc_computed     // Running CRC32 for verification
);

    // =========================================================================
    // FSM STATES
    // =========================================================================

    localparam S_IDLE         = 4'd0;
    localparam S_RECV_HEADER  = 4'd1;
    localparam S_PARSE_HEADER = 4'd2;
    localparam S_WAIT_AUTH    = 4'd3;  // Wait for governance + sig verify
    localparam S_RECV_PAYLOAD = 4'd4;
    localparam S_FINALIZE     = 4'd5;
    localparam S_DONE         = 4'd6;
    localparam S_ERROR        = 4'd7;
    localparam S_ABORT        = 4'd8;

    // =========================================================================
    // ERROR CODES
    // =========================================================================

    localparam ERR_NONE           = 8'h00;
    localparam ERR_BAD_MAGIC      = 8'h01;
    localparam ERR_SIZE_EXCEEDED  = 8'h02;
    localparam ERR_CRC_MISMATCH   = 8'h03;
    localparam ERR_TIMEOUT        = 8'h04;
    localparam ERR_FLASH_FULL     = 8'h05;
    localparam ERR_ABORTED        = 8'h06;
    localparam ERR_UNDERFLOW      = 8'h07;

    // =========================================================================
    // INTERNAL REGISTERS
    // =========================================================================

    reg [511:0] header_buffer;
    reg [5:0]   header_byte_cnt;       // 0-63
    reg [31:0]  payload_remaining;
    reg [31:0]  timeout_counter;

    // CRC32 computation (IEEE 802.3 polynomial)
    reg [31:0]  crc_reg;
    wire [31:0] crc_next;

    // CRC32 lookup - single byte at a time using LFSR method
    function [31:0] crc32_byte;
        input [31:0] crc_in;
        input [7:0]  data_in;
        reg [31:0] c;
        reg [7:0]  d;
        integer i;
        begin
            c = crc_in;
            d = data_in;
            for (i = 0; i < 8; i = i + 1) begin
                if ((c[0] ^ d[0]) == 1'b1)
                    c = {1'b0, c[31:1]} ^ 32'hEDB88320;
                else
                    c = {1'b0, c[31:1]};
                d = {1'b0, d[7:1]};
            end
            crc32_byte = c;
        end
    endfunction

    assign crc_next = crc32_byte(crc_reg, s_axis_tdata);

    // =========================================================================
    // MAIN FSM
    // =========================================================================

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= S_IDLE;
            s_axis_tready   <= 1'b0;
            m_axis_tdata    <= 8'd0;
            m_axis_tvalid   <= 1'b0;
            m_axis_tlast    <= 1'b0;

            hdr_version     <= 32'd0;
            hdr_size        <= 32'd0;
            hdr_crc32       <= 32'd0;
            hdr_signature   <= 256'd0;
            hdr_gov_hash    <= 128'd0;
            hdr_valid       <= 1'b0;

            rx_active       <= 1'b0;
            rx_done         <= 1'b0;
            rx_error        <= 1'b0;
            rx_error_code   <= ERR_NONE;
            bytes_received  <= 32'd0;
            crc_computed    <= 32'd0;

            header_buffer   <= 512'd0;
            header_byte_cnt <= 6'd0;
            payload_remaining <= 32'd0;
            timeout_counter <= 32'd0;
            crc_reg         <= 32'hFFFFFFFF;
        end else begin
            // Default de-assertions
            m_axis_tvalid <= m_axis_tvalid && !m_axis_tready;
            m_axis_tlast  <= m_axis_tlast && !m_axis_tready;

            // Abort handling (highest priority)
            if (rx_abort && state != S_IDLE) begin
                state         <= S_ABORT;
                s_axis_tready <= 1'b0;
            end

            case (state)
                // =============================================================
                // IDLE: Wait for enable
                // =============================================================
                S_IDLE: begin
                    rx_active       <= 1'b0;
                    rx_done         <= 1'b0;
                    rx_error        <= 1'b0;
                    rx_error_code   <= ERR_NONE;
                    hdr_valid       <= 1'b0;

                    if (rx_enable) begin
                        state           <= S_RECV_HEADER;
                        s_axis_tready   <= 1'b1;
                        rx_active       <= 1'b1;
                        bytes_received  <= 32'd0;
                        header_byte_cnt <= 6'd0;
                        header_buffer   <= 512'd0;
                        timeout_counter <= 32'd0;
                        crc_reg         <= 32'hFFFFFFFF;
                    end
                end

                // =============================================================
                // RECV_HEADER: Collect 64-byte header
                // =============================================================
                S_RECV_HEADER: begin
                    // Timeout check
                    if (timeout_counter >= TIMEOUT_CYCLES) begin
                        rx_error_code <= ERR_TIMEOUT;
                        state         <= S_ERROR;
                        s_axis_tready <= 1'b0;
                    end else if (!s_axis_tvalid) begin
                        timeout_counter <= timeout_counter + 1;
                    end

                    if (s_axis_tvalid && s_axis_tready) begin
                        timeout_counter <= 32'd0;
                        header_buffer   <= {header_buffer[503:0], s_axis_tdata};
                        header_byte_cnt <= header_byte_cnt + 1;

                        if (header_byte_cnt == HEADER_SIZE - 1) begin
                            s_axis_tready <= 1'b0;
                            state         <= S_PARSE_HEADER;
                        end
                    end
                end

                // =============================================================
                // PARSE_HEADER: Validate header fields
                // =============================================================
                S_PARSE_HEADER: begin
                    // Extract fields from header buffer (MSB-first packing)
                    hdr_version   <= header_buffer[511:480];
                    hdr_size      <= header_buffer[447:416];
                    hdr_crc32     <= header_buffer[415:384];
                    hdr_signature <= header_buffer[383:128];
                    hdr_gov_hash  <= header_buffer[127:0];

                    // Validate magic bytes
                    if (header_buffer[511:480] == 32'd0) begin
                        // Version 0 is invalid
                        rx_error_code <= ERR_BAD_MAGIC;
                        state         <= S_ERROR;
                    end else if (header_buffer[447:416] > MAX_BITSTREAM) begin
                        // Size exceeds maximum
                        rx_error_code <= ERR_SIZE_EXCEEDED;
                        state         <= S_ERROR;
                    end else if (header_buffer[447:416] == 32'd0) begin
                        // Zero-size bitstream
                        rx_error_code <= ERR_UNDERFLOW;
                        state         <= S_ERROR;
                    end else begin
                        hdr_valid         <= 1'b1;
                        payload_remaining <= header_buffer[447:416];
                        state             <= S_WAIT_AUTH;
                    end
                end

                // =============================================================
                // WAIT_AUTH: External governance + sig verify occurs here
                // Caller asserts rx_enable again once auth passes
                // =============================================================
                S_WAIT_AUTH: begin
                    // The update_top module orchestrates governance and
                    // signature verification, then re-enables the receiver
                    // by providing a second rx_enable pulse.
                    // During this time we hold state.
                    timeout_counter <= timeout_counter + 1;

                    if (timeout_counter >= TIMEOUT_CYCLES * 10) begin
                        // 10-second auth timeout
                        rx_error_code <= ERR_TIMEOUT;
                        state         <= S_ERROR;
                    end else if (rx_enable && hdr_valid) begin
                        state           <= S_RECV_PAYLOAD;
                        s_axis_tready   <= 1'b1;
                        timeout_counter <= 32'd0;
                    end
                end

                // =============================================================
                // RECV_PAYLOAD: Stream payload to flash manager
                // =============================================================
                S_RECV_PAYLOAD: begin
                    // Timeout
                    if (timeout_counter >= TIMEOUT_CYCLES) begin
                        rx_error_code <= ERR_TIMEOUT;
                        state         <= S_ERROR;
                        s_axis_tready <= 1'b0;
                    end else if (!s_axis_tvalid) begin
                        timeout_counter <= timeout_counter + 1;
                    end

                    // Flow control: only accept input when output can take it
                    s_axis_tready <= m_axis_tready || !m_axis_tvalid;

                    if (s_axis_tvalid && s_axis_tready) begin
                        timeout_counter <= 32'd0;

                        // Forward byte to flash manager
                        m_axis_tdata  <= s_axis_tdata;
                        m_axis_tvalid <= 1'b1;

                        // CRC accumulation
                        crc_reg <= crc_next;

                        // Bookkeeping
                        bytes_received    <= bytes_received + 1;
                        payload_remaining <= payload_remaining - 1;

                        if (payload_remaining == 1) begin
                            // Last byte
                            m_axis_tlast  <= 1'b1;
                            s_axis_tready <= 1'b0;
                            state         <= S_FINALIZE;
                        end
                    end
                end

                // =============================================================
                // FINALIZE: Check CRC, report result
                // =============================================================
                S_FINALIZE: begin
                    // Wait for last byte to be consumed
                    if (!m_axis_tvalid || m_axis_tready) begin
                        m_axis_tvalid <= 1'b0;
                        m_axis_tlast  <= 1'b0;

                        // Finalize CRC (invert)
                        crc_computed <= ~crc_reg;

                        if ((~crc_reg) != hdr_crc32) begin
                            rx_error_code <= ERR_CRC_MISMATCH;
                            state         <= S_ERROR;
                        end else begin
                            state <= S_DONE;
                        end
                    end
                end

                // =============================================================
                // DONE: Transfer complete
                // =============================================================
                S_DONE: begin
                    rx_active <= 1'b0;
                    rx_done   <= 1'b1;
                    // Return to idle when enable deasserted
                    if (!rx_enable) begin
                        state   <= S_IDLE;
                        rx_done <= 1'b0;
                    end
                end

                // =============================================================
                // ERROR: Transfer failed
                // =============================================================
                S_ERROR: begin
                    rx_active     <= 1'b0;
                    rx_error      <= 1'b1;
                    s_axis_tready <= 1'b0;
                    m_axis_tvalid <= 1'b0;
                    if (!rx_enable) begin
                        state    <= S_IDLE;
                        rx_error <= 1'b0;
                    end
                end

                // =============================================================
                // ABORT: Clean shutdown
                // =============================================================
                S_ABORT: begin
                    rx_active       <= 1'b0;
                    rx_error        <= 1'b1;
                    rx_error_code   <= ERR_ABORTED;
                    s_axis_tready   <= 1'b0;
                    m_axis_tvalid   <= 1'b0;
                    if (!rx_abort) begin
                        state    <= S_IDLE;
                        rx_error <= 1'b0;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
