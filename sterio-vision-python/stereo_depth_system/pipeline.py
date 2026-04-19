from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, List

import cv2
import numpy as np

from .config import StereoConfig
from .depth import disparity_to_relative_depth
from .io_utils import (
    ensure_dir,
    find_stereo_pairs,
    load_grayscale,
    normalize_for_display,
    save_float_map,
    save_preview_png,
)
from .methods import get_methods
from .preprocess import preprocess_image


def run_pipeline(cfg: StereoConfig) -> Dict[str, Any]:
    ensure_dir(cfg.output_dir)
    methods = get_methods()
    selected = [m.lower().strip() for m in cfg.methods if m.strip()]
    unknown = [m for m in selected if m not in methods]
    if unknown:
        raise ValueError(f"Unknown methods: {unknown}. Available: {sorted(methods.keys())}")

    pairs = find_stereo_pairs(cfg.input_dir)
    if not pairs:
        raise ValueError(f"No stereo pairs found in {cfg.input_dir}. Expected *_left.png and *_right.png.")

    summary: Dict[str, Any] = {
        "input_dir": str(cfg.input_dir),
        "output_dir": str(cfg.output_dir),
        "swap_inputs": cfg.swap_inputs,
        "methods": selected,
        "pairs_processed": [],
    }

    for pair_name, left_path, right_path in pairs:
        left = load_grayscale(left_path)
        right = load_grayscale(right_path)

        if cfg.swap_inputs:
            left, right = right, left

        left = preprocess_image(left, cfg.crop_height, cfg.use_clahe, cfg.median_blur_ksize)
        right = preprocess_image(right, cfg.crop_height, cfg.use_clahe, cfg.median_blur_ksize)

        if left.shape != right.shape:
            h = min(left.shape[0], right.shape[0])
            w = min(left.shape[1], right.shape[1])
            left = left[:h, :w]
            right = right[:h, :w]

        pair_result: Dict[str, Any] = {
            "pair_name": pair_name,
            "left_source": str(left_path),
            "right_source": str(right_path),
            "shape_used": [int(left.shape[0]), int(left.shape[1])],
            "method_results": [],
        }

        pair_out_dir = cfg.output_dir / pair_name
        ensure_dir(pair_out_dir)
        cv2.imwrite(str(pair_out_dir / "input_left_used.png"), left)
        cv2.imwrite(str(pair_out_dir / "input_right_used.png"), right)

        for method_name in selected:
            method_out_dir = pair_out_dir / method_name
            ensure_dir(method_out_dir)

            disparity = methods[method_name](left, right, cfg)
            depth = disparity_to_relative_depth(disparity)

            save_float_map(method_out_dir / "disparity.npy", disparity)
            save_float_map(method_out_dir / "depth_relative.npy", depth)
            save_preview_png(method_out_dir / "disparity_preview.png", disparity)
            save_preview_png(method_out_dir / "depth_preview.png", depth)

            color_disp = cv2.applyColorMap(normalize_for_display(disparity), cv2.COLORMAP_TURBO)
            color_depth = cv2.applyColorMap(normalize_for_display(depth), cv2.COLORMAP_VIRIDIS)
            cv2.imwrite(str(method_out_dir / "disparity_color.png"), color_disp)
            cv2.imwrite(str(method_out_dir / "depth_color.png"), color_depth)

            pair_result["method_results"].append(_stats_for_method(method_name, disparity, depth, method_out_dir))

        summary["pairs_processed"].append(pair_result)

    with (cfg.output_dir / "summary.json").open("w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)

    return summary


def _stats_for_method(
    method_name: str,
    disparity: np.ndarray,
    depth: np.ndarray,
    method_out_dir: Path,
) -> Dict[str, Any]:
    valid = np.isfinite(disparity) & (disparity > 0)
    valid_count = int(valid.sum())
    total = int(disparity.size)

    if valid_count > 0:
        disp_vals = disparity[valid]
        depth_vals = depth[valid]
        disp_min, disp_max = float(np.min(disp_vals)), float(np.max(disp_vals))
        depth_min, depth_max = float(np.min(depth_vals)), float(np.max(depth_vals))
    else:
        disp_min = disp_max = depth_min = depth_max = None

    return {
        "method": method_name,
        "output_dir": str(method_out_dir),
        "valid_pixel_ratio": float(valid_count / total) if total else 0.0,
        "disparity_min": disp_min,
        "disparity_max": disp_max,
        "depth_relative_min": depth_min,
        "depth_relative_max": depth_max,
    }

