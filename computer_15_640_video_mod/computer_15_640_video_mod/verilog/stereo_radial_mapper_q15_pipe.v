// =============================================================================
// stereo_radial_mapper_q15_pipe
//
// Pipelined version of stereo_radial_mapper_q15. Drop one (dst_x, dst_y,
// valid_in) per clock cycle; receive the corresponding (src_x, src_y,
// valid_out) PIPE_LATENCY cycles later. Throughput: 1 pixel / cycle.
//
// The pipeline mirrors stage-for-stage what the FSM in stereo_radial_mapper_q15
// did, with each former state becoming a registered pipeline stage. The LUT
// lookup that used to happen "in" ST_LUT (combinational case) is now a
// synchronous 1-cycle read inferred as M10K, which is what made the cost a
// pipeline stage of its own.
//
// Stage map (FSM state -> pipe stage):
//   ST_IDLE (input latch + center lookup)  -> S1
//   ST_VEC                                 -> S2
//   ST_R2                                  -> S3
//   ST_POS                                 -> S4
//   ST_LUT (addr + sync ROM read)          -> S5
//   ST_INTERP                              -> S6
//   ST_SCALE                               -> S7
//   ST_MUL                                 -> S8
//   ST_OFFSET                              -> S9
//   ST_CHECK part 1 (round Q8 -> int)      -> S10
//   ST_CHECK part 2 (bounds check + emit)  -> S11
//
// PIPE_LATENCY = 11.
//
// Bit-exact with stereo_radial_mapper_q15 for any input that the FSM accepts:
// the per-stage arithmetic, widths, rounding constants, and sign extensions
// match line-for-line.
// =============================================================================

module stereo_radial_mapper_q15_pipe (
    input  wire        clk,
    input  wire        reset_n,
    input  wire        valid_in,
    input  wire [9:0]  dst_x,
    input  wire [9:0]  dst_y,
    output reg  [9:0]  src_x,
    output reg  [9:0]  src_y,
    output reg         valid_out
);

// ---- Geometry constants (same as stereo_radial_mapper_q15.v) ----
localparam integer FRAME_HEIGHT          = 288;
localparam integer LEFT_LUT_WIDTH        = 315;
localparam integer INTER_CAMERA_GAP      = 4;
localparam integer RIGHT_OUTPUT_X_START  = LEFT_LUT_WIDTH + INTER_CAMERA_GAP;
localparam integer RIGHT_LUT_WIDTH       = 315;

localparam integer LUT_LAST_INDEX        = 255;
localparam integer R2_TO_POS_Q16         = 92;

localparam signed [12:0] LEFT_LUT_WIDTH_S    = 13'sd315;
localparam signed [12:0] FRAME_HEIGHT_S      = 13'sd288;
localparam signed [12:0] FULL_FRAME_WIDTH_S  = 13'sd640;

localparam integer PIPE_LATENCY = 11;

// LUT data (same case-statement-based ROM the FSM uses; called synchronously
// below so Quartus infers a registered M10K rather than wide combinational logic).
`include "radial_scale_lut_q15.vh"

// ---- Helper functions for per-side calibration constants ----
function signed [18:0] cdx_of;
    input side;
begin
    cdx_of = side ? 19'sd46592 : 19'sd33792;
end
endfunction

function signed [18:0] cdy_of;
    input side;
begin
    cdy_of = side ? 19'sd34944 : 19'sd35200;
end
endfunction

function signed [23:0] csx_of;
    input side;
begin
    csx_of = side ? 24'sd43346 : 24'sd37312;
end
endfunction

function signed [23:0] csy_of;
    input side;
begin
    csy_of = side ? 24'sd35533 : 24'sd35700;
end
endfunction

function signed [12:0] round_q8_to_int;
    input signed [23:0] v_q8;
    reg   signed [23:0] tmp;
begin
    if (v_q8 >= 0)
        tmp = v_q8 + 24'sd128;
    else
        tmp = v_q8 - 24'sd128;
    round_q8_to_int = tmp >>> 8;
end
endfunction

// =============================================================================
// Stage 1 input combinational (consumed by the S1 register at posedge)
// =============================================================================
wire        s0_side       = (dst_x >= RIGHT_OUTPUT_X_START);
wire [9:0]  s0_local_x    = s0_side ? (dst_x - RIGHT_OUTPUT_X_START) : dst_x;
wire        s0_in_active  = (dst_y < FRAME_HEIGHT) &&
                            ((dst_x < LEFT_LUT_WIDTH) ||
                             ((dst_x >= RIGHT_OUTPUT_X_START) &&
                              (dst_x < (RIGHT_OUTPUT_X_START + RIGHT_LUT_WIDTH))));

// =============================================================================
// Stage 1: input latch + per-side calibration constant lookup
// =============================================================================
reg                 s1_valid;
reg                 s1_side;
reg                 s1_in_active;
reg [9:0]           s1_local_x;
reg [9:0]           s1_dst_y;
reg signed [18:0]   s1_cdx;
reg signed [18:0]   s1_cdy;
reg signed [23:0]   s1_csx;
reg signed [23:0]   s1_csy;

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        s1_valid     <= 1'b0;
        s1_side      <= 1'b0;
        s1_in_active <= 1'b0;
        s1_local_x   <= 10'd0;
        s1_dst_y     <= 10'd0;
        s1_cdx       <= 19'sd0;
        s1_cdy       <= 19'sd0;
        s1_csx       <= 24'sd0;
        s1_csy       <= 24'sd0;
    end else begin
        s1_valid     <= valid_in;
        s1_side      <= s0_side;
        s1_in_active <= s0_in_active;
        s1_local_x   <= s0_local_x;
        s1_dst_y     <= dst_y;
        s1_cdx       <= cdx_of(s0_side);
        s1_cdy       <= cdy_of(s0_side);
        s1_csx       <= csx_of(s0_side);
        s1_csy       <= csy_of(s0_side);
    end
end

// =============================================================================
// Stage 2: vector to image center (subtract cdx/cdy)   <-> ST_VEC
// =============================================================================
reg                 s2_valid, s2_side, s2_in_active;
reg signed [18:0]   s2_dx_q8, s2_dy_q8;
reg signed [23:0]   s2_csx, s2_csy;

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        s2_valid     <= 1'b0;
        s2_side      <= 1'b0;
        s2_in_active <= 1'b0;
        s2_dx_q8     <= 19'sd0;
        s2_dy_q8     <= 19'sd0;
        s2_csx       <= 24'sd0;
        s2_csy       <= 24'sd0;
    end else begin
        s2_valid     <= s1_valid;
        s2_side      <= s1_side;
        s2_in_active <= s1_in_active;
        s2_dx_q8     <= ($signed({1'b0, s1_local_x}) <<< 8) - s1_cdx;
        s2_dy_q8     <= ($signed({1'b0, s1_dst_y})   <<< 8) - s1_cdy;
        s2_csx       <= s1_csx;
        s2_csy       <= s1_csy;
    end
end

// =============================================================================
// Stage 3: r^2 = (dx>>>7)^2 + (dy>>>7)^2     <-> ST_R2
// =============================================================================
reg                 s3_valid, s3_side, s3_in_active;
reg [24:0]          s3_r2;
reg signed [18:0]   s3_dx_q8, s3_dy_q8;
reg signed [23:0]   s3_csx, s3_csy;

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        s3_valid     <= 1'b0;
        s3_side      <= 1'b0;
        s3_in_active <= 1'b0;
        s3_r2        <= 25'd0;
        s3_dx_q8     <= 19'sd0;
        s3_dy_q8     <= 19'sd0;
        s3_csx       <= 24'sd0;
        s3_csy       <= 24'sd0;
    end else begin
        s3_valid     <= s2_valid;
        s3_side      <= s2_side;
        s3_in_active <= s2_in_active;
        s3_r2        <= ($signed(s2_dx_q8 >>> 7) * $signed(s2_dx_q8 >>> 7)) +
                        ($signed(s2_dy_q8 >>> 7) * $signed(s2_dy_q8 >>> 7));
        s3_dx_q8     <= s2_dx_q8;
        s3_dy_q8     <= s2_dy_q8;
        s3_csx       <= s2_csx;
        s3_csy       <= s2_csy;
    end
end

// =============================================================================
// Stage 4: pos_q16 = r^2 * 92                <-> ST_POS
// =============================================================================
reg                 s4_valid, s4_side, s4_in_active;
reg [31:0]          s4_pos;
reg signed [18:0]   s4_dx_q8, s4_dy_q8;
reg signed [23:0]   s4_csx, s4_csy;

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        s4_valid     <= 1'b0;
        s4_side      <= 1'b0;
        s4_in_active <= 1'b0;
        s4_pos       <= 32'd0;
        s4_dx_q8     <= 19'sd0;
        s4_dy_q8     <= 19'sd0;
        s4_csx       <= 24'sd0;
        s4_csy       <= 24'sd0;
    end else begin
        s4_valid     <= s3_valid;
        s4_side      <= s3_side;
        s4_in_active <= s3_in_active;
        s4_pos       <= s3_r2 * R2_TO_POS_Q16;
        s4_dx_q8     <= s3_dx_q8;
        s4_dy_q8     <= s3_dy_q8;
        s4_csx       <= s3_csx;
        s4_csy       <= s3_csy;
    end
end

// =============================================================================
// Stage 5: LUT addr (combinational) + synchronous ROM read    <-> ST_LUT
//
// The two function calls below are evaluated combinationally on s4_idx0/idx1
// and the result is registered into s5_s0_q15 / s5_s1_q15 at the next posedge.
// That makes the LUT a 1-cycle synchronous ROM that Quartus infers as M10K.
//
// Saturation rule: if pos[31:16] >= 255, both reads return LUT[255] and frac=0
// (clamps at the outer edge). When not saturated, pos[31:16] in [0,254], so
// pos[23:16] in [0,254] and idx0+1 stays in [1,255] -- no 8-bit wrap.
// =============================================================================
wire        s4_sat   = (s4_pos[31:16] >= LUT_LAST_INDEX);
wire [7:0]  s4_idx0  = s4_sat ? 8'd255 : s4_pos[23:16];
wire [7:0]  s4_idx1  = s4_sat ? 8'd255 : (s4_pos[23:16] + 8'd1);
wire [15:0] s4_frac  = s4_sat ? 16'd0  : s4_pos[15:0];

reg                 s5_valid, s5_side, s5_in_active;
reg [15:0]          s5_frac;
reg signed [18:0]   s5_dx_q8, s5_dy_q8;
reg signed [23:0]   s5_csx, s5_csy;
reg signed [17:0]   s5_s0_q15;
reg signed [17:0]   s5_s1_q15;

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        s5_valid     <= 1'b0;
        s5_side      <= 1'b0;
        s5_in_active <= 1'b0;
        s5_frac      <= 16'd0;
        s5_dx_q8     <= 19'sd0;
        s5_dy_q8     <= 19'sd0;
        s5_csx       <= 24'sd0;
        s5_csy       <= 24'sd0;
        s5_s0_q15    <= 18'sd0;
        s5_s1_q15    <= 18'sd0;
    end else begin
        s5_valid     <= s4_valid;
        s5_side      <= s4_side;
        s5_in_active <= s4_in_active;
        s5_frac      <= s4_frac;
        s5_dx_q8     <= s4_dx_q8;
        s5_dy_q8     <= s4_dy_q8;
        s5_csx       <= s4_csx;
        s5_csy       <= s4_csy;
        s5_s0_q15    <= s4_side ? right_scale_q15(s4_idx0) : left_scale_q15(s4_idx0);
        s5_s1_q15    <= s4_side ? right_scale_q15(s4_idx1) : left_scale_q15(s4_idx1);
    end
end

// =============================================================================
// Stage 6: interp_prod = (s1 - s0) * frac    <-> ST_INTERP
// =============================================================================
reg                 s6_valid, s6_side, s6_in_active;
reg signed [37:0]   s6_interp_prod;
reg signed [17:0]   s6_s0_q15;
reg signed [18:0]   s6_dx_q8, s6_dy_q8;
reg signed [23:0]   s6_csx, s6_csy;

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        s6_valid       <= 1'b0;
        s6_side        <= 1'b0;
        s6_in_active   <= 1'b0;
        s6_interp_prod <= 38'sd0;
        s6_s0_q15      <= 18'sd0;
        s6_dx_q8       <= 19'sd0;
        s6_dy_q8       <= 19'sd0;
        s6_csx         <= 24'sd0;
        s6_csy         <= 24'sd0;
    end else begin
        s6_valid       <= s5_valid;
        s6_side        <= s5_side;
        s6_in_active   <= s5_in_active;
        s6_interp_prod <= ($signed({s5_s1_q15[17], s5_s1_q15}) -
                           $signed({s5_s0_q15[17], s5_s0_q15})) *
                          $signed({1'b0, s5_frac});
        s6_s0_q15      <= s5_s0_q15;
        s6_dx_q8       <= s5_dx_q8;
        s6_dy_q8       <= s5_dy_q8;
        s6_csx         <= s5_csx;
        s6_csy         <= s5_csy;
    end
end

// =============================================================================
// Stage 7: scale_q15 = s0 + (interp_prod +/- 2^15) >>> 16    <-> ST_SCALE
// =============================================================================
reg                 s7_valid, s7_side, s7_in_active;
reg signed [18:0]   s7_scale_q15;
reg signed [18:0]   s7_dx_q8, s7_dy_q8;
reg signed [23:0]   s7_csx, s7_csy;

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        s7_valid     <= 1'b0;
        s7_side      <= 1'b0;
        s7_in_active <= 1'b0;
        s7_scale_q15 <= 19'sd0;
        s7_dx_q8     <= 19'sd0;
        s7_dy_q8     <= 19'sd0;
        s7_csx       <= 24'sd0;
        s7_csy       <= 24'sd0;
    end else begin
        s7_valid     <= s6_valid;
        s7_side      <= s6_side;
        s7_in_active <= s6_in_active;
        if (s6_interp_prod >= 0)
            s7_scale_q15 <= $signed({s6_s0_q15[17], s6_s0_q15}) +
                            ((s6_interp_prod + 38'sd32768) >>> 16);
        else
            s7_scale_q15 <= $signed({s6_s0_q15[17], s6_s0_q15}) +
                            ((s6_interp_prod - 38'sd32768) >>> 16);
        s7_dx_q8     <= s6_dx_q8;
        s7_dy_q8     <= s6_dy_q8;
        s7_csx       <= s6_csx;
        s7_csy       <= s6_csy;
    end
end

// =============================================================================
// Stage 8: x_scaled = dx * scale, y_scaled = dy * scale    <-> ST_MUL
// =============================================================================
reg                 s8_valid, s8_side, s8_in_active;
reg signed [37:0]   s8_x_scaled, s8_y_scaled;
reg signed [23:0]   s8_csx, s8_csy;

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        s8_valid     <= 1'b0;
        s8_side      <= 1'b0;
        s8_in_active <= 1'b0;
        s8_x_scaled  <= 38'sd0;
        s8_y_scaled  <= 38'sd0;
        s8_csx       <= 24'sd0;
        s8_csy       <= 24'sd0;
    end else begin
        s8_valid     <= s7_valid;
        s8_side      <= s7_side;
        s8_in_active <= s7_in_active;
        s8_x_scaled  <= s7_dx_q8 * s7_scale_q15;
        s8_y_scaled  <= s7_dy_q8 * s7_scale_q15;
        s8_csx       <= s7_csx;
        s8_csy       <= s7_csy;
    end
end

// =============================================================================
// Stage 9: sx_q8 = csx + (x_scaled +/- 2^14) >>> 15  (Q8)    <-> ST_OFFSET
// =============================================================================
reg                 s9_valid, s9_side, s9_in_active;
reg signed [23:0]   s9_sx_q8, s9_sy_q8;

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        s9_valid     <= 1'b0;
        s9_side      <= 1'b0;
        s9_in_active <= 1'b0;
        s9_sx_q8     <= 24'sd0;
        s9_sy_q8     <= 24'sd0;
    end else begin
        s9_valid     <= s8_valid;
        s9_side      <= s8_side;
        s9_in_active <= s8_in_active;
        if (s8_x_scaled >= 0)
            s9_sx_q8 <= s8_csx + ((s8_x_scaled + 38'sd16384) >>> 15);
        else
            s9_sx_q8 <= s8_csx + ((s8_x_scaled - 38'sd16384) >>> 15);
        if (s8_y_scaled >= 0)
            s9_sy_q8 <= s8_csy + ((s8_y_scaled + 38'sd16384) >>> 15);
        else
            s9_sy_q8 <= s8_csy + ((s8_y_scaled - 38'sd16384) >>> 15);
    end
end

// =============================================================================
// Stage 10: round Q8 -> integer pixel coord    <-> ST_CHECK part 1
// =============================================================================
reg                 s10_valid, s10_side, s10_in_active;
reg signed [12:0]   s10_sx_int, s10_sy_int;

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        s10_valid     <= 1'b0;
        s10_side      <= 1'b0;
        s10_in_active <= 1'b0;
        s10_sx_int    <= 13'sd0;
        s10_sy_int    <= 13'sd0;
    end else begin
        s10_valid     <= s9_valid;
        s10_side      <= s9_side;
        s10_in_active <= s9_in_active;
        s10_sx_int    <= round_q8_to_int(s9_sx_q8);
        s10_sy_int    <= round_q8_to_int(s9_sy_q8);
    end
end

// =============================================================================
// Stage 11: bounds check + emit final (src_x, src_y, valid_out)    <-> ST_CHECK part 2
// =============================================================================
wire signed [12:0] s10_gx_i      = s10_side ? (s10_sx_int + RIGHT_OUTPUT_X_START)
                                            : s10_sx_int;
wire               s10_in_bounds = (s10_sx_int >= 0) &&
                                   (s10_sx_int <  LEFT_LUT_WIDTH_S) &&
                                   (s10_sy_int >= 0) &&
                                   (s10_sy_int <  FRAME_HEIGHT_S) &&
                                   (s10_gx_i   >= 0) &&
                                   (s10_gx_i   <  FULL_FRAME_WIDTH_S);

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        src_x     <= 10'd0;
        src_y     <= 10'd0;
        valid_out <= 1'b0;
    end else begin
        if (s10_valid && s10_in_active && s10_in_bounds) begin
            src_x     <= s10_gx_i[9:0];
            src_y     <= s10_sy_int[9:0];
            valid_out <= 1'b1;
        end else begin
            src_x     <= 10'd0;
            src_y     <= 10'd0;
            valid_out <= 1'b0;
        end
    end
end

endmodule
