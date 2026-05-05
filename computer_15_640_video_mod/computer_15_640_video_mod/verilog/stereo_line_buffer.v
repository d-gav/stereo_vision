// =============================================================================
// stereo_line_buffer
//
// Replacement for stereo_bram_bank in the disparity-parallel architecture.
// Stores only BLOCK_SIZE rows of the full-width image (left 0..319 + right
// 320..639) instead of the entire frame. Uses BLOCK_SIZE independent M10K
// BRAMs, one per row slot, so a full BLOCK_SIZE-pixel column can be read
// in a single cycle (all row-BRAMs share the same read address and return
// their pixel simultaneously).
//
// Memory cost: BLOCK_SIZE BRAMs × 640 entries × 8 bits ≈ 5 M10Ks (vs. 134
// for the old 67-stripe bank). Left and right cameras share the same BRAMs
// (left at cols 0..319, right at 320..639), matching the legacy layout that
// fill_pipe_controller already produces.
//
// Write port: one pixel per cycle, addressed by (row_slot, col).
//   row_slot = y % BLOCK_SIZE (caller computes this).
//   col      = 0..FULL_ROW_WIDTH-1.
//
// Read port: given rd_col, returns BLOCK_SIZE pixels (one per row slot)
//   in a single cycle (1-cycle BRAM read latency). The ordering in
//   rd_data_col[0..BLOCK_SIZE-1] corresponds to row_slot 0..BLOCK_SIZE-1.
//   The consumer is responsible for circular re-ordering if needed.
// =============================================================================

module stereo_line_buffer #(
    parameter integer BLOCK_SIZE      = 5,
    parameter integer FULL_ROW_WIDTH  = 640,
    parameter integer PIXEL_W         = 8,
    parameter integer SLOT_W          = (BLOCK_SIZE <= 1) ? 1 : $clog2(BLOCK_SIZE),
    parameter integer COL_W           = $clog2(FULL_ROW_WIDTH)
)(
    input  wire                    clk,

    // Write port: one pixel per cycle
    input  wire                    wr_en,
    input  wire [SLOT_W-1:0]       wr_row_slot,   // which row-BRAM to write
    input  wire [COL_W-1:0]        wr_col,
    input  wire [PIXEL_W-1:0]      wr_data,

    // Read port: full column in 1 cycle (1-cycle BRAM latency)
    input  wire [COL_W-1:0]        rd_col,
    output wire [BLOCK_SIZE*PIXEL_W-1:0] rd_data_flat  // packed: slot0 at [PIXEL_W-1:0]
);

    genvar s;
    generate
        for (s = 0; s < BLOCK_SIZE; s = s + 1) begin : GEN_ROW_BRAM
            wire              slot_wr_en;
            wire [PIXEL_W-1:0] slot_rd_data;

            // Only enable writes to the addressed row slot
            assign slot_wr_en = wr_en && (wr_row_slot == s);

            stereo_stripe_bram #(
                .DATA_W(PIXEL_W),
                .DEPTH (FULL_ROW_WIDTH)
            ) u_row_bram (
                .clk    (clk),
                .wr_en  (slot_wr_en),
                .wr_addr(wr_col),
                .wr_data(wr_data),
                .rd_addr(rd_col),
                .rd_data(slot_rd_data)
            );

            assign rd_data_flat[s*PIXEL_W +: PIXEL_W] = slot_rd_data;
        end
    endgenerate

endmodule
