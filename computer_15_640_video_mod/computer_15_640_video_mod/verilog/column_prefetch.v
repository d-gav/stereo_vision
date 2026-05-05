// =============================================================================
// column_prefetch  (per-row BRAM version)
//
// Adapter between mem_block_intf and the per-row stereo_bram_bank.
//
// With per-row partitioning, ALL FRAME_HEIGHT bytes arrive in parallel after
// a single cycle of M10K read latency. The prefetch just translates the
// (bank, col) request into a global column address and stalls for 1 cycle
// while the BRAM reads. Combined with mem_block_intf's 1-cycle self-stall
// from mem_req, total latency is 2 cycles per column fetch.
//
// bram_rd_data is wired directly through to mem_rdata (no intermediate
// register) since the data stays stable until the next request.
// =============================================================================

module column_prefetch #(
    parameter int FRAME_HEIGHT     = 200,
    parameter int HALF_FRAME_WIDTH = 320,
    parameter int FULL_ROW_WIDTH   = 640,
    parameter int PIXEL_W          = 8,
    parameter int ROW_W            = 8,
    parameter int COL_W            = 9,
    parameter int FULL_COL_W       = $clog2(FULL_ROW_WIDTH)
)(
    input  logic clk,
    input  logic rst,

    // Interface from mem_block_intf
    input  logic             mbi_mem_req,
    input  logic             mbi_mem_bank,  // 0 = left, 1 = right
    input  logic [COL_W-1:0] mbi_mem_col,
    output logic             stall,

    // Data output to mem_block_intf (one full column, all FRAME_HEIGHT rows)
    output logic [PIXEL_W-1:0] mem_rdata [0:FRAME_HEIGHT-1],

    // Per-row BRAM read port: shared rd_col, per-row data.
    output logic [FULL_COL_W-1:0] bram_rd_col,
    input  logic [PIXEL_W-1:0]    bram_rd_data [0:FRAME_HEIGHT-1]
);

    // Combinational address translation: left at cols 0..HALF-1,
    // right at cols HALF..FULL-1. Stays stable while FSM is stalled
    // since mem_block_intf doesn't change mem_bank/mem_col until
    // the next unstalled cycle.
    always_comb begin
        if (mbi_mem_bank)
            bram_rd_col = FULL_COL_W'(HALF_FRAME_WIDTH + mbi_mem_col);
        else
            bram_rd_col = FULL_COL_W'(mbi_mem_col);
    end

    // Wire BRAM read data directly to mem_rdata — no intermediate latch.
    // Data stays valid because bram_rd_col is stable while stalled.
    genvar r;
    generate
        for (r = 0; r < FRAME_HEIGHT; r++) begin : GEN_WIRE
            assign mem_rdata[r] = bram_rd_data[r];
        end
    endgenerate

    // 1-cycle stall after mem_req: delays by exactly the M10K read latency.
    // Cycle 0: mem_req=1 (self-stalls FSM via internal_stall), address presented.
    // Cycle 1: stall=1, BRAM data becomes valid.
    // Cycle 2: stall=0, FSM advances and reads mem_rdata.
    logic stall_pipe;
    always_ff @(posedge clk) begin
        if (rst)
            stall_pipe <= 1'b0;
        else
            stall_pipe <= mbi_mem_req;
    end

    assign stall = stall_pipe;

endmodule
