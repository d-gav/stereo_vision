// Parameterizable SAD (sum of absolute differences) block matcher.
// Combinational: outputs reflect current inputs only.

module block_match_sad #(
	parameter int BLOCK_SIZE = 5,
	parameter int PIXEL_W    = 8,
	parameter int SAD_W      = PIXEL_W + $clog2(BLOCK_SIZE * BLOCK_SIZE)
)(
	input  logic [BLOCK_SIZE*BLOCK_SIZE*PIXEL_W-1:0] left_block_flat,
	input  logic [BLOCK_SIZE*BLOCK_SIZE*PIXEL_W-1:0] right_block_flat,
	output logic [SAD_W-1:0] sad
);
	logic [SAD_W-1:0] sum_local;
	logic saw_unknown_input;
	integer i;
	integer j;

	function automatic logic [PIXEL_W-1:0] get_px(
		input logic [BLOCK_SIZE*BLOCK_SIZE*PIXEL_W-1:0] flat,
		input int r,
		input int c
	);
		int idx;
		begin
			idx = ((r * BLOCK_SIZE) + c) * PIXEL_W;
			get_px = flat[idx +: PIXEL_W];
		end
	endfunction

	function automatic logic [PIXEL_W:0] abs_diff(
		input logic [PIXEL_W-1:0] a,
		input logic [PIXEL_W-1:0] b
	);
		logic [PIXEL_W-1:0] a_s;
		logic [PIXEL_W-1:0] b_s;
		begin
			// Defensive sanitization keeps SAD deterministic during warm-up or invalid windows.
			if (^a === 1'bx) begin
				a_s = '0;
			end else begin
				a_s = a;
			end
			if (^b === 1'bx) begin
				b_s = '0;
			end else begin
				b_s = b;
			end

			if (a_s >= b_s) begin
				abs_diff = a_s - b_s;
			end else begin
				abs_diff = b_s - a_s;
			end
		end
	endfunction

	always_comb begin
		logic [PIXEL_W-1:0] left_px;
		logic [PIXEL_W-1:0] right_px;

		sum_local = '0;
		saw_unknown_input = 1'b0;
		for (i = 0; i < BLOCK_SIZE; i++) begin
			for (j = 0; j < BLOCK_SIZE; j++) begin
				left_px = get_px(left_block_flat, i, j);
				right_px = get_px(right_block_flat, i, j);
				if ((^left_px === 1'bx) || (^right_px === 1'bx)) begin
					saw_unknown_input = 1'b1;
				end
				sum_local = sum_local + abs_diff(left_px, right_px);
			end
		end
		sad = sum_local;
	end

endmodule
