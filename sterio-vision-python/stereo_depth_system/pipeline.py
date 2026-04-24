from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any, Dict, List, Tuple

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
from .methods import (
    compute_census_descriptors,
    compute_census_debug_views,
    compute_census_hamming_custom,
    compute_census_hamming_custom_vshift,
    compute_sad_custom,
    compute_sad_custom_vshift,
    compute_sgbm_vshift,
    get_methods,
    render_vshift_preview,
)
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

    method_jobs = _build_method_jobs(cfg, selected)

    summary: Dict[str, Any] = {
        "input_dir": str(cfg.input_dir),
        "output_dir": str(cfg.output_dir),
        "swap_inputs": cfg.swap_inputs,
        "methods": selected,
        "method_jobs": [job["name"] for job in method_jobs],
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
        sad_grid_cells: Dict[str, Dict[Tuple[Tuple[int, int], int], np.ndarray]] = {"l1": {}, "l2": {}}
        sad_vshift_disp_cells: Dict[str, Dict[Tuple[int, int, int, int], np.ndarray]] = {"l1": {}, "l2": {}}
        sad_vshift_map_cells: Dict[str, Dict[Tuple[int, int, int, int], np.ndarray]] = {"l1": {}, "l2": {}}
        sgbm_vshift_disp_cells: Dict[Tuple[int, int, int], np.ndarray] = {}
        sgbm_vshift_map_cells: Dict[Tuple[int, int, int], np.ndarray] = {}
        census_grid_cells: Dict[Tuple[int, int], np.ndarray] = {}
        census_popcount_pair_cells: Dict[Tuple[int, int], np.ndarray] = {}
        census_descriptor_pair_cells: Dict[Tuple[int, int], np.ndarray] = {}
        census_vshift_disp_cells: Dict[Tuple[int, int, int, int], np.ndarray] = {}
        census_vshift_map_cells: Dict[Tuple[int, int, int, int], np.ndarray] = {}
        census_descriptor_cache: Dict[int, Tuple[np.ndarray, np.ndarray]] = {}
        census_debug_cache: Dict[int, Dict[str, np.ndarray]] = {}

        pair_out_dir = cfg.output_dir / pair_name
        pair_runs_dir = pair_out_dir / "runs"
        pair_grids_dir = pair_out_dir / "grids"
        ensure_dir(pair_out_dir)
        ensure_dir(pair_runs_dir)
        ensure_dir(pair_grids_dir)
        cv2.imwrite(str(pair_out_dir / "input_left_used.png"), left)
        cv2.imwrite(str(pair_out_dir / "input_right_used.png"), right)

        def _get_census_descriptors_for_window(window_size: int) -> Tuple[np.ndarray, np.ndarray]:
            w_key = int(window_size)
            cached = census_descriptor_cache.get(w_key)
            if cached is not None:
                return cached
            left_bytes, right_bytes = compute_census_descriptors(left, right, w_key)
            census_descriptor_cache[w_key] = (left_bytes, right_bytes)
            return left_bytes, right_bytes

        def _get_census_debug_assets(window_size: int) -> Dict[str, np.ndarray]:
            w_key = int(window_size)
            cached = census_debug_cache.get(w_key)
            if cached is not None:
                return cached
            left_desc, right_desc = _get_census_descriptors_for_window(w_key)
            left_debug = compute_census_debug_views(left, w_key, descriptor=left_desc)
            right_debug = compute_census_debug_views(right, w_key, descriptor=right_desc)
            popcount_side = _merge_left_right_debug(
                left_debug["census_popcount"],
                right_debug["census_popcount"],
                left_title="Left popcount",
                right_title="Right popcount",
            )
            descriptor_side = _merge_left_right_debug(
                left_debug["census_descriptor_rgb"],
                right_debug["census_descriptor_rgb"],
                left_title="Left descriptor",
                right_title="Right descriptor",
            )
            assets = {
                "left_popcount": left_debug["census_popcount"],
                "right_popcount": right_debug["census_popcount"],
                "left_descriptor_rgb": left_debug["census_descriptor_rgb"],
                "right_descriptor_rgb": right_debug["census_descriptor_rgb"],
                "popcount_side": popcount_side,
                "descriptor_side": descriptor_side,
            }
            census_debug_cache[w_key] = assets
            return assets

        for job in method_jobs:
            method_name = job["name"]
            method_out_dir = pair_runs_dir / method_name
            ensure_dir(method_out_dir)
            vshift_map: np.ndarray | None = None
            vshift_value_used: int | None = None

            if job["type"] == "sad":
                disparity = compute_sad_custom(
                    left=left,
                    right=right,
                    max_disparity=int(job["max_disparity"]),
                    window_width=int(job["window_width"]),
                    window_height=int(job["window_height"]),
                    min_disparity=0,
                    cost_mode=job["cost_mode"],
                )
            elif job["type"] == "sad_vshift":
                vshift_value_used = int(job["max_vertical_shift"])
                disparity, vshift_map = compute_sad_custom_vshift(
                    left=left,
                    right=right,
                    max_disparity=int(job["max_disparity"]),
                    window_width=int(job["window_width"]),
                    window_height=int(job["window_height"]),
                    min_disparity=0,
                    max_vertical_shift=vshift_value_used,
                    cost_mode=job["cost_mode"],
                )
            elif job["type"] == "sgbm_vshift":
                vshift_value_used = int(job["max_vertical_shift"])
                disparity, vshift_map = compute_sgbm_vshift(
                    left=left,
                    right=right,
                    num_disparities=cfg.sgbm_num_disparities,
                    block_size=int(job.get("block_size", cfg.sgbm_block_size)),
                    max_vertical_shift=vshift_value_used,
                    min_disparity=cfg.min_disparity,
                    validation_window=int(job.get("validation_window", cfg.sgbm_vshift_validation_window)),
                    validation_height_scale=cfg.sgbm_vshift_validation_height_scale,
                )
            elif job["type"] == "census":
                win = int(job["window_size"])
                left_desc, right_desc = _get_census_descriptors_for_window(win)
                disparity = compute_census_hamming_custom(
                    left=left,
                    right=right,
                    max_disparity=int(job["max_disparity"]),
                    census_window=win,
                    aggregation_window=int(job["aggregation_window"]),
                    min_disparity=cfg.min_disparity,
                    left_desc=left_desc,
                    right_desc=right_desc,
                )
                debug_assets = _get_census_debug_assets(win)
                cv2.imwrite(str(method_out_dir / "census_left_popcount.png"), debug_assets["left_popcount"])
                cv2.imwrite(str(method_out_dir / "census_right_popcount.png"), debug_assets["right_popcount"])
                cv2.imwrite(str(method_out_dir / "census_left_descriptor_rgb.png"), debug_assets["left_descriptor_rgb"])
                cv2.imwrite(str(method_out_dir / "census_right_descriptor_rgb.png"), debug_assets["right_descriptor_rgb"])
                cv2.imwrite(str(method_out_dir / "census_popcount_side_by_side.png"), debug_assets["popcount_side"])
                cv2.imwrite(str(method_out_dir / "census_descriptor_side_by_side.png"), debug_assets["descriptor_side"])
                popcount_side = debug_assets["popcount_side"]
                descriptor_side = debug_assets["descriptor_side"]
            elif job["type"] == "census_vshift":
                vshift_value_used = int(job["max_vertical_shift"])
                win = int(job["window_size"])
                left_desc, right_desc = _get_census_descriptors_for_window(win)
                disparity, vshift_map = compute_census_hamming_custom_vshift(
                    left=left,
                    right=right,
                    max_disparity=int(job["max_disparity"]),
                    census_window=win,
                    aggregation_window=int(job["aggregation_window"]),
                    max_vertical_shift=vshift_value_used,
                    min_disparity=cfg.min_disparity,
                    left_desc=left_desc,
                    right_desc=right_desc,
                )
                debug_assets = _get_census_debug_assets(win)
                cv2.imwrite(str(method_out_dir / "census_left_popcount.png"), debug_assets["left_popcount"])
                cv2.imwrite(str(method_out_dir / "census_right_popcount.png"), debug_assets["right_popcount"])
                cv2.imwrite(str(method_out_dir / "census_left_descriptor_rgb.png"), debug_assets["left_descriptor_rgb"])
                cv2.imwrite(str(method_out_dir / "census_right_descriptor_rgb.png"), debug_assets["right_descriptor_rgb"])
                cv2.imwrite(str(method_out_dir / "census_popcount_side_by_side.png"), debug_assets["popcount_side"])
                cv2.imwrite(str(method_out_dir / "census_descriptor_side_by_side.png"), debug_assets["descriptor_side"])
            else:
                disparity = methods[job["method"]](left, right, cfg)

            # For SAD variants, keep full disparity search but post-mask tiny disparities
            # so noise is visualized as invalid (dark blue in colormaps).
            if job["type"] in {"sad", "sad_vshift"} and cfg.min_disparity > 0:
                low_disp_mask = np.isfinite(disparity) & (disparity < float(cfg.min_disparity))
                disparity[low_disp_mask] = np.nan
                if vshift_map is not None:
                    vshift_map[low_disp_mask] = np.nan
            depth = disparity_to_relative_depth(disparity)

            save_float_map(method_out_dir / "disparity.npy", disparity)
            save_float_map(method_out_dir / "depth_relative.npy", depth)
            save_preview_png(method_out_dir / "disparity_preview.png", disparity)
            save_preview_png(method_out_dir / "depth_preview.png", depth)

            color_disp = cv2.applyColorMap(normalize_for_display(disparity), cv2.COLORMAP_TURBO)
            color_depth = cv2.applyColorMap(normalize_for_display(depth), cv2.COLORMAP_VIRIDIS)
            cv2.imwrite(str(method_out_dir / "disparity_color.png"), color_disp)
            cv2.imwrite(str(method_out_dir / "depth_color.png"), color_depth)

            vshift_color: np.ndarray | None = None
            if vshift_map is not None and vshift_value_used is not None:
                save_float_map(method_out_dir / "vshift_map.npy", vshift_map)
                save_preview_png(method_out_dir / "vshift_preview.png", vshift_map)
                vshift_color = render_vshift_preview(vshift_map, vshift_value_used)
                cv2.imwrite(str(method_out_dir / "vshift_color.png"), vshift_color)

            sad_meta = _parse_sad_variant(method_name)
            if sad_meta is not None:
                sad_window = (int(sad_meta["window_height"]), int(sad_meta["window_width"]))
                sad_grid_cells[sad_meta["cost_mode"]][(sad_window, int(sad_meta["max_disparity"]))] = color_disp

            sad_vshift_meta = _parse_sad_vshift_variant(method_name)
            if sad_vshift_meta is not None:
                key = (
                    int(sad_vshift_meta["vshift"]),
                    int(sad_vshift_meta["window_height"]),
                    int(sad_vshift_meta["window_width"]),
                    int(sad_vshift_meta["max_disparity"]),
                )
                sad_vshift_disp_cells[sad_vshift_meta["cost_mode"]][key] = color_disp
                if vshift_color is not None:
                    sad_vshift_map_cells[sad_vshift_meta["cost_mode"]][key] = vshift_color

            sgbm_vshift_meta = _parse_sgbm_vshift_variant(method_name)
            if sgbm_vshift_meta is not None:
                key = (
                    sgbm_vshift_meta["block_size"],
                    sgbm_vshift_meta["validation_window"],
                    sgbm_vshift_meta["vshift"],
                )
                sgbm_vshift_disp_cells[key] = color_disp
                if vshift_color is not None:
                    sgbm_vshift_map_cells[key] = vshift_color

            census_meta = _parse_census_variant(method_name)
            if census_meta is not None:
                census_grid_cells[(census_meta["window_size"], census_meta["max_disparity"])] = color_disp
                census_popcount_pair_cells[(census_meta["window_size"], census_meta["max_disparity"])] = popcount_side
                census_descriptor_pair_cells[(census_meta["window_size"], census_meta["max_disparity"])] = descriptor_side

            census_vshift_meta = _parse_census_vshift_variant(method_name)
            if census_vshift_meta is not None:
                key = (
                    census_vshift_meta["vshift"],
                    census_vshift_meta["aggregation_window"],
                    census_vshift_meta["window_size"],
                    census_vshift_meta["max_disparity"],
                )
                census_vshift_disp_cells[key] = color_disp
                if vshift_color is not None:
                    census_vshift_map_cells[key] = vshift_color

            method_stats = _stats_for_method(method_name, disparity, depth, method_out_dir)
            if vshift_map is not None and vshift_value_used is not None:
                method_stats.update(_vshift_stats(vshift_map, vshift_value_used))
            pair_result["method_results"].append(method_stats)

        grid_paths = _write_sad_grids(pair_grids_dir, sad_grid_cells)
        if grid_paths:
            pair_result["sad_grid_paths"] = grid_paths
        sad_vshift_grid_paths = _write_sad_vshift_grids(
            pair_out_dir=pair_grids_dir,
            sad_vshift_disp_cells=sad_vshift_disp_cells,
            sad_vshift_map_cells=sad_vshift_map_cells,
            row_param=cfg.sad_vshift_grid_row_param,
            col_param=cfg.sad_vshift_grid_col_param,
            panel_param=cfg.sad_vshift_grid_panel_param,
        )
        if sad_vshift_grid_paths:
            pair_result["sad_vshift_grid_paths"] = sad_vshift_grid_paths
        sgbm_vshift_grid_paths = _write_sgbm_vshift_grids(
            pair_out_dir=pair_grids_dir,
            sgbm_vshift_disp_cells=sgbm_vshift_disp_cells,
            sgbm_vshift_map_cells=sgbm_vshift_map_cells,
        )
        if sgbm_vshift_grid_paths:
            pair_result["sgbm_vshift_grid_paths"] = sgbm_vshift_grid_paths

        best_sgbm = _pick_best_sgbm_vshift(pair_result["method_results"])
        if best_sgbm is not None:
            pair_result["sgbm_vshift_best_by_valid_ratio"] = {
                "method": best_sgbm["method"],
                "valid_pixel_ratio": best_sgbm["valid_pixel_ratio"],
                "vshift_abs_mean": best_sgbm.get("vshift_abs_mean"),
                "output_dir": best_sgbm["output_dir"],
            }
        census_grid_paths = _write_census_grids(pair_grids_dir, census_grid_cells)
        if census_grid_paths:
            pair_result["census_grid_paths"] = census_grid_paths
        census_transform_grid_paths = _write_census_transform_grids(
            pair_out_dir=pair_grids_dir,
            census_popcount_pair_cells=census_popcount_pair_cells,
            census_descriptor_pair_cells=census_descriptor_pair_cells,
        )
        if census_transform_grid_paths:
            pair_result["census_transform_grid_paths"] = census_transform_grid_paths
        census_vshift_grid_paths = _write_census_vshift_grids(
            pair_out_dir=pair_grids_dir,
            census_vshift_disp_cells=census_vshift_disp_cells,
            census_vshift_map_cells=census_vshift_map_cells,
        )
        if census_vshift_grid_paths:
            pair_result["census_vshift_grid_paths"] = census_vshift_grid_paths

        best_census_vshift = _pick_best_census_vshift(pair_result["method_results"])
        if best_census_vshift is not None:
            pair_result["census_vshift_best_by_valid_ratio"] = {
                "method": best_census_vshift["method"],
                "valid_pixel_ratio": best_census_vshift["valid_pixel_ratio"],
                "vshift_abs_mean": best_census_vshift.get("vshift_abs_mean"),
                "output_dir": best_census_vshift["output_dir"],
            }

        summary["pairs_processed"].append(pair_result)

    sgbm_vshift_leaderboard = _sgbm_vshift_leaderboard(summary["pairs_processed"])
    if sgbm_vshift_leaderboard:
        summary["sgbm_vshift_leaderboard"] = sgbm_vshift_leaderboard
    census_vshift_leaderboard = _census_vshift_leaderboard(summary["pairs_processed"])
    if census_vshift_leaderboard:
        summary["census_vshift_leaderboard"] = census_vshift_leaderboard

    with (cfg.output_dir / "summary.json").open("w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)

    return summary


def _build_method_jobs(cfg: StereoConfig, selected: List[str]) -> List[Dict[str, Any]]:
    jobs: List[Dict[str, Any]] = []
    max_disps = [max(1, int(v)) for v in cfg.sad_max_disparities]
    raw_widths = cfg.sad_window_widths or cfg.sad_window_sizes
    raw_heights = cfg.sad_window_heights or cfg.sad_window_sizes
    sad_widths = _unique_preserve_order_ints([_ensure_odd_min(v, 3) for v in raw_widths]) or [9]
    sad_heights = _unique_preserve_order_ints([_ensure_odd_min(v, 3) for v in raw_heights]) or [9]
    sad_vshifts = [max(0, int(v)) for v in cfg.sad_vshift_values] or [0]
    sgbm_vshifts = [max(0, int(v)) for v in cfg.sgbm_vshift_values] or [0]
    census_disps = [max(1, int(v)) for v in cfg.census_max_disparities]
    census_windows = [max(3, int(v)) for v in cfg.census_window_sizes]
    census_agg = max(1, int(cfg.census_aggregation_window))

    for method in selected:
        if method in {"sad", "sad_l1"}:
            for d in max_disps:
                for h in sad_heights:
                    for w in sad_widths:
                        jobs.append(
                            {
                                "name": f"sad_l1_d{d}_h{h}_w{w}",
                                "type": "sad",
                                "method": method,
                                "cost_mode": "l1",
                                "max_disparity": d,
                                "window_width": w,
                                "window_height": h,
                            }
                        )
        elif method == "sad_l2":
            for d in max_disps:
                for h in sad_heights:
                    for w in sad_widths:
                        jobs.append(
                            {
                                "name": f"sad_l2_d{d}_h{h}_w{w}",
                                "type": "sad",
                                "method": method,
                                "cost_mode": "l2",
                                "max_disparity": d,
                                "window_width": w,
                                "window_height": h,
                            }
                        )
        elif method in {"sad_vshift", "sad_l1_vshift"}:
            for v in sad_vshifts:
                for d in max_disps:
                    for h in sad_heights:
                        for w in sad_widths:
                            jobs.append(
                                {
                                    "name": f"sad_l1_vs{v}_d{d}_h{h}_w{w}",
                                    "type": "sad_vshift",
                                    "method": method,
                                    "cost_mode": "l1",
                                    "max_disparity": d,
                                    "window_width": w,
                                    "window_height": h,
                                    "max_vertical_shift": v,
                                }
                            )
        elif method == "sad_l2_vshift":
            for v in sad_vshifts:
                for d in max_disps:
                    for h in sad_heights:
                        for w in sad_widths:
                            jobs.append(
                                {
                                    "name": f"sad_l2_vs{v}_d{d}_h{h}_w{w}",
                                    "type": "sad_vshift",
                                    "method": method,
                                    "cost_mode": "l2",
                                    "max_disparity": d,
                                    "window_width": w,
                                    "window_height": h,
                                    "max_vertical_shift": v,
                                }
                            )
        elif method == "sgbm_vshift":
            raw_bs = [_ensure_odd_min(v, 3) for v in cfg.sgbm_vshift_block_sizes]
            raw_vw = [_ensure_odd_min(v, 3) for v in cfg.sgbm_vshift_validation_windows]
            if not raw_bs:
                raw_bs = [_ensure_odd_min(int(cfg.sgbm_block_size), 3)]
            if not raw_vw:
                raw_vw = [_ensure_odd_min(int(cfg.sgbm_vshift_validation_window), 3)]
            bs_list = _unique_preserve_order_ints(raw_bs)
            vw_list = _unique_preserve_order_ints(raw_vw)
            for bs in bs_list:
                for vw in vw_list:
                    for v in sgbm_vshifts:
                        jobs.append(
                            {
                                "name": f"sgbm_bs{bs}_vw{vw}_vs{v}",
                                "type": "sgbm_vshift",
                                "method": method,
                                "max_vertical_shift": v,
                                "block_size": bs,
                                "validation_window": vw,
                            }
                        )
        elif method in {"census", "census_hamming"}:
            for d in census_disps:
                for w in census_windows:
                    jobs.append(
                        {
                            "name": f"census_hamming_d{d}_w{w}",
                            "type": "census",
                            "method": method,
                            "max_disparity": d,
                            "window_size": w,
                            "aggregation_window": census_agg,
                        }
                    )
        elif method in {"census_vshift", "census_hamming_vshift"}:
            census_vshifts_raw = [max(0, int(v)) for v in cfg.census_vshift_values]
            census_vshifts = _unique_preserve_order_ints(census_vshifts_raw) or [0]
            census_agg_raw = [_ensure_odd_min(v, 1) for v in cfg.census_vshift_aggregation_windows]
            if not census_agg_raw:
                census_agg_raw = [_ensure_odd_min(int(cfg.census_aggregation_window), 1)]
            census_aggs = _unique_preserve_order_ints(census_agg_raw)
            for v in census_vshifts:
                for a in census_aggs:
                    for d in census_disps:
                        for w in census_windows:
                            jobs.append(
                                {
                                    "name": f"census_hamming_vs{v}_aw{a}_d{d}_w{w}",
                                    "type": "census_vshift",
                                    "method": method,
                                    "max_disparity": d,
                                    "window_size": w,
                                    "aggregation_window": a,
                                    "max_vertical_shift": v,
                                }
                            )
        else:
            jobs.append({"name": method, "type": "default", "method": method})

    return jobs


def _parse_sad_variant(method_name: str) -> Dict[str, int | str] | None:
    match = re.fullmatch(r"sad_(l1|l2)_d(\d+)_h(\d+)_w(\d+)", method_name)
    if match:
        return {
            "cost_mode": match.group(1),
            "max_disparity": int(match.group(2)),
            "window_height": int(match.group(3)),
            "window_width": int(match.group(4)),
        }
    match_legacy = re.fullmatch(r"sad_(l1|l2)_d(\d+)_w(\d+)", method_name)
    if match_legacy:
        w = int(match_legacy.group(3))
        return {
            "cost_mode": match_legacy.group(1),
            "max_disparity": int(match_legacy.group(2)),
            "window_height": w,
            "window_width": w,
        }
    return None


def _parse_sad_vshift_variant(method_name: str) -> Dict[str, int | str] | None:
    match = re.fullmatch(r"sad_(l1|l2)_vs(\d+)_d(\d+)_h(\d+)_w(\d+)", method_name)
    if match:
        return {
            "cost_mode": match.group(1),
            "vshift": int(match.group(2)),
            "max_disparity": int(match.group(3)),
            "window_height": int(match.group(4)),
            "window_width": int(match.group(5)),
        }
    match_legacy = re.fullmatch(r"sad_(l1|l2)_vs(\d+)_d(\d+)_w(\d+)", method_name)
    if match_legacy:
        w = int(match_legacy.group(4))
        return {
            "cost_mode": match_legacy.group(1),
            "vshift": int(match_legacy.group(2)),
            "max_disparity": int(match_legacy.group(3)),
            "window_height": w,
            "window_width": w,
        }
    return None


def _parse_sgbm_vshift_variant(method_name: str) -> Dict[str, int] | None:
    match = re.fullmatch(r"sgbm_bs(\d+)_vw(\d+)_vs(\d+)", method_name)
    if match:
        return {
            "block_size": int(match.group(1)),
            "validation_window": int(match.group(2)),
            "vshift": int(match.group(3)),
        }
    # Backwards compatible with the original sgbm_vs{V} naming.
    match_legacy = re.fullmatch(r"sgbm_vs(\d+)", method_name)
    if match_legacy:
        return {
            "block_size": -1,
            "validation_window": -1,
            "vshift": int(match_legacy.group(1)),
        }
    return None


def _parse_census_variant(method_name: str) -> Dict[str, int] | None:
    match = re.fullmatch(r"census_hamming_d(\d+)_w(\d+)", method_name)
    if not match:
        return None
    return {
        "max_disparity": int(match.group(1)),
        "window_size": int(match.group(2)),
    }


def _parse_census_vshift_variant(method_name: str) -> Dict[str, int] | None:
    match = re.fullmatch(r"census_hamming_vs(\d+)_aw(\d+)_d(\d+)_w(\d+)", method_name)
    if not match:
        return None
    return {
        "vshift": int(match.group(1)),
        "aggregation_window": int(match.group(2)),
        "max_disparity": int(match.group(3)),
        "window_size": int(match.group(4)),
    }


def _write_sad_grids(
    pair_out_dir: Path,
    sad_grid_cells: Dict[str, Dict[Tuple[Tuple[int, int], int], np.ndarray]],
) -> Dict[str, str]:
    out: Dict[str, str] = {}
    rendered: Dict[str, np.ndarray] = {}

    for cost_mode in ("l1", "l2"):
        cells = sad_grid_cells[cost_mode]
        if not cells:
            continue

        windows = sorted({k[0] for k in cells.keys()})
        max_disparities = sorted({k[1] for k in cells.keys()})
        title = f"SAD {cost_mode.upper()} disparity grid"
        grid = _build_labeled_grid(cells, windows, max_disparities, title)

        path = pair_out_dir / f"sad_{cost_mode}_grid.png"
        cv2.imwrite(str(path), grid)
        out[f"sad_{cost_mode}_grid"] = str(path)
        rendered[cost_mode] = grid

    if "l1" in rendered and "l2" in rendered:
        combined = _stack_with_padding([rendered["l1"], rendered["l2"]], gap=16)
        combined_path = pair_out_dir / "sad_l1_l2_grid.png"
        cv2.imwrite(str(combined_path), combined)
        out["sad_l1_l2_grid"] = str(combined_path)

    return out


def _write_census_grids(
    pair_out_dir: Path,
    census_grid_cells: Dict[Tuple[int, int], np.ndarray],
) -> Dict[str, str]:
    if not census_grid_cells:
        return {}

    windows = sorted({k[0] for k in census_grid_cells.keys()})
    max_disparities = sorted({k[1] for k in census_grid_cells.keys()})
    grid = _build_labeled_grid(
        cells=census_grid_cells,
        windows=windows,
        max_disparities=max_disparities,
        title="Census + Hamming disparity grid",
    )
    path = pair_out_dir / "census_hamming_grid.png"
    cv2.imwrite(str(path), grid)
    return {"census_hamming_grid": str(path)}


def _write_census_transform_grids(
    pair_out_dir: Path,
    census_popcount_pair_cells: Dict[Tuple[int, int], np.ndarray],
    census_descriptor_pair_cells: Dict[Tuple[int, int], np.ndarray],
) -> Dict[str, str]:
    out: Dict[str, str] = {}

    if census_popcount_pair_cells:
        windows = sorted({k[0] for k in census_popcount_pair_cells.keys()})
        max_disparities = sorted({k[1] for k in census_popcount_pair_cells.keys()})
        grid = _build_labeled_grid(
            cells=census_popcount_pair_cells,
            windows=windows,
            max_disparities=max_disparities,
            title="Census popcount (Left | Right)",
        )
        path = pair_out_dir / "census_popcount_side_by_side_grid.png"
        cv2.imwrite(str(path), grid)
        out["census_popcount_side_by_side_grid"] = str(path)

    if census_descriptor_pair_cells:
        windows = sorted({k[0] for k in census_descriptor_pair_cells.keys()})
        max_disparities = sorted({k[1] for k in census_descriptor_pair_cells.keys()})
        grid = _build_labeled_grid(
            cells=census_descriptor_pair_cells,
            windows=windows,
            max_disparities=max_disparities,
            title="Census descriptor RGB (Left | Right)",
        )
        path = pair_out_dir / "census_descriptor_side_by_side_grid.png"
        cv2.imwrite(str(path), grid)
        out["census_descriptor_side_by_side_grid"] = str(path)

    return out


def _write_sad_vshift_grids(
    pair_out_dir: Path,
    sad_vshift_disp_cells: Dict[str, Dict[Tuple[int, int, int, int], np.ndarray]],
    sad_vshift_map_cells: Dict[str, Dict[Tuple[int, int, int, int], np.ndarray]],
    row_param: str,
    col_param: str,
    panel_param: str,
) -> Dict[str, str]:
    """Build grids for SAD-with-vertical-shift experiments.

    For each cost mode, produce one (row_param x col_param) panel per panel_param
    value. Any remaining parameters not assigned to row/col/panel are grouped into
    separate panel sets and included in panel titles.
    """
    out: Dict[str, str] = {}
    rendered_disp: Dict[str, np.ndarray] = {}
    valid_params = {"window_height", "window_width", "vshift", "max_disparity"}
    row = row_param if row_param in valid_params else "window_height"
    col = col_param if col_param in valid_params else "vshift"
    panel = panel_param if panel_param in valid_params else "max_disparity"
    if col == row:
        # Keep user intent for rows, fallback columns to vshift.
        col = "vshift" if row != "vshift" else "window_width"
    if panel == row or panel == col:
        for candidate in ("max_disparity", "vshift", "window_height", "window_width"):
            if candidate != row and candidate != col:
                panel = candidate
                break

    for cost_mode in ("l1", "l2"):
        cells = sad_vshift_disp_cells[cost_mode]
        if not cells:
            continue

        panels = _build_sad_param_panels(
            cells=cells,
            cost_mode=cost_mode,
            row_param=row,
            col_param=col,
            panel_param=panel,
            is_map=False,
        )
        if not panels:
            continue

        combined = _stack_with_padding(panels, gap=24)
        path = pair_out_dir / f"sad_{cost_mode}_vshift_grid.png"
        cv2.imwrite(str(path), combined)
        out[f"sad_{cost_mode}_vshift_grid"] = str(path)
        rendered_disp[cost_mode] = combined

    if "l1" in rendered_disp and "l2" in rendered_disp:
        combined_l1_l2 = _stack_with_padding([rendered_disp["l1"], rendered_disp["l2"]], gap=32)
        path = pair_out_dir / "sad_l1_l2_vshift_grid.png"
        cv2.imwrite(str(path), combined_l1_l2)
        out["sad_l1_l2_vshift_grid"] = str(path)

    for cost_mode in ("l1", "l2"):
        cells = sad_vshift_map_cells[cost_mode]
        if not cells:
            continue

        panels = _build_sad_param_panels(
            cells=cells,
            cost_mode=cost_mode,
            row_param=row,
            col_param=col,
            panel_param=panel,
            is_map=True,
        )
        if not panels:
            continue
        combined = _stack_with_padding(panels, gap=24)
        path = pair_out_dir / f"sad_{cost_mode}_vshift_map_grid.png"
        cv2.imwrite(str(path), combined)
        out[f"sad_{cost_mode}_vshift_map_grid"] = str(path)

    return out


def _build_sad_param_panels(
    cells: Dict[Tuple[int, int, int, int], np.ndarray],
    cost_mode: str,
    row_param: str,
    col_param: str,
    panel_param: str,
    is_map: bool,
) -> List[np.ndarray]:
    # Key order: (vshift, window_height, window_width, max_disparity)
    remaining = [p for p in ("vshift", "window_height", "window_width", "max_disparity") if p not in {row_param, col_param, panel_param}]
    remaining_a = remaining[0] if remaining else None
    remaining_b = remaining[1] if len(remaining) > 1 else None

    def value_for(param: str, key: Tuple[int, int, int, int]) -> int:
        if param == "vshift":
            return int(key[0])
        if param == "window_height":
            return int(key[1])
        if param == "window_width":
            return int(key[2])
        if param == "max_disparity":
            return int(key[3])
        return 0

    group_keys = sorted(
        {
            (
                value_for(panel_param, key),
                value_for(remaining_a, key) if remaining_a is not None else -1,
                value_for(remaining_b, key) if remaining_b is not None else -1,
            )
            for key in cells.keys()
        }
    )
    panels: List[np.ndarray] = []
    for panel_value, rem_a_val, rem_b_val in group_keys:
        sub: Dict[Tuple[int, int], np.ndarray] = {}
        for key, img in cells.items():
            if value_for(panel_param, key) != panel_value:
                continue
            if remaining_a is not None and value_for(remaining_a, key) != rem_a_val:
                continue
            if remaining_b is not None and value_for(remaining_b, key) != rem_b_val:
                continue
            r = value_for(row_param, key)
            c = value_for(col_param, key)
            sub[(r, c)] = img
        if not sub:
            continue

        row_values = sorted({k[0] for k in sub.keys()})
        col_values = sorted({k[1] for k in sub.keys()})
        mode_label = "chosen-row" if is_map else "disparity"
        title_parts = [f"SAD {cost_mode.upper()} {mode_label}", f"{_short_param_label(panel_param)}={panel_value}"]
        if remaining_a is not None:
            title_parts.append(f"{_short_param_label(remaining_a)}={rem_a_val}")
        if remaining_b is not None:
            title_parts.append(f"{_short_param_label(remaining_b)}={rem_b_val}")
        if is_map:
            title_parts.append("(B=up, G=0, R=down)")
        title = ", ".join(title_parts)
        panels.append(
            _build_row_col_grid(
                cells=sub,
                row_values=row_values,
                col_values=col_values,
                row_label=_short_param_label(row_param),
                col_label=_short_param_label(col_param),
                title=title,
            )
        )
    return panels


def _short_param_label(param: str) -> str:
    return {
        "vshift": "vs",
        "window_height": "h",
        "window_width": "w",
        "max_disparity": "d",
    }.get(param, param)


def _write_sgbm_vshift_grids(
    pair_out_dir: Path,
    sgbm_vshift_disp_cells: Dict[Tuple[int, int, int], np.ndarray],
    sgbm_vshift_map_cells: Dict[Tuple[int, int, int], np.ndarray],
) -> Dict[str, str]:
    """Build SGBM vshift grids.

    When the sweep only varied vshift, produce a single (1 x vshift) strip (legacy layout).
    When it also varied block_size and/or validation_window, produce one
    (validation_window x vshift) 2D grid per block_size, then stack those
    per-block-size grids vertically with a title.
    """
    out: Dict[str, str] = {}

    def _render(cells: Dict[Tuple[int, int, int], np.ndarray], title_base: str) -> np.ndarray | None:
        if not cells:
            return None
        block_sizes = sorted({k[0] for k in cells.keys()})
        validation_wins = sorted({k[1] for k in cells.keys()})
        vshifts = sorted({k[2] for k in cells.keys()})

        single_axis = len(block_sizes) == 1 and len(validation_wins) == 1
        if single_axis:
            single = {k[2]: v for k, v in cells.items()}
            return _build_single_axis_grid(
                cells=single,
                axis_values=vshifts,
                axis_label="vshift",
                title=title_base,
            )

        per_bs_images: List[np.ndarray] = []
        for bs in block_sizes:
            sub: Dict[Tuple[int, int], np.ndarray] = {}
            for (bs_k, vw_k, vs_k), img in cells.items():
                if bs_k == bs:
                    sub[(vw_k, vs_k)] = img
            if not sub:
                continue
            vw_present = sorted({k[0] for k in sub.keys()})
            vs_present = sorted({k[1] for k in sub.keys()})
            grid = _build_row_col_grid(
                cells=sub,
                row_values=vw_present,
                col_values=vs_present,
                row_label="val_win",
                col_label="vshift",
                title=f"{title_base} [block_size={bs}]",
            )
            per_bs_images.append(grid)
        if not per_bs_images:
            return None
        return _stack_with_padding(per_bs_images, gap=24)

    disp_grid = _render(sgbm_vshift_disp_cells, "SGBM vshift disparity")
    if disp_grid is not None:
        path = pair_out_dir / "sgbm_vshift_grid.png"
        cv2.imwrite(str(path), disp_grid)
        out["sgbm_vshift_grid"] = str(path)

    map_grid = _render(
        sgbm_vshift_map_cells,
        "SGBM vshift chosen-row (blue=up, green=0, red=down)",
    )
    if map_grid is not None:
        path = pair_out_dir / "sgbm_vshift_map_grid.png"
        cv2.imwrite(str(path), map_grid)
        out["sgbm_vshift_map_grid"] = str(path)

    return out


def _write_census_vshift_grids(
    pair_out_dir: Path,
    census_vshift_disp_cells: Dict[Tuple[int, int, int, int], np.ndarray],
    census_vshift_map_cells: Dict[Tuple[int, int, int, int], np.ndarray],
) -> Dict[str, str]:
    """Build Census + Hamming vshift grids.

    Cells are keyed by (vshift, aggregation_window, census_window, max_disparity).
    We render *sets of square grids* where:
      - columns = vshift
      - rows = census window size
    and each set is for one (aggregation_window, max_disparity) combo.
    """
    out: Dict[str, str] = {}

    def _render(
        cells: Dict[Tuple[int, int, int, int], np.ndarray],
        title_base: str,
    ) -> np.ndarray | None:
        if not cells:
            return None
        vshifts = sorted({k[0] for k in cells.keys()})
        agg_wins = sorted({k[1] for k in cells.keys()})
        max_disparities = sorted({k[3] for k in cells.keys()})

        groups: List[np.ndarray] = []
        for a in agg_wins:
            for d in max_disparities:
                sub: Dict[Tuple[int, int], np.ndarray] = {}
                for (v_k, a_k, w_k, d_k), img in cells.items():
                    if a_k == a and d_k == d:
                        # row = window size, col = vshift
                        sub[(w_k, v_k)] = img
                if not sub:
                    continue
                windows = sorted({k[0] for k in sub.keys()})
                shifts = sorted({k[1] for k in sub.keys()})
                grid = _build_row_col_grid(
                    cells=sub,
                    row_values=windows,
                    col_values=shifts,
                    row_label="w",
                    col_label="vs",
                    title=f"{title_base} [aw={a}, d={d}]",
                )
                groups.append(grid)

        if not groups:
            return None
        return _stack_with_padding(groups, gap=24)

    disp_grid = _render(census_vshift_disp_cells, "Census vshift disparity")
    if disp_grid is not None:
        path = pair_out_dir / "census_hamming_vshift_grid.png"
        cv2.imwrite(str(path), disp_grid)
        out["census_hamming_vshift_grid"] = str(path)

    map_grid = _render(
        census_vshift_map_cells,
        "Census chosen-row (B=up G=0 R=down)",
    )
    if map_grid is not None:
        path = pair_out_dir / "census_hamming_vshift_map_grid.png"
        cv2.imwrite(str(path), map_grid)
        out["census_hamming_vshift_map_grid"] = str(path)

    return out


def _build_row_col_grid(
    cells: Dict[Tuple[int, int], np.ndarray],
    row_values: List[int],
    col_values: List[int],
    row_label: str,
    col_label: str,
    title: str,
) -> np.ndarray:
    sample = next(iter(cells.values()))
    cell_h, cell_w = sample.shape[:2]
    gap = 8
    top_h = 64
    left_w = 140

    rows = len(row_values)
    cols = len(col_values)
    canvas_h = top_h + gap + rows * (cell_h + gap)
    canvas_w = left_w + gap + cols * (cell_w + gap)
    canvas = np.full((canvas_h, canvas_w, 3), 25, dtype=np.uint8)

    cv2.putText(canvas, title, (12, 28), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (240, 240, 240), 2, cv2.LINE_AA)
    cv2.putText(
        canvas,
        f"Columns: {col_label}, Rows: {row_label}",
        (12, 52),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.5,
        (190, 190, 190),
        1,
        cv2.LINE_AA,
    )

    for j, c in enumerate(col_values):
        x = left_w + gap + j * (cell_w + gap)
        cv2.putText(
            canvas,
            f"{col_label}={c}",
            (x + 10, top_h - 10),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.6,
            (255, 255, 255),
            2,
            cv2.LINE_AA,
        )

    for i, r in enumerate(row_values):
        y = top_h + gap + i * (cell_h + gap)
        row_text = _format_window_label(r) if row_label.startswith("w") else str(r)
        cv2.putText(
            canvas,
            f"{row_label}={row_text}",
            (12, y + cell_h // 2),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.6,
            (255, 255, 255),
            2,
            cv2.LINE_AA,
        )
        for j, c in enumerate(col_values):
            x = left_w + gap + j * (cell_w + gap)
            cell = cells.get((r, c))
            if cell is None:
                cv2.rectangle(canvas, (x, y), (x + cell_w, y + cell_h), (70, 70, 70), -1)
                cv2.line(canvas, (x, y), (x + cell_w, y + cell_h), (120, 120, 120), 2)
                cv2.line(canvas, (x + cell_w, y), (x, y + cell_h), (120, 120, 120), 2)
            else:
                canvas[y : y + cell_h, x : x + cell_w] = cell
                cv2.rectangle(canvas, (x, y), (x + cell_w, y + cell_h), (30, 30, 30), 1)

    return canvas


def _build_single_axis_grid(
    cells: Dict[int, np.ndarray],
    axis_values: List[int],
    axis_label: str,
    title: str,
) -> np.ndarray:
    sample = next(iter(cells.values()))
    cell_h, cell_w = sample.shape[:2]
    gap = 8
    top_h = 64
    left_w = 120

    cols = len(axis_values)
    canvas_h = top_h + gap + cell_h + gap
    canvas_w = left_w + gap + cols * (cell_w + gap)
    canvas = np.full((canvas_h, canvas_w, 3), 25, dtype=np.uint8)

    cv2.putText(canvas, title, (12, 28), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (240, 240, 240), 2, cv2.LINE_AA)
    cv2.putText(
        canvas,
        f"Columns: {axis_label} (+/- rows)",
        (12, 52),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.5,
        (190, 190, 190),
        1,
        cv2.LINE_AA,
    )

    for j, v in enumerate(axis_values):
        x = left_w + gap + j * (cell_w + gap)
        cv2.putText(
            canvas,
            f"{axis_label}=+/-{v}",
            (x + 10, top_h - 10),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.65,
            (255, 255, 255),
            2,
            cv2.LINE_AA,
        )
        y = top_h + gap
        cell = cells.get(v)
        if cell is None:
            cv2.rectangle(canvas, (x, y), (x + cell_w, y + cell_h), (70, 70, 70), -1)
            cv2.line(canvas, (x, y), (x + cell_w, y + cell_h), (120, 120, 120), 2)
            cv2.line(canvas, (x + cell_w, y), (x, y + cell_h), (120, 120, 120), 2)
        else:
            canvas[y : y + cell_h, x : x + cell_w] = cell
            cv2.rectangle(canvas, (x, y), (x + cell_w, y + cell_h), (30, 30, 30), 1)

    return canvas


def _build_labeled_grid(
    cells: Dict[Tuple[int, int], np.ndarray],
    windows: List[int],
    max_disparities: List[int],
    title: str,
) -> np.ndarray:
    sample = next(iter(cells.values()))
    cell_h, cell_w = sample.shape[:2]
    gap = 8
    top_h = 64
    left_w = 120

    rows = len(windows)
    cols = len(max_disparities)
    canvas_h = top_h + gap + rows * (cell_h + gap)
    canvas_w = left_w + gap + cols * (cell_w + gap)
    canvas = np.full((canvas_h, canvas_w, 3), 25, dtype=np.uint8)

    cv2.putText(canvas, title, (12, 28), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (240, 240, 240), 2, cv2.LINE_AA)
    cv2.putText(
        canvas,
        "Columns: max disparity (d), Rows: window size (w)",
        (12, 52),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.5,
        (190, 190, 190),
        1,
        cv2.LINE_AA,
    )

    for j, d in enumerate(max_disparities):
        x = left_w + gap + j * (cell_w + gap)
        cv2.putText(canvas, f"d={d}", (x + 10, top_h - 10), cv2.FONT_HERSHEY_SIMPLEX, 0.65, (255, 255, 255), 2, cv2.LINE_AA)

    for i, w in enumerate(windows):
        y = top_h + gap + i * (cell_h + gap)
        w_text = _format_window_label(w)
        cv2.putText(canvas, f"w={w_text}", (16, y + cell_h // 2), cv2.FONT_HERSHEY_SIMPLEX, 0.75, (255, 255, 255), 2, cv2.LINE_AA)
        for j, d in enumerate(max_disparities):
            x = left_w + gap + j * (cell_w + gap)
            cell = cells.get((w, d))
            if cell is None:
                cv2.rectangle(canvas, (x, y), (x + cell_w, y + cell_h), (70, 70, 70), -1)
                cv2.line(canvas, (x, y), (x + cell_w, y + cell_h), (120, 120, 120), 2)
                cv2.line(canvas, (x + cell_w, y), (x, y + cell_h), (120, 120, 120), 2)
            else:
                canvas[y : y + cell_h, x : x + cell_w] = cell
                cv2.rectangle(canvas, (x, y), (x + cell_w, y + cell_h), (30, 30, 30), 1)

    return canvas


def _stack_with_padding(images: List[np.ndarray], gap: int) -> np.ndarray:
    max_w = max(img.shape[1] for img in images)
    padded = []
    for img in images:
        h, w = img.shape[:2]
        if w < max_w:
            pad = np.full((h, max_w - w, 3), 20, dtype=np.uint8)
            img = np.concatenate([img, pad], axis=1)
        padded.append(img)

    rows = []
    for idx, img in enumerate(padded):
        rows.append(img)
        if idx != len(padded) - 1:
            rows.append(np.full((gap, max_w, 3), 15, dtype=np.uint8))
    return np.concatenate(rows, axis=0)


def _merge_left_right_debug(
    left_img: np.ndarray,
    right_img: np.ndarray,
    left_title: str,
    right_title: str,
) -> np.ndarray:
    left = _ensure_bgr(left_img)
    right = _ensure_bgr(right_img)

    h = min(left.shape[0], right.shape[0])
    w_left = left.shape[1]
    w_right = right.shape[1]
    left = left[:h, :w_left]
    right = right[:h, :w_right]

    header_h = 28
    gap = 8
    canvas = np.full((h + header_h, w_left + gap + w_right, 3), 20, dtype=np.uint8)
    canvas[header_h:, :w_left] = left
    canvas[header_h:, w_left + gap : w_left + gap + w_right] = right

    cv2.putText(canvas, left_title, (8, 20), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (240, 240, 240), 1, cv2.LINE_AA)
    cv2.putText(
        canvas,
        right_title,
        (w_left + gap + 8, 20),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.55,
        (240, 240, 240),
        1,
        cv2.LINE_AA,
    )
    return canvas


def _ensure_bgr(image: np.ndarray) -> np.ndarray:
    if image.ndim == 2:
        return cv2.cvtColor(image, cv2.COLOR_GRAY2BGR)
    return image


def _format_window_label(window_value: Any) -> str:
    if isinstance(window_value, tuple) and len(window_value) == 2:
        h, w = window_value
        return f"{h}x{w}"
    return str(window_value)


def _ensure_odd_min(value: int, min_value: int) -> int:
    v = max(int(min_value), int(value))
    if v % 2 == 0:
        v += 1
    return v


def _unique_preserve_order_ints(values: List[int]) -> List[int]:
    seen = set()
    out: List[int] = []
    for v in values:
        if v not in seen:
            seen.add(v)
            out.append(int(v))
    return out


def _pick_best_sgbm_vshift(method_results: List[Dict[str, Any]]) -> Dict[str, Any] | None:
    """Return the sgbm_vshift_* entry with the highest valid pixel ratio (or None)."""
    best: Dict[str, Any] | None = None
    for entry in method_results:
        name = entry.get("method", "")
        if not name.startswith("sgbm_"):
            continue
        if not (name.startswith("sgbm_bs") or name.startswith("sgbm_vs")):
            continue
        ratio = float(entry.get("valid_pixel_ratio", 0.0) or 0.0)
        if best is None or ratio > float(best.get("valid_pixel_ratio", 0.0) or 0.0):
            best = entry
    return best


def _pick_best_census_vshift(method_results: List[Dict[str, Any]]) -> Dict[str, Any] | None:
    """Return the census_hamming_vs... entry with the highest valid pixel ratio (or None).

    Note: census_hamming_custom always produces a disparity at every pixel inside the
    valid domain, so this ratio mostly reflects the valid domain size (which shrinks
    slightly with larger windows and vshifts). It's still useful as a tiebreaker.
    """
    best: Dict[str, Any] | None = None
    for entry in method_results:
        name = entry.get("method", "")
        if not name.startswith("census_hamming_vs"):
            continue
        ratio = float(entry.get("valid_pixel_ratio", 0.0) or 0.0)
        if best is None or ratio > float(best.get("valid_pixel_ratio", 0.0) or 0.0):
            best = entry
    return best


def _sgbm_vshift_leaderboard(pairs_processed: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Aggregate valid-pixel ratios per sgbm_vshift method across all processed pairs,
    returning a list sorted by mean ratio (descending). Empty if no sgbm_vshift results.
    """
    per_method: Dict[str, Dict[str, Any]] = {}
    for pair in pairs_processed:
        for entry in pair.get("method_results", []):
            name = entry.get("method", "")
            if not (name.startswith("sgbm_bs") or name.startswith("sgbm_vs")):
                continue
            ratio = entry.get("valid_pixel_ratio")
            vshift_abs_mean = entry.get("vshift_abs_mean")
            if name not in per_method:
                per_method[name] = {"method": name, "ratios": [], "vshift_abs_means": []}
            if ratio is not None:
                per_method[name]["ratios"].append(float(ratio))
            if vshift_abs_mean is not None:
                per_method[name]["vshift_abs_means"].append(float(vshift_abs_mean))

    board: List[Dict[str, Any]] = []
    for name, info in per_method.items():
        ratios = info["ratios"]
        if not ratios:
            continue
        meta = _parse_sgbm_vshift_variant(name) or {}
        entry = {
            "method": name,
            "mean_valid_pixel_ratio": float(sum(ratios) / len(ratios)),
            "min_valid_pixel_ratio": float(min(ratios)),
            "max_valid_pixel_ratio": float(max(ratios)),
            "num_pairs": len(ratios),
            "block_size": meta.get("block_size"),
            "validation_window": meta.get("validation_window"),
            "vshift": meta.get("vshift"),
        }
        if info["vshift_abs_means"]:
            entry["mean_vshift_abs_mean"] = float(
                sum(info["vshift_abs_means"]) / len(info["vshift_abs_means"])
            )
        board.append(entry)

    board.sort(key=lambda d: d["mean_valid_pixel_ratio"], reverse=True)
    return board


def _census_vshift_leaderboard(pairs_processed: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Aggregate valid-pixel ratios per census_hamming_vshift method across pairs."""
    per_method: Dict[str, Dict[str, Any]] = {}
    for pair in pairs_processed:
        for entry in pair.get("method_results", []):
            name = entry.get("method", "")
            if not name.startswith("census_hamming_vs"):
                continue
            ratio = entry.get("valid_pixel_ratio")
            vshift_abs_mean = entry.get("vshift_abs_mean")
            if name not in per_method:
                per_method[name] = {"method": name, "ratios": [], "vshift_abs_means": []}
            if ratio is not None:
                per_method[name]["ratios"].append(float(ratio))
            if vshift_abs_mean is not None:
                per_method[name]["vshift_abs_means"].append(float(vshift_abs_mean))

    board: List[Dict[str, Any]] = []
    for name, info in per_method.items():
        ratios = info["ratios"]
        if not ratios:
            continue
        meta = _parse_census_vshift_variant(name) or {}
        entry = {
            "method": name,
            "mean_valid_pixel_ratio": float(sum(ratios) / len(ratios)),
            "min_valid_pixel_ratio": float(min(ratios)),
            "max_valid_pixel_ratio": float(max(ratios)),
            "num_pairs": len(ratios),
            "vshift": meta.get("vshift"),
            "aggregation_window": meta.get("aggregation_window"),
            "census_window": meta.get("window_size"),
            "max_disparity": meta.get("max_disparity"),
        }
        if info["vshift_abs_means"]:
            entry["mean_vshift_abs_mean"] = float(
                sum(info["vshift_abs_means"]) / len(info["vshift_abs_means"])
            )
        board.append(entry)

    board.sort(key=lambda d: d["mean_valid_pixel_ratio"], reverse=True)
    return board


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


def _vshift_stats(vshift_map: np.ndarray, max_vertical_shift: int) -> Dict[str, Any]:
    valid = np.isfinite(vshift_map)
    if not np.any(valid):
        return {
            "vshift_max": int(max_vertical_shift),
            "vshift_mean": None,
            "vshift_abs_mean": None,
            "vshift_fraction_nonzero": 0.0,
        }
    vals = vshift_map[valid]
    return {
        "vshift_max": int(max_vertical_shift),
        "vshift_mean": float(np.mean(vals)),
        "vshift_abs_mean": float(np.mean(np.abs(vals))),
        "vshift_fraction_nonzero": float(np.count_nonzero(vals) / vals.size),
    }

