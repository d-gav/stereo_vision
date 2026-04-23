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
	output logic [ROW_W-1:0] mem_row,
	output logic [COL_W-1:0] mem_col,
	input  logic [PIXEL_W-1:0] mem_rdata,
	input  logic mem_rvalid,

	output logic [7:0] disp_map [0:FRAME_HEIGHT-1][0:HALF_FRAME_WIDTH-1]
);

	localparam int HALF_BLOCK = BLOCK_SIZE / 2;
	localparam int X_W        = COL_W;
	localparam int Y_W        = ROW_W;
	localparam int PHASE_W    = (BLOCK_SIZE <= 1) ? 1 : $clog2(BLOCK_SIZE);
	localparam int UNIT_W     = (NUM_SAD_UNITS <= 1) ? 1 : $clog2(NUM_SAD_UNITS);
	localparam int X_MIN      = HALF_BLOCK;
	localparam int X_MAX      = HALF_FRAME_WIDTH - HALF_BLOCK - 1;

	localparam logic [X_W-1:0]      X_MIN_L     = X_MIN;
	localparam logic [X_W-1:0]      X_MAX_L     = X_MAX;
	localparam logic [DISP_W-1:0]   MAX_DISP_L  = MAX_DISP;
	localparam logic [PHASE_W-1:0]  MAX_PHASE_L = BLOCK_SIZE - 1;

	logic [SAD_W-1:0] sad_value [0:NUM_SAD_UNITS-1];
	logic [SAD_W-1:0] sad_eval  [0:NUM_SAD_UNITS-1];

	logic [SAD_W-1:0]  best_sad  [0:NUM_SAD_UNITS-1];
	logic [DISP_W-1:0] best_disp [0:NUM_SAD_UNITS-1];

	logic [Y_W-1:0] unit_center_y     [0:NUM_SAD_UNITS-1];
	logic           unit_center_valid [0:NUM_SAD_UNITS-1];


	logic [X_W-1:0]     cur_x; // current x pixel
	logic [DISP_W-1:0]  cur_d; // current disparity for right image
	logic [PHASE_W-1:0] cur_phase; // current row phase
	logic [UNIT_W-1:0]  cur_unit; // current SAD unit
	logic              phase_init_pending;

	logic [PIXEL_W-1:0] left_col_buf  [0:BLOCK_SIZE-1];
	logic [PIXEL_W-1:0] right_col_buf [0:BLOCK_SIZE-1];

	logic [BLOCK_SIZE:0] left_cols_remaining;
	logic [BLOCK_SIZE:0] right_cols_remaining;
	logic [PHASE_W-1:0]  left_col_idx;
	logic [PHASE_W-1:0]  right_col_idx;
	logic [PHASE_W-1:0]  row_idx;
	logic               cur_bank; // 0 = left, 1 = right
	logic               pending_read;
	logic               need_init;

	logic left_pulse;
	logic right_pulse;
	logic eval_pulse;




	genvar g;
	generate
		for (g = 0; g < NUM_SAD_UNITS; g++) begin : GEN_UNIT
			localparam logic [UNIT_W-1:0] G_UNIT = g;
			logic [PIXEL_W-1:0] left_block_g  [0:BLOCK_SIZE-1][0:BLOCK_SIZE-1];
			logic [PIXEL_W-1:0] right_block_g [0:BLOCK_SIZE-1][0:BLOCK_SIZE-1];

			sliding_window #(
				.BLOCK_SIZE(BLOCK_SIZE),
				.PIXEL_W(PIXEL_W)
			) u_ref_window (
				.clk(clk),
				.rst(rst),
				.valid_in(left_pulse && (cur_unit == G_UNIT)),
				.pixel_in_col(left_col_buf),
				.block_out(left_block_g)
			);

			sliding_window #(
				.BLOCK_SIZE(BLOCK_SIZE),
				.PIXEL_W(PIXEL_W)
			) u_match_window (
				.clk(clk),
				.rst(rst),
				.valid_in(right_pulse && (cur_unit == G_UNIT)),
				.pixel_in_col(right_col_buf),
				.block_out(right_block_g)
			);

			block_match_sad #(
				.BLOCK_SIZE(BLOCK_SIZE),
				.PIXEL_W(PIXEL_W),
				.SAD_W(SAD_W)
			) u_block_match_sad (
				.left_block(left_block_g),
				.right_block(right_block_g),
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
	integer y_addr_i;
	integer x_left_col_i;
	integer x_right_col_i;
	logic row_advance;

	always @* begin
		int u_idx;
		int y_center_local;
		logic valid_local;

		// default evals
		for (u_idx = 0; u_idx < NUM_SAD_UNITS; u_idx++) begin
			sad_eval[u_idx] = {SAD_W{1'b1}};
			unit_center_y[u_idx] = '0;
			unit_center_valid[u_idx] = 1'b0;
		end

		if (!rst && (cur_unit < NUM_SAD_UNITS)) begin
			y_center_local = (cur_unit * BLOCK_SIZE) + cur_phase;
			if ((y_center_local >= 0) && (y_center_local < FRAME_HEIGHT)) begin
				unit_center_y[cur_unit] = y_center_local[Y_W-1:0];
			end

			valid_local =
				(y_center_local >= HALF_BLOCK)
				&& (y_center_local + HALF_BLOCK < FRAME_HEIGHT)
				&& (cur_x >= X_MIN_L)
				&& (cur_x <= X_MAX_L)
				&& (cur_x >= (cur_d + HALF_BLOCK));

			unit_center_valid[cur_unit] = valid_local;

			if (valid_local) begin
				sad_eval[cur_unit] = sad_value[cur_unit];
			end
		end
	end

	always_ff @(posedge clk) begin
		if (rst) begin
			// Initialize scan position and control state.
			cur_x <= X_MIN_L;
			cur_d <= '0;
			cur_phase <= '0;
			cur_unit <= '0;
			phase_init_pending <= 1'b1;
			need_init <= 1'b0;

			left_cols_remaining <= BLOCK_SIZE;
			right_cols_remaining <= BLOCK_SIZE;
			left_col_idx <= '0;
			right_col_idx <= '0;
			row_idx <= '0;
			cur_bank <= 1'b0;
			pending_read <= 1'b0;
			mem_req <= 1'b0;
			mem_bank <= 1'b0;
			mem_row <= '0;
			mem_col <= '0;
			left_pulse <= 1'b0;
			right_pulse <= 1'b0;
			eval_pulse <= 1'b0;

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
			left_pulse <= 1'b0;
			right_pulse <= 1'b0;
			eval_pulse <= 1'b0;
			row_advance = 1'b0;
			mem_req <= pending_read;

			// Issue or complete memory reads for column loading.
			if (pending_read) begin
				if (mem_rvalid) begin
					if (cur_bank == 1'b0) begin
						left_col_buf[row_idx] <= mem_rdata;
					end else begin
						right_col_buf[row_idx] <= mem_rdata;
					end
					pending_read <= 1'b0;
					row_advance = 1;
				end
			end else if (left_cols_remaining != 0 || right_cols_remaining != 0) begin
				// Select bank if needed.
				if ((left_cols_remaining != 0) && (cur_bank == 1'b1)) begin
					cur_bank <= 1'b0;
					row_idx <= '0;
				end else if ((right_cols_remaining != 0) && (cur_bank == 1'b0) && (left_cols_remaining == 0)) begin
					cur_bank <= 1'b1;
					row_idx <= '0;
				end

				// Load one row of the active column.
				y_addr_i = (cur_unit * BLOCK_SIZE) + cur_phase - HALF_BLOCK + row_idx;
				if (cur_bank == 1'b0) begin
					if (phase_init_pending && (cur_x == X_MIN_L) && (cur_d == '0)) begin
						x_left_col_i = cur_x - HALF_BLOCK + left_col_idx;
					end else begin
						x_left_col_i = cur_x + HALF_BLOCK;
					end
					if ((y_addr_i >= 0) && (y_addr_i < FRAME_HEIGHT)
						&& (x_left_col_i >= 0) && (x_left_col_i < HALF_FRAME_WIDTH)) begin
						mem_req <= 1'b1;
						mem_bank <= 1'b0;
						mem_row <= y_addr_i[Y_W-1:0];
						mem_col <= x_left_col_i[X_W-1:0];
						pending_read <= 1'b1;
					end else begin
						left_col_buf[row_idx] <= '0;
						row_advance = 1;
					end
				end else begin
					if (phase_init_pending && (cur_x == X_MIN_L) && (cur_d == '0)) begin
						x_right_col_i = (cur_x - cur_d) - HALF_BLOCK + right_col_idx;
					end else begin
						x_right_col_i = (cur_x - cur_d) + HALF_BLOCK;
					end
					if ((y_addr_i >= 0) && (y_addr_i < FRAME_HEIGHT)
						&& (x_right_col_i >= 0) && (x_right_col_i < HALF_FRAME_WIDTH)) begin
						mem_req <= 1'b1;
						mem_bank <= 1'b1;
						mem_row <= y_addr_i[Y_W-1:0];
						mem_col <= x_right_col_i[X_W-1:0];
						pending_read <= 1'b1;
					end else begin
						right_col_buf[row_idx] <= '0;
						row_advance = 1;
					end
				end
			end

			if (row_advance == 1) begin
				if (row_idx == BLOCK_SIZE-1) begin
					row_idx <= '0;
					if (cur_bank == 1'b0) begin
						left_pulse <= 1'b1;
						left_cols_remaining <= left_cols_remaining - 1'b1;
						left_col_idx <= left_col_idx + 1'b1;
					end else begin
						right_pulse <= 1'b1;
						right_cols_remaining <= right_cols_remaining - 1'b1;
						right_col_idx <= right_col_idx + 1'b1;
					end
				end else begin
					row_idx <= row_idx + 1'b1;
				end
			end

			// Setup/evaluate when no column loads are pending.
			if ((left_cols_remaining == 0) && (right_cols_remaining == 0) && !pending_read) begin
				if (need_init) begin
					if (phase_init_pending && (cur_x == X_MIN_L) && (cur_d == '0)) begin
						left_cols_remaining <= BLOCK_SIZE;
						right_cols_remaining <= BLOCK_SIZE;
						cur_bank <= 1'b0;
					end else begin
						left_cols_remaining <= (cur_d == '0) ? 1 : 0;
						right_cols_remaining <= 1;
						cur_bank <= (cur_d == '0) ? 1'b0 : 1'b1;
					end
					left_col_idx <= '0;
					right_col_idx <= '0;
					row_idx <= '0;
					need_init <= 1'b0;
				end else begin
					eval_pulse <= 1'b1;
					need_init <= 1'b1;
				end
			end

			// Evaluate SAD and advance scanning indices.
			if (eval_pulse) begin
				if ((cur_d == '0) || (sad_eval[cur_unit] < best_sad[cur_unit])) begin
					best_sad[cur_unit] <= sad_eval[cur_unit];
					best_disp[cur_unit] <= cur_d;
				end

				if ((cur_d == MAX_DISP_L) && unit_center_valid[cur_unit]) begin
					if ((cur_d == '0) || (sad_eval[cur_unit] < best_sad[cur_unit])) begin
						disp_map[unit_center_y[cur_unit]][cur_x] <= disp_to_u8(cur_d);
					end else begin
						disp_map[unit_center_y[cur_unit]][cur_x] <= disp_to_u8(best_disp[cur_unit]);
					end
				end

				// Advance unit -> disparity -> x -> phase.
				if (cur_unit == NUM_SAD_UNITS-1) begin
					cur_unit <= '0;
					if (cur_d == MAX_DISP_L) begin
						cur_d <= '0;
						if (cur_x == X_MAX_L) begin
							cur_x <= X_MIN_L;
							if (cur_phase == MAX_PHASE_L) begin
								cur_phase <= '0;
								phase_init_pending <= 1'b1;
							end else begin
								cur_phase <= cur_phase + 1'b1;
								phase_init_pending <= 1'b1;
							end
						end else begin
							cur_x <= cur_x + 1'b1;
						end
					end else begin
						cur_d <= cur_d + 1'b1;
					end
				end else begin
					cur_unit <= cur_unit + 1'b1;
				end

				// Clear phase init after all units finish the initial load at x=min, d=0.
				if (phase_init_pending && (cur_unit == NUM_SAD_UNITS-1)
					&& (cur_x == X_MIN_L) && (cur_d == '0)) begin
					phase_init_pending <= 1'b0;
				end
			end
		end
	end

endmodule