#ifndef DISPARITY_COLORMAP_H
#define DISPARITY_COLORMAP_H

#include <stdint.h>

typedef enum {
    /* Grayscale intensity ramp (0 = dark, 255 = bright).
     * Required by the stock DE1-SoC Qsys (8-bit Grayscale pixel DMA). */
    STEREO_COLORMAP_GRAYSCALE = 0,
    /* Jet-style blue->cyan->green->yellow->red packed into RGB332.
     * Only displays correctly if the Qsys VGA Pixel DMA / Resampler have
     * been reconfigured for an 8-bit RGB332 color buffer. */
    STEREO_COLORMAP_RGB332    = 1,
} stereo_colormap_mode_t;

/* Populate a 256-entry palette matching the requested mode. */
void disparity_colormap_build_palette(uint8_t palette[256],
                                      stereo_colormap_mode_t mode);

/* Convenience helpers for a single value. */
uint8_t disparity_to_byte(uint8_t disparity, uint8_t max_disparity,
                          stereo_colormap_mode_t mode);

#endif /* DISPARITY_COLORMAP_H */
