module mem_block_intf #(
	parameter int FRAME_HEIGHT     = 288,
	parameter int HALF_FRAME_WIDTH = 320,
	parameter int BLOCK_SIZE       = 5,
	parameter int PIXEL_W          = 8,
	parameter int MAX_DISP         = 85,
	parameter int SAD_W            = PIXEL_W + $clog2(BLOCK_SIZE * BLOCK_SIZE),
	parameter int DISP_W           = (MAX_DISP < 1) ? 1 : $clog2(MAX_DISP + 1),
	parameter int NUM_SAD_UNITS    = 32,
	parameter int ROW_W            = (FRAME_HEIGHT <= 1) ? 1 : $clog2(FRAME_HEIGHT),
	parameter int COL_W            = (HALF_FRAME_WIDTH <= 1) ? 1 : $clog2(HALF_FRAME_WIDTH)
) (
	input logic clk,
	input logic rst,
	input logic go,
	input logic stall,

	output logic mem_req,
	output logic mem_bank, // 0 = left, 1 = right
	output logic [COL_W-1:0] mem_col,
	input  logic [PIXEL_W-1:0] mem_rdata [0:FRAME_HEIGHT-1],

	// Streaming disparity output (one pixel at a time)
	output logic                disp_valid,
	output logic [ROW_W-1:0]    disp_out_y,
	output logic [COL_W-1:0]    disp_out_x,
	output logic [DISP_W-1:0]   disp_out_value,
	input  logic                disp_ack,

	output logic done
);

	localparam int HALF_BLOCK    = BLOCK_SIZE / 2;
	localparam int STRIPE_HEIGHT = FRAME_HEIGHT / NUM_SAD_UNITS;
	localparam int X_W           = COL_W;
	localparam int PHASE_W       = (STRIPE_HEIGHT <= 1) ? 1 : ($clog2(STRIPE_HEIGHT) + 1);
	localparam int X_MIN         = 0;
	localparam int X_MAX         = HALF_FRAME_WIDTH - 1;

	localparam logic [X_W-1:0]      X_MIN_L     = X_MIN;
	localparam logic [X_W-1:0]      X_MAX_L     = X_MAX;
	localparam logic [DISP_W-1:0]   MAX_DISP_L  = MAX_DISP;
	localparam logic [PHASE_W-1:0]  MAX_PHASE_L = STRIPE_HEIGHT - 1;

	localparam [2:0] IDLE       = 3'd0;
	localparam [2:0] INCR_DISP  = 3'd1;  // Inner loop: shift matching block to the right, load single column
	localparam [2:0] INCR_X     = 3'd2;  // Mid loop: shift reference block to the right, write out best disparity for previous x position, load 5 new columns in reference
	localparam [2:0] INCR_PHASE = 3'd3;  // Outer loop: shift both blocks down by one row

	logic [2:0] curr_state;
	logic [2:0] next_state;

	logic [PIXEL_W-1:0] left_col_buf  [0:NUM_SAD_UNITS-1][0:BLOCK_SIZE-1];
	logic [PIXEL_W-1:0] right_col_buf [0:NUM_SAD_UNITS-1][0:BLOCK_SIZE-1];


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

	// Emit mechanism: serialize best_disp results to streaming output
	localparam int UNIT_W = (NUM_SAD_UNITS <= 1) ? 1 : $clog2(NUM_SAD_UNITS);
	logic emit_active;
	logic [UNIT_W-1:0] emit_unit;
	logic [PHASE_W-1:0] emit_phase_lat;
	logic [X_W-1:0] emit_col_x_lat;
	logic [DISP_W-1:0] emit_disp_lat [0:NUM_SAD_UNITS-1];

	// Stall the FSM not only when column_prefetch reports stall (or emit is
	// streaming results), but also for the cycle right after we asserted
	// mem_req. Without that extra gate, the FSM would re-issue the request
	// during the 1-cycle window before column_prefetch's stall actually
	// rises, causing reg_disp to advance twice per honored prefetch and
	// silently desyncing the disparity tag from the column actually fetched.
	wire internal_stall = stall | emit_active | mem_req;

	assign disp_valid = emit_active;
	assign disp_out_x = emit_col_x_lat;
	assign disp_out_y = (emit_unit * STRIPE_HEIGHT) + emit_phase_lat;
	assign disp_out_value = emit_disp_lat[emit_unit];




	//
	// Pipeline for issuing requests and associating them with results 
	//
	// phase: how far down in the Y direction the block is from its starting point
	// col_x: the X coordinate of the reference block 
	// disp: the disparity being evaluated (the x coordinate of the matching block is col_x + disp)
	//

	logic [PHASE_W-1:0] phase_pipeline [2:0];
	logic [X_W-1:0]   col_x_pipeline [2:0];
	logic signed [DISP_W:0] disp_pipeline [2:0];
	logic to_ref_block_pipeline[2:0]; // True if going to ref block, false if going to match block
	logic valid_rd_pipeline [2:0];

	// Done when FSM returns to IDLE after having been started
	logic was_started;
	assign done = was_started && (curr_state == IDLE);



	// Result is the metadata register that was written when the request was
	// issued. Because column_prefetch is a multi-cycle blocking operation
	// (the FSM stalls during the entire prefetch), the request that finishes
	// when stall drops is exactly the request whose metadata is currently
	// sitting in pipeline[0] -- so we read [0], not [2]. The deeper [1]/[2]
	// stages were written for an older single-cycle BRAM model and now serve
	// no purpose; they can be deleted in a follow-up cleanup.
	logic [PHASE_W-1:0] phase_result;
	logic [X_W-1:0] col_x_result;
	logic signed [DISP_W:0] disp_result;
	logic to_ref_block_result;
	logic valid_rd_result;
	assign phase_result = phase_pipeline[0];
	assign col_x_result = col_x_pipeline[0];
	assign disp_result = disp_pipeline[0];
	assign to_ref_block_result = to_ref_block_pipeline[0];
	assign valid_rd_result = valid_rd_pipeline[0];


	logic [PHASE_W-1:0] curr_phase;
	logic [X_W-1:0] curr_col_x;
	logic signed [DISP_W:0] curr_disp;

	// Dedicated registers to track the current loop variables outside the pipeline.
	// These hold the "committed" values of phase/col_x/disp and are the source
	// for the combinational curr_* next-value logic.
	logic [PHASE_W-1:0]     reg_phase;
	logic [X_W-1:0]         reg_col_x;
	logic signed [DISP_W:0] reg_disp;

	logic sad_compare_en; // delayed one cycle after slide_matching so SAD reflects the new window


	//counters to figure out state transitions
	logic [$clog2(BLOCK_SIZE*2+2)-1:0] phase_cnt;
	logic [$clog2(BLOCK_SIZE*2+2)-1:0] phase_cnt_next;
	logic phase_complete; // the reference and matching blocks have shifted in enough rows to fill the block 
	assign phase_complete = (phase_cnt == (BLOCK_SIZE)*2 + 2);
	logic PHASE_match_read; // the cycles where we're still loading rows for the matching block (after we've loaded all rows for the reference block)
	assign PHASE_match_read = (curr_state == INCR_PHASE) && (phase_cnt <= BLOCK_SIZE-1);
	logic PHASE_ref_read; // the cycles where we're loading rows for the reference block
	assign PHASE_ref_read = (curr_state == INCR_PHASE) && (phase_cnt > (BLOCK_SIZE-1) && phase_cnt < (BLOCK_SIZE)*2);

	logic [$clog2(BLOCK_SIZE+4)-1:0] x_cnt;
	logic [$clog2(BLOCK_SIZE+4)-1:0] x_cnt_next;
	logic match_full_x; // the matching block has shifted in enough rows to fill it as well as 1 extra cycle to shift in the new reference block column
	assign match_full_x = (x_cnt == BLOCK_SIZE + 3);

	logic INCR_X_reading_ref; // the cycle where we're loading the last column of the reference block and shifting and already done loading matching block columns
	assign INCR_X_reading_ref = (curr_state == INCR_X) && (x_cnt == (BLOCK_SIZE));
	logic INCR_X_reading_match; // the cycles where we're still loading columns for the matching block
	assign INCR_X_reading_match = (curr_state == INCR_X) && (x_cnt < (BLOCK_SIZE));
	
	

	logic in_disp_bounds;
	assign in_disp_bounds = (reg_disp >= 0)
		&& (reg_disp < $signed({1'b0, MAX_DISP_L}))
		&& ((reg_disp + $signed({1'b0, reg_col_x})) < $signed({1'b0, X_MAX_L}));
	logic [1:0] disp_out_bounds_cnt;

	always_ff @(posedge clk) begin
		if (rst) begin
			curr_state <= IDLE;
			disp_out_bounds_cnt <= 2'b0;
			x_cnt <= '0;
			phase_cnt <= '0;
			sad_compare_en <= 1'b0;
			reg_phase <= '0;
			reg_col_x <= '0;
			reg_disp  <= '0;
			was_started <= 1'b0;
			emit_active <= 1'b0;
			emit_unit <= '0;

			phase_pipeline[0] <= '0;
			col_x_pipeline[0] <= '0;
			disp_pipeline[0] <= '0;
			valid_rd_pipeline[0] <= 1'b0;
			to_ref_block_pipeline[0] <= 1'b0;

			phase_pipeline[1] <= '0;
			col_x_pipeline[1] <= '0;
			disp_pipeline[1] <= '0;
			valid_rd_pipeline[1] <= 1'b0;
			to_ref_block_pipeline[1] <= 1'b0;

			phase_pipeline[2] <= '0;
			col_x_pipeline[2] <= '0;
			disp_pipeline[2] <= '0;
			valid_rd_pipeline[2] <= 1'b0;
			to_ref_block_pipeline[2] <= 1'b0;
		end else begin
			// Default each non-reset cycle: deassert mem_req so the
			// internal_stall (which now includes mem_req) self-releases
			// after one cycle, instead of pinning the FSM forever the way
			// it would if mem_req kept its registered value during stall.
			// The case statement below re-asserts mem_req to 1 only on the
			// cycle a request should actually be issued.
			mem_req <= 1'b0;

			if (emit_active) begin
				// Emit mode: stream results one unit at a time
				if (disp_ack) begin
					if (emit_unit == NUM_SAD_UNITS - 1) begin
						emit_active <= 1'b0;
						emit_unit <= '0;
					end else begin
						emit_unit <= emit_unit + 1;
					end
				end
			end else if (!internal_stall) begin
			// shift pipeline
			phase_pipeline[1] <= phase_pipeline[0];
			col_x_pipeline[1] <= col_x_pipeline[0];
			disp_pipeline[1] <= disp_pipeline[0];
			valid_rd_pipeline[1] <= valid_rd_pipeline[0];
			to_ref_block_pipeline[1] <= to_ref_block_pipeline[0];
			

			phase_pipeline[2] <= phase_pipeline[1];
			col_x_pipeline[2] <= col_x_pipeline[1];
			disp_pipeline[2] <= disp_pipeline[1];
			valid_rd_pipeline[2] <= valid_rd_pipeline[1];
			to_ref_block_pipeline[2] <= to_ref_block_pipeline[1];

			// update FSM state
			curr_state <= next_state;

			// update dedicated loop-variable registers
			reg_phase <= curr_phase;
			reg_col_x <= curr_col_x;
			reg_disp  <= curr_disp;

			// pre assign default values
			mem_req <= 1'b0;
			slide_reference <= 1'b0;
			slide_matching  <= 1'b0;
			sad_compare_en  <= slide_matching; // one-cycle delay: compare SAD after the window has shifted

			valid_rd_pipeline[0] <= 1'b0;

			// Reset best SAD/disparity when starting a new disparity sweep (new x or y)
			if (next_state == INCR_DISP && curr_state != INCR_DISP) begin
				for (int i = 0; i < NUM_SAD_UNITS; i++) begin
					best_sad[i] <= {SAD_W{1'b1}};
					best_disp[i] <= '0;
				end
			end

			// Emit last column's disparity when transitioning from INCR_X to INCR_PHASE
			if (curr_state == INCR_X && next_state == INCR_PHASE) begin
				emit_active <= 1'b1;
				emit_unit <= '0;
				emit_phase_lat <= reg_phase;
				emit_col_x_lat <= reg_col_x;
				for (int i = 0; i < NUM_SAD_UNITS; i++) begin
					emit_disp_lat[i] <= best_disp[i];
				end
			end

			// issue new request
			case(curr_state) 

				IDLE: begin
					phase_pipeline[0] <= '0;
					col_x_pipeline[0] <= '0;
					disp_pipeline[0] <= '0;

					// no read during idle
					valid_rd_pipeline[0] <= 1'b0;

					if (go) begin
						was_started <= 1'b1;
					end
				end



				INCR_DISP: begin
					x_cnt <= x_cnt_next;
					phase_cnt <= phase_cnt_next;
					// Issue memory reads and add to pipeline if we're still within bounds for the current reference block position
					if (in_disp_bounds) begin
						mem_req <= 1'b1;
						mem_bank <= 1'b1; // right block
						mem_col <= $signed({1'b0, reg_col_x}) + reg_disp;

						valid_rd_pipeline[0] <= 1'b1;
						col_x_pipeline[0] <= reg_col_x;
						disp_pipeline[0] <= reg_disp;
						phase_pipeline[0] <= reg_phase;

						
						disp_out_bounds_cnt <= 0;
					end else begin // wait for 2 more cycles to flush out all results for the current reference block position before shifting it
						disp_out_bounds_cnt <= disp_out_bounds_cnt + 1;
					end


					// catch valid memory read and update right block buffer
					if (valid_rd_result) begin
						// write the new column to each compute unit's right block buffer
						for (int g = 0; g < NUM_SAD_UNITS; g++) begin
							for (int rr = 0; rr < BLOCK_SIZE; rr++) begin
								right_col_buf[g][rr] <= mem_rdata[g * STRIPE_HEIGHT + phase_result + rr];
							end
						end
						slide_matching <= 1'b1; 
					end

					// update best SAD and disparity one cycle after slide so window is current
					if (sad_compare_en) begin
						for (int g = 0; g < NUM_SAD_UNITS; g++) begin
							if (sad_value[g] < best_sad[g]) begin
								best_sad[g] <= sad_value[g];
								best_disp[g] <= disp_result;
							end
						end
					end
				end



				INCR_X: begin
					x_cnt <= x_cnt_next;
					if (INCR_X_reading_ref) begin
						// Issue memory reads for new reference block column
						mem_req <= 1'b1;
						mem_bank <= 1'b0; // left block
						mem_col <= reg_col_x;

						col_x_pipeline[0] <= curr_col_x;
						disp_pipeline[0] <= curr_disp - 1;
						phase_pipeline[0] <= curr_phase;
						valid_rd_pipeline[0] <= 1'b1;
						to_ref_block_pipeline[0] <= 1'b1; 
					end
					else if (INCR_X_reading_match) begin
						// Issue memory reads for new matching block column
						mem_req <= 1'b1;
						mem_bank <= 1'b1; // right block
						mem_col <= $signed({1'b0, reg_col_x}) + reg_disp;

						valid_rd_pipeline[0] <= 1'b1;
						col_x_pipeline[0] <= curr_col_x - 1;
						disp_pipeline[0] <= curr_disp - 1;
						phase_pipeline[0] <= curr_phase;
						to_ref_block_pipeline[0] <= 1'b0;
					end

					// catch valid memory read for reference block and update left block buffer
					if (valid_rd_result && to_ref_block_result) begin
						// write the new column to each compute unit's left block buffer
						for (int g = 0; g < NUM_SAD_UNITS; g++) begin
							for (int rr = 0; rr < BLOCK_SIZE; rr++) begin
								left_col_buf[g][rr] <= mem_rdata[g * STRIPE_HEIGHT + phase_result + rr];
							end
						end
						slide_reference <= 1'b1; 

						// Emit best disparity for the previous reference block position
						emit_active <= 1'b1;
						emit_unit <= '0;
						emit_phase_lat <= phase_result;
						emit_col_x_lat <= col_x_result;
						for (int i = 0; i < NUM_SAD_UNITS; i++) begin
							emit_disp_lat[i] <= best_disp[i];
						end

					end else if (valid_rd_result && !to_ref_block_result) begin
						// write the new column to each compute unit's right block buffer
						for (int g = 0; g < NUM_SAD_UNITS; g++) begin
							for (int rr = 0; rr < BLOCK_SIZE; rr++) begin
								right_col_buf[g][rr] <= mem_rdata[g * STRIPE_HEIGHT + phase_result + rr];
							end
						end
						slide_matching <= 1'b1; 


					end


				end



				INCR_PHASE: begin

					phase_cnt <= phase_cnt_next;

					if (PHASE_ref_read) begin
						// Issue memory reads for new reference block row
						mem_req <= 1'b1;
						mem_bank <= 1'b0; // left block
						mem_col <= curr_col_x;

						col_x_pipeline[0] <= curr_col_x - 1;
						disp_pipeline[0] <= curr_disp - 1;
						phase_pipeline[0] <= curr_phase;
						valid_rd_pipeline[0] <= 1'b1;
						to_ref_block_pipeline[0] <= 1'b1; 
					end
					else if (PHASE_match_read) begin
						// Issue memory reads for new matching block row
						mem_req <= 1'b1;
						mem_bank <= 1'b1; // right block
						mem_col <= $signed({1'b0, curr_col_x}) + curr_disp;

						valid_rd_pipeline[0] <= 1'b1;
						col_x_pipeline[0] <= curr_col_x - 1;
						disp_pipeline[0] <= curr_disp - 1;
						phase_pipeline[0] <= curr_phase;
						to_ref_block_pipeline[0] <= 1'b0;
					end else begin
						valid_rd_pipeline[0] <= 1'b0;
					end
					

					// catch valid memory read for reference block and update left block buffer
					if (valid_rd_result && to_ref_block_result) begin
						// write the new column to each compute unit's left block buffer
						for (int g = 0; g < NUM_SAD_UNITS; g++) begin
							for (int rr = 0; rr < BLOCK_SIZE; rr++) begin
								left_col_buf[g][rr] <= mem_rdata[g * STRIPE_HEIGHT + phase_result + rr];
							end
						end
						slide_reference <= 1'b1; 
					end else if (valid_rd_result && !to_ref_block_result) begin
						// write the new column to each compute unit's right block buffer
						for (int g = 0; g < NUM_SAD_UNITS; g++) begin
							for (int rr = 0; rr < BLOCK_SIZE; rr++) begin
								right_col_buf[g][rr] <= mem_rdata[g * STRIPE_HEIGHT + phase_result + rr];
							end
						end
						slide_matching <= 1'b1; 
					end

				end

				default: begin
					// no-op
				end
				

			
			endcase
		end
		end
	end

	always_comb begin
		// Default assignments to prevent latch inference
		next_state     = curr_state;
		curr_disp      = reg_disp;
		curr_col_x     = reg_col_x;
		curr_phase     = reg_phase;
		x_cnt_next     = x_cnt;
		phase_cnt_next = phase_cnt;

		case (curr_state) 
			IDLE: begin
				if (go) begin
					next_state     = INCR_PHASE;
					curr_phase     = '0;
					curr_col_x     = '0;
					curr_disp      = '0;
					phase_cnt_next = 0;
					x_cnt_next     = 0;
				end
			end
			INCR_DISP: begin
				x_cnt_next = 0;
				phase_cnt_next = 0;
				if (in_disp_bounds) begin
					next_state = INCR_DISP;
					curr_disp = reg_disp + 1;
				end else begin
					if (disp_out_bounds_cnt == 2) begin
						next_state = INCR_X;
						curr_disp = '0;
					end else begin
						next_state = INCR_DISP;
						curr_disp = reg_disp; // hold the current disparity for one more cycle while we flush out the results for the last valid disparity
					end
				end
			end 
			INCR_X: begin
				x_cnt_next = x_cnt + 1;
				phase_cnt_next = 0;
				if (reg_col_x < X_MAX_L) begin
					if (match_full_x) begin
						next_state = INCR_DISP;
						curr_col_x = reg_col_x;
						curr_phase = reg_phase;
						curr_disp = '0; // reset disparity to 0 for new reference block position
					end else if (INCR_X_reading_match) begin
						next_state = INCR_X;
						curr_disp = reg_disp + 1;
						curr_col_x = reg_col_x;
					end else if (INCR_X_reading_ref) begin
						next_state = INCR_X;
						curr_col_x = reg_col_x + 1;
						curr_disp = reg_disp;
					end else begin
						next_state = INCR_X;
						curr_phase = reg_phase;
					end
				end else begin
					next_state = INCR_PHASE;
					curr_col_x = '0;
					curr_disp = '0; // reset disparity to -starting value for new reference block position
					curr_phase = reg_phase + 1;
				end
			end
			INCR_PHASE: begin
				phase_cnt_next = phase_cnt + 1;
				if (reg_phase <= MAX_PHASE_L) begin
					if (phase_complete) begin
						next_state = INCR_DISP;
						curr_col_x = BLOCK_SIZE - 1; // reset the current X to be right side of the frame
						curr_disp = '0;
						curr_phase = reg_phase;
					end else begin
						next_state = INCR_PHASE;
						curr_phase = reg_phase;
						if (PHASE_match_read) begin
							curr_disp = reg_disp + 1;
							curr_col_x = reg_col_x;
						end else if (PHASE_ref_read) begin
							curr_disp = '0;
							curr_col_x = reg_col_x + 1;
						end else begin
							next_state = INCR_PHASE;
						end
					end
				end else begin
					next_state = IDLE;
				end
			end
			default: begin
				// no-op
			end
		endcase
	end 
endmodule