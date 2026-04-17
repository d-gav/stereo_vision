module undistort_lut_right_rom (
    input wire [16:0] address,
    output wire [20:0] q
);

localparam integer LUT_DEPTH = 315 * 288;

(* ramstyle = "M10K", ram_init_file = "right_lut_315x288_21b.mif" *)
reg [20:0] rom [0:LUT_DEPTH-1];

assign q = rom[address];

endmodule
