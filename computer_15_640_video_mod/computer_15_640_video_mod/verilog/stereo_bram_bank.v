// =============================================================================
// stereo_bram_bank
//
// Striped BRAM. Replaces the previous monolithic single-port BRAM.
//
// Storage is partitioned into NUM_STRIPES independent M10K-backed sub-banks.
// Each sub-bank holds STRIPE_HEIGHT contiguous rows × FULL_ROW_WIDTH columns
// of pixel data. All sub-banks have their own physical read port, so a single
// (rd_col, rd_row_in_stripe) pair returns NUM_STRIPES bytes in parallel —
// one byte from each stripe at the same column / row-within-stripe.
//
// This lets column_prefetch fetch a full column in STRIPE_HEIGHT cycles
// (one read per row-within-stripe, served by all stripes simultaneously)
// instead of FRAME_HEIGHT cycles. With STRIPE_HEIGHT=8 and FRAME_HEIGHT=200
// that's a 25× reduction in column-fetch latency.
//
// Write side stays single-byte-per-cycle. Writers split the (dy, col)
// destination into (stripe, row_in_stripe, col) and only the addressed
// sub-bank is written each cycle.
// =============================================================================

module stereo_bram_bank #(
    parameter int FRAME_HEIGHT     = 200,
    parameter int FULL_ROW_WIDTH   = 640,
    parameter int STRIPE_HEIGHT    = 8,
    parameter int NUM_STRIPES      = (FRAME_HEIGHT + STRIPE_HEIGHT - 1) / STRIPE_HEIGHT,
    parameter int DATA_W           = 8,
    parameter int STRIPE_W         = (NUM_STRIPES   <= 1) ? 1 : $clog2(NUM_STRIPES),
    parameter int ROW_IN_STRIPE_W  = (STRIPE_HEIGHT <= 1) ? 1 : $clog2(STRIPE_HEIGHT),
    parameter int COL_W            = $clog2(FULL_ROW_WIDTH)
)(
    input  logic                       clk,

    // Write port: one pixel per cycle. Writers compute the destination's
    // (stripe, row_in_stripe, col) themselves so the BRAM doesn't need a
    // divider. Only the indexed stripe BRAM has its enable asserted.
    input  logic                       wr_en,
    input  logic [STRIPE_W-1:0]        wr_stripe,
    input  logic [ROW_IN_STRIPE_W-1:0] wr_row_in_stripe,
    input  logic [COL_W-1:0]           wr_col,
    input  logic [DATA_W-1:0]          wr_data,

    // Parallel read port: rd_col and rd_row_in_stripe are shared across all
    // stripes; each stripe returns its byte at that (col, row_in_stripe).
    // Registered output, 1-cycle BRAM read latency (M10K behavior).
    input  logic [COL_W-1:0]           rd_col,
    input  logic [ROW_IN_STRIPE_W-1:0] rd_row_in_stripe,
    output logic [DATA_W-1:0]          rd_data [0:NUM_STRIPES-1]
);

    localparam int STRIPE_DEPTH  = STRIPE_HEIGHT * FULL_ROW_WIDTH;
    localparam int STRIPE_ADDR_W = $clog2(STRIPE_DEPTH);

    // Address within a stripe = row_in_stripe * FULL_ROW_WIDTH + col.
    // Multiplications are by a fixed (compile-time) constant, so Quartus
    // synthesizes them as a small shift+add tree, not a multiplier.
    logic [STRIPE_ADDR_W-1:0] wr_addr_in_stripe;
    logic [STRIPE_ADDR_W-1:0] rd_addr_in_stripe;
    assign wr_addr_in_stripe = (STRIPE_ADDR_W'(wr_row_in_stripe) * FULL_ROW_WIDTH) +
                               STRIPE_ADDR_W'(wr_col);
    assign rd_addr_in_stripe = (STRIPE_ADDR_W'(rd_row_in_stripe) * FULL_ROW_WIDTH) +
                               STRIPE_ADDR_W'(rd_col);

    genvar g;
    generate
        for (g = 0; g < NUM_STRIPES; g++) begin : GEN_STRIPE
            (* ramstyle = "M10K" *) logic [DATA_W-1:0] mem [0:STRIPE_DEPTH-1];

            always_ff @(posedge clk) begin
                if (wr_en && (wr_stripe == STRIPE_W'(g))) begin
                    mem[wr_addr_in_stripe] <= wr_data;
                end
            end

            always_ff @(posedge clk) begin
                rd_data[g] <= mem[rd_addr_in_stripe];
            end
        end
    endgenerate

endmodule
