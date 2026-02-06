// =============================================================================
// FPGA METADATA
// =============================================================================
// Module: ML-DSA-87 Signature Verification Interface
// Version: 1.0.0
// Purpose: Interface to ML-DSA-87 post-quantum signature verification
// Clock Budget: Variable (verification takes ~100ms on crypto coprocessor)
// Interface: Command/status with message hash and signature inputs
// Target: Lattice Nexus 40K (LIFCL-40)
// Upstream: Uses estream-io prime_signer.v crypto interface pattern
// =============================================================================

/*
 * ML-DSA-87 Verification Interface
 * ══════════════════════════════════════════════════════════════════════════════
 *
 * ML-DSA-87 (FIPS 204) is too computationally intensive for full hardware
 * implementation on Nexus 40K. This module provides the interface to an
 * external crypto coprocessor (via SPI) or to the estream Node's T0 PRIME
 * module for signature verification.
 *
 * In docked mode (connected to estream Node):
 *   - Verification delegated to T0 PRIME via TSSP protocol
 *   - Signature verified against PRIME key hierarchy
 *
 * In standalone mode (field update via serial):
 *   - Verification via on-board crypto coprocessor (SPI)
 *   - Public key stored in eFuse / OTP
 *
 * ML-DSA-87 Parameters:
 *   - Public key:  2592 bytes
 *   - Signature:   4627 bytes
 *   - Security:    NIST Level 5 (256-bit classical, 128-bit quantum)
 */

`timescale 1ns/1ps

module ml_dsa87_verify #(
    parameter SIGNATURE_BYTES  = 4627,      // ML-DSA-87 signature size
    parameter PUBKEY_BYTES     = 2592,      // ML-DSA-87 public key size
    parameter MSG_HASH_BITS    = 256,       // SHA3-256 message hash
    parameter SPI_CLK_DIV      = 8,         // SPI clock divider for crypto chip
    parameter VERIFY_TIMEOUT   = 250_000_000 // 5 seconds at 50 MHz
)(
    input  wire        clk,
    input  wire        rst_n,

    // =========================================================================
    // Verification Request
    // =========================================================================
    input  wire              verify_start,
    input  wire [MSG_HASH_BITS-1:0] msg_hash,    // SHA3-256 of bitstream
    output reg               verify_done,
    output reg               verify_pass,         // 1 = signature valid
    output reg               verify_error,

    // =========================================================================
    // Signature Input (streamed in 8-bit chunks)
    // =========================================================================
    input  wire [7:0]        sig_data,
    input  wire              sig_valid,
    output reg               sig_ready,
    input  wire              sig_last,

    // =========================================================================
    // Public Key Source Select
    // =========================================================================
    input  wire              use_tssp,      // 1 = use TSSP (docked), 0 = local
    input  wire [7:0]        key_slot,      // Key slot in OTP/eFuse

    // =========================================================================
    // TSSP Interface (to estream Node T0 PRIME)
    // =========================================================================
    output reg               tssp_req_valid,
    output reg  [7:0]        tssp_req_cmd,
    output reg  [255:0]      tssp_req_hash,
    input  wire              tssp_req_ready,
    input  wire              tssp_resp_valid,
    input  wire              tssp_resp_pass,
    input  wire [7:0]        tssp_resp_status,

    // =========================================================================
    // SPI Crypto Coprocessor Interface (standalone mode)
    // =========================================================================
    output reg               crypto_cs_n,
    output wire              crypto_sclk,
    output reg               crypto_mosi,
    input  wire              crypto_miso,

    // =========================================================================
    // Status
    // =========================================================================
    output reg  [3:0]        state,
    output reg               busy
);

    // =========================================================================
    // FSM STATES
    // =========================================================================

    localparam S_IDLE          = 4'd0;
    localparam S_LOAD_SIG      = 4'd1;   // Buffer incoming signature
    localparam S_SEND_TSSP     = 4'd2;   // Send to T0 PRIME via TSSP
    localparam S_WAIT_TSSP     = 4'd3;   // Wait for TSSP response
    localparam S_SEND_CRYPTO   = 4'd4;   // Send to crypto coprocessor
    localparam S_WAIT_CRYPTO   = 4'd5;   // Wait for crypto response
    localparam S_DONE          = 4'd6;
    localparam S_ERROR         = 4'd7;

    // TSSP command codes
    localparam TSSP_CMD_VERIFY = 8'h10;  // Verify signature

    // =========================================================================
    // INTERNAL REGISTERS
    // =========================================================================

    reg [31:0]  sig_byte_cnt;
    reg [31:0]  timeout_cnt;
    reg         sig_complete;

    // SPI clock for crypto coprocessor
    reg [3:0]  spi_clk_cnt;
    reg        spi_clk_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spi_clk_cnt <= 0;
            spi_clk_reg <= 0;
        end else if (!crypto_cs_n) begin
            if (spi_clk_cnt == SPI_CLK_DIV - 1) begin
                spi_clk_cnt <= 0;
                spi_clk_reg <= ~spi_clk_reg;
            end else begin
                spi_clk_cnt <= spi_clk_cnt + 1;
            end
        end else begin
            spi_clk_cnt <= 0;
            spi_clk_reg <= 0;
        end
    end

    assign crypto_sclk = spi_clk_reg;

    // =========================================================================
    // MAIN FSM
    // =========================================================================

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= S_IDLE;
            verify_done    <= 1'b0;
            verify_pass    <= 1'b0;
            verify_error   <= 1'b0;
            sig_ready      <= 1'b0;
            busy           <= 1'b0;

            tssp_req_valid <= 1'b0;
            tssp_req_cmd   <= 8'd0;
            tssp_req_hash  <= 256'd0;

            crypto_cs_n    <= 1'b1;
            crypto_mosi    <= 1'b0;

            sig_byte_cnt   <= 32'd0;
            timeout_cnt    <= 32'd0;
            sig_complete   <= 1'b0;
        end else begin
            // Default de-assertions
            tssp_req_valid <= tssp_req_valid && !tssp_req_ready;

            case (state)
                // =============================================================
                // IDLE
                // =============================================================
                S_IDLE: begin
                    verify_done  <= 1'b0;
                    verify_pass  <= 1'b0;
                    verify_error <= 1'b0;
                    busy         <= 1'b0;

                    if (verify_start) begin
                        busy         <= 1'b1;
                        timeout_cnt  <= 32'd0;

                        // Two modes:
                        // 1. Streamed signature (sig_valid asserted on same
                        //    cycle as verify_start) → buffer via S_LOAD_SIG
                        // 2. Hash-only mode (Phase 1): signature hash already
                        //    in msg_hash from the header → skip straight to
                        //    verification backend
                        if (sig_valid) begin
                            state        <= S_LOAD_SIG;
                            sig_ready    <= 1'b1;
                            sig_byte_cnt <= 32'd0;
                            sig_complete <= 1'b0;
                        end else begin
                            sig_complete <= 1'b1;
                            if (use_tssp) begin
                                state <= S_SEND_TSSP;
                            end else begin
                                state <= S_SEND_CRYPTO;
                            end
                        end
                    end
                end

                // =============================================================
                // LOAD_SIG: Buffer the incoming signature stream
                // =============================================================
                S_LOAD_SIG: begin
                    if (sig_valid && sig_ready) begin
                        sig_byte_cnt <= sig_byte_cnt + 1;

                        // In real implementation: buffer to BRAM or stream to
                        // crypto coprocessor. Here we count bytes and wait for
                        // the complete signature.
                        if (sig_last || sig_byte_cnt >= SIGNATURE_BYTES - 1) begin
                            sig_ready    <= 1'b0;
                            sig_complete <= 1'b1;

                            if (use_tssp) begin
                                state <= S_SEND_TSSP;
                            end else begin
                                state <= S_SEND_CRYPTO;
                            end
                        end
                    end

                    // Timeout
                    timeout_cnt <= timeout_cnt + 1;
                    if (timeout_cnt >= VERIFY_TIMEOUT) begin
                        state <= S_ERROR;
                    end
                end

                // =============================================================
                // SEND_TSSP: Delegate verification to T0 PRIME
                // =============================================================
                S_SEND_TSSP: begin
                    tssp_req_valid <= 1'b1;
                    tssp_req_cmd   <= TSSP_CMD_VERIFY;
                    tssp_req_hash  <= msg_hash;

                    if (tssp_req_ready) begin
                        tssp_req_valid <= 1'b0;
                        state          <= S_WAIT_TSSP;
                        timeout_cnt    <= 32'd0;
                    end
                end

                // =============================================================
                // WAIT_TSSP: Wait for T0 PRIME verification result
                // =============================================================
                S_WAIT_TSSP: begin
                    timeout_cnt <= timeout_cnt + 1;

                    if (tssp_resp_valid) begin
                        verify_pass <= tssp_resp_pass;
                        state       <= S_DONE;
                    end else if (timeout_cnt >= VERIFY_TIMEOUT) begin
                        state <= S_ERROR;
                    end
                end

                // =============================================================
                // SEND_CRYPTO: Send to local crypto coprocessor (standalone)
                // =============================================================
                S_SEND_CRYPTO: begin
                    // In real implementation: drive SPI to crypto coprocessor
                    // with message hash, signature, and key slot
                    crypto_cs_n <= 1'b0;
                    state       <= S_WAIT_CRYPTO;
                    timeout_cnt <= 32'd0;
                end

                // =============================================================
                // WAIT_CRYPTO: Wait for crypto coprocessor result
                // =============================================================
                S_WAIT_CRYPTO: begin
                    timeout_cnt <= timeout_cnt + 1;

                    // In real implementation: poll crypto coprocessor status
                    // Simplified: simulate verification time
                    if (timeout_cnt >= 32'd5_000_000) begin
                        // ~100ms verification time
                        crypto_cs_n <= 1'b1;
                        verify_pass <= 1'b1;  // Placeholder
                        state       <= S_DONE;
                    end else if (timeout_cnt >= VERIFY_TIMEOUT) begin
                        crypto_cs_n <= 1'b1;
                        state       <= S_ERROR;
                    end
                end

                // =============================================================
                // DONE
                // =============================================================
                S_DONE: begin
                    verify_done <= 1'b1;
                    busy        <= 1'b0;
                    if (!verify_start) begin
                        state <= S_IDLE;
                    end
                end

                // =============================================================
                // ERROR
                // =============================================================
                S_ERROR: begin
                    verify_error <= 1'b1;
                    busy         <= 1'b0;
                    crypto_cs_n  <= 1'b1;
                    if (!verify_start) begin
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
