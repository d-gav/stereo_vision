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
	localparam int X_MIN      = 0;
	localparam int X_MAX      = HALF_FRAME_WIDTH - 1;

	localparam logic [X_W-1:0]      X_MIN_L     = X_MIN;
	localparam logic [X_W-1:0]      X_MAX_L     = X_MAX;
	localparam logic [DISP_W-1:0]   MAX_DISP_L  = MAX_DISP;
	localparam logic [PHASE_W-1:0]  MAX_PHASE_L = FRAME_HEIGHT/NUM_SAD_UNITS - 1;

	typedef enum logic [2:0] {
		IDLE,                  //
		INCR_DISP,             // Inner loop: shift matching block to the right, load single column
		INCR_X,                // Mid loop: shift reference block to the right, write out best disparity for previous x position, load 5 new columns in reference 
		INCR_PHASE,            // Outer loop: shift both blocks down by one row
	} state_t;

	state_t curr_state;
	state_t next_state;

	logic [PIXEL_W-1:0] left_col_buf  [0:NUM_SAD_UNITS-1][0:BLOCK_SIZE-1];
	logic [PIXEL_W-1:0] right_col_buf [0:NUM_SAD_UNITS-1][0:BLOCK_SIZE-1];

	logic left_pulse;
	logic right_pulse;

	logic [SAD_W-1:0] sad_value [0:NUM_SAD_UNITS-1];
	logic [SAD_W-1:0] best_sad  [0:NUM_SAD_UNITS-1];
	logic [DISP_W-1:0] best_disp [0:NUM_SAD_UNITS-1];


	logic slide_reference;
	logic slide_matching;

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
				.valid_in(slide_reference),
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
				.valid_in(slide_matching),
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




	//
	// Pipeline for issuing requests and associating them with results 
	//
	// phase: how far down in the Y direction the block is from its starting point
	// col_x: the X coordinate of the reference block 
	// disp: the disparity being evaluated (the x coordinate of the matching block is col_x + disp)
	//

	logic [PHASE_W-1:0] phase_pipeline [2:0];
	logic [X_W-1:0]   col_x_pipeline [2:0];
	logic [DISP_W-1:0] disp_pipeline [2:0];
	logic to_ref_block_pipeline[2:0]; // True if going to ref block, false if going to match block
	logic valid_rd_pipeline [2:0];



	// result is back of pipeline
	logic [PHASE_W-1:0] phase_result;
	logic [X_W-1:0] col_x_result;
	logic [DISP_W-1:0] disp_result;
	logic to_ref_block_result;
	logic valid_rd_result;
	assign phase_result = phase_pipeline[2];
	assign col_x_result = col_x_pipeline[2];
	assign disp_result = disp_pipeline[2];
	assign to_ref_block_result = to_ref_block_pipeline[2];
	assign valid_rd_result = valid_rd_pipeline[2];


	logic [PHASE_W-1:0] curr_phase;
	logic [X_W-1:0] curr_col_x;
	logic [DISP_W-1:0] curr_disp;


	//counters to figure out state transitions
	logic [$clog2(BLOCK_SIZE*2-1)-1:0] phase_cnt;
	logic [$clog2(BLOCK_SIZE*2-1)-1:0] phase_cnt_next;
	logic phase_complete = (phase_cnt == (BLOCK_SIZE)*2 + 1) ; // the reference and matching blocks have shifted in enough rows to fill the block 
	logic PHASE_match_read = (curr_state == INCR_PHASE) && (phase_cnt < BLOCK_SIZE); // the cycles where we're still loading rows for the matching block (after we've loaded all rows for the reference block)
	logic PHASE_ref_read = (curr_state == INCR_PHASE) && (phase_cnt >= BLOCK_SIZE && phase_cnt < (BLOCK_SIZE)*2	) && !PHASE_match_read; // the cycles where we're loading rows for the reference block

	logic [$clog2(BLOCK_SIZE+1)-1:0] x_cnt;
	logic [$clog2(BLOCK_SIZE+1)-1:0] x_cnt_next;
	logic match_full_x = (x_cnt == BLOCK_SIZE) + 2; // the matching block has shifted in enough rows to fill it as well as 1 extra cycle to shift in the new reference block column

	logic INCR_x_reading_ref = (curr_state == INCR_X) && (x_cnt == BLOCK_SIZE-1); // the cycle where we're loading the last column of the reference block and shifting and already done loading matching block columns
	logic INCR_X_reading_match = (curr_state == INCR_X) && (x_cnt < BLOCK_SIZE-1); // the cycles where we're still loading columns for the matching block
	
	

	logic in_disp_bounds = (disp_pipeline[0] < MAX_DISP_L) && ((disp_pipeline[0] + col_x_pipeline[0]) < X_MAX_L);
	logic [1:0] disp_out_bounds_cnt;

	always_ff @(posedge clk) begin
		if (rst) begin
			phase_pipeline[0] <= '0;
			col_x_pipeline[0] <= '0;
			disp_pipeline[0] <= '0;
			valid_rd_pipeline[0]      <= 1'b0;

			phase_pipeline[1] <= '0;
			col_x_pipeline[1] <= '0;
			disp_pipeline[1] <= '0;
			valid_rd_pipeline[1]      <= 1'b0;
			

			phase_pipeline[2] <= '0;
			col_x_pipeline[2] <= '0;
			disp_pipeline[2] <= '0;
			valid_rd_pipeline[2]      <= 1'b0;
		end else begin
			// shift pipeline
			phase_pipeline[1] <= phase_pipeline[0];
			col_x_pipeline[1] <= col_x_pipeline[0];
			disp_pipeline[1] <= disp_pipeline[0];

			phase_pipeline[2] <= phase_pipeline[1];
			col_x_pipeline[2] <= col_x_pipeline[1];
			disp_pipeline[2] <= disp_pipeline[1];

			// update FSM state
			curr_state <= next_state;


			// pre assign default values
			mem_req <= 1'b0;


			phase_pipeline[0] <= phase_pipeline[0]; // default to holding the current value in the pipeline
			col_x_pipeline[0] <= col_x_pipeline[0];
			disp_pipeline[0] <= ;
			valid_rd_pipeline[0] <= 1'b0;

			// issue new request
			case(curr_state) 

				IDLE: begin
					phase_pipeline[0] <= '0;
					col_x_pipeline[0] <= '0;
					disp_pipeline[0] <= '0;

					// no read during idle
					valid_rd[0]      <= 1'b0;

				end



				INCR_DISP: begin
					x_cnt <= 0; // reset x counter for new disparity
					phase_cnt <= 0; // reset phase counter for new disparity
					// Issue memory reads and add to pipeline if we're still within bounds for the current reference block position
					if (in_disp_bounds) begin
						mem_req <= 1'b1;
						mem_bank <= 1'b1; // right block
						mem_col <= col_x_pipeline[0] + disp_pipeline[0];

						valid_rd_pipeline[0] <= 1'b1;
						col_x_pipeline[0] <= curr_col_x;
						disp_pipeline[0] <= curr_disp;
						phase_pipeline[0] <= curr_phase;

						
						disp_out_bounds_cnt <= 0;
					end else begin // wait for 2 more cycles to flush out all results for the current reference block position before shifting it
						disp_out_bounds_cnt <= disp_out_bounds_cnt + 1;
					end


					// catch valid memory read and update right block buffer
					if (valid_rd_result) begin
						// write the new column to the appropriate place in the right block buffer
						right_col_buf[phase_result][col_x_result - curr_disp] <= mem_rdata[phase_result];
						slide_matching <= 1'b1; 

						// update best SAD and disparity
						if (sad_value[phase_result] < best_sad[phase_result]) begin
							best_sad[phase_result] <= sad_value[phase_result];
							best_disp[phase_result] <= disp_result;
						end
					end
				end



				INCR_X: begin

					x_cnt <= x_cnt_next;

					if (INCR_X_reading_ref) begin
						// Issue memory reads for new reference block column
						mem_req <= 1'b1;
						mem_bank <= 1'b0; // left block
						mem_col <= col_x_pipeline[0];

						col_x_pipeline[0] <= curr_col_x;
						disp_pipeline[0] <= curr_disp;
						phase_pipeline[0] <= curr_phase;
						valid_rd_pipeline[0] <= 1'b1;
						to_ref_block_pipeline[0] <= 1'b1; 
					end
					else if (INCR_X_reading_match) begin
						// Issue memory reads for new matching block column
						mem_req <= 1'b1;
						mem_bank <= 1'b1; // right block
						mem_col <= col_x_pipeline[0] + disp_pipeline[0];

						valid_rd_pipeline[0] <= 1'b1;
						col_x_pipeline[0] <= curr_col_x;
						disp_pipeline[0] <= curr_disp;
						phase_pipeline[0] <= curr_phase;
						to_ref_block_pipeline[0] <= 1'b0;
					end

					// catch valid memory read for reference block and update left block buffer
					if (valid_rd_result && to_ref_block_result) begin
						// write the new column to the appropriate place in the left block buffer
						left_col_buf[phase_result][col_x_result] <= mem_rdata[phase_result];
						slide_reference <= 1'b1; 

						// update disparity map with best disparity at (x, y) for the previous reference block position
						for (int i = 0; i < NUM_SAD_UNITS; i++) begin
							disp_map[phase_result + i * MAX_PHASE_L][col_x_result] <= disp_to_u8(best_disp[i]);
						end

					end else if (valid_rd_result && !to_ref_block_result) begin
						// write the new column to the appropriate place in the right block buffer
						right_col_buf[phase_result][col_x_result - curr_disp] <= mem_rdata[phase_result];
						slide_matching <= 1'b1; 


					end


				end



				INCR_PHASE: begin

					phase_cnt <= phase_cnt_next;

					if (INCR_PHASE_reading_ref) begin
						// Issue memory reads for new reference block row
						mem_req <= 1'b1;
						mem_bank <= 1'b0; // left block
						mem_col <= col_x_pipeline[0];

						col_x_pipeline[0] <= curr_col_x;
						disp_pipeline[0] <= curr_disp;
						phase_pipeline[0] <= curr_phase;
						valid_rd_pipeline[0] <= 1'b1;
						to_ref_block_pipeline[0] <= 1'b1; 
					end
					else if (INCR_PHASE_reading_match) begin
						// Issue memory reads for new matching block row
						mem_req <= 1'b1;
						mem_bank <= 1'b1; // right block
						mem_col <= col_x_pipeline[0] + disp_pipeline[0];

						valid_rd_pipeline[0] <= 1'b1;
						col_x_pipeline[0] <= curr_col_x;
						disp_pipeline[0] <= curr_disp;
						phase_pipeline[0] <= curr_phase;
						to_ref_block_pipeline[0] <= 1'b0;
					end

					// catch valid memory read for reference block and update left block buffer
					if (valid_rd_result && to_ref_block_result) begin
						// write the new row to the appropriate place in the left block buffer
						left_col_buf[phase_result][col_x_result] <= mem_rdata[phase_result];
						slide_reference <= 1'b1; 
					end else if (valid_rd_result && !to_ref_block_result) begin
						// write the new row to the appropriate place in the right block buffer
						right_col_buf[phase_result][col_x_result - curr_disp] <= mem_rdata[phase_result];
						slide_matching <= 1'b1; 
					end

				end

				default:
					assert(0);
				

			
			endcase
		end
	end 

	always_comb begin 
		case (curr_state) 
			INCR_DISP: begin
				//TOTDO: Add all combinational values for things that stay the same in the state
				if (in_disp_bounds) begin
					next_state = INCR_DISP;
					curr_disp = disp_pipeline[0] + 1;
				end else begin
					curr_disp = '0;
					next_state = (disp_out_bounds_cnt == 2) ? INCR_X : INCR_DISP; // wait for 2 more cycles to flush out all results for the current reference block position before shifting it
					x_cnt_next = 0;
					phase_cnt_next = 0;
				end
			end 
			INCR_X: begin

				x_cnt_next = x_cnt + 1;

				if (col_x_pipeline[0] < X_MAX_L) begin
					if (match_full_x) begin
						next_state = INCR_DISP;
						curr_col_x = col_x_pipeline[0] + 1;
						curr_phase = phase_pipeline[0];
						curr_disp = '0; // reset disparity to 0 for new reference block position
					end else if (INCR_X_reading_match) begin
						curr_disp = disp_pipeline[0] + 1;
						curr_col_x = col_x_pipeline[0];
					end else if (INCR_X_reading_ref) begin
						curr_col_x = col_x_pipeline[0] + 1;
						curr_disp = disp_pipeline[0]; //I think here I need to also reset disparity to 0
					end else begin
						next_state = INCR_X;
						curr_phase = phase_pipeline[0];
					end
				end else begin
					next_state = INCR_PHASE;
					curr_col_x = '0;
					curr_disp = '0; // reset disparity to 0 for new reference block position
					curr_phase = phase_pipeline[0] + 1;
				end
			end
			INCR_PHASE: begin
				if (phase_pipeline[0] < MAX_PHASE_L) begin
					if (phase_complete) begin
						next_state = INCR_DISP;
						curr_col_x = BLOCK_SIZE - 1; // reset the current X to be right side of the frame
						curr_disp = '0; // reset disparity to 0 for new reference block position
						curr_phase = phase_pipeline[0];
					end else begin
						next_state = INCR_PHASE;
						curr_phase = phase_pipeline[0];
						if (PHASE_match_read) begin
							curr_disp = disp_pipeline[0] + 1;
							curr_col_x = col_x_pipeline[0];
						end else if (PHASE_ref_read) begin
							curr_disp = '0;
							curr_col_x = col_x_pipeline[0] + 1;
						end
					end
				end else begin
					next_state = IDLE;
				end
			end
			default:
				assert(0);
		endcase
	end 
endmodule
