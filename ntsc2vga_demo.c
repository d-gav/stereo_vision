///////////////////////////////////////
/// 640x480 version!
/// test VGA with hardware video input copy to VGA
///////////////////////////////////////
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdint.h>
#include <time.h>
#include <termios.h>
#include <sys/types.h>
#include <sys/ipc.h> 
#include <sys/shm.h> 
#include <sys/mman.h>
#include <sys/time.h> 
#include "address_map_arm_brl4.h"


/* function prototypes */
void VGA_text (int, int, char *);
void VGA_text_clear();
void VGA_box (int, int, int, int, short);
void VGA_line(int, int, int, int, short) ;
void VGA_disc (int, int, int, short);
int  VGA_read_pixel(int, int) ;
int  video_in_read_pixel(int, int);
void draw_delay(void) ;
int  save_vga_png(const char *filename);


// the light weight buss base
void *h2p_lw_virtual_base;
volatile unsigned int *h2p_lw_video_in_control_addr=NULL;
volatile unsigned int *h2p_lw_video_in_resolution_addr=NULL;
//volatile unsigned int *h2p_lw_video_in_control_addr=NULL;
//volatile unsigned int *h2p_lw_video_in_control_addr=NULL;

volatile unsigned int *h2p_lw_video_edge_control_addr=NULL;
volatile unsigned int *h2p_lw_test_pio=NULL;

// pixel buffer
volatile unsigned int * vga_pixel_ptr = NULL ;
void *vga_pixel_virtual_base;

// video input buffer
volatile unsigned int * video_in_ptr = NULL ;
void *video_in_virtual_base;

// character buffer
volatile unsigned int * vga_char_ptr = NULL ;
void *vga_char_virtual_base;

// /dev/mem file id
int fd;

// shared memory 
key_t mem_key=0xf0;
int shared_mem_id; 
int *shared_ptr;
int shared_time;
int shared_note;
char shared_str[64];

// pixel macro
#define VGA_PIXEL(x,y,color) do{\
	char  *pixel_ptr ;\
	pixel_ptr = (char *)vga_pixel_ptr + ((y)<<10) + (x) ;\
	*(char *)pixel_ptr = (color);\
} while(0)
	
#define VIDEO_IN_PIXEL(x,y,color) do{\
	char  *pixel_ptr ;\
	// X-Y mode stride for width 640 is 1024 bytes per row.\
	pixel_ptr = (char *)video_in_ptr + ((y) * VIDEO_IN_XY_STRIDE) + (x) ;\
	*(char *)pixel_ptr = (color);\
} while(0)
	

// measure time
struct timeval t1, t2;
double elapsedTime;
struct timespec delay_time ;

#define VGA_WIDTH 640
#define VGA_HEIGHT 480

// Video-In DMA uses X-Y addressing mode in this design.
#define VIDEO_IN_WIDTH 640U
#define VIDEO_IN_HEIGHT 288U
#define VIDEO_IN_XY_STRIDE 1024U
#define VIDEO_IN_REQUIRED_SPAN (VIDEO_IN_XY_STRIDE * VIDEO_IN_HEIGHT)
#define VIDEO_IN_MAP_SPAN ((FPGA_ONCHIP_SPAN > VIDEO_IN_REQUIRED_SPAN) ? FPGA_ONCHIP_SPAN : VIDEO_IN_REQUIRED_SPAN)

static unsigned int crc32_table[256];
static int crc32_table_initialized = 0;

static void init_crc32_table(void)
{
	unsigned int i, j, c;
	for (i = 0; i < 256; i++) {
		c = i;
		for (j = 0; j < 8; j++) {
			if (c & 1U) {
				c = 0xEDB88320U ^ (c >> 1);
			} else {
				c >>= 1;
			}
		}
		crc32_table[i] = c;
	}
	crc32_table_initialized = 1;
}

static unsigned int crc32_update(unsigned int crc, const unsigned char *data, size_t len)
{
	size_t i;
	if (!crc32_table_initialized) {
		init_crc32_table();
	}
	for (i = 0; i < len; i++) {
		crc = crc32_table[(crc ^ data[i]) & 0xFFU] ^ (crc >> 8);
	}
	return crc;
}

static unsigned int adler32_calc(const unsigned char *data, size_t len)
{
	const unsigned int mod_adler = 65521U;
	unsigned int a = 1;
	unsigned int b = 0;
	size_t i;

	for (i = 0; i < len; i++) {
		a = (a + data[i]) % mod_adler;
		b = (b + a) % mod_adler;
	}

	return (b << 16) | a;
}

static int write_be32(FILE *fp, unsigned int value)
{
	unsigned char bytes[4];
	bytes[0] = (unsigned char)((value >> 24) & 0xFFU);
	bytes[1] = (unsigned char)((value >> 16) & 0xFFU);
	bytes[2] = (unsigned char)((value >> 8) & 0xFFU);
	bytes[3] = (unsigned char)(value & 0xFFU);
	return (fwrite(bytes, 1, 4, fp) == 4) ? 0 : -1;
}

static int write_png_chunk(FILE *fp, const char type[4], const unsigned char *data, size_t len)
{
	unsigned int crc = 0xFFFFFFFFU;

	if (write_be32(fp, (unsigned int)len) != 0) {
		return -1;
	}

	if (fwrite(type, 1, 4, fp) != 4) {
		return -1;
	}

	if (len > 0 && fwrite(data, 1, len, fp) != len) {
		return -1;
	}

	crc = crc32_update(crc, (const unsigned char *)type, 4);
	if (len > 0) {
		crc = crc32_update(crc, data, len);
	}
	crc ^= 0xFFFFFFFFU;

	return write_be32(fp, crc);
}

static void build_capture_filename(char *filename, size_t filename_size)
{
	time_t now;
	struct tm *now_tm;
	char timestamp[32];
	static unsigned int capture_count = 0;

	now = time(NULL);
	now_tm = localtime(&now);
	if (now_tm != NULL && strftime(timestamp, sizeof(timestamp), "%Y%m%d_%H%M%S", now_tm) > 0) {
		snprintf(filename, filename_size, "vga_capture_%s_%03u.png", timestamp, capture_count);
	} else {
		snprintf(filename, filename_size, "vga_capture_%03u.png", capture_count);
	}
	capture_count++;
}

static int configure_terminal_raw(struct termios *saved_terminal)
{
	struct termios raw_terminal;

	if (tcgetattr(STDIN_FILENO, saved_terminal) != 0) {
		return -1;
	}

	raw_terminal = *saved_terminal;
	raw_terminal.c_lflag &= (tcflag_t)~(ICANON | ECHO);
	raw_terminal.c_cc[VMIN] = 0;
	raw_terminal.c_cc[VTIME] = 0;

	return tcsetattr(STDIN_FILENO, TCSANOW, &raw_terminal);
}

static void restore_terminal(const struct termios *saved_terminal)
{
	tcsetattr(STDIN_FILENO, TCSANOW, saved_terminal);
}
	
int main(void)
{
	delay_time.tv_nsec = 10 ;
	delay_time.tv_sec = 0 ;
	char key;
	ssize_t bytes_read;
	char png_filename[128];
	struct termios saved_terminal;
	int raw_terminal_enabled = 0;
	unsigned int video_in_resolution;

	// Declare volatile pointers to I/O registers (volatile 	// means that IO load and store instructions will be used 	// to access these pointer locations, 
	// instead of regular memory loads and stores) 
  	
	// === need to mmap: =======================
	// FPGA_CHAR_BASE
	// FPGA_ONCHIP_BASE      
	// HW_REGS_BASE        
  
	// === get FPGA addresses ==================
    // Open /dev/mem
	if( ( fd = open( "/dev/mem", ( O_RDWR | O_SYNC ) ) ) == -1 ) 	{
		printf( "ERROR: could not open \"/dev/mem\"...\n" );
		return( 1 );
	}
    
    // get virtual addr that maps to physical
	h2p_lw_virtual_base = mmap( NULL, HW_REGS_SPAN, ( PROT_READ | PROT_WRITE ), MAP_SHARED, fd, HW_REGS_BASE );	
	if( h2p_lw_virtual_base == MAP_FAILED ) {
		printf( "ERROR: mmap1() failed...\n" );
		close( fd );
		return(1);
	}
	h2p_lw_test_pio=(volatile unsigned int *)(h2p_lw_virtual_base+VIDEO_IN_BASE+0x0);
    h2p_lw_video_in_control_addr=(volatile unsigned int *)(h2p_lw_virtual_base+VIDEO_IN_BASE+0x0c);
	h2p_lw_video_in_resolution_addr=(volatile unsigned int *)(h2p_lw_virtual_base+VIDEO_IN_BASE+0x08);
	*(h2p_lw_video_in_control_addr) = 0x04 ; // turn on video capture
	// Resolution is read-only in this DMA core; read it back for diagnostics.
	video_in_resolution = *(h2p_lw_video_in_resolution_addr);
	printf("Video-In DMA resolution (RO): 0x%08X (Y=%u, X=%u)\n",
		video_in_resolution,
		(video_in_resolution >> 16) & 0xFFFFU,
		video_in_resolution & 0xFFFFU);
	if (FPGA_ONCHIP_SPAN < VIDEO_IN_REQUIRED_SPAN) {
		printf("Video-In mmap span expanded to %u bytes (header span %u).\n",
			(unsigned int)VIDEO_IN_MAP_SPAN,
			(unsigned int)FPGA_ONCHIP_SPAN);
	}
	h2p_lw_video_edge_control_addr=(volatile unsigned int *)(h2p_lw_virtual_base+VIDEO_IN_BASE+0x10);
	*h2p_lw_video_edge_control_addr = 0x01 ; // 1 means edges
	*h2p_lw_video_edge_control_addr = 0x00 ; // 1 means edges
	
	// === get VGA char addr =====================
	// get virtual addr that maps to physical
	vga_char_virtual_base = mmap( NULL, FPGA_CHAR_SPAN, ( PROT_READ | PROT_WRITE ), MAP_SHARED, fd, FPGA_CHAR_BASE );	
	if( vga_char_virtual_base == MAP_FAILED ) {
		printf( "ERROR: mmap2() failed...\n" );
		close( fd );
		return(1);
	}
    
    // Get the address that maps to the character 
	vga_char_ptr =(unsigned int *)(vga_char_virtual_base);

	// === get VGA pixel addr ====================
	// get virtual addr that maps to physical
	// SDRAM
	vga_pixel_virtual_base = mmap( NULL, FPGA_ONCHIP_SPAN, ( PROT_READ | PROT_WRITE ), MAP_SHARED, fd, SDRAM_BASE); //SDRAM_BASE	
	
	if( vga_pixel_virtual_base == MAP_FAILED ) {
		printf( "ERROR: mmap3() failed...\n" );
		close( fd );
		return(1);
	}
    // Get the address that maps to the FPGA pixel buffer
	vga_pixel_ptr =(unsigned int *)(vga_pixel_virtual_base);
	
	
	// === get video input =======================
	// on-chip RAM
		video_in_virtual_base = mmap( NULL, VIDEO_IN_MAP_SPAN, ( PROT_READ | PROT_WRITE ), MAP_SHARED, fd, FPGA_ONCHIP_BASE); 
	if( video_in_virtual_base == MAP_FAILED ) {
		printf( "ERROR: mmap3() failed...\n" );
		close( fd );
		return(1);
	}
	// format the pointer
	video_in_ptr =(unsigned int *)(video_in_virtual_base);
	
	// ===========================================

	// start timer
    //gettimeofday(&t1, NULL);

	printf("Press C to capture the VGA screen to a PNG file. Press Q to quit.\n");

	if (configure_terminal_raw(&saved_terminal) == 0) {
		raw_terminal_enabled = 1;
	} else {
		printf("Warning: raw terminal mode unavailable, input may require Enter.\n");
	}

	printf("value read from h2p lw bus: %d", *h2p_lw_test_pio); 

	while (1) {
		bytes_read = read(STDIN_FILENO, &key, 1);
		if (bytes_read == 1) {
			if (key == 'c' || key == 'C') {
				build_capture_filename(png_filename, sizeof(png_filename));
				if (save_vga_png(png_filename) == 0) {
					printf("Saved VGA snapshot to %s\n", png_filename);
				} else {
					printf("Failed to save VGA snapshot to %s\n", png_filename);
				}
			} else if (key == 'q' || key == 'Q') {
				break;
			}
		} else if (bytes_read < 0 && errno != EAGAIN && errno != EINTR) {
			printf("Read error on stdin\n");
			break;
		}

		usleep(10000);
	}

	if (raw_terminal_enabled) {
		restore_terminal(&saved_terminal);
	}

	if (video_in_virtual_base != NULL && video_in_virtual_base != MAP_FAILED) {
		munmap(video_in_virtual_base, VIDEO_IN_MAP_SPAN);
	}
	if (vga_pixel_virtual_base != NULL && vga_pixel_virtual_base != MAP_FAILED) {
		munmap(vga_pixel_virtual_base, FPGA_ONCHIP_SPAN);
	}
	if (vga_char_virtual_base != NULL && vga_char_virtual_base != MAP_FAILED) {
		munmap(vga_char_virtual_base, FPGA_CHAR_SPAN);
	}
	if (h2p_lw_virtual_base != NULL && h2p_lw_virtual_base != MAP_FAILED) {
		munmap(h2p_lw_virtual_base, HW_REGS_SPAN);
	}
	close(fd);
	return 0;
	
} // end main

int save_vga_png(const char *filename)
{
    FILE *fp;
    unsigned char png_signature[8] = {137, 80, 78, 71, 13, 10, 26, 10};
    unsigned char ihdr[13];
    unsigned char *raw = NULL;
    unsigned char *idat = NULL;
    unsigned int adler;
    size_t raw_size;
    size_t raw_pos;
    size_t idat_size;
    size_t idat_pos;
    size_t remaining;
    size_t max_blocks;
    int x, y;

    /* CHANGE 1: Calculate raw size for 1 byte per pixel instead of 3 */
    raw_size = (size_t)VGA_HEIGHT * (1 + (size_t)VGA_WIDTH);
    max_blocks = (raw_size + 65534U) / 65535U;
    idat_size = 2 + raw_size + (max_blocks * 5U) + 4;

    raw = (unsigned char *)malloc(raw_size);
    idat = (unsigned char *)malloc(idat_size);
    if (raw == NULL || idat == NULL) {
        free(raw);
        free(idat);
        return -1;
    }

    for (y = 0; y < VGA_HEIGHT; y++) {
        /* CHANGE 2: Scanline width is now just 1 + VGA_WIDTH */
        size_t row_start = (size_t)y * (1 + (size_t)VGA_WIDTH);
        raw[row_start] = 0; /* No filter for this row */
        
        for (x = 0; x < VGA_WIDTH; x++) {
            /* CHANGE 3: Read the 8-bit grayscale value and write it directly */
            unsigned char pix = (unsigned char)(VGA_read_pixel(x, y) & 0xFF);
            size_t out = row_start + 1 + (size_t)x;
            raw[out] = pix; 
        }
    }

    idat_pos = 0;
    idat[idat_pos++] = 0x78;
    idat[idat_pos++] = 0x01;

    raw_pos = 0;
    remaining = raw_size;
    while (remaining > 0) {
        unsigned int block_len = (remaining > 65535U) ? 65535U : (unsigned int)remaining;
        unsigned int nlen = 0xFFFFU - block_len;
        idat[idat_pos++] = (remaining > 65535U) ? 0x00 : 0x01;
        idat[idat_pos++] = (unsigned char)(block_len & 0xFFU);
        idat[idat_pos++] = (unsigned char)((block_len >> 8) & 0xFFU);
        idat[idat_pos++] = (unsigned char)(nlen & 0xFFU);
        idat[idat_pos++] = (unsigned char)((nlen >> 8) & 0xFFU);
        memcpy(idat + idat_pos, raw + raw_pos, block_len);
        idat_pos += block_len;
        raw_pos += block_len;
        remaining -= block_len;
    }

    adler = adler32_calc(raw, raw_size);
    idat[idat_pos++] = (unsigned char)((adler >> 24) & 0xFFU);
    idat[idat_pos++] = (unsigned char)((adler >> 16) & 0xFFU);
    idat[idat_pos++] = (unsigned char)((adler >> 8) & 0xFFU);
    idat[idat_pos++] = (unsigned char)(adler & 0xFFU);

    fp = fopen(filename, "wb");
    if (fp == NULL) {
        free(raw);
        free(idat);
        return -1;
    }

    if (fwrite(png_signature, 1, sizeof(png_signature), fp) != sizeof(png_signature)) {
        fclose(fp);
        free(raw);
        free(idat);
        return -1;
    }

    ihdr[0] = (unsigned char)((VGA_WIDTH >> 24) & 0xFFU);
    ihdr[1] = (unsigned char)((VGA_WIDTH >> 16) & 0xFFU);
    ihdr[2] = (unsigned char)((VGA_WIDTH >> 8) & 0xFFU);
    ihdr[3] = (unsigned char)(VGA_WIDTH & 0xFFU);
    ihdr[4] = (unsigned char)((VGA_HEIGHT >> 24) & 0xFFU);
    ihdr[5] = (unsigned char)((VGA_HEIGHT >> 16) & 0xFFU);
    ihdr[6] = (unsigned char)((VGA_HEIGHT >> 8) & 0xFFU);
    ihdr[7] = (unsigned char)(VGA_HEIGHT & 0xFFU);
    ihdr[8] = 8; /* Bit depth: 8 bits per channel/pixel */
    
    /* CHANGE 4: Color Type 0 = Grayscale (was 2 for Truecolor) */
    ihdr[9] = 0; 
    
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;

    if (write_png_chunk(fp, "IHDR", ihdr, sizeof(ihdr)) != 0 ||
        write_png_chunk(fp, "IDAT", idat, idat_pos) != 0 ||
        write_png_chunk(fp, "IEND", NULL, 0) != 0) {
        fclose(fp);
        free(raw);
        free(idat);
        return -1;
    }

    fclose(fp);
    free(raw);
    free(idat);
    return 0;
}

/****************************************************************************************
 * Subroutine to read a pixel from the video input 
****************************************************************************************/
int  video_in_read_pixel(int x, int y){
	char  *pixel_ptr ;
	// X-Y mode stride for width 640 is 1024 bytes per row.
	pixel_ptr = (char *)video_in_ptr + (y * VIDEO_IN_XY_STRIDE) + x ;
	return *pixel_ptr ;
}

/****************************************************************************************
 * Subroutine to read a pixel from the VGA monitor 
****************************************************************************************/
int  VGA_read_pixel(int x, int y){
	char  *pixel_ptr ;
	pixel_ptr = (char *)vga_pixel_ptr + ((y)<<10) + (x) ;
	return *pixel_ptr ;
}

/****************************************************************************************
 * Subroutine to send a string of text to the VGA monitor 
****************************************************************************************/
void VGA_text(int x, int y, char * text_ptr)
{
  	volatile char * character_buffer = (char *) vga_char_ptr ;	// VGA character buffer
	int offset;
	/* assume that the text string fits on one line */
	offset = (y << 7) + x;
	while ( *(text_ptr) )
	{
		// write to the character buffer
		*(character_buffer + offset) = *(text_ptr);	
		++text_ptr;
		++offset;
	}
}

/****************************************************************************************
 * Subroutine to clear text to the VGA monitor 
****************************************************************************************/
void VGA_text_clear()
{
  	volatile char * character_buffer = (char *) vga_char_ptr ;	// VGA character buffer
	int offset, x, y;
	for (x=0; x<79; x++){
		for (y=0; y<59; y++){
	/* assume that the text string fits on one line */
			offset = (y << 7) + x;
			// write to the character buffer
			*(character_buffer + offset) = ' ';		
		}
	}
}

/****************************************************************************************
 * Draw a filled rectangle on the VGA monitor 
****************************************************************************************/
#define SWAP(X,Y) do{int temp=X; X=Y; Y=temp;}while(0) 

void VGA_box(int x1, int y1, int x2, int y2, short pixel_color)
{
	char  *pixel_ptr ; 
	int row, col;

	/* check and fix box coordinates to be valid */
	if (x1>639) x1 = 639;
	if (y1>479) y1 = 479;
	if (x2>639) x2 = 639;
	if (y2>479) y2 = 479;
	if (x1<0) x1 = 0;
	if (y1<0) y1 = 0;
	if (x2<0) x2 = 0;
	if (y2<0) y2 = 0;
	if (x1>x2) SWAP(x1,x2);
	if (y1>y2) SWAP(y1,y2);
	for (row = y1; row <= y2; row++)
		for (col = x1; col <= x2; ++col)
		{
			//640x480
			pixel_ptr = (char *)vga_pixel_ptr + (row<<10)    + col ;
			// set pixel color
			*(char *)pixel_ptr = pixel_color;		
		}
}

/****************************************************************************************
 * Draw a filled circle on the VGA monitor 
****************************************************************************************/

void VGA_disc(int x, int y, int r, short pixel_color)
{
	char  *pixel_ptr ; 
	int row, col, rsqr, xc, yc;
	
	rsqr = r*r;
	
	for (yc = -r; yc <= r; yc++)
		for (xc = -r; xc <= r; xc++)
		{
			col = xc;
			row = yc;
			// add the r to make the edge smoother
			if(col*col+row*row <= rsqr+r){
				col += x; // add the center point
				row += y; // add the center point
				//check for valid 640x480
				if (col>639) col = 639;
				if (row>479) row = 479;
				if (col<0) col = 0;
				if (row<0) row = 0;
				pixel_ptr = (char *)vga_pixel_ptr + (row<<10) + col ;
				// set pixel color
				//nanosleep(&delay_time, NULL);
				draw_delay();
				*(char *)pixel_ptr = pixel_color;
			}
					
		}
}

// =============================================
// === Draw a line
// =============================================
//plot a line 
//at x1,y1 to x2,y2 with color 
//Code is from David Rodgers,
//"Procedural Elements of Computer Graphics",1985
void VGA_line(int x1, int y1, int x2, int y2, short c) {
	int e;
	signed int dx,dy,j, temp;
	signed int s1,s2, xchange;
     signed int x,y;
	char *pixel_ptr ;
	
	/* check and fix line coordinates to be valid */
	if (x1>639) x1 = 639;
	if (y1>479) y1 = 479;
	if (x2>639) x2 = 639;
	if (y2>479) y2 = 479;
	if (x1<0) x1 = 0;
	if (y1<0) y1 = 0;
	if (x2<0) x2 = 0;
	if (y2<0) y2 = 0;
        
	x = x1;
	y = y1;
	
	//take absolute value
	if (x2 < x1) {
		dx = x1 - x2;
		s1 = -1;
	}

	else if (x2 == x1) {
		dx = 0;
		s1 = 0;
	}

	else {
		dx = x2 - x1;
		s1 = 1;
	}

	if (y2 < y1) {
		dy = y1 - y2;
		s2 = -1;
	}

	else if (y2 == y1) {
		dy = 0;
		s2 = 0;
	}

	else {
		dy = y2 - y1;
		s2 = 1;
	}

	xchange = 0;   

	if (dy>dx) {
		temp = dx;
		dx = dy;
		dy = temp;
		xchange = 1;
	} 

	e = ((int)dy<<1) - dx;  
	 
	for (j=0; j<=dx; j++) {
		//video_pt(x,y,c); //640x480
		pixel_ptr = (char *)vga_pixel_ptr + (y<<10)+ x; 
		// set pixel color
		*(char *)pixel_ptr = c;	
		 
		if (e>=0) {
			if (xchange==1) x = x + s1;
			else y = y + s2;
			e = e - ((int)dx<<1);
		}

		if (xchange==1) y = y + s2;
		else x = x + s1;

		e = e + ((int)dy<<1);
	}
}

/////////////////////////////////////////////

#define NOP10() asm("nop;nop;nop;nop;nop;nop;nop;nop;nop;nop")

void draw_delay(void){
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10(); //16
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10(); //32
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10(); //48
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10(); //64
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10(); //68
	// NOP10(); NOP10(); NOP10(); NOP10();
	// NOP10(); NOP10(); NOP10(); NOP10();
	// NOP10(); NOP10(); NOP10(); NOP10();
	// NOP10(); NOP10(); NOP10(); NOP10();
	// NOP10(); NOP10(); NOP10(); NOP10();
	// NOP10(); NOP10(); NOP10(); NOP10();
	// NOP10(); NOP10(); NOP10(); NOP10();
	// NOP10(); NOP10(); NOP10(); NOP10();
	// NOP10(); NOP10(); NOP10(); NOP10();
	// NOP10(); NOP10(); NOP10(); NOP10();
	// NOP10(); NOP10(); NOP10(); NOP10();
	// NOP10(); NOP10(); NOP10(); NOP10(); //80
	// NOP10(); NOP10(); NOP10(); NOP10();
	// NOP10(); NOP10(); NOP10(); NOP10();
	// NOP10(); NOP10(); NOP10(); NOP10();
	// NOP10(); NOP10(); NOP10(); NOP10();
	// NOP10(); NOP10(); NOP10(); NOP10();
	// NOP10(); NOP10(); NOP10(); NOP10();
	// NOP10(); NOP10(); NOP10(); NOP10();
	// NOP10(); NOP10(); NOP10(); NOP10();
	// NOP10(); NOP10(); NOP10(); NOP10();
	// NOP10(); NOP10(); NOP10(); NOP10();
	// NOP10(); NOP10(); NOP10(); NOP10();
	// NOP10(); NOP10(); NOP10(); NOP10();
	// NOP10(); NOP10(); NOP10(); NOP10();
	// NOP10(); NOP10(); NOP10(); NOP10();
	// NOP10(); NOP10(); NOP10(); NOP10();
	NOP10(); NOP10(); NOP10(); NOP10(); //96
}

/// /// ///////////////////////////////////// 
/// end /////////////////////////////////////
