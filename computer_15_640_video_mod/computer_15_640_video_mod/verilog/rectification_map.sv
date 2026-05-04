
// combinational logic to rectify input video stream
// Remaps a single 160 x 240 pixel stereo frame
// LUT based on calibration data maps (x,y) --> (x',y') for each pixel
module rectification_map (
    input logic [9:0] x_in, // input pixel x coordinate
    input logic [9:0] y_in, // input pixel y coordinate
    output logic [9:0] x_out, // rectified pixel x coordinate
    output logic [9:0] y_out  // rectified pixel y coordinate
);

    always_comb begin : LUT
        //
        // TODO: REPLACE WITH ACTUAL LUT BASED ON OPENCV CALIBRATION
        //

        x_out = x_in; 
        y_out = y_in;
    end


endmodule 