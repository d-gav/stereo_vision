// Column Prefetch Controller
//
// Bridges the mem_block_intf (which expects all FRAME_HEIGHT rows of a column
// in one shot via mem_rdata[0:FRAME_HEIGHT-1]) to a single-ported BRAM that
// can only read one address per cycle.
//
// Operation:
//   1. mem_block_intf asserts mem_req with mem_col and mem_bank
//   2. This module asserts `stall` to freeze the mem_block_intf pipeline
//   3. Iterates through rows 0..FRAME_HEIGHT-1, reading from the appropriate
//      BRAM bank one row per cycle
//   4. After all rows read, populates mem_rdata and de-asserts stall
//   5. mem_block_intf pipeline resumes

module column_prefetch #(
	parameter FRAME_HEIGHT     = 288,
	parameter HALF_FRAME_WIDTH = 320,
	parameter PIXEL_W          = 8,
	parameter ADDR_W           = 17,
	parameter ROW_W            = 9,   // clog2(288)
	parameter COL_W            = 9    // clog2(320)
)(
	input wire clk,
	input wire rst,

	// Interface from mem_block_intf
	input  wire             mbi_mem_req,
	input  wire             mbi_mem_bank,  // 0=left, 1=right
	input  wire [COL_W-1:0] mbi_mem_col,
	output reg              stall,

	// Data output to mem_block_intf
	output reg [PIXEL_W-1:0] mem_rdata [0:FRAME_HEIGHT-1],

	// BRAM read ports
	output reg [ADDR_W-1:0] left_rd_addr,
	input  wire [PIXEL_W-1:0] left_rd_data,
	output reg [ADDR_W-1:0] right_rd_addr,
	input  wire [PIXEL_W-1:0] right_rd_data
);

	localparam [1:0] PF_IDLE  = 2'd0;
	localparam [1:0] PF_FETCH = 2'd1;
	localparam [1:0] PF_DONE  = 2'd2;

	reg [1:0]       pf_state;
	reg [ROW_W:0]   row_cnt;     // counts 0..FRAME_HEIGHT (needs extra bit)
	reg [COL_W-1:0] latched_col;
	reg             latched_bank;

	// BRAM read address computation
	// Address = row * HALF_FRAME_WIDTH + col
	wire [ADDR_W-1:0] fetch_addr;
	assign fetch_addr = row_cnt[ROW_W-1:0] * HALF_FRAME_WIDTH + latched_col;

	// Stall is asserted during FETCH and the first cycle of DONE
	// (DONE lets the BRAM output register settle for the last row)
	always @(*) begin
		stall = (pf_state == PF_FETCH) || (pf_state == PF_DONE);
	end

	always @(posedge clk) begin
		if (rst) begin
			pf_state    <= PF_IDLE;
			row_cnt     <= 0;
			latched_col <= 0;
			latched_bank <= 0;
			left_rd_addr  <= 0;
			right_rd_addr <= 0;
		end else begin
			case (pf_state)
				PF_IDLE: begin
					if (mbi_mem_req) begin
						pf_state     <= PF_FETCH;
						latched_col  <= mbi_mem_col;
						latched_bank <= mbi_mem_bank;
						row_cnt      <= 0;
						// Issue first read address
						if (mbi_mem_bank == 1'b0) begin
							left_rd_addr <= mbi_mem_col; // row 0 * 320 + col = col
						end else begin
							right_rd_addr <= mbi_mem_col;
						end
					end
				end

				PF_FETCH: begin
					// Capture data from previous read (BRAM has 1-cycle latency)
					if (row_cnt >= 1) begin
						if (latched_bank == 1'b0) begin
							mem_rdata[row_cnt - 1] <= left_rd_data;
						end else begin
							mem_rdata[row_cnt - 1] <= right_rd_data;
						end
					end

					if (row_cnt == FRAME_HEIGHT) begin
						// All rows have been read (last one captured above)
						pf_state <= PF_DONE;
					end else begin
						// Issue next read
						if (latched_bank == 1'b0) begin
							left_rd_addr <= (row_cnt * HALF_FRAME_WIDTH) + latched_col;
						end else begin
							right_rd_addr <= (row_cnt * HALF_FRAME_WIDTH) + latched_col;
						end
						row_cnt <= row_cnt + 1;
					end
				end

				PF_DONE: begin
					// One extra cycle to let BRAM output register settle
					// for the last row read
					pf_state <= PF_IDLE;
				end

				default: begin
					pf_state <= PF_IDLE;
				end
			endcase
		end
	end

endmodule
