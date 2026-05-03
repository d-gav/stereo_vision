// Parameterizable SAD (sum of absolute differences) block matcher.
// Combinational: outputs reflect current inputs only.
// Uses flat bit-vectors for block inputs to avoid parameterized package dependency.

module block_match_sad #(
	parameter int BLOCK_SIZE = 5,
	parameter int PIXEL_W    = 8,
	parameter int SAD_W      = PIXEL_W + $clog2(BLOCK_SIZE * BLOCK_SIZE)
)(
	input  logic [BLOCK_SIZE*BLOCK_SIZE*PIXEL_W-1:0] left_block_flat,
	input  logic [BLOCK_SIZE*BLOCK_SIZE*PIXEL_W-1:0] right_block_flat,
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

	// Extract a pixel from the flat block vector
	function automatic logic [PIXEL_W-1:0] get_pixel(
		input logic [BLOCK_SIZE*BLOCK_SIZE*PIXEL_W-1:0] blk,
		input int row,
		input int col
	);
		int idx;
		begin
			idx = ((row * BLOCK_SIZE) + col) * PIXEL_W;
			get_pixel = blk[idx +: PIXEL_W];
		end
	endfunction

	always_comb begin
		sum = '0;
		for (i = 0; i < BLOCK_SIZE; i++) begin
			for (j = 0; j < BLOCK_SIZE; j++) begin
				sum = sum + abs_diff(get_pixel(left_block_flat, i, j),
				                     get_pixel(right_block_flat, i, j));
			end
		end
		sad = sum;
	end

endmodule
