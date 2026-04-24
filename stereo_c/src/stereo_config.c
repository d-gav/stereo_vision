#include "stereo_config.h"

static int odd_clamp(int v, int min_v, int max_v)
{
    if (v < min_v) v = min_v;
    if (v > max_v) v = max_v;
    if ((v & 1) == 0) {
        if (v + 1 <= max_v) {
            v = v + 1;
        } else {
            v = v - 1;
        }
    }
    return v;
}

void stereo_params_defaults(stereo_params_t *p)
{
    if (p == NULL) {
        return;
    }

    p->left_x_start   = STEREO_LEFT_X_START_DEFAULT;
    p->left_x_end     = STEREO_LEFT_X_END_DEFAULT;
    p->right_x_start  = STEREO_RIGHT_X_START_DEFAULT;
    p->right_x_end    = STEREO_RIGHT_X_END_DEFAULT;
    p->sub_width      = STEREO_SUB_WIDTH_DEFAULT;
    p->sub_height     = STEREO_SUB_HEIGHT_DEFAULT;

    p->window_w       = STEREO_DEFAULT_WINDOW_W;
    p->window_h       = STEREO_DEFAULT_WINDOW_H;
    p->max_disparity  = STEREO_DEFAULT_MAX_DISP;
    p->v_shift        = STEREO_DEFAULT_V_SHIFT;

    p->swap_lr        = STEREO_SWAP_LR_DEFAULT;
    p->use_neon       = 1;
    p->colormap_mode  = 0; /* grayscale by default: matches stock DE1-SoC Qsys */
}

int stereo_params_normalize(stereo_params_t *p)
{
    int changed = 0;
    if (p == NULL) {
        return -1;
    }

    int left_width  = p->left_x_end  - p->left_x_start  + 1;
    int right_width = p->right_x_end - p->right_x_start + 1;
    int sub_width   = (left_width < right_width) ? left_width : right_width;
    if (sub_width > STEREO_MAX_SUB_WIDTH) {
        sub_width = STEREO_MAX_SUB_WIDTH;
        changed = 1;
    }
    if (sub_width < 16) {
        sub_width = 16;
        changed = 1;
    }
    p->sub_width = sub_width;

    if (p->sub_height <= 0 || p->sub_height > STEREO_MAX_SUB_HEIGHT) {
        p->sub_height = STEREO_SUB_HEIGHT_DEFAULT;
        changed = 1;
    }

    int new_w = odd_clamp(p->window_w, 3, STEREO_MAX_WINDOW);
    int new_h = odd_clamp(p->window_h, 3, STEREO_MAX_WINDOW);
    if (new_w != p->window_w) { p->window_w = new_w; changed = 1; }
    if (new_h != p->window_h) { p->window_h = new_h; changed = 1; }

    if (p->max_disparity < 1) {
        p->max_disparity = 1;
        changed = 1;
    }
    if (p->max_disparity > STEREO_MAX_MAX_DISP) {
        p->max_disparity = STEREO_MAX_MAX_DISP;
        changed = 1;
    }
    if (p->max_disparity >= p->sub_width - p->window_w) {
        p->max_disparity = p->sub_width - p->window_w - 1;
        if (p->max_disparity < 1) p->max_disparity = 1;
        changed = 1;
    }

    if (p->v_shift < -32) { p->v_shift = -32; changed = 1; }
    if (p->v_shift >  32) { p->v_shift =  32; changed = 1; }

    if (p->swap_lr) p->swap_lr = 1;
    if (p->use_neon) p->use_neon = 1;

    return changed;
}
