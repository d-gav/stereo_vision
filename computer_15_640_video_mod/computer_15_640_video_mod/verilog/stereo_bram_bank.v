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
// Read data is exposed as a packed bus rd_data_flat = {stripe[N-1], ...,
// stripe[1], stripe[0]}, each DATA_W bits wide. Consumers slice it. Using a
// packed bus instead of an unpacked array port avoids Quartus quirks with
// multi-driver unpacked array outputs (one driver per generate iteration).
//
// Write side stays single-byte-per-cycle. Writers split the (dy, col)
// destination into (stripe, row_in_stripe, col) and only the addressed
// sub-bank is written each cycle.
// =============================================================================

module stereo_bram_bank #(
    parameter integer FRAME_HEIGHT     = 200,
    parameter integer FULL_ROW_WIDTH   = 640,
    parameter integer STRIPE_HEIGHT    = 8,
    parameter integer NUM_STRIPES      = (FRAME_HEIGHT + STRIPE_HEIGHT - 1) / STRIPE_HEIGHT,
    parameter integer DATA_W           = 8,
    parameter integer STRIPE_W         = (NUM_STRIPES   <= 1) ? 1 : $clog2(NUM_STRIPES),
    parameter integer ROW_IN_STRIPE_W  = (STRIPE_HEIGHT <= 1) ? 1 : $clog2(STRIPE_HEIGHT),
    parameter integer COL_W            = $clog2(FULL_ROW_WIDTH),
    parameter integer STRIPE_ADDR_W    = $clog2(STRIPE_HEIGHT * FULL_ROW_WIDTH)
)(
    input  wire                                clk,

    // Write port: one pixel per cycle. Writers compute the destination's
    // (stripe, row_in_stripe, col) themselves so the BRAM doesn't need a
    // divider. Only the indexed stripe BRAM has its enable asserted.
    input  wire                                wr_en,
    input  wire [STRIPE_W-1:0]                 wr_stripe,
    input  wire [ROW_IN_STRIPE_W-1:0]          wr_row_in_stripe,
    input  wire [COL_W-1:0]                    wr_col,
    input  wire [DATA_W-1:0]                   wr_data,

    // Parallel read port: rd_col and rd_row_in_stripe shared across all
    // stripes; each stripe returns its byte at that (col, row_in_stripe).
    // Returned as a packed bus: rd_data_flat[g*DATA_W +: DATA_W] is stripe g.
    // Registered output, 1-cycle BRAM read latency (M10K behavior).
    input  wire [COL_W-1:0]                    rd_col,
    input  wire [ROW_IN_STRIPE_W-1:0]          rd_row_in_stripe,
    output wire [NUM_STRIPES*DATA_W-1:0]       rd_data_flat
);

    localparam integer STRIPE_DEPTH = STRIPE_HEIGHT * FULL_ROW_WIDTH;

    // Address within a stripe = row_in_stripe * FULL_ROW_WIDTH + col.
    // Multiply is by a compile-time constant so Quartus emits a shift/add
    // tree, not a true multiplier. Width-extension happens implicitly.
    wire [STRIPE_ADDR_W-1:0] wr_addr_in_stripe;
    wire [STRIPE_ADDR_W-1:0] rd_addr_in_stripe;
    assign wr_addr_in_stripe = wr_row_in_stripe * FULL_ROW_WIDTH + wr_col;
    assign rd_addr_in_stripe = rd_row_in_stripe * FULL_ROW_WIDTH + rd_col;

    genvar g;
    generate
        for (g = 0; g < NUM_STRIPES; g = g + 1) begin : GEN_STRIPE
            (* ramstyle = "M10K" *) reg [DATA_W-1:0] mem [0:STRIPE_DEPTH-1];
            reg [DATA_W-1:0] rd_q;

            always @(posedge clk) begin
                if (wr_en && (wr_stripe == g)) begin
                    mem[wr_addr_in_stripe] <= wr_data;
                end
            end

            always @(posedge clk) begin
                rd_q <= mem[rd_addr_in_stripe];
            end

            assign rd_data_flat[g*DATA_W +: DATA_W] = rd_q;
        end
    endgenerate

endmodule
