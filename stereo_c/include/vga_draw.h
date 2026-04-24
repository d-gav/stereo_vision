#ifndef VGA_DRAW_H
#define VGA_DRAW_H

#include <stdint.h>

/* VGA writes are 8-bit RGB332 byte writes to a buffer with a 1024-byte row
 * stride. All functions accept the base pointer to the pixel buffer. */

void vga_set_pixel(volatile unsigned int *vga_pixel_ptr,
                   int x, int y, uint8_t color);

uint8_t vga_read_pixel(volatile unsigned int *vga_pixel_ptr, int x, int y);

void vga_fill_rect(volatile unsigned int *vga_pixel_ptr,
                   int x0, int y0, int x1, int y1, uint8_t color);

void vga_text(volatile unsigned int *vga_char_ptr,
              int x, int y, const char *text);

void vga_text_clear(volatile unsigned int *vga_char_ptr);

/* Copy an 8-bit source block to the VGA buffer at (x0, y0). */
void vga_blit_u8(volatile unsigned int *vga_pixel_ptr,
                 int x0, int y0,
                 const uint8_t *src, int src_stride,
                 int width, int height);

#endif /* VGA_DRAW_H */
