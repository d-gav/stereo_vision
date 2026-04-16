// Typedefs for square SAD blocks.

package block_match_pkg #(
	parameter int BLOCK_SIZE = 5,
	parameter int PIXEL_W    = 8
);
	typedef logic [PIXEL_W-1:0] pixel_t;
	typedef pixel_t block_t [BLOCK_SIZE-1:0][BLOCK_SIZE-1:0];
endpackage
