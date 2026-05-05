// =============================================================================
// stereo_radial_mapper_q15_pipe_compat
//
// Drop-in compatibility wrapper for stereo_radial_mapper_q15_pipe that exposes
// the same start/done/valid/busy interface as the original FSM-based
// stereo_radial_mapper_q15. Use this to swap in the pipelined module without
// changing the FILL FSM in DE1_SoC_Computer.v, e.g. for verification:
//
//     stereo_radial_mapper_q15_pipe_compat stereo_radial_mapper_inst (
//         .clk(CLOCK2_50), .reset_n(KEY[0]),
//         .start(read_video_start),
//         .dst_x(video_in_x_cood), .dst_y(mapper_dst_y),
//         .src_x(read_video_map_x), .src_y(read_video_map_y),
//         .valid(read_video_map_valid), .done(read_video_map_done),
//         .busy()
//     );
//
// In this mode each request takes PIPE_LATENCY cycles end-to-end (same as the
// FSM), so this wrapper does NOT give any throughput speedup -- the only
// benefit is identical interface for a sanity test against the FSM version.
// To actually exploit the pipeline, drive stereo_radial_mapper_q15_pipe
// directly with one (dst_x, dst_y, valid_in) per cycle from a streaming FILL
// controller.
// =============================================================================

module stereo_radial_mapper_q15_pipe_compat (
    input  wire        clk,
    input  wire        reset_n,
    input  wire        start,        // single-cycle pulse to launch a request
    input  wire [9:0]  dst_x,
    input  wire [9:0]  dst_y,
    output wire [9:0]  src_x,
    output wire [9:0]  src_y,
    output wire        valid,        // result is in-bounds (mirrors FSM 'valid')
    output reg         done,         // result-cycle pulse (fires regardless of valid)
    output wire        busy          // 1 while any request is in flight
);

    localparam integer PIPE_LATENCY = 11;

    // ---- Pipelined mapper instance ----
    stereo_radial_mapper_q15_pipe u_pipe (
        .clk(clk),
        .reset_n(reset_n),
        .valid_in(start),
        .dst_x(dst_x),
        .dst_y(dst_y),
        .src_x(src_x),
        .src_y(src_y),
        .valid_out(valid)
    );

    // ---- Delay the start pulse by PIPE_LATENCY cycles to produce 'done' ----
    // 'done' fires whether or not the result is in-bounds, so the caller can
    // advance even on out-of-bounds pixels (matching the FSM behavior, where
    // ST_DONE always followed ST_CHECK).
    reg [PIPE_LATENCY-1:0] start_sr;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            start_sr <= {PIPE_LATENCY{1'b0}};
            done     <= 1'b0;
        end else begin
            start_sr <= {start_sr[PIPE_LATENCY-2:0], start};
            done     <= start_sr[PIPE_LATENCY-2];   // fires same cycle as valid_out
        end
    end

    // 'busy' is high whenever any request is somewhere in the shift register
    // OR a request is being issued this cycle.
    assign busy = start | (|start_sr);

endmodule
