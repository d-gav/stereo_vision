// Simple dual-port BRAM for stereo pixel storage.
// Port A: write-only (from AXI bus master)
// Port B: read-only  (from column prefetch FSM)
// Quartus will infer M10K blocks from this pattern.
//
// Storage: DEPTH entries of DATA_W bits.
// For stereo: DEPTH = FRAME_HEIGHT * HALF_FRAME_WIDTH = 288*320 = 92160
//             DATA_W = 8

module stereo_bram_bank #(
	parameter DEPTH  = 92160,
	parameter DATA_W = 8,
	parameter ADDR_W = 17    // ceil(log2(92160)) = 17
)(
	input wire clk,

	// Write port (A)
	input wire              wr_en,
	input wire [ADDR_W-1:0] wr_addr,
	input wire [DATA_W-1:0] wr_data,

	// Read port (B)
	input wire [ADDR_W-1:0] rd_addr,
	output reg [DATA_W-1:0] rd_data
);

	// Memory array — Quartus infers M10K from this
	(* ramstyle = "M10K" *) reg [DATA_W-1:0] mem [0:DEPTH-1];

	// Write port
	always @(posedge clk) begin
		if (wr_en) begin
			mem[wr_addr] <= wr_data;
		end
	end

	// Read port (1-cycle latency)
	always @(posedge clk) begin
		rd_data <= mem[rd_addr];
	end

endmodule
