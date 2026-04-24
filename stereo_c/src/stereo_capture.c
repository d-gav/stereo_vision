#include "stereo_capture.h"
#include "vga_draw.h"

#include <string.h>

/* Classify a column as "dark" if at least DARK_RATIO of its pixels are below
 * DARK_THRESHOLD. These settings mirror the Python split_stereo_images.ps1 bar
 * detector. */
#define STEREO_BAR_DARK_THRESHOLD 40
#define STEREO_BAR_DARK_RATIO_NUM 3
#define STEREO_BAR_DARK_RATIO_DEN 4  /* 3/4 of column pixels must be dark */

static int column_is_dark(volatile unsigned int *vga_pixel_ptr, int x)
{
    int dark = 0;
    for (int y = 0; y < STEREO_FRAME_HEIGHT; ++y) {
        uint8_t v = vga_read_pixel(vga_pixel_ptr, x, y);
        if (v < STEREO_BAR_DARK_THRESHOLD) {
            ++dark;
        }
    }
    return (dark * STEREO_BAR_DARK_RATIO_DEN) >=
           (STEREO_FRAME_HEIGHT * STEREO_BAR_DARK_RATIO_NUM);
}

int stereo_capture_detect_bars(volatile unsigned int *vga_pixel_ptr,
                               int *out_left_end,
                               int *out_right_start,
                               int *out_right_end)
{
    if (vga_pixel_ptr == NULL) {
        return -1;
    }

    int is_dark[STEREO_FRAME_WIDTH];
    for (int x = 0; x < STEREO_FRAME_WIDTH; ++x) {
        is_dark[x] = column_is_dark(vga_pixel_ptr, x);
    }

    /* Find dark runs. */
    int runs_start[32];
    int runs_end[32];
    int run_count = 0;

    int x = 0;
    while (x < STEREO_FRAME_WIDTH && run_count < 32) {
        if (!is_dark[x]) { ++x; continue; }
        int s = x;
        while (x < STEREO_FRAME_WIDTH && is_dark[x]) ++x;
        runs_start[run_count] = s;
        runs_end[run_count] = x - 1;
        ++run_count;
    }

    if (run_count == 0) {
        return -1;
    }

    /* Center run: the one closest to the frame midline. */
    int image_center = STEREO_FRAME_WIDTH / 2;
    int center_idx = 0;
    int center_dist = STEREO_FRAME_WIDTH;
    for (int i = 0; i < run_count; ++i) {
        int mid = (runs_start[i] + runs_end[i]) / 2;
        int d = mid - image_center;
        if (d < 0) d = -d;
        if (d < center_dist) {
            center_dist = d;
            center_idx = i;
        }
    }

    int center_start = runs_start[center_idx];
    int center_end   = runs_end[center_idx];
    if (center_start <= 0 || center_end >= STEREO_FRAME_WIDTH - 1) {
        return -1;
    }

    /* Right-edge bar: the rightmost run whose center is in the far-right
     * quarter of the frame. */
    int right_bar_start = -1;
    int right_threshold = (STEREO_FRAME_WIDTH * 3) / 4;
    for (int i = 0; i < run_count; ++i) {
        int mid = (runs_start[i] + runs_end[i]) / 2;
        if (mid >= right_threshold) {
            right_bar_start = runs_start[i];
        }
    }

    *out_left_end    = center_start - 1;
    *out_right_start = center_end + 1;
    *out_right_end   = (right_bar_start >= 0) ? (right_bar_start - 1)
                                              : (STEREO_FRAME_WIDTH - 1);
    return 0;
}

void stereo_capture_copy(const stereo_params_t *params,
                         volatile unsigned int *vga_pixel_ptr,
                         uint8_t *scratch_left,
                         uint8_t *scratch_right,
                         int dst_stride)
{
    if (params == NULL || vga_pixel_ptr == NULL || scratch_left == NULL ||
        scratch_right == NULL) {
        return;
    }

    int width  = params->sub_width;
    int height = params->sub_height;

    /* The canonical "left camera" image is what we treat as the reference for
     * SAD. When swap_lr is set, capture's right half is the actual left cam. */
    int ref_x_base = params->swap_lr ? params->right_x_start : params->left_x_start;
    int tgt_x_base = params->swap_lr ? params->left_x_start  : params->right_x_start;

    if (ref_x_base + width > STEREO_FRAME_WIDTH) {
        width = STEREO_FRAME_WIDTH - ref_x_base;
    }
    if (tgt_x_base + width > STEREO_FRAME_WIDTH) {
        width = STEREO_FRAME_WIDTH - tgt_x_base;
    }
    if (width <= 0 || height <= 0) {
        return;
    }

    for (int y = 0; y < height; ++y) {
        volatile char *src_row = (volatile char *)vga_pixel_ptr + ((size_t)y << 10);
        uint8_t *ref_row = scratch_left  + (size_t)y * (size_t)dst_stride;
        uint8_t *tgt_row = scratch_right + (size_t)y * (size_t)dst_stride;
        memcpy(ref_row, (const void *)(src_row + ref_x_base), (size_t)width);
        memcpy(tgt_row, (const void *)(src_row + tgt_x_base), (size_t)width);
    }
}
