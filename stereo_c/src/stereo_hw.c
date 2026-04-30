#include "stereo_hw.h"
#include "stereo_config.h"

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/mman.h>

#include "address_map_arm_brl4.h"

#define STEREO_VIDEO_IN_REQUIRED_SPAN \
    ((size_t)STEREO_VIDEO_IN_STRIDE * (size_t)STEREO_FRAME_HEIGHT)

#define STEREO_VGA_REQUIRED_SPAN \
    ((size_t)STEREO_VGA_STRIDE * (size_t)STEREO_VGA_HEIGHT)

int stereo_hw_init(stereo_hw_t *hw)
{
    if (hw == NULL) {
        return -1;
    }

    memset(hw, 0, sizeof(*hw));
    hw->fd = -1;
    hw->lw_base = MAP_FAILED;
    hw->vga_pixel_base = MAP_FAILED;
    hw->video_in_base = MAP_FAILED;
    hw->vga_char_base = MAP_FAILED;

    hw->fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (hw->fd == -1) {
        perror("open(/dev/mem)");
        return -1;
    }

    hw->lw_map_span = HW_REGS_SPAN;
    hw->lw_base = mmap(NULL, hw->lw_map_span, PROT_READ | PROT_WRITE,
                       MAP_SHARED, hw->fd, HW_REGS_BASE);
    if (hw->lw_base == MAP_FAILED) {
        perror("mmap(lw)");
        goto fail;
    }

    hw->lw_video_in_control =
        (volatile unsigned int *)((char *)hw->lw_base + VIDEO_IN_BASE + 0x0c);
    hw->lw_video_in_resolution =
        (volatile unsigned int *)((char *)hw->lw_base + VIDEO_IN_BASE + 0x08);
    hw->lw_video_edge_control =
        (volatile unsigned int *)((char *)hw->lw_base + VIDEO_IN_BASE + 0x10);

    *(hw->lw_video_in_control) = 0x04;
    *(hw->lw_video_edge_control) = 0x00;

    hw->char_map_span = FPGA_CHAR_SPAN;
    hw->vga_char_base = mmap(NULL, hw->char_map_span, PROT_READ | PROT_WRITE,
                             MAP_SHARED, hw->fd, FPGA_CHAR_BASE);
    if (hw->vga_char_base == MAP_FAILED) {
        perror("mmap(char)");
        goto fail;
    }
    hw->vga_char_ptr = (volatile unsigned int *)hw->vga_char_base;

    hw->onchip_map_span = FPGA_ONCHIP_SPAN;
    if (STEREO_VGA_REQUIRED_SPAN > hw->onchip_map_span) {
        hw->onchip_map_span = STEREO_VGA_REQUIRED_SPAN;
    }
    hw->vga_pixel_base = mmap(NULL, hw->onchip_map_span, PROT_READ | PROT_WRITE,
                              MAP_SHARED, hw->fd, SDRAM_BASE);
    if (hw->vga_pixel_base == MAP_FAILED) {
        perror("mmap(sdram)");
        goto fail;
    }
    hw->vga_pixel_ptr = (volatile unsigned int *)hw->vga_pixel_base;

    hw->video_in_map_span = FPGA_ONCHIP_SPAN;
    if (STEREO_VIDEO_IN_REQUIRED_SPAN > hw->video_in_map_span) {
        hw->video_in_map_span = STEREO_VIDEO_IN_REQUIRED_SPAN;
    }

    hw->video_in_base = mmap(NULL, hw->video_in_map_span,
                             PROT_READ | PROT_WRITE, MAP_SHARED, hw->fd,
                             FPGA_ONCHIP_BASE);
    if (hw->video_in_base == MAP_FAILED) {
        perror("mmap(video_in)");
        goto fail;
    }
    hw->video_in_ptr = (volatile unsigned int *)hw->video_in_base;

    return 0;

fail:
    stereo_hw_teardown(hw);
    return -1;
}

void stereo_hw_teardown(stereo_hw_t *hw)
{
    if (hw == NULL) {
        return;
    }

    if (hw->video_in_base != NULL && hw->video_in_base != MAP_FAILED) {
        munmap(hw->video_in_base, hw->video_in_map_span);
        hw->video_in_base = MAP_FAILED;
    }
    if (hw->vga_pixel_base != NULL && hw->vga_pixel_base != MAP_FAILED) {
        munmap(hw->vga_pixel_base, hw->onchip_map_span);
        hw->vga_pixel_base = MAP_FAILED;
    }
    if (hw->vga_char_base != NULL && hw->vga_char_base != MAP_FAILED) {
        munmap(hw->vga_char_base, hw->char_map_span);
        hw->vga_char_base = MAP_FAILED;
    }
    if (hw->lw_base != NULL && hw->lw_base != MAP_FAILED) {
        munmap(hw->lw_base, hw->lw_map_span);
        hw->lw_base = MAP_FAILED;
    }

    if (hw->fd != -1) {
        close(hw->fd);
        hw->fd = -1;
    }
}
