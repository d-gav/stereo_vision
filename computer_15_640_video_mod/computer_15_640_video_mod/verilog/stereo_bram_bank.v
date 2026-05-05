// =============================================================================
// stereo_bram_bank
//
// Striped BRAM. NUM_STRIPES leaf instances of stereo_stripe_bram, each holding
// STRIPE_HEIGHT rows × FULL_ROW_WIDTH columns of pixel data. Each leaf is its
// own module so Quartus performs M10K inference on the simplest possible
// pattern (matches the canonical Altera RAM template); avoids the
// large-system-memory / slow-compile failure mode called out in
// UG-20131 §2.4.1 ("If your design contains a RAM block that your synthesis
// tool does not recognize and infer, the design might require a large amount
// of system memory that can potentially cause compilation problems").
//
// Read data is exposed as a packed bus rd_data_flat = {stripe[N-1], ...,
// stripe[1], stripe[0]}, each DATA_W bits wide. Consumers slice it.
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

    // Write port: one pixel per cycle. Writers compute (stripe, row_in_stripe,
    // col) themselves so the BRAM doesn't need a divider. Only the addressed
    // stripe's wr_en is driven high each cycle.
    input  wire                                wr_en,
    input  wire [STRIPE_W-1:0]                 wr_stripe,
    input  wire [ROW_IN_STRIPE_W-1:0]          wr_row_in_stripe,
    input  wire [COL_W-1:0]                    wr_col,
    input  wire [DATA_W-1:0]                   wr_data,

    // Parallel read port: rd_col and rd_row_in_stripe shared across all
    // stripes; each stripe returns its byte at that location, packed into
    // rd_data_flat[g*DATA_W +: DATA_W]. 1-cycle BRAM read latency.
    input  wire [COL_W-1:0]                    rd_col,
    input  wire [ROW_IN_STRIPE_W-1:0]          rd_row_in_stripe,
    output wire [NUM_STRIPES*DATA_W-1:0]       rd_data_flat
);

    localparam integer STRIPE_DEPTH = STRIPE_HEIGHT * FULL_ROW_WIDTH;

    // Address within a stripe = row_in_stripe * FULL_ROW_WIDTH + col.
    // Multiply is by a compile-time constant so Quartus emits a shift/add
    // tree, not a multiplier. Width-extension happens implicitly.
    wire [STRIPE_ADDR_W-1:0] wr_addr_in_stripe;
    wire [STRIPE_ADDR_W-1:0] rd_addr_in_stripe;
    assign wr_addr_in_stripe = wr_row_in_stripe * FULL_ROW_WIDTH + wr_col;
    assign rd_addr_in_stripe = rd_row_in_stripe * FULL_ROW_WIDTH + rd_col;

    genvar g;
    generate
        for (g = 0; g < NUM_STRIPES; g = g + 1) begin : GEN_STRIPE
            wire              stripe_wr_en;
            wire [DATA_W-1:0] stripe_rd_data;

            assign stripe_wr_en = wr_en && (wr_stripe == g);

            stereo_stripe_bram #(
                .DATA_W(DATA_W),
                .DEPTH (STRIPE_DEPTH)
            ) u_stripe (
                .clk    (clk),
                .wr_en  (stripe_wr_en),
                .wr_addr(wr_addr_in_stripe),
                .wr_data(wr_data),
                .rd_addr(rd_addr_in_stripe),
                .rd_data(stripe_rd_data)
            );

            assign rd_data_flat[g*DATA_W +: DATA_W] = stripe_rd_data;
        end
    endgenerate

endmodule
