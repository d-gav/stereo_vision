#include "vga_draw.h"
#include "stereo_config.h"

#include <string.h>

void vga_set_pixel(volatile unsigned int *vga_pixel_ptr,
                   int x, int y, uint8_t color)
{
    if ((unsigned)x >= STEREO_VGA_WIDTH || (unsigned)y >= STEREO_VGA_HEIGHT) {
        return;
    }
    volatile char *p = (volatile char *)vga_pixel_ptr + ((size_t)y << 10) + (size_t)x;
    *p = (char)color;
}

uint8_t vga_read_pixel(volatile unsigned int *vga_pixel_ptr, int x, int y)
{
    if ((unsigned)x >= STEREO_VGA_WIDTH || (unsigned)y >= STEREO_VGA_HEIGHT) {
        return 0;
    }
    volatile char *p = (volatile char *)vga_pixel_ptr + ((size_t)y << 10) + (size_t)x;
    return (uint8_t)(*p);
}

void vga_fill_rect(volatile unsigned int *vga_pixel_ptr,
                   int x0, int y0, int x1, int y1, uint8_t color)
{
    if (x0 > x1) { int t = x0; x0 = x1; x1 = t; }
    if (y0 > y1) { int t = y0; y0 = y1; y1 = t; }
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 >= STEREO_VGA_WIDTH)  x1 = STEREO_VGA_WIDTH  - 1;
    if (y1 >= STEREO_VGA_HEIGHT) y1 = STEREO_VGA_HEIGHT - 1;

    for (int y = y0; y <= y1; ++y) {
        volatile char *row = (volatile char *)vga_pixel_ptr + ((size_t)y << 10);
        for (int x = x0; x <= x1; ++x) {
            row[x] = (char)color;
        }
    }
}

void vga_text(volatile unsigned int *vga_char_ptr,
              int x, int y, const char *text)
{
    if (text == NULL) {
        return;
    }
    volatile char *character_buffer = (volatile char *)vga_char_ptr;
    int offset = (y << 7) + x;
    while (*text) {
        character_buffer[offset] = *text;
        ++text;
        ++offset;
    }
}

void vga_text_clear(volatile unsigned int *vga_char_ptr)
{
    volatile char *character_buffer = (volatile char *)vga_char_ptr;
    for (int y = 0; y < 59; ++y) {
        for (int x = 0; x < 79; ++x) {
            character_buffer[(y << 7) + x] = ' ';
        }
    }
}

void vga_blit_u8(volatile unsigned int *vga_pixel_ptr,
                 int x0, int y0,
                 const uint8_t *src, int src_stride,
                 int width, int height)
{
    if (src == NULL || width <= 0 || height <= 0) {
        return;
    }

    int x_end = x0 + width;
    int y_end = y0 + height;
    if (x0 < 0 || y0 < 0 || x_end > STEREO_VGA_WIDTH || y_end > STEREO_VGA_HEIGHT) {
        /* Clamp per-pixel rather than rejecting the whole blit. */
        for (int dy = 0; dy < height; ++dy) {
            int vy = y0 + dy;
            if ((unsigned)vy >= STEREO_VGA_HEIGHT) continue;
            volatile char *row = (volatile char *)vga_pixel_ptr + ((size_t)vy << 10);
            const uint8_t *src_row = src + (size_t)dy * (size_t)src_stride;
            for (int dx = 0; dx < width; ++dx) {
                int vx = x0 + dx;
                if ((unsigned)vx >= STEREO_VGA_WIDTH) continue;
                row[vx] = (char)src_row[dx];
            }
        }
        return;
    }

    for (int dy = 0; dy < height; ++dy) {
        volatile char *row = (volatile char *)vga_pixel_ptr + ((size_t)(y0 + dy) << 10);
        const uint8_t *src_row = src + (size_t)dy * (size_t)src_stride;
        memcpy((void *)(row + x0), src_row, (size_t)width);
    }
}
