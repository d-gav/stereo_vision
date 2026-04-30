#include "disparity_colormap.h"

static inline uint8_t rgb332_pack(uint8_t r, uint8_t g, uint8_t b)
{
    return (uint8_t)(((r & 0xE0u)) | ((g & 0xE0u) >> 3) | ((b & 0xC0u) >> 6));
}

static void jet_rgb(uint8_t t, uint8_t *r, uint8_t *g, uint8_t *b)
{
    int v = (int)t;
    int rr = 0, gg = 0, bb = 0;

    if (v < 64) {
        rr = 0;             gg = v * 4;         bb = 255;
    } else if (v < 128) {
        rr = 0;             gg = 255;           bb = 255 - (v - 64) * 4;
    } else if (v < 192) {
        rr = (v - 128) * 4; gg = 255;           bb = 0;
    } else {
        rr = 255;           gg = 255 - (v - 192) * 4; bb = 0;
    }

    if (rr < 0) rr = 0; else if (rr > 255) rr = 255;
    if (gg < 0) gg = 0; else if (gg > 255) gg = 255;
    if (bb < 0) bb = 0; else if (bb > 255) bb = 255;

    *r = (uint8_t)rr;
    *g = (uint8_t)gg;
    *b = (uint8_t)bb;
}

uint8_t disparity_to_byte(uint8_t disparity, uint8_t max_disparity,
                          stereo_colormap_mode_t mode)
{
    uint32_t denom = (max_disparity == 0) ? 1 : (uint32_t)max_disparity;
    uint32_t scaled = (uint32_t)disparity * 255u / denom;
    if (scaled > 255u) scaled = 255u;

    if (mode == STEREO_COLORMAP_RGB332) {
        uint8_t r, g, b;
        jet_rgb((uint8_t)scaled, &r, &g, &b);
        return rgb332_pack(r, g, b);
    }

    /* Grayscale: larger disparity -> brighter pixel. */
    return (uint8_t)scaled;
}

void disparity_colormap_build_palette(uint8_t palette[256],
                                      stereo_colormap_mode_t mode)
{
    for (int i = 0; i < 256; ++i) {
        if (mode == STEREO_COLORMAP_RGB332) {
            uint8_t r, g, b;
            jet_rgb((uint8_t)i, &r, &g, &b);
            palette[i] = rgb332_pack(r, g, b);
        } else {
            palette[i] = (uint8_t)i;
        }
    }
}
