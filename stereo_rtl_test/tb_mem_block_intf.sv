`timescale 1ns/1ps

module tb_mem_block_intf #(
	parameter int FRAME_HEIGHT     = 288,
	parameter int HALF_FRAME_WIDTH = 320,
	parameter int BLOCK_SIZE       = 5,
	parameter int PIXEL_W          = 8,
	parameter int MAX_DISP         = 63
);
	localparam int SAD_W            = PIXEL_W + $clog2(BLOCK_SIZE * BLOCK_SIZE);
	localparam int DISP_W           = (MAX_DISP < 1) ? 1 : $clog2(MAX_DISP + 1);
	localparam int NUM_SAD_UNITS    = (FRAME_HEIGHT + BLOCK_SIZE - 1) / BLOCK_SIZE;
	localparam int ROW_W            = (FRAME_HEIGHT <= 1) ? 1 : $clog2(FRAME_HEIGHT);
	localparam int COL_W            = (HALF_FRAME_WIDTH <= 1) ? 1 : $clog2(HALF_FRAME_WIDTH);

	localparam int HALF_BLOCK = BLOCK_SIZE / 2;
	localparam int X_MIN      = HALF_BLOCK;
	localparam int X_MAX      = HALF_FRAME_WIDTH - HALF_BLOCK - 1;
	localparam int X_COUNT    = X_MAX - X_MIN + 1;
	localparam int TOTAL_EVALS = BLOCK_SIZE * X_COUNT * (MAX_DISP + 1);

	logic clk;
	logic rst;

	logic mem_req;
	logic mem_bank;
	logic [COL_W-1:0] mem_col;
	logic [PIXEL_W-1:0] mem_rdata [0:FRAME_HEIGHT-1];
	logic mem_rvalid;

	logic [7:0] disp_map [0:FRAME_HEIGHT-1][0:HALF_FRAME_WIDTH-1];

	logic [PIXEL_W-1:0] left_mem  [0:FRAME_HEIGHT*HALF_FRAME_WIDTH-1];
	logic [PIXEL_W-1:0] right_mem [0:FRAME_HEIGHT*HALF_FRAME_WIDTH-1];

	logic req_q;
	logic bank_q;
	logic [COL_W-1:0] col_q;

	string left_hex_path;
	string right_hex_path;
	string out_hex_path;
	string vcd_path;
	int max_cycles;
	int progress_stride;

	int cycles;
	int eval_count;
	int rst_wait_cycles;
	int rst_cycles;

	function automatic int flat_idx(
		input int row,
		input logic [COL_W-1:0] col
	);
		flat_idx = (row * HALF_FRAME_WIDTH) + col;
	endfunction

	initial begin
		if (!$value$plusargs("VCD=%s", vcd_path)) begin
			vcd_path = "tb_mem_block_intf.vcd";
		end
		$dumpfile(vcd_path);
		$dumpvars(0, tb_mem_block_intf);
		$display("[TB] VCD=%s", vcd_path);
	end

	integer rr;

	initial begin
		if (!$value$plusargs("LEFT_HEX=%s", left_hex_path)) begin
			$error("Missing +LEFT_HEX=<path>");
			$finish;
		end
		if (!$value$plusargs("RIGHT_HEX=%s", right_hex_path)) begin
			$error("Missing +RIGHT_HEX=<path>");
			$finish;
		end
		if (!$value$plusargs("OUT_HEX=%s", out_hex_path)) begin
			$error("Missing +OUT_HEX=<path>");
			$finish;
		end
		if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) begin
			max_cycles = 150000000;
		end
		if (!$value$plusargs("PROGRESS_STRIDE=%d", progress_stride)) begin
			progress_stride = 50000;
		end
		if (!$value$plusargs("RST_CYCLES=%d", rst_cycles)) begin
			rst_cycles = 1;
		end
		if (progress_stride <= 0) begin
			progress_stride = 1000;
		end
		if (rst_cycles <= 0) begin
			rst_cycles = 1;
		end

		$display("[TB] LEFT_HEX=%s", left_hex_path);
		$display("[TB] RIGHT_HEX=%s", right_hex_path);
		$display("[TB] OUT_HEX=%s", out_hex_path);
		$display("[TB] TOTAL_EVALS=%0d", TOTAL_EVALS);
		$display("[TB] MAX_CYCLES=%0d", max_cycles);
		$display("[TB] PROGRESS_STRIDE=%0d", progress_stride);
		$display("[TB] RST_CYCLES=%0d", rst_cycles);
		$readmemh(left_hex_path, left_mem);
		$readmemh(right_hex_path, right_mem);
	end

	initial begin
		clk = 1'b0;
		forever #5 clk = ~clk;
	end

	initial begin
		rst = 1'b1;
		repeat (rst_cycles) @(posedge clk);
		@(negedge clk);
		rst = 1'b0;
		$display("[TB] Reset deasserted by TB at t=%0t", $time);
	end

	always_ff @(posedge clk) begin
		if (rst) begin
			req_q <= 1'b0;
			bank_q <= 1'b0;
			col_q <= '0;
			mem_rvalid <= 1'b0;
			for (rr = 0; rr < FRAME_HEIGHT; rr++) begin
				mem_rdata[rr] <= '0;
			end
		end else begin
			mem_rvalid <= req_q;
			if (req_q) begin
				for (rr = 0; rr < FRAME_HEIGHT; rr++) begin
					if (bank_q) begin
						mem_rdata[rr] <= right_mem[flat_idx(rr, col_q)];
					end else begin
						mem_rdata[rr] <= left_mem[flat_idx(rr, col_q)];
					end
				end
			end else begin
				for (rr = 0; rr < FRAME_HEIGHT; rr++) begin
					mem_rdata[rr] <= '0;
				end
			end

			req_q <= mem_req;
			bank_q <= mem_bank;
			col_q <= mem_col;
		end
	end

	always_ff @(posedge clk) begin
		if (rst) begin
			eval_count <= 0;
		end else if (dut.state_q == 3'd4) begin
			eval_count <= eval_count + 1;
		end
	end

	mem_block_intf #(
		.FRAME_HEIGHT(FRAME_HEIGHT),
		.HALF_FRAME_WIDTH(HALF_FRAME_WIDTH),
		.BLOCK_SIZE(BLOCK_SIZE),
		.PIXEL_W(PIXEL_W),
		.MAX_DISP(MAX_DISP),
		.SAD_W(SAD_W),
		.DISP_W(DISP_W),
		.NUM_SAD_UNITS(NUM_SAD_UNITS),
		.ROW_W(ROW_W),
		.COL_W(COL_W)
	) dut (
		.clk(clk),
		.rst(rst),
		.mem_req(mem_req),
		.mem_bank(mem_bank),
		.mem_col(mem_col),
		.mem_rdata(mem_rdata),
		.mem_rvalid(mem_rvalid),
		.disp_map(disp_map)
	);

	integer fd;
	integer r;
	integer c;
	bit timed_out;
	initial begin
		cycles = 0;
		rst_wait_cycles = 0;
		timed_out = 1'b0;
		$display("[TB] Waiting for reset release...");
		while (rst !== 1'b0) begin
			@(posedge clk);
			rst_wait_cycles = rst_wait_cycles + 1;
			if ((rst_wait_cycles % 1000) == 0) begin
				$display("[TB] still waiting rst=%b wait_cycles=%0d t=%0t", rst, rst_wait_cycles, $time);
			end
			if (rst_wait_cycles > 100000) begin
				$fatal(1, "Reset did not deassert within timeout. rst=%b t=%0t", rst, $time);
			end
		end
		$display("[TB] Reset released at t=%0t", $time);
		$display("[TB] Entering run loop...");

		while ((eval_count < TOTAL_EVALS) && (cycles < max_cycles)) begin
			@(posedge clk);
			cycles = cycles + 1;
			if ((cycles == 1) || ((cycles % progress_stride) == 0) || ((cycles % 1000) == 0)) begin
				$display(
					"[TB] cycles=%0d evals=%0d/%0d req=%0b rvalid=%0b bank=%0b col=%0d state=%0d col_idx=%0d phase=%0d d=%0d x=%0d",
					cycles,
					eval_count,
					TOTAL_EVALS,
					mem_req,
					mem_rvalid,
					mem_bank,
					mem_col,
					dut.state_q,
					dut.col_idx,
					dut.cur_phase,
					dut.cur_d,
					dut.cur_x
				);
			end
		end

		if (eval_count < TOTAL_EVALS) begin
			timed_out = 1'b1;
			$display("[TB] WARNING: Timeout reached, writing partial disparity output.");
		end

		repeat (4) @(posedge clk);

		fd = $fopen(out_hex_path, "w");
		if (fd == 0) begin
			$fatal(1, "Failed to open output file: %s", out_hex_path);
		end

		for (r = 0; r < FRAME_HEIGHT; r++) begin
			for (c = 0; c < HALF_FRAME_WIDTH; c++) begin
				$fdisplay(fd, "%02x", disp_map[r][c]);
			end
		end
		$fclose(fd);

		if (timed_out) begin
			$fatal(1, "Timeout: cycles=%0d evals=%0d/%0d (partial disparity written to %s)", cycles, eval_count, TOTAL_EVALS, out_hex_path);
		end

		$display("[TB] Done: wrote disparity hex to %s", out_hex_path);
		$finish;
	end

endmodule
