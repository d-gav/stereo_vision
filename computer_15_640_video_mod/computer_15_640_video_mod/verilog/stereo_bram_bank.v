// =============================================================================
// stereo_bram_bank  (per-row partitioned version)
//
// Storage is partitioned into FRAME_HEIGHT independent M10K-backed sub-banks,
// one per image row. Each sub-bank holds FULL_ROW_WIDTH columns of pixel data
// (left camera in cols 0..HALF-1, right in cols HALF..FULL-1).
//
// All row-banks share the same read column address and return their byte in
// parallel, so a single (rd_col) presentation yields FRAME_HEIGHT bytes —
// one complete column — after one cycle of M10K read latency.
//
// Write side stays single-byte-per-cycle. Writers specify the destination
// row and column; only that row's M10K is written.
//
// CRITICAL: The "no_rw_check" ramstyle attribute prevents Quartus from
// analysing read-during-write hazards across all FRAME_HEIGHT banks, which
// would otherwise cause synthesis to hang. This is safe because FILL and
// COMPUTE phases never overlap.
// =============================================================================

module stereo_bram_bank #(
    parameter int FRAME_HEIGHT   = 200,
    parameter int FULL_ROW_WIDTH = 640,
    parameter int DATA_W         = 8,
    parameter int ROW_W          = (FRAME_HEIGHT <= 1) ? 1 : $clog2(FRAME_HEIGHT),
    parameter int COL_W          = $clog2(FULL_ROW_WIDTH)
)(
    input  logic                 clk,

    // Write port: one pixel per cycle. Addressed by (row, col).
    input  logic                 wr_en,
    input  logic [ROW_W-1:0]     wr_row,
    input  logic [COL_W-1:0]     wr_col,
    input  logic [DATA_W-1:0]    wr_data,

    // Parallel read port: rd_col is shared across all row-banks.
    // All FRAME_HEIGHT bytes come out in parallel after 1-cycle BRAM latency.
    input  logic [COL_W-1:0]     rd_col,
    output logic [DATA_W-1:0]    rd_data [0:FRAME_HEIGHT-1]
);

    genvar g;
    generate
        for (g = 0; g < FRAME_HEIGHT; g++) begin : GEN_ROW
            (* ramstyle = "M10K, no_rw_check" *) logic [DATA_W-1:0] mem [0:FULL_ROW_WIDTH-1];

            always_ff @(posedge clk) begin
                if (wr_en && (wr_row == ROW_W'(g))) begin
                    mem[wr_col] <= wr_data;
                end
            end

            always_ff @(posedge clk) begin
                rd_data[g] <= mem[rd_col];
            end
        end
    endgenerate

endmodule
