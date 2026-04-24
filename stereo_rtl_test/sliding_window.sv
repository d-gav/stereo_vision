module sliding_window #(
    parameter int BLOCK_SIZE = 5,
    parameter int PIXEL_W    = 8
)(
    input clk,
    input rst,
    input valid_in,
    input  logic [BLOCK_SIZE*PIXEL_W-1:0] pixel_in_col_flat,
    output logic [PIXEL_W-1:0] block_out [0:BLOCK_SIZE-1][0:BLOCK_SIZE-1],
    output logic [BLOCK_SIZE*BLOCK_SIZE*PIXEL_W-1:0] block_out_flat
);

    int row;
    int col;

    function automatic logic [PIXEL_W-1:0] col_px(
        input logic [BLOCK_SIZE*PIXEL_W-1:0] col_flat,
        input int r
    );
        int idx;
        begin
            idx = r * PIXEL_W;
            col_px = col_flat[idx +: PIXEL_W];
        end
    endfunction

    genvar gi;
    generate
        for (gi = 0; gi < BLOCK_SIZE; gi++) begin : GEN_DBG_BLOCK_ROW
            genvar gj;
            for (gj = 0; gj < BLOCK_SIZE; gj++) begin : GEN_DBG_BLOCK_COL
                localparam int FLAT_IDX = ((gi * BLOCK_SIZE) + gj) * PIXEL_W;
                assign block_out_flat[FLAT_IDX +: PIXEL_W] = block_out[gi][gj];
            end
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (rst) begin
            for (row = 0; row < BLOCK_SIZE; row++) begin
                for (col = 0; col < BLOCK_SIZE; col++) begin
                    block_out[row][col] <= '0;
                end
            end
        end else if (valid_in) begin
            // Shift existing columns left and insert the new column at the right edge.
            for (row = 0; row < BLOCK_SIZE; row++) begin
                for (col = 0; col < BLOCK_SIZE - 1; col++) begin
                    block_out[row][col] <= block_out[row][col + 1];
                end
                block_out[row][BLOCK_SIZE - 1] <= col_px(pixel_in_col_flat, row);
            end
        end
    end

endmodule 