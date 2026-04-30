# Depth vs Baseline Visualizer

This tool visualizes stereo depth capability as you change camera spacing (baseline).

It is configured for your camera defaults:

- Horizontal FOV: `108 deg`
- Horizontal resolution: `320 px`

## What it shows

Given stereo geometry

- `Z = (f * B) / d`
- `f = (W/2) / tan(FOV/2)`

where `Z` is depth, `B` is baseline, `d` is disparity, and `f` is focal length in pixels,
the script generates:

- `depth_capability_vs_baseline.png`
  - Min/Max measurable depth vs baseline (using disparity limits)
  - Heatmap of absolute depth resolution error (m)
  - Heatmap of relative depth resolution error (%)
- `depth_error_at_target_distances.png`
  - Depth error vs baseline for fixed target depths
- `disparity_vs_distance.png`
  - Pixel disparity as a function of distance (for selected baselines)
- `baseline_depth_summary.csv`
  - Per-baseline min/max depth table

## Install

From `sterio-vision-python`:

```powershell
pip install numpy matplotlib
```

## Run

From `sterio-vision-python/depth-baseline-visualizer`:

```powershell
python visualize_depth_vs_baseline.py
```

Example custom sweep:

```powershell
python visualize_depth_vs_baseline.py `
  --fov-deg 108 `
  --image-width-px 320 `
  --baseline-min-cm 2 `
  --baseline-max-cm 40 `
  --baseline-steps 160 `
  --depth-min-m 0.2 `
  --depth-max-m 25 `
  --target-depths-m "1,2,3,5,10,15" `
  --disparity-baselines-cm "3,6,10,15,20" `
  --output-dir output `
  --show
```

Enable log-scale disparity axis (optional):

```powershell
python visualize_depth_vs_baseline.py --disparity-log-y
```

## Notes

- Larger baseline increases max measurable depth and improves depth resolution.
- Depth precision degrades approximately with `Z^2`, so far distances become rapidly less precise.
- `min-disparity-px` sets far-depth cutoff, and `max-disparity-px` sets near-depth cutoff.
