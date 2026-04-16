module mem_block_intf #(
	parameter int FRAME_HEIGHT     = 288,
	parameter int HALF_FRAME_WIDTH = 320,
	parameter int BLOCK_SIZE       = 5,
	parameter int PIXEL_W          = 8,
	parameter int MAX_DISP         = 63,
	parameter int SAD_W            = PIXEL_W + $clog2(BLOCK_SIZE * BLOCK_SIZE),
	parameter int DISP_W           = (MAX_DISP < 1) ? 1 : $clog2(MAX_DISP + 1),
	parameter int NUM_SAD_UNITS    = (FRAME_HEIGHT + BLOCK_SIZE - 1) / BLOCK_SIZE
) (
	input logic clk,
	input logic rst,

	input logic [PIXEL_W-1:0] left_row_bank  [0:FRAME_HEIGHT-1][0:HALF_FRAME_WIDTH-1],
	input logic [PIXEL_W-1:0] right_row_bank [0:FRAME_HEIGHT-1][0:HALF_FRAME_WIDTH-1],

	output logic [7:0] disp_map [0:FRAME_HEIGHT-1][0:HALF_FRAME_WIDTH-1]
);

	localparam int HALF_BLOCK = BLOCK_SIZE / 2;
	localparam int X_W        = (HALF_FRAME_WIDTH <= 1) ? 1 : $clog2(HALF_FRAME_WIDTH);
	localparam int Y_W        = (FRAME_HEIGHT <= 1) ? 1 : $clog2(FRAME_HEIGHT);
	localparam int PHASE_W    = (BLOCK_SIZE <= 1) ? 1 : $clog2(BLOCK_SIZE);
	localparam int X_MIN      = HALF_BLOCK;
	localparam int X_MAX      = HALF_FRAME_WIDTH - HALF_BLOCK - 1;

	localparam logic [X_W-1:0]      X_MIN_L     = X_MIN;
	localparam logic [X_W-1:0]      X_MAX_L     = X_MAX;
	localparam logic [DISP_W-1:0]   MAX_DISP_L  = MAX_DISP;
	localparam logic [PHASE_W-1:0]  MAX_PHASE_L = BLOCK_SIZE - 1;

	typedef block_match_pkg#(.BLOCK_SIZE(BLOCK_SIZE), .PIXEL_W(PIXEL_W))::block_t block_t;

	block_t left_blocks  [0:NUM_SAD_UNITS-1];
	block_t right_blocks [0:NUM_SAD_UNITS-1];

	logic [SAD_W-1:0] sad_value [0:NUM_SAD_UNITS-1];
	logic [SAD_W-1:0] sad_eval  [0:NUM_SAD_UNITS-1];

	logic [SAD_W-1:0]  best_sad  [0:NUM_SAD_UNITS-1];
	logic [DISP_W-1:0] best_disp [0:NUM_SAD_UNITS-1];

	logic [Y_W-1:0] unit_center_y     [0:NUM_SAD_UNITS-1];
	logic           unit_center_valid [0:NUM_SAD_UNITS-1];


    // Request pipeline for SAD 
    // At stage 0, new request is issued, we assign x, d, and phase
    // At stage 2, memory is ready and SAD can be evaluated.

	logic req_valid [0:2];
	logic [X_W-1:0]     req_x      [0:2];
	logic [DISP_W-1:0]  req_d      [0:2];
	logic [PHASE_W-1:0] req_phase  [0:2];
	logic               req_last_d [0:2];


	logic [X_W-1:0]     cur_x; // the current x pixel for every unit  (e.g. [0 ... 319])
	logic [DISP_W-1:0]  cur_d; // the current disparity being processed for a given pixel in reference image (e.g. [0 ... 128])
	logic [PHASE_W-1:0] cur_phase; // the current row phase (e.g. [0 ... BLOCK_SIZE-1]) that determines vertical center of each unit's block




	genvar g;
	generate
		for (g = 0; g < NUM_SAD_UNITS; g++) begin : GEN_SAD
			block_match_sad #(
				.BLOCK_SIZE(BLOCK_SIZE),
				.PIXEL_W(PIXEL_W),
				.SAD_W(SAD_W)
			) u_block_match_sad (
				.left_block(left_blocks[g]),
				.right_block(right_blocks[g]),
				.sad(sad_value[g])
			);
		end
	endgenerate

	function automatic logic [7:0] disp_to_u8(input logic [DISP_W-1:0] d);
		int k;
		begin
			disp_to_u8 = 8'h00;
			for (k = 0; k < 8; k++) begin
				if (k < DISP_W) begin
					disp_to_u8[k] = d[k];
				end
			end
		end
	endfunction

	integer u;
	integer r;
	integer c;
	integer y_center_i;
	integer y_addr_i;
	integer x_left_i;
	integer x_right_i;

	always_comb begin
		// for each SAD unit: 
		for (u = 0; u < NUM_SAD_UNITS; u++) begin
            // assign y: which block am I? how big is a block? where am I in current phase? 
			y_center_i = (u * BLOCK_SIZE) + req_phase[2];

			// Keep a packed version of center y for downstream map writeback.
			if ((y_center_i >= 0) && (y_center_i < FRAME_HEIGHT)) begin
				unit_center_y[u] = y_center_i[Y_W-1:0];
			end else begin
				unit_center_y[u] = '0;
			end

			// Mark whether this unit/window request is valid for SAD evaluation.
			// Checks include vertical bounds, horizontal center bounds, and
			// right-image disparity reachability.
			unit_center_valid[u] = req_valid[2]
				&& (y_center_i >= HALF_BLOCK) // half block halo from top
				&& (y_center_i + HALF_BLOCK < FRAME_HEIGHT) // half block halo from bottom
				&& (req_x[2] >= X_MIN_L) // horizontal center bounds
				&& (req_x[2] <= X_MAX_L) // horizontal center bounds
				&& (req_x[2] >= (req_d[2] + HALF_BLOCK)); // right-image disparity reachability

			// Gather both reference (left) and candidate (right-shifted by disparity)
			// blocks from row-banked memories. Out-of-range samples are zero-padded.
			for (r = 0; r < BLOCK_SIZE; r++) begin
				for (c = 0; c < BLOCK_SIZE; c++) begin
					y_addr_i  = y_center_i - HALF_BLOCK + r;
					x_left_i  = req_x[2] - HALF_BLOCK + c;
					x_right_i = req_x[2] - req_d[2] - HALF_BLOCK + c;

					if ((y_addr_i >= 0) && (y_addr_i < FRAME_HEIGHT)
						&& (x_left_i >= 0) && (x_left_i < HALF_FRAME_WIDTH)) begin
						left_blocks[u][r][c] = left_row_bank[y_addr_i][x_left_i];
					end else begin
						left_blocks[u][r][c] = '0;
					end

					if ((y_addr_i >= 0) && (y_addr_i < FRAME_HEIGHT)
						&& (x_right_i >= 0) && (x_right_i < HALF_FRAME_WIDTH)) begin
						right_blocks[u][r][c] = right_row_bank[y_addr_i][x_right_i];
					end else begin
						right_blocks[u][r][c] = '0;
					end
				end
			end

			// Invalid windows get max SAD so they never win the min comparison.
			if (unit_center_valid[u]) begin
				sad_eval[u] = sad_value[u];
			end else begin
				sad_eval[u] = {SAD_W{1'b1}};
			end
		end
	end

	integer ur;
	integer xr;
	always_ff @(posedge clk or posedge rst) begin
		if (rst) begin
			// Initialize scan position and request pipeline.
			cur_x <= X_MIN_L;
			cur_d <= '0;
			cur_phase <= '0;

			req_valid[0] <= 1'b0;
			req_valid[1] <= 1'b0;
			req_valid[2] <= 1'b0;
			req_x[0] <= '0;
			req_x[1] <= '0;
			req_x[2] <= '0;
			req_d[0] <= '0;
			req_d[1] <= '0;
			req_d[2] <= '0;
			req_phase[0] <= '0;
			req_phase[1] <= '0;
			req_phase[2] <= '0;
			req_last_d[0] <= 1'b0;
			req_last_d[1] <= 1'b0;
			req_last_d[2] <= 1'b0;

			for (ur = 0; ur < NUM_SAD_UNITS; ur++) begin
				best_sad[ur] <= {SAD_W{1'b1}};
				best_disp[ur] <= '0;
			end

			for (ur = 0; ur < FRAME_HEIGHT; ur++) begin
				for (xr = 0; xr < HALF_FRAME_WIDTH; xr++) begin
					disp_map[ur][xr] <= 8'h00;
				end
			end
		end else begin
			// Request metadata pipeline for 2-cycle memory latency:
			// stage 0 = issue, stage 2 = SAD consume.
			req_valid[2] <= req_valid[1];
			req_x[2] <= req_x[1];
			req_d[2] <= req_d[1];
			req_phase[2] <= req_phase[1];
			req_last_d[2] <= req_last_d[1];

			req_valid[1] <= req_valid[0];
			req_x[1] <= req_x[0];
			req_d[1] <= req_d[0];
			req_phase[1] <= req_phase[0];
			req_last_d[1] <= req_last_d[0];

			// Issue next request (x, disparity, row phase).
			req_valid[0] <= 1'b1;
			req_x[0] <= cur_x;
			req_d[0] <= cur_d;
			req_phase[0] <= cur_phase;
			req_last_d[0] <= (cur_d == MAX_DISP_L);

			// Disparity-serial schedule:
			// d increments fastest; then x; then row phase.
			if (cur_d == MAX_DISP_L) begin
				cur_d <= '0;
				if (cur_x == X_MAX_L) begin
					cur_x <= X_MIN_L;
					if (cur_phase == MAX_PHASE_L) begin
						cur_phase <= '0;
					end else begin
						cur_phase <= cur_phase + 1'b1;
					end
				end else begin
					cur_x <= cur_x + 1'b1;
				end
			end else begin
				cur_d <= cur_d + 1'b1;
			end

			// For each unit, track running minimum SAD over all disparities.
			// On final disparity, commit winning disparity to disp_map.
			for (ur = 0; ur < NUM_SAD_UNITS; ur++) begin
				if (req_valid[2]) begin
					if ((req_d[2] == '0) || (sad_eval[ur] < best_sad[ur])) begin
						best_sad[ur] <= sad_eval[ur];
						best_disp[ur] <= req_d[2];
						if (req_last_d[2] && unit_center_valid[ur]) begin
							disp_map[unit_center_y[ur]][req_x[2]] <= disp_to_u8(req_d[2]);
						end
					end else if (req_last_d[2] && unit_center_valid[ur]) begin
						disp_map[unit_center_y[ur]][req_x[2]] <= disp_to_u8(best_disp[ur]);
					end
				end
			end
		end
	end

endmodule