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
	logic valid_rd [2:0];


	// issue end is front of pipeline
	logic [PHASE_W-1:0] phase_issue;
	logic [X_W-1:0] col_x_issue;
	logic [DISP_W-1:0] disp_issue;
	logic valid_rd_issue;
	assign phase_issue = phase_pipeline[0];
	assign col_x_issue = col_x_pipeline[0];
	assign disp_issue = disp_pipeline[0];
	assign valid_rd_issue = valid_rd[0];


	// result is back of pipeline
	logic [PHASE_W-1:0] phase_result;
	logic [X_W-1:0] col_x_result;
	logic [DISP_W-1:0] disp_result;
	logic valid_rd_result;
	assign phase_result = phase_pipeline[2];
	assign col_x_result = col_x_pipeline[2];
	assign disp_result = disp_pipeline[2];
	assign valid_rd_result = valid_rd[2];


	logic [PHASE_W-1:0] curr_phase;
	logic [X_W-1:0] curr_col_x;
	logic [DISP_W-1:0] curr_disp;


	always_ff @(posedge clk) begin
		if (rst) begin
			phase_pipeline[0] <= '0;
			col_x_pipeline[0] <= '0;
			disp_pipeline[0] <= '0;
			valid_rd[0]      <= 1'b0;

			phase_pipeline[1] <= '0;
			col_x_pipeline[1] <= '0;
			disp_pipeline[1] <= '0;
			valid_rd[1]      <= 1'b0;
			

			phase_pipeline[2] <= '0;
			col_x_pipeline[2] <= '0;
			disp_pipeline[2] <= '0;
			valid_rd[2]      <= 1'b0;
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
					// Read new column for matching block with x = x + disp
					phase_pipeline[0] <= curr_phase;
					col_x_pipeline[0] <= curr_col_x;
					disp_pipeline[0] <= curr_disp;

					if (valid_rd_result) begin
						right_col_buf[phase_result][col_x_result - curr_disp] <= mem_rdata[phase_result];
						
					end
				end

				INCR_X: begin
				end

				INCR_PHASE: begin
				end

				default:
					assert(0);
				

			
			endcase
		end
	end 

	always_comb begin 
		case (curr_state) 
			INCR_DISP: begin
				if (disp_issue < MAX_DISP_L && disp_issue + x_issue < X_MAX_L) begin
					next_state = INCR_DISP;
					curr_disparity = disp_issue + 1;
				end else begin
					curr_disparity = '0;
					next_state = INCR_X;
				end
			end 
			INCR_X: begin
				if (col_x_issue < X_MAX_L) begin
					next_state = INCR_X;
					curr_x = col_x_issue + 1;
					curr_disparity = '0;
				end else begin
					next_state = INCR_PHASE;
					curr_phase = '0;
				end
			end
			INCR_PHASE: begin
				if (phase_issue < MAX_PHASE_L) begin
					next_state = INCR_PHASE;
					curr_phase = phase_issue + 1;
					curr_x = X_MIN_L;
					curr_disparity = '0;
				end else begin
					next_state = IDLE;
				end
			end
			default:
				assert(0);
		endcase
	end 
endmodule
