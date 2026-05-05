// =============================================================================
// column_prefetch  (split L/R, 3 rows per bank)
//
// Sweeps rd_row_in_bank = 0, 1, 2. Each sweep returns NUM_BANKS bytes from
// both left and right bank arrays. Selects the correct side based on
// mbi_mem_bank, and scatters into mem_rdata[3*g + row_in_bank].
//
// Timing (4 cycles total per column fetch):
//   Cycle 0: mem_req self-stalls FSM. rd_col + rd_row_in_bank=0 presented.
//   Cycle 1: BRAM row0 data valid. Latch rows 0,3,6,...  Switch to rib=1.
//   Cycle 2: BRAM row1 data valid. Latch rows 1,4,7,...  Switch to rib=2.
//   Cycle 3: BRAM row2 data valid. Latch rows 2,5,8,...  Stall drops.
//   Cycle 4: Pipeline advances, reads mem_rdata.
// =============================================================================

module column_prefetch #(
    parameter integer FRAME_HEIGHT     = 200,
    parameter integer HALF_FRAME_WIDTH = 320,
    parameter integer FULL_ROW_WIDTH   = 640,
    parameter integer STRIPE_HEIGHT    = 8,
    parameter integer NUM_STRIPES      = (FRAME_HEIGHT + STRIPE_HEIGHT - 1) / STRIPE_HEIGHT,
    parameter integer PIXEL_W          = 8,
    parameter integer ROW_W            = 8,
    parameter integer COL_W            = 9,
    parameter integer ROW_IN_STRIPE_W  = (STRIPE_HEIGHT <= 1) ? 1 : $clog2(STRIPE_HEIGHT),
    parameter integer FULL_COL_W       = $clog2(FULL_ROW_WIDTH)
)(
    input  wire clk,
    input  wire rst,

    // Interface from mem_block_intf
    input  wire             mbi_mem_req,
    input  wire             mbi_mem_bank,  // 0 = left, 1 = right
    input  wire [COL_W-1:0] mbi_mem_col,
    output reg              stall,

    // Data output to mem_block_intf (one full column, all FRAME_HEIGHT rows)
    output reg [PIXEL_W-1:0] mem_rdata [0:FRAME_HEIGHT-1],

    // Striped BRAM read port: shared (col, row_in_stripe). Per-stripe data
    // arrives as a packed bus, stripe g at bits [g*PIXEL_W +: PIXEL_W].
    output reg  [FULL_COL_W-1:0]               bram_rd_col,
    output reg  [ROW_IN_STRIPE_W-1:0]          bram_rd_row_in_stripe,
    input  wire [NUM_STRIPES*PIXEL_W-1:0]      bram_rd_data_flat
);

    localparam [1:0] PF_IDLE  = 2'd0;
    localparam [1:0] PF_FETCH = 2'd1;
    localparam [1:0] PF_DONE  = 2'd2;
    reg [1:0] pf_state;

    // row_cnt counts the number of *fetch* cycles entered so far. It runs
    // 0..STRIPE_HEIGHT (one extra to cover the final 1-cycle BRAM latency).
    reg [ROW_IN_STRIPE_W:0] row_cnt;

    // Stall mem_block_intf while we are mid-fetch or in the post-fetch
    // single-cycle DONE.
    always @(*) begin
        stall = (pf_state == PF_FETCH) || (pf_state == PF_DONE);
    end

    integer g;
    always @(posedge clk) begin
        if (rst) begin
            pf_state              <= PF_IDLE;
            row_cnt               <= 0;
            bram_rd_col           <= 0;
            bram_rd_row_in_stripe <= 0;
        end else begin
            case (cnt)
                2'd0: begin
                    if (mbi_mem_req) begin
                        pf_state <= PF_FETCH;
                        row_cnt  <= 0;

                        // Drive the column address that all stripe BRAMs
                        // will see for the entire request. Left bank lives
                        // at cols 0..HALF-1, right bank at HALF..FULL-1.
                        if (mbi_mem_bank)
                            bram_rd_col <= HALF_FRAME_WIDTH + mbi_mem_col;
                        else
                            bram_rd_col <= mbi_mem_col;

                        // Issue first read at row_in_stripe = 0.
                        bram_rd_row_in_stripe <= 0;
                    end
                end

                PF_FETCH: begin
                    // BRAM is 1-cycle latency: at row_cnt = r, bram_rd_data
                    // reflects what bram_rd_row_in_stripe was *last* cycle.
                    // So when row_cnt is r >= 1, bram_rd_data[g] holds the
                    // pixel at (col, row_in_stripe = r-1) for stripe g, which
                    // belongs at mem_rdata[g*STRIPE_HEIGHT + (r-1)].
                    if (row_cnt >= 1) begin
                        for (g = 0; g < NUM_STRIPES; g = g + 1) begin
                            if ((g * STRIPE_HEIGHT + (row_cnt - 1)) < FRAME_HEIGHT) begin
                                mem_rdata[g * STRIPE_HEIGHT + (row_cnt - 1)] <=
                                    bram_rd_data_flat[g*PIXEL_W +: PIXEL_W];
                            end
                        end
                    end

                    if (row_cnt == STRIPE_HEIGHT) begin
                        // Captured the last row this cycle; we're done.
                        pf_state <= PF_DONE;
                    end else begin
                        // Issue the next read. Skip when row_cnt+1 would be
                        // out of range so the final row's read still lands.
                        if ((row_cnt + 1) < STRIPE_HEIGHT) begin
                            bram_rd_row_in_stripe <= row_cnt + 1;
                        end
                        row_cnt <= row_cnt + 1;
                    end
                    cnt <= 2'd0;
                end
                default: cnt <= 2'd0;
            endcase
        end
    end

endmodule
