

module DE1_SoC_Computer (
	////////////////////////////////////
	// FPGA Pins
	////////////////////////////////////

	// Clock pins
	CLOCK_50,
	CLOCK2_50,
	CLOCK3_50,
	CLOCK4_50,

	// ADC
	ADC_CS_N,
	ADC_DIN,
	ADC_DOUT,
	ADC_SCLK,

	// Audio
	AUD_ADCDAT,
	AUD_ADCLRCK,
	AUD_BCLK,
	AUD_DACDAT,
	AUD_DACLRCK,
	AUD_XCK,

	// SDRAM
	DRAM_ADDR,
	DRAM_BA,
	DRAM_CAS_N,
	DRAM_CKE,
	DRAM_CLK,
	DRAM_CS_N,
	DRAM_DQ,
	DRAM_LDQM,
	DRAM_RAS_N,
	DRAM_UDQM,
	DRAM_WE_N,

	// I2C Bus for Configuration of the Audio and Video-In Chips
	FPGA_I2C_SCLK,
	FPGA_I2C_SDAT,

	// 40-Pin Headers
	GPIO_0,
	GPIO_1,
	
	// Seven Segment Displays
	HEX0,
	HEX1,
	HEX2,
	HEX3,
	HEX4,
	HEX5,

	// IR
	IRDA_RXD,
	IRDA_TXD,

	// Pushbuttons
	KEY,

	// LEDs
	LEDR,

	// PS2 Ports
	PS2_CLK,
	PS2_DAT,
	
	PS2_CLK2,
	PS2_DAT2,

	// Slider Switches
	SW,

	// Video-In
	TD_CLK27,
	TD_DATA,
	TD_HS,
	TD_RESET_N,
	TD_VS,

	// VGA
	VGA_B,
	VGA_BLANK_N,
	VGA_CLK,
	VGA_G,
	VGA_HS,
	VGA_R,
	VGA_SYNC_N,
	VGA_VS,

	////////////////////////////////////
	// HPS Pins
	////////////////////////////////////
	
	// DDR3 SDRAM
	HPS_DDR3_ADDR,
	HPS_DDR3_BA,
	HPS_DDR3_CAS_N,
	HPS_DDR3_CKE,
	HPS_DDR3_CK_N,
	HPS_DDR3_CK_P,
	HPS_DDR3_CS_N,
	HPS_DDR3_DM,
	HPS_DDR3_DQ,
	HPS_DDR3_DQS_N,
	HPS_DDR3_DQS_P,
	HPS_DDR3_ODT,
	HPS_DDR3_RAS_N,
	HPS_DDR3_RESET_N,
	HPS_DDR3_RZQ,
	HPS_DDR3_WE_N,

	// Ethernet
	HPS_ENET_GTX_CLK,
	HPS_ENET_INT_N,
	HPS_ENET_MDC,
	HPS_ENET_MDIO,
	HPS_ENET_RX_CLK,
	HPS_ENET_RX_DATA,
	HPS_ENET_RX_DV,
	HPS_ENET_TX_DATA,
	HPS_ENET_TX_EN,

	// Flash
	HPS_FLASH_DATA,
	HPS_FLASH_DCLK,
	HPS_FLASH_NCSO,

	// Accelerometer
	HPS_GSENSOR_INT,
		
	// General Purpose I/O
	HPS_GPIO,
		
	// I2C
	HPS_I2C_CONTROL,
	HPS_I2C1_SCLK,
	HPS_I2C1_SDAT,
	HPS_I2C2_SCLK,
	HPS_I2C2_SDAT,

	// Pushbutton
	HPS_KEY,

	// LED
	HPS_LED,
		
	// SD Card
	HPS_SD_CLK,
	HPS_SD_CMD,
	HPS_SD_DATA,

	// SPI
	HPS_SPIM_CLK,
	HPS_SPIM_MISO,
	HPS_SPIM_MOSI,
	HPS_SPIM_SS,

	// UART
	HPS_UART_RX,
	HPS_UART_TX,

	// USB
	HPS_CONV_USB_N,
	HPS_USB_CLKOUT,
	HPS_USB_DATA,
	HPS_USB_DIR,
	HPS_USB_NXT,
	HPS_USB_STP
);

//=======================================================
//  PARAMETER declarations
//=======================================================


//=======================================================
//  PORT declarations
//=======================================================

////////////////////////////////////
// FPGA Pins
////////////////////////////////////

// Clock pins
input						CLOCK_50;
input						CLOCK2_50;
input						CLOCK3_50;
input						CLOCK4_50;

// ADC
inout						ADC_CS_N;
output					ADC_DIN;
input						ADC_DOUT;
output					ADC_SCLK;

// Audio
input						AUD_ADCDAT;
inout						AUD_ADCLRCK;
inout						AUD_BCLK;
output					AUD_DACDAT;
inout						AUD_DACLRCK;
output					AUD_XCK;

// SDRAM
output 		[12: 0]	DRAM_ADDR;
output		[ 1: 0]	DRAM_BA;
output					DRAM_CAS_N;
output					DRAM_CKE;
output					DRAM_CLK;
output					DRAM_CS_N;
inout			[15: 0]	DRAM_DQ;
output					DRAM_LDQM;
output					DRAM_RAS_N;
output					DRAM_UDQM;
output					DRAM_WE_N;

// I2C Bus for Configuration of the Audio and Video-In Chips
output					FPGA_I2C_SCLK;
inout						FPGA_I2C_SDAT;

// 40-pin headers
inout			[35: 0]	GPIO_0;
inout			[35: 0]	GPIO_1;

// Seven Segment Displays
output		[ 6: 0]	HEX0;
output		[ 6: 0]	HEX1;
output		[ 6: 0]	HEX2;
output		[ 6: 0]	HEX3;
output		[ 6: 0]	HEX4;
output		[ 6: 0]	HEX5;

// IR
input						IRDA_RXD;
output					IRDA_TXD;

// Pushbuttons
input			[ 3: 0]	KEY;

// LEDs
output		[ 9: 0]	LEDR;

// PS2 Ports
inout						PS2_CLK;
inout						PS2_DAT;

inout						PS2_CLK2;
inout						PS2_DAT2;

// Slider Switches
input			[ 9: 0]	SW;

// Video-In
input						TD_CLK27;
input			[ 7: 0]	TD_DATA;
input						TD_HS;
output					TD_RESET_N;
input						TD_VS;

// VGA
output		[ 7: 0]	VGA_B;
output					VGA_BLANK_N;
output					VGA_CLK;
output		[ 7: 0]	VGA_G;
output					VGA_HS;
output		[ 7: 0]	VGA_R;
output					VGA_SYNC_N;
output					VGA_VS;



////////////////////////////////////
// HPS Pins
////////////////////////////////////
	
// DDR3 SDRAM
output		[14: 0]	HPS_DDR3_ADDR;
output		[ 2: 0]  HPS_DDR3_BA;
output					HPS_DDR3_CAS_N;
output					HPS_DDR3_CKE;
output					HPS_DDR3_CK_N;
output					HPS_DDR3_CK_P;
output					HPS_DDR3_CS_N;
output		[ 3: 0]	HPS_DDR3_DM;
inout			[31: 0]	HPS_DDR3_DQ;
inout			[ 3: 0]	HPS_DDR3_DQS_N;
inout			[ 3: 0]	HPS_DDR3_DQS_P;
output					HPS_DDR3_ODT;
output					HPS_DDR3_RAS_N;
output					HPS_DDR3_RESET_N;
input						HPS_DDR3_RZQ;
output					HPS_DDR3_WE_N;

// Ethernet
output					HPS_ENET_GTX_CLK;
inout						HPS_ENET_INT_N;
output					HPS_ENET_MDC;
inout						HPS_ENET_MDIO;
input						HPS_ENET_RX_CLK;
input			[ 3: 0]	HPS_ENET_RX_DATA;
input						HPS_ENET_RX_DV;
output		[ 3: 0]	HPS_ENET_TX_DATA;
output					HPS_ENET_TX_EN;

// Flash
inout			[ 3: 0]	HPS_FLASH_DATA;
output					HPS_FLASH_DCLK;
output					HPS_FLASH_NCSO;

// Accelerometer
inout						HPS_GSENSOR_INT;

// General Purpose I/O
inout			[ 1: 0]	HPS_GPIO;

// I2C
inout						HPS_I2C_CONTROL;
inout						HPS_I2C1_SCLK;
inout						HPS_I2C1_SDAT;
inout						HPS_I2C2_SCLK;
inout						HPS_I2C2_SDAT;

// Pushbutton
inout						HPS_KEY;

// LED
inout						HPS_LED;

// SD Card
output					HPS_SD_CLK;
inout						HPS_SD_CMD;
inout			[ 3: 0]	HPS_SD_DATA;

// SPI
output					HPS_SPIM_CLK;
input						HPS_SPIM_MISO;
output					HPS_SPIM_MOSI;
inout						HPS_SPIM_SS;

// UART
input						HPS_UART_RX;
output					HPS_UART_TX;

// USB
inout						HPS_CONV_USB_N;
input						HPS_USB_CLKOUT;
inout			[ 7: 0]	HPS_USB_DATA;
input						HPS_USB_DIR;
input						HPS_USB_NXT;
output					HPS_USB_STP;

//=======================================================
//  REG/WIRE declarations
//=======================================================

// Stereo layout assumptions:
//  - Input is a 640x288 side-by-side frame.
//  - Left camera occupies x=[0..314], Right x=[319..633].
localparam FULL_FRAME_WIDTH     = 640;
localparam HALF_FRAME_WIDTH     = 320;
localparam FRAME_HEIGHT         = 200;
localparam LEFT_OUTPUT_X_START  = 0;
localparam LEFT_LUT_WIDTH       = 315;
localparam INTER_CAMERA_GAP     = 4;
localparam RIGHT_OUTPUT_X_START = LEFT_OUTPUT_X_START + LEFT_LUT_WIDTH + INTER_CAMERA_GAP;
localparam RIGHT_LUT_WIDTH      = 315;

// The video-in clipper removes 44 rows from top and bottom of the original 288-row image.
// The radial mapper LUT was calibrated for the original 288-row frame,
// so we must offset coordinates when calling the mapper.
localparam Y_CROP_OFFSET = 44;

// Stereo engine parameters
localparam BLOCK_SIZE      = 5;
localparam PIXEL_W         = 8;
localparam MAX_DISP        = 85;
localparam FULL_ROW_WIDTH  = FULL_FRAME_WIDTH;  // 640: left(0..319) + right(320..639)

// Striped BRAM layout. The single monolithic BRAM has been replaced by
// NUM_STRIPES independent M10K-backed sub-banks so column_prefetch can read
// one byte from each stripe in parallel each cycle. Choose STRIPE_HEIGHT
// equal to FRAME_HEIGHT/NUM_SAD_UNITS so the SAD engine's stripes line up
// with the BRAM stripes.
// STRIPE_HEIGHT chosen to minimise M10K usage. Each stripe has DEPTH =
// STRIPE_HEIGHT * 640 entries, and Quartus provisions M10Ks by rounding the
// address space up to the next power of 2. STRIPE_HEIGHT=3 -> DEPTH=1920 ->
// 11-bit addr -> 2 M10Ks/stripe * 67 stripes = 134 M10Ks. STRIPE_HEIGHT=8
// gave 8 M10Ks * 25 = 200 and overflowed the chip's M10K budget.
//
// Note: bram_stripe_of() / bram_row_in_stripe_of() in fill_pipe_controller.v
// (and the equivalent legacy assignment in state==4'd8 below) MUST use real
// `/` and `%`, NOT bit-slicing, since 3 is not a power of 2.
localparam NUM_SAD_UNITS    = 24;
localparam STRIPE_HEIGHT    = 3;
localparam NUM_STRIPES      = (FRAME_HEIGHT + STRIPE_HEIGHT - 1) / STRIPE_HEIGHT; // 67
localparam STRIPE_W         = 7;  // $clog2(NUM_STRIPES) = $clog2(67) = 7
localparam ROW_IN_STRIPE_W  = 2;  // $clog2(STRIPE_HEIGHT) = $clog2(3) = 2
localparam BRAM_COL_W       = 10; // $clog2(FULL_ROW_WIDTH) = $clog2(640) = 10

// Top-level phase
localparam [1:0] PHASE_FILL      = 2'd0;
localparam [1:0] PHASE_COMPUTE   = 2'd1;
reg [1:0] top_phase;

wire [15:0] hex3_hex0;
assign HEX4 = 7'b1111111;
assign HEX5 = 7'b1111111;
HexDigit Digit0(HEX0, hex3_hex0[3:0]);
HexDigit Digit1(HEX1, hex3_hex0[7:4]);
HexDigit Digit2(HEX2, hex3_hex0[11:8]);
HexDigit Digit3(HEX3, hex3_hex0[15:12]);

assign TD_RESET_N = SW[1];
assign GPIO_0[0] = TD_HS;
assign GPIO_0[1] = TD_VS;
assign GPIO_0[2] = TD_DATA[6];
assign GPIO_0[3] = TD_CLK27;
assign GPIO_0[4] = TD_RESET_N;

//=======================================================
// Split L/R BRAM for left+right camera images.
//
// 134 M10K banks (67 left + 67 right). Each stores
// 3 rows × 320 cols = 960 entries at 93.75% utilization.
//=======================================================
reg                          bram_wr_en;
reg [BRAM_ROW_W-1:0]         bram_wr_row;
reg [BRAM_COL_W-1:0]         bram_wr_col;
reg [7:0]                    bram_wr_data;

wire [BRAM_COL_W-1:0]        bram_rd_col;
wire [ROW_IN_STRIPE_W-1:0]   bram_rd_row_in_stripe;
wire [NUM_STRIPES*8-1:0]     bram_rd_data_flat;

stereo_bram_bank #(
	.FRAME_HEIGHT    (FRAME_HEIGHT),
	.HALF_FRAME_WIDTH(HALF_FRAME_WIDTH),
	.FULL_ROW_WIDTH  (FULL_ROW_WIDTH),
	.ROWS_PER_BANK   (ROWS_PER_BANK),
	.DATA_W          (8)
) stereo_bram (
	.clk             (CLOCK2_50),
	.wr_en           (mux_bram_wr_en),
	.wr_row          (mux_bram_wr_row),
	.wr_col          (mux_bram_wr_col),
	.wr_data         (mux_bram_wr_data),
	.rd_row_in_bank  (bram_rd_row_in_bank),
	.rd_col          (bram_rd_col),
	.rd_row_in_stripe(bram_rd_row_in_stripe),
	.rd_data_flat    (bram_rd_data_flat)
);

//=======================================================
// Bus controller for AVALON bus-master
//=======================================================
wire [31:0] vga_bus_addr, video_in_bus_addr;
reg  [31:0] bus_addr;
wire [31:0] vga_out_base_address = 32'h0000_0000;
wire [31:0] video_in_base_address = 32'h0800_0000;
reg [3:0] bus_byte_enable;
reg bus_read, bus_write;
reg [31:0] bus_write_data;
wire bus_ack;
wire [31:0] bus_read_data;
reg [31:0] timer;
reg [3:0] state;

reg [9:0] vga_x_cood, vga_y_cood;
reg [9:0] video_in_x_cood, video_in_y_cood;
reg [9:0] old_video_in_x_cood, old_video_in_y_cood;
reg [7:0] current_pixel_color1;
reg old_poly_valid;
reg map_enable_latched;
reg read_video_start;
wire [9:0] read_video_map_x, read_video_map_y;
wire read_video_map_valid, read_video_map_done;

wire raw_read_valid =
	(old_video_in_y_cood < FRAME_HEIGHT) &&
	((old_video_in_x_cood < LEFT_LUT_WIDTH) ||
	 ((old_video_in_x_cood >= RIGHT_OUTPUT_X_START) &&
	  (old_video_in_x_cood < (RIGHT_OUTPUT_X_START + RIGHT_LUT_WIDTH))));

// Adjusted mapper outputs: subtract Y_CROP_OFFSET from src_y since
// the video-in buffer now starts at original row 44
wire [9:0] adjusted_map_y = (read_video_map_y >= Y_CROP_OFFSET) ?
	(read_video_map_y - Y_CROP_OFFSET) : 10'd0;
wire adjusted_map_valid = read_video_map_valid &&
	(read_video_map_y >= Y_CROP_OFFSET) &&
	(read_video_map_y < (Y_CROP_OFFSET + FRAME_HEIGHT));

wire [9:0] read_video_x = map_enable_latched ? read_video_map_x : old_video_in_x_cood;
wire [9:0] read_video_y = map_enable_latched ? adjusted_map_y    : old_video_in_y_cood;
wire read_video_valid   = map_enable_latched ? adjusted_map_valid : raw_read_valid;
wire read_video_done    = map_enable_latched ? read_video_map_done : 1'b1;

wire [9:0] write_vga_x = old_video_in_x_cood - vga_x_cood;
wire [9:0] write_vga_y = old_video_in_y_cood + vga_y_cood;

assign vga_bus_addr      = vga_out_base_address + {22'b0,write_vga_x} + ({22'b0,write_vga_y}<<10);
assign video_in_bus_addr = video_in_base_address + {22'b0,read_video_x} + ({22'b0,read_video_y}<<10);

reg display_right_sel;
wire right_read_side = (old_video_in_x_cood >= RIGHT_OUTPUT_X_START) ? 1'b1 : 1'b0;
wire [9:0] right_cam_mem_x_cood = old_video_in_x_cood - RIGHT_OUTPUT_X_START;

// Track whether the full frame has been read
reg frame_filled;

//=======================================================
// Stereo engine: mem_block_intf + column prefetch
//=======================================================
wire        mbi_mem_req, mbi_mem_bank, mbi_done, mbi_stall;
wire [8:0]  mbi_mem_col;
wire [7:0]  mbi_mem_rdata [0:FRAME_HEIGHT-1];
reg         mbi_go, mbi_rst;

// Streaming disparity output from mem_block_intf
localparam DISP_W = 7; // clog2(85+1)=7
localparam ROW_W  = 8; // clog2(200)=8
wire             mbi_disp_valid;
wire [ROW_W-1:0] mbi_disp_y;
wire [8:0]       mbi_disp_x;
wire [DISP_W-1:0] mbi_disp_value;
reg              mbi_disp_ack;

column_prefetch #(
	.FRAME_HEIGHT    (FRAME_HEIGHT),
	.HALF_FRAME_WIDTH(HALF_FRAME_WIDTH),
	.ROWS_PER_BANK   (ROWS_PER_BANK),
	.NUM_BANKS       (NUM_BANKS),
	.PIXEL_W         (PIXEL_W),
	.COL_W           (9)
) u_col_prefetch (
	.clk                  (CLOCK2_50),
	.rst                  (~KEY[0]),
	.mbi_mem_req          (mbi_mem_req),
	.mbi_mem_bank         (mbi_mem_bank),
	.mbi_mem_col          (mbi_mem_col),
	.stall                (mbi_stall),
	.mem_rdata            (mbi_mem_rdata),
	.bram_rd_col          (bram_rd_col),
	.bram_rd_row_in_stripe(bram_rd_row_in_stripe),
	.bram_rd_data_flat    (bram_rd_data_flat)
);

mem_block_intf #(
	.FRAME_HEIGHT(FRAME_HEIGHT), .HALF_FRAME_WIDTH(HALF_FRAME_WIDTH),
	.BLOCK_SIZE(BLOCK_SIZE), .PIXEL_W(PIXEL_W), .MAX_DISP(MAX_DISP),
	.NUM_SAD_UNITS(NUM_SAD_UNITS)
) u_mem_block_intf (
	.clk(CLOCK2_50), .rst(mbi_rst),
	.go(mbi_go), .stall(mbi_stall),
	.mem_req(mbi_mem_req), .mem_bank(mbi_mem_bank), .mem_col(mbi_mem_col),
	.mem_rdata(mbi_mem_rdata),
	.disp_valid(mbi_disp_valid), .disp_out_y(mbi_disp_y),
	.disp_out_x(mbi_disp_x), .disp_out_value(mbi_disp_value),
	.disp_ack(mbi_disp_ack),
	.done(mbi_done)
);

// Scale disparity to pixel intensity. High disparity = closer object = bright;
// low disparity = farther away = dark. disp >= 85 means out of search range
// and is rendered black.
wire [7:0] disp_pixel_color = (mbi_disp_value >= 85) ? 8'h00 :
	(mbi_disp_value[6:0] * 8'd3);

// VGA address for streaming disparity: place right below raw video (row 200+)
wire [9:0] disp_vga_y = mbi_disp_y + FRAME_HEIGHT;
wire [31:0] disp_stream_vga_addr = vga_out_base_address +
	{22'b0, mbi_disp_x} + ({22'b0, disp_vga_y} << 10);

// Debug: show top_phase on HEX
assign hex3_hex0 = {6'b0, top_phase, 8'b0};

// Radial mapper — feed original-frame coordinates (add Y_CROP_OFFSET to dst_y)
wire [9:0] mapper_dst_y = video_in_y_cood + Y_CROP_OFFSET;
stereo_radial_mapper_q15 stereo_radial_mapper_inst (
	.clk(CLOCK2_50), .reset_n(KEY[0]),
	.start(read_video_start),
	.dst_x(video_in_x_cood), .dst_y(mapper_dst_y),
	.src_x(read_video_map_x), .src_y(read_video_map_y),
	.valid(read_video_map_valid), .done(read_video_map_done),
	.busy()
);

// SW inputs are asynchronous slider switches with mechanical bounce.
// Two-FF synchronizers prevent metastability and glitching the bus mux
// (pipe_active) mid-transaction when SW[4] is toggled at runtime.
reg sw0_q1, sw0_q2;
reg sw3_q1, sw3_q2;
reg sw4_q1, sw4_q2;
always @(posedge CLOCK2_50) begin
	sw0_q1 <= SW[0]; sw0_q2 <= sw0_q1;
	sw3_q1 <= SW[3]; sw3_q2 <= sw3_q1;
	sw4_q1 <= SW[4]; sw4_q2 <= sw4_q1;
end
wire sw0_sync = sw0_q2;
wire sw3_sync = sw3_q2;

// SW[4] = stereo enable
wire stereo_enabled = sw4_q2;

//=======================================================
// Streaming FILL controller (pipelined mapper + bus + BRAM + VGA)
//
// When stereo is enabled this replaces the legacy per-pixel PHASE_FILL FSM.
// The controller drives the EBAB master (one camera read + one VGA write
// per pixel) and the stereo BRAM. The legacy FSM is left in place for the
// non-stereo debug-display mode; muxes below select which one drives each
// shared signal at any given cycle.
//=======================================================
wire        fp_done;
wire [31:0] fp_bus_addr;
wire        fp_bus_read;
wire        fp_bus_write;
wire [3:0]  fp_bus_byte_enable;
wire [31:0] fp_bus_write_data;
wire                    fp_bram_wr_en;
wire [BRAM_ROW_W-1:0]   fp_bram_wr_row;
wire [BRAM_COL_W-1:0]   fp_bram_wr_col;
wire [7:0]              fp_bram_wr_data;

// pipe_active gates whose signals reach the EBAB / BRAM. While pipe_active is
// true (PHASE_FILL with stereo on), the legacy bus_*/bram_wr_* registers are
// kept off the wires. fp_go is purely combinational from this gate plus SW[0],
// minus the one cycle that fp_done is asserted -- otherwise the controller
// would race-restart between done and the phase transition.
wire pipe_active = (top_phase == PHASE_FILL) && stereo_enabled;
wire fp_go       = pipe_active && sw0_sync && !fp_done;

// Muxed bus signals -- these are what actually go to the EBAB master.
wire [31:0] mux_bus_addr        = pipe_active ? fp_bus_addr        : bus_addr;
wire        mux_bus_read        = pipe_active ? fp_bus_read        : bus_read;
wire [3:0]  mux_bus_byte_enable = pipe_active ? fp_bus_byte_enable : bus_byte_enable;
wire        mux_bus_write       = pipe_active ? fp_bus_write       : bus_write;
wire [31:0] mux_bus_write_data  = pipe_active ? fp_bus_write_data  : bus_write_data;

// Muxed BRAM write signals -- what actually goes to stereo_bram.
wire                    mux_bram_wr_en   = pipe_active ? fp_bram_wr_en   : bram_wr_en;
wire [BRAM_ROW_W-1:0]   mux_bram_wr_row  = pipe_active ? fp_bram_wr_row  : bram_wr_row;
wire [BRAM_COL_W-1:0]   mux_bram_wr_col  = pipe_active ? fp_bram_wr_col  : bram_wr_col;
wire [7:0]              mux_bram_wr_data = pipe_active ? fp_bram_wr_data : bram_wr_data;

fill_pipe_controller #(
    .FULL_FRAME_WIDTH    (FULL_FRAME_WIDTH),
    .FRAME_HEIGHT        (FRAME_HEIGHT),
    .FULL_ROW_WIDTH      (FULL_ROW_WIDTH),
    .Y_CROP_OFFSET       (Y_CROP_OFFSET),
    .HALF_FRAME_WIDTH    (HALF_FRAME_WIDTH),
    .LEFT_LUT_WIDTH      (LEFT_LUT_WIDTH),
    .INTER_CAMERA_GAP    (INTER_CAMERA_GAP),
    .RIGHT_OUTPUT_X_START(RIGHT_OUTPUT_X_START),
    .MAPPER_LATENCY      (11)
) u_fill_pipe (
    .clk                   (CLOCK2_50),
    .reset_n               (KEY[0]),
    .go                    (fp_go),

    .bus_addr              (fp_bus_addr),
    .bus_read              (fp_bus_read),
    .bus_write             (fp_bus_write),
    .bus_byte_enable       (fp_bus_byte_enable),
    .bus_write_data        (fp_bus_write_data),
    .bus_read_data         (bus_read_data),
    .bus_ack               (bus_ack),

    .bram_wr_en            (fp_bram_wr_en),
    .bram_wr_row           (fp_bram_wr_row),
    .bram_wr_col           (fp_bram_wr_col),
    .bram_wr_data          (fp_bram_wr_data),

    .done                  (fp_done)
);

//=======================================================
// Main FSM: FILL → COMPUTE → WRITEBACK → FILL ...
//=======================================================
always @(posedge CLOCK2_50) begin
	if (~KEY[0]) begin
		state <= 0;
		bus_read <= 0; bus_write <= 0;
		vga_x_cood <= 0; vga_y_cood <= 0;
		video_in_x_cood <= 0; old_video_in_x_cood <= 0;
		video_in_y_cood <= 0; old_video_in_y_cood <= 0;
		bus_byte_enable <= 4'b0001;
		old_poly_valid <= 0;
		map_enable_latched <= 1'b1;
		read_video_start <= 0;
		display_right_sel <= SW[2];
		timer <= 0;
		top_phase <= PHASE_FILL;
		bram_wr_en   <= 0;
		bram_wr_row  <= 0;
		bram_wr_col  <= 0;
		bram_wr_data <= 0;
		mbi_go <= 0; mbi_rst <= 1;
		frame_filled <= 0;
		current_pixel_color1 <= 0;
		mbi_disp_ack <= 0;
	end
	else begin
		timer <= timer + 1;
		read_video_start <= 1'b0;
		bram_wr_en <= 1'b0;
		mbi_go <= 1'b0;
		mbi_disp_ack <= 1'b0;

		case (top_phase)

		// ============ PHASE_FILL ============
		PHASE_FILL: begin
			mbi_rst <= 1'b1;

			if (stereo_enabled) begin
				// ---- Streaming pipelined fill via fill_pipe_controller ----
				// fp_go is combinational from (top_phase, SW[0]); the phase
				// machine itself sequences FILL -> COMPUTE -> FILL.
				if (fp_done) begin
					// Frame is in BRAM and on VGA. Hop to PHASE_COMPUTE.
					top_phase    <= PHASE_COMPUTE;
					frame_filled <= 1'b1;
					state        <= 4'd0;
				end
			end else begin
				// ---- Legacy per-pixel debug path (raw video copy to VGA) ----
				if (state==0 && sw0_sync && (timer & 5) == 0) begin
					state <= 4'd11;
					map_enable_latched <= sw3_sync;
					read_video_start <= 1'b1;
					old_video_in_x_cood <= video_in_x_cood;
					old_video_in_y_cood <= video_in_y_cood;
					video_in_x_cood <= video_in_x_cood + 10'd1;
					if (video_in_x_cood >= FULL_FRAME_WIDTH - 1) begin
						video_in_x_cood <= 0;
						video_in_y_cood <= video_in_y_cood + 10'd1;
						if (video_in_y_cood >= FRAME_HEIGHT - 1) begin
							video_in_y_cood <= 10'd0;
						end
					end
					bus_byte_enable <= 4'b0001;
				end

				if (state==4'd11 && read_video_done) begin
					state <= 4'd10;
					old_poly_valid <= read_video_valid;
				end

				if (state==4'd10) begin
					state <= 4'd1;
					bus_byte_enable <= 4'b0001;
					bus_addr <= video_in_bus_addr;
					bus_read <= 1'b1;
				end

				if (state==4'd1 && bus_ack) begin
					state <= 4'd8;
					bus_read <= 1'b0;
					current_pixel_color1 <= old_poly_valid ? bus_read_data[7:0] : 8'h00;
				end

				if (state==4'd8) begin
					// Write to striped BRAM. Decompose dy into
					// (stripe, row_in_stripe) and select the col_global
					// (left at 0..319, right at 320..639). Use real / and %
					// since STRIPE_HEIGHT is not a power of 2 (=3); Quartus
					// synthesizes divide-by-constant as a tiny shift/add net.
					bram_wr_en            <= 1'b1;
					bram_wr_data          <= current_pixel_color1;
					bram_wr_stripe        <= old_video_in_y_cood / STRIPE_HEIGHT;
					bram_wr_row_in_stripe <= old_video_in_y_cood % STRIPE_HEIGHT;
					if (right_read_side) begin
						bram_wr_col <= HALF_FRAME_WIDTH + right_cam_mem_x_cood;
					end else begin
						bram_wr_col <= old_video_in_x_cood;
					end
					// Push the same pixel to the VGA so the user can see what the
					// cameras see. State 9 waits for the VGA bus_ack.
					state <= 4'd9;
					bus_write <= 1'b1;
					bus_addr <= vga_bus_addr;
					bus_write_data <= current_pixel_color1;
					bus_byte_enable <= 4'b0001;
				end

				if (state==4'd9 && bus_ack) begin
					bus_write <= 1'b0;
					if (old_video_in_x_cood == (FULL_FRAME_WIDTH-1) &&
					    old_video_in_y_cood == (FRAME_HEIGHT-1)) begin
						state <= 4'd0;
						frame_filled <= 1'b1;
					end else begin
						state <= 4'd0;
					end
				end
			end
		end

		// ============ PHASE_COMPUTE ============
		PHASE_COMPUTE: begin
			mbi_rst <= 1'b0;
			// Start computation
			if (!mbi_done && !mbi_go && state == 0) begin
				mbi_go <= 1'b1;
				state <= 4'd1;
			end

			// Handle streaming disparity output
			if (mbi_disp_valid && state != 4'd13 && state != 4'd14) begin
				// New disparity pixel ready — write to VGA
				state <= 4'd13;
				bus_write <= 1'b1;
				bus_addr <= disp_stream_vga_addr;
				bus_write_data <= {24'b0, disp_pixel_color};
				bus_byte_enable <= 4'b0001;
			end

			if (state == 4'd13 && bus_ack) begin
				bus_write <= 1'b0;
				mbi_disp_ack <= 1'b1; // acknowledge to mem_block_intf
				state <= 4'd14;
			end

			// Hold ack for one cycle then release
			if (state == 4'd14) begin
				mbi_disp_ack <= 1'b0;
				state <= 4'd1; // back to waiting
			end

			// Done with entire computation
			if (mbi_done) begin
				top_phase    <= PHASE_FILL;
				state        <= 4'd0;
				frame_filled <= 0;
			end
		end

		default: top_phase <= PHASE_FILL;
		endcase
	end
end






//=======================================================
//  Structural coding
//=======================================================

Computer_System The_System (
	////////////////////////////////////
	// FPGA Side
	////////////////////////////////////

	// Global signals
	.system_pll_ref_clk_clk					(CLOCK_50),
	.system_pll_ref_reset_reset			(1'b0),

	// AV Config
	.av_config_SCLK							(FPGA_I2C_SCLK),
	.av_config_SDAT							(FPGA_I2C_SDAT),

	// VGA Subsystem
	.vga_pll_ref_clk_clk 					(CLOCK2_50),
	.vga_pll_ref_reset_reset				(1'b0),
	.vga_CLK										(VGA_CLK),
	.vga_BLANK									(VGA_BLANK_N),
	.vga_SYNC									(VGA_SYNC_N),
	.vga_HS										(VGA_HS),
	.vga_VS										(VGA_VS),
	.vga_R										(VGA_R),
	.vga_G										(VGA_G),
	.vga_B										(VGA_B),
	
	// Video In Subsystem
	.video_in_TD_CLK27 						(TD_CLK27),
	.video_in_TD_DATA							(TD_DATA),
	.video_in_TD_HS							(TD_HS),
	.video_in_TD_VS							(TD_VS),
	.video_in_clk27_reset					(),
	.video_in_TD_RESET						(),
	.video_in_overflow_flag					(),
	
	//PIO out
	.pio_test_test_export(32'd5),
	
	.ebab_video_in_external_interface_address     (mux_bus_addr),     //
	.ebab_video_in_external_interface_byte_enable (mux_bus_byte_enable), //  .byte_enable
	.ebab_video_in_external_interface_read        (mux_bus_read),        //  .read
	.ebab_video_in_external_interface_write       (mux_bus_write),       //  .write
	.ebab_video_in_external_interface_write_data  (mux_bus_write_data),  //.write_data
	.ebab_video_in_external_interface_acknowledge (bus_ack), //  .acknowledge
	.ebab_video_in_external_interface_read_data   (bus_read_data),
	// clock bridge for EBAb_video_in_external_interface_acknowledge
	.clock_bridge_0_in_clk_clk                    (CLOCK_50),
		
	// SDRAM
	.sdram_clk_clk								(DRAM_CLK),
   .sdram_addr									(DRAM_ADDR),
	.sdram_ba									(DRAM_BA),
	.sdram_cas_n								(DRAM_CAS_N),
	.sdram_cke									(DRAM_CKE),
	.sdram_cs_n									(DRAM_CS_N),
	.sdram_dq									(DRAM_DQ),
	.sdram_dqm									({DRAM_UDQM,DRAM_LDQM}),
	.sdram_ras_n								(DRAM_RAS_N),
	.sdram_we_n									(DRAM_WE_N),
	
	////////////////////////////////////
	// HPS Side
	////////////////////////////////////
	// DDR3 SDRAM
	.memory_mem_a			(HPS_DDR3_ADDR),
	.memory_mem_ba			(HPS_DDR3_BA),
	.memory_mem_ck			(HPS_DDR3_CK_P),
	.memory_mem_ck_n		(HPS_DDR3_CK_N),
	.memory_mem_cke		(HPS_DDR3_CKE),
	.memory_mem_cs_n		(HPS_DDR3_CS_N),
	.memory_mem_ras_n		(HPS_DDR3_RAS_N),
	.memory_mem_cas_n		(HPS_DDR3_CAS_N),
	.memory_mem_we_n		(HPS_DDR3_WE_N),
	.memory_mem_reset_n	(HPS_DDR3_RESET_N),
	.memory_mem_dq			(HPS_DDR3_DQ),
	.memory_mem_dqs		(HPS_DDR3_DQS_P),
	.memory_mem_dqs_n		(HPS_DDR3_DQS_N),
	.memory_mem_odt		(HPS_DDR3_ODT),
	.memory_mem_dm			(HPS_DDR3_DM),
	.memory_oct_rzqin		(HPS_DDR3_RZQ),
		  
	// Ethernet
	.hps_io_hps_io_gpio_inst_GPIO35	(HPS_ENET_INT_N),
	.hps_io_hps_io_emac1_inst_TX_CLK	(HPS_ENET_GTX_CLK),
	.hps_io_hps_io_emac1_inst_TXD0	(HPS_ENET_TX_DATA[0]),
	.hps_io_hps_io_emac1_inst_TXD1	(HPS_ENET_TX_DATA[1]),
	.hps_io_hps_io_emac1_inst_TXD2	(HPS_ENET_TX_DATA[2]),
	.hps_io_hps_io_emac1_inst_TXD3	(HPS_ENET_TX_DATA[3]),
	.hps_io_hps_io_emac1_inst_RXD0	(HPS_ENET_RX_DATA[0]),
	.hps_io_hps_io_emac1_inst_MDIO	(HPS_ENET_MDIO),
	.hps_io_hps_io_emac1_inst_MDC		(HPS_ENET_MDC),
	.hps_io_hps_io_emac1_inst_RX_CTL	(HPS_ENET_RX_DV),
	.hps_io_hps_io_emac1_inst_TX_CTL	(HPS_ENET_TX_EN),
	.hps_io_hps_io_emac1_inst_RX_CLK	(HPS_ENET_RX_CLK),
	.hps_io_hps_io_emac1_inst_RXD1	(HPS_ENET_RX_DATA[1]),
	.hps_io_hps_io_emac1_inst_RXD2	(HPS_ENET_RX_DATA[2]),
	.hps_io_hps_io_emac1_inst_RXD3	(HPS_ENET_RX_DATA[3]),

	// Flash
	.hps_io_hps_io_qspi_inst_IO0	(HPS_FLASH_DATA[0]),
	.hps_io_hps_io_qspi_inst_IO1	(HPS_FLASH_DATA[1]),
	.hps_io_hps_io_qspi_inst_IO2	(HPS_FLASH_DATA[2]),
	.hps_io_hps_io_qspi_inst_IO3	(HPS_FLASH_DATA[3]),
	.hps_io_hps_io_qspi_inst_SS0	(HPS_FLASH_NCSO),
	.hps_io_hps_io_qspi_inst_CLK	(HPS_FLASH_DCLK),

	// Accelerometer
	.hps_io_hps_io_gpio_inst_GPIO61	(HPS_GSENSOR_INT),

	//.adc_sclk                        (ADC_SCLK),
	//.adc_cs_n                        (ADC_CS_N),
	//.adc_dout                        (ADC_DOUT),
	//.adc_din                         (ADC_DIN),

	// General Purpose I/O
	.hps_io_hps_io_gpio_inst_GPIO40	(HPS_GPIO[0]),
	.hps_io_hps_io_gpio_inst_GPIO41	(HPS_GPIO[1]),

	// I2C
	.hps_io_hps_io_gpio_inst_GPIO48	(HPS_I2C_CONTROL),
	.hps_io_hps_io_i2c0_inst_SDA		(HPS_I2C1_SDAT),
	.hps_io_hps_io_i2c0_inst_SCL		(HPS_I2C1_SCLK),
	.hps_io_hps_io_i2c1_inst_SDA		(HPS_I2C2_SDAT),
	.hps_io_hps_io_i2c1_inst_SCL		(HPS_I2C2_SCLK),

	// Pushbutton
	.hps_io_hps_io_gpio_inst_GPIO54	(HPS_KEY),

	// LED
	.hps_io_hps_io_gpio_inst_GPIO53	(HPS_LED),

	// SD Card
	.hps_io_hps_io_sdio_inst_CMD	(HPS_SD_CMD),
	.hps_io_hps_io_sdio_inst_D0	(HPS_SD_DATA[0]),
	.hps_io_hps_io_sdio_inst_D1	(HPS_SD_DATA[1]),
	.hps_io_hps_io_sdio_inst_CLK	(HPS_SD_CLK),
	.hps_io_hps_io_sdio_inst_D2	(HPS_SD_DATA[2]),
	.hps_io_hps_io_sdio_inst_D3	(HPS_SD_DATA[3]),

	// SPI
	.hps_io_hps_io_spim1_inst_CLK		(HPS_SPIM_CLK),
	.hps_io_hps_io_spim1_inst_MOSI	(HPS_SPIM_MOSI),
	.hps_io_hps_io_spim1_inst_MISO	(HPS_SPIM_MISO),
	.hps_io_hps_io_spim1_inst_SS0		(HPS_SPIM_SS),

	// UART
	.hps_io_hps_io_uart0_inst_RX	(HPS_UART_RX),
	.hps_io_hps_io_uart0_inst_TX	(HPS_UART_TX),

	// USB
	.hps_io_hps_io_gpio_inst_GPIO09	(HPS_CONV_USB_N),
	.hps_io_hps_io_usb1_inst_D0		(HPS_USB_DATA[0]),
	.hps_io_hps_io_usb1_inst_D1		(HPS_USB_DATA[1]),
	.hps_io_hps_io_usb1_inst_D2		(HPS_USB_DATA[2]),
	.hps_io_hps_io_usb1_inst_D3		(HPS_USB_DATA[3]),
	.hps_io_hps_io_usb1_inst_D4		(HPS_USB_DATA[4]),
	.hps_io_hps_io_usb1_inst_D5		(HPS_USB_DATA[5]),
	.hps_io_hps_io_usb1_inst_D6		(HPS_USB_DATA[6]),
	.hps_io_hps_io_usb1_inst_D7		(HPS_USB_DATA[7]),
	.hps_io_hps_io_usb1_inst_CLK		(HPS_USB_CLKOUT),
	.hps_io_hps_io_usb1_inst_STP		(HPS_USB_STP),
	.hps_io_hps_io_usb1_inst_DIR		(HPS_USB_DIR),
	.hps_io_hps_io_usb1_inst_NXT		(HPS_USB_NXT)
);


endmodule
