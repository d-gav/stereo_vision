import importlib.util
import itertools
import json
import subprocess
import sys
import time
from pathlib import Path

import cv2
import numpy as np


def load_module(module_path: Path):
    spec = importlib.util.spec_from_file_location("fisheye_reconstruction_mod", module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to create module spec for {module_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def compute_hv_length_sum(rectified_bgr: np.ndarray) -> float:
    gray = cv2.cvtColor(rectified_bgr, cv2.COLOR_BGR2GRAY)
    small = cv2.resize(gray, (160, 120), interpolation=cv2.INTER_AREA)
    edges = cv2.Canny(small, 50, 120, L2gradient=True)
    lines = cv2.HoughLinesP(
        edges,
        rho=1,
        theta=np.pi / 180.0,
        threshold=22,
        minLineLength=16,
        maxLineGap=6,
    )
    if lines is None:
        return 0.0

    hv_sum = 0.0
    for line in lines[:, 0, :]:
        x1, y1, x2, y2 = map(float, line)
        dx = x2 - x1
        dy = y2 - y1
        length = float(np.hypot(dx, dy))
        if length < 3.0:
            continue
        angle = (float(np.degrees(np.arctan2(dy, dx))) + 180.0) % 180.0
        horizontal = min(angle, 180.0 - angle) <= 12.0
        vertical = abs(angle - 90.0) <= 12.0
        if horizontal or vertical:
            hv_sum += length

    return hv_sum * 2.0


def track_edges_and_cost(rectified_bgr: np.ndarray, y_start: int = 90, y_end: int = 210):
    gray = cv2.cvtColor(rectified_bgr, cv2.COLOR_BGR2GRAY)
    gray = cv2.GaussianBlur(gray, (5, 5), 0.0)
    grad_x = cv2.Sobel(gray, cv2.CV_32F, 1, 0, ksize=3)
    mag = np.abs(grad_x)

    h, w = gray.shape
    y0 = max(0, min(h - 1, int(y_start)))
    y1 = max(y0 + 1, min(h, int(y_end)))
    band = mag[y0:y1, :]

    margin = 6
    profile = band.mean(axis=0)
    left_seed = int(np.argmax(profile[margin : (w // 2) - margin]) + margin)
    right_seed = int(np.argmax(profile[(w // 2) + margin : w - margin]) + (w // 2) + margin)

    edge_thresh = max(8.0, float(np.percentile(band, 70) * 0.28))

    def track_one(seed_x: int):
        ys = np.arange(y0, y1, dtype=np.int32)
        xs = np.empty_like(ys, dtype=np.float32)
        scores = np.empty_like(ys, dtype=np.float32)
        valid = np.zeros_like(ys, dtype=bool)

        prev = float(seed_x)
        prev_prev = float(seed_x)
        radius = 15.0
        smooth_lambda = 1.25

        for i, yy in enumerate(ys):
            pred = prev + (prev - prev_prev) if i >= 2 else prev
            lo = max(0, int(round(pred - radius)))
            hi = min(w, int(round(pred + radius + 1)))
            if hi <= lo:
                lo = int(np.clip(round(pred), 0, w - 1))
                hi = min(w, lo + 1)

            segment = mag[yy, lo:hi]
            if segment.size == 0:
                best_x = float(np.clip(pred, 0, w - 1))
                raw_score = 0.0
            else:
                cand_x = np.arange(lo, hi, dtype=np.float32)
                penalized = segment - smooth_lambda * np.abs(cand_x - pred)
                j = int(np.argmax(penalized))
                best_x = float(cand_x[j])
                raw_score = float(segment[j])

            xs[i] = best_x
            scores[i] = raw_score
            is_valid = raw_score >= edge_thresh
            valid[i] = is_valid

            if is_valid:
                prev_prev, prev = prev, best_x
            else:
                prev_prev, prev = prev, 0.65 * prev + 0.35 * pred

        return ys, xs, scores, valid

    def edge_metrics(ys, xs, scores, valid):
        valid_count = int(valid.sum())
        if valid_count >= 8:
            coef = np.polyfit(ys[valid], xs[valid], 1)
            fit = np.polyval(coef, ys)
            rms = float(np.sqrt(np.mean((xs[valid] - fit[valid]) ** 2)))
        else:
            rms = 40.0

        if valid.any():
            idx_all = np.arange(xs.shape[0], dtype=np.float32)
            idx_valid = idx_all[valid]
            xs_valid = xs[valid]
            xs_filled = np.interp(idx_all, idx_valid, xs_valid)
            mean_strength = float(scores[valid].mean())
        else:
            xs_filled = xs
            mean_strength = 0.0

        curvature = (
            float(np.sqrt(np.mean(np.diff(xs_filled, n=2) ** 2))) if xs_filled.shape[0] > 2 else 0.0
        )
        valid_ratio = float(valid.mean())

        edge_cost = (
            120.0 * rms
            + 260.0 * curvature
            - 0.38 * mean_strength
            + 900.0 * (1.0 - valid_ratio)
        )
        return edge_cost, valid_ratio

    ys_l, xs_l, sc_l, va_l = track_one(left_seed)
    ys_r, xs_r, sc_r, va_r = track_one(right_seed)

    left_cost, left_valid = edge_metrics(ys_l, xs_l, sc_l, va_l)
    right_cost, right_valid = edge_metrics(ys_r, xs_r, sc_r, va_r)

    table_cost = 0.5 * (left_cost + right_cost)
    valid_ratio = 0.5 * (left_valid + right_valid)
    return float(table_cost), float(valid_ratio)


def evaluate_candidate(module, crops, params):
    map_x, map_y = module.build_lens_to_pinhole_map(
        src_width=crops[0].shape[1],
        src_height=crops[0].shape[0],
        input_hfov_deg=params["input_hfov_deg"],
        output_hfov_deg=params["output_hfov_deg"],
        correction_strength=params["correction_strength"],
        projection_model=params["projection_model"],
        center_x_offset_px=params["center_x_offset_px"],
        center_y_offset_px=params["center_y_offset_px"],
        residual_k1=params["residual_k1"],
        residual_k2=params["residual_k2"],
    )

    table_costs = []
    valid_ratios = []
    global_hv = 0.0

    for crop in crops:
        rectified = cv2.remap(
            crop,
            map_x,
            map_y,
            interpolation=cv2.INTER_LINEAR,
            borderMode=cv2.BORDER_CONSTANT,
            borderValue=(0, 0, 0),
        )
        t_cost, v_ratio = track_edges_and_cost(rectified, y_start=90, y_end=210)
        table_costs.append(t_cost)
        valid_ratios.append(v_ratio)
        global_hv += compute_hv_length_sum(rectified)

    table_cost = float(np.mean(table_costs))
    valid_ratio = float(np.mean(valid_ratios))
    final_cost = table_cost - (global_hv / 220.0) + max(0.0, 0.97 - valid_ratio) * 4000.0

    return {
        "params": params,
        "table_cost": table_cost,
        "global_hv": float(global_hv),
        "valid_ratio": valid_ratio,
        "final_cost": float(final_cost),
    }


def main():
    root = Path.cwd()
    module_path = root / "python-testing" / "fisheye-reconstruction.py"
    module = load_module(module_path)

    png_paths = sorted((root / "test-ntsc-images").glob("*.png"))
    if len(png_paths) < 2:
        raise RuntimeError("Expected at least two PNG files in test-ntsc-images")

    frames = []
    for p in png_paths[:2]:
        img = cv2.imread(str(p), cv2.IMREAD_COLOR)
        if img is None:
            raise RuntimeError(f"Failed to read {p}")
        frames.append((p, img))

    crops = []
    for p, frame in frames:
        x, y, w, h, sat = module.detect_active_bbox(frame, bbox_width=320, bbox_height=240)
        crop = frame[y : y + h, x : x + w]
        crops.append(crop)
        print(f"Crop: {p.name} bbox=(x={x}, y={y}, w={w}, h={h}) mean_saturation={sat:.4f}")

    projection_models = ["equidistant", "equisolid", "rectilinear"]
    input_hfov_deg_values = [105.0, 107.0, 109.0]
    output_hfov_deg_values = [82.0, 84.0, 86.0]
    correction_strength_values = [1.3, 1.5, 1.7]
    center_x_offset_px_values = [-10.0, -8.0, -6.0, -4.0]
    center_y_offset_px_values = [6.0, 8.0, 10.0, 12.0]
    residual_k1_values = [-0.50, -0.35, -0.20, -0.05, 0.10]
    residual_k2_values = [-0.25, -0.15, -0.05, 0.00, 0.05]

    total = (
        len(projection_models)
        * len(input_hfov_deg_values)
        * len(output_hfov_deg_values)
        * len(correction_strength_values)
        * len(center_x_offset_px_values)
        * len(center_y_offset_px_values)
        * len(residual_k1_values)
        * len(residual_k2_values)
    )
    print(f"Total candidates: {total}")

    t0 = time.time()
    results = []
    for idx, (projection_model, input_hfov_deg, output_hfov_deg, correction_strength, center_x_offset_px, center_y_offset_px, residual_k1, residual_k2) in enumerate(
        itertools.product(
            projection_models,
            input_hfov_deg_values,
            output_hfov_deg_values,
            correction_strength_values,
            center_x_offset_px_values,
            center_y_offset_px_values,
            residual_k1_values,
            residual_k2_values,
        ),
        start=1,
    ):
        params = {
            "projection_model": projection_model,
            "input_hfov_deg": input_hfov_deg,
            "output_hfov_deg": output_hfov_deg,
            "correction_strength": correction_strength,
            "center_x_offset_px": center_x_offset_px,
            "center_y_offset_px": center_y_offset_px,
            "residual_k1": residual_k1,
            "residual_k2": residual_k2,
        }
        result = evaluate_candidate(module, crops, params)
        results.append(result)

        if idx % 600 == 0 or idx == total:
            elapsed = time.time() - t0
            print(f"Progress: {idx}/{total} ({elapsed:.1f}s)")

    results.sort(key=lambda r: r["final_cost"])

    print("TOP_12_CANDIDATES")
    for rank, rec in enumerate(results[:12], start=1):
        p = rec["params"]
        print(
            f"{rank:2d}) "
            f"model={p['projection_model']}, in={p['input_hfov_deg']:.1f}, out={p['output_hfov_deg']:.1f}, "
            f"strength={p['correction_strength']:.2f}, cx={p['center_x_offset_px']:.1f}, cy={p['center_y_offset_px']:.1f}, "
            f"k1={p['residual_k1']:.2f}, k2={p['residual_k2']:.2f}, "
            f"table_cost={rec['table_cost']:.3f}, global_hv={rec['global_hv']:.3f}, "
            f"valid_ratio={rec['valid_ratio']:.6f}, final_cost={rec['final_cost']:.3f}"
        )

    best = results[0]
    print("BEST_PARAMS")
    print(json.dumps(best["params"], sort_keys=True))
    print(
        f"BEST_METRICS table_cost={best['table_cost']:.3f}, "
        f"global_hv={best['global_hv']:.3f}, valid_ratio={best['valid_ratio']:.6f}, final_cost={best['final_cost']:.3f}"
    )

    out_dir = root / "python-testing" / "reconstruction-output-v9-plumbline"
    run_cmd = [
        sys.executable,
        str(module_path),
        "--input-dir",
        str(root / "test-ntsc-images"),
        "--output-dir",
        str(out_dir),
        "--projection-model",
        str(best["params"]["projection_model"]),
        "--input-hfov-deg",
        str(best["params"]["input_hfov_deg"]),
        "--output-hfov-deg",
        str(best["params"]["output_hfov_deg"]),
        "--correction-strength",
        str(best["params"]["correction_strength"]),
        "--center-x-offset-px",
        str(best["params"]["center_x_offset_px"]),
        "--center-y-offset-px",
        str(best["params"]["center_y_offset_px"]),
        "--residual-k1",
        str(best["params"]["residual_k1"]),
        "--residual-k2",
        str(best["params"]["residual_k2"]),
    ]

    proc = subprocess.run(run_cmd, capture_output=True, text=True)
    print("RECONSTRUCTION_RUN_STDOUT")
    stdout = proc.stdout.strip()
    if stdout:
        print(stdout)
    else:
        print("<empty>")

    stderr = proc.stderr.strip()
    if stderr:
        print("RECONSTRUCTION_RUN_STDERR")
        print(stderr)

    report_path = out_dir / "reconstruction_report.json"
    run_success = proc.returncode == 0 and report_path.exists()
    print(f"RUN_RETURN_CODE={proc.returncode}")
    print(f"RUN_REPORT_EXISTS={report_path.exists()}")
    print(f"RUN_SUCCESS={run_success}")


if __name__ == "__main__":
    main()
