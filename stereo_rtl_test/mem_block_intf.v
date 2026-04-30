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

	localparam int MEM_RD_LATENCY = 2;

	localparam int HALF_BLOCK = BLOCK_SIZE / 2;
	localparam int X_W        = COL_W;
	localparam int PHASE_W    = (BLOCK_SIZE <= 1) ? 1 : $clog2(BLOCK_SIZE);
	localparam int X_MIN      = HALF_BLOCK;
	localparam int X_MAX      = HALF_FRAME_WIDTH - HALF_BLOCK - 1;
	localparam int PRELOAD_W  = (BLOCK_SIZE <= 1) ? 1 : $clog2(BLOCK_SIZE + 1);
	localparam int PRIME_W    = (MEM_RD_LATENCY <= 1) ? 1 : $clog2(MEM_RD_LATENCY + 1);
	localparam int TRANS_W    = (MAX_DISP <= 0) ? 1 : $clog2(MAX_DISP + 1);

	localparam logic [X_W-1:0]      X_MIN_L     = X_MIN;
	localparam logic [X_W-1:0]      X_MAX_L     = X_MAX;
	localparam logic [DISP_W-1:0]   MAX_DISP_L  = MAX_DISP;
	localparam logic [PHASE_W-1:0]  MAX_PHASE_L = BLOCK_SIZE - 1;

	typedef enum logic [2:0] {
		ST_REQ_LEFT  = 3'd0,
		ST_WAIT_LEFT = 3'd1,
		ST_REQ_RIGHT = 3'd2,
		ST_WAIT_RIGHT= 3'd3,
		ST_EVAL      = 3'd4,
		ST_PRIME     = 3'd5
	} state_t;

	state_t state_q;

	logic [PIXEL_W-1:0] left_col_buf  [0:NUM_SAD_UNITS-1][0:BLOCK_SIZE-1];
	logic [PIXEL_W-1:0] right_col_buf [0:NUM_SAD_UNITS-1][0:BLOCK_SIZE-1];

	logic left_pulse;
	logic right_pulse;

	logic [SAD_W-1:0] sad_value [0:NUM_SAD_UNITS-1];
	logic [SAD_W-1:0] best_sad  [0:NUM_SAD_UNITS-1];
	logic [DISP_W-1:0] best_disp [0:NUM_SAD_UNITS-1];
	logic [DISP_W-1:0] eval_disp;

	logic [X_W-1:0]     cur_x;
	logic [DISP_W-1:0]  cur_d;
	logic [PHASE_W-1:0] cur_phase;
	logic [PHASE_W-1:0] col_idx;

	logic [PRELOAD_W-1:0] preload_issue_count;
	logic [PRELOAD_W-1:0] preload_recv_count;
	logic [PRELOAD_W-1:0] preload_target_count;
	logic preload_full;
	logic [PRIME_W-1:0]   prime_issue_count;
	logic [TRANS_W-1:0]   next_transition;

	logic req_valid_pipe   [0:MEM_RD_LATENCY-1];
	logic req_bank_pipe    [0:MEM_RD_LATENCY-1];
	logic req_use_mem_pipe [0:MEM_RD_LATENCY-1];
	logic [COL_W-1:0]   req_col_pipe   [0:MEM_RD_LATENCY-1];
	logic [PHASE_W-1:0] req_phase_pipe [0:MEM_RD_LATENCY-1];

	logic mature_valid;
	logic mature_bank;
	logic mature_use_mem;
	logic mature_fire;
	logic mature_stall;
	logic [COL_W-1:0] mature_col;
	logic [PHASE_W-1:0] mature_phase;

	logic issue_valid;
	logic issue_bank;
	logic issue_use_mem;
	logic [COL_W-1:0] issue_col;
	logic [PHASE_W-1:0] issue_phase;

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
	integer trans_i;
	integer p;
	logic [SAD_W-1:0] sad_u;
	logic [SAD_W-1:0] next_best_sad_u;
	logic [DISP_W-1:0] next_best_disp_u;
	logic valid_u;

	always_ff @(posedge clk) begin
		if (rst) begin
			state_q <= ST_REQ_LEFT;

			preload_issue_count <= '0;
			preload_recv_count <= '0;
			preload_target_count <= BLOCK_SIZE[PRELOAD_W-1:0];
			preload_full <= 1'b1;
			prime_issue_count <= '0;
			next_transition <= '0;
			col_idx <= '0;

			cur_x <= X_MIN_L;
			cur_d <= '0;
			cur_phase <= '0;

			mem_req <= 1'b0;
			mem_bank <= 1'b0;
			mem_col <= '0;
			left_pulse <= 1'b0;
			right_pulse <= 1'b0;

			for (p = 0; p < MEM_RD_LATENCY; p++) begin
				req_valid_pipe[p] <= 1'b0;
				req_bank_pipe[p] <= 1'b0;
				req_use_mem_pipe[p] <= 1'b0;
				req_col_pipe[p] <= '0;
				req_phase_pipe[p] <= '0;
			end

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
			issue_valid = 1'b0;
			issue_bank = 1'b0;
			issue_use_mem = 1'b0;
			issue_col = '0;
			issue_phase = cur_phase;

			mature_valid = req_valid_pipe[MEM_RD_LATENCY-1];
			mature_bank = req_bank_pipe[MEM_RD_LATENCY-1];
			mature_use_mem = req_use_mem_pipe[MEM_RD_LATENCY-1];
			mature_stall = mature_valid && mature_use_mem && !mem_rvalid;
			mature_fire = mature_valid && ((mature_use_mem == 1'b0) || (mem_rvalid == 1'b1));
			mature_col = req_col_pipe[MEM_RD_LATENCY-1];
			mature_phase = req_phase_pipe[MEM_RD_LATENCY-1];

			left_pulse <= 1'b0;
			right_pulse <= 1'b0;
			mem_req <= 1'b0;
			mem_bank <= 1'b0;
			mem_col <= '0;

			if (mature_fire) begin
				for (u = 0; u < NUM_SAD_UNITS; u++) begin
					for (r = 0; r < BLOCK_SIZE; r++) begin
						y_addr_i = (u * BLOCK_SIZE) + mature_phase - HALF_BLOCK + r;
						if ((y_addr_i >= 0) && (y_addr_i < FRAME_HEIGHT)) begin
							if (mature_use_mem) begin
								if (mature_bank) begin
									right_col_buf[u][r] <= mem_rdata[y_addr_i];
								end else begin
									left_col_buf[u][r] <= mem_rdata[y_addr_i];
								end
							end else begin
								if (mature_bank) begin
									right_col_buf[u][r] <= '0;
								end else begin
									left_col_buf[u][r] <= '0;
								end
							end
						end else begin
							if (mature_bank) begin
								right_col_buf[u][r] <= '0;
							end else begin
								left_col_buf[u][r] <= '0;
							end
						end
					end
				end

				if (mature_bank) begin
					right_pulse <= 1'b1;
				end else begin
					left_pulse <= 1'b1;
				end
			end

			if (!mature_stall) begin
				case (state_q)
					ST_REQ_LEFT: begin
					col_idx <= preload_issue_count[PHASE_W-1:0];
					if (!preload_full) begin
						left_col_i = cur_x - HALF_BLOCK + preload_issue_count;
						issue_valid = 1'b1;
						issue_bank = 1'b0;
						issue_phase = cur_phase;
						if ((left_col_i >= 0) && (left_col_i < HALF_FRAME_WIDTH)) begin
							issue_use_mem = 1'b1;
							issue_col = left_col_i[X_W-1:0];
						end else begin
							issue_use_mem = 1'b0;
							issue_col = '0;
						end
						preload_issue_count <= '0;
						preload_target_count <= 1;
						state_q <= ST_WAIT_LEFT;
					end else begin
						left_col_i = cur_x - HALF_BLOCK + preload_issue_count;
						issue_valid = 1'b1;
						issue_bank = 1'b0;
						issue_phase = cur_phase;
						if ((left_col_i >= 0) && (left_col_i < HALF_FRAME_WIDTH)) begin
							issue_use_mem = 1'b1;
							issue_col = left_col_i[X_W-1:0];
						end else begin
							issue_use_mem = 1'b0;
							issue_col = '0;
						end
						if (preload_issue_count == (BLOCK_SIZE - 1)) begin
							preload_issue_count <= '0;
							preload_target_count <= BLOCK_SIZE[PRELOAD_W-1:0];
							state_q <= ST_WAIT_LEFT;
						end else begin
							preload_issue_count <= preload_issue_count + 1'b1;
						end
					end

					if (mature_fire && (mature_bank == 1'b0) && (preload_recv_count < BLOCK_SIZE)) begin
						preload_recv_count <= preload_recv_count + 1'b1;
					end
					end

					ST_WAIT_LEFT: begin
					col_idx <= '0;
					if (mature_fire && (mature_bank == 1'b0)) begin
						if ((preload_recv_count + 1'b1) == preload_target_count) begin
							preload_recv_count <= '0;
							preload_issue_count <= '0;
							state_q <= ST_REQ_RIGHT;
						end else begin
							preload_recv_count <= preload_recv_count + 1'b1;
						end
					end
					end

					ST_REQ_RIGHT: begin
					col_idx <= preload_issue_count[PHASE_W-1:0];
					if (!preload_full) begin
						right_col_i = cur_x - MAX_DISP - HALF_BLOCK + preload_issue_count;
						issue_valid = 1'b1;
						issue_bank = 1'b1;
						issue_phase = cur_phase;
						if ((right_col_i >= 0) && (right_col_i < HALF_FRAME_WIDTH)) begin
							issue_use_mem = 1'b1;
							issue_col = right_col_i[X_W-1:0];
						end else begin
							issue_use_mem = 1'b0;
							issue_col = '0;
						end
						preload_issue_count <= '0;
						preload_target_count <= 1;
						state_q <= ST_WAIT_RIGHT;
					end else begin
						right_col_i = cur_x - MAX_DISP - HALF_BLOCK + preload_issue_count;
						issue_valid = 1'b1;
						issue_bank = 1'b1;
						issue_phase = cur_phase;
						if ((right_col_i >= 0) && (right_col_i < HALF_FRAME_WIDTH)) begin
							issue_use_mem = 1'b1;
							issue_col = right_col_i[X_W-1:0];
						end else begin
							issue_use_mem = 1'b0;
							issue_col = '0;
						end
						if (preload_issue_count == (BLOCK_SIZE - 1)) begin
							preload_issue_count <= '0;
							preload_target_count <= BLOCK_SIZE[PRELOAD_W-1:0];
							state_q <= ST_WAIT_RIGHT;
						end else begin
							preload_issue_count <= preload_issue_count + 1'b1;
						end
					end

					if (mature_fire && (mature_bank == 1'b1) && (preload_recv_count < BLOCK_SIZE)) begin
						preload_recv_count <= preload_recv_count + 1'b1;
					end
					end

					ST_WAIT_RIGHT: begin
					col_idx <= '0;
					if (mature_fire && (mature_bank == 1'b1)) begin
						if ((preload_recv_count + 1'b1) == preload_target_count) begin
							for (u = 0; u < NUM_SAD_UNITS; u++) begin
								best_sad[u] <= {SAD_W{1'b1}};
								best_disp[u] <= '0;
							end
							cur_d <= '0;
							prime_issue_count <= '0;
							next_transition <= (MAX_DISP >= 1) ? TRANS_W'(1) : '0;
							state_q <= ST_PRIME;
						end else begin
							preload_recv_count <= preload_recv_count + 1'b1;
						end
					end
					end

					ST_PRIME: begin
					col_idx <= '0;
					if (prime_issue_count < MEM_RD_LATENCY) begin
						trans_i = next_transition;
						if (trans_i <= MAX_DISP) begin
							right_col_i = cur_x - MAX_DISP + trans_i + HALF_BLOCK;
							issue_valid = 1'b1;
							issue_bank = 1'b1;
							issue_phase = cur_phase;
							if ((right_col_i >= 0) && (right_col_i < HALF_FRAME_WIDTH)) begin
								issue_use_mem = 1'b1;
								issue_col = right_col_i[X_W-1:0];
							end else begin
								issue_use_mem = 1'b0;
								issue_col = '0;
							end
							next_transition <= next_transition + 1'b1;
						end

						if (prime_issue_count == (MEM_RD_LATENCY - 1)) begin
							prime_issue_count <= '0;
							state_q <= ST_EVAL;
						end else begin
							prime_issue_count <= prime_issue_count + 1'b1;
						end
					end else begin
						state_q <= ST_EVAL;
					end
					end

					ST_EVAL: begin
					col_idx <= '0;
					eval_disp <= MAX_DISP_L - cur_d;

					for (u = 0; u < NUM_SAD_UNITS; u++) begin
						y_center_i = (u * BLOCK_SIZE) + cur_phase;
						valid_u =
							(y_center_i >= HALF_BLOCK)
							&& (y_center_i + HALF_BLOCK < FRAME_HEIGHT)
							&& (cur_x >= X_MIN_L)
							&& (cur_x <= X_MAX_L)
							&& (cur_x >= ((MAX_DISP_L - cur_d) + HALF_BLOCK));

						if (valid_u) begin
							sad_u = sad_value[u];
						end else begin
							sad_u = {SAD_W{1'b1}};
						end

						next_best_sad_u = best_sad[u];
						next_best_disp_u = best_disp[u];

						if ((cur_d == '0) || (sad_u < next_best_sad_u)) begin
							next_best_sad_u = sad_u;
							next_best_disp_u = MAX_DISP_L - cur_d;
						end

						best_sad[u] <= next_best_sad_u;
						best_disp[u] <= next_best_disp_u;

						if ((cur_d == MAX_DISP_L) && valid_u) begin
							disp_map[y_center_i][cur_x] <= disp_to_u8(next_best_disp_u);
						end
					end

					trans_i = cur_d + MEM_RD_LATENCY + 1;
					if (trans_i <= MAX_DISP) begin
						right_col_i = cur_x - MAX_DISP + trans_i + HALF_BLOCK;
						issue_valid = 1'b1;
						issue_bank = 1'b1;
						issue_phase = cur_phase;
						if ((right_col_i >= 0) && (right_col_i < HALF_FRAME_WIDTH)) begin
							issue_use_mem = 1'b1;
							issue_col = right_col_i[X_W-1:0];
						end else begin
							issue_use_mem = 1'b0;
							issue_col = '0;
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

						// if we're wrapping X (cur_x==X_MAX_L) then we changed Y/phase and
						// need a full BLOCK_SIZE preload; otherwise only a single-column
						// preload is required for a per-x shift.
						preload_full <= (cur_x == X_MAX_L) ? 1'b1 : 1'b0;
						preload_issue_count <= '0;
						preload_recv_count <= '0;
						state_q <= ST_REQ_LEFT;
					end else begin
						cur_d <= cur_d + 1'b1;
					end
					end

					default: begin
						state_q <= ST_REQ_LEFT;
					end
				endcase

				mem_bank <= issue_bank;
				mem_col <= issue_col;
				mem_req <= issue_valid && issue_use_mem;

				for (p = MEM_RD_LATENCY - 1; p > 0; p--) begin
					req_valid_pipe[p] <= req_valid_pipe[p-1];
					req_bank_pipe[p] <= req_bank_pipe[p-1];
					req_use_mem_pipe[p] <= req_use_mem_pipe[p-1];
					req_col_pipe[p] <= req_col_pipe[p-1];
					req_phase_pipe[p] <= req_phase_pipe[p-1];
				end

				req_valid_pipe[0] <= issue_valid;
				req_bank_pipe[0] <= issue_bank;
				req_use_mem_pipe[0] <= issue_use_mem;
				req_col_pipe[0] <= issue_col;
				req_phase_pipe[0] <= issue_phase;
			end
		end
	end

endmodule
