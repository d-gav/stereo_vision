// =============================================================================
// column_prefetch (parallel-stripe version)
//
// Adapter between mem_block_intf (which expects all FRAME_HEIGHT rows of one
// column delivered in a single mem_rdata array once stall drops) and the
// new striped stereo_bram_bank (NUM_STRIPES independent read ports, one
// byte per stripe per cycle, all sharing the same (col, row_in_stripe)).
//
// Per request, we sweep row_in_stripe = 0..STRIPE_HEIGHT-1 (instead of the
// old design's 0..FRAME_HEIGHT-1). Every cycle, all NUM_STRIPES bytes for
// that row arrive in parallel and we scatter them into mem_rdata at indices
// g * STRIPE_HEIGHT + row_in_stripe. Result: STRIPE_HEIGHT-cycle column
// fetch instead of FRAME_HEIGHT-cycle. With STRIPE_HEIGHT=8 and
// FRAME_HEIGHT=200 that's a ~20× reduction in mem_block_intf stall time.
//
// The mem_rdata interface to mem_block_intf is unchanged so no SAD-engine
// code needs to be touched.
// =============================================================================

module column_prefetch #(
    parameter int FRAME_HEIGHT     = 200,
    parameter int HALF_FRAME_WIDTH = 320,
    parameter int FULL_ROW_WIDTH   = 640,
    parameter int STRIPE_HEIGHT    = 8,
    parameter int NUM_STRIPES      = (FRAME_HEIGHT + STRIPE_HEIGHT - 1) / STRIPE_HEIGHT,
    parameter int PIXEL_W          = 8,
    parameter int ROW_W            = 8,
    parameter int COL_W            = 9,
    parameter int ROW_IN_STRIPE_W  = (STRIPE_HEIGHT <= 1) ? 1 : $clog2(STRIPE_HEIGHT),
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

    // Striped BRAM read port: shared (col, row_in_stripe), per-stripe data.
    output logic [FULL_COL_W-1:0]      bram_rd_col,
    output logic [ROW_IN_STRIPE_W-1:0] bram_rd_row_in_stripe,
    input  logic [PIXEL_W-1:0]         bram_rd_data [0:NUM_STRIPES-1]
);

    typedef enum logic [1:0] { PF_IDLE, PF_FETCH, PF_DONE } pf_state_t;
    pf_state_t pf_state;

    // row_cnt counts the number of *fetch* cycles entered so far. It runs
    // 0..STRIPE_HEIGHT (one extra to cover the final 1-cycle BRAM latency).
    logic [ROW_IN_STRIPE_W:0] row_cnt;

    // Stall mem_block_intf while we are mid-fetch or in the post-fetch
    // single-cycle DONE.
    always_comb begin
        stall = (pf_state == PF_FETCH) || (pf_state == PF_DONE);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            pf_state              <= PF_IDLE;
            row_cnt               <= '0;
            bram_rd_col           <= '0;
            bram_rd_row_in_stripe <= '0;
        end else begin
            case (pf_state)
                PF_IDLE: begin
                    if (mbi_mem_req) begin
                        pf_state <= PF_FETCH;
                        row_cnt  <= '0;

                        // Drive the column address that all stripe BRAMs
                        // will see for the entire request. Left bank lives
                        // at cols 0..HALF-1, right bank at HALF..FULL-1.
                        bram_rd_col <= mbi_mem_bank
                            ? FULL_COL_W'(HALF_FRAME_WIDTH + mbi_mem_col)
                            : FULL_COL_W'(mbi_mem_col);

                        // Issue first read at row_in_stripe = 0.
                        bram_rd_row_in_stripe <= '0;
                    end
                end

                PF_FETCH: begin
                    // BRAM is 1-cycle latency: at row_cnt = r, bram_rd_data
                    // reflects what bram_rd_row_in_stripe was *last* cycle.
                    // So when row_cnt is r >= 1, bram_rd_data[g] holds the
                    // pixel at (col, row_in_stripe = r-1) for stripe g, which
                    // belongs at mem_rdata[g*STRIPE_HEIGHT + (r-1)].
                    if (row_cnt >= 1) begin
                        for (int g = 0; g < NUM_STRIPES; g++) begin
                            // Skip slots past FRAME_HEIGHT-1 (only matters
                            // when NUM_STRIPES * STRIPE_HEIGHT > FRAME_HEIGHT,
                            // i.e. the last stripe is partial).
                            if ((g * STRIPE_HEIGHT + (int'(row_cnt) - 1)) < FRAME_HEIGHT) begin
                                mem_rdata[g * STRIPE_HEIGHT + (row_cnt - 1)] <= bram_rd_data[g];
                            end
                        end
                    end

                    if (row_cnt == ROW_IN_STRIPE_W'(STRIPE_HEIGHT)) begin
                        // Captured the last row this cycle; we're done.
                        pf_state <= PF_DONE;
                    end else begin
                        // Issue the next read. Skip when row_cnt+1 would be
                        // out of range so the final row's read still lands.
                        if ((row_cnt + 1) < STRIPE_HEIGHT) begin
                            bram_rd_row_in_stripe <= ROW_IN_STRIPE_W'(row_cnt + 1);
                        end
                        row_cnt <= row_cnt + 1;
                    end
                end

                PF_DONE: begin
                    pf_state <= PF_IDLE;
                end

                default: pf_state <= PF_IDLE;
            endcase
        end
    end

endmodule
