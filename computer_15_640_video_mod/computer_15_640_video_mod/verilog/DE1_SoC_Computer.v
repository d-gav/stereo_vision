

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

// Top-level phase
//
// PHASE_WAIT is the only phase during which the Video-In DMA is allowed to
// write Onchip_SRAM. WAIT must be long enough that the DMA can lay down at
// least one complete PAL frame before FILL starts reading source pixels.
// FILL, DRAIN and COMPUTE all run with the s1 write-lock asserted so that
// drained undistorted bytes survive long enough for SAD to read them.
localparam [1:0] PHASE_FILL      = 2'd0;
localparam [1:0] PHASE_DRAIN     = 2'd2;   // tail-drain after FILL completes
localparam [1:0] PHASE_COMPUTE   = 2'd1;
localparam [1:0] PHASE_WAIT      = 2'd3;   // DMA refresh window, lock released
reg [1:0] top_phase;

// 50 ms at 50 MHz (CLOCK2_50). PAL is 40 ms/frame, so 50 ms guarantees the
// DMA writes at least one full frame into SRAM during WAIT regardless of
// where in its frame cycle the lock-release caught it. Increase if you see
// tearing in the rectified disparity output; decrease for higher update rate.
localparam [31:0] WAIT_CYCLES    = 32'd2_500_000;
reg [31:0] wait_start_timer;

// Undistortion staging ring buffer. PHASE_FILL produces undistorted pixels at
// destination coordinates and stages them into the ring; older rows are
// committed back to stereo_onchip_ram in place via Avalon writes (mid-frame
// drains during FILL, plus PHASE_DRAIN at the end). RING_DEPTH must be at
// least 1 + max |src_y - dst_y| of the radial mapper to avoid overwriting
// raw rows still needed as sources by later destinations.
localparam int RING_DEPTH = 13;            // K = RING_DEPTH - 1 = 12
localparam int DRAIN_K    = RING_DEPTH - 1;

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

// ---- LED diagnostic for SRAM lock and FSM phase ----
// LEDR[0] = sram_s1_write_lock (steady on except a brief gap during PHASE_WAIT
//                               every cycle; off only while DMA is allowed to
//                               write the SRAM)
// LEDR[1] = top_phase == PHASE_FILL    (longest pulse: rectify+drain in place)
// LEDR[2] = top_phase == PHASE_DRAIN   (brief ~3 ms pulse per cycle)
// LEDR[3] = top_phase == PHASE_COMPUTE (longer pulse per cycle: SAD running)
// LEDR[4] = frame_filled               (high from last pixel until mbi_done resets)
// LEDR[5] = top_phase == PHASE_WAIT    (~50 ms pulse: DMA refresh window)
assign LEDR[0] = sram_s1_write_lock;
assign LEDR[1] = (top_phase == PHASE_FILL);
assign LEDR[2] = (top_phase == PHASE_DRAIN);
assign LEDR[3] = (top_phase == PHASE_COMPUTE);
assign LEDR[4] = frame_filled;
assign LEDR[5] = (top_phase == PHASE_WAIT);
assign LEDR[9:6] = 4'b0;

//=======================================================
// Direct sad_port conduit into stereo_onchip_ram (port B of every row's M10K).
// SAD reads all FRAME_HEIGHT rows in parallel at one byte column per cycle;
// the Video-In DMA continues to write into Onchip_SRAM through s1 in the
// background, with the layout matching DE1_SoC_Computer.v's coordinate system
// (left col 0..LEFT_LUT_WIDTH-1, gap, right col RIGHT_OUTPUT_X_START..).
//=======================================================
wire                              sad_re;
wire [9:0]                        sad_col;
wire [FRAME_HEIGHT*PIXEL_W-1:0]   sad_rdata_flat;

// stereo_onchip_ram s1 write-lock. Asserted for the entire FILL → DRAIN →
// COMPUTE window, released only during PHASE_WAIT. The earlier policy of
// asserting only at frame_filled left the autonomous Video-In DMA free to
// overwrite mid-frame drained rows for the bulk of FILL, so SAD ended up
// reading raw DMA bytes instead of the undistorted pixels just committed.
// PHASE_WAIT exists precisely so the DMA still gets a window to refresh
// SRAM with a fresh frame between cycles. Registered to keep the s1 gate
// edge clean across top_phase transitions.
reg sram_s1_write_lock;
wire sram_s1_write_lock_next = (top_phase != PHASE_WAIT);
always @(posedge CLOCK2_50) begin
    if (~KEY[0]) sram_s1_write_lock <= 1'b0;
    else         sram_s1_write_lock <= sram_s1_write_lock_next;
end

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

// Undistortion ring-buffer drain controller state. cur_write_slot tracks
// (old_video_in_y_cood mod RING_DEPTH) for ring writes during FILL; drain_y/
// drain_byte/drain_slot drive the per-row writeback into stereo_onchip_ram.
//
// drain_byte iterates over BYTE columns 0..FULL_FRAME_WIDTH-1, not 32-bit
// words. The EBAB_video_in master is 8-bit (data_size=8 in Computer_System.qsys),
// so a "32-bit" write through bus_write_data only delivers the low 8 bits
// to the slave; advancing by 4 bytes per write would leave 3 of every 4
// byte columns of stereo_onchip_ram untouched (= stale DMA bytes), which
// silently dilutes the undistorted pixels and is what made SW[3] appear
// to have no effect on the disparity output.
reg [3:0] cur_write_slot;
reg [9:0] drain_y;            // 0..FRAME_HEIGHT  (== FRAME_HEIGHT means done)
reg [9:0] drain_byte;         // 0..FULL_FRAME_WIDTH-1
reg [3:0] drain_slot;         // (drain_y mod RING_DEPTH)
wire [31:0] ring_rd_data;
wire [31:0] drain_bus_addr =
    video_in_base_address
    + ({22'b0, drain_y}    << 10)   // row stride = 1024 bytes
    + {22'b0, drain_byte};          // byte stride within row

// Ring write enable: pulse for one cycle per produced pixel. State 4'd8 is
// where current_pixel_color1 is valid and the FILL FSM is queueing the VGA
// write; same cycle is the natural place to also commit the pixel into the
// staging ring.
wire ring_wr_en_pulse = (top_phase == PHASE_FILL) && (state == 4'd8);

undistort_ring #(.RING_DEPTH(RING_DEPTH)) u_undistort_ring (
    .clk         (CLOCK2_50),
    .wr_slot     (cur_write_slot),
    .wr_byte_col (old_video_in_x_cood),
    .wr_en       (ring_wr_en_pulse),
    .wr_data     (current_pixel_color1),
    .rd_slot     (drain_slot),
    .rd_word     (drain_byte[9:2]),
    .rd_data     (ring_rd_data)
);

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

// SGM penalty values driven by HPS via Avalon PIOs
// (pio_small_pen at LW offset 0x10, pio_big_pen at LW offset 0x20)
wire [31:0] pio_small_pen_value;
wire [31:0] pio_big_pen_value;

// Disparity range driven by HPS via Avalon PIOs. Used both to bound the
// SAD search and to drive the disparity-to-pixel colorization below.
wire [31:0] pio_min_disp_value;
wire [31:0] pio_max_disp_value;

column_prefetch_parallel #(
	.FRAME_HEIGHT      (FRAME_HEIGHT),
	.RIGHT_BANK_OFFSET (RIGHT_OUTPUT_X_START),  // 319 — matches the side-by-side
	                                            // layout the Video-In DMA writes
	                                            // (NOT HALF_FRAME_WIDTH=320)
	.PIXEL_W           (PIXEL_W),
	.COL_W             (9),
	.SAD_COL_W         (10)
) u_col_prefetch (
	.clk           (CLOCK2_50),
	.rst           (~KEY[0]),
	.mbi_mem_req   (mbi_mem_req),
	.mbi_mem_bank  (mbi_mem_bank),
	.mbi_mem_col   (mbi_mem_col),
	.stall         (mbi_stall),
	.mem_rdata     (mbi_mem_rdata),
	.sad_re        (sad_re),
	.sad_col       (sad_col),
	.sad_rdata_flat(sad_rdata_flat)
);

mem_block_intf #(
	.FRAME_HEIGHT(FRAME_HEIGHT), .HALF_FRAME_WIDTH(HALF_FRAME_WIDTH),
	.BLOCK_SIZE(BLOCK_SIZE), .PIXEL_W(PIXEL_W), .MAX_DISP(MAX_DISP),
	.NUM_SAD_UNITS(12)
) u_mem_block_intf (
	.clk(CLOCK2_50), .rst(mbi_rst),
	.go(mbi_go), .stall(mbi_stall),
	.sgm_p1(pio_small_pen_value), .sgm_p2(pio_big_pen_value),
	.mem_req(mbi_mem_req), .mem_bank(mbi_mem_bank), .mem_col(mbi_mem_col),
	.mem_rdata(mbi_mem_rdata),
	.disp_valid(mbi_disp_valid), .disp_out_y(mbi_disp_y),
	.disp_out_x(mbi_disp_x), .disp_out_value(mbi_disp_value),
	.disp_ack(mbi_disp_ack),
	.done(mbi_done)
);

// Disparity-to-pixel colorization, parameterized by the runtime min/max
// disparity PIOs.  Linear map:
//   disp == pio_min_disp -> 0xFF (white, near)
//   disp == pio_max_disp -> 0x00 (black, far)
//   disp <  pio_min_disp -> clipped to 0xFF
//   disp >  pio_max_disp -> clipped to 0x00
//
// pixel = 255 - (disp - min) * 255 / (max - min)
//
// The 16-by-8 unsigned divide sits in the combinational path from
// mbi_disp_value into bus_write_data. At 100 MHz on Cyclone V it should
// fit, but if the timing analyzer flags it later, register disp_pixel_color
// (and pipeline mbi_disp_valid / mbi_disp_x / mbi_disp_y by the same number
// of cycles) before the PHASE_COMPUTE state machine consumes it.
wire [6:0] disp_min7  = pio_min_disp_value[6:0];
wire [6:0] disp_max7  = pio_max_disp_value[6:0];
wire [7:0] disp_range = (disp_max7 > disp_min7) ?
	({1'b0, disp_max7} - {1'b0, disp_min7}) : 8'd1;          // /0 guard
wire [7:0] disp_offset = (mbi_disp_value > disp_min7) ?
	({1'b0, mbi_disp_value} - {1'b0, disp_min7}) : 8'd0;
wire [15:0] disp_scaled = disp_offset * 8'd255;
wire [7:0]  disp_grad   = disp_scaled / disp_range;

wire [7:0] disp_pixel_color =
	(mbi_disp_value <= disp_min7) ? 8'h00 :
	(mbi_disp_value >= disp_max7) ? 8'hFF :
	(disp_grad);

// VGA address for streaming disparity: place right below raw video (row 200+)
wire [9:0] disp_vga_y = mbi_disp_y + FRAME_HEIGHT;
wire [31:0] disp_stream_vga_addr = vga_out_base_address +
	{22'b0, mbi_disp_x} + ({22'b0, disp_vga_y} << 10);

// Debug HEX assembly. Field layout documented above the HexDigit instances.
// Verilog continuous-assigns can forward-reference wires, so the signals
// declared further down (mux_bus_*, stereo_active, fp_*_dbg, bus_grant)
// resolve fine at elaboration.
assign hex_word = {
    /* HEX5 */ 3'b000, top_phase[0],
    /* HEX4 */ state,
    /* HEX3 */ 1'b0, fp_bus_state_dbg,
    /* HEX2 */ stereo_active, bus_grant, mux_bus_read, mux_bus_write,
    /* HEX1 */ fp_ack_wait_dbg[7:4],
    /* HEX0 */ fp_ack_wait_dbg[3:0]
};

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

// SW[4] = stereo enable (raw, asynchronously toggled by user).
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
wire                          fp_bram_wr_en;
wire [STRIPE_W-1:0]           fp_bram_wr_stripe;
wire [ROW_IN_STRIPE_W-1:0]    fp_bram_wr_row_in_stripe;
wire [BRAM_COL_W-1:0]         fp_bram_wr_col;
wire [7:0]                    fp_bram_wr_data;
wire [2:0]                    fp_bus_state_dbg;
wire [7:0]                    fp_ack_wait_dbg;

// stereo_active is the LATCHED version of stereo_enabled. The bus mux
// (pipe_active below) keys off this, NOT stereo_enabled directly: SW[4]
// toggling combinationally tore the EBAB transactions in half (legacy
// FSM mid-read, mux flips, fp_bus_read = 0 dropped read on the wire,
// EBAB stranded an outstanding response, design wedged until reflash).
//
// Update only when both controllers are fully quiet on the shared bus and
// BRAM. While the toggling side has an in-flight transaction, stereo_active
// stays put -- the in-flight FSM drains naturally before ownership flips.
reg stereo_active;
wire stereo_safe = (state == 4'd0)
                && !bus_read    && !bus_write    && !bram_wr_en
                && !fp_bus_read && !fp_bus_write && !fp_bram_wr_en;

always @(posedge CLOCK2_50 or negedge KEY[0]) begin
    if (!KEY[0])         stereo_active <= 1'b0;
    else if (stereo_safe) stereo_active <= stereo_enabled;
end

// pipe_active gates whose signals reach the EBAB / BRAM. While pipe_active is
// true (PHASE_FILL with stereo on), the legacy bus_*/bram_wr_* registers are
// kept off the wires. fp_go is purely combinational from this gate plus SW[0],
// minus the one cycle that fp_done is asserted -- otherwise the controller
// would race-restart between done and the phase transition.
wire pipe_active = (top_phase == PHASE_FILL) && stereo_active;
wire fp_go       = pipe_active && sw0_sync && !fp_done;

// Bus-issue throttle, identical to the legacy PHASE_FILL gate. Without this
// the EBAB / VGA pixel buffer falls behind: removing the timer historically
// caused the VGA display to stop updating entirely. The pipelined mapper
// inside fill_pipe still runs at 1 px/cycle into its FIFO; only new bus
// transactions (camera read or VGA write) are issued at the throttled rate.
// PHASE_COMPUTE's disparity-write start uses the same gate -- previously
// it was implicitly throttled by SAD compute time, but bursts of 24 emits
// per column went out back-to-back which can over-feed the bridge.
wire bus_grant = ((timer & 32'd5) == 32'd0);

// Muxed bus signals -- these are what actually go to the EBAB master.
wire [31:0] mux_bus_addr        = pipe_active ? fp_bus_addr        : bus_addr;
wire        mux_bus_read        = pipe_active ? fp_bus_read        : bus_read;
wire [3:0]  mux_bus_byte_enable = pipe_active ? fp_bus_byte_enable : bus_byte_enable;
wire        mux_bus_write       = pipe_active ? fp_bus_write       : bus_write;
wire [31:0] mux_bus_write_data  = pipe_active ? fp_bus_write_data  : bus_write_data;

// Muxed BRAM write signals -- what actually goes to stereo_bram.
wire                          mux_bram_wr_en             = pipe_active ? fp_bram_wr_en             : bram_wr_en;
wire [STRIPE_W-1:0]           mux_bram_wr_stripe         = pipe_active ? fp_bram_wr_stripe         : bram_wr_stripe;
wire [ROW_IN_STRIPE_W-1:0]    mux_bram_wr_row_in_stripe  = pipe_active ? fp_bram_wr_row_in_stripe  : bram_wr_row_in_stripe;
wire [BRAM_COL_W-1:0]         mux_bram_wr_col            = pipe_active ? fp_bram_wr_col            : bram_wr_col;
wire [7:0]                    mux_bram_wr_data           = pipe_active ? fp_bram_wr_data           : bram_wr_data;

fill_pipe_controller #(
    .FULL_FRAME_WIDTH    (FULL_FRAME_WIDTH),
    .FRAME_HEIGHT        (FRAME_HEIGHT),
    .FULL_ROW_WIDTH      (FULL_ROW_WIDTH),
    .Y_CROP_OFFSET       (Y_CROP_OFFSET),
    .HALF_FRAME_WIDTH    (HALF_FRAME_WIDTH),
    .LEFT_LUT_WIDTH      (LEFT_LUT_WIDTH),
    .INTER_CAMERA_GAP    (INTER_CAMERA_GAP),
    .RIGHT_OUTPUT_X_START(RIGHT_OUTPUT_X_START),
    .STRIPE_HEIGHT       (STRIPE_HEIGHT),
    .NUM_STRIPES         (NUM_STRIPES),
    .MAPPER_LATENCY      (11)
) u_fill_pipe (
    .clk                   (CLOCK2_50),
    // Held in reset whenever stereo_active = 0 so the controller can't be
    // partway through an FSM transition when the bus mux switches owners.
    // Combined with stereo_active's safe-update gating this guarantees fp_*
    // outputs are 0 in any cycle the legacy FSM owns the bus.
    .reset_n               (KEY[0] && stereo_active),
    .go                    (fp_go),
    .bus_grant             (bus_grant),

    .bus_addr              (fp_bus_addr),
    .bus_read              (fp_bus_read),
    .bus_write             (fp_bus_write),
    .bus_byte_enable       (fp_bus_byte_enable),
    .bus_write_data        (fp_bus_write_data),
    .bus_read_data         (bus_read_data),
    .bus_ack               (bus_ack),

    .bram_wr_en            (fp_bram_wr_en),
    .bram_wr_stripe        (fp_bram_wr_stripe),
    .bram_wr_row_in_stripe (fp_bram_wr_row_in_stripe),
    .bram_wr_col           (fp_bram_wr_col),
    .bram_wr_data          (fp_bram_wr_data),

    .done                  (fp_done),
    .bus_state_dbg         (fp_bus_state_dbg),
    .ack_wait_dbg          (fp_ack_wait_dbg)
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
		// Start in PHASE_WAIT so the DMA has time to lay down a complete
		// frame before the first FILL reads source pixels. Starting in FILL
		// would mean reading whatever uninitialized M10K contents power up.
		top_phase <= PHASE_WAIT;
		wait_start_timer <= 32'd0;
		mbi_go <= 0; mbi_rst <= 1;
		frame_filled <= 0;
		current_pixel_color1 <= 0;
		mbi_disp_ack <= 0;
		cur_write_slot <= 4'd0;
		drain_y <= 10'd0;
		drain_byte <= 10'd0;
		drain_slot <= 4'd0;
	end
	else begin
		timer <= timer + 1;
		read_video_start <= 1'b0;
		mbi_go <= 1'b0;
		mbi_disp_ack <= 1'b0;

		case (top_phase)

		// ============ PHASE_FILL ============
		PHASE_FILL: begin
			mbi_rst <= 1'b1;

			if (state==0 && SW[0] && (timer & 5) == 0) begin
				state <= 4'd11;
				map_enable_latched <= SW[3];
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
				// Stereo data is already in Onchip_SRAM (written there directly
				// by the Video-In DMA). The SAD engine reads it through the
				// sad_port conduit, so we no longer copy into stereo_bram_bank.
				// We still write each pixel to the VGA buffer for live display.
				state <= 4'd9;
				bus_write <= 1'b1;
				bus_addr <= vga_bus_addr;
				bus_write_data <= current_pixel_color1;
				bus_byte_enable <= 4'b0001;
			end

			if (state==4'd9 && bus_ack) begin
				bus_write <= 1'b0;
				if (old_video_in_x_cood == (FULL_FRAME_WIDTH-1)) begin
					// End of a destination row. Advance the ring write slot
					// for the next row and remember whether the frame just
					// finished (last drain triggers the PHASE_DRAIN tail).
					cur_write_slot <= (cur_write_slot == RING_DEPTH-1) ? 4'd0
					                                                   : cur_write_slot + 4'd1;
					if (old_video_in_y_cood == (FRAME_HEIGHT-1)) begin
						frame_filled <= 1'b1;
					end
					// Mid-frame drain: row (old_y - K) has now had K rows of
					// destinations produced after it, so its raw data is no
					// longer needed by anyone — safe to commit the staged
					// undistorted version back into stereo_onchip_ram.
					if (old_video_in_y_cood >= DRAIN_K) begin
						drain_byte <= 10'd0;
						state <= 4'd2;
					end else begin
						state <= 4'd0;
					end
				end else begin
					state <= 4'd0;
				end
			end

			// ---- Drain mini-FSM (states 2/3/4) -----------------------------
			// Pumps one staged row out of the ring buffer back into the main
			// SRAM via Avalon writes. Shared across PHASE_FILL (mid-frame
			// drains) and PHASE_DRAIN (tail drains). One byte per iteration
			// because the EBAB master is 8-bit; bus_write_data and
			// bus_byte_enable are sized for a hypothetical 32-bit master but
			// only their low byte / low bit actually reach the slave.
			if (state == 4'd2) begin
				// Setup. ring_rd_data will be valid one cycle later because
				// the ring is M10K-backed (1-cycle read latency).
				bus_addr <= drain_bus_addr;
				bus_byte_enable <= 4'b0001;
				state <= 4'd3;
			end
			if (state == 4'd3) begin
				bus_write <= 1'b1;
				// Pick the byte at lane drain_byte[1:0] from the 32-bit ring
				// word. The ring stores bytes packed by lane = byte_col[1:0],
				// so this lines up the byte we just produced in FILL with
				// the SRAM byte column drain_bus_addr targets.
				case (drain_byte[1:0])
					2'd0:    bus_write_data <= {24'b0, ring_rd_data[ 7: 0]};
					2'd1:    bus_write_data <= {24'b0, ring_rd_data[15: 8]};
					2'd2:    bus_write_data <= {24'b0, ring_rd_data[23:16]};
					default: bus_write_data <= {24'b0, ring_rd_data[31:24]};
				endcase
				state <= 4'd4;
			end
			if (state == 4'd4 && bus_ack) begin
				bus_write <= 1'b0;
				if (drain_byte == FULL_FRAME_WIDTH - 1) begin
					// Row drain complete. Advance to next row.
					drain_y    <= drain_y + 10'd1;
					drain_slot <= (drain_slot == RING_DEPTH-1) ? 4'd0
					                                           : drain_slot + 4'd1;
					if (frame_filled && top_phase == PHASE_FILL) begin
						// Last mid-frame drain just finished; switch into
						// the tail-drain phase to flush the K rows still
						// in the ring.
						top_phase <= PHASE_DRAIN;
					end
					state <= 4'd0;
				end else begin
					drain_byte <= drain_byte + 10'd1;
					state      <= 4'd2;
				end
			end
		end

		// ============ PHASE_DRAIN ============
		// Flushes the trailing K rows that were still in the ring buffer
		// when PHASE_FILL finished. Drives the same drain mini-FSM (states
		// 2/3/4) one row at a time until drain_y reaches FRAME_HEIGHT.
		PHASE_DRAIN: begin
			mbi_rst <= 1'b1;
			if (state == 4'd0) begin
				if (drain_y >= FRAME_HEIGHT) begin
					// All rows committed.
					if (stereo_enabled) begin
						top_phase <= PHASE_COMPUTE;
					end else begin
						// Skip COMPUTE; go straight to WAIT so the DMA can
						// refresh the SRAM with a fresh frame before the
						// next FILL reads source pixels. (Returning straight
						// to PHASE_FILL would re-read previously-drained,
						// already-rectified bytes and rectify them again.)
						top_phase        <= PHASE_WAIT;
						wait_start_timer <= timer;
						frame_filled     <= 1'b0;
						drain_y          <= 10'd0;
						drain_slot       <= 4'd0;
						cur_write_slot   <= 4'd0;
					end
				end else begin
					drain_byte <= 10'd0;
					state      <= 4'd2;
				end
			end

			// Same drain mini-FSM body as in PHASE_FILL.
			if (state == 4'd2) begin
				bus_addr <= drain_bus_addr;
				bus_byte_enable <= 4'b0001;
				state <= 4'd3;
			end
			if (state == 4'd3) begin
				bus_write <= 1'b1;
				case (drain_byte[1:0])
					2'd0:    bus_write_data <= {24'b0, ring_rd_data[ 7: 0]};
					2'd1:    bus_write_data <= {24'b0, ring_rd_data[15: 8]};
					2'd2:    bus_write_data <= {24'b0, ring_rd_data[23:16]};
					default: bus_write_data <= {24'b0, ring_rd_data[31:24]};
				endcase
				state <= 4'd4;
			end
			if (state == 4'd4 && bus_ack) begin
				bus_write <= 1'b0;
				if (drain_byte == FULL_FRAME_WIDTH - 1) begin
					drain_y    <= drain_y + 10'd1;
					drain_slot <= (drain_slot == RING_DEPTH-1) ? 4'd0
					                                           : drain_slot + 4'd1;
					state <= 4'd0;
				end else begin
					drain_byte <= drain_byte + 10'd1;
					state      <= 4'd2;
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

			// Handle streaming disparity output. Same bus_grant throttle as
			// PHASE_FILL: a column's worth of emits arrives in a back-to-back
			// burst from mem_block_intf, and the EBAB clock-bridge can't keep
			// up at full rate. We let mem_block_intf wait by holding off the
			// disp_ack chain (state stays at 1 until bus_grant goes high).
			if (mbi_disp_valid && state != 4'd13 && state != 4'd14 && bus_grant) begin
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

			// Done with entire computation. Route through PHASE_WAIT so the
			// DMA gets a refresh window before the next FILL.
			if (mbi_done) begin
				top_phase        <= PHASE_WAIT;
				wait_start_timer <= timer;
				state            <= 4'd0;
				frame_filled     <= 0;
				drain_y          <= 10'd0;
				drain_slot       <= 4'd0;
				cur_write_slot   <= 4'd0;
			end
		end

		// ============ PHASE_WAIT ============
		// Lock is released here (sram_s1_write_lock_next gates on this), so
		// the autonomous Video-In DMA writes a fresh frame into Onchip_SRAM.
		// We simply count cycles until at least one full PAL frame has been
		// written, then return to FILL with the lock asserted again.
		PHASE_WAIT: begin
			mbi_rst <= 1'b1;
			if ((timer - wait_start_timer) >= WAIT_CYCLES) begin
				top_phase <= PHASE_FILL;
			end
		end

		default: top_phase <= PHASE_WAIT;
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
	
	// Onchip_SRAM SAD parallel-read conduit (port B of every row's M10K).
	// Exported by Qsys as onchip_sram_1_sad_port_{re,col,rdata}; sad_rdata
	// is a flat 1600-bit bus (200 rows * 8 bits) consumed by
	// column_prefetch_parallel which unflattens it row-by-row.
	.onchip_sram_1_sad_port_re    (sad_re),
	.onchip_sram_1_sad_port_col   (sad_col),
	.onchip_sram_1_sad_port_rdata (sad_rdata_flat),

	// s1 write-lock conduit. Held high during PHASE_DRAIN + PHASE_COMPUTE
	// so the autonomous Video_In_DMA can't overwrite the undistorted SRAM
	// contents before SAD reads them. Released during PHASE_FILL so the
	// DMA refreshes the raw frame normally.
	.onchip_sram_s1_lock_lock     (sram_s1_write_lock),

	//PIO out
	.pio_test_test_export(32'd5),

	// SGM penalty PIOs (HPS -> FPGA, 32-bit each)
	.pio_small_pen_external_connection_export (pio_small_pen_value),
	.pio_big_pen_external_connection_export   (pio_big_pen_value),

	// Disparity-range PIOs (HPS -> FPGA, 32-bit each)
	.pio_min_disp_external_connection_export  (pio_min_disp_value),
	.pio_max_disp_external_connection_export  (pio_max_disp_value),

	.ebab_video_in_external_interface_address     (bus_addr),     // 
	.ebab_video_in_external_interface_byte_enable (bus_byte_enable), //  .byte_enable
	.ebab_video_in_external_interface_read        (bus_read),        //  .read
	.ebab_video_in_external_interface_write       (bus_write),       //  .write
	.ebab_video_in_external_interface_write_data  (bus_write_data),  //.write_data
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
