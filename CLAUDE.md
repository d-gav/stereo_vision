# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

Stereo-vision class project (Daniel, Demetrios, Ezra) targeting the **Terasic DE1-SoC** with a dual-camera PAL/NTSC video front end. The same SAD block-matching algorithm is implemented in three forms that are intended to track each other:

1. **Verilog/SystemVerilog RTL** that runs on the Cyclone V FPGA (Quartus project under `computer_15_640_video_mod/`).
2. **C reference for the HPS (ARM Cortex-A9)** that mmaps the Qsys peripherals and drives the same VGA buffer (`stereo_c/`).
3. **Python research code** that prototypes algorithms, sweeps parameters, and runs the RTL through Icarus Verilog testbenches (`sterio-vision-python/`, `python-testing/`, `stereo_rtl_test/`).

When changing the matching algorithm, expect to touch the RTL, the C, and the Python golden model — they share parameter names (`window_w/window_h`, `max_disparity`, `v_shift`, `BLOCK_SIZE`, `MAX_DISP`, `NUM_SAD_UNITS`, ...) on purpose.

## Repository layout

- [computer_15_640_video_mod/computer_15_640_video_mod/](computer_15_640_video_mod/computer_15_640_video_mod/) — Quartus project (forked from the U.Toronto "Computer System 15" 640x480 video-mod baseline). Top-level is [DE1_SoC_Computer.v](computer_15_640_video_mod/computer_15_640_video_mod/verilog/DE1_SoC_Computer.v); Qsys subsystems are `Computer_System.qsys`, `VGA_Subsystem.qsys`, `Video_In_Subsystem.qsys`. Stereo RTL lives alongside in `verilog/` (`block_match.sv`, `mem_block_intf*.v`, `sliding_window.sv`, `column_prefetch.v`, `stereo_bram_bank.v`, plus the radial/polynomial undistortion mappers).
- [stereo_c/](stereo_c/) — Multi-file C SAD matcher for the HPS. Builds with the in-tree Makefile.
- [sterio-vision-python/](sterio-vision-python/) — Production-style Python pipeline (`stereo_depth_system/` package + `run_stereo_experiments.py` driver). This is the canonical reference implementation.
- [python-testing/](python-testing/) — Loose research scripts (calibration, lens-distortion fits, polynomial/radial mapper LUT generation, parameter sweeps). Many `*_results.json` files are reports from past sweeps.
- [stereo_rtl_test/](stereo_rtl_test/) — Standalone Icarus Verilog testbench that drives `mem_block_intf` from a real PNG and renders the disparity output back to PNG.
- [stero-vision-test-images/](stero-vision-test-images/) and [calibration-images/](calibration-images/) — Captured VGA frames used as input fixtures.
- [ntsc2vga_demo.c](ntsc2vga_demo.c), [address_map_arm_brl4.h](address_map_arm_brl4.h) — Vendored DE1-SoC reference; the C build's include path is set up to find this header in the repo root.

## Hardware/memory map (must match across RTL + C)

Set in the stock Qsys; do not invent new addresses:

- `SDRAM_BASE = 0xC0000000` — HPS view of `SDRAM.s1`, target of the **VGA Pixel DMA**, 640×480 8-bit grayscale, **stride 1024**.
- `FPGA_ONCHIP_BASE = 0xC8000000` — HPS view of `Onchip_SRAM.s1`, target of the **Video-In DMA**, 640×288 8-bit, stride 1024.
- `FPGA_CHAR_BASE = 0xC9000000` — VGA character buffer.
- The captured PAL frame contains both cameras side-by-side. Default sub-image bounds (from the Python split pipeline calibration): left x=[0..313], black bar x=[314..317], right x=[318..631]. The C code re-detects these bars at startup.
- The captured "left" half is actually the right camera and vice-versa, so `swap_lr` defaults to 1 in C and `--swap-inputs` is the usual flag in the Python driver.

## Build and run

### C SAD matcher (HPS)

Build from [stereo_c/](stereo_c/):

```
make                       # default: GCC, -std=gnu99, NEON on
make CSTD=gnu11            # newer toolchains only
make NEON=0                # disable ARM NEON fast path
make BRL4_INCLUDE=/path    # extra include dir if address_map_arm_brl4.h lives elsewhere
```

The Makefile resolves include paths from the **Makefile location**, not the shell cwd, and adds the parent and grandparent directories so the repo-root copy of `address_map_arm_brl4.h` is found automatically. The DE1-SoC's stock Linux GCC 4.x cannot build `-std=gnu11`; that is why `gnu99` is the default.

Run on the board:

```
./build/stereo_disparity --window-w 9 --window-h 9 --max-disp 32 --vshift 0
```

Hotkeys at runtime: `r` recompute, `w/W h/H d/D v/V` adjust window/disp/vshift, `s` toggle NEON, `x` toggle LR swap, `b` re-detect dark bars, `m` toggle grayscale↔RGB332 jet, `q` quit.

### Python stereo pipeline

```
cd sterio-vision-python && pip install -r requirements.txt
python run_stereo_experiments.py --input-dir <split-pairs-dir> --output-dir <out> \
       --methods "bm,sgbm,sad_l1,census_hamming" --swap-inputs --crop-height 288
```

Supported `--methods` cover OpenCV BM/SGBM, custom L1/L2 SAD, vshift variants (2D search around the epipolar line for imperfect rectification), and Census+Hamming. The README in [sterio-vision-python/README.md](sterio-vision-python/README.md) documents every sweep flag and output artifact.

The exploratory scripts under [python-testing/](python-testing/) are standalone (`pip install -r python-testing/requirements.txt` — only numpy + opencv). They write `*_results.json` and PNG grids; many are referenced by name in earlier scripts so renaming them breaks the chain.

### RTL image testbench (Icarus Verilog)

Requires `iverilog` + `vvp` on PATH and Pillow.

```
cd stereo_rtl_test
python -m pip install -r requirements.txt
python run_interactive_tb.py                                   # interactive prompts
python run_interactive_tb.py --input-png in.png --output-png out.png
python run_interactive_tb.py --max-disp 15 --progress-stride 10000   # quick smoke
```

This drives [tb_mem_block_intf.sv](stereo_rtl_test/tb_mem_block_intf.sv) using the same `mem_block_intf` DUT that lives in the Quartus tree, with one-cycle memory read latency. Use `--no-vcd` to skip waveform dump for speed; `--keep-intermediate` to inspect the generated left/right/disp hex files in `build/`.

### FPGA build

Open the Quartus project [DE1_SoC_Computer.qpf](computer_15_640_video_mod/computer_15_640_video_mod/verilog/DE1_SoC_Computer.qpf) in Quartus 18.1 (matches the included `db/`, `incremental_db/`, `output_files/`). Regenerate Qsys subsystems if you edit `.qsys` files. The committed `.sof` and the `.qar` snapshots (`DE1_SoC_Computer_640_480.qar`) preserve known-good states — recent commits show that working SOFs are tagged in the git log (e.g. "practically last working SAD") rather than only stored as artifacts.

## Architectural notes worth knowing before editing

- **Stereo RTL pipeline.** The matcher reads a row-banked memory through a single-pixel `mem_req/mem_bank/mem_col` interface (left=0, right=1) with one-cycle latency. The active `mem_block_intf` is in [mem_block_intf_d.v](computer_15_640_video_mod/computer_15_640_video_mod/verilog/mem_block_intf_d.v) (the `_d` variant — `mem_block_intf.v` without the suffix is an older snapshot). It drives `NUM_SAD_UNITS` parallel `block_match_sad` engines (each on a horizontal stripe) that compare a `BLOCK_SIZE×BLOCK_SIZE` reference against a `BLOCK_SIZE×(BLOCK_SIZE+MAX_DISP)` search window. The streaming output is `disp_valid / disp_out_x / disp_out_y / disp_out_value`. SGM-style penalties (`SGM_P1`, `SGM_P2`) are present as parameters.
- **Two undistortion mappers exist.** Pixel-radial (`stereo_radial_mapper_q15*.v`, with a Q15 LUT in [radial_scale_lut_q15.vh](computer_15_640_video_mod/computer_15_640_video_mod/verilog/radial_scale_lut_q15.vh)) and a degree-6 2D polynomial (`stereo_poly_mapper_deg6_q18.v`). Calibration coefficients are produced by the Python scripts (`fit_polynomial_mapper_from_lut.py`, `apply_charuco_calibration_to_ntsc.py`, `generate_stereo_lut_from_existing_calibration.py`). The fixed undistort LUT ROMs (`undistort_lut_*.v`, `undistort_lut_*.memh`) are generated artifacts.
- **C SAD matcher mirrors the RTL parameters.** [stereo_config.h](stereo_c/include/stereo_config.h) holds the canonical defaults (window 9×9, max-disparity 32, sub-image 314×288). The NEON path uses `vabdq_u8` for the per-pixel diff and `vcltq_u32` for winner-take-all; the scalar fallback uses a box-filter aggregation with running sums. The output disparity map is written into the bottom 192 rows of the same VGA buffer the Video-In DMA wrote the input to (rows 0..287 input, rows 288..479 disparity).
- **Pixel-buffer format depends on Qsys.** The stock VGA Pixel DMA in this project is **8-bit grayscale**, so the C and RTL outputs default to grayscale. RGB332 jet mapping (the blue→red colormap) only works if you rebuild Qsys with an RGB332 pixel buffer; the C code's `--rgb332` / `m` hotkey assume that.
- **Python `stereo_depth_system/` is the algorithm playground.** New matching ideas should land in [methods.py](sterio-vision-python/stereo_depth_system/methods.py) and be exposed through the registry returned by `get_methods()` so the sweep driver in [pipeline.py](sterio-vision-python/stereo_depth_system/pipeline.py) and [run_stereo_experiments.py](sterio-vision-python/run_stereo_experiments.py) picks them up automatically. Test images live in [stero-vision-test-images/](stero-vision-test-images/) and [calibration-images/](calibration-images/).

## Conventions

- **`.gitignore` excludes generated artifacts** (`*.png`, `*.npy`, `*.mif`, `*.memh`, `*.hex`, `*.json`, `*.vcd`, `*.qmsg`, `*.vpp`, `*.vvp`, `*.pyc`). Calibration images and test PNGs in this repo are intentionally **not** gitignored — they are committed fixtures, not build output. Don't add new generated files outside the gitignored patterns without a reason.
- **Verilog files ending in `_d.v` are the active variants** (e.g. `mem_block_intf_d.v` is what's wired into the top-level — not `mem_block_intf.v`). Edit the `_d.v` version. The non-suffixed and "copy" siblings are older snapshots kept around for reference.
- The Python pipelines write `summary.json` / `*_results.json` leaderboards alongside the PNG/NPY outputs; scripts later in the iteration chain (`blend_*`, `classify_*`, `top_only_*`) consume those JSON files by name.
