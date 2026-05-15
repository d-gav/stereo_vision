// =============================================================================
// column_prefetch_parallel
//
// Drop-in replacement for column_prefetch.v that uses the new stereo_onchip_ram
// "sad_port" conduit (one parallel byte per row, 1-cycle M10K read latency)
// instead of fetching pixels one row at a time out of stereo_bram_bank.
//
// External interface to mem_block_intf is unchanged: same mbi_mem_req /
// mbi_mem_bank / mbi_mem_col inputs, same `mem_rdata [0:FRAME_HEIGHT-1]`
// per-row byte array, same active-high `stall` handshake.
//
// Internal protocol (matches column_prefetch.v's stall pattern):
//   cycle N   (S_IDLE,  stall=0): mbi_mem_req asserts; sad_col is driven
//                                  combinationally; latch col/bank.
//   cycle N+1 (S_FETCH, stall=1): sad_rdata_flat is valid (M10K latency 1);
//                                  every row latched into mem_rdata in parallel.
//   cycle N+2 (S_DONE,  stall=1): hold; one extra cycle so mem_block_intf can
//                                  observe the stall transition cleanly.
//   cycle N+3 (S_IDLE,  stall=0): mem_rdata stable; mem_block_intf consumes.
//
// Bank-to-byte-column translation matches the side-by-side layout the Video-In
// DMA writes into Onchip_SRAM:
//   bank=0 (left)  -> sad_col = LEFT_OUTPUT_X_START + col   (default offset 0)
//   bank=1 (right) -> sad_col = RIGHT_BANK_OFFSET + col     (default offset 319)
// =============================================================================

`default_nettype none

module column_prefetch_parallel #(
    parameter int FRAME_HEIGHT      = 200,
    parameter int RIGHT_BANK_OFFSET = 319,   // RIGHT_OUTPUT_X_START in DE1_SoC_Computer.v
    parameter int PIXEL_W           = 8,
    parameter int COL_W             = 9,    // mem_block_intf column width
    parameter int SAD_COL_W         = 10    // sad_port column width
) (
    input  wire                                clk,
    input  wire                                rst,

    // ---- mem_block_intf side ----
    input  wire                                mbi_mem_req,
    input  wire                                mbi_mem_bank,   // 0=left, 1=right
    input  wire [COL_W-1:0]                    mbi_mem_col,
    output reg                                 stall,
    output reg  [PIXEL_W-1:0]                  mem_rdata [0:FRAME_HEIGHT-1],

    // ---- stereo_onchip_ram sad_port (flat conduit) ----
    output wire                                sad_re,
    output wire [SAD_COL_W-1:0]                sad_col,
    input  wire [FRAME_HEIGHT*PIXEL_W-1:0]     sad_rdata_flat
);

    localparam [SAD_COL_W-1:0] R_OFF = RIGHT_BANK_OFFSET[SAD_COL_W-1:0];

    localparam logic [1:0] S_IDLE  = 2'd0;
    localparam logic [1:0] S_FETCH = 2'd1;
    localparam logic [1:0] S_DONE  = 2'd2;
    reg [1:0] state;

    // Latch col/bank on entering S_FETCH so sad_col stays stable in case
    // mem_block_intf releases mbi_mem_req while we are stalling it.
    reg [COL_W-1:0]   latched_col;
    reg               latched_bank;

    wire [SAD_COL_W-1:0] live_col_ext = {{(SAD_COL_W-COL_W){1'b0}}, mbi_mem_col};
    wire [SAD_COL_W-1:0] held_col_ext = {{(SAD_COL_W-COL_W){1'b0}}, latched_col};

    assign sad_col = (state == S_IDLE)
                   ? (mbi_mem_bank ? live_col_ext + R_OFF : live_col_ext)
                   : (latched_bank ? held_col_ext + R_OFF : held_col_ext);

    // Advisory read enable; the M10K reads every cycle anyway.
    assign sad_re  = (state == S_IDLE) ? mbi_mem_req : 1'b1;

    always @(*) begin
        stall = (state != S_IDLE);
    end

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            state        <= S_IDLE;
            latched_col  <= '0;
            latched_bank <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (mbi_mem_req) begin
                        latched_col  <= mbi_mem_col;
                        latched_bank <= mbi_mem_bank;
                        state        <= S_FETCH;
                    end
                end

                S_FETCH: begin
                    // sad_rdata_flat is valid this cycle; latch every row.
                    for (i = 0; i < FRAME_HEIGHT; i = i + 1) begin
                        mem_rdata[i] <= sad_rdata_flat[i*PIXEL_W +: PIXEL_W];
                    end
                    state <= S_DONE;
                end

                S_DONE: begin
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
