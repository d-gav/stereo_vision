#include "stereo_sad.h"
#include "stereo_sad_internal.h"

#include <stdint.h>
#include <string.h>

#if STEREO_HAVE_NEON

#include <arm_neon.h>

void stereo_sad_compute_ad_neon(const uint8_t *ref_img,
                                const uint8_t *tgt_img,
                                uint8_t *ad,
                                int width, int height,
                                size_t stride,
                                int d, int v_shift)
{
    const uint8x16_t invalid_v = vdupq_n_u8(STEREO_AD_INVALID);

    for (int y = 0; y < height; ++y) {
        int ty = y + v_shift;
        uint8_t *ad_row = ad + (size_t)y * stride;

        if (ty < 0 || ty >= height) {
            int x = 0;
            for (; x + 16 <= width; x += 16) {
                vst1q_u8(&ad_row[x], invalid_v);
            }
            for (; x < width; ++x) {
                ad_row[x] = STEREO_AD_INVALID;
            }
            continue;
        }

        const uint8_t *ref_row = ref_img + (size_t)y  * stride;
        const uint8_t *tgt_row = tgt_img + (size_t)ty * stride;

        int left_invalid = d;
        if (left_invalid > width) left_invalid = width;

        int x = 0;
        for (; x + 16 <= left_invalid; x += 16) {
            vst1q_u8(&ad_row[x], invalid_v);
        }
        for (; x < left_invalid; ++x) {
            ad_row[x] = STEREO_AD_INVALID;
        }

        for (; x + 16 <= width; x += 16) {
            uint8x16_t r = vld1q_u8(&ref_row[x]);
            uint8x16_t t = vld1q_u8(&tgt_row[x - d]);
            uint8x16_t a = vabdq_u8(r, t);
            vst1q_u8(&ad_row[x], a);
        }
        for (; x < width; ++x) {
            int diff = (int)ref_row[x] - (int)tgt_row[x - d];
            if (diff < 0) diff = -diff;
            ad_row[x] = (uint8_t)diff;
        }
    }
}

void stereo_sad_update_best_neon(const uint32_t *agg,
                                 uint32_t *best_cost,
                                 uint8_t *best_d,
                                 int width, int height,
                                 size_t stride,
                                 int d)
{
    const uint8_t d_byte = (uint8_t)d;
    const uint8x16_t new_dv = vdupq_n_u8(d_byte);

    for (int y = 0; y < height; ++y) {
        const uint32_t *a_row  = agg       + (size_t)y * stride;
        uint32_t       *bc_row = best_cost + (size_t)y * stride;
        uint8_t        *bd_row = best_d    + (size_t)y * stride;

        int x = 0;
        for (; x + 16 <= width; x += 16) {
            uint32x4_t bc0 = vld1q_u32(&bc_row[x +  0]);
            uint32x4_t bc1 = vld1q_u32(&bc_row[x +  4]);
            uint32x4_t bc2 = vld1q_u32(&bc_row[x +  8]);
            uint32x4_t bc3 = vld1q_u32(&bc_row[x + 12]);
            uint32x4_t a0  = vld1q_u32(&a_row[x +  0]);
            uint32x4_t a1  = vld1q_u32(&a_row[x +  4]);
            uint32x4_t a2  = vld1q_u32(&a_row[x +  8]);
            uint32x4_t a3  = vld1q_u32(&a_row[x + 12]);

            uint32x4_t m0 = vcltq_u32(a0, bc0);
            uint32x4_t m1 = vcltq_u32(a1, bc1);
            uint32x4_t m2 = vcltq_u32(a2, bc2);
            uint32x4_t m3 = vcltq_u32(a3, bc3);

            vst1q_u32(&bc_row[x +  0], vbslq_u32(m0, a0, bc0));
            vst1q_u32(&bc_row[x +  4], vbslq_u32(m1, a1, bc1));
            vst1q_u32(&bc_row[x +  8], vbslq_u32(m2, a2, bc2));
            vst1q_u32(&bc_row[x + 12], vbslq_u32(m3, a3, bc3));

            uint16x8_t m01 = vcombine_u16(vmovn_u32(m0), vmovn_u32(m1));
            uint16x8_t m23 = vcombine_u16(vmovn_u32(m2), vmovn_u32(m3));
            uint8x16_t mask8 = vcombine_u8(vmovn_u16(m01), vmovn_u16(m23));

            uint8x16_t old_d = vld1q_u8(&bd_row[x]);
            uint8x16_t blended = vbslq_u8(mask8, new_dv, old_d);
            vst1q_u8(&bd_row[x], blended);
        }

        for (; x < width; ++x) {
            if (a_row[x] < bc_row[x]) {
                bc_row[x] = a_row[x];
                bd_row[x] = d_byte;
            }
        }
    }
}

static void fill_invalid_row_u32(uint32_t *row, int width)
{
    const uint32x4_t inv = vdupq_n_u32(UINT32_MAX);
    int x = 0;
    for (; x + 4 <= width; x += 4) {
        vst1q_u32(&row[x], inv);
    }
    for (; x < width; ++x) {
        row[x] = UINT32_MAX;
    }
}

void stereo_sad_vertical_sum_neon(const uint32_t *hsum,
                                  uint32_t *agg,
                                  int width, int height,
                                  size_t stride,
                                  int window_h)
{
    const int half = window_h / 2;

    int first_valid_y = (height >= window_h) ? half : height;
    int last_valid_y  = (height >= window_h) ? (height - half - 1) : -1;

    for (int y = 0; y < first_valid_y; ++y) {
        fill_invalid_row_u32(agg + (size_t)y * stride, width);
    }

    if (height >= window_h) {
        uint32_t *out = agg + (size_t)half * stride;
        int x = 0;
        for (; x + 4 <= width; x += 4) {
            uint32x4_t s = vdupq_n_u32(0);
            for (int i = 0; i < window_h; ++i) {
                s = vaddq_u32(s, vld1q_u32(&hsum[(size_t)i * stride + x]));
            }
            vst1q_u32(&out[x], s);
        }
        for (; x < width; ++x) {
            uint32_t s = 0;
            for (int i = 0; i < window_h; ++i) {
                s += hsum[(size_t)i * stride + x];
            }
            out[x] = s;
        }

        for (int y = half + 1; y <= last_valid_y; ++y) {
            const uint32_t *prev_row = agg  + (size_t)(y - 1) * stride;
            const uint32_t *add_row  = hsum + (size_t)(y + half) * stride;
            const uint32_t *sub_row  = hsum + (size_t)(y - half - 1) * stride;
            uint32_t       *cur_row  = agg  + (size_t)y * stride;

            int xv = 0;
            for (; xv + 4 <= width; xv += 4) {
                uint32x4_t p = vld1q_u32(&prev_row[xv]);
                uint32x4_t a = vld1q_u32(&add_row[xv]);
                uint32x4_t s = vld1q_u32(&sub_row[xv]);
                uint32x4_t r = vaddq_u32(p, vsubq_u32(a, s));
                vst1q_u32(&cur_row[xv], r);
            }
            for (; xv < width; ++xv) {
                cur_row[xv] = prev_row[xv] + add_row[xv] - sub_row[xv];
            }
        }
    }

    for (int y = last_valid_y + 1; y < height; ++y) {
        fill_invalid_row_u32(agg + (size_t)y * stride, width);
    }
}

#endif /* STEREO_HAVE_NEON */
