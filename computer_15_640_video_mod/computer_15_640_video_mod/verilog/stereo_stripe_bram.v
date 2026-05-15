// =============================================================================
// stereo_stripe_bram
//
// One stripe of the striped stereo BRAM. Implementation matches the canonical
// Altera Quartus Prime template for "Single-Clock, Simple Dual-Port
// Synchronous RAM with Old Data Read-During-Write Behavior" (Quartus Prime
// Pro Edition User Guide: Design Recommendations UG-20131, Example 8) so
// Quartus reliably infers a single M10K-backed memory per stripe.
//
// Key requirements from the inference docs that this module respects:
//   - One always block with both read and write at the same posedge clk.
//   - No reset signal in the always block (RAM contents cannot be cleared
//     by reset; the presence of a reset prevents M10K inference).
//   - Read output is registered (rd_data is `output reg`).
//   - No clock enable on the read address (prevents inference).
//   - (* ramstyle = "M10K" *) attribute on the reg array.
// =============================================================================

module stereo_stripe_bram #(
    parameter integer DATA_W = 8,
    parameter integer DEPTH  = 5120,
    parameter integer ADDR_W = $clog2(DEPTH)
)(
    input  wire                clk,

    input  wire                wr_en,
    input  wire [ADDR_W-1:0]   wr_addr,
    input  wire [DATA_W-1:0]   wr_data,

    input  wire [ADDR_W-1:0]   rd_addr,
    output reg  [DATA_W-1:0]   rd_data
);

    (* ramstyle = "M10K" *) reg [DATA_W-1:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (wr_en) mem[wr_addr] <= wr_data;
        rd_data <= mem[rd_addr];
    end

endmodule
