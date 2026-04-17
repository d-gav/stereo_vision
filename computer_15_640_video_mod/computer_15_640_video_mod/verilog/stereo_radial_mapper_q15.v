module stereo_radial_mapper_q15 (
    input wire clk,
    input wire reset_n,
    input wire start,
    input wire [9:0] dst_x,
    input wire [9:0] dst_y,
    output reg [9:0] src_x,
    output reg [9:0] src_y,
    output reg valid,
    output reg done,
    output reg busy
);

localparam integer FULL_FRAME_WIDTH      = 640;
localparam integer FRAME_HEIGHT          = 288;
localparam integer LEFT_LUT_WIDTH        = 315;
localparam integer INTER_CAMERA_GAP      = 4;
localparam integer RIGHT_OUTPUT_X_START  = LEFT_LUT_WIDTH + INTER_CAMERA_GAP;
localparam integer RIGHT_LUT_WIDTH       = 315;

localparam integer LUT_LAST_INDEX        = 255;
localparam integer R2_TO_POS_Q16         = 92;

localparam [1:0] ST_IDLE = 2'd0;
localparam [1:0] ST_CALC = 2'd1;
localparam [1:0] ST_DONE = 2'd2;

wire side_right_in;
wire [9:0] local_x_in;
wire in_active_region;

reg [1:0] state;
reg side_right_r;
reg [9:0] dst_x_r;
reg [9:0] dst_y_r;
reg [9:0] local_x_r;

reg signed [18:0] dx_q8;
reg signed [18:0] dy_q8;
reg signed [11:0] dx_h;
reg signed [11:0] dy_h;
reg [24:0] r2_h;
reg [31:0] pos_q16;
reg [7:0] idx;
reg [15:0] frac;
reg signed [17:0] s0_q15;
reg signed [17:0] s1_q15;
reg signed [18:0] s_diff_q15;
reg signed [18:0] scale_q15;
reg signed [37:0] interp_prod;
reg signed [37:0] x_scaled_prod;
reg signed [37:0] y_scaled_prod;
reg signed [23:0] sx_q8;
reg signed [23:0] sy_q8;
reg signed [12:0] sx_i;
reg signed [12:0] sy_i;
reg signed [12:0] gx_i;

assign side_right_in = (dst_x >= RIGHT_OUTPUT_X_START);
assign local_x_in = side_right_in ? (dst_x - RIGHT_OUTPUT_X_START) : dst_x;
assign in_active_region =
    (dst_y < FRAME_HEIGHT) &&
    ((dst_x < LEFT_LUT_WIDTH) ||
     ((dst_x >= RIGHT_OUTPUT_X_START) &&
      (dst_x < (RIGHT_OUTPUT_X_START + RIGHT_LUT_WIDTH))));

function signed [18:0] side_cdx_q8;
    input side_right_sel;
begin
    side_cdx_q8 = side_right_sel ? 19'sd46592 : 19'sd33792;
end
endfunction

function signed [18:0] side_cdy_q8;
    input side_right_sel;
begin
    side_cdy_q8 = side_right_sel ? 19'sd34944 : 19'sd35200;
end
endfunction

function signed [23:0] side_csx_q8;
    input side_right_sel;
begin
    side_csx_q8 = side_right_sel ? 24'sd43346 : 24'sd37312;
end
endfunction

function signed [23:0] side_csy_q8;
    input side_right_sel;
begin
    side_csy_q8 = side_right_sel ? 24'sd35533 : 24'sd35700;
end
endfunction

function signed [12:0] round_q8_to_int;
    input signed [23:0] v_q8;
    reg signed [23:0] tmp;
begin
    if (v_q8 >= 0)
        tmp = v_q8 + 24'sd128;
    else
        tmp = v_q8 - 24'sd128;
    round_q8_to_int = tmp >>> 8;
end
endfunction

`include "radial_scale_lut_q15.vh"

function signed [17:0] side_scale_q15;
    input side_right_sel;
    input [7:0] lut_idx;
begin
    side_scale_q15 = side_right_sel ? right_scale_q15(lut_idx) : left_scale_q15(lut_idx);
end
endfunction

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        state <= ST_IDLE;
        side_right_r <= 1'b0;
        dst_x_r <= 10'd0;
        dst_y_r <= 10'd0;
        local_x_r <= 10'd0;
        dx_q8 <= 19'sd0;
        dy_q8 <= 19'sd0;
        dx_h <= 12'sd0;
        dy_h <= 12'sd0;
        r2_h <= 25'd0;
        pos_q16 <= 32'd0;
        idx <= 8'd0;
        frac <= 16'd0;
        s0_q15 <= 18'sd0;
        s1_q15 <= 18'sd0;
        s_diff_q15 <= 19'sd0;
        scale_q15 <= 19'sd0;
        interp_prod <= 38'sd0;
        x_scaled_prod <= 38'sd0;
        y_scaled_prod <= 38'sd0;
        sx_q8 <= 24'sd0;
        sy_q8 <= 24'sd0;
        sx_i <= 13'sd0;
        sy_i <= 13'sd0;
        gx_i <= 13'sd0;
        src_x <= 10'd0;
        src_y <= 10'd0;
        valid <= 1'b0;
        done <= 1'b0;
        busy <= 1'b0;
    end else begin
        done <= 1'b0;

        case (state)
            ST_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    side_right_r <= side_right_in;
                    dst_x_r <= dst_x;
                    dst_y_r <= dst_y;
                    local_x_r <= local_x_in;
                    if (in_active_region) begin
                        busy <= 1'b1;
                        state <= ST_CALC;
                    end else begin
                        src_x <= 10'd0;
                        src_y <= 10'd0;
                        valid <= 1'b0;
                        done <= 1'b1;
                    end
                end
            end

            ST_CALC: begin
                dx_q8 = ($signed({1'b0, local_x_r}) <<< 8) - side_cdx_q8(side_right_r);
                dy_q8 = ($signed({1'b0, dst_y_r}) <<< 8) - side_cdy_q8(side_right_r);

                dx_h = dx_q8 >>> 7;
                dy_h = dy_q8 >>> 7;
                r2_h = ($signed(dx_h) * $signed(dx_h)) + ($signed(dy_h) * $signed(dy_h));

                pos_q16 = r2_h * R2_TO_POS_Q16;
                if (pos_q16[31:16] >= LUT_LAST_INDEX) begin
                    idx = LUT_LAST_INDEX[7:0];
                    frac = 16'd0;
                end else begin
                    idx = pos_q16[23:16];
                    frac = pos_q16[15:0];
                end

                s0_q15 = side_scale_q15(side_right_r, idx);
                if (idx == LUT_LAST_INDEX[7:0])
                    s1_q15 = s0_q15;
                else
                    s1_q15 = side_scale_q15(side_right_r, idx + 8'd1);

                s_diff_q15 = $signed({s1_q15[17], s1_q15}) - $signed({s0_q15[17], s0_q15});
                interp_prod = s_diff_q15 * $signed({1'b0, frac});
                if (interp_prod >= 0)
                    scale_q15 = $signed({s0_q15[17], s0_q15}) + ((interp_prod + 38'sd32768) >>> 16);
                else
                    scale_q15 = $signed({s0_q15[17], s0_q15}) + ((interp_prod - 38'sd32768) >>> 16);

                x_scaled_prod = dx_q8 * scale_q15;
                y_scaled_prod = dy_q8 * scale_q15;

                if (x_scaled_prod >= 0)
                    sx_q8 = side_csx_q8(side_right_r) + ((x_scaled_prod + 38'sd16384) >>> 15);
                else
                    sx_q8 = side_csx_q8(side_right_r) + ((x_scaled_prod - 38'sd16384) >>> 15);

                if (y_scaled_prod >= 0)
                    sy_q8 = side_csy_q8(side_right_r) + ((y_scaled_prod + 38'sd16384) >>> 15);
                else
                    sy_q8 = side_csy_q8(side_right_r) + ((y_scaled_prod - 38'sd16384) >>> 15);

                sx_i = round_q8_to_int(sx_q8);
                sy_i = round_q8_to_int(sy_q8);
                gx_i = side_right_r ? (sx_i + RIGHT_OUTPUT_X_START) : sx_i;

                if ((sx_i >= 0) && (sx_i < LEFT_LUT_WIDTH) &&
                    (sy_i >= 0) && (sy_i < FRAME_HEIGHT) &&
                    (gx_i >= 0) && (gx_i < FULL_FRAME_WIDTH)) begin
                    src_x <= gx_i[9:0];
                    src_y <= sy_i[9:0];
                    valid <= 1'b1;
                end else begin
                    src_x <= 10'd0;
                    src_y <= 10'd0;
                    valid <= 1'b0;
                end

                state <= ST_DONE;
            end

            ST_DONE: begin
                busy <= 1'b0;
                done <= 1'b1;
                state <= ST_IDLE;
            end

            default: begin
                state <= ST_IDLE;
            end
        endcase
    end
end

endmodule
