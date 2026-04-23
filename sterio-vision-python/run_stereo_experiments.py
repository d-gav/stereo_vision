from __future__ import annotations

import argparse
import json
from pathlib import Path

from stereo_depth_system.config import StereoConfig
from stereo_depth_system.pipeline import run_pipeline


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run stereo depth experiments from scratch on grayscale image pairs."
    )
    parser.add_argument(
        "--input-dir",
        type=Path,
        required=True,
        help="Directory containing files like <name>_left.png and <name>_right.png",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        required=True,
        help="Directory where depth outputs and summaries will be written",
    )
    parser.add_argument(
        "--methods",
        type=str,
        default="bm,sgbm,sad_l1,census_hamming",
        help=(
            "Comma-separated list of methods: "
            "bm,sgbm,sad,sad_l1,sad_l2,sad_l1_vshift,sad_l2_vshift,sgbm_vshift,"
            "census,census_hamming,census_hamming_vshift"
        ),
    )
    parser.add_argument(
        "--swap-inputs",
        action="store_true",
        default=False,
        help="Swap left/right inputs before processing (use this if naming is reversed).",
    )
    parser.add_argument("--crop-height", type=int, default=288, help="Top crop height to use.")
    parser.add_argument("--no-clahe", action="store_true", help="Disable CLAHE preprocessing.")
    parser.add_argument("--median-blur-ksize", type=int, default=3, help="Median blur kernel size.")
    parser.add_argument("--bm-num-disp", type=int, default=128)
    parser.add_argument("--bm-block-size", type=int, default=15)
    parser.add_argument("--sgbm-num-disp", type=int, default=128)
    parser.add_argument("--sgbm-block-size", type=int, default=5)
    parser.add_argument("--sad-max-disparity", type=int, default=None, help="Legacy single-value SAD max disparity.")
    parser.add_argument("--sad-window-size", type=int, default=None, help="Legacy single-value SAD window size.")
    parser.add_argument(
        "--sad-max-disparities",
        type=str,
        default="96",
        help="Comma-separated SAD max disparity values, e.g. 32,48,64,96",
    )
    parser.add_argument(
        "--sad-window-sizes",
        type=str,
        default="9",
        help="Comma-separated SAD window sizes, e.g. 5,7,9,11",
    )
    parser.add_argument(
        "--sad-vshifts",
        type=str,
        default="2",
        help=(
            "Comma-separated SAD vertical shift radii for sad_l1_vshift/sad_l2_vshift, "
            "each V means search rows in [-V, +V]. Example: 0,2,4"
        ),
    )
    parser.add_argument(
        "--sgbm-vshifts",
        type=str,
        default="0,2,4",
        help=(
            "Comma-separated SGBM vertical shift radii for sgbm_vshift, "
            "each V means run SGBM for rows in [-V, +V] and pick best per pixel. Example: 0,2,4"
        ),
    )
    parser.add_argument(
        "--sgbm-vshift-block-sizes",
        type=str,
        default="5",
        help=(
            "Comma-separated SGBM block sizes to sweep inside the sgbm_vshift method. "
            "Even values are rounded up to the next odd number. Example: 3,5,7,9"
        ),
    )
    parser.add_argument(
        "--sgbm-vshift-validation-windows",
        type=str,
        default="7",
        help=(
            "Comma-separated window sizes for the per-pixel validation cost in sgbm_vshift. "
            "Example: 5,7,9"
        ),
    )
    parser.add_argument(
        "--sgbm-vshift-validation-window",
        type=int,
        default=None,
        help="(Legacy) single validation window for sgbm_vshift. Appended to --sgbm-vshift-validation-windows.",
    )
    parser.add_argument(
        "--census-max-disparities",
        type=str,
        default="48,64,96",
        help="Comma-separated Census max disparity values, e.g. 24,32,48,64",
    )
    parser.add_argument(
        "--census-window-sizes",
        type=str,
        default="5,7",
        help="Comma-separated Census window sizes, e.g. 5,7,9 (<=9 recommended)",
    )
    parser.add_argument(
        "--census-aggregation-window",
        type=int,
        default=5,
        help="Cost aggregation window for Census Hamming matcher (non-sweep).",
    )
    parser.add_argument(
        "--census-vshifts",
        type=str,
        default="2",
        help=(
            "Comma-separated Census vertical shift radii for census_hamming_vshift. "
            "Each V means search rows in [-V, +V]. Example: 0,2,4"
        ),
    )
    parser.add_argument(
        "--census-aggregation-windows",
        type=str,
        default="5",
        help=(
            "Comma-separated aggregation windows for census_hamming_vshift. "
            "Example: 1,3,5,7"
        ),
    )
    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()

    sad_max_disps = _parse_int_list(args.sad_max_disparities)
    sad_window_sizes = _parse_int_list(args.sad_window_sizes)
    sad_vshifts = _parse_int_list(args.sad_vshifts)
    sgbm_vshifts = _parse_int_list(args.sgbm_vshifts)
    sgbm_vshift_block_sizes = _parse_int_list(args.sgbm_vshift_block_sizes)
    sgbm_vshift_validation_windows = _parse_int_list(args.sgbm_vshift_validation_windows)
    if args.sgbm_vshift_validation_window is not None:
        sgbm_vshift_validation_windows.append(args.sgbm_vshift_validation_window)
    census_max_disps = _parse_int_list(args.census_max_disparities)
    census_window_sizes = _parse_int_list(args.census_window_sizes)
    census_vshifts = _parse_int_list(args.census_vshifts)
    census_vshift_aggregation_windows = _parse_int_list(args.census_aggregation_windows)

    # Backward-compatible single value flags are appended when provided.
    if args.sad_max_disparity is not None:
        sad_max_disps.append(args.sad_max_disparity)
    if args.sad_window_size is not None:
        sad_window_sizes.append(args.sad_window_size)

    sad_max_disps = _unique_preserve_order([max(1, v) for v in sad_max_disps]) or [96]
    sad_window_sizes = _unique_preserve_order([max(3, v) if v % 2 == 1 else max(3, v + 1) for v in sad_window_sizes]) or [9]
    sad_vshifts = _unique_preserve_order([max(0, v) for v in sad_vshifts]) or [2]
    sgbm_vshifts = _unique_preserve_order([max(0, v) for v in sgbm_vshifts]) or [0, 2, 4]
    sgbm_vshift_block_sizes = _unique_preserve_order(
        [max(3, v) if v % 2 == 1 else max(3, v + 1) for v in sgbm_vshift_block_sizes]
    ) or [5]
    sgbm_vshift_validation_windows = _unique_preserve_order(
        [max(3, v) if v % 2 == 1 else max(3, v + 1) for v in sgbm_vshift_validation_windows]
    ) or [7]
    census_max_disps = _unique_preserve_order([max(1, v) for v in census_max_disps]) or [64]
    census_window_sizes = _unique_preserve_order(
        [max(3, v) if v % 2 == 1 else max(3, v + 1) for v in census_window_sizes]
    ) or [7]
    census_vshifts = _unique_preserve_order([max(0, v) for v in census_vshifts]) or [2]
    census_vshift_aggregation_windows = _unique_preserve_order(
        [max(1, v) if v % 2 == 1 else max(1, v + 1) for v in census_vshift_aggregation_windows]
    ) or [5]

    cfg = StereoConfig(
        input_dir=args.input_dir,
        output_dir=args.output_dir,
        methods=[m.strip() for m in args.methods.split(",") if m.strip()],
        swap_inputs=args.swap_inputs,
        crop_height=args.crop_height if args.crop_height > 0 else None,
        use_clahe=not args.no_clahe,
        median_blur_ksize=args.median_blur_ksize,
        bm_num_disparities=args.bm_num_disp,
        bm_block_size=args.bm_block_size,
        sgbm_num_disparities=args.sgbm_num_disp,
        sgbm_block_size=args.sgbm_block_size,
        sad_max_disparities=sad_max_disps,
        sad_window_sizes=sad_window_sizes,
        sad_vshift_values=sad_vshifts,
        sgbm_vshift_values=sgbm_vshifts,
        sgbm_vshift_block_sizes=sgbm_vshift_block_sizes,
        sgbm_vshift_validation_windows=sgbm_vshift_validation_windows,
        sgbm_vshift_validation_window=sgbm_vshift_validation_windows[0],
        census_max_disparities=census_max_disps,
        census_window_sizes=census_window_sizes,
        census_aggregation_window=max(1, args.census_aggregation_window),
        census_vshift_values=census_vshifts,
        census_vshift_aggregation_windows=census_vshift_aggregation_windows,
    )

    summary = run_pipeline(cfg)
    print(json.dumps(summary, indent=2))


def _parse_int_list(value: str) -> list[int]:
    items = []
    for token in value.split(","):
        t = token.strip()
        if not t:
            continue
        items.append(int(t))
    return items


def _unique_preserve_order(values: list[int]) -> list[int]:
    seen = set()
    out = []
    for v in values:
        if v not in seen:
            seen.add(v)
            out.append(v)
    return out


if __name__ == "__main__":
    main()

