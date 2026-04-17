module undistort_lut_right_rom (
    input wire clk,
    input wire [16:0] address,
    output reg [20:0] q
);

localparam integer LUT_DEPTH = 315 * 288;

(* ramstyle = "M10K", ram_init_file = "right_lut_315x288_21b.mif" *)
reg [20:0] rom [0:LUT_DEPTH-1];

always @(posedge clk) begin
    q <= rom[address];
end

endmodule
