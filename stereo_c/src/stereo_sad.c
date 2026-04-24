#include "stereo_sad.h"
#include "stereo_sad_internal.h"

#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdio.h>

static size_t align16(size_t v)
{
    return (v + 15u) & ~((size_t)15);
}

/* Simple aligned allocator for portability. Allocates extra bytes and stores
 * the original malloc pointer just before the aligned address so free() can
 * recover the original. */
static void *aligned_alloc16(size_t bytes)
{
    void *raw = malloc(bytes + 16u + sizeof(void *));
    if (raw == NULL) {
        return NULL;
    }
    uintptr_t aligned = ((uintptr_t)raw + sizeof(void *) + 15u) & ~(uintptr_t)15u;
    ((void **)aligned)[-1] = raw;
    return (void *)aligned;
}

static void aligned_free16(void *p)
{
    if (p != NULL) {
        free(((void **)p)[-1]);
    }
}

int stereo_sad_workspace_init(stereo_sad_workspace_t *ws, int width, int height)
{
    if (ws == NULL || width <= 0 || height <= 0) {
        return -1;
    }
    memset(ws, 0, sizeof(*ws));

    size_t stride_u8  = align16((size_t)width);
    size_t stride_u32 = align16((size_t)width);
    size_t plane_u8   = stride_u8  * (size_t)height;
    size_t plane_u32  = stride_u32 * (size_t)height;

    ws->ref_img   = (uint8_t *)aligned_alloc16(plane_u8);
    ws->tgt_img   = (uint8_t *)aligned_alloc16(plane_u8);
    ws->ad        = (uint8_t *)aligned_alloc16(plane_u8);
    ws->best_d    = (uint8_t *)aligned_alloc16(plane_u8);
    ws->hsum      = (uint32_t *)aligned_alloc16(plane_u32 * sizeof(uint32_t));
    ws->agg       = (uint32_t *)aligned_alloc16(plane_u32 * sizeof(uint32_t));
    ws->best_cost = (uint32_t *)aligned_alloc16(plane_u32 * sizeof(uint32_t));

    if (ws->ref_img == NULL || ws->tgt_img == NULL || ws->ad == NULL ||
        ws->best_d == NULL || ws->hsum == NULL || ws->agg == NULL ||
        ws->best_cost == NULL) {
        stereo_sad_workspace_free(ws);
        return -1;
    }

    ws->width      = width;
    ws->height     = height;
    ws->u8_stride  = stride_u8;
    ws->u32_stride = stride_u32;
    return 0;
}

void stereo_sad_workspace_free(stereo_sad_workspace_t *ws)
{
    if (ws == NULL) {
        return;
    }
    aligned_free16(ws->ref_img);
    aligned_free16(ws->tgt_img);
    aligned_free16(ws->ad);
    aligned_free16(ws->best_d);
    aligned_free16(ws->hsum);
    aligned_free16(ws->agg);
    aligned_free16(ws->best_cost);
    memset(ws, 0, sizeof(*ws));
}

/* ------------------------------------------------------------------ */
/* Scalar per-pixel absolute difference for one disparity.            */
/* ------------------------------------------------------------------ */
void stereo_sad_compute_ad_scalar(const uint8_t *ref_img,
                                  const uint8_t *tgt_img,
                                  uint8_t *ad,
                                  int width, int height,
                                  size_t stride,
                                  int d, int v_shift)
{
    for (int y = 0; y < height; ++y) {
        int ty = y + v_shift;
        uint8_t *ad_row = ad + (size_t)y * stride;

        if (ty < 0 || ty >= height) {
            memset(ad_row, STEREO_AD_INVALID, (size_t)width);
            continue;
        }

        const uint8_t *ref_row = ref_img + (size_t)y * stride;
        const uint8_t *tgt_row = tgt_img + (size_t)ty * stride;

        int left_invalid = d;
        if (left_invalid > width) left_invalid = width;
        if (left_invalid > 0) {
            memset(ad_row, STEREO_AD_INVALID, (size_t)left_invalid);
        }

        for (int x = left_invalid; x < width; ++x) {
            int diff = (int)ref_row[x] - (int)tgt_row[x - d];
            if (diff < 0) diff = -diff;
            ad_row[x] = (uint8_t)diff;
        }
    }
}

/* ------------------------------------------------------------------ */
/* Horizontal running sum (length window_w, centered on each x).       */
/* ------------------------------------------------------------------ */
void stereo_sad_horizontal_sum(const uint8_t *ad,
                               uint32_t *hsum,
                               int width, int height,
                               size_t ad_stride,
                               size_t hsum_stride,
                               int window_w)
{
    const int half = window_w / 2;
    const uint32_t invalid_fill = UINT32_MAX;

    for (int y = 0; y < height; ++y) {
        const uint8_t *ad_row = ad   + (size_t)y * ad_stride;
        uint32_t      *h_row  = hsum + (size_t)y * hsum_stride;

        int last_valid_x = (width >= window_w) ? (width - half - 1) : -1;
        int first_valid_x = (width >= window_w) ? half : width;

        for (int x = 0; x < first_valid_x; ++x) {
            h_row[x] = invalid_fill;
        }

        if (width >= window_w) {
            uint32_t sum = 0;
            for (int i = 0; i < window_w; ++i) sum += ad_row[i];
            h_row[half] = sum;

            for (int x = half + 1; x <= last_valid_x; ++x) {
                sum += ad_row[x + half];
                sum -= ad_row[x - half - 1];
                h_row[x] = sum;
            }
        }

        for (int x = last_valid_x + 1; x < width; ++x) {
            h_row[x] = invalid_fill;
        }
    }
}

/* ------------------------------------------------------------------ */
/* Scalar vertical running sum (length window_h, centered on each y). */
/* ------------------------------------------------------------------ */
void stereo_sad_vertical_sum_scalar(const uint32_t *hsum,
                                    uint32_t *agg,
                                    int width, int height,
                                    size_t stride,
                                    int window_h)
{
    const int half = window_h / 2;
    const uint32_t invalid_fill = UINT32_MAX;

    int first_valid_y = (height >= window_h) ? half : height;
    int last_valid_y  = (height >= window_h) ? (height - half - 1) : -1;

    for (int y = 0; y < first_valid_y; ++y) {
        uint32_t *row = agg + (size_t)y * stride;
        for (int x = 0; x < width; ++x) row[x] = invalid_fill;
    }

    if (height >= window_h) {
        uint32_t *out_row = agg + (size_t)half * stride;
        for (int x = 0; x < width; ++x) {
            uint32_t s = 0;
            for (int i = 0; i < window_h; ++i) {
                s += hsum[(size_t)i * stride + x];
            }
            out_row[x] = s;
        }

        for (int y = half + 1; y <= last_valid_y; ++y) {
            const uint32_t *prev_row = agg  + (size_t)(y - 1) * stride;
            const uint32_t *add_row  = hsum + (size_t)(y + half) * stride;
            const uint32_t *sub_row  = hsum + (size_t)(y - half - 1) * stride;
            uint32_t       *out      = agg  + (size_t)y * stride;
            for (int x = 0; x < width; ++x) {
                out[x] = prev_row[x] + add_row[x] - sub_row[x];
            }
        }
    }

    for (int y = last_valid_y + 1; y < height; ++y) {
        uint32_t *row = agg + (size_t)y * stride;
        for (int x = 0; x < width; ++x) row[x] = invalid_fill;
    }
}

/* ------------------------------------------------------------------ */
/* Winner-take-all update.                                             */
/* ------------------------------------------------------------------ */
void stereo_sad_update_best_scalar(const uint32_t *agg,
                                   uint32_t *best_cost,
                                   uint8_t *best_d,
                                   int width, int height,
                                   size_t stride,
                                   int d)
{
    uint8_t d_byte = (uint8_t)d;
    for (int y = 0; y < height; ++y) {
        const uint32_t *a_row  = agg       + (size_t)y * stride;
        uint32_t       *bc_row = best_cost + (size_t)y * stride;
        uint8_t        *bd_row = best_d    + (size_t)y * stride;
        for (int x = 0; x < width; ++x) {
            if (a_row[x] < bc_row[x]) {
                bc_row[x] = a_row[x];
                bd_row[x] = d_byte;
            }
        }
    }
}

/* ------------------------------------------------------------------ */
/* Fall-back stubs when NEON is disabled at compile time.              */
/* ------------------------------------------------------------------ */
#if !STEREO_HAVE_NEON
void stereo_sad_compute_ad_neon(const uint8_t *ref_img,
                                const uint8_t *tgt_img,
                                uint8_t *ad,
                                int width, int height,
                                size_t stride,
                                int d, int v_shift)
{
    stereo_sad_compute_ad_scalar(ref_img, tgt_img, ad, width, height, stride,
                                 d, v_shift);
}

void stereo_sad_update_best_neon(const uint32_t *agg,
                                 uint32_t *best_cost,
                                 uint8_t *best_d,
                                 int width, int height,
                                 size_t stride,
                                 int d)
{
    stereo_sad_update_best_scalar(agg, best_cost, best_d, width, height, stride, d);
}

void stereo_sad_vertical_sum_neon(const uint32_t *hsum,
                                  uint32_t *agg,
                                  int width, int height,
                                  size_t stride,
                                  int window_h)
{
    stereo_sad_vertical_sum_scalar(hsum, agg, width, height, stride, window_h);
}
#endif /* !STEREO_HAVE_NEON */

/* ------------------------------------------------------------------ */
/* Orchestrator: runs compute_ad, box filter, and WTA across all d.    */
/* ------------------------------------------------------------------ */
void stereo_sad_compute(const stereo_params_t *params,
                        stereo_sad_workspace_t *ws)
{
    if (params == NULL || ws == NULL) return;

    int width  = params->sub_width;
    int height = params->sub_height;
    if (width > ws->width)   width  = ws->width;
    if (height > ws->height) height = ws->height;

    size_t plane_u32_bytes = ws->u32_stride * (size_t)ws->height * sizeof(uint32_t);
    size_t plane_u8_bytes  = ws->u8_stride  * (size_t)ws->height;

    memset(ws->best_cost, 0xFF, plane_u32_bytes);
    memset(ws->best_d,    0x00, plane_u8_bytes);

    const int use_neon = (STEREO_HAVE_NEON && params->use_neon) ? 1 : 0;

    for (int d = 0; d <= params->max_disparity; ++d) {
        if (use_neon) {
            stereo_sad_compute_ad_neon(ws->ref_img, ws->tgt_img, ws->ad,
                                       width, height, ws->u8_stride,
                                       d, params->v_shift);
        } else {
            stereo_sad_compute_ad_scalar(ws->ref_img, ws->tgt_img, ws->ad,
                                         width, height, ws->u8_stride,
                                         d, params->v_shift);
        }

        stereo_sad_horizontal_sum(ws->ad, ws->hsum,
                                  width, height,
                                  ws->u8_stride, ws->u32_stride,
                                  params->window_w);

        if (use_neon) {
            stereo_sad_vertical_sum_neon(ws->hsum, ws->agg,
                                         width, height, ws->u32_stride,
                                         params->window_h);
        } else {
            stereo_sad_vertical_sum_scalar(ws->hsum, ws->agg,
                                           width, height, ws->u32_stride,
                                           params->window_h);
        }

        if (use_neon) {
            stereo_sad_update_best_neon(ws->agg, ws->best_cost, ws->best_d,
                                        width, height, ws->u32_stride, d);
        } else {
            stereo_sad_update_best_scalar(ws->agg, ws->best_cost, ws->best_d,
                                          width, height, ws->u32_stride, d);
        }
    }

    /* Force invalid border pixels to disparity 0 for visualization. */
    for (int y = 0; y < height; ++y) {
        uint32_t *bc_row = ws->best_cost + (size_t)y * ws->u32_stride;
        uint8_t  *bd_row = ws->best_d    + (size_t)y * ws->u8_stride;
        for (int x = 0; x < width; ++x) {
            if (bc_row[x] == UINT32_MAX) {
                bd_row[x] = 0;
            }
        }
    }
}
