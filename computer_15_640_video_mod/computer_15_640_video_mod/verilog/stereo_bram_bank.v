// =============================================================================
// stereo_bram_bank  (split L/R, 3 rows per M10K)
//
// 134 M10K banks total: 67 left + 67 right.
// Each M10K stores 3 rows × 320 cols = 960 entries at 1024×8 (93.75% util).
// Bank g holds rows 3g, 3g+1, 3g+2. Last bank (g=66) holds only rows 198,199.
//
// Write interface: global (row, col) where col 0-319=left, 320-639=right.
// Read interface: (row_in_bank, local_col) shared across all banks.
//   Returns both left and right data arrays; caller selects.
// =============================================================================

module stereo_bram_bank #(
    parameter int FRAME_HEIGHT     = 200,
    parameter int HALF_FRAME_WIDTH = 320,
    parameter int FULL_ROW_WIDTH   = 640,
    parameter int ROWS_PER_BANK    = 3,
    parameter int DATA_W           = 8,
    parameter int NUM_BANKS        = (FRAME_HEIGHT + ROWS_PER_BANK - 1) / ROWS_PER_BANK,
    parameter int ROW_W            = (FRAME_HEIGHT <= 1) ? 1 : $clog2(FRAME_HEIGHT),
    parameter int FULL_COL_W       = $clog2(FULL_ROW_WIDTH),
    parameter int HALF_COL_W       = $clog2(HALF_FRAME_WIDTH),
    parameter int ROW_IN_BANK_W    = (ROWS_PER_BANK <= 1) ? 1 : $clog2(ROWS_PER_BANK),
    parameter int BANK_IDX_W       = (NUM_BANKS <= 1) ? 1 : $clog2(NUM_BANKS)
)(
    input  logic                       clk,

    // Write: global row (0-199) and global col (0-639). Module splits L/R.
    input  logic                       wr_en,
    input  logic [ROW_W-1:0]           wr_row,
    input  logic [FULL_COL_W-1:0]      wr_col,
    input  logic [DATA_W-1:0]          wr_data,

    // Read: shared (row_in_bank, local_col), returns both sides in parallel.
    input  logic [ROW_IN_BANK_W-1:0]   rd_row_in_bank,
    input  logic [HALF_COL_W-1:0]      rd_col,
    output logic [DATA_W-1:0]          rd_data_left  [0:NUM_BANKS-1],
    output logic [DATA_W-1:0]          rd_data_right [0:NUM_BANKS-1]
);

    localparam int BANK_DEPTH  = ROWS_PER_BANK * HALF_FRAME_WIDTH; // 960
    localparam int BANK_ADDR_W = $clog2(BANK_DEPTH);

    // Write decomposition
    wire wr_is_right = (wr_col >= HALF_FRAME_WIDTH);
    wire [HALF_COL_W-1:0]    wr_local_col   = wr_is_right ?
        HALF_COL_W'(wr_col - HALF_FRAME_WIDTH) : HALF_COL_W'(wr_col);
    wire [BANK_IDX_W-1:0]    wr_bank_idx    = wr_row / ROWS_PER_BANK;
    wire [ROW_IN_BANK_W-1:0] wr_row_in_bank = wr_row % ROWS_PER_BANK;
    wire [BANK_ADDR_W-1:0]   wr_addr =
        (BANK_ADDR_W'(wr_row_in_bank) * HALF_FRAME_WIDTH) + BANK_ADDR_W'(wr_local_col);

    // Read address (shared across all banks)
    wire [BANK_ADDR_W-1:0] rd_addr =
        (BANK_ADDR_W'(rd_row_in_bank) * HALF_FRAME_WIDTH) + BANK_ADDR_W'(rd_col);

    genvar g;
    generate
        for (g = 0; g < NUM_BANKS; g++) begin : GEN_BANK
            (* ramstyle = "M10K, no_rw_check" *)
            logic [DATA_W-1:0] mem_left [0:BANK_DEPTH-1];
            (* ramstyle = "M10K, no_rw_check" *)
            logic [DATA_W-1:0] mem_right [0:BANK_DEPTH-1];

            // Write: only the addressed bank+side is written
            always_ff @(posedge clk) begin
                if (wr_en && (wr_bank_idx == BANK_IDX_W'(g)) && !wr_is_right)
                    mem_left[wr_addr] <= wr_data;
            end
            always_ff @(posedge clk) begin
                if (wr_en && (wr_bank_idx == BANK_IDX_W'(g)) && wr_is_right)
                    mem_right[wr_addr] <= wr_data;
            end

            // Read: both sides read every cycle
            always_ff @(posedge clk) begin
                rd_data_left[g]  <= mem_left[rd_addr];
            end
            always_ff @(posedge clk) begin
                rd_data_right[g] <= mem_right[rd_addr];
            end
        end
    endgenerate

endmodule
