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
    parameter int FRAME_HEIGHT     = 200,
    parameter int HALF_FRAME_WIDTH = 320,
    parameter int ROWS_PER_BANK    = 3,
    parameter int NUM_BANKS        = (FRAME_HEIGHT + ROWS_PER_BANK - 1) / ROWS_PER_BANK,
    parameter int PIXEL_W          = 8,
    parameter int COL_W            = 9,
    parameter int HALF_COL_W       = $clog2(HALF_FRAME_WIDTH),
    parameter int ROW_IN_BANK_W    = (ROWS_PER_BANK <= 1) ? 1 : $clog2(ROWS_PER_BANK)
)(
    input  logic clk,
    input  logic rst,

    // Interface from mem_block_intf
    input  logic             mbi_mem_req,
    input  logic             mbi_mem_bank,  // 0 = left, 1 = right
    input  logic [COL_W-1:0] mbi_mem_col,   // local column (0-319 for left, 0-404 for right)
    output logic             stall,

    // Data output to mem_block_intf
    output logic [PIXEL_W-1:0] mem_rdata [0:FRAME_HEIGHT-1],

    // BRAM read interface
    output logic [ROW_IN_BANK_W-1:0] bram_rd_row_in_bank,
    output logic [HALF_COL_W-1:0]    bram_rd_col,
    input  logic [PIXEL_W-1:0]       bram_rd_data_left  [0:NUM_BANKS-1],
    input  logic [PIXEL_W-1:0]       bram_rd_data_right [0:NUM_BANKS-1]
);

    // Column address: use mem_col directly as local column
    assign bram_rd_col = HALF_COL_W'(mbi_mem_col);

    // 3-cycle sweep: cnt 0=idle, 1/2/3 = reading row_in_bank 0/1/2
    logic [1:0] cnt;
    logic       latched_bank; // which side to read (latched on request)

    // Row-in-bank presented to BRAM: one cycle ahead of the data we latch
    assign bram_rd_row_in_bank = ROW_IN_BANK_W'(cnt);
    assign stall = (cnt != 2'd0);

    always_ff @(posedge clk) begin
        if (rst) begin
            cnt <= 2'd0;
            latched_bank <= 1'b0;
        end else begin
            case (cnt)
                2'd0: begin
                    if (mbi_mem_req) begin
                        cnt <= 2'd1;
                        latched_bank <= mbi_mem_bank;
                    end
                end
                2'd1: begin
                    // BRAM data for row_in_bank=0 now valid. Latch rows 0,3,6,...
                    for (int g = 0; g < NUM_BANKS; g++) begin
                        if ((3*g) < FRAME_HEIGHT)
                            mem_rdata[3*g] <= latched_bank ?
                                bram_rd_data_right[g] : bram_rd_data_left[g];
                    end
                    cnt <= 2'd2;
                end
                2'd2: begin
                    // BRAM data for row_in_bank=1 now valid. Latch rows 1,4,7,...
                    for (int g = 0; g < NUM_BANKS; g++) begin
                        if ((3*g + 1) < FRAME_HEIGHT)
                            mem_rdata[3*g + 1] <= latched_bank ?
                                bram_rd_data_right[g] : bram_rd_data_left[g];
                    end
                    cnt <= 2'd3;
                end
                2'd3: begin
                    // BRAM data for row_in_bank=2 now valid. Latch rows 2,5,8,...
                    for (int g = 0; g < NUM_BANKS; g++) begin
                        if ((3*g + 2) < FRAME_HEIGHT)
                            mem_rdata[3*g + 2] <= latched_bank ?
                                bram_rd_data_right[g] : bram_rd_data_left[g];
                    end
                    cnt <= 2'd0;
                end
                default: cnt <= 2'd0;
            endcase
        end
    end

endmodule
