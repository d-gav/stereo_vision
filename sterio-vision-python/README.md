# Stereo Depth System (From Scratch)

This folder contains a clean stereo-vision depth pipeline built from scratch for 8-bit grayscale stereo images.

## Features

- Pair discovery from `*_left.png` and `*_right.png`
- Explicit `--swap-inputs` support for reversed left/right naming
- Organized multi-method experiments:
  - `bm` (OpenCV StereoBM)
  - `sgbm` (OpenCV StereoSGBM)
  - `sad_l1` (windowed Sum of Absolute Differences, L1)
  - `sad_l2` (windowed Sum of Squared Differences, L2)
  - `sad_l1_vshift` / `sad_l2_vshift` (SAD with 2D search that also checks +/- V rows,
    useful when rectification is imperfect after fisheye removal)
  - `sgbm_vshift` (runs SGBM at several vertical row offsets and picks the per-pixel best match)
  - `census_hamming` (Census transform + Hamming distance)
  - `census_hamming_vshift` (Census + Hamming with 2D search that also checks +/- V rows,
    plus a sweep over aggregation window, census window, and max disparity)
- SAD and vshift parameter sweeps across multiple disparity ranges, window sizes, and vertical radii
- Per-pixel chosen-row visualization (`vshift_color.png`) for the vshift methods
- Relative depth map generation from disparity
- Structured output folders plus a machine-readable `summary.json`

## Install

```bash
pip install -r requirements.txt
```

## Run

```powershell
python run_stereo_experiments.py `
  --input-dir "test-images-4-19/split" `
  --output-dir "test-images-4-19/depth-results" `
  --methods "bm,sgbm,sad_l1" `
  --swap-inputs `
  --crop-height 288
```

Optional: add `--min-disparity N` to suppress low-disparity noise.
Values below `N` are marked invalid and appear blue in preview colormaps.
For SAD methods this is applied *after* matching (full search is still used).

### SAD-Only Grid Search (L1 + L2)

```powershell
python run_stereo_experiments.py `
  --input-dir "test-images-4-19/split" `
  --output-dir "test-images-4-19/depth-results-sad-grid" `
  --methods "sad_l1,sad_l2" `
  --swap-inputs `
  --crop-height 288 `
  --sad-max-disparities "24,32,48,64,96" `
  --sad-window-sizes "5,7,9,11,13"
```

### SAD with Vertical Shifts (robust to imperfect rectification)

Sweep horizontal disparity + window size at several vertical search radii. Each vshift
value `V` means the block matcher also checks rows in `[-V, +V]` around the epipolar line.

```powershell
python run_stereo_experiments.py `
  --input-dir "test-images-4-19/split" `
  --output-dir "test-images-4-19/depth-results-sad-vshift" `
  --methods "sad_l1_vshift,sad_l2_vshift" `
  --swap-inputs `
  --crop-height 288 `
  --min-disparity 6 `
  --sad-max-disparities "48,64,96" `
  --sad-window-sizes "7,9,13" `
  --sad-vshifts "0,2,4"
```

### Preprocessing Sweep for a Fixed SAD Configuration

Use this to hold SAD parameters fixed (e.g. `d=85`, `3x3`, `vshift=3`) and test
multiple preprocessing combinations automatically.

```powershell
python run_stereo_experiments.py `
  --input-dir "test-images-4-19/split" `
  --output-dir "test-images-4-19/depth-results-sad-best-pre-sweep" `
  --methods "sad_l1_vshift,sad_l2_vshift" `
  --swap-inputs `
  --crop-height 288 `
  --sad-max-disparities "85" `
  --sad-window-widths "3" `
  --sad-window-heights "3" `
  --sad-vshifts "3" `
  --preprocess-sweep `
  --preprocess-clahe-options "off,on" `
  --preprocess-median-ksizes "0,3,5"
```

This writes one subfolder per preprocessing variant (for example
`pre_clahe_off_med0`, `pre_clahe_on_med3`, ...), plus
`preprocess_sweep_summary.json` at the sweep root with per-method mean valid ratio
for each variant.

It also writes cross-variant comparison grids to:

- `<output>/preprocess_grids/<pair_name>/<method>_preprocess_grid.png`
- `<output>/preprocess_grids/<pair_name>/input_processed_preprocess_grid.png`

where rows are median blur settings and columns are CLAHE on/off.

### SGBM with Vertical Shifts

Runs OpenCV SGBM for each vertical offset and selects the per-pixel best match using
a windowed L1 validation cost.

```powershell
python run_stereo_experiments.py `
  --input-dir "test-images-4-19/split" `
  --output-dir "test-images-4-19/depth-results-sgbm-vshift" `
  --methods "sgbm_vshift" `
  --swap-inputs `
  --crop-height 288 `
  --sgbm-num-disp 128 `
  --sgbm-vshift-block-sizes "5" `
  --sgbm-vshifts "0,2,4,6" `
  --sgbm-vshift-validation-windows "7"
```

### Census + Hamming with Vertical Shifts (sweep over vshift x agg_win x census_win x max_disp)

Runs the Census transform + Hamming distance matcher with an additional vertical
search radius, sweeping aggregation window and the usual (census_window, max_disparity)
axes. Each job is named `census_hamming_vs{V}_aw{A}_d{D}_w{W}`. Per-pair grid images
group (census_w x max_disp) panels by (vshift, aggregation_window).

```powershell
python run_stereo_experiments.py `
  --input-dir "test-images-4-19/split" `
  --output-dir "test-images-4-19/depth-results-census-vshift" `
  --methods "census_hamming_vshift" `
  --swap-inputs `
  --crop-height 288 `
  --census-max-disparities "48,64,96" `
  --census-window-sizes "3,5,7,9" `
  --census-vshifts "0,2,4" `
  --census-aggregation-windows "1,3,5,7"
```

Number of jobs per pair = `N_vshifts * N_agg_windows * N_census_windows * N_max_disparities`,
so budget accordingly. As with SGBM vshift, `summary.json` includes a per-pair
`census_vshift_best_by_valid_ratio` and a top-level `census_vshift_leaderboard`
sorted by mean valid-pixel ratio across all pairs, including
`mean_vshift_abs_mean` so you can see how much vertical compensation each config used.

### SGBM Full Parameter Sweep (block_size x validation_window x vshift)

To find the best SGBM configuration, sweep all three parameters at once. Each job
is named `sgbm_bs{B}_vw{W}_vs{V}`. A per-pair grid (one `val_win x vshift` 2D grid
per block_size, stacked vertically) is written, plus a `summary.json` leaderboard
sorted by mean valid-pixel ratio across all pairs.

```powershell
python run_stereo_experiments.py `
  --input-dir "test-images-4-19/split" `
  --output-dir "test-images-4-19/depth-results-sgbm-sweep" `
  --methods "sgbm_vshift" `
  --swap-inputs `
  --crop-height 288 `
  --sgbm-num-disp 128 `
  --sgbm-vshift-block-sizes "3,5,7,9,11" `
  --sgbm-vshift-validation-windows "5,7,9,11" `
  --sgbm-vshifts "0,2,4,6"
```

Even values are automatically rounded up to the next odd number. The run produces
`N_block_sizes * N_val_windows * N_vshifts` jobs per pair, so budget your sweep
ranges accordingly.

### Census + Hamming Sweep (Recommended for radiometric mismatch)

```powershell
python run_stereo_experiments.py `
  --input-dir "test-images-4-19/split" `
  --output-dir "test-images-4-19/depth-results-census" `
  --methods "census_hamming" `
  --swap-inputs `
  --crop-height 288 `
  --census-max-disparities "24,32,48,64,96" `
  --census-window-sizes "5,7,9" `
  --census-aggregation-window 5
```

## Output Structure

For each pair `<name>`, outputs are written to:

- `<output>/<name>/input_left_used.png`
- `<output>/<name>/input_right_used.png`
- `<output>/<name>/bm/...`
- `<output>/<name>/sgbm/...`
- `<output>/<name>/sad_l1_dXX_wYY/...`
- `<output>/<name>/sad_l2_dXX_wYY/...`

Each method directory contains:

- `disparity.npy`
- `depth_relative.npy`
- `disparity_preview.png`
- `depth_preview.png`
- `disparity_color.png`
- `depth_color.png`

`vshift` methods additionally write:

- `vshift_map.npy` (per-pixel chosen vertical offset in rows)
- `vshift_preview.png`
- `vshift_color.png` (blue = shift up, green = zero, red = shift down)

`summary.json` includes key statistics and valid disparity ratio for quick comparison.
For vshift methods it also reports `vshift_mean`, `vshift_abs_mean`, and
`vshift_fraction_nonzero` so you can tell how much vertical drift the matcher needed.

When running SAD sweeps, each pair directory also includes:

- `sad_l1_grid.png` (rows = window sizes, cols = max disparities)
- `sad_l2_grid.png` (rows = window sizes, cols = max disparities)
- `sad_l1_l2_grid.png` (stacked overview when both are present)

When running SAD vshift sweeps, each pair directory also includes:

- `sad_l1_vshift_grid.png` (per-vshift (w x d) grids stacked)
- `sad_l2_vshift_grid.png`
- `sad_l1_l2_vshift_grid.png`
- `sad_l1_vshift_map_grid.png` / `sad_l2_vshift_map_grid.png` (chosen-row visualizations)

When running Census vshift sweeps, each pair directory also includes:

- `census_hamming_vshift_grid.png` (one `census_window x max_disparity` panel per
  `(vshift, aggregation_window)` group, stacked vertically)
- `census_hamming_vshift_map_grid.png` (same layout, colored by chosen vertical offset)

When running SGBM vshift sweeps, each pair directory also includes:

- `sgbm_vshift_grid.png`
  - 1D layout (one row of vshifts) when only `--sgbm-vshifts` varies
  - Otherwise one `val_win x vshift` 2D grid per block_size, stacked vertically
- `sgbm_vshift_map_grid.png` (same layout, colored by chosen vertical offset)

When running an SGBM sweep, `summary.json` also contains:

- Per pair: `sgbm_vshift_best_by_valid_ratio` (winning config and output dir)
- Top level: `sgbm_vshift_leaderboard` (list of `(block_size, val_win, vshift)`
  configs sorted by mean valid-pixel ratio across all processed pairs, with
  `min`, `max`, and `mean_vshift_abs_mean` so you can spot which config
  generalizes best and which actually needed large vertical shifts)

When running Census sweeps, each pair directory also includes:

- `census_hamming_grid.png` (rows = census window sizes, cols = max disparities)
- Per census job folder:
  - `census_left_popcount.png`
  - `census_right_popcount.png`
  - `census_left_descriptor_rgb.png`
  - `census_right_descriptor_rgb.png`
  - `census_popcount_side_by_side.png`
  - `census_descriptor_side_by_side.png`
- Pair-level transform grids across parameters:
  - `census_popcount_side_by_side_grid.png`
  - `census_descriptor_side_by_side_grid.png`

