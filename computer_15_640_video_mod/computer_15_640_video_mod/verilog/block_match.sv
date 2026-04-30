// Parameterizable SAD (sum of absolute differences) block matcher.
// Combinational: outputs reflect current inputs only.

module block_match_sad #(
	parameter int BLOCK_SIZE = 5,
	parameter int PIXEL_W    = 8,
	parameter int SAD_W      = PIXEL_W + $clog2(BLOCK_SIZE * BLOCK_SIZE)
)(
	input  block_match_pkg#(.BLOCK_SIZE(BLOCK_SIZE), .PIXEL_W(PIXEL_W))::block_t left_block,
	input  block_match_pkg#(.BLOCK_SIZE(BLOCK_SIZE), .PIXEL_W(PIXEL_W))::block_t right_block,
	output logic [SAD_W-1:0] sad
);

	function automatic logic [PIXEL_W:0] abs_diff(
		input logic [PIXEL_W-1:0] a,
		input logic [PIXEL_W-1:0] b
	);
		if (a >= b) begin
			abs_diff = a - b;
		end else begin
			abs_diff = b - a;
		end
	endfunction

	int i;
	int j;
	logic [SAD_W-1:0] sum;

	always_comb begin
		sum = '0;
		for (i = 0; i < BLOCK_SIZE; i++) begin
			for (j = 0; j < BLOCK_SIZE; j++) begin
				sum = sum + abs_diff(left_block[i][j], right_block[i][j]);
			end
		end
		sad = sum;
	end

endmodule
