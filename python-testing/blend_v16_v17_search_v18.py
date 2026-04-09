import importlib.util
import json
import math
import sys
from pathlib import Path
from typing import Any

import cv2
import numpy as np


def load_module(module_path: Path):
    spec = importlib.util.spec_from_file_location("fisheye_reconstruction_mod", module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load module from {module_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def track_horizontal_edge(gray: np.ndarray, y0: int, y1: int, max_step: int = 4) -> tuple[np.ndarray, float]:
    h, w = gray.shape
    y0 = max(1, min(h - 2, int(y0)))
    y1 = max(y0 + 2, min(h - 1, int(y1)))

    gy = cv2.Sobel(gray, cv2.CV_32F, 0, 1, ksize=3)
    mag = np.abs(gy)

    band = mag[y0:y1, :]
    ys = np.arange(y0, y1, dtype=np.int32)

    cx = w // 2
    start_idx = int(np.argmax(band[:, cx]))

    y_path = np.zeros(w, dtype=np.float32)
    y_path[cx] = float(ys[start_idx])

    for x in range(cx + 1, w):
        prev = int(y_path[x - 1])
        lo = max(y0, prev - max_step)
        hi = min(y1 - 1, prev + max_step)
        col = mag[lo : hi + 1, x]
        y_path[x] = float(lo + int(np.argmax(col)))

    for x in range(cx - 1, -1, -1):
        prev = int(y_path[x + 1])
        lo = max(y0, prev - max_step)
        hi = min(y1 - 1, prev + max_step)
        col = mag[lo : hi + 1, x]
        y_path[x] = float(lo + int(np.argmax(col)))

    conf = float(np.mean(mag[y_path.astype(np.int32), np.arange(w, dtype=np.int32)]))
    return y_path, conf


def signed_bow_px(y_path: np.ndarray) -> float:
    w = y_path.shape[0]
    x = np.arange(w, dtype=np.float64)
    cx = (w - 1) * 0.5
    xm = x - cx
    a, b, c = np.polyfit(xm, y_path.astype(np.float64), 2)
    _ = b, c
    return float(a * (cx**2))


def hv_hough_score(gray: np.ndarray) -> float:
    small = cv2.resize(gray, (160, 120), interpolation=cv2.INTER_AREA)
    edges = cv2.Canny(small, 50, 140, L2gradient=True)
    lines = cv2.HoughLinesP(
        edges,
        rho=1,
        theta=np.pi / 180.0,
        threshold=24,
        minLineLength=16,
        maxLineGap=6,
    )
    if lines is None:
        return 0.0

    score = 0.0
    for line in lines[:, 0, :]:
        x1, y1, x2, y2 = map(float, line)
        dx = x2 - x1
        dy = y2 - y1
        length = float(math.hypot(dx, dy))
        if length < 3.0:
            continue
        angle = (float(np.degrees(np.arctan2(dy, dx))) + 180.0) % 180.0
        horizontal = min(angle, 180.0 - angle) <= 12.0
        vertical = abs(angle - 90.0) <= 12.0
        if horizontal or vertical:
            score += length
    return score * 2.0


def params_from_best(best: dict[str, Any]) -> dict[str, float | str]:
    return {
        "projection_model": str(best["projection_model"]),
        "input_hfov_deg": float(best["input_hfov_deg"]),
        "output_hfov_deg": float(best["output_hfov_deg"]),
        "correction_strength": float(best["correction_strength"]),
        "center_x_offset_px": float(best["center_x_offset_px"]),
        "center_y_offset_px": float(best["center_y_offset_px"]),
        "residual_k1": float(best["residual_k1"]),
        "residual_k2": float(best["residual_k2"]),
    }


def build_map(module: Any, w: int, h: int, p: dict[str, float | str]) -> tuple[np.ndarray, np.ndarray]:
    return module.build_lens_to_pinhole_map(
        src_width=w,
        src_height=h,
        input_hfov_deg=float(p["input_hfov_deg"]),
        output_hfov_deg=float(p["output_hfov_deg"]),
        correction_strength=float(p["correction_strength"]),
        projection_model=str(p["projection_model"]),
        center_x_offset_px=float(p["center_x_offset_px"]),
        center_y_offset_px=float(p["center_y_offset_px"]),
        residual_k1=float(p["residual_k1"]),
        residual_k2=float(p["residual_k2"]),
    )


def evaluate_alpha(crops: list[np.ndarray], map_x: np.ndarray, map_y: np.ndarray) -> dict[str, float]:
    primary_signed: list[float] = []
    secondary_signed: list[float] = []
    confs: list[float] = []
    hvs: list[float] = []

    for crop in crops:
        rect = cv2.remap(
            crop,
            map_x,
            map_y,
            interpolation=cv2.INTER_LINEAR,
            borderMode=cv2.BORDER_CONSTANT,
            borderValue=(0, 0, 0),
        )
        gray = cv2.cvtColor(rect, cv2.COLOR_BGR2GRAY)

        p_path, p_conf = track_horizontal_edge(gray, y0=142, y1=194, max_step=4)
        s_path, s_conf = track_horizontal_edge(gray, y0=120, y1=172, max_step=4)

        p_bow = signed_bow_px(p_path)
        s_bow = signed_bow_px(s_path)

        primary_signed.append(p_bow)
        secondary_signed.append(s_bow)
        confs.append(0.5 * (p_conf + s_conf))
        hvs.append(hv_hough_score(gray))

    mean_abs_primary = float(np.mean(np.abs(primary_signed)))
    mean_abs_secondary = float(np.mean(np.abs(secondary_signed)))
    std_primary = float(np.std(primary_signed))
    mean_signed_primary = float(np.mean(primary_signed))
    mean_conf = float(np.mean(confs))
    mean_hv = float(np.mean(hvs))

    cost = (
        1.00 * mean_abs_primary
        + 0.45 * mean_abs_secondary
        + 0.20 * std_primary
        + max(0.0, 4300.0 - mean_hv) / 2500.0
        + 0.04 * max(0.0, 120.0 - mean_conf)
    )

    return {
        "mean_abs_primary_bow_px": mean_abs_primary,
        "mean_abs_secondary_bow_px": mean_abs_secondary,
        "std_primary_bow_px": std_primary,
        "mean_signed_primary_bow_px": mean_signed_primary,
        "edge_confidence_mean": mean_conf,
        "hv_hough_mean": mean_hv,
        "cost": float(cost),
    }


def main() -> None:
    root = Path.cwd()

    report16_path = root / "python-testing" / "classification_v16_from_scratch_results.json"
    report17_path = root / "python-testing" / "classification_v17_from_scratch_results.json"
    if not report16_path.exists() or not report17_path.exists():
        raise RuntimeError("Missing v16 or v17 classification report JSON")

    rep16 = json.loads(report16_path.read_text(encoding="utf-8"))
    rep17 = json.loads(report17_path.read_text(encoding="utf-8"))
    p16 = params_from_best(rep16["best_overall"])
    p17 = params_from_best(rep17["best_overall"])

    module_path = root / "python-testing" / "fisheye-reconstruction.py"
    module = load_module(module_path)

    image_paths = sorted((root / "test-ntsc-images").glob("*.png"))
    if not image_paths:
        raise RuntimeError("No images found in test-ntsc-images")

    crops: list[np.ndarray] = []
    crop_info: list[dict[str, Any]] = []
    for p in image_paths:
        frame = cv2.imread(str(p), cv2.IMREAD_COLOR)
        if frame is None:
            raise RuntimeError(f"Failed to load {p}")
        x, y, w, h, sat = module.detect_active_bbox(frame, bbox_width=320, bbox_height=240)
        crops.append(frame[y : y + h, x : x + w])
        crop_info.append(
            {
                "file": p.name,
                "bbox": {"x": int(x), "y": int(y), "w": int(w), "h": int(h)},
                "mean_saturation": float(sat),
            }
        )

    h, w = crops[0].shape[:2]
    map16_x, map16_y = build_map(module, w, h, p16)
    map17_x, map17_y = build_map(module, w, h, p17)

    alphas = [i / 40.0 for i in range(41)]
    rows: list[dict[str, Any]] = []

    for alpha in alphas:
        ax = ((1.0 - alpha) * map16_x + alpha * map17_x).astype(np.float32)
        ay = ((1.0 - alpha) * map16_y + alpha * map17_y).astype(np.float32)

        m = evaluate_alpha(crops, ax, ay)
        row = {"alpha": float(alpha)}
        row.update(m)
        rows.append(row)

    rows_sorted = sorted(rows, key=lambda r: r["cost"])
    best = rows_sorted[0]

    interior_rows = [r for r in rows_sorted if 0.05 <= float(r["alpha"]) <= 0.95]
    if not interior_rows:
        raise RuntimeError("No interior alpha candidates available")
    best_interior = interior_rows[0]

    best_alpha = float(best_interior["alpha"])
    map_best_x = ((1.0 - best_alpha) * map16_x + best_alpha * map17_x).astype(np.float32)
    map_best_y = ((1.0 - best_alpha) * map16_y + best_alpha * map17_y).astype(np.float32)

    out_dir = root / "python-testing" / "reconstruction-output-v18-between-v16-v17-interior"
    out_dir.mkdir(parents=True, exist_ok=True)

    written: list[str] = []
    for p, crop in zip(image_paths, crops):
        rect = cv2.remap(
            crop,
            map_best_x,
            map_best_y,
            interpolation=cv2.INTER_LINEAR,
            borderMode=cv2.BORDER_CONSTANT,
            borderValue=(0, 0, 0),
        )
        out_name = f"{p.stem}_rectified.png"
        out_path = out_dir / out_name
        ok = cv2.imwrite(str(out_path), rect)
        if not ok:
            raise RuntimeError(f"Failed to write {out_path}")
        written.append(out_name)

    midpoint = min(rows, key=lambda r: abs(float(r["alpha"]) - 0.5))

    report = {
        "source_reports": {
            "v16": str(report16_path),
            "v17": str(report17_path),
        },
        "params_v16": p16,
        "params_v17": p17,
        "crop_info": crop_info,
        "search": {
            "alpha_grid_count": len(alphas),
            "alpha_min": 0.0,
            "alpha_max": 1.0,
        },
        "best_unconstrained": best,
        "best_interior": best_interior,
        "midpoint": midpoint,
        "top10": rows_sorted[:10],
        "top10_interior": interior_rows[:10],
        "output_dir": str(out_dir),
        "output_files": written,
    }

    out_json = root / "python-testing" / "blend_v18_between_v16_v17_interior_report.json"
    out_json.write_text(json.dumps(report, indent=2), encoding="utf-8")

    print("BEST_UNCONSTRAINED_BLEND")
    print(json.dumps(best, indent=2))
    print("BEST_INTERIOR_BLEND")
    print(json.dumps(best_interior, indent=2))
    print("MIDPOINT_BLEND")
    print(json.dumps(midpoint, indent=2))
    print(f"REPORT_JSON={out_json}")
    print(f"OUTPUT_DIR={out_dir}")
    print("OUTPUT_FILES")
    for name in sorted(written):
        print(name)


if __name__ == "__main__":
    main()
