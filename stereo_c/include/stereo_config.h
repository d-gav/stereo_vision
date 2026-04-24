#ifndef STEREO_CONFIG_H
#define STEREO_CONFIG_H

#include <stddef.h>

/* VGA configuration (DE1-SoC pixel buffer: 640x480, 8-bit per pixel RGB332,
 * with 1024-byte row stride). */
#define STEREO_VGA_WIDTH        640
#define STEREO_VGA_HEIGHT       480
#define STEREO_VGA_STRIDE       1024

/* Video-In DMA: 640x288 stereo frame packed into the same 1024-byte stride
 * on-chip buffer. The captured frame is mirrored to the top of the VGA. */
#define STEREO_FRAME_WIDTH      640
#define STEREO_FRAME_HEIGHT     288
#define STEREO_VIDEO_IN_STRIDE  1024

/* Default sub-image boundaries (measured from calibration of the PAL mux). */
#define STEREO_LEFT_X_START_DEFAULT   0
#define STEREO_LEFT_X_END_DEFAULT     313   /* inclusive */
#define STEREO_CENTER_BAR_START_DFT   314
#define STEREO_CENTER_BAR_END_DFT     317
#define STEREO_RIGHT_X_START_DEFAULT  318
#define STEREO_RIGHT_X_END_DEFAULT    631   /* inclusive */

#define STEREO_SUB_WIDTH_DEFAULT      314
#define STEREO_SUB_HEIGHT_DEFAULT     288

/* Maximum bounds used when allocating internal buffers. Anything larger at
 * runtime will be clamped. */
#define STEREO_MAX_SUB_WIDTH          320
#define STEREO_MAX_SUB_HEIGHT         288
#define STEREO_MAX_WINDOW             31
#define STEREO_MAX_MAX_DISP           128

/* Default SAD parameters. */
#define STEREO_DEFAULT_WINDOW_W       9
#define STEREO_DEFAULT_WINDOW_H       9
#define STEREO_DEFAULT_MAX_DISP       32
#define STEREO_DEFAULT_V_SHIFT        0

/* The captured pair's left half is actually the right camera and vice
 * versa; set to 1 by default so we compute standard-convention disparity. */
#define STEREO_SWAP_LR_DEFAULT        1

/* Disparity output region (bottom strip of the VGA). */
#define STEREO_DISP_Y_START           288
#define STEREO_DISP_Y_END             480
#define STEREO_DISP_BAND_HEIGHT       (STEREO_DISP_Y_END - STEREO_DISP_Y_START)

typedef struct stereo_params {
    /* Sub-image geometry (inclusive column ranges) */
    int left_x_start;
    int left_x_end;
    int right_x_start;
    int right_x_end;
    int sub_width;           /* min of the two widths derived from bounds */
    int sub_height;

    /* SAD parameters */
    int window_w;            /* odd */
    int window_h;            /* odd */
    int max_disparity;
    int v_shift;             /* target row offset applied to target image */

    /* Behavioral flags */
    int swap_lr;             /* 1 if capture[left] is right camera */
    int use_neon;            /* 1 to enable NEON fast path */
    int colormap_mode;       /* 0 = grayscale (default), 1 = RGB332 jet */
} stereo_params_t;

void stereo_params_defaults(stereo_params_t *p);

/* Clamp parameters to safe ranges and ensure windows are odd. Returns 0 on
 * success, non-zero if a parameter was out of range and had to be clamped. */
int stereo_params_normalize(stereo_params_t *p);

#endif /* STEREO_CONFIG_H */
