#ifndef STEREO_HW_H
#define STEREO_HW_H

#include <stddef.h>

/* Encapsulates all mmap'd DE1-SoC regions used by the stereo application.
 * Fields are volatile pointers for the FPGA-facing registers because they
 * must be accessed with IO loads/stores. */
typedef struct stereo_hw {
    int fd;

    void *lw_base;
    void *vga_pixel_base;
    void *video_in_base;
    void *vga_char_base;

    volatile unsigned int *lw_video_in_control;
    volatile unsigned int *lw_video_in_resolution;
    volatile unsigned int *lw_video_edge_control;

    volatile unsigned int *vga_pixel_ptr;
    volatile unsigned int *video_in_ptr;
    volatile unsigned int *vga_char_ptr;

    size_t video_in_map_span;
    size_t onchip_map_span;
    size_t lw_map_span;
    size_t char_map_span;
} stereo_hw_t;

int  stereo_hw_init(stereo_hw_t *hw);
void stereo_hw_teardown(stereo_hw_t *hw);

#endif /* STEREO_HW_H */
