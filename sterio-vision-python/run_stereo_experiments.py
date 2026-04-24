from __future__ import annotations

import argparse
import json
from dataclasses import replace
from pathlib import Path

import cv2
import numpy as np

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
    parser.add_argument(
        "--preprocess-sweep",
        action="store_true",
        help=(
            "Run the same stereo config over multiple preprocessing combinations "
            "(CLAHE x median blur). Outputs each combo under a subfolder and writes "
            "an aggregate sweep summary."
        ),
    )
    parser.add_argument(
        "--preprocess-clahe-options",
        type=str,
        default="",
        help=(
            "Comma-separated CLAHE options for --preprocess-sweep. "
            "Accepted values: on,off,true,false,1,0. "
            "Default sweep: off,on"
        ),
    )
    parser.add_argument(
        "--preprocess-median-ksizes",
        type=str,
        default="",
        help=(
            "Comma-separated median blur kernel sizes for --preprocess-sweep. "
            "0 disables blur; even values are rounded up to odd. "
            "Default sweep: 0,3,5"
        ),
    )
    parser.add_argument(
        "--min-disparity",
        type=int,
        default=0,
        help=(
            "Global minimum disparity floor. Values below this are treated as invalid "
            "(shown blue in previews). SAD/Census also skip searching below this value."
        ),
    )
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
        "--sad-window-widths",
        type=str,
        default="",
        help="Comma-separated SAD window widths (odd preferred), e.g. 5,7,9",
    )
    parser.add_argument(
        "--sad-window-heights",
        type=str,
        default="",
        help="Comma-separated SAD window heights (odd preferred), e.g. 5,7,9",
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
        "--sad-vshift-grid-row-param",
        type=str,
        default="window_height",
        help=(
            "SAD-vshift grid row parameter: one of "
            "window_height,window_width,vshift,max_disparity"
        ),
    )
    parser.add_argument(
        "--sad-vshift-grid-col-param",
        type=str,
        default="vshift",
        help=(
            "SAD-vshift grid column parameter: one of "
            "window_height,window_width,vshift,max_disparity"
        ),
    )
    parser.add_argument(
        "--sad-vshift-grid-panel-param",
        type=str,
        default="max_disparity",
        help=(
            "SAD-vshift grid panel/set parameter: one of "
            "window_height,window_width,vshift,max_disparity"
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
        "--sgbm-vshift-validation-height-scale",
        type=int,
        default=1,
        help=(
            "Scale factor for validation-window height in sgbm_vshift. "
            "1=square, 2=taller rectangle (height=2*width), etc."
        ),
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
    sad_window_widths = _parse_int_list(args.sad_window_widths)
    sad_window_heights = _parse_int_list(args.sad_window_heights)
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
    if not sad_window_widths:
        sad_window_widths = list(sad_window_sizes)
    if not sad_window_heights:
        sad_window_heights = list(sad_window_sizes)

    sad_max_disps = _unique_preserve_order([max(1, v) for v in sad_max_disps]) or [96]
    sad_window_sizes = _unique_preserve_order([max(3, v) if v % 2 == 1 else max(3, v + 1) for v in sad_window_sizes]) or [9]
    sad_window_widths = _unique_preserve_order([max(3, v) if v % 2 == 1 else max(3, v + 1) for v in sad_window_widths]) or [9]
    sad_window_heights = _unique_preserve_order([max(3, v) if v % 2 == 1 else max(3, v + 1) for v in sad_window_heights]) or [9]
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
        min_disparity=max(0, args.min_disparity),
        bm_num_disparities=args.bm_num_disp,
        bm_block_size=args.bm_block_size,
        sgbm_num_disparities=args.sgbm_num_disp,
        sgbm_block_size=args.sgbm_block_size,
        sad_max_disparities=sad_max_disps,
        sad_window_sizes=sad_window_sizes,
        sad_window_widths=sad_window_widths,
        sad_window_heights=sad_window_heights,
        sad_vshift_values=sad_vshifts,
        sad_vshift_grid_row_param=args.sad_vshift_grid_row_param.strip().lower(),
        sad_vshift_grid_col_param=args.sad_vshift_grid_col_param.strip().lower(),
        sad_vshift_grid_panel_param=args.sad_vshift_grid_panel_param.strip().lower(),
        sgbm_vshift_values=sgbm_vshifts,
        sgbm_vshift_block_sizes=sgbm_vshift_block_sizes,
        sgbm_vshift_validation_windows=sgbm_vshift_validation_windows,
        sgbm_vshift_validation_height_scale=max(1, args.sgbm_vshift_validation_height_scale),
        sgbm_vshift_validation_window=sgbm_vshift_validation_windows[0],
        census_max_disparities=census_max_disps,
        census_window_sizes=census_window_sizes,
        census_aggregation_window=max(1, args.census_aggregation_window),
        census_vshift_values=census_vshifts,
        census_vshift_aggregation_windows=census_vshift_aggregation_windows,
    )

    if not args.preprocess_sweep:
        summary = run_pipeline(cfg)
        print(json.dumps(summary, indent=2))
        return

    clahe_options = _parse_bool_list(args.preprocess_clahe_options)
    if not clahe_options:
        clahe_options = [False, True]
    median_ksizes = _parse_int_list(args.preprocess_median_ksizes)
    if not median_ksizes:
        median_ksizes = [0, 3, 5]
    median_ksizes = _normalize_median_ksizes(median_ksizes)

    sweep_results = []
    for use_clahe in clahe_options:
        for med_ksize in median_ksizes:
            variant_name = _preprocess_variant_name(use_clahe=use_clahe, median_blur_ksize=med_ksize)
            variant_out_dir = cfg.output_dir / variant_name
            variant_cfg = replace(
                cfg,
                output_dir=variant_out_dir,
                use_clahe=use_clahe,
                median_blur_ksize=med_ksize,
            )
            variant_summary = run_pipeline(variant_cfg)
            sweep_results.append(
                {
                    "variant": variant_name,
                    "use_clahe": use_clahe,
                    "median_blur_ksize": med_ksize,
                    "output_dir": str(variant_out_dir),
                    "summary": variant_summary,
                    "method_mean_valid_ratio": _method_mean_valid_ratio(variant_summary),
                }
            )

    aggregate = {
        "mode": "preprocess_sweep",
        "base_output_dir": str(cfg.output_dir),
        "variants": [
            {
                "variant": r["variant"],
                "use_clahe": r["use_clahe"],
                "median_blur_ksize": r["median_blur_ksize"],
                "output_dir": r["output_dir"],
                "method_mean_valid_ratio": r["method_mean_valid_ratio"],
                "summary_file": str(Path(r["output_dir"]) / "summary.json"),
            }
            for r in sweep_results
        ],
    }
    preprocess_grid_paths = _write_preprocess_comparison_grids(
        base_output_dir=cfg.output_dir,
        sweep_results=sweep_results,
        clahe_options=clahe_options,
        median_ksizes=median_ksizes,
    )
    if preprocess_grid_paths:
        aggregate["preprocess_grid_paths"] = preprocess_grid_paths
    aggregate_path = cfg.output_dir / "preprocess_sweep_summary.json"
    aggregate_path.parent.mkdir(parents=True, exist_ok=True)
    with aggregate_path.open("w", encoding="utf-8") as f:
        json.dump(aggregate, f, indent=2)
    print(json.dumps(aggregate, indent=2))


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


def _parse_bool_list(value: str) -> list[bool]:
    out: list[bool] = []
    for token in value.split(","):
        t = token.strip().lower()
        if not t:
            continue
        if t in {"1", "true", "on", "yes", "y"}:
            out.append(True)
        elif t in {"0", "false", "off", "no", "n"}:
            out.append(False)
        else:
            raise ValueError(
                f"Invalid boolean token '{token}' in list '{value}'. "
                "Use one of: on,off,true,false,1,0."
            )
    seen = set()
    deduped: list[bool] = []
    for v in out:
        if v not in seen:
            seen.add(v)
            deduped.append(v)
    return deduped


def _normalize_median_ksizes(values: list[int]) -> list[int]:
    normalized: list[int] = []
    for raw in values:
        v = int(raw)
        if v <= 0:
            normalized.append(0)
            continue
        if v < 3:
            v = 3
        if v % 2 == 0:
            v += 1
        normalized.append(v)
    return _unique_preserve_order(normalized)


def _preprocess_variant_name(use_clahe: bool, median_blur_ksize: int) -> str:
    clahe_str = "clahe_on" if use_clahe else "clahe_off"
    med_str = f"med{median_blur_ksize}" if median_blur_ksize > 0 else "med0"
    return f"pre_{clahe_str}_{med_str}"


def _method_mean_valid_ratio(summary: dict) -> dict[str, float]:
    by_method: dict[str, list[float]] = {}
    for pair in summary.get("pairs_processed", []):
        for result in pair.get("method_results", []):
            method = str(result.get("method", ""))
            ratio = result.get("valid_pixel_ratio")
            if not method or ratio is None:
                continue
            by_method.setdefault(method, []).append(float(ratio))
    out: dict[str, float] = {}
    for method, vals in by_method.items():
        if vals:
            out[method] = float(sum(vals) / len(vals))
    return out


def _write_preprocess_comparison_grids(
    base_output_dir: Path,
    sweep_results: list[dict],
    clahe_options: list[bool],
    median_ksizes: list[int],
) -> dict[str, dict[str, str]]:
    """
    Write grids that compare preprocessing variants for each (pair, method).
    Rows = median blur kernel size, columns = CLAHE on/off.
    """
    grids_root = base_output_dir / "preprocess_grids"
    grids_root.mkdir(parents=True, exist_ok=True)

    # pair_name -> method_name -> {(median, clahe): image}
    cells: dict[str, dict[str, dict[tuple[int, bool], np.ndarray]]] = {}
    for result in sweep_results:
        med = int(result["median_blur_ksize"])
        clahe = bool(result["use_clahe"])
        summary = result["summary"]
        for pair in summary.get("pairs_processed", []):
            pair_name = str(pair.get("pair_name", "unknown_pair"))
            cells.setdefault(pair_name, {})
            for method_result in pair.get("method_results", []):
                method_name = str(method_result.get("method", "unknown_method"))
                out_dir = Path(str(method_result.get("output_dir", "")))
                color_path = out_dir / "disparity_color.png"
                if not color_path.exists():
                    continue
                img = cv2.imread(str(color_path), cv2.IMREAD_COLOR)
                if img is None:
                    continue
                method_cells = cells[pair_name].setdefault(method_name, {})
                method_cells[(med, clahe)] = img

    all_paths: dict[str, dict[str, str]] = {}
    sorted_rows = sorted({int(v) for v in median_ksizes})
    sorted_cols = [bool(v) for v in clahe_options]
    for pair_name, methods in cells.items():
        pair_out_dir = grids_root / pair_name
        pair_out_dir.mkdir(parents=True, exist_ok=True)
        all_paths[pair_name] = {}
        for method_name, method_cells in methods.items():
            if not method_cells:
                continue
            grid = _build_preprocess_grid(
                cells=method_cells,
                row_values=sorted_rows,
                col_values=sorted_cols,
                title=f"{method_name} disparity across preprocessing",
            )
            filename = f"{_safe_filename(method_name)}_preprocess_grid.png"
            path = pair_out_dir / filename
            cv2.imwrite(str(path), grid)
            all_paths[pair_name][method_name] = str(path)
    return all_paths


def _build_preprocess_grid(
    cells: dict[tuple[int, bool], np.ndarray],
    row_values: list[int],
    col_values: list[bool],
    title: str,
) -> np.ndarray:
    sample = next(iter(cells.values()))
    cell_h, cell_w = sample.shape[:2]
    gap = 8
    top_h = 64
    left_w = 180
    rows = len(row_values)
    cols = len(col_values)
    canvas_h = top_h + gap + rows * (cell_h + gap)
    canvas_w = left_w + gap + cols * (cell_w + gap)
    canvas = np.full((canvas_h, canvas_w, 3), 25, dtype=np.uint8)

    cv2.putText(canvas, title, (12, 28), cv2.FONT_HERSHEY_SIMPLEX, 0.75, (240, 240, 240), 2, cv2.LINE_AA)
    cv2.putText(
        canvas,
        "Columns: CLAHE, Rows: median blur kernel",
        (12, 52),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.5,
        (190, 190, 190),
        1,
        cv2.LINE_AA,
    )

    for j, clahe in enumerate(col_values):
        x = left_w + gap + j * (cell_w + gap)
        clahe_label = "clahe=on" if clahe else "clahe=off"
        cv2.putText(canvas, clahe_label, (x + 8, top_h - 10), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 255, 255), 2, cv2.LINE_AA)

    for i, med in enumerate(row_values):
        y = top_h + gap + i * (cell_h + gap)
        med_label = f"median={med}" if med > 0 else "median=off"
        cv2.putText(canvas, med_label, (12, y + cell_h // 2), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 255, 255), 2, cv2.LINE_AA)
        for j, clahe in enumerate(col_values):
            x = left_w + gap + j * (cell_w + gap)
            cell = cells.get((med, clahe))
            if cell is None:
                cv2.rectangle(canvas, (x, y), (x + cell_w, y + cell_h), (70, 70, 70), -1)
                cv2.line(canvas, (x, y), (x + cell_w, y + cell_h), (120, 120, 120), 2)
                cv2.line(canvas, (x + cell_w, y), (x, y + cell_h), (120, 120, 120), 2)
            else:
                canvas[y : y + cell_h, x : x + cell_w] = cell
                cv2.rectangle(canvas, (x, y), (x + cell_w, y + cell_h), (30, 30, 30), 1)

    return canvas


def _safe_filename(value: str) -> str:
    out = []
    for ch in value:
        if ch.isalnum() or ch in {"_", "-"}:
            out.append(ch)
        else:
            out.append("_")
    return "".join(out)


if __name__ == "__main__":
    main()

