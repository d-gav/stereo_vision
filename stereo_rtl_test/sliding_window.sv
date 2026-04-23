module sliding_window #(
    parameter int BLOCK_SIZE = 5,
    parameter int PIXEL_W    = 8
)(
    input clk,
    input rst,
    input valid_in,
    input  logic [PIXEL_W-1:0] pixel_in_col [0:BLOCK_SIZE-1], 
    output logic [PIXEL_W-1:0] block_out [0:BLOCK_SIZE-1][0:BLOCK_SIZE-1]
);

    int row;
    int col;

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
                block_out[row][BLOCK_SIZE - 1] <= pixel_in_col[row];
            end
        end
    end

endmodule 