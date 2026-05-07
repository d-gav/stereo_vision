module mem_block_intf #(
    parameter int FRAME_HEIGHT     = 288,
    parameter int HALF_FRAME_WIDTH = 320,
    parameter int BLOCK_SIZE       = 5,
    parameter int PIXEL_W          = 8,
    parameter int MAX_DISP         = 63,
    parameter logic EDGE_PIXEL_MIN     = 8'd1,
    parameter int                 FILL_MAX_GAP       = 24,
    parameter logic [7:0]         FILL_MAX_DISP_JUMP = 8'd8,
    parameter logic [7:0]         INVALID_DISP_VALUE = 8'h00,
    parameter int COST_W           = 4, // Max Hamming distance for 5x5 CSCT is 12, fits in 4 bits
    
    parameter int DISP_W           = (MAX_DISP < 1)? 1 : $clog2(MAX_DISP + 1),
    parameter int NUM_COST_UNITS   = FRAME_HEIGHT / BLOCK_SIZE,
    parameter int STRIPE_HEIGHT    = FRAME_HEIGHT / NUM_COST_UNITS,
    parameter int PHASE_W          = (STRIPE_HEIGHT <= 1)? 1 : ($clog2(STRIPE_HEIGHT) + 1),
    parameter int ROW_W            = (FRAME_HEIGHT <= 1)? 1 : $clog2(FRAME_HEIGHT),
    parameter int COL_W            = (HALF_FRAME_WIDTH <= 1)? 1 : $clog2(HALF_FRAME_WIDTH)
) (
    input logic clk,
    input logic rst,
    input logic go,

    output logic mem_req,
    output logic mem_bank, 
    output logic mem_col,
    input  logic mem_rdata,

    output logic [7:0] disp_map,

    output logic       pipe0_phase,
    output logic         pipe0_col_x,
    output logic signed   pipe0_disp,
    output logic                     pipe0_valid,
    output logic                     pipe0_to_ref
);

    localparam int HALF_BLOCK    = BLOCK_SIZE / 2;
    localparam int X_W           = COL_W;
    localparam int X_MIN         = 0;
    localparam int X_MAX         = HALF_FRAME_WIDTH - 1;

    localparam logic      X_MIN_L     = X_MIN;
    localparam logic      X_MAX_L     = X_MAX;
    localparam logic   MAX_DISP_L  = MAX_DISP;
    localparam logic  MAX_PHASE_L = STRIPE_HEIGHT - 1;

    localparam [2:0] IDLE       = 3'd0;
    localparam [2:0] INCR_DISP  = 3'd1;  
    localparam [2:0] INCR_X     = 3'd2;  
    localparam [2:0] INCR_PHASE = 3'd3;  
    localparam [2:0] FILL_SCAN  = 3'd4;  
    localparam [2:0] FILL_APPLY = 3'd5;  

    logic [2:0] curr_state;
    logic [2:0] next_state;

    logic left_col_buf ;
    logic right_col_buf;
    logic ref_center_pix;
    logic ref_edge_valid;
    logic disp_valid_map;

    logic cost_value;
    logic best_cost ;
    logic best_disp;

    logic slide_reference;
    logic slide_matching;

    genvar g;
    generate
        for (g = 0; g < NUM_COST_UNITS; g++) begin : GEN_UNIT
            logic left_col_flat_g;
            logic right_col_flat_g;
            logic left_block_g ;
            logic right_block_g;
            logic left_block_flat_g;
            logic right_block_flat_g;

            genvar rr;
            for (rr = 0; rr < BLOCK_SIZE; rr++) begin : GEN_COL_WIRE
                assign left_col_flat_g = left_col_buf[g][rr];
                assign right_col_flat_g = right_col_buf[g][rr];
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

            // Center-Symmetric Census Transform (CSCT) Logic for 5x5 Window
            logic [11:0] left_csct;
            logic [11:0] right_csct;
            logic [11:0] hamming_xor;

            assign left_csct  = (left_block_g >= left_block_g[1][1]);
            assign left_csct[2]  = (left_block_g[2] >= left_block_g[1][3]);
            assign left_csct[4]  = (left_block_g[4] >= left_block_g[1][4]);
            assign left_csct[3]  = (left_block_g[3] >= left_block_g[1][2]);
            assign left_csct[1]  = (left_block_g[1] >= left_block_g[1]);
            assign left_csct[5]  = (left_block_g[2] >= left_block_g[3][1]);
            assign left_csct[6]  = (left_block_g[2][2] >= left_block_g[3][3]);
            assign left_csct[7]  = (left_block_g[2][4] >= left_block_g[3][4]);
            assign left_csct[8]  = (left_block_g[2][3] >= left_block_g[3][2]);
            assign left_csct[9]  = (left_block_g[2][1] >= left_block_g[3]);
            assign left_csct[10] = (left_block_g[4] >= left_block_g[4][1]);
            assign left_csct[11] = (left_block_g[4][2] >= left_block_g[4][3]);

            assign right_csct  = (right_block_g >= right_block_g[1][1]);
            assign right_csct[2]  = (right_block_g[2] >= right_block_g[1][3]);
            assign right_csct[4]  = (right_block_g[4] >= right_block_g[1][4]);
            assign right_csct[3]  = (right_block_g[3] >= right_block_g[1][2]);
            assign right_csct[1]  = (right_block_g[1] >= right_block_g[1]);
            assign right_csct[5]  = (right_block_g[2] >= right_block_g[3][1]);
            assign right_csct[6]  = (right_block_g[2][2] >= right_block_g[3][3]);
            assign right_csct[7]  = (right_block_g[2][4] >= right_block_g[3][4]);
            assign right_csct[8]  = (right_block_g[2][3] >= right_block_g[3][2]);
            assign right_csct[9]  = (right_block_g[2][1] >= right_block_g[3]);
            assign right_csct[10] = (right_block_g[4] >= right_block_g[4][1]);
            assign right_csct[11] = (right_block_g[4][2] >= right_block_g[4][3]);

            assign hamming_xor = left_csct ^ right_csct;

            // Parallel Adder Tree for Popcount
            always_comb begin
                cost_value[g] = (hamming_xor + hamming_xor[2] + hamming_xor[4]) +
                                (hamming_xor[3] + hamming_xor[1] + hamming_xor[5]) +
                                (hamming_xor[6] + hamming_xor[7] + hamming_xor[8]) +
                                (hamming_xor[9] + hamming_xor[10] + hamming_xor[11]);
            end

            assign ref_center_pix[g] = left_block_g;
        end
    endgenerate

    function automatic logic [7:0] disp_to_u8(input logic d);
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

    function automatic logic [7:0] abs_diff_u8(input logic [7:0] a, input logic [7:0] b);
        begin
            if (a >= b) begin
                abs_diff_u8 = a - b;
            end else begin
                abs_diff_u8 = b - a;
            end
        end
    endfunction

    localparam int PIPE_DEPTH = 3;
    logic phase_pipeline;
    logic   col_x_pipeline;
    logic signed disp_pipeline;
    logic to_ref_block_pipeline; 
    logic valid_rd_pipeline;

    assign pipe0_phase  = phase_pipeline;
    assign pipe0_col_x  = col_x_pipeline;
    assign pipe0_disp   = disp_pipeline;
    assign pipe0_valid  = valid_rd_pipeline;
    assign pipe0_to_ref = to_ref_block_pipeline;

    logic phase_result;
    logic col_x_result;
    logic signed disp_result;
    logic to_ref_block_result;
    logic valid_rd_result;
    
    assign phase_result = phase_pipeline;
    assign col_x_result = col_x_pipeline;
    assign disp_result = disp_pipeline;
    assign to_ref_block_result = to_ref_block_pipeline;
    assign valid_rd_result = valid_rd_pipeline;

    logic curr_phase;
    logic curr_col_x;
    logic signed curr_disp;

    logic     reg_phase;
    logic         reg_col_x;
    logic signed reg_disp;

    logic cost_compare_en;

    logic phase_cnt;
    logic phase_cnt_next;
    logic phase_complete; 
    assign phase_complete = (phase_cnt == (BLOCK_SIZE)*2 + 2);
    logic PHASE_match_read; 
    assign PHASE_match_read = (curr_state == INCR_PHASE) && (phase_cnt <= BLOCK_SIZE-1);
    logic PHASE_ref_read; 
    assign PHASE_ref_read = (curr_state == INCR_PHASE) && (phase_cnt > (BLOCK_SIZE-1) && phase_cnt < (BLOCK_SIZE)*2);

    logic x_cnt;
    logic x_cnt_next;
    logic match_full_x; 
    assign match_full_x = (x_cnt == BLOCK_SIZE + 3);

    logic INCR_X_reading_ref; 
    assign INCR_X_reading_ref = (curr_state == INCR_X) && (x_cnt == (BLOCK_SIZE));
    logic INCR_X_reading_match; 
    assign INCR_X_reading_match = (curr_state == INCR_X) && (x_cnt < (BLOCK_SIZE));
    
    logic in_disp_bounds;
    assign in_disp_bounds = (reg_disp >= 0)
        && (reg_disp < $signed({1'b0, MAX_DISP_L}))
        && ((reg_disp + $signed({1'b0, reg_col_x})) < $signed({1'b0, X_MAX_L}));
    logic [1:0] disp_out_bounds_cnt;

    logic fill_row;
    logic fill_scan_col;
    logic fill_have_left;
    logic fill_left_col;
    logic [7:0] fill_left_disp;
    logic fill_right_col;
    logic [7:0] fill_right_disp;
    logic fill_resume_col;
    logic fill_write_col;
    logic fill_seg_left_col;
    logic [7:0] fill_seg_left_disp;

    logic fill_scan_valid;
    logic fill_gap_present;
    logic fill_gap_len;
    logic fill_gap_len_ok;
    logic [7:0] fill_gap_jump;
    logic fill_gap_jump_ok;
    logic fill_start_apply;

    assign fill_scan_valid = (fill_row < FRAME_HEIGHT && fill_scan_col < HALF_FRAME_WIDTH)
       ? disp_valid_map[fill_row][fill_scan_col]
        : 1'b0;
    assign fill_gap_present = fill_have_left && (fill_scan_col > (fill_left_col + 1'b1));
    assign fill_gap_len = fill_gap_present? (fill_scan_col - fill_left_col - 1'b1) : '0;
    assign fill_gap_len_ok = (fill_gap_len <= FILL_MAX_GAP);
    assign fill_gap_jump = (fill_row < FRAME_HEIGHT && fill_scan_col < HALF_FRAME_WIDTH)
       ? abs_diff_u8(fill_left_disp, disp_map[fill_row][fill_scan_col])
        : 8'hFF;
    assign fill_gap_jump_ok = (fill_gap_jump <= FILL_MAX_DISP_JUMP);
    assign fill_start_apply = fill_scan_valid && fill_gap_present && fill_gap_len_ok && fill_gap_jump_ok;

    integer init_r, init_c;
    always_ff @(posedge clk) begin
        if (rst) begin
            curr_state <= IDLE;
            disp_out_bounds_cnt <= 2'b0;
            x_cnt <= '0;
            phase_cnt <= '0;
            cost_compare_en <= 1'b0;
            reg_phase <= '0;
            reg_col_x <= '0;
            reg_disp  <= '0;

            for (init_r = 0; init_r < FRAME_HEIGHT; init_r++) begin
                for (init_c = 0; init_c < HALF_FRAME_WIDTH; init_c++) begin
                    disp_map[init_r][init_c] <= INVALID_DISP_VALUE;
                    disp_valid_map[init_r][init_c] <= 1'b0;
                end
            end

            for (int i = 0; i < NUM_COST_UNITS; i++) begin
                ref_edge_valid[i] <= 1'b0;
            end

            fill_row <= '0;
            fill_scan_col <= '0;
            fill_have_left <= 1'b0;
            fill_left_col <= '0;
            fill_left_disp <= '0;
            fill_right_col <= '0;
            fill_right_disp <= '0;
            fill_resume_col <= '0;
            fill_write_col <= '0;
            fill_seg_left_col <= '0;
            fill_seg_left_disp <= '0;

            for (int p = 0; p < PIPE_DEPTH; p++) begin
                phase_pipeline[p] <= '0;
                col_x_pipeline[p] <= '0;
                disp_pipeline[p] <= '0;
                valid_rd_pipeline[p] <= 1'b0;
                to_ref_block_pipeline[p] <= 1'b0;
            end
        end else begin
            for (int p = PIPE_DEPTH-1; p > 0; p--) begin
                phase_pipeline[p] <= phase_pipeline[p-1];
                col_x_pipeline[p] <= col_x_pipeline[p-1];
                disp_pipeline[p] <= disp_pipeline[p-1];
                valid_rd_pipeline[p] <= valid_rd_pipeline[p-1];
                to_ref_block_pipeline[p] <= to_ref_block_pipeline[p-1];
            end

            curr_state <= next_state;
            reg_phase <= curr_phase;
            reg_col_x <= curr_col_x;
            reg_disp  <= curr_disp;

            mem_req <= 1'b0;
            slide_reference <= 1'b0;
            slide_matching  <= 1'b0;
            cost_compare_en  <= slide_matching; 

            valid_rd_pipeline <= 1'b0;

            if (next_state == INCR_DISP && curr_state!= INCR_DISP) begin
                for (int i = 0; i < NUM_COST_UNITS; i++) begin
                    best_cost[i] <= {COST_W{1'b1}};
                    best_disp[i] <= '0;
                    ref_edge_valid[i] <= (ref_center_pix[i] >= EDGE_PIXEL_MIN);
                end
            end

            if (curr_state == IDLE && next_state == INCR_PHASE) begin
                fill_row <= '0;
                fill_scan_col <= '0;
                fill_have_left <= 1'b0;
            end

            if (curr_state == INCR_X && next_state == INCR_PHASE) begin
                for (int i = 0; i < NUM_COST_UNITS; i++) begin
                    if (ref_edge_valid[i]) begin
                        disp_map[reg_col_x] <= disp_to_u8(best_disp[i]);
                        disp_valid_map[reg_col_x] <= 1'b1;
                    end else begin
                        disp_map[reg_col_x] <= INVALID_DISP_VALUE;
                        disp_valid_map[reg_col_x] <= 1'b0;
                    end
                end
            end

            case(curr_state) 
                IDLE: begin
                    phase_pipeline <= '0;
                    col_x_pipeline <= '0;
                    disp_pipeline <= '0;
                    valid_rd_pipeline <= 1'b0;
                end

                INCR_DISP: begin
                    x_cnt <= x_cnt_next;
                    phase_cnt <= phase_cnt_next;
                    if (in_disp_bounds) begin
                        mem_req <= 1'b1;
                        mem_bank <= 1'b1; 
                        mem_col <= $signed({1'b0, reg_col_x}) + reg_disp;

                        valid_rd_pipeline <= 1'b1;
                        col_x_pipeline <= reg_col_x;
                        disp_pipeline <= reg_disp;
                        phase_pipeline <= reg_phase;
                        to_ref_block_pipeline <= 1'b0;  
                        
                        disp_out_bounds_cnt <= 0;
                    end else begin 
                        disp_out_bounds_cnt <= disp_out_bounds_cnt + 1;
                    end

                    if (valid_rd_result) begin
                        for (int g = 0; g < NUM_COST_UNITS; g++) begin
                            for (int rr = 0; rr < BLOCK_SIZE; rr++) begin
                                logic row_idx = (g * STRIPE_HEIGHT + phase_result + rr < FRAME_HEIGHT) 
                                   ? (g * STRIPE_HEIGHT + phase_result + rr) 
                                    : (FRAME_HEIGHT - 1);
                                right_col_buf[g][rr] <= mem_rdata[row_idx];
                            end
                        end
                        slide_matching <= 1'b1; 
                    end

                    if (cost_compare_en) begin
                        for (int g = 0; g < NUM_COST_UNITS; g++) begin
                            if (cost_value[g] < best_cost[g]) begin
                                best_cost[g] <= cost_value[g];
                                best_disp[g] <= disp_result;
                            end
                        end
                    end
                end

                INCR_X: begin
                    x_cnt <= x_cnt_next;
                    if (INCR_X_reading_ref) begin
                        mem_req <= 1'b1;
                        mem_bank <= 1'b0; 
                        mem_col <= reg_col_x;

                        col_x_pipeline <= curr_col_x;
                        disp_pipeline <= curr_disp - 1;
                        phase_pipeline <= curr_phase;
                        valid_rd_pipeline <= 1'b1;
                        to_ref_block_pipeline <= 1'b1; 
                    end
                    else if (INCR_X_reading_match) begin
                        mem_req <= 1'b1;
                        mem_bank <= 1'b1; 
                        mem_col <= $signed({1'b0, reg_col_x}) + reg_disp;

                        valid_rd_pipeline <= 1'b1;
                        col_x_pipeline <= curr_col_x - 1;
                        disp_pipeline <= curr_disp - 1;
                        phase_pipeline <= curr_phase;
                        to_ref_block_pipeline <= 1'b0;
                    end

                    if (valid_rd_result && to_ref_block_result) begin
                        for (int g = 0; g < NUM_COST_UNITS; g++) begin
                            for (int rr = 0; rr < BLOCK_SIZE; rr++) begin
                                logic row_idx = (g * STRIPE_HEIGHT + phase_result + rr < FRAME_HEIGHT) 
                                   ? (g * STRIPE_HEIGHT + phase_result + rr) 
                                    : (FRAME_HEIGHT - 1);
                                left_col_buf[g][rr] <= mem_rdata[row_idx];
                            end
                        end
                        slide_reference <= 1'b1; 

                        for (int i = 0; i < NUM_COST_UNITS; i++) begin
                            if (ref_edge_valid[i]) begin
                                disp_map[col_x_result] <= disp_to_u8(best_disp[i]);
                                disp_valid_map[col_x_result] <= 1'b1;
                            end else begin
                                disp_map[col_x_result] <= INVALID_DISP_VALUE;
                                disp_valid_map[col_x_result] <= 1'b0;
                            end
                        end

                    end else if (valid_rd_result &&!to_ref_block_result) begin
                        for (int g = 0; g < NUM_COST_UNITS; g++) begin
                            for (int rr = 0; rr < BLOCK_SIZE; rr++) begin
                                logic row_idx = (g * STRIPE_HEIGHT + phase_result + rr < FRAME_HEIGHT) 
                                   ? (g * STRIPE_HEIGHT + phase_result + rr) 
                                    : (FRAME_HEIGHT - 1);
                                right_col_buf[g][rr] <= mem_rdata[row_idx];
                            end
                        end
                        slide_matching <= 1'b1; 
                    end
                end

                INCR_PHASE: begin
                    phase_cnt <= phase_cnt_next;

                    if (PHASE_ref_read) begin
                        mem_req <= 1'b1;
                        mem_bank <= 1'b0; 
                        mem_col <= curr_col_x;

                        col_x_pipeline <= curr_col_x - 1;
                        disp_pipeline <= curr_disp - 1;
                        phase_pipeline <= curr_phase;
                        valid_rd_pipeline <= 1'b1;
                        to_ref_block_pipeline <= 1'b1; 
                    end
                    else if (PHASE_match_read) begin
                        mem_req <= 1'b1;
                        mem_bank <= 1'b1; 
                        mem_col <= $signed({1'b0, curr_col_x}) + curr_disp;

                        valid_rd_pipeline <= 1'b1;
                        col_x_pipeline <= curr_col_x - 1;
                        disp_pipeline <= curr_disp - 1;
                        phase_pipeline <= curr_phase;
                        to_ref_block_pipeline <= 1'b0;
                    end else begin
                        valid_rd_pipeline <= 1'b0;
                    end
                    
                    if (valid_rd_result && to_ref_block_result) begin
                        for (int g = 0; g < NUM_COST_UNITS; g++) begin
                            for (int rr = 0; rr < BLOCK_SIZE; rr++) begin
                                left_col_buf[g][rr] <= mem_rdata;
                            end
                        end
                        slide_reference <= 1'b1; 
                    end else if (valid_rd_result &&!to_ref_block_result) begin
                        for (int g = 0; g < NUM_COST_UNITS; g++) begin
                            for (int rr = 0; rr < BLOCK_SIZE; rr++) begin
                                right_col_buf[g][rr] <= mem_rdata;
                            end
                        end
                        slide_matching <= 1'b1; 
                    end
                end

                FILL_SCAN: begin
                    if (fill_row < FRAME_HEIGHT) begin
                        if (fill_scan_col >= HALF_FRAME_WIDTH) begin
                            fill_row <= fill_row + 1'b1;
                            fill_scan_col <= '0;
                            fill_have_left <= 1'b0;
                        end else if (fill_scan_valid) begin
                            if (fill_start_apply) begin
                                fill_right_col <= fill_scan_col;
                                fill_right_disp <= disp_map[fill_row][fill_scan_col];
                                fill_seg_left_col <= fill_left_col;
                                fill_seg_left_disp <= fill_left_disp;
                                fill_write_col <= fill_left_col + 1'b1;
                                fill_resume_col <= fill_scan_col + 1'b1;
                            end else begin
                                fill_left_col <= fill_scan_col;
                                fill_left_disp <= disp_map[fill_row][fill_scan_col];
                                fill_have_left <= 1'b1;
                                fill_scan_col <= fill_scan_col + 1'b1;
                            end
                        end else begin
                            fill_scan_col <= fill_scan_col + 1'b1;
                        end
                    end
                end

                FILL_APPLY: begin
                    if (fill_write_col < fill_right_col) begin
                        if ((fill_write_col - fill_seg_left_col) <= (fill_right_col - fill_write_col)) begin
                            disp_map[fill_row][fill_write_col] <= fill_seg_left_disp;
                        end else begin
                            disp_map[fill_row][fill_write_col] <= fill_right_disp;
                        end
                        disp_valid_map[fill_row][fill_write_col] <= 1'b1;
                        fill_write_col <= fill_write_col + 1'b1;
                    end else begin
                        fill_left_col <= fill_right_col;
                        fill_left_disp <= fill_right_disp;
                        fill_have_left <= 1'b1;
                        fill_scan_col <= fill_resume_col;
                    end
                end

                default:
                    assert(0);
            endcase
        end
    end 

    always_comb begin 
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
                        curr_disp = reg_disp; 
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
                        curr_disp = '0; 
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
                    curr_disp = '0; 
                    curr_phase = reg_phase + 1;
                end
            end
            INCR_PHASE: begin
                phase_cnt_next = phase_cnt + 1;
                if (reg_phase <= MAX_PHASE_L) begin
                    if (phase_complete) begin
                        next_state = INCR_DISP;
                        curr_col_x = BLOCK_SIZE - 1; 
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
                    next_state = FILL_SCAN;
                end
            end
            FILL_SCAN: begin
                if (fill_row >= FRAME_HEIGHT) begin
                    next_state = IDLE;
                end else if (fill_start_apply) begin
                    next_state = FILL_APPLY;
                end else begin
                    next_state = FILL_SCAN;
                end
            end
            FILL_APPLY: begin
                if (fill_write_col < fill_right_col) begin
                    next_state = FILL_APPLY;
                end else begin
                    next_state = FILL_SCAN;
                end
            end
            default:
                assert(0);
        endcase
    end 
endmodule