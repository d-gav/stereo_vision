`timescale 1ns/1ps

module tb_mem_block_intf #(
	parameter int FRAME_HEIGHT     = 288,
	parameter int HALF_FRAME_WIDTH = 320,
	parameter int BLOCK_SIZE       = 5,
	parameter int PIXEL_W          = 8,
	parameter int MAX_DISP         = 63,
	parameter int NUM_SAD_UNITS    = FRAME_HEIGHT / BLOCK_SIZE
);
	localparam int SAD_W            = PIXEL_W + $clog2(BLOCK_SIZE * BLOCK_SIZE);
	localparam int DISP_W           = (MAX_DISP < 1) ? 1 : $clog2(MAX_DISP + 1);
	localparam int STRIPE_HEIGHT    = FRAME_HEIGHT / NUM_SAD_UNITS;
	localparam int PHASE_W          = (STRIPE_HEIGHT <= 1) ? 1 : ($clog2(STRIPE_HEIGHT) + 1);
	localparam int ROW_W            = (FRAME_HEIGHT <= 1) ? 1 : $clog2(FRAME_HEIGHT);
	localparam int COL_W            = (HALF_FRAME_WIDTH <= 1) ? 1 : $clog2(HALF_FRAME_WIDTH);

	localparam int HALF_BLOCK = BLOCK_SIZE / 2;
	localparam int X_MIN      = 0;
	localparam int X_MAX      = HALF_FRAME_WIDTH - 1;
	localparam int X_COUNT    = X_MAX - X_MIN + 1;
	localparam int PROBE_U = (NUM_SAD_UNITS > 1) ? (NUM_SAD_UNITS / 2) : 0;
	localparam int PROBE_ROW0 = 0;
	localparam int PROBE_COL0 = 0;
	localparam int PROBE_ROW_MID = FRAME_HEIGHT / 2;
	localparam int PROBE_COL_MID = HALF_FRAME_WIDTH / 2;
	localparam int PROBE_ROW_STRIPE = PROBE_U * STRIPE_HEIGHT;
	localparam int PROBE_COL_STRIPE = HALF_FRAME_WIDTH / 4;
	localparam int PROBE_ROW_LAST = FRAME_HEIGHT - 1;
	localparam int PROBE_COL_LAST = HALF_FRAME_WIDTH - 1;
	localparam logic [DISP_W-1:0] MAX_DISP_L = MAX_DISP;

	logic clk;
	logic rst;
	logic go;

	logic mem_req;
	logic mem_bank;
	logic [COL_W-1:0] mem_col;
	logic [PIXEL_W-1:0] mem_rdata [0:FRAME_HEIGHT-1];

	// NOTE: disp_map is read via hierarchical reference (dut.disp_map) because
	// iverilog does not propagate writes through unpacked-array output ports.

	logic [PIXEL_W-1:0] left_mem  [0:FRAME_HEIGHT*HALF_FRAME_WIDTH-1];
	logic [PIXEL_W-1:0] right_mem [0:FRAME_HEIGHT*HALF_FRAME_WIDTH-1];

	logic req_q0;
	logic bank_q0;
	logic [COL_W-1:0] col_q0;

	string left_hex_path;
	string right_hex_path;
	string out_hex_path;
	string vcd_path;
	logic vcd_enable;
	int max_cycles;
	int progress_stride;

	int cycles;
	int rst_wait_cycles;
	int rst_cycles = 1;
	int rst_cycles_runtime;

	// Probe signals into DUT internals
	logic [DISP_W-1:0] best_disp0_probe;
	logic best_disp0_has_x;
	logic [DISP_W-1:0] best_disp_mid_probe;
	logic best_disp_mid_has_x;
	logic [PHASE_W-1:0] cur_phase_probe;
	logic [COL_W-1:0] cur_x_probe;
	logic [SAD_W-1:0] best_sad_mid_probe;
	logic [SAD_W-1:0] sad_mid_probe;
	logic [7:0] disp00_probe;
	logic disp00_has_x;
	logic [7:0] disp_mid_probe;
	logic disp_mid_has_x;
	logic [7:0] disp_stripe_probe;
	logic disp_stripe_has_x;
	logic [7:0] disp_last_probe;
	logic disp_last_has_x;
	logic started; // tracks whether go has been asserted
	logic done;    // DUT returned to IDLE after processing

	// Pipeline head (stage 0) from DUT
	logic [PHASE_W-1:0]      pipe0_phase;
	logic [COL_W-1:0]        pipe0_col_x;
	logic signed [DISP_W:0]  pipe0_disp;
	logic                    pipe0_valid;
	logic                    pipe0_to_ref;

	assign best_disp0_probe = dut.best_disp[0];
	assign best_disp0_has_x = (^best_disp0_probe === 1'bx);
	assign best_disp_mid_probe = dut.best_disp[PROBE_U];
	assign best_disp_mid_has_x = (^best_disp_mid_probe === 1'bx);
	assign cur_phase_probe = dut.curr_phase;
	assign cur_x_probe = dut.curr_col_x;
	assign best_sad_mid_probe = dut.best_sad[PROBE_U];
	assign sad_mid_probe = dut.sad_value[PROBE_U];
	assign disp00_probe = dut.disp_map[PROBE_ROW0][PROBE_COL0];
	assign disp00_has_x = (^disp00_probe === 1'bx);
	assign disp_mid_probe = dut.disp_map[PROBE_ROW_MID][PROBE_COL_MID];
	assign disp_mid_has_x = (^disp_mid_probe === 1'bx);
	assign disp_stripe_probe = dut.disp_map[PROBE_ROW_STRIPE][PROBE_COL_STRIPE];
	assign disp_stripe_has_x = (^disp_stripe_probe === 1'bx);
	assign disp_last_probe = dut.disp_map[PROBE_ROW_LAST][PROBE_COL_LAST];
	assign disp_last_has_x = (^disp_last_probe === 1'bx);
	assign done = started && (dut.curr_state == 3'd0); // IDLE = 0

	function automatic int flat_idx(
		input int row,
		input logic [COL_W-1:0] col
	);
		flat_idx = (row * HALF_FRAME_WIDTH) + col;
	endfunction

	initial begin
		vcd_enable = 1'b1;
		if ($test$plusargs("NOVCD")) begin
			vcd_enable = 1'b0;
		end
		if (vcd_enable) begin
			if (!$value$plusargs("VCD=%s", vcd_path)) begin
				vcd_path = "tb_mem_block_intf.vcd";
			end
			$dumpfile(vcd_path);
			$dumpvars(0, tb_mem_block_intf);
			$dumpvars(0, best_disp0_probe);
			$dumpvars(0, best_disp0_has_x);
			$dumpvars(0, best_disp_mid_probe);
			$dumpvars(0, best_disp_mid_has_x);
			$dumpvars(0, cur_phase_probe);
			$dumpvars(0, cur_x_probe);
			$dumpvars(0, best_sad_mid_probe);
			$dumpvars(0, sad_mid_probe);
			$dumpvars(0, disp00_probe);
			$dumpvars(0, disp00_has_x);
			$dumpvars(0, disp_mid_probe);
			$dumpvars(0, disp_mid_has_x);
			$dumpvars(0, disp_stripe_probe);
			$dumpvars(0, disp_stripe_has_x);
			$dumpvars(0, disp_last_probe);
			$dumpvars(0, disp_last_has_x);
			$dumpvars(0, pipe0_phase);
			$dumpvars(0, pipe0_col_x);
			$dumpvars(0, pipe0_disp);
			$dumpvars(0, pipe0_valid);
			$dumpvars(0, pipe0_to_ref);
			$display("[TB] VCD=%s", vcd_path);
		end else begin
			$display("[TB] VCD disabled");
		end
		$display("[TB] PROBE_U=%0d", PROBE_U);
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

	// Reset and go sequence
	initial begin
		rst = 1'b1;
		go = 1'b0;
		started = 1'b0;
		rst_cycles_runtime = 1;
		if ($value$plusargs("RST_CYCLES=%d", rst_cycles_runtime)) begin
			if (rst_cycles_runtime <= 0) begin
				rst_cycles_runtime = 1;
			end
		end
		repeat (rst_cycles_runtime) @(posedge clk);
		@(negedge clk);
		rst = 1'b0;
		$display("[TB] Reset deasserted by TB at t=%0t", $time);

		// Assert go for one cycle to start processing
		@(posedge clk);
		go = 1'b1;
		started = 1'b1;
		@(posedge clk);
		go = 1'b0;
		$display("[TB] Go asserted at t=%0t", $time);
	end

	// Memory model: 1-cycle latency from mem_req to mem_rdata
	always_ff @(posedge clk) begin
		if (rst) begin
			req_q0 <= 1'b0;
			bank_q0 <= 1'b0;
			col_q0 <= '0;
			for (rr = 0; rr < FRAME_HEIGHT; rr++) begin
				mem_rdata[rr] <= '0;
			end
		end else begin
			if (req_q0) begin
				for (rr = 0; rr < FRAME_HEIGHT; rr++) begin
					if (bank_q0) begin
						mem_rdata[rr] <= right_mem[flat_idx(rr, col_q0)];
					end else begin
						mem_rdata[rr] <= left_mem[flat_idx(rr, col_q0)];
					end
				end
			end else begin
				for (rr = 0; rr < FRAME_HEIGHT; rr++) begin
					mem_rdata[rr] <= '0;
				end
			end

			req_q0 <= mem_req;
			bank_q0 <= mem_bank;
			col_q0 <= mem_col;
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
		.go(go),
		.mem_req(mem_req),
		.mem_bank(mem_bank),
		.mem_col(mem_col),
		.mem_rdata(mem_rdata),
		.disp_map(),
		.pipe0_phase(pipe0_phase),
		.pipe0_col_x(pipe0_col_x),
		.pipe0_disp(pipe0_disp),
		.pipe0_valid(pipe0_valid),
		.pipe0_to_ref(pipe0_to_ref)
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

		// Wait for go to be asserted
		while (!started) begin
			@(posedge clk);
		end

		// Wait for DUT to leave IDLE (go takes effect)
		while (dut.curr_state == 3'd0) begin
			@(posedge clk);
		end
		$display("[TB] Entering run loop (DUT left IDLE at t=%0t)...", $time);

		// Wait for DUT to return to IDLE (done processing) or timeout
		while ((dut.curr_state != 3'd0) && (cycles < max_cycles)) begin
			@(posedge clk);
			cycles = cycles + 1;
			if ((cycles == 1) || ((cycles % progress_stride) == 0)) begin
				$display(
					"[TB] cycles=%0d req=%0b bank=%0b col=%0d state=%0d phase=%0d x=%0d best_disp0=%0h best_disp_mid=%0h best_sad_mid=%0h sad_mid=%0h",
					cycles,
					mem_req,
					mem_bank,
					mem_col,
					dut.curr_state,
					cur_phase_probe,
					cur_x_probe,
					best_disp0_probe,
					best_disp_mid_probe,
					best_sad_mid_probe,
					sad_mid_probe
				);
			end
		end

		if (dut.curr_state != 3'd0) begin
			timed_out = 1'b1;
			$display("[TB] WARNING: Timeout reached, writing partial disparity output.");
		end else begin
			$display("[TB] DUT returned to IDLE after %0d cycles", cycles);
		end

		repeat (4) @(posedge clk);

		fd = $fopen(out_hex_path, "w");
		if (fd == 0) begin
			$fatal(1, "Failed to open output file: %s", out_hex_path);
		end

		for (r = 0; r < FRAME_HEIGHT; r++) begin
			for (c = 0; c < HALF_FRAME_WIDTH; c++) begin
				$fdisplay(fd, "%02x", dut.disp_map[r][c]);
			end
		end
		$fclose(fd);

		if (timed_out) begin
			$fatal(1, "Timeout: cycles=%0d (partial disparity written to %s)", cycles, out_hex_path);
		end

		$display("[TB] Done: wrote disparity hex to %s", out_hex_path);
		$finish;
	end

endmodule
