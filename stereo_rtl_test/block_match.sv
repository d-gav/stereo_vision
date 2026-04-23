// Parameterizable SAD (sum of absolute differences) block matcher.
// Combinational: outputs reflect current inputs only.

module block_match_sad #(
	parameter int BLOCK_SIZE = 5,
	parameter int PIXEL_W    = 8,
	parameter int SAD_W      = PIXEL_W + $clog2(BLOCK_SIZE * BLOCK_SIZE)
)(
	input  logic [PIXEL_W-1:0] left_block  [0:BLOCK_SIZE-1][0:BLOCK_SIZE-1],
	input  logic [PIXEL_W-1:0] right_block [0:BLOCK_SIZE-1][0:BLOCK_SIZE-1],
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

	always @* begin
		logic [SAD_W-1:0] sum_local;
		int i;
		int j;

		sum_local = '0;
		for (i = 0; i < BLOCK_SIZE; i++) begin
			for (j = 0; j < BLOCK_SIZE; j++) begin
				sum_local = sum_local + abs_diff(left_block[i][j], right_block[i][j]);
			end
		end
		sad = sum_local;
	end

endmodule
