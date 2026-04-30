#ifndef STEREO_CAPTURE_H
#define STEREO_CAPTURE_H

#include <stdint.h>
#include "stereo_config.h"

/* Detect the vertical black bar columns in the captured stereo frame. The
 * frame is read from the VGA pixel buffer (top STEREO_FRAME_HEIGHT rows).
 *
 * On success returns 0 and writes:
 *   - out_left_end     : inclusive x of the last column of the left sub-image
 *   - out_right_start  : inclusive x of the first column of the right sub-image
 *   - out_right_end    : inclusive x of the last column of the right sub-image
 *
 * On failure returns non-zero and the outputs are left unchanged. */
int stereo_capture_detect_bars(volatile unsigned int *vga_pixel_ptr,
                               int *out_left_end,
                               int *out_right_start,
                               int *out_right_end);

/* Copy the two sub-images from the top of the VGA buffer into the supplied
 * scratch buffers. The destination stride is measured in bytes and must be at
 * least params->sub_width. params->swap_lr is honored: if set, capture's
 * right half fills scratch_left and vice versa so that the caller receives
 * the canonical (left-cam, right-cam) pair. */
void stereo_capture_copy(const stereo_params_t *params,
                         volatile unsigned int *vga_pixel_ptr,
                         uint8_t *scratch_left,
                         uint8_t *scratch_right,
                         int dst_stride);

#endif /* STEREO_CAPTURE_H */
