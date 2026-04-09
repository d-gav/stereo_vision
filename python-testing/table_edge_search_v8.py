import cv2
import json
import numpy as np
import importlib.util
import pathlib
import sys
import subprocess
from itertools import product


def load_module(module_path: pathlib.Path):
    spec = importlib.util.spec_from_file_location("fisheye_recon", module_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def track_horizontal_edge_metrics(rectified_bgr: np.ndarray, y_min: int = 90, y_max: int = 210):
    gray = cv2.cvtColor(rectified_bgr, cv2.COLOR_BGR2GRAY).astype(np.float32)
    gray = cv2.GaussianBlur(gray, (5, 5), 0)
    grad_y = cv2.Sobel(gray, cv2.CV_32F, 0, 1, ksize=3)

    h, w = gray.shape
    y0 = max(0, int(y_min))
    y1 = min(h - 1, int(y_max))
    if y1 <= y0:
        raise ValueError(f"Invalid y-band [{y_min},{y_max}] for image height {h}")

    band = np.abs(grad_y[y0 : y1 + 1, :]).astype(np.float32)
    band_h, band_w = band.shape

    max_step = 3
    smoothness = 0.85
    shifts = np.arange(-max_step, max_step + 1, dtype=np.int16)
    penalties = (smoothness * (shifts.astype(np.float32) ** 2)).astype(np.float32)

    prev_cost = -band[:, 0].copy()
    back_ptr = np.zeros((band_w, band_h), dtype=np.int16)
    y_idx = np.arange(band_h, dtype=np.int16)

    for x in range(1, band_w):
        candidates = np.empty((len(shifts), band_h), dtype=np.float32)
        for i, d in enumerate(shifts):
            rolled = np.roll(prev_cost, int(d))
            if d > 0:
                rolled[:d] = np.inf
            elif d < 0:
                rolled[d:] = np.inf
            candidates[i] = rolled + penalties[i]

        best_shift_idx = np.argmin(candidates, axis=0)
        best_prev_cost = candidates[best_shift_idx, np.arange(band_h)]
        best_prev_y = y_idx - shifts[best_shift_idx]

        back_ptr[x] = best_prev_y
        prev_cost = best_prev_cost - band[:, x]

    path = np.empty(band_w, dtype=np.int16)
    y_end = int(np.argmin(prev_cost))
    path[-1] = y_end
    for x in range(band_w - 1, 0, -1):
        y_end = int(back_ptr[x, y_end])
        path[x - 1] = y_end

    y_path = path.astype(np.float32) + float(y0)
    x_coords = np.arange(band_w, dtype=np.float32)

    line_coef = np.polyfit(x_coords, y_path, deg=1)
    line_fit = np.polyval(line_coef, x_coords)
    linear_rms = float(np.sqrt(np.mean((y_path - line_fit) ** 2)))

    quad_coef = np.polyfit(x_coords, y_path, deg=2)
    curvature_abs_a = float(abs(quad_coef[0]))

    edge_strength = float(np.mean(band[path, np.arange(band_w)]))

    return {
        "linear_rms": linear_rms,
        "curvature_abs_a": curvature_abs_a,
        "edge_strength": edge_strength,
    }


def evaluate_candidate(mod, crops, model, input_hfov, output_hfov, strength, cx, cy):
    h, w = crops[0].shape[:2]
    map_x, map_y = mod.build_lens_to_pinhole_map(
        src_width=w,
        src_height=h,
        input_hfov_deg=float(input_hfov),
        output_hfov_deg=float(output_hfov),
        correction_strength=float(strength),
        projection_model=str(model),
        center_x_offset_px=float(cx),
        center_y_offset_px=float(cy),
    )

    valid_mask = (
        (map_x >= 0.0)
        & (map_x <= float(w - 1))
        & (map_y >= 0.0)
        & (map_y <= float(h - 1))
    )
    valid_ratio = float(valid_mask.mean())

    all_metrics = []
    for crop in crops:
        rectified = cv2.remap(
            crop,
            map_x,
            map_y,
            interpolation=cv2.INTER_LINEAR,
            borderMode=cv2.BORDER_CONSTANT,
            borderValue=(0, 0, 0),
        )
        all_metrics.append(track_horizontal_edge_metrics(rectified, y_min=90, y_max=210))

    avg_rms = float(np.mean([m["linear_rms"] for m in all_metrics]))
    avg_curv = float(np.mean([m["curvature_abs_a"] for m in all_metrics]))
    avg_strength = float(np.mean([m["edge_strength"] for m in all_metrics]))

    # Strongly prioritize straightness (low RMS and low quadratic curvature),
    # with mapping-validity penalty and mild edge-strength reward.
    final_score = (
        8.0 * (avg_rms ** 2)
        + 220000.0 * avg_curv
        + 1200.0 * (1.0 - valid_ratio)
        - 0.12 * avg_strength
    )

    return {
        "projection_model": model,
        "input_hfov_deg": float(input_hfov),
        "output_hfov_deg": float(output_hfov),
        "correction_strength": float(strength),
        "center_x_offset_px": float(cx),
        "center_y_offset_px": float(cy),
        "valid_ratio": valid_ratio,
        "avg_linear_rms": avg_rms,
        "avg_curvature_abs_a": avg_curv,
        "avg_edge_strength": avg_strength,
        "final_score": float(final_score),
    }


def print_top_table(title, rows, top_n=12):
    print(title)
    header = (
        f"{'rank':>4} | {'score':>10} | {'model':>12} | {'in_hfov':>7} | {'out_hfov':>8} | "
        f"{'str':>5} | {'cx':>4} | {'cy':>4} | {'valid':>7} | {'rms':>8} | {'|a|':>10} | {'edge':>8}"
    )
    print(header)
    print("-" * len(header))
    for i, r in enumerate(rows[:top_n], 1):
        print(
            f"{i:4d} | {r['final_score']:10.4f} | {r['projection_model']:>12} | "
            f"{r['input_hfov_deg']:7.2f} | {r['output_hfov_deg']:8.2f} | "
            f"{r['correction_strength']:5.2f} | {r['center_x_offset_px']:4.0f} | {r['center_y_offset_px']:4.0f} | "
            f"{r['valid_ratio']:7.4f} | {r['avg_linear_rms']:8.4f} | {r['avg_curvature_abs_a']:10.7f} | "
            f"{r['avg_edge_strength']:8.3f}"
        )


def main():
    root = pathlib.Path.cwd()
    module_path = root / "python-testing" / "fisheye-reconstruction.py"
    mod = load_module(module_path)

    image_paths = sorted((root / "test-ntsc-images").glob("*.png"))
    if len(image_paths) < 2:
        raise RuntimeError("Expected at least two test images in test-ntsc-images")

    crops = []
    for p in image_paths:
        frame = cv2.imread(str(p), cv2.IMREAD_COLOR)
        if frame is None:
            raise RuntimeError(f"Failed to load image: {p}")
        x, y, w, h, sat = mod.detect_active_bbox(frame, 320, 240)
        crop = frame[y : y + h, x : x + w]
        crops.append(crop)
        print(f"Loaded {p.name}: frame={frame.shape}, bbox=(x={x}, y={y}, w={w}, h={h}), sat={sat:.3f}")

    # Stage A: coarse search.
    stage_a_models = ["rectilinear", "equidistant", "equisolid", "stereographic", "orthographic"]
    stage_a_in = [95, 98, 101, 104, 107, 110]
    stage_a_out = [82, 85, 88, 90, 92, 95]
    stage_a_strength = [0.70, 0.85, 1.0, 1.15, 1.30]

    coarse_results = []
    for model, ih, oh, s in product(stage_a_models, stage_a_in, stage_a_out, stage_a_strength):
        coarse_results.append(evaluate_candidate(mod, crops, model, ih, oh, s, 0.0, 0.0))

    coarse_results.sort(key=lambda r: r["final_score"])
    best_a = coarse_results[0]

    print()
    print_top_table("Stage A best 5 (coarse):", coarse_results, top_n=5)

    # Stage B: refined search around best coarse parameters.
    best_model = best_a["projection_model"]
    best_in = best_a["input_hfov_deg"]
    best_out = best_a["output_hfov_deg"]
    best_s = best_a["correction_strength"]

    stage_b_in = sorted({best_in - 3.0, best_in, best_in + 3.0})
    stage_b_out = sorted({best_out - 2.0, best_out, best_out + 2.0})
    stage_b_strength = sorted(
        {
            max(0.5, min(1.6, best_s - 0.2)),
            max(0.5, min(1.6, best_s)),
            max(0.5, min(1.6, best_s + 0.2)),
        }
    )
    stage_b_cx = [-8, -4, 0, 4, 8]
    stage_b_cy = [-8, -4, 0, 4, 8]

    refined_results = []
    for ih, oh, s, cx, cy in product(stage_b_in, stage_b_out, stage_b_strength, stage_b_cx, stage_b_cy):
        refined_results.append(evaluate_candidate(mod, crops, best_model, ih, oh, s, cx, cy))

    refined_results.sort(key=lambda r: r["final_score"])
    best_b = refined_results[0]

    print()
    print_top_table("Stage B top 12 (refined):", refined_results, top_n=12)

    chosen = {
        "projection_model": best_b["projection_model"],
        "input_hfov_deg": best_b["input_hfov_deg"],
        "output_hfov_deg": best_b["output_hfov_deg"],
        "correction_strength": best_b["correction_strength"],
        "center_x_offset_px": best_b["center_x_offset_px"],
        "center_y_offset_px": best_b["center_y_offset_px"],
    }

    print()
    print("Chosen refined parameters:")
    print(json.dumps(chosen, indent=2))

    output_dir = root / "python-testing" / "reconstruction-output-v8-table-flat"
    cmd = [
        str(sys.executable),
        str(module_path),
        "--profile",
        "razer_v3",
        "--output-dir",
        str(output_dir),
        "--projection-model",
        str(chosen["projection_model"]),
        "--input-hfov-deg",
        f"{chosen['input_hfov_deg']}",
        "--output-hfov-deg",
        f"{chosen['output_hfov_deg']}",
        "--correction-strength",
        f"{chosen['correction_strength']}",
        "--center-x-offset-px",
        f"{chosen['center_x_offset_px']}",
        "--center-y-offset-px",
        f"{chosen['center_y_offset_px']}",
    ]

    print()
    print("Running fisheye-reconstruction.py with chosen refined parameters...")
    proc = subprocess.run(cmd, cwd=str(root), text=True, capture_output=True)
    print(f"Return code: {proc.returncode}")
    if proc.stdout:
        print("--- script stdout ---")
        print(proc.stdout.rstrip())
    if proc.stderr:
        print("--- script stderr ---")
        print(proc.stderr.rstrip())

    status = {
        "run_success": proc.returncode == 0,
        "return_code": int(proc.returncode),
        "chosen_parameters": chosen,
        "top12_refined": refined_results[:12],
    }
    out_json = root / "python-testing" / "table_edge_search_v8_results.json"
    out_json.write_text(json.dumps(status, indent=2), encoding="utf-8")
    print(f"Saved summary JSON: {out_json}")


if __name__ == "__main__":
    main()
