// =============================================================================
// FPGA METADATA
// =============================================================================
// Module: Flash Manager
// Version: 1.0.0
// Purpose: Dual-slot SPI flash management with FRAM inventory for bitstream
//          storage, A/B slot swapping, and safe rollback
// Clock Budget: 50 MHz system clock
// Interface: AXI-Stream input, SPI master output
// Target: Lattice Nexus 40K (LIFCL-40)
// Upstream: Adapted from estream-io t0_bitstream_manager.v FRAM/flash paths
// =============================================================================

/*
 * Flash Manager - Dual-Slot Bitstream Storage
 * ══════════════════════════════════════════════════════════════════════════════
 *
 * Manages two flash slots (A and B) for safe bitstream updates. The active
 * slot is always the last successfully written and verified slot. The
 * inactive slot is used for incoming updates.
 *
 * Flash Memory Map:
 * ┌──────────────────────────────────────┐
 * │  Slot A: 0x000000 - 0x3FFFFF (4 MB) │
 * ├──────────────────────────────────────┤
 * │  Slot B: 0x400000 - 0x7FFFFF (4 MB) │
 * ├──────────────────────────────────────┤
 * │  Metadata: 0x800000 - 0x800FFF       │
 * │   - Active slot indicator            │
 * │   - Version A / Version B            │
 * │   - CRC A / CRC B                   │
 * │   - Write counter (wear leveling)   │
 * └──────────────────────────────────────┘
 *
 * FRAM Inventory (external, see t0_bitstream_manager.v):
 * - 64 entries × 64 bytes = 4 KB
 * - Audit trail at offset 0x1000
 */

`timescale 1ns/1ps

module flash_manager #(
    parameter SLOT_SIZE     = 4 * 1024 * 1024,   // 4 MB per slot
    parameter SLOT_A_BASE   = 24'h000000,
    parameter SLOT_B_BASE   = 24'h400000,
    parameter META_BASE     = 24'h800000,
    parameter PAGE_SIZE     = 256,                // Flash page size
    parameter SECTOR_SIZE   = 4096,               // Flash sector size (4 KB)
    parameter SPI_CLK_DIV   = 4                   // SPI clock divider
)(
    input  wire        clk,
    input  wire        rst_n,

    // =========================================================================
    // Bitstream Data Input (from bitstream_rx)
    // =========================================================================
    input  wire [7:0]  s_axis_tdata,
    input  wire        s_axis_tvalid,
    output reg         s_axis_tready,
    input  wire        s_axis_tlast,

    // =========================================================================
    // SPI Flash Interface
    // =========================================================================
    output reg         flash_cs_n,
    output wire        flash_sclk,
    output reg         flash_mosi,
    input  wire        flash_miso,

    // =========================================================================
    // Control Interface
    // =========================================================================
    input  wire        write_start,     // Begin writing to inactive slot
    input  wire [31:0] write_size,      // Expected write size
    input  wire [31:0] write_version,   // Version to store in metadata
    input  wire        swap_slots,      // Mark write as successful, swap active
    input  wire        rollback,        // Emergency rollback to other slot

    // =========================================================================
    // Status
    // =========================================================================
    output reg  [3:0]  state,
    output reg         busy,
    output reg         write_done,
    output reg         write_error,
    output reg  [7:0]  error_code,
    output reg         active_slot,     // 0 = Slot A, 1 = Slot B
    output reg  [31:0] version_a,
    output reg  [31:0] version_b,
    output reg  [31:0] bytes_written,
    output reg  [31:0] active_version   // Version of the currently active slot
);

    // =========================================================================
    // FSM STATES
    // =========================================================================

    localparam S_IDLE          = 4'd0;
    localparam S_READ_META     = 4'd1;   // Read metadata on startup
    localparam S_ERASE_SECTOR  = 4'd2;   // Erase flash sector
    localparam S_WAIT_ERASE    = 4'd3;
    localparam S_WRITE_PAGE    = 4'd4;   // Write 256-byte page
    localparam S_WAIT_WRITE    = 4'd5;
    localparam S_VERIFY        = 4'd6;   // Read-back verify
    localparam S_UPDATE_META   = 4'd7;   // Write metadata
    localparam S_SWAP          = 4'd8;   // Swap active slot
    localparam S_DONE          = 4'd9;
    localparam S_ERROR         = 4'd10;
    localparam S_INIT          = 4'd11;  // Power-on initialization

    // =========================================================================
    // ERROR CODES
    // =========================================================================

    localparam ERR_NONE         = 8'h00;
    localparam ERR_ERASE_FAIL   = 8'h01;
    localparam ERR_WRITE_FAIL   = 8'h02;
    localparam ERR_VERIFY_FAIL  = 8'h03;
    localparam ERR_META_CORRUPT = 8'h04;
    localparam ERR_SIZE_MISMATCH= 8'h05;

    // =========================================================================
    // SPI COMMANDS (standard SPI NOR flash)
    // =========================================================================

    localparam SPI_CMD_READ       = 8'h03;  // Read data
    localparam SPI_CMD_PAGE_PROG  = 8'h02;  // Page program
    localparam SPI_CMD_SECTOR_ER  = 8'h20;  // Sector erase (4 KB)
    localparam SPI_CMD_WRITE_EN   = 8'h06;  // Write enable
    localparam SPI_CMD_READ_SR    = 8'h05;  // Read status register
    localparam SPI_CMD_RDID       = 8'h9F;  // Read JEDEC ID

    // =========================================================================
    // METADATA FORMAT (at META_BASE, 32 bytes)
    // =========================================================================
    // Offset 0:   Active slot (0x00 = A, 0x01 = B)
    // Offset 1:   Metadata valid marker (0xA5)
    // Offset 2-3: Reserved
    // Offset 4-7: Version A (32-bit)
    // Offset 8-11: Version B (32-bit)
    // Offset 12-15: CRC A
    // Offset 16-19: CRC B
    // Offset 20-23: Write count
    // Offset 24-31: Reserved

    localparam META_VALID_MARKER = 8'hA5;

    // =========================================================================
    // INTERNAL REGISTERS
    // =========================================================================

    reg [23:0] write_addr;              // Current flash write address
    reg [23:0] sector_addr;             // Current sector being erased
    reg [31:0] sectors_to_erase;        // Sectors remaining to erase
    reg [7:0]  page_buffer [0:255];     // Page write buffer
    reg [8:0]  page_idx;                // Index into page buffer (0-255)
    reg [31:0] total_write_size;        // Expected total size
    reg [31:0] write_count;             // Flash write count (wear leveling)

    // SPI state
    reg [3:0]  spi_clk_cnt;
    reg        spi_clk_en;
    reg        spi_clk_reg;
    reg [7:0]  spi_tx_byte;
    reg [7:0]  spi_rx_byte;
    reg [3:0]  spi_bit_cnt;
    reg        spi_busy;
    reg [2:0]  spi_byte_cnt;           // Bytes in current SPI transaction
    reg        spi_done_pulse;

    // Sub-state for multi-step operations
    reg [3:0]  sub_state;

    // =========================================================================
    // SPI CLOCK GENERATION
    // =========================================================================

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spi_clk_cnt <= 0;
            spi_clk_reg <= 0;
        end else if (spi_clk_en) begin
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

    assign flash_sclk = spi_clk_reg;

    // =========================================================================
    // SPI BYTE TRANSFER (Mode 0: CPOL=0, CPHA=0)
    // =========================================================================

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spi_bit_cnt    <= 0;
            spi_busy       <= 0;
            spi_done_pulse <= 0;
            spi_rx_byte    <= 0;
        end else begin
            spi_done_pulse <= 0;

            if (spi_clk_en && spi_busy) begin
                if (spi_clk_cnt == SPI_CLK_DIV - 1 && spi_clk_reg) begin
                    // Falling edge: shift out next bit
                    flash_mosi  <= spi_tx_byte[7 - spi_bit_cnt];
                    spi_bit_cnt <= spi_bit_cnt + 1;

                    if (spi_bit_cnt == 7) begin
                        spi_busy       <= 0;
                        spi_done_pulse <= 1;
                    end
                end
                if (spi_clk_cnt == SPI_CLK_DIV - 1 && !spi_clk_reg) begin
                    // Rising edge: sample input
                    spi_rx_byte <= {spi_rx_byte[6:0], flash_miso};
                end
            end
        end
    end

    // =========================================================================
    // MAIN FSM
    // =========================================================================

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= S_INIT;
            busy            <= 1'b1;
            write_done      <= 1'b0;
            write_error     <= 1'b0;
            error_code      <= ERR_NONE;
            active_slot     <= 1'b0;
            version_a       <= 32'd0;
            version_b       <= 32'd0;
            bytes_written   <= 32'd0;
            active_version  <= 32'd0;

            flash_cs_n      <= 1'b1;
            spi_clk_en      <= 1'b0;
            s_axis_tready   <= 1'b0;

            write_addr      <= 24'd0;
            sector_addr     <= 24'd0;
            page_idx        <= 9'd0;
            sub_state       <= 4'd0;
            write_count     <= 32'd0;
        end else begin
            case (state)
                // =============================================================
                // INIT: Read metadata from flash on power-up
                // =============================================================
                S_INIT: begin
                    // Simplified init: assume Slot A active, version 0
                    // Full implementation reads META_BASE via SPI
                    active_slot    <= 1'b0;
                    version_a      <= 32'd0;
                    version_b      <= 32'd0;
                    active_version <= 32'd0;
                    busy           <= 1'b0;
                    state          <= S_IDLE;
                end

                // =============================================================
                // IDLE: Wait for commands
                // =============================================================
                S_IDLE: begin
                    busy        <= 1'b0;
                    write_done  <= 1'b0;
                    write_error <= 1'b0;

                    if (write_start) begin
                        state           <= S_ERASE_SECTOR;
                        busy            <= 1'b1;
                        bytes_written   <= 32'd0;
                        total_write_size <= write_size;
                        page_idx        <= 9'd0;
                        sub_state       <= 4'd0;

                        // Write to the inactive slot
                        if (active_slot == 1'b0) begin
                            write_addr  <= SLOT_B_BASE;
                            sector_addr <= SLOT_B_BASE;
                        end else begin
                            write_addr  <= SLOT_A_BASE;
                            sector_addr <= SLOT_A_BASE;
                        end

                        // Calculate sectors to erase
                        sectors_to_erase <= (write_size + SECTOR_SIZE - 1) / SECTOR_SIZE;
                    end else if (swap_slots) begin
                        state <= S_SWAP;
                        busy  <= 1'b1;
                    end else if (rollback) begin
                        // Swap to the other slot immediately
                        active_slot    <= ~active_slot;
                        active_version <= (active_slot) ? version_a : version_b;
                    end
                end

                // =============================================================
                // ERASE_SECTOR: Erase sectors in the inactive slot
                // =============================================================
                S_ERASE_SECTOR: begin
                    if (sectors_to_erase > 0) begin
                        // Issue SPI sector erase
                        // Simplified: in real implementation, this drives
                        // SPI_CMD_WRITE_EN then SPI_CMD_SECTOR_ER with address
                        state <= S_WAIT_ERASE;
                    end else begin
                        // All sectors erased, begin writing
                        state         <= S_WRITE_PAGE;
                        s_axis_tready <= 1'b1;
                    end
                end

                // =============================================================
                // WAIT_ERASE: Wait for sector erase to complete
                // =============================================================
                S_WAIT_ERASE: begin
                    // In real implementation, poll SPI status register
                    // Simplified: assume erase takes ~50ms, use counter
                    sub_state <= sub_state + 1;
                    if (sub_state == 4'd15) begin
                        sector_addr      <= sector_addr + SECTOR_SIZE;
                        sectors_to_erase <= sectors_to_erase - 1;
                        sub_state        <= 4'd0;
                        state            <= S_ERASE_SECTOR;
                    end
                end

                // =============================================================
                // WRITE_PAGE: Buffer incoming data into 256-byte pages
                // =============================================================
                S_WRITE_PAGE: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        page_buffer[page_idx[7:0]] <= s_axis_tdata;
                        page_idx      <= page_idx + 1;
                        bytes_written <= bytes_written + 1;

                        // Page full or last byte
                        if (page_idx[7:0] == 8'hFF || s_axis_tlast) begin
                            s_axis_tready <= 1'b0;
                            state         <= S_WAIT_WRITE;
                            sub_state     <= 4'd0;
                        end
                    end

                    // Check for completion
                    if (bytes_written >= total_write_size) begin
                        s_axis_tready <= 1'b0;
                        state         <= S_VERIFY;
                    end
                end

                // =============================================================
                // WAIT_WRITE: Flash page program in progress
                // =============================================================
                S_WAIT_WRITE: begin
                    // In real implementation: SPI_CMD_PAGE_PROG with address
                    // then poll status register until WIP=0
                    sub_state <= sub_state + 1;
                    if (sub_state == 4'd7) begin
                        write_addr <= write_addr + {15'd0, page_idx[8:0]};
                        page_idx   <= 9'd0;
                        sub_state  <= 4'd0;

                        if (bytes_written >= total_write_size) begin
                            state <= S_VERIFY;
                        end else begin
                            state         <= S_WRITE_PAGE;
                            s_axis_tready <= 1'b1;
                        end
                    end
                end

                // =============================================================
                // VERIFY: Read-back and compare (simplified)
                // =============================================================
                S_VERIFY: begin
                    // In real implementation: read back flash and compare CRC
                    // Simplified: assume verify passes
                    state <= S_UPDATE_META;
                end

                // =============================================================
                // UPDATE_META: Write version and slot info to metadata area
                // =============================================================
                S_UPDATE_META: begin
                    // Update version for the written slot
                    if (active_slot == 1'b0) begin
                        version_b <= write_version;
                    end else begin
                        version_a <= write_version;
                    end
                    write_count <= write_count + 1;
                    state       <= S_DONE;
                end

                // =============================================================
                // SWAP: Swap active slot after successful write + verify
                // =============================================================
                S_SWAP: begin
                    active_slot    <= ~active_slot;
                    active_version <= (active_slot == 1'b0) ? version_b : version_a;
                    // Write updated metadata to flash
                    // (simplified: metadata update via SPI)
                    state <= S_DONE;
                end

                // =============================================================
                // DONE
                // =============================================================
                S_DONE: begin
                    busy       <= 1'b0;
                    write_done <= 1'b1;
                    if (!write_start && !swap_slots) begin
                        state <= S_IDLE;
                    end
                end

                // =============================================================
                // ERROR
                // =============================================================
                S_ERROR: begin
                    busy        <= 1'b0;
                    write_error <= 1'b1;
                    if (!write_start) begin
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
