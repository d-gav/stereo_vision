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

localparam signed [12:0] LEFT_LUT_WIDTH_S       = 13'sd315;
localparam signed [12:0] FRAME_HEIGHT_S         = 13'sd288;
localparam signed [12:0] FULL_FRAME_WIDTH_S     = 13'sd640;

localparam [3:0] ST_IDLE   = 4'd0;
localparam [3:0] ST_VEC    = 4'd1;
localparam [3:0] ST_R2     = 4'd2;
localparam [3:0] ST_POS    = 4'd3;
localparam [3:0] ST_LUT    = 4'd4;
localparam [3:0] ST_INTERP = 4'd5;
localparam [3:0] ST_SCALE  = 4'd6;
localparam [3:0] ST_MUL    = 4'd7;
localparam [3:0] ST_OFFSET = 4'd8;
localparam [3:0] ST_CHECK  = 4'd9;
localparam [3:0] ST_DONE   = 4'd10;

wire side_right_in;
wire [9:0] local_x_in;
wire in_active_region;
wire signed [12:0] sx_i_w;
wire signed [12:0] sy_i_w;
wire signed [12:0] gx_i_w;

reg [3:0] state;
reg side_right_r;
reg [9:0] dst_x_r;
reg [9:0] dst_y_r;
reg [9:0] local_x_r;
reg signed [18:0] cdx_q8_r;
reg signed [18:0] cdy_q8_r;
reg signed [23:0] csx_q8_r;
reg signed [23:0] csy_q8_r;

reg signed [18:0] dx_q8;
reg signed [18:0] dy_q8;
reg [24:0] r2_h;
reg [31:0] pos_q16;
reg [7:0] idx;
reg [15:0] frac;
reg signed [17:0] s0_q15;
reg signed [17:0] s1_q15;
reg signed [18:0] scale_q15;
reg signed [37:0] interp_prod;
reg signed [37:0] x_scaled_prod;
reg signed [37:0] y_scaled_prod;
reg signed [23:0] sx_q8;
reg signed [23:0] sy_q8;

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

assign sx_i_w = round_q8_to_int(sx_q8);
assign sy_i_w = round_q8_to_int(sy_q8);
assign gx_i_w = side_right_r ? (sx_i_w + RIGHT_OUTPUT_X_START) : sx_i_w;

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
        cdx_q8_r <= 19'sd0;
        cdy_q8_r <= 19'sd0;
        csx_q8_r <= 24'sd0;
        csy_q8_r <= 24'sd0;
        dx_q8 <= 19'sd0;
        dy_q8 <= 19'sd0;
        r2_h <= 25'd0;
        pos_q16 <= 32'd0;
        idx <= 8'd0;
        frac <= 16'd0;
        s0_q15 <= 18'sd0;
        s1_q15 <= 18'sd0;
        scale_q15 <= 19'sd0;
        interp_prod <= 38'sd0;
        x_scaled_prod <= 38'sd0;
        y_scaled_prod <= 38'sd0;
        sx_q8 <= 24'sd0;
        sy_q8 <= 24'sd0;
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
                    cdx_q8_r <= side_cdx_q8(side_right_in);
                    cdy_q8_r <= side_cdy_q8(side_right_in);
                    csx_q8_r <= side_csx_q8(side_right_in);
                    csy_q8_r <= side_csy_q8(side_right_in);
                    if (in_active_region) begin
                        busy <= 1'b1;
                        state <= ST_VEC;
                    end else begin
                        src_x <= 10'd0;
                        src_y <= 10'd0;
                        valid <= 1'b0;
                        done <= 1'b1;
                    end
                end
            end

            ST_VEC: begin
                dx_q8 <= ($signed({1'b0, local_x_r}) <<< 8) - cdx_q8_r;
                dy_q8 <= ($signed({1'b0, dst_y_r}) <<< 8) - cdy_q8_r;
                state <= ST_R2;
            end

            ST_R2: begin
                r2_h <= ($signed(dx_q8 >>> 7) * $signed(dx_q8 >>> 7)) +
                        ($signed(dy_q8 >>> 7) * $signed(dy_q8 >>> 7));
                state <= ST_POS;
            end

            ST_POS: begin
                pos_q16 <= r2_h * R2_TO_POS_Q16;
                state <= ST_LUT;
            end

            ST_LUT: begin
                if (pos_q16[31:16] >= LUT_LAST_INDEX) begin
                    idx <= LUT_LAST_INDEX[7:0];
                    frac <= 16'd0;
                    s0_q15 <= side_scale_q15(side_right_r, LUT_LAST_INDEX[7:0]);
                    s1_q15 <= side_scale_q15(side_right_r, LUT_LAST_INDEX[7:0]);
                end else begin
                    idx <= pos_q16[23:16];
                    frac <= pos_q16[15:0];
                    s0_q15 <= side_scale_q15(side_right_r, pos_q16[23:16]);
                    s1_q15 <= side_scale_q15(side_right_r, pos_q16[23:16] + 8'd1);
                end
                state <= ST_INTERP;
            end

            ST_INTERP: begin
                interp_prod <= ($signed({s1_q15[17], s1_q15}) - $signed({s0_q15[17], s0_q15})) *
                               $signed({1'b0, frac});
                state <= ST_SCALE;
            end

            ST_SCALE: begin
                if (interp_prod >= 0)
                    scale_q15 <= $signed({s0_q15[17], s0_q15}) + ((interp_prod + 38'sd32768) >>> 16);
                else
                    scale_q15 <= $signed({s0_q15[17], s0_q15}) + ((interp_prod - 38'sd32768) >>> 16);
                state <= ST_MUL;
            end

            ST_MUL: begin
                x_scaled_prod <= dx_q8 * scale_q15;
                y_scaled_prod <= dy_q8 * scale_q15;
                state <= ST_OFFSET;
            end

            ST_OFFSET: begin
                if (x_scaled_prod >= 0)
                    sx_q8 <= csx_q8_r + ((x_scaled_prod + 38'sd16384) >>> 15);
                else
                    sx_q8 <= csx_q8_r + ((x_scaled_prod - 38'sd16384) >>> 15);

                if (y_scaled_prod >= 0)
                    sy_q8 <= csy_q8_r + ((y_scaled_prod + 38'sd16384) >>> 15);
                else
                    sy_q8 <= csy_q8_r + ((y_scaled_prod - 38'sd16384) >>> 15);

                state <= ST_CHECK;
            end

            ST_CHECK: begin
                if ((sx_i_w >= 0) && (sx_i_w < LEFT_LUT_WIDTH_S) &&
                    (sy_i_w >= 0) && (sy_i_w < FRAME_HEIGHT_S) &&
                    (gx_i_w >= 0) && (gx_i_w < FULL_FRAME_WIDTH_S)) begin
                    src_x <= gx_i_w[9:0];
                    src_y <= sy_i_w[9:0];
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
