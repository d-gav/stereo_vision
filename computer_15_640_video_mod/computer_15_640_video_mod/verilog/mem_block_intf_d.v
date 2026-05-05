// =============================================================================
// mem_block_intf  (disparity-parallel, line-buffer version)
//
// Computes stereo disparity for one row-position of the line buffer.
// Called once per y-position by the top level; the top level manages the
// line buffer (filling new rows and advancing the circular pointer).
//
// Architecture:
//   NUM_DISP_UNITS SAD workers, each evaluating a DIFFERENT disparity on
//   the SAME reference block.  One shared reference sliding_window; each
//   worker has its own match sliding_window + block_match_sad.
//
// Loop structure (executed inside this module per go pulse):
//   1. LOAD_REF: read BLOCK_SIZE left columns → fill ref sliding window
//   2. For each x = BLOCK_SIZE-1 .. HALF_FRAME_WIDTH-1:
//      a. For each d_batch = 0 .. ceil(MAX_DISP/NUM_DISP_UNITS)-1:
//         - STREAM_MATCH: read (NUM_DISP_UNITS + BLOCK_SIZE - 1) right cols
//           Unit i shifts when stream_idx in [i, i+BLOCK_SIZE)
//         - COMPARE: check all SADs, update best
//      b. EMIT: output best disparity for (x, y)
//      c. ADVANCE_X: read 1 new left col → shift ref window
//   3. DONE
//
// Line-buffer read interface (directly drives BRAM rd_col via top-level mux):
//   lb_rd_req + lb_rd_bank + lb_rd_col → issue address
//   lb_rd_data[0:BLOCK_SIZE-1] ← arrives 1 cycle later (M10K latency)
// =============================================================================

module mem_block_intf #(
    parameter int FRAME_HEIGHT     = 200,
    parameter int HALF_FRAME_WIDTH = 320,
    parameter int BLOCK_SIZE       = 5,
    parameter int PIXEL_W          = 8,
    parameter int MAX_DISP         = 85,
    parameter int SAD_W            = PIXEL_W + $clog2(BLOCK_SIZE * BLOCK_SIZE),
    parameter int DISP_W           = (MAX_DISP < 1) ? 1 : $clog2(MAX_DISP + 1),
    parameter int NUM_DISP_UNITS   = 24,
    parameter int ROW_W            = (FRAME_HEIGHT <= 1) ? 1 : $clog2(FRAME_HEIGHT),
    parameter int COL_W            = (HALF_FRAME_WIDTH <= 1) ? 1 : $clog2(HALF_FRAME_WIDTH)
) (
    input  logic clk,
    input  logic rst,
    input  logic go,

    // Line-buffer read port
    output logic                lb_rd_req,
    output logic                lb_rd_bank,  // 0=left, 1=right
    output logic [COL_W-1:0]    lb_rd_col,
    input  logic [PIXEL_W-1:0]  lb_rd_data [0:BLOCK_SIZE-1],

    // Circular buffer base (physical slot of the top row of current window)
    input  logic [$clog2(BLOCK_SIZE)-1:0] buf_base,

    // Current y-coordinate (set by top level before asserting go)
    input  logic [ROW_W-1:0]    curr_y,

    // Streaming disparity output
    output logic                disp_valid,
    output logic [ROW_W-1:0]    disp_out_y,
    output logic [COL_W-1:0]    disp_out_x,
    output logic [DISP_W-1:0]   disp_out_value,
    input  logic                disp_ack,

    output logic done
);

    // ---- Derived constants ----
    localparam int HALF_BLOCK    = BLOCK_SIZE / 2;
    localparam int X_MAX         = HALF_FRAME_WIDTH - 1;
    localparam int STREAM_LEN    = NUM_DISP_UNITS + BLOCK_SIZE - 1;
    localparam int STREAM_CNT_W  = $clog2(STREAM_LEN + 2);  // +2 for pipeline flush
    localparam int NUM_D_BATCHES = (MAX_DISP + NUM_DISP_UNITS - 1) / NUM_DISP_UNITS;
    localparam int D_BATCH_W     = (NUM_D_BATCHES <= 1) ? 1 : $clog2(NUM_D_BATCHES);
    localparam int SLOT_W        = $clog2(BLOCK_SIZE);

    // ---- FSM states ----
    localparam [3:0] S_IDLE       = 4'd0;
    localparam [3:0] S_LOAD_REF   = 4'd1;  // fill ref window (BLOCK_SIZE reads)
    localparam [3:0] S_LOAD_WAIT  = 4'd2;  // wait for last ref read to arrive
    localparam [3:0] S_STREAM_M   = 4'd3;  // stream right cols for match windows
    localparam [3:0] S_STREAM_TAIL= 4'd4;  // flush last pending match read
    localparam [3:0] S_COMPARE    = 4'd5;  // compare SADs, update best
    localparam [3:0] S_NEXT_BATCH = 4'd6;  // advance d_batch or go to emit
    localparam [3:0] S_EMIT       = 4'd7;  // output disparity, wait for ack
    localparam [3:0] S_ADV_X      = 4'd8;  // read 1 new left col for next x
    localparam [3:0] S_ADV_WAIT   = 4'd9;  // wait for that read
    localparam [3:0] S_DONE       = 4'd10;

    logic [3:0] state;
    logic was_started;
    assign done = was_started && (state == S_IDLE);

    // ---- Loop counters ----
    logic [COL_W-1:0]                    curr_x;
    logic [D_BATCH_W-1:0]               curr_d_batch;
    logic [$clog2(BLOCK_SIZE+1)-1:0]    ref_cnt;
    logic [STREAM_CNT_W-1:0]            stream_cnt;

    // ---- Pending read pipeline (1-cycle BRAM latency) ----
    // prev_* tracks what was issued LAST cycle; pending_rd is set from prev_req.
    logic                pending_rd;     // data arriving THIS cycle is valid
    logic                pending_bank;   // bank of arriving data
    logic [STREAM_CNT_W-1:0] pending_stream_idx;  // stream index of arriving match data
    logic                prev_req;       // was a read issued last cycle?
    logic                prev_bank;      // bank of last cycle's read
    logic [STREAM_CNT_W-1:0] prev_stream_idx;

    // ---- Reorder buffer: circular slot → linear row order ----
    logic [PIXEL_W-1:0] col_pixels [0:BLOCK_SIZE-1];
    always_comb begin
        for (int i = 0; i < BLOCK_SIZE; i++) begin
            col_pixels[i] = lb_rd_data[(buf_base + i) % BLOCK_SIZE];
        end
    end

    // Flatten for sliding_window input
    logic [BLOCK_SIZE*PIXEL_W-1:0] col_flat;
    always_comb begin
        for (int i = 0; i < BLOCK_SIZE; i++) begin
            col_flat[i*PIXEL_W +: PIXEL_W] = col_pixels[i];
        end
    end

    // ---- Shared reference sliding window ----
    logic slide_ref;
    logic [BLOCK_SIZE*BLOCK_SIZE*PIXEL_W-1:0] ref_block_flat;

    sliding_window #(.BLOCK_SIZE(BLOCK_SIZE), .PIXEL_W(PIXEL_W))
    u_ref_window (
        .clk(clk), .rst(rst),
        .valid_in(slide_ref),
        .pixel_in_col_flat(col_flat),
        .block_out(),
        .block_out_flat(ref_block_flat)
    );

    // ---- Per-unit match windows + SAD ----
    logic [NUM_DISP_UNITS-1:0] slide_match;
    logic [SAD_W-1:0] sad_value [0:NUM_DISP_UNITS-1];

    genvar g;
    generate
        for (g = 0; g < NUM_DISP_UNITS; g++) begin : GEN_UNIT
            logic [BLOCK_SIZE*BLOCK_SIZE*PIXEL_W-1:0] match_flat_g;

            sliding_window #(.BLOCK_SIZE(BLOCK_SIZE), .PIXEL_W(PIXEL_W))
            u_match_win (
                .clk(clk), .rst(rst),
                .valid_in(slide_match[g]),
                .pixel_in_col_flat(col_flat),
                .block_out(),
                .block_out_flat(match_flat_g)
            );

            block_match_sad #(.BLOCK_SIZE(BLOCK_SIZE), .PIXEL_W(PIXEL_W), .SAD_W(SAD_W))
            u_sad (
                .left_block_flat(ref_block_flat),
                .right_block_flat(match_flat_g),
                .sad(sad_value[g])
            );
        end
    endgenerate

    // ---- Best-disparity tracking ----
    logic [SAD_W-1:0]  best_sad;
    logic [DISP_W-1:0] best_disp;

    // ---- Combinational: slide_ref from pending left reads ----
    // slide_match from pending right reads with per-unit gating
    always_comb begin
        slide_ref   = 1'b0;
        slide_match = '0;

        if (pending_rd) begin
            if (pending_bank == 1'b0) begin
                // Left data arrived → shift reference window
                slide_ref = 1'b1;
            end else begin
                // Right data arrived → shift appropriate match windows
                for (int i = 0; i < NUM_DISP_UNITS; i++) begin
                    if (pending_stream_idx >= i[STREAM_CNT_W-1:0] &&
                        pending_stream_idx < (i[STREAM_CNT_W-1:0] + BLOCK_SIZE)) begin
                        slide_match[i] = 1'b1;
                    end
                end
            end
        end
    end

    // ---- Right column address for current stream position ----
    // batch base disparity + stream index gives the right-image column offset
    logic [COL_W:0] stream_right_col_ext;  // 1 extra bit for overflow detection
    assign stream_right_col_ext = curr_x + (curr_d_batch * NUM_DISP_UNITS) + stream_cnt;

    // ---- Main FSM ----
    always_ff @(posedge clk) begin
        if (rst) begin
            state       <= S_IDLE;
            was_started <= 1'b0;
            curr_x      <= '0;
            curr_d_batch<= '0;
            ref_cnt     <= '0;
            stream_cnt  <= '0;
            lb_rd_req   <= 1'b0;
            lb_rd_bank  <= 1'b0;
            lb_rd_col   <= '0;
            pending_rd  <= 1'b0;
            pending_bank<= 1'b0;
            pending_stream_idx <= '0;
            prev_req    <= 1'b0;
            prev_bank   <= 1'b0;
            prev_stream_idx <= '0;
            best_sad    <= {SAD_W{1'b1}};
            best_disp   <= '0;
            disp_valid  <= 1'b0;
            disp_out_y  <= '0;
            disp_out_x  <= '0;
            disp_out_value <= '0;
        end else begin
            // Default: deassert single-cycle signals
            lb_rd_req  <= 1'b0;
            disp_valid <= 1'b0;

            // Pipeline: data from PREVIOUS cycle's read arrives this cycle
            pending_rd         <= prev_req;
            pending_bank       <= prev_bank;
            pending_stream_idx <= prev_stream_idx;
            prev_req           <= 1'b0;  // default: no req this cycle

            case (state)

            // ================================================================
            S_IDLE: begin
                pending_rd <= 1'b0;
                if (go) begin
                    was_started  <= 1'b1;
                    curr_x       <= '0;
                    ref_cnt      <= '0;
                    state        <= S_LOAD_REF;
                end
            end

            // ================================================================
            // Read BLOCK_SIZE left columns (0..BLOCK_SIZE-1) to fill ref window
            S_LOAD_REF: begin
                if (ref_cnt < BLOCK_SIZE) begin
                    lb_rd_req  <= 1'b1;
                    lb_rd_bank <= 1'b0;
                    lb_rd_col  <= ref_cnt[COL_W-1:0];
                    prev_req   <= 1'b1;
                    prev_bank  <= 1'b0;
                    ref_cnt    <= ref_cnt + 1;
                end else begin
                    // All reads issued; last data arrives this cycle via pending
                    state <= S_LOAD_WAIT;
                end
            end

            // ================================================================
            // Wait one cycle for last ref read to arrive and shift
            S_LOAD_WAIT: begin
                pending_rd <= 1'b0;
                // Ref window now has columns 0..BLOCK_SIZE-1
                // First valid x = BLOCK_SIZE-1 (center of first complete window)
                curr_x       <= BLOCK_SIZE - 1;
                curr_d_batch <= '0;
                stream_cnt   <= '0;
                best_sad     <= {SAD_W{1'b1}};
                best_disp    <= '0;
                state        <= S_STREAM_M;
            end

            // ================================================================
            // Stream right columns for current (x, d_batch)
            S_STREAM_M: begin
                if (stream_cnt < STREAM_LEN) begin
                    // Issue read if column is in bounds
                    if (stream_right_col_ext < HALF_FRAME_WIDTH) begin
                        lb_rd_req       <= 1'b1;
                        lb_rd_bank      <= 1'b1;
                        lb_rd_col       <= stream_right_col_ext[COL_W-1:0];
                        prev_req        <= 1'b1;
                        prev_bank       <= 1'b1;
                        prev_stream_idx <= stream_cnt;
                    end
                    stream_cnt <= stream_cnt + 1;
                end else begin
                    // All reads issued; last data arrives via pending pipeline
                    state <= S_STREAM_TAIL;
                end
            end

            // ================================================================
            // Flush: last match column data arrives this cycle
            S_STREAM_TAIL: begin
                pending_rd <= 1'b0;
                state      <= S_COMPARE;
            end

            // ================================================================
            // Compare all SADs, update best for this x
            S_COMPARE: begin
                best_sad  <= compare_best_sad;
                best_disp <= compare_best_disp;
                state     <= S_NEXT_BATCH;
            end

            // ================================================================
            // Check if more d_batches remain, else emit
            S_NEXT_BATCH: begin
                if ((curr_d_batch + 1) < NUM_D_BATCHES) begin
                    curr_d_batch <= curr_d_batch + 1;
                    stream_cnt   <= '0;
                    state        <= S_STREAM_M;
                end else begin
                    // All batches done → emit
                    disp_valid     <= 1'b1;
                    disp_out_y     <= curr_y;
                    disp_out_x     <= curr_x;
                    disp_out_value <= best_disp;
                    state          <= S_EMIT;
                end
            end

            // ================================================================
            // Wait for disp_ack, then advance x or finish
            S_EMIT: begin
                disp_valid <= 1'b1;  // hold until ack
                if (disp_ack) begin
                    disp_valid <= 1'b0;
                    if (curr_x < X_MAX) begin
                        // Read 1 new left column for next x
                        lb_rd_req  <= 1'b1;
                        lb_rd_bank <= 1'b0;
                        lb_rd_col  <= curr_x + 1;
                        prev_req   <= 1'b1;
                        prev_bank  <= 1'b0;
                        state      <= S_ADV_X;
                    end else begin
                        state <= S_DONE;
                    end
                end
            end

            // ================================================================
            // Wait for the new left column read to complete
            S_ADV_X: begin
                // prev_req was set when we issued the read in S_EMIT.
                // pending_rd will be set by the pipeline this cycle.
                // Data arrives and slide_ref fires combinationally.
                state <= S_ADV_WAIT;
            end

            // ================================================================
            // The ref window shift happens combinationally this cycle.
            // Set up for next x's disparity sweep.
            S_ADV_WAIT: begin
                pending_rd   <= 1'b0;
                curr_x       <= curr_x + 1;
                curr_d_batch <= '0;
                stream_cnt   <= '0;
                best_sad     <= {SAD_W{1'b1}};
                best_disp    <= '0;
                state        <= S_STREAM_M;
            end

            // ================================================================
            S_DONE: begin
                was_started <= 1'b0;
                state       <= S_IDLE;
            end

            default: state <= S_IDLE;

            endcase
        end
    end

    // ---- Combinational best-SAD finder across all units ----
    logic [SAD_W-1:0]  compare_best_sad;
    logic [DISP_W-1:0] compare_best_disp;

    always_comb begin
        compare_best_sad  = best_sad;
        compare_best_disp = best_disp;
        for (int i = 0; i < NUM_DISP_UNITS; i++) begin
            automatic int d_abs = (curr_d_batch * NUM_DISP_UNITS) + i;
            if (d_abs < MAX_DISP && (curr_x + d_abs) < HALF_FRAME_WIDTH) begin
                if (sad_value[i] < compare_best_sad) begin
                    compare_best_sad  = sad_value[i];
                    compare_best_disp = d_abs[DISP_W-1:0];
                end
            end
        end
    end

endmodule