// Typedefs for square SAD blocks.

package block_match_pkg;
	localparam int BLOCK_SIZE = 5;
	localparam int PIXEL_W    = 8;
	typedef logic [PIXEL_W-1:0] pixel_t;
	typedef pixel_t block_t [0:BLOCK_SIZE-1][0:BLOCK_SIZE-1];
	typedef pixel_t line_t [0:BLOCK_SIZE-1];
endpackage
