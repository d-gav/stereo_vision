# Stereo Depth System (From Scratch)

This folder contains a clean stereo-vision depth pipeline built from scratch for 8-bit grayscale stereo images.

## Features

- Pair discovery from `*_left.png` and `*_right.png`
- Explicit `--swap-inputs` support for reversed left/right naming
- Organized multi-method experiments:
  - `bm` (OpenCV StereoBM)
  - `sgbm` (OpenCV StereoSGBM)
  - `sad` (simple windowed Sum of Absolute Differences baseline)
- Relative depth map generation from disparity
- Structured output folders plus a machine-readable `summary.json`

## Install

```bash
pip install -r requirements.txt
```

## Run

```bash
python run_stereo_experiments.py \
  --input-dir "test-images-4-19/split" \
  --output-dir "test-images-4-19/depth-results" \
  --methods bm,sgbm,sad \
  --swap-inputs \
  --crop-height 288
```

## Output Structure

For each pair `<name>`, outputs are written to:

- `<output>/<name>/input_left_used.png`
- `<output>/<name>/input_right_used.png`
- `<output>/<name>/bm/...`
- `<output>/<name>/sgbm/...`
- `<output>/<name>/sad/...`

Each method directory contains:

- `disparity.npy`
- `depth_relative.npy`
- `disparity_preview.png`
- `depth_preview.png`
- `disparity_color.png`
- `depth_color.png`

`summary.json` includes key statistics and valid disparity ratio for quick comparison.

