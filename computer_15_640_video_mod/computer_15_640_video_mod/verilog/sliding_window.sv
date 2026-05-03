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
    
    // Internal registers to store the shift register state
    logic [PIXEL_W-1:0] shift_reg [0:BLOCK_SIZE-1][0:BLOCK_SIZE-2];

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

    // Sequential logic: update the shift register state on clock
    always_ff @(posedge clk) begin
        if (rst) begin
            for (row = 0; row < BLOCK_SIZE; row++) begin
                for (col = 0; col < BLOCK_SIZE - 1; col++) begin
                    shift_reg[row][col] <= '0;
                end
            end
        end else if (valid_in) begin
            // Shift columns left and insert new column at the right edge
            for (row = 0; row < BLOCK_SIZE; row++) begin
                for (col = 0; col < BLOCK_SIZE - 2; col++) begin
                    shift_reg[row][col] <= shift_reg[row][col + 1];
                end
                shift_reg[row][BLOCK_SIZE - 2] <= col_px(pixel_in_col_flat, row);
            end
        end
    end

    // Combinational logic: derive the 2D window immediately from shift register + new input
    always_comb begin
        for (row = 0; row < BLOCK_SIZE; row++) begin
            for (col = 0; col < BLOCK_SIZE - 1; col++) begin
                block_out[row][col] = shift_reg[row][col];
            end
            // Right column: use new input if valid_in, otherwise repeat the last stored column
            if (valid_in) begin
                block_out[row][BLOCK_SIZE - 1] = col_px(pixel_in_col_flat, row);
            end else begin
                block_out[row][BLOCK_SIZE - 1] = shift_reg[row][BLOCK_SIZE - 2];
            end
        end
    end

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

endmodule 