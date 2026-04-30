#ifndef STEREO_SAD_H
#define STEREO_SAD_H

#include <stdint.h>
#include <stddef.h>
#include "stereo_config.h"

/* Stereo SAD workspace: all buffers share the same width/height/stride so the
 * inner kernels can be generic. The stride is in elements (not bytes). */
typedef struct stereo_sad_workspace {
    uint8_t  *ref_img;       /* left-camera canonical image */
    uint8_t  *tgt_img;       /* right-camera canonical image */
    uint8_t  *ad;            /* per-pixel absolute differences for one d */
    uint32_t *hsum;          /* horizontal box sum of ad (32-bit to be safe) */
    uint32_t *agg;           /* full 2-D box aggregated cost for one d */
    uint32_t *best_cost;     /* running minimum over d */
    uint8_t  *best_d;        /* argmin over d (0..max_disparity) */

    int       width;         /* sub_width */
    int       height;        /* sub_height */
    size_t    u8_stride;     /* in bytes/elements for uint8 buffers */
    size_t    u32_stride;    /* in uint32 elements */
} stereo_sad_workspace_t;

int  stereo_sad_workspace_init(stereo_sad_workspace_t *ws, int width, int height);
void stereo_sad_workspace_free(stereo_sad_workspace_t *ws);

/* Run the SAD matcher. ws must have been initialized with dimensions >=
 * params->sub_width/height, and ws->ref_img/tgt_img must already contain the
 * two canonical images (left-cam, right-cam). On return, ws->best_d contains
 * the disparity in the range [0, params->max_disparity] for each pixel. */
void stereo_sad_compute(const stereo_params_t *params,
                        stereo_sad_workspace_t *ws);

#endif /* STEREO_SAD_H */
