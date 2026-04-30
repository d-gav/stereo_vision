module stereo_poly_mapper_deg6_q18 (
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

localparam integer FULL_FRAME_WIDTH  = 640;
localparam integer FRAME_HEIGHT      = 288;
localparam integer LEFT_LUT_WIDTH    = 315;
localparam integer INTER_CAMERA_GAP  = 4;
localparam integer RIGHT_OUTPUT_X_START = LEFT_LUT_WIDTH + INTER_CAMERA_GAP;
localparam integer RIGHT_LUT_WIDTH   = 315;

localparam signed [26:0] SCALE = 27'sd262144;      // Q18 1.0

localparam [2:0] ST_IDLE        = 3'd0;
localparam [2:0] ST_INNER_SEED  = 3'd1;
localparam [2:0] ST_INNER_STEP  = 3'd2;
localparam [2:0] ST_OUTER_ACCUM = 3'd3;
localparam [2:0] ST_DENORM      = 3'd4;
localparam [2:0] ST_DONE        = 3'd5;

wire side_right_in;
wire [9:0] local_x_in;
wire in_active_region;

reg [2:0] state;
reg side_right;
reg [9:0] local_x;

reg signed [26:0] xn_q;
reg signed [26:0] yn_q;

reg signed [26:0] qx_q;
reg signed [26:0] qy_q;
reg signed [26:0] acc_xn_q;
reg signed [26:0] acc_yn_q;

reg [2:0] i_pow;
reg [2:0] j_pow;

reg signed [15:0] den_x;
reg signed [15:0] den_y;
reg signed [15:0] den_gx;

assign side_right_in = (dst_x >= RIGHT_OUTPUT_X_START);
assign local_x_in = side_right_in ? (dst_x - RIGHT_OUTPUT_X_START) : dst_x;
assign in_active_region =
    (dst_y < FRAME_HEIGHT) &&
    ((dst_x < LEFT_LUT_WIDTH) ||
     ((dst_x >= RIGHT_OUTPUT_X_START) && (dst_x < (RIGHT_OUTPUT_X_START + RIGHT_LUT_WIDTH))));

function signed [26:0] mul_q18;
    input signed [26:0] a;
    input signed [26:0] b;
    reg signed [53:0] prod;
begin
    prod = a * b;
    if (prod >= 0)
        mul_q18 = (prod + 54'sd131072) >>> 18;
    else
        mul_q18 = (prod - 54'sd131072) >>> 18;
end
endfunction

function signed [26:0] norm_x_q18;
    input signed [11:0] raw;
    reg signed [25:0] prod;
begin
    // Approximate (raw * 2^18) / 314 with fixed reciprocal and /4.
    prod = raw * 13'sd3341;
    if (prod >= 0)
        norm_x_q18 = (prod + 26'sd2) >>> 2;
    else
        norm_x_q18 = (prod - 26'sd2) >>> 2;
end
endfunction

function signed [26:0] norm_y_q18;
    input signed [11:0] raw;
    reg signed [25:0] prod;
begin
    // Approximate (raw * 2^18) / 287 with fixed reciprocal and /4.
    prod = raw * 13'sd3654;
    if (prod >= 0)
        norm_y_q18 = (prod + 26'sd2) >>> 2;
    else
        norm_y_q18 = (prod - 26'sd2) >>> 2;
end
endfunction

function [5:0] term_idx_from_xy;
    input [2:0] ix;
    input [2:0] iy;
    reg [3:0] degree;
    reg [5:0] base;
begin
    degree = ix + iy;
    case (degree)
        4'd0: base = 6'd0;
        4'd1: base = 6'd1;
        4'd2: base = 6'd3;
        4'd3: base = 6'd6;
        4'd4: base = 6'd10;
        4'd5: base = 6'd15;
        default: base = 6'd21;
    endcase
    term_idx_from_xy = base + iy;
end
endfunction

function signed [19:0] coeff_x;
    input side_right_sel;
    input [5:0] idx;
begin
    if (side_right_sel) begin
        case (idx)
            6'd0: coeff_x = -20'sd29517;
            6'd1: coeff_x = 20'sd295824;
            6'd2: coeff_x = 20'sd1459;
            6'd3: coeff_x = 20'sd58333;
            6'd4: coeff_x = -20'sd8389;
            6'd5: coeff_x = 20'sd12742;
            6'd6: coeff_x = -20'sd86242;
            6'd7: coeff_x = -20'sd3344;
            6'd8: coeff_x = -20'sd60167;
            6'd9: coeff_x = -20'sd610;
            6'd10: coeff_x = -20'sd42017;
            6'd11: coeff_x = 20'sd6205;
            6'd12: coeff_x = -20'sd31505;
            6'd13: coeff_x = 20'sd4842;
            6'd14: coeff_x = -20'sd2648;
            6'd15: coeff_x = 20'sd20188;
            6'd16: coeff_x = 20'sd1552;
            6'd17: coeff_x = 20'sd26691;
            6'd18: coeff_x = 20'sd1239;
            6'd19: coeff_x = 20'sd9320;
            6'd20: coeff_x = -20'sd14;
            6'd21: coeff_x = 20'sd13219;
            6'd22: coeff_x = -20'sd1685;
            6'd23: coeff_x = 20'sd16425;
            6'd24: coeff_x = -20'sd2683;
            6'd25: coeff_x = 20'sd5620;
            6'd26: coeff_x = -20'sd1086;
            6'd27: coeff_x = -20'sd82;
            default: coeff_x = 20'sd0;
        endcase
    end else begin
        case (idx)
            6'd0: coeff_x = 20'sd32735;
            6'd1: coeff_x = 20'sd292793;
            6'd2: coeff_x = -20'sd1334;
            6'd3: coeff_x = -20'sd63913;
            6'd4: coeff_x = -20'sd6567;
            6'd5: coeff_x = -20'sd14494;
            6'd6: coeff_x = -20'sd82672;
            6'd7: coeff_x = 20'sd2891;
            6'd8: coeff_x = -20'sd58729;
            6'd9: coeff_x = 20'sd695;
            6'd10: coeff_x = 20'sd44300;
            6'd11: coeff_x = 20'sd4675;
            6'd12: coeff_x = 20'sd33284;
            6'd13: coeff_x = 20'sd3584;
            6'd14: coeff_x = 20'sd4218;
            6'd15: coeff_x = 20'sd18713;
            6'd16: coeff_x = -20'sd1293;
            6'd17: coeff_x = 20'sd25786;
            6'd18: coeff_x = -20'sd979;
            6'd19: coeff_x = 20'sd9105;
            6'd20: coeff_x = -20'sd168;
            6'd21: coeff_x = -20'sd13424;
            6'd22: coeff_x = -20'sd1178;
            6'd23: coeff_x = -20'sd16311;
            6'd24: coeff_x = -20'sd2027;
            6'd25: coeff_x = -20'sd6011;
            6'd26: coeff_x = -20'sd665;
            6'd27: coeff_x = -20'sd778;
            default: coeff_x = 20'sd0;
        endcase
    end
end
endfunction

function signed [19:0] coeff_y;
    input side_right_sel;
    input [5:0] idx;
begin
    if (side_right_sel) begin
        case (idx)
            6'd0: coeff_y = 20'sd6887;
            6'd1: coeff_y = 20'sd2206;
            6'd2: coeff_y = 20'sd302916;
            6'd3: coeff_y = -20'sd6107;
            6'd4: coeff_y = 20'sd38843;
            6'd5: coeff_y = -20'sd13999;
            6'd6: coeff_y = -20'sd1551;
            6'd7: coeff_y = -20'sd89229;
            6'd8: coeff_y = -20'sd3596;
            6'd9: coeff_y = -20'sd68789;
            6'd10: coeff_y = 20'sd1970;
            6'd11: coeff_y = -20'sd31260;
            6'd12: coeff_y = 20'sd10958;
            6'd13: coeff_y = -20'sd22090;
            6'd14: coeff_y = 20'sd7622;
            6'd15: coeff_y = 20'sd292;
            6'd16: coeff_y = 20'sd18914;
            6'd17: coeff_y = 20'sd2047;
            6'd18: coeff_y = 20'sd30577;
            6'd19: coeff_y = 20'sd1156;
            6'd20: coeff_y = 20'sd13615;
            6'd21: coeff_y = -20'sd183;
            6'd22: coeff_y = 20'sd9223;
            6'd23: coeff_y = -20'sd2887;
            6'd24: coeff_y = 20'sd13204;
            6'd25: coeff_y = -20'sd4420;
            6'd26: coeff_y = 20'sd4552;
            6'd27: coeff_y = -20'sd1863;
            default: coeff_y = 20'sd0;
        endcase
    end else begin
        case (idx)
            6'd0: coeff_y = 20'sd5590;
            6'd1: coeff_y = -20'sd1958;
            6'd2: coeff_y = 20'sd301804;
            6'd3: coeff_y = -20'sd4776;
            6'd4: coeff_y = -20'sd43156;
            6'd5: coeff_y = -20'sd11265;
            6'd6: coeff_y = 20'sd1286;
            6'd7: coeff_y = -20'sd87622;
            6'd8: coeff_y = 20'sd3128;
            6'd9: coeff_y = -20'sd67830;
            6'd10: coeff_y = 20'sd1524;
            6'd11: coeff_y = 20'sd33909;
            6'd12: coeff_y = 20'sd8161;
            6'd13: coeff_y = 20'sd23946;
            6'd14: coeff_y = 20'sd6235;
            6'd15: coeff_y = -20'sd244;
            6'd16: coeff_y = 20'sd18373;
            6'd17: coeff_y = -20'sd1598;
            6'd18: coeff_y = 20'sd29918;
            6'd19: coeff_y = -20'sd1023;
            6'd20: coeff_y = 20'sd13294;
            6'd21: coeff_y = -20'sd185;
            6'd22: coeff_y = -20'sd9678;
            6'd23: coeff_y = -20'sd2008;
            6'd24: coeff_y = -20'sd13902;
            6'd25: coeff_y = -20'sd3155;
            6'd26: coeff_y = -20'sd4768;
            6'd27: coeff_y = -20'sd1634;
            default: coeff_y = 20'sd0;
        endcase
    end
end
endfunction

function signed [26:0] coeff_x_q18;
    input side_right_sel;
    input [2:0] ix;
    input [2:0] iy;
begin
    coeff_x_q18 = $signed(coeff_x(side_right_sel, term_idx_from_xy(ix, iy)));
end
endfunction

function signed [26:0] coeff_y_q18;
    input side_right_sel;
    input [2:0] ix;
    input [2:0] iy;
begin
    coeff_y_q18 = $signed(coeff_y(side_right_sel, term_idx_from_xy(ix, iy)));
end
endfunction

function signed [15:0] denorm_q18_to_px;
    input signed [26:0] v_q18;
    input [9:0] max_px;
    reg signed [37:0] numer;
begin
    numer = (v_q18 + SCALE) * $signed({1'b0, max_px});
    if (numer >= 0)
        denorm_q18_to_px = (numer + 38'sd262144) >>> 19;
    else
        denorm_q18_to_px = (numer - 38'sd262144) >>> 19;
end
endfunction

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        state <= ST_IDLE;
        side_right <= 1'b0;
        local_x <= 10'd0;
        xn_q <= 27'sd0;
        yn_q <= 27'sd0;
        qx_q <= 27'sd0;
        qy_q <= 27'sd0;
        acc_xn_q <= 27'sd0;
        acc_yn_q <= 27'sd0;
        i_pow <= 3'd0;
        j_pow <= 3'd0;
        den_x <= 16'sd0;
        den_y <= 16'sd0;
        den_gx <= 16'sd0;
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
                    side_right <= side_right_in;
                    local_x <= local_x_in;
                    if (in_active_region) begin
                        xn_q <= norm_x_q18(($signed({1'b0, local_x_in}) <<< 1) - 12'sd314);
                        yn_q <= norm_y_q18(($signed({1'b0, dst_y}) <<< 1) - 12'sd287);
                        i_pow <= 3'd6;
                        busy <= 1'b1;
                        state <= ST_INNER_SEED;
                    end else begin
                        src_x <= 10'd0;
                        src_y <= 10'd0;
                        valid <= 1'b0;
                        done <= 1'b1;
                    end
                end
            end

            ST_INNER_SEED: begin
                if (i_pow == 3'd6) begin
                    qx_q <= coeff_x_q18(side_right, i_pow, 3'd0);
                    qy_q <= coeff_y_q18(side_right, i_pow, 3'd0);
                    state <= ST_OUTER_ACCUM;
                end else begin
                    qx_q <= coeff_x_q18(side_right, i_pow, (3'd6 - i_pow));
                    qy_q <= coeff_y_q18(side_right, i_pow, (3'd6 - i_pow));
                    j_pow <= (3'd6 - i_pow) - 1'b1;
                    state <= ST_INNER_STEP;
                end
            end

            ST_INNER_STEP: begin
                qx_q <= mul_q18(qx_q, yn_q) + coeff_x_q18(side_right, i_pow, j_pow);
                qy_q <= mul_q18(qy_q, yn_q) + coeff_y_q18(side_right, i_pow, j_pow);
                if (j_pow == 3'd0)
                    state <= ST_OUTER_ACCUM;
                else
                    j_pow <= j_pow - 1'b1;
            end

            ST_OUTER_ACCUM: begin
                if (i_pow == 3'd6) begin
                    acc_xn_q <= qx_q;
                    acc_yn_q <= qy_q;
                end else begin
                    acc_xn_q <= mul_q18(acc_xn_q, xn_q) + qx_q;
                    acc_yn_q <= mul_q18(acc_yn_q, xn_q) + qy_q;
                end

                if (i_pow == 3'd0)
                    state <= ST_DENORM;
                else begin
                    i_pow <= i_pow - 1'b1;
                    state <= ST_INNER_SEED;
                end
            end

            ST_DENORM: begin
                den_x = denorm_q18_to_px(acc_xn_q, 10'd314);
                den_y = denorm_q18_to_px(acc_yn_q, 10'd287);

                if ((den_x >= 0) && (den_x < 16'sd315) &&
                    (den_y >= 0) && (den_y < 16'sd288)) begin

                    den_gx = side_right ? (den_x + RIGHT_OUTPUT_X_START) : den_x;
                    if ((den_gx >= 0) && (den_gx < FULL_FRAME_WIDTH)) begin
                        src_x <= den_gx[9:0];
                        src_y <= den_y[9:0];
                        valid <= 1'b1;
                    end else begin
                        src_x <= 10'd0;
                        src_y <= 10'd0;
                        valid <= 1'b0;
                    end
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
