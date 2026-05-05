// =============================================================================
// fill_pipe_controller
//
// Streaming PHASE_FILL controller. Replaces the per-pixel sequential FSM that
// used to live in DE1_SoC_Computer.v with a pipelined dataflow:
//
//   coord-gen -> stereo_radial_mapper_q15_pipe (11 stages, 1 px/cycle)
//             -> small FIFO  -> bus issuer  -> BRAM write + VGA write
//
// The mapper's 11-cycle latency is hidden because successive pixels are in
// flight simultaneously. Per-pixel cost is bounded below by the bus
// round-trips: one read of camera SRAM + one write to VGA, at single-trans.
//
// "go" starts a frame fill. After the entire 640 x FRAME_HEIGHT grid has
// been written into the destination BRAM and to VGA, "done" pulses HIGH for
// one cycle. While "go" stays high after done, no new frame starts (the
// top-level drops "go" between frames as it sequences PHASE_FILL ->
// PHASE_COMPUTE -> PHASE_FILL).
// =============================================================================

module fill_pipe_controller #(
    parameter integer FULL_FRAME_WIDTH      = 640,
    parameter integer FRAME_HEIGHT          = 200,
    parameter integer FULL_ROW_WIDTH        = 640,
    parameter integer Y_CROP_OFFSET         = 44,
    parameter integer HALF_FRAME_WIDTH      = 320,
    parameter integer LEFT_LUT_WIDTH        = 315,
    parameter integer INTER_CAMERA_GAP      = 4,
    parameter integer RIGHT_OUTPUT_X_START  = LEFT_LUT_WIDTH + INTER_CAMERA_GAP,
    parameter integer BRAM_ADDR_W           = 17,
    parameter integer MAPPER_LATENCY        = 11
) (
    input  wire                       clk,
    input  wire                       reset_n,
    input  wire                       go,            // hold high to run a frame fill

    // Avalon master (shared via top-level mux). The controller drives one of
    // {camera-SRAM read, VGA write} per transaction.
    output reg  [31:0]                bus_addr,
    output reg                        bus_read,
    output reg                        bus_write,
    output reg  [3:0]                 bus_byte_enable,
    output reg  [31:0]                bus_write_data,
    input  wire [31:0]                bus_read_data,
    input  wire                       bus_ack,

    // BRAM write port (stereo_bram, single port)
    output reg                        bram_wr_en,
    output reg  [BRAM_ADDR_W-1:0]     bram_wr_addr,
    output reg  [7:0]                 bram_wr_data,

    output reg                        done
);

    // ---- Bus base addresses (must match top-level Qsys mapping) ----
    localparam [31:0] VIDEO_IN_BASE = 32'h0800_0000;
    localparam [31:0] VGA_OUT_BASE  = 32'h0000_0000;

    // ====================================================================
    // 1) Coordinate generator -- advances every cycle while feeding mapper.
    //    "feeding" is gated by FIFO backpressure to avoid losing outputs.
    // ====================================================================
    reg [9:0]  dst_x;
    reg [9:0]  dst_y;
    reg        streaming;        // 1 while we are still feeding the mapper
    reg        last_submitted;   // we have issued the last pixel into the mapper
    wire       can_feed;
    wire       at_last_pixel = (dst_x == FULL_FRAME_WIDTH-1) &&
                                (dst_y == FRAME_HEIGHT-1);

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            dst_x          <= 10'd0;
            dst_y          <= 10'd0;
            streaming      <= 1'b0;
            last_submitted <= 1'b0;
        end else begin
            if (go && !streaming && !last_submitted) begin
                // Begin a new frame from (0, 0).
                dst_x          <= 10'd0;
                dst_y          <= 10'd0;
                streaming      <= 1'b1;
                last_submitted <= 1'b0;
            end else if (streaming && can_feed) begin
                if (at_last_pixel) begin
                    last_submitted <= 1'b1;
                    streaming      <= 1'b0;   // stop feeding; pipeline drains
                end else if (dst_x == FULL_FRAME_WIDTH-1) begin
                    dst_x <= 10'd0;
                    dst_y <= dst_y + 10'd1;
                end else begin
                    dst_x <= dst_x + 10'd1;
                end
            end else if (frame_complete) begin
                last_submitted <= 1'b0;
            end
        end
    end

    // ====================================================================
    // 2) Pipelined radial mapper. 11-stage, 1 px/cycle throughput.
    // ====================================================================
    wire [9:0] mapper_dst_y_in = dst_y + Y_CROP_OFFSET[9:0];
    wire       mapper_valid_in = streaming && can_feed;
    wire [9:0] mapper_src_x;
    wire [9:0] mapper_src_y;
    wire       mapper_valid_out;

    stereo_radial_mapper_q15_pipe u_mapper (
        .clk      (clk),
        .reset_n  (reset_n),
        .valid_in (mapper_valid_in),
        .dst_x    (dst_x),
        .dst_y    (mapper_dst_y_in),
        .src_x    (mapper_src_x),
        .src_y    (mapper_src_y),
        .valid_out(mapper_valid_out)
    );

    // ====================================================================
    // 3) Delay (dst_x, dst_y, mapper_valid_in) by MAPPER_LATENCY cycles to
    //    line up with the mapper's output for the same pixel.
    // ====================================================================
    reg [9:0] dl_dst_x [0:MAPPER_LATENCY-1];
    reg [9:0] dl_dst_y [0:MAPPER_LATENCY-1];
    reg       dl_valid [0:MAPPER_LATENCY-1];

    integer i;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            for (i = 0; i < MAPPER_LATENCY; i = i + 1) begin
                dl_dst_x[i] <= 10'd0;
                dl_dst_y[i] <= 10'd0;
                dl_valid[i] <= 1'b0;
            end
        end else begin
            dl_dst_x[0] <= dst_x;
            dl_dst_y[0] <= dst_y;
            dl_valid[0] <= mapper_valid_in;
            for (i = 1; i < MAPPER_LATENCY; i = i + 1) begin
                dl_dst_x[i] <= dl_dst_x[i-1];
                dl_dst_y[i] <= dl_dst_y[i-1];
                dl_valid[i] <= dl_valid[i-1];
            end
        end
    end

    wire [9:0] aligned_dst_x      = dl_dst_x[MAPPER_LATENCY-1];
    wire [9:0] aligned_dst_y      = dl_dst_y[MAPPER_LATENCY-1];
    wire       aligned_was_valid  = dl_valid[MAPPER_LATENCY-1];

    // ====================================================================
    // 4) FIFO between mapper output and bus consumer.
    //    Each entry holds the full request: dst_x (10) + dst_y (10) +
    //    src_x (10) + src_y (10) + in_bounds (1) = 41 bits.
    //
    //    HIGH_WATER must leave room for MAPPER_LATENCY in-flight pixels
    //    (already past the can_feed gate) plus a few cycles of margin so
    //    the FIFO never wraps. Otherwise entries get silently overwritten,
    //    which manifests as vertical stripes in the disparity output.
    // ====================================================================
    localparam FIFO_DEPTH_LOG2 = 5;                                 // 32 entries
    localparam FIFO_DEPTH      = (1 << FIFO_DEPTH_LOG2);
    localparam FIFO_HIGH_WATER = FIFO_DEPTH - MAPPER_LATENCY - 4;   // 17

    reg [40:0] fifo_mem [0:FIFO_DEPTH-1];
    reg [FIFO_DEPTH_LOG2-1:0] fifo_wr_ptr;
    reg [FIFO_DEPTH_LOG2-1:0] fifo_rd_ptr;
    reg [FIFO_DEPTH_LOG2:0]   fifo_count;
    wire fifo_full  = (fifo_count >= FIFO_HIGH_WATER);
    wire fifo_empty = (fifo_count == 0);

    wire fifo_push = aligned_was_valid;
    wire fifo_pop;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            fifo_wr_ptr <= 0;
            fifo_rd_ptr <= 0;
            fifo_count  <= 0;
        end else begin
            if (fifo_push) begin
                fifo_mem[fifo_wr_ptr] <= {aligned_dst_x, aligned_dst_y,
                                         mapper_src_x, mapper_src_y,
                                         mapper_valid_out};
                fifo_wr_ptr <= fifo_wr_ptr + 1'b1;
            end
            if (fifo_pop) begin
                fifo_rd_ptr <= fifo_rd_ptr + 1'b1;
            end
            case ({fifo_push, fifo_pop})
                2'b10:   fifo_count <= fifo_count + 1'b1;
                2'b01:   fifo_count <= fifo_count - 1'b1;
                default: fifo_count <= fifo_count;
            endcase
        end
    end

    assign can_feed = streaming && !fifo_full;

    // Read FIFO head (combinational).
    wire [40:0] head_word    = fifo_mem[fifo_rd_ptr];
    wire [9:0]  head_dst_x   = head_word[40:31];
    wire [9:0]  head_dst_y   = head_word[30:21];
    wire [9:0]  head_src_x   = head_word[20:11];
    wire [9:0]  head_src_y   = head_word[10:1];
    wire        head_inbnd   = head_word[0];

    // ====================================================================
    // 5) Address translations
    // ====================================================================
    function [31:0] cam_byte_addr;
        input [9:0] sx;
        input [9:0] sy;
    begin
        cam_byte_addr = VIDEO_IN_BASE + {22'b0, sx} + ({22'b0, sy} << 10);
    end
    endfunction

    function [31:0] vga_byte_addr;
        input [9:0] dx;
        input [9:0] dy;
    begin
        // VGA buffer: row-major, 1024-byte stride. (dx, dy) of (0..639, 0..199)
        // map directly to (col, row) on the upper half of VGA.
        vga_byte_addr = VGA_OUT_BASE + {22'b0, dx} + ({22'b0, dy} << 10);
    end
    endfunction

    function [BRAM_ADDR_W-1:0] bram_byte_addr;
        input [9:0] dx;
        input [9:0] dy;
        reg right_side;
        reg [9:0] right_local_x;
    begin
        right_side    = (dx >= RIGHT_OUTPUT_X_START);
        right_local_x = dx - RIGHT_OUTPUT_X_START[9:0];
        if (right_side)
            bram_byte_addr = dy * FULL_ROW_WIDTH + HALF_FRAME_WIDTH + right_local_x;
        else
            bram_byte_addr = dy * FULL_ROW_WIDTH + dx;
    end
    endfunction

    // ====================================================================
    // 6) Bus consumer FSM. Per pixel:
    //    - in-bounds:  read camera -> (BRAM write + VGA write) -> idle    (3 cyc)
    //    - out-of-bnd: (BRAM write 0 + VGA write 0) -> idle               (2 cyc)
    // ====================================================================
    localparam [1:0] BUS_IDLE       = 2'd0;
    localparam [1:0] BUS_WAIT_READ  = 2'd1;
    localparam [1:0] BUS_WAIT_WRITE = 2'd2;
    localparam [1:0] BUS_DONE       = 2'd3;
    reg [1:0] bus_state;

    reg [9:0] inflight_dst_x;
    reg [9:0] inflight_dst_y;

    reg fifo_pop_r;
    assign fifo_pop = fifo_pop_r;

    reg frame_complete;
    wire pipeline_drained = last_submitted && fifo_empty && (bus_state == BUS_IDLE);

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            bus_state       <= BUS_IDLE;
            bus_addr        <= 32'd0;
            bus_read        <= 1'b0;
            bus_write       <= 1'b0;
            bus_byte_enable <= 4'b0001;
            bus_write_data  <= 32'd0;
            bram_wr_en      <= 1'b0;
            bram_wr_addr    <= {BRAM_ADDR_W{1'b0}};
            bram_wr_data    <= 8'd0;
            inflight_dst_x  <= 10'd0;
            inflight_dst_y  <= 10'd0;
            done            <= 1'b0;
            fifo_pop_r      <= 1'b0;
            frame_complete  <= 1'b0;
        end else begin
            // Defaults (single-cycle pulses).
            bram_wr_en     <= 1'b0;
            fifo_pop_r     <= 1'b0;
            done           <= 1'b0;
            frame_complete <= 1'b0;

            case (bus_state)
                BUS_IDLE: begin
                    bus_read  <= 1'b0;
                    bus_write <= 1'b0;
                    if (!fifo_empty) begin
                        fifo_pop_r     <= 1'b1;
                        inflight_dst_x <= head_dst_x;
                        inflight_dst_y <= head_dst_y;
                        if (head_inbnd) begin
                            // Issue a camera-SRAM read. BRAM + VGA writes
                            // happen when ack returns.
                            bus_addr        <= cam_byte_addr(head_src_x, head_src_y);
                            bus_read        <= 1'b1;
                            bus_byte_enable <= 4'b0001;
                            bus_state       <= BUS_WAIT_READ;
                        end else begin
                            // Out-of-bounds destination: write 0 to BRAM,
                            // and write 0 to VGA (so the camera display goes
                            // black in the gap region, matching legacy).
                            bram_wr_en      <= 1'b1;
                            bram_wr_addr    <= bram_byte_addr(head_dst_x, head_dst_y);
                            bram_wr_data    <= 8'h00;
                            bus_addr        <= vga_byte_addr(head_dst_x, head_dst_y);
                            bus_write       <= 1'b1;
                            bus_write_data  <= 32'd0;
                            bus_byte_enable <= 4'b0001;
                            bus_state       <= BUS_WAIT_WRITE;
                        end
                    end else if (pipeline_drained) begin
                        bus_state      <= BUS_DONE;
                        frame_complete <= 1'b1;
                    end
                end

                BUS_WAIT_READ: begin
                    if (bus_ack) begin
                        // Camera read complete. Drop read, register the BRAM
                        // write, and start a VGA write with the same pixel.
                        bus_read       <= 1'b0;
                        bram_wr_en     <= 1'b1;
                        bram_wr_addr   <= bram_byte_addr(inflight_dst_x,
                                                         inflight_dst_y);
                        bram_wr_data   <= bus_read_data[7:0];
                        bus_addr       <= vga_byte_addr(inflight_dst_x,
                                                        inflight_dst_y);
                        bus_write      <= 1'b1;
                        bus_write_data <= {24'd0, bus_read_data[7:0]};
                        bus_byte_enable<= 4'b0001;
                        bus_state      <= BUS_WAIT_WRITE;
                    end
                end

                BUS_WAIT_WRITE: begin
                    if (bus_ack) begin
                        bus_write <= 1'b0;
                        bus_state <= BUS_IDLE;
                    end
                end

                BUS_DONE: begin
                    done      <= 1'b1;
                    bus_state <= BUS_IDLE;
                end

                default: bus_state <= BUS_IDLE;
            endcase
        end
    end

endmodule
