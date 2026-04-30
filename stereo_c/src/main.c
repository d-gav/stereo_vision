#include "stereo_config.h"
#include "stereo_hw.h"
#include "vga_draw.h"
#include "stereo_capture.h"
#include "stereo_sad.h"
#include "disparity_colormap.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/time.h>
#include <termios.h>

/* ------------------------------------------------------------------ */
/* Command line parsing                                                */
/* ------------------------------------------------------------------ */
static void print_usage(const char *prog)
{
    fprintf(stderr,
        "Usage: %s [options]\n"
        "\n"
        "  --window-w  N   Odd SAD window width (default %d, max %d)\n"
        "  --window-h  N   Odd SAD window height (default %d, max %d)\n"
        "  --max-disp  N   Maximum disparity (default %d, max %d)\n"
        "  --vshift    N   Vertical shift applied to target (default %d)\n"
        "  --vshift-pm N   Also search shifts in [vshift-N, vshift+N] (default %d)\n"
        "  --continuous    Recompute continuously (no 'r' key required)\n"
        "  --period-ms N   Continuous loop period in ms (default %d)\n"
        "  --no-swap       Do not swap captured left/right halves\n"
        "  --no-neon       Disable NEON fast path\n"
        "  --rgb332        Use RGB332 jet colormap (requires Qsys color buf)\n"
        "  -h, --help      Show this help and exit\n",
        prog,
        STEREO_DEFAULT_WINDOW_W, STEREO_MAX_WINDOW,
        STEREO_DEFAULT_WINDOW_H, STEREO_MAX_WINDOW,
        STEREO_DEFAULT_MAX_DISP, STEREO_MAX_MAX_DISP,
        STEREO_DEFAULT_V_SHIFT,
        STEREO_DEFAULT_V_SHIFT_PM,
        10);
}

typedef struct app_options {
    int continuous;
    int period_ms;
} app_options_t;

static int parse_args(int argc, char **argv,
                      stereo_params_t *params,
                      app_options_t *opts)
{
    stereo_params_defaults(params);
    opts->continuous = 0;
    opts->period_ms = 10;

    for (int i = 1; i < argc; ++i) {
        const char *arg = argv[i];
        if (strcmp(arg, "-h") == 0 || strcmp(arg, "--help") == 0) {
            print_usage(argv[0]);
            return -1;
        } else if (strcmp(arg, "--continuous") == 0) {
            opts->continuous = 1;
        } else if (i + 1 < argc && strcmp(arg, "--period-ms") == 0) {
            opts->period_ms = atoi(argv[++i]);
        } else if (strcmp(arg, "--no-swap") == 0) {
            params->swap_lr = 0;
        } else if (strcmp(arg, "--no-neon") == 0) {
            params->use_neon = 0;
        } else if (strcmp(arg, "--rgb332") == 0) {
            params->colormap_mode = 1;
        } else if (i + 1 < argc && strcmp(arg, "--window-w") == 0) {
            params->window_w = atoi(argv[++i]);
        } else if (i + 1 < argc && strcmp(arg, "--window-h") == 0) {
            params->window_h = atoi(argv[++i]);
        } else if (i + 1 < argc && strcmp(arg, "--max-disp") == 0) {
            params->max_disparity = atoi(argv[++i]);
        } else if (i + 1 < argc && strcmp(arg, "--vshift") == 0) {
            params->v_shift = atoi(argv[++i]);
        } else if (i + 1 < argc && strcmp(arg, "--vshift-pm") == 0) {
            params->v_shift_pm = atoi(argv[++i]);
        } else {
            fprintf(stderr, "Unknown argument: %s\n", arg);
            print_usage(argv[0]);
            return -1;
        }
    }

    if (opts->period_ms < 0) {
        opts->period_ms = 0;
    }

    stereo_params_normalize(params);
    return 0;
}

/* ------------------------------------------------------------------ */
/* Terminal helpers                                                    */
/* ------------------------------------------------------------------ */
static int configure_terminal_raw(struct termios *saved)
{
    struct termios raw;
    if (tcgetattr(STDIN_FILENO, saved) != 0) return -1;
    raw = *saved;
    raw.c_lflag &= (tcflag_t)~(ICANON | ECHO);
    raw.c_cc[VMIN]  = 0;
    raw.c_cc[VTIME] = 0;
    return tcsetattr(STDIN_FILENO, TCSANOW, &raw);
}

static void restore_terminal(const struct termios *saved)
{
    tcsetattr(STDIN_FILENO, TCSANOW, saved);
}

/* ------------------------------------------------------------------ */
/* Rendering                                                           */
/* ------------------------------------------------------------------ */
static void render_disparity_to_vga(const stereo_params_t *params,
                                    const stereo_sad_workspace_t *ws,
                                    volatile unsigned int *vga_pixel_ptr,
                                    const uint8_t palette[256])
{
    int src_width  = params->sub_width;
    int src_height = params->sub_height;
    int out_width  = src_width;
    int out_height = (src_height > STEREO_DISP_BAND_HEIGHT)
                         ? STEREO_DISP_BAND_HEIGHT : src_height;
    int y_crop_start = (src_height - out_height) / 2;

    int vga_x0 = (STEREO_VGA_WIDTH - out_width) / 2;
    int vga_y0 = STEREO_DISP_Y_START +
                 (STEREO_DISP_BAND_HEIGHT - out_height) / 2;

    /* Clear the output band to black first. */
    vga_fill_rect(vga_pixel_ptr,
                  0, STEREO_DISP_Y_START,
                  STEREO_VGA_WIDTH - 1, STEREO_DISP_Y_END - 1,
                  0x00);

    uint32_t denom = (uint32_t)params->max_disparity;
    if (denom == 0) denom = 1;

    for (int dy = 0; dy < out_height; ++dy) {
        const uint8_t *src_row =
            ws->best_d + (size_t)(y_crop_start + dy) * ws->u8_stride;
        volatile char *vga_row =
            (volatile char *)vga_pixel_ptr + ((size_t)(vga_y0 + dy) << 10);
        for (int dx = 0; dx < out_width; ++dx) {
            uint8_t d = src_row[dx];
            uint32_t scaled = (uint32_t)d * 255u / denom;
            if (scaled > 255u) scaled = 255u;
            vga_row[vga_x0 + dx] = (char)palette[scaled];
        }
    }
}

static void draw_status_text(volatile unsigned int *vga_char_ptr,
                             const stereo_params_t *params,
                             double last_ms)
{
    char buf[120];
    vga_text_clear(vga_char_ptr);

    snprintf(buf, sizeof(buf),
             "SAD  w=%d h=%d maxD=%d vshift=%d+-%d swap=%d neon=%d cmap=%s",
             params->window_w, params->window_h, params->max_disparity,
             params->v_shift, params->v_shift_pm,
             params->swap_lr, params->use_neon,
             params->colormap_mode ? "rgb332" : "gray");
    vga_text(vga_char_ptr, 1, 55, buf);

    snprintf(buf, sizeof(buf), "last compute: %.1f ms", last_ms);
    vga_text(vga_char_ptr, 1, 56, buf);

    vga_text(vga_char_ptr, 1, 57,
             "keys: r  wW hH dD vV  x swap  s neon  m colormap  b bars  q quit");
}

static double compute_elapsed_ms(struct timeval *a, struct timeval *b)
{
    double ms = (double)(b->tv_sec - a->tv_sec) * 1000.0;
    ms += (double)(b->tv_usec - a->tv_usec) / 1000.0;
    return ms;
}

/* ------------------------------------------------------------------ */
/* One SAD cycle: capture, compute, render.                            */
/* ------------------------------------------------------------------ */
static double run_once(const stereo_params_t *params,
                       stereo_hw_t *hw,
                       stereo_sad_workspace_t *ws,
                       const uint8_t palette[256])
{
    struct timeval t0, t1;
    gettimeofday(&t0, NULL);

    stereo_capture_copy(params, hw->vga_pixel_ptr,
                        ws->ref_img, ws->tgt_img, (int)ws->u8_stride);
    stereo_sad_compute(params, ws);
    render_disparity_to_vga(params, ws, hw->vga_pixel_ptr, palette);

    gettimeofday(&t1, NULL);
    return compute_elapsed_ms(&t0, &t1);
}

/* ------------------------------------------------------------------ */
/* Main                                                                */
/* ------------------------------------------------------------------ */
int main(int argc, char **argv)
{
    stereo_params_t params;
    app_options_t opts;
    if (parse_args(argc, argv, &params, &opts) != 0) {
        return 1;
    }

    stereo_hw_t hw;
    if (stereo_hw_init(&hw) != 0) {
        fprintf(stderr, "Failed to initialize DE1-SoC hardware mappings.\n");
        return 1;
    }

    /* Let the Video-In DMA settle before scanning for dark bars. */
    usleep(150000);

    int detected_left_end, detected_right_start, detected_right_end;
    if (stereo_capture_detect_bars(hw.vga_pixel_ptr, &detected_left_end,
                                   &detected_right_start,
                                   &detected_right_end) == 0) {
        params.left_x_start  = 0;
        params.left_x_end    = detected_left_end;
        params.right_x_start = detected_right_start;
        params.right_x_end   = detected_right_end;
        printf("Detected bars: left=[0,%d] right=[%d,%d]\n",
               params.left_x_end, params.right_x_start, params.right_x_end);
    } else {
        printf("Bar detection failed, using defaults.\n");
    }
    stereo_params_normalize(&params);

    stereo_sad_workspace_t ws;
    if (stereo_sad_workspace_init(&ws, STEREO_MAX_SUB_WIDTH,
                                  STEREO_MAX_SUB_HEIGHT) != 0) {
        fprintf(stderr, "Failed to allocate SAD workspace.\n");
        stereo_hw_teardown(&hw);
        return 1;
    }

    uint8_t palette[256];
    disparity_colormap_build_palette(palette,
        (stereo_colormap_mode_t)(params.colormap_mode ? STEREO_COLORMAP_RGB332
                                                      : STEREO_COLORMAP_GRAYSCALE));

    struct termios saved_tty;
    int raw_ok = (configure_terminal_raw(&saved_tty) == 0) ? 1 : 0;

    double last_ms = run_once(&params, &hw, &ws, palette);
    draw_status_text(hw.vga_char_ptr, &params, last_ms);
    printf("Initial SAD pass: %.1f ms. Press keys: r/wW/hH/dD/vV/x/s/q.\n",
           last_ms);

    int quit = 0;
    while (!quit) {
        char key;
        ssize_t n = read(STDIN_FILENO, &key, 1);
        int dirty = opts.continuous ? 1 : 0;
        if (n == 1) {
            switch (key) {
                case 'q': case 'Q': quit = 1; break;
                case 'r': case 'R': dirty = 1; break;
                case 'w': params.window_w -= 2; dirty = 1; break;
                case 'W': params.window_w += 2; dirty = 1; break;
                case 'h': params.window_h -= 2; dirty = 1; break;
                case 'H': params.window_h += 2; dirty = 1; break;
                case 'd': params.max_disparity -= 4; dirty = 1; break;
                case 'D': params.max_disparity += 4; dirty = 1; break;
                case 'v': params.v_shift -= 1; dirty = 1; break;
                case 'V': params.v_shift += 1; dirty = 1; break;
                case 'x': case 'X': params.swap_lr = !params.swap_lr; dirty = 1; break;
                case 's': case 'S': params.use_neon = !params.use_neon; dirty = 1; break;
                case 'm': case 'M':
                    params.colormap_mode = !params.colormap_mode;
                    disparity_colormap_build_palette(palette,
                        (stereo_colormap_mode_t)(params.colormap_mode
                            ? STEREO_COLORMAP_RGB332 : STEREO_COLORMAP_GRAYSCALE));
                    dirty = 1;
                    break;
                case 'b': case 'B': {
                    int le, rs, re;
                    if (stereo_capture_detect_bars(hw.vga_pixel_ptr,
                                                   &le, &rs, &re) == 0) {
                        params.left_x_start  = 0;
                        params.left_x_end    = le;
                        params.right_x_start = rs;
                        params.right_x_end   = re;
                        dirty = 1;
                    }
                    break;
                }
                default: break;
            }
        } else if (n < 0 && errno != EAGAIN && errno != EINTR) {
            fprintf(stderr, "stdin read error\n");
            break;
        }

        if (dirty) {
            stereo_params_normalize(&params);
            last_ms = run_once(&params, &hw, &ws, palette);
            draw_status_text(hw.vga_char_ptr, &params, last_ms);
        }

        if (opts.continuous) {
            if (opts.period_ms > 0) {
                usleep((useconds_t)opts.period_ms * 1000u);
            }
        } else {
            usleep(10000);
        }
    }

    if (raw_ok) restore_terminal(&saved_tty);
    stereo_sad_workspace_free(&ws);
    stereo_hw_teardown(&hw);
    return 0;
}
