module mem_block_intf #(
	parameter int FRAME_HEIGHT     = 288,
	parameter int HALF_FRAME_WIDTH = 320,
	parameter int BLOCK_SIZE       = 5,
	parameter int PIXEL_W          = 8,
	parameter int MAX_DISP         = 63,
	parameter int SAD_W            = PIXEL_W + $clog2(BLOCK_SIZE * BLOCK_SIZE),
	parameter int DISP_W           = (MAX_DISP < 1) ? 1 : $clog2(MAX_DISP + 1),
	parameter int NUM_SAD_UNITS    = (FRAME_HEIGHT + BLOCK_SIZE - 1) / BLOCK_SIZE,
	parameter int ROW_W            = (FRAME_HEIGHT <= 1) ? 1 : $clog2(FRAME_HEIGHT),
	parameter int COL_W            = (HALF_FRAME_WIDTH <= 1) ? 1 : $clog2(HALF_FRAME_WIDTH)
) (
	input logic clk,
	input logic rst,

	output logic mem_req,
	output logic mem_bank, // 0 = left, 1 = right
	output logic [COL_W-1:0] mem_col,
	input  logic [PIXEL_W-1:0] mem_rdata [0:FRAME_HEIGHT-1],
	input  logic mem_rvalid,

	output logic [7:0] disp_map [0:FRAME_HEIGHT-1][0:HALF_FRAME_WIDTH-1]
);

	localparam int HALF_BLOCK = BLOCK_SIZE / 2;
	localparam int X_W        = COL_W;
	localparam int PHASE_W    = (BLOCK_SIZE <= 1) ? 1 : $clog2(BLOCK_SIZE);
	localparam int X_MIN      = HALF_BLOCK;
	localparam int X_MAX      = HALF_FRAME_WIDTH - HALF_BLOCK - 1;

	localparam logic [X_W-1:0]      X_MIN_L     = X_MIN;
	localparam logic [X_W-1:0]      X_MAX_L     = X_MAX;
	localparam logic [DISP_W-1:0]   MAX_DISP_L  = MAX_DISP;
	localparam logic [PHASE_W-1:0]  MAX_PHASE_L = BLOCK_SIZE - 1;

	typedef enum logic [2:0] {
		ST_REQ_LEFT,
		ST_WAIT_LEFT,
		ST_REQ_RIGHT,
		ST_WAIT_RIGHT,
		ST_EVAL
	} state_t;

	state_t state_q;

	logic [PIXEL_W-1:0] left_col_buf  [0:NUM_SAD_UNITS-1][0:BLOCK_SIZE-1];
	logic [PIXEL_W-1:0] right_col_buf [0:NUM_SAD_UNITS-1][0:BLOCK_SIZE-1];

	logic left_pulse;
	logic right_pulse;

	logic [SAD_W-1:0] sad_value [0:NUM_SAD_UNITS-1];
	logic [SAD_W-1:0] best_sad  [0:NUM_SAD_UNITS-1];
	logic [DISP_W-1:0] best_disp [0:NUM_SAD_UNITS-1];

	logic [X_W-1:0]     cur_x;
	logic [DISP_W-1:0]  cur_d;
	logic [PHASE_W-1:0] cur_phase;
	logic [PHASE_W-1:0] col_idx;

	genvar g;
	generate
		for (g = 0; g < NUM_SAD_UNITS; g++) begin : GEN_UNIT
			logic [BLOCK_SIZE*PIXEL_W-1:0] left_col_flat_g;
			logic [BLOCK_SIZE*PIXEL_W-1:0] right_col_flat_g;
			logic [PIXEL_W-1:0] left_block_g  [0:BLOCK_SIZE-1][0:BLOCK_SIZE-1];
			logic [PIXEL_W-1:0] right_block_g [0:BLOCK_SIZE-1][0:BLOCK_SIZE-1];
			logic [BLOCK_SIZE*BLOCK_SIZE*PIXEL_W-1:0] left_block_flat_g;
			logic [BLOCK_SIZE*BLOCK_SIZE*PIXEL_W-1:0] right_block_flat_g;

			genvar rr;
			for (rr = 0; rr < BLOCK_SIZE; rr++) begin : GEN_COL_WIRE
				assign left_col_flat_g[(rr+1)*PIXEL_W-1 -: PIXEL_W] = left_col_buf[g][rr];
				assign right_col_flat_g[(rr+1)*PIXEL_W-1 -: PIXEL_W] = right_col_buf[g][rr];
			end

			sliding_window #(
				.BLOCK_SIZE(BLOCK_SIZE),
				.PIXEL_W(PIXEL_W)
			) u_ref_window (
				.clk(clk),
				.rst(rst),
				.valid_in(left_pulse),
				.pixel_in_col_flat(left_col_flat_g),
				.block_out(left_block_g),
				.block_out_flat(left_block_flat_g)
			);

			sliding_window #(
				.BLOCK_SIZE(BLOCK_SIZE),
				.PIXEL_W(PIXEL_W)
			) u_match_window (
				.clk(clk),
				.rst(rst),
				.valid_in(right_pulse),
				.pixel_in_col_flat(right_col_flat_g),
				.block_out(right_block_g),
				.block_out_flat(right_block_flat_g)
			);

			block_match_sad #(
				.BLOCK_SIZE(BLOCK_SIZE),
				.PIXEL_W(PIXEL_W),
				.SAD_W(SAD_W)
			) u_block_match_sad (
				.left_block_flat(left_block_flat_g),
				.right_block_flat(right_block_flat_g),
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

	integer ur;
	integer xr;
	integer u;
	integer r;
	integer y_addr_i;
	integer y_center_i;
	integer left_col_i;
	integer right_col_i;
	logic [SAD_W-1:0] sad_u;
	logic valid_u;

	always_ff @(posedge clk) begin
		if (rst) begin
			state_q <= ST_REQ_LEFT;
			cur_x <= X_MIN_L;
			cur_d <= '0;
			cur_phase <= '0;
			col_idx <= '0;

			mem_req <= 1'b0;
			mem_bank <= 1'b0;
			mem_col <= '0;
			left_pulse <= 1'b0;
			right_pulse <= 1'b0;

			for (u = 0; u < NUM_SAD_UNITS; u++) begin
				best_sad[u] <= {SAD_W{1'b1}};
				best_disp[u] <= '0;
				for (r = 0; r < BLOCK_SIZE; r++) begin
					left_col_buf[u][r] <= '0;
					right_col_buf[u][r] <= '0;
				end
			end

			for (ur = 0; ur < FRAME_HEIGHT; ur++) begin
				for (xr = 0; xr < HALF_FRAME_WIDTH; xr++) begin
					disp_map[ur][xr] <= 8'h00;
				end
			end
		end else begin
			left_pulse <= 1'b0;
			right_pulse <= 1'b0;
			mem_req <= 1'b0;

			case (state_q)
				ST_REQ_LEFT: begin
					left_col_i = cur_x - HALF_BLOCK + col_idx;
					mem_bank <= 1'b0;
					if ((left_col_i >= 0) && (left_col_i < HALF_FRAME_WIDTH)) begin
						mem_req <= 1'b1;
						mem_col <= left_col_i[X_W-1:0];
						state_q <= ST_WAIT_LEFT;
					end else begin
						for (u = 0; u < NUM_SAD_UNITS; u++) begin
							for (r = 0; r < BLOCK_SIZE; r++) begin
								left_col_buf[u][r] <= '0;
							end
						end
						left_pulse <= 1'b1;
						state_q <= ST_REQ_RIGHT;
					end
				end

				ST_WAIT_LEFT: begin
					if (mem_rvalid) begin
						for (u = 0; u < NUM_SAD_UNITS; u++) begin
							for (r = 0; r < BLOCK_SIZE; r++) begin
								y_addr_i = (u * BLOCK_SIZE) + cur_phase - HALF_BLOCK + r;
								if ((y_addr_i >= 0) && (y_addr_i < FRAME_HEIGHT)) begin
									left_col_buf[u][r] <= mem_rdata[y_addr_i];
								end else begin
									left_col_buf[u][r] <= '0;
								end
							end
						end
						left_pulse <= 1'b1;
						state_q <= ST_REQ_RIGHT;
					end
				end

				ST_REQ_RIGHT: begin
					right_col_i = cur_x - cur_d - HALF_BLOCK + col_idx;
					mem_bank <= 1'b1;
					if ((right_col_i >= 0) && (right_col_i < HALF_FRAME_WIDTH)) begin
						mem_req <= 1'b1;
						mem_col <= right_col_i[X_W-1:0];
						state_q <= ST_WAIT_RIGHT;
					end else begin
						for (u = 0; u < NUM_SAD_UNITS; u++) begin
							for (r = 0; r < BLOCK_SIZE; r++) begin
								right_col_buf[u][r] <= '0;
							end
						end
						right_pulse <= 1'b1;
						if (col_idx == MAX_PHASE_L) begin
							state_q <= ST_EVAL;
						end else begin
							col_idx <= col_idx + 1'b1;
							state_q <= ST_REQ_LEFT;
						end
					end
				end

				ST_WAIT_RIGHT: begin
					if (mem_rvalid) begin
						for (u = 0; u < NUM_SAD_UNITS; u++) begin
							for (r = 0; r < BLOCK_SIZE; r++) begin
								y_addr_i = (u * BLOCK_SIZE) + cur_phase - HALF_BLOCK + r;
								if ((y_addr_i >= 0) && (y_addr_i < FRAME_HEIGHT)) begin
									right_col_buf[u][r] <= mem_rdata[y_addr_i];
								end else begin
									right_col_buf[u][r] <= '0;
								end
							end
						end
						right_pulse <= 1'b1;
						if (col_idx == MAX_PHASE_L) begin
							state_q <= ST_EVAL;
						end else begin
							col_idx <= col_idx + 1'b1;
							state_q <= ST_REQ_LEFT;
						end
					end
				end

				ST_EVAL: begin
					for (u = 0; u < NUM_SAD_UNITS; u++) begin
						y_center_i = (u * BLOCK_SIZE) + cur_phase;
						valid_u =
							(y_center_i >= HALF_BLOCK)
							&& (y_center_i + HALF_BLOCK < FRAME_HEIGHT)
							&& (cur_x >= X_MIN_L)
							&& (cur_x <= X_MAX_L)
							&& (cur_x >= (cur_d + HALF_BLOCK));

						if (valid_u) begin
							sad_u = sad_value[u];
						end else begin
							sad_u = {SAD_W{1'b1}};
						end

						if ((cur_d == '0) || (sad_u < best_sad[u])) begin
							best_sad[u] <= sad_u;
							best_disp[u] <= cur_d;
						end

						if ((cur_d == MAX_DISP_L) && valid_u) begin
							if ((cur_d == '0) || (sad_u < best_sad[u])) begin
								disp_map[y_center_i][cur_x] <= disp_to_u8(cur_d);
							end else begin
								disp_map[y_center_i][cur_x] <= disp_to_u8(best_disp[u]);
							end
						end
					end

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

					col_idx <= '0;
					state_q <= ST_REQ_LEFT;
				end

				default: begin
					state_q <= ST_REQ_LEFT;
				end
			endcase
		end
	end

endmodule
