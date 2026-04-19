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
        default="bm,sgbm,sad",
        help="Comma-separated list of methods: bm,sgbm,sad",
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
    parser.add_argument("--sad-max-disparity", type=int, default=96)
    parser.add_argument("--sad-window-size", type=int, default=9)
    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()

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
        sad_max_disparity=args.sad_max_disparity,
        sad_window_size=args.sad_window_size,
    )

    summary = run_pipeline(cfg)
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()

