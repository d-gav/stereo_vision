#ifndef STEREO_SAD_INTERNAL_H
#define STEREO_SAD_INTERNAL_H

#include <stdint.h>
#include <stddef.h>
#include "stereo_sad.h"

#ifndef STEREO_HAVE_NEON
#define STEREO_HAVE_NEON 0
#endif

/* A per-pixel absolute-difference value used to mark out-of-bounds locations.
 * Keeping it moderate avoids overflowing the uint32 aggregation buffer when
 * multiplied by the maximum supported window size. */
#define STEREO_AD_INVALID 255u

void stereo_sad_compute_ad_scalar(const uint8_t *ref_img,
                                  const uint8_t *tgt_img,
                                  uint8_t *ad,
                                  int width, int height,
                                  size_t stride,
                                  int d, int v_shift);

void stereo_sad_horizontal_sum(const uint8_t *ad,
                               uint32_t *hsum,
                               int width, int height,
                               size_t ad_stride,
                               size_t hsum_stride,
                               int window_w);

void stereo_sad_vertical_sum_scalar(const uint32_t *hsum,
                                    uint32_t *agg,
                                    int width, int height,
                                    size_t stride,
                                    int window_h);

void stereo_sad_update_best_scalar(const uint32_t *agg,
                                   uint32_t *best_cost,
                                   uint8_t *best_d,
                                   int width, int height,
                                   size_t stride,
                                   int d);

/* NEON-accelerated variants. When STEREO_HAVE_NEON is 0 these are stubs that
 * fall back to the scalar implementations. */
void stereo_sad_compute_ad_neon(const uint8_t *ref_img,
                                const uint8_t *tgt_img,
                                uint8_t *ad,
                                int width, int height,
                                size_t stride,
                                int d, int v_shift);

void stereo_sad_update_best_neon(const uint32_t *agg,
                                 uint32_t *best_cost,
                                 uint8_t *best_d,
                                 int width, int height,
                                 size_t stride,
                                 int d);

void stereo_sad_vertical_sum_neon(const uint32_t *hsum,
                                  uint32_t *agg,
                                  int width, int height,
                                  size_t stride,
                                  int window_h);

#endif /* STEREO_SAD_INTERNAL_H */
