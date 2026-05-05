// =============================================================================
// fill_pipe_controller
//
// Streaming PHASE_FILL controller. Pipelined dataflow:
//   coord-gen -> stereo_radial_mapper_q15_pipe (11 stages, 1 px/cycle)
//             -> small FIFO  -> bus issuer  -> BRAM write + VGA write
//
// MODES:
//   fill_mode = 0: Fill ALL rows (0..FRAME_HEIGHT-1). Used for initial fill
//                   and full-frame VGA display.
//   fill_mode = 1: Fill ONE row (fill_row_y). Used for incremental line-buffer
//                   refill between compute steps.
//
// "go" starts a fill. "done" pulses for one cycle when finished.
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
    parameter integer BLOCK_SIZE            = 5,
    parameter integer SLOT_W               = (BLOCK_SIZE <= 1) ? 1 : $clog2(BLOCK_SIZE),
    parameter integer COL_W                 = $clog2(FULL_ROW_WIDTH),
    parameter integer MAPPER_LATENCY        = 11
) (
    input  wire                       clk,
    input  wire                       reset_n,
    input  wire                       go,

    // Fill mode control
    input  wire                       fill_mode,     // 0=full frame, 1=single row
    input  wire [9:0]                 fill_row_y,    // row to fill when fill_mode=1

    // Avalon master (UNCHANGED from old design)
    output reg  [31:0]                bus_addr,
    output reg                        bus_read,
    output reg                        bus_write,
    output reg  [3:0]                 bus_byte_enable,
    output reg  [31:0]                bus_write_data,
    input  wire [31:0]                bus_read_data,
    input  wire                       bus_ack,

    // Line-buffer BRAM write port (row-slot based instead of stripe-based)
    output reg                        bram_wr_en,
    output reg  [SLOT_W-1:0]          bram_wr_row_slot,
    output reg  [COL_W-1:0]           bram_wr_col,
    output reg  [7:0]                 bram_wr_data,

    output reg                        done
);

    // ---- Bus base addresses (must match top-level Qsys mapping) ----
    localparam [31:0] VIDEO_IN_BASE = 32'h0800_0000;
    localparam [31:0] VGA_OUT_BASE  = 32'h0000_0000;

    // ====================================================================
    // 1) Coordinate generator
    // ====================================================================
    reg [9:0]  dst_x;
    reg [9:0]  dst_y;
    reg        streaming;
    reg        last_submitted;
    wire       can_feed;

    // End-of-scan depends on fill mode
    wire [9:0] y_start = fill_mode ? fill_row_y : 10'd0;
    wire [9:0] y_end   = fill_mode ? fill_row_y : (FRAME_HEIGHT - 1);
    wire       at_last_pixel = (dst_x == FULL_FRAME_WIDTH-1) && (dst_y == y_end);

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            dst_x          <= 10'd0;
            dst_y          <= 10'd0;
            streaming      <= 1'b0;
            last_submitted <= 1'b0;
        end else begin
            if (go && !streaming && !last_submitted) begin
                dst_x          <= 10'd0;
                dst_y          <= y_start;
                streaming      <= 1'b1;
                last_submitted <= 1'b0;
            end else if (streaming && can_feed) begin
                if (at_last_pixel) begin
                    last_submitted <= 1'b1;
                    streaming      <= 1'b0;
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
    // 2) Pipelined radial mapper
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
    // 3) Delay line for dst coords
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
    // 4) FIFO
    // ====================================================================
    localparam FIFO_DEPTH_LOG2 = 5;
    localparam FIFO_DEPTH      = (1 << FIFO_DEPTH_LOG2);
    localparam FIFO_HIGH_WATER = FIFO_DEPTH - MAPPER_LATENCY - 4;

    reg [40:0] fifo_mem [0:FIFO_DEPTH-1];
    reg [FIFO_DEPTH_LOG2-1:0] fifo_wr_ptr;
    reg [FIFO_DEPTH_LOG2-1:0] fifo_rd_ptr;
    reg [FIFO_DEPTH_LOG2:0]   fifo_count;
    wire fifo_full  = (fifo_count >= FIFO_HIGH_WATER);
    wire fifo_empty = (fifo_count == 0);

    wire fifo_push = aligned_was_valid;
    wire fifo_pop;

    wire src_y_in_cropped = (mapper_src_y >= Y_CROP_OFFSET[9:0]) &&
                            (mapper_src_y < (Y_CROP_OFFSET[9:0] + FRAME_HEIGHT[9:0]));
    wire effective_in_bounds = mapper_valid_out && src_y_in_cropped;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            fifo_wr_ptr <= 0;
            fifo_rd_ptr <= 0;
            fifo_count  <= 0;
        end else begin
            if (fifo_push) begin
                fifo_mem[fifo_wr_ptr] <= {aligned_dst_x, aligned_dst_y,
                                         mapper_src_x, mapper_src_y,
                                         effective_in_bounds};
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

    wire [40:0] head_word    = fifo_mem[fifo_rd_ptr];
    wire [9:0]  head_dst_x   = head_word[40:31];
    wire [9:0]  head_dst_y   = head_word[30:21];
    wire [9:0]  head_src_x   = head_word[20:11];
    wire [9:0]  head_src_y   = head_word[10:1];
    wire        head_inbnd   = head_word[0];

    // ====================================================================
    // 5) Address translations (UNCHANGED)
    // ====================================================================
    function [31:0] cam_byte_addr;
        input [9:0] sx;
        input [9:0] sy;
        reg [9:0] sy_cropped;
    begin
        sy_cropped    = sy - Y_CROP_OFFSET[9:0];
        cam_byte_addr = VIDEO_IN_BASE + {22'b0, sx} + ({22'b0, sy_cropped} << 10);
    end
    endfunction

    function [31:0] vga_byte_addr;
        input [9:0] dx;
        input [9:0] dy;
    begin
        vga_byte_addr = VGA_OUT_BASE + {22'b0, dx} + ({22'b0, dy} << 10);
    end
    endfunction

    // Line-buffer column mapping (replaces stripe-based helpers)
    function [SLOT_W-1:0] bram_row_slot_of;
        input [9:0] dy;
    begin
        bram_row_slot_of = dy % BLOCK_SIZE;
    end
    endfunction

    function [COL_W-1:0] bram_col_of;
        input [9:0] dx;
        reg right_side;
        reg [9:0] right_local_x;
    begin
        right_side    = (dx >= RIGHT_OUTPUT_X_START);
        right_local_x = dx - RIGHT_OUTPUT_X_START[9:0];
        if (right_side)
            bram_col_of = HALF_FRAME_WIDTH + right_local_x;
        else
            bram_col_of = dx;
    end
    endfunction

    // ====================================================================
    // 6) Bus consumer FSM (UNCHANGED bus protocol)
    // ====================================================================
    localparam [2:0] BUS_IDLE        = 3'd0;
    localparam [2:0] BUS_WAIT_READ   = 3'd1;
    localparam [2:0] BUS_TRANSITION  = 3'd2;
    localparam [2:0] BUS_WAIT_WRITE  = 3'd3;
    localparam [2:0] BUS_DONE        = 3'd4;
    reg [2:0] bus_state;

    reg [9:0] inflight_dst_x;
    reg [9:0] inflight_dst_y;
    reg [7:0] captured_pixel;

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
            bram_wr_en            <= 1'b0;
            bram_wr_row_slot      <= {SLOT_W{1'b0}};
            bram_wr_col           <= {COL_W{1'b0}};
            bram_wr_data          <= 8'd0;
            inflight_dst_x  <= 10'd0;
            inflight_dst_y  <= 10'd0;
            captured_pixel  <= 8'd0;
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
                            bus_addr        <= cam_byte_addr(head_src_x, head_src_y);
                            bus_read        <= 1'b1;
                            bus_byte_enable <= 4'b0001;
                            bus_state       <= BUS_WAIT_READ;
                        end else begin
                            bram_wr_en            <= 1'b1;
                            bram_wr_row_slot      <= bram_row_slot_of(head_dst_y);
                            bram_wr_col           <= bram_col_of(head_dst_x);
                            bram_wr_data          <= 8'h00;
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
                        bus_read              <= 1'b0;
                        bram_wr_en            <= 1'b1;
                        bram_wr_row_slot      <= bram_row_slot_of(inflight_dst_y);
                        bram_wr_col           <= bram_col_of(inflight_dst_x);
                        bram_wr_data          <= bus_read_data[7:0];
                        captured_pixel        <= bus_read_data[7:0];
                        bus_state             <= BUS_TRANSITION;
                    end
                end

                BUS_TRANSITION: begin
                    bus_addr        <= vga_byte_addr(inflight_dst_x,
                                                     inflight_dst_y);
                    bus_write       <= 1'b1;
                    bus_write_data  <= {24'd0, captured_pixel};
                    bus_byte_enable <= 4'b0001;
                    bus_state       <= BUS_WAIT_WRITE;
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
