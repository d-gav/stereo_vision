## Stereo Disparity on DE1-SoC HPS

A clean multi-file C implementation of a parametrizable SAD stereo matcher for
the DE1-SoC platform. It reads the captured stereo pair from the top of the
VGA pixel buffer (where the Video-In DMA has copied the dual-camera PAL frame),
computes a disparity map between the two sub-images with optional NEON SIMD
acceleration, and writes the map centered in the bottom 192 rows of the VGA.

### Compatibility with `computer_15_640_video_mod`

This matches the stock Qsys in that project:

- `SDRAM_BASE = 0xC0000000` (HPS view of `SDRAM.s1`; VGA Pixel DMA target)
- `FPGA_ONCHIP_BASE = 0xC8000000` (HPS view of `Onchip_SRAM.s1`; Video-In DMA target)
- VGA Pixel DMA: X-Y addressing, 640x480, **8-bit grayscale**, stride 1024
- Video-In DMA: X-Y addressing, 640x288, 8-bit, stride 1024
- VGA character buffer at `FPGA_CHAR_BASE = 0xC9000000`

Because the Pixel DMA is configured as 8-bit grayscale (see
`VGA_Subsystem.qsys`), the default output is a grayscale disparity map
(small disparity = dark, large disparity = bright). If you rebuild the FPGA
with an RGB332 pixel buffer instead, enable the jet colormap with `--rgb332`
or the `m` hotkey to get the blue->red gradient described below.

### Directory layout

```
stereo_c/
  Makefile
  README.md
  include/
    address_map_arm_brl4.h
    stereo_config.h
    stereo_hw.h
    stereo_capture.h
    stereo_sad.h
    stereo_sad_internal.h
    disparity_colormap.h
    vga_draw.h
  src/
    stereo_hw.c
    stereo_capture.c
    stereo_sad.c
    stereo_sad_neon.c
    disparity_colormap.c
    vga_draw.c
    main.c
```

### Build (on DE1-SoC HPS or ARM cross toolchain)

The stock DE1-SoC Linux image often ships **GCC 4.x**, which does not support
`-std=gnu11`. The Makefile defaults to **`-std=gnu99`**. If you have GCC 4.7+ or
a cross-compiler, you can use:

```
make CSTD=gnu11
```

Otherwise:

```
make
```

A minimal `include/address_map_arm_brl4.h` is checked in (DE1-SoC Computer
system map, with `VIDEO_IN_BASE` as an offset into the `HW_REGS` mmap, matching
`ntsc2vga_demo.c`). The Makefile adds the parent and grandparent of this
`stereo_c/` directory to the include path (paths are resolved from the
`Makefile` location, not your shell’s cwd). A copy of the same header can also
live in the project root. Do **not** set `BRL4_INCLUDE=../..` when building from
`stereo-vision/stereo_c` that points *past* the repo (that adds `/`’s parent,
not `stereo-vision`). For an extra directory:

```
make BRL4_INCLUDE=/path/to/custom/include
```

**If you see a nested `stereo_vision/stereo_c/stereo_c/`** (accidental copy),
build inside the **inner** tree only if it is complete, or remove the extra
nesting and keep a **single** `stereo_vision/stereo_c` with a full `include/`.
**If `address_map_arm_brl4.h` is missing in `include/`**, run:

`cp "$HOME/stereo-vision/address_map_arm_brl4.h" stereo_c/include/`

(adjust paths to match your machine) or re-copy the `stereo_c/` tree from
this repository.

NEON is enabled by default (`-mfpu=neon -mfloat-abi=hard`). Disable with:

```
make NEON=0
```

### Run

```
./build/stereo_disparity \
  --window-w 9 \
  --window-h 9 \
  --max-disp 32 \
  --vshift 0
```

Runtime keys:
- `r` – recompute disparity with current parameters
- `w` / `W` – decrease / increase window width
- `h` / `H` – decrease / increase window height
- `d` / `D` – decrease / increase max disparity
- `v` / `V` – decrease / increase vertical shift
- `s` – toggle NEON fast path
- `x` – toggle LR swap (capture is reversed)
- `b` – re-detect the dark bars that separate the sub-images
- `m` – toggle colormap (grayscale <-> RGB332)
- `q` – quit

### VGA layout

- Rows 0..287: mirrored Video-In frame (640x288, with black bar between the two
  314-pixel-wide sub-images).
- Rows 288..479: disparity map, horizontally centered around x=163 (width 314).
  Grayscale by default; blue->red jet available via `--rgb332` if the Qsys
  pixel buffer is rebuilt in color mode.

### Notes

- Default parameters match the bar positions observed in the Python split
  pipeline (`left_x_start=0, left_x_end=313, right_x_start=318,
  right_x_end=631`). The black-bar locations are re-detected automatically
  at startup; if detection fails the defaults are used.
- All heavy computation uses fixed-size scratch buffers and a box-filter
  aggregation with running sums. The NEON path accelerates the per-pixel
  absolute-difference stage (16 pixels per op using `vabdq_u8`) and the
  winner-take-all stage (8 pixels per op using `vcltq_u32`).
