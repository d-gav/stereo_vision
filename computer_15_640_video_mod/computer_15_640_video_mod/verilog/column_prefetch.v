// Column Prefetch Controller (Single Combined BRAM version)
//
// Bridges the mem_block_intf (which expects all FRAME_HEIGHT rows of a column
// in one shot via mem_rdata[0:FRAME_HEIGHT-1]) to a single-ported BRAM that
// can only read one address per cycle.
//
// BRAM layout: 640 bytes per row (left cols 0..319, right cols 320..639)
// Left column C, row R  → address = R * FULL_ROW_WIDTH + C
// Right column C, row R → address = R * FULL_ROW_WIDTH + HALF_FRAME_WIDTH + C

module column_prefetch #(
	parameter FRAME_HEIGHT     = 200,
	parameter HALF_FRAME_WIDTH = 320,
	parameter FULL_ROW_WIDTH   = 640,
	parameter PIXEL_W          = 8,
	parameter ADDR_W           = 17,
	parameter ROW_W            = 8,   // clog2(200)
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

	// Single combined BRAM read port
	output reg  [ADDR_W-1:0] bram_rd_addr,
	input  wire [PIXEL_W-1:0] bram_rd_data
);

	localparam [1:0] PF_IDLE  = 2'd0;
	localparam [1:0] PF_FETCH = 2'd1;
	localparam [1:0] PF_DONE  = 2'd2;

	reg [1:0]       pf_state;
	reg [ROW_W:0]   row_cnt;     // counts 0..FRAME_HEIGHT (needs extra bit)
	reg [COL_W-1:0] latched_col;
	reg             latched_bank;

	// Base column offset: left=col, right=HALF_FRAME_WIDTH+col
	wire [ADDR_W-1:0] col_base = latched_bank ?
		(latched_col + HALF_FRAME_WIDTH) : {1'b0, latched_col};

	// Stall is asserted during FETCH and DONE
	always @(*) begin
		stall = (pf_state == PF_FETCH) || (pf_state == PF_DONE);
	end

	always @(posedge clk) begin
		if (rst) begin
			pf_state    <= PF_IDLE;
			row_cnt     <= 0;
			latched_col <= 0;
			latched_bank <= 0;
			bram_rd_addr <= 0;
		end else begin
			case (pf_state)
				PF_IDLE: begin
					if (mbi_mem_req) begin
						pf_state     <= PF_FETCH;
						latched_col  <= mbi_mem_col;
						latched_bank <= mbi_mem_bank;
						row_cnt      <= 0;
						// Issue first read: row 0
						if (mbi_mem_bank == 1'b0)
							bram_rd_addr <= mbi_mem_col; // 0 * 640 + col
						else
							bram_rd_addr <= HALF_FRAME_WIDTH + mbi_mem_col; // 0 * 640 + 320 + col
					end
				end

				PF_FETCH: begin
					// Capture data from previous read (BRAM has 1-cycle latency)
					if (row_cnt >= 1) begin
						mem_rdata[row_cnt - 1] <= bram_rd_data;
					end

					if (row_cnt == FRAME_HEIGHT) begin
						// All rows captured (last row written this cycle from row_cnt-1 = FRAME_HEIGHT-1)
						pf_state <= PF_DONE;
					end else begin
						// PF_IDLE already issued row 0; issue (row_cnt + 1) here so
						// the address pipeline stays in lockstep with the data pipeline.
						// Skip the issue when (row_cnt + 1) would be out of range so the
						// last row's read (row_cnt = FRAME_HEIGHT-1) still gets captured
						// next cycle.
						if ((row_cnt + 1) < FRAME_HEIGHT) begin
							bram_rd_addr <= ((row_cnt + 1) * FULL_ROW_WIDTH) + col_base;
						end
						row_cnt <= row_cnt + 1;
					end
				end

				PF_DONE: begin
					pf_state <= PF_IDLE;
				end

				default: begin
					pf_state <= PF_IDLE;
				end
			endcase
		end
	end

endmodule
