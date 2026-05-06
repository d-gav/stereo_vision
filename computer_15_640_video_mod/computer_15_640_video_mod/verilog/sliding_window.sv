// =============================================================================
// sliding_window
//
// Holds a BLOCK_SIZE x BLOCK_SIZE window of pixels and shifts left by one
// column whenever valid_in is asserted, inserting the incoming column on
// the right.
//
// Timing semantics:
//   T   (valid_in=1, pixel_in = NEW_COL): block_out shows the PRE-slide
//       window (last BLOCK_SIZE columns up to and including the previously-
//       loaded one). The NEW_COL is registered at the T -> T+1 edge.
//   T+1 (valid_in=0):                     block_out shows the POST-slide
//       window with NEW_COL on the right and the oldest column dropped.
//       Stable until the next slide.
//
// This matches the consumer's expectation in mem_block_intf_d.v, where
// sad_compare_en is the registered version of slide_matching (one-cycle
// delay) and best_sad/best_disp update on the cycle AFTER the slide -- by
// which point block_out reflects the freshly-loaded window.
//
// Earlier revision stored only BLOCK_SIZE-1 columns and fed pixel_in
// combinationally as the rightmost column when valid_in=1. That made
// block_out correct ONLY on the slide cycle itself; one cycle later, the
// window had shifted left and the rightmost column was a duplicate of its
// neighbor. SAD was then captured against this corrupted window. This
// version stores all BLOCK_SIZE columns so the post-slide window is
// stable.
// =============================================================================

module sliding_window #(
    parameter int BLOCK_SIZE = 5,
    parameter int PIXEL_W    = 8
)(
    input clk,
    input rst,
    input valid_in,
    input  logic [BLOCK_SIZE*PIXEL_W-1:0] pixel_in_col_flat,
    output logic [PIXEL_W-1:0] block_out [0:BLOCK_SIZE-1][0:BLOCK_SIZE-1],
    output logic [BLOCK_SIZE*BLOCK_SIZE*PIXEL_W-1:0] block_out_flat
);

    int row;
    int col;

    // Full window storage: BLOCK_SIZE columns x BLOCK_SIZE rows.
    logic [PIXEL_W-1:0] shift_reg [0:BLOCK_SIZE-1][0:BLOCK_SIZE-1];

    function automatic logic [PIXEL_W-1:0] col_px(
        input logic [BLOCK_SIZE*PIXEL_W-1:0] col_flat,
        input int r
    );
        int idx;
        begin
            idx = r * PIXEL_W;
            col_px = col_flat[idx +: PIXEL_W];
        end
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            for (row = 0; row < BLOCK_SIZE; row++) begin
                for (col = 0; col < BLOCK_SIZE; col++) begin
                    shift_reg[row][col] <= '0;
                end
            end
        end else if (valid_in) begin
            // Shift all stored columns left by one and load the new column
            // into the rightmost position. Window stays stable until the
            // next valid_in pulse.
            for (row = 0; row < BLOCK_SIZE; row++) begin
                for (col = 0; col < BLOCK_SIZE - 1; col++) begin
                    shift_reg[row][col] <= shift_reg[row][col + 1];
                end
                shift_reg[row][BLOCK_SIZE - 1] <= col_px(pixel_in_col_flat, row);
            end
        end
    end

    // block_out is purely the registered window. No combinational path
    // through pixel_in_col_flat -- that's what produced the duplicate-
    // column bug in the previous revision.
    always_comb begin
        for (row = 0; row < BLOCK_SIZE; row++) begin
            for (col = 0; col < BLOCK_SIZE; col++) begin
                block_out[row][col] = shift_reg[row][col];
            end
        end
    end

    genvar gi;
    generate
        for (gi = 0; gi < BLOCK_SIZE; gi++) begin : GEN_DBG_BLOCK_ROW
            genvar gj;
            for (gj = 0; gj < BLOCK_SIZE; gj++) begin : GEN_DBG_BLOCK_COL
                localparam int FLAT_IDX = ((gi * BLOCK_SIZE) + gj) * PIXEL_W;
                assign block_out_flat[FLAT_IDX +: PIXEL_W] = block_out[gi][gj];
            end
        end
    endgenerate

endmodule
