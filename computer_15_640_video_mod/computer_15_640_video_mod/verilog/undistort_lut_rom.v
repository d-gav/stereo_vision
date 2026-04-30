module undistort_lut_rom (
    input wire [17:0] address,
    output wire [20:0] q
);

localparam integer LUT_DEPTH = 640 * 288;

// Synthesis initializes this ROM from the MIF so LUT-only updates can skip full compile.
(* ramstyle = "M10K", ram_init_file = "undistort_lut_640x288_stereo_from_existing_calib_21b.mif" *)
reg [20:0] rom [0:LUT_DEPTH-1];

assign q = rom[address];

endmodule
