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


def smoothstep01(t: np.ndarray) -> np.ndarray:
    t = np.clip(t, 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def alpha_profile(h: int, alpha_top: float, alpha_bottom: float, y0: int, y1: int) -> np.ndarray:
    if y1 <= y0:
        return np.full((h,), alpha_bottom, dtype=np.float32)
    y = np.arange(h, dtype=np.float32)
    t = (y - float(y0)) / float(y1 - y0)
    s = smoothstep01(t)
    return (alpha_top + (alpha_bottom - alpha_top) * s).astype(np.float32)


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
        y_path[x] = float(lo + int(np.argmax(mag[lo : hi + 1, x])))

    for x in range(cx - 1, -1, -1):
        prev = int(y_path[x + 1])
        lo = max(y0, prev - max_step)
        hi = min(y1 - 1, prev + max_step)
        y_path[x] = float(lo + int(np.argmax(mag[lo : hi + 1, x])))

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


def evaluate_maps(crops: list[np.ndarray], map_x: np.ndarray, map_y: np.ndarray) -> dict[str, float]:
    # Multiple top bands to capture "lights in a row" relative curvature.
    top_bands = [(8, 42), (18, 56), (30, 72), (42, 86)]
    bottom_bands = [(120, 172), (142, 194)]

    frame_top_abs: list[float] = []
    frame_top_spread: list[float] = []
    frame_top_signed_mean: list[float] = []

    frame_bottom_abs: list[float] = []
    frame_bottom_spread: list[float] = []

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

        top_signed: list[float] = []
        bot_signed: list[float] = []
        conf_acc = 0.0

        for y0, y1 in top_bands:
            path, c = track_horizontal_edge(gray, y0, y1, max_step=4)
            top_signed.append(signed_bow_px(path))
            conf_acc += c

        for y0, y1 in bottom_bands:
            path, c = track_horizontal_edge(gray, y0, y1, max_step=4)
            bot_signed.append(signed_bow_px(path))
            conf_acc += c

        top_signed_np = np.array(top_signed, dtype=np.float64)
        bot_signed_np = np.array(bot_signed, dtype=np.float64)

        frame_top_abs.append(float(np.mean(np.abs(top_signed_np))))
        frame_top_spread.append(float(np.std(top_signed_np)))
        frame_top_signed_mean.append(float(np.mean(top_signed_np)))

        frame_bottom_abs.append(float(np.mean(np.abs(bot_signed_np))))
        frame_bottom_spread.append(float(np.std(bot_signed_np)))

        confs.append(float(conf_acc / float(len(top_bands) + len(bottom_bands))))
        hvs.append(hv_hough_score(gray))

    top_abs_mean = float(np.mean(frame_top_abs))
    top_spread_mean = float(np.mean(frame_top_spread))
    top_signed_mean = float(np.mean(frame_top_signed_mean))

    bottom_abs_mean = float(np.mean(frame_bottom_abs))
    bottom_spread_mean = float(np.mean(frame_bottom_spread))

    conf_mean = float(np.mean(confs))
    hv_mean = float(np.mean(hvs))

    return {
        "top_abs_mean_px": top_abs_mean,
        "top_spread_mean_px": top_spread_mean,
        "top_signed_mean_px": top_signed_mean,
        "bottom_abs_mean_px": bottom_abs_mean,
        "bottom_spread_mean_px": bottom_spread_mean,
        "edge_confidence_mean": conf_mean,
        "hv_hough_mean": hv_mean,
    }


def make_blended_maps(
    map16_x: np.ndarray,
    map16_y: np.ndarray,
    map17_x: np.ndarray,
    map17_y: np.ndarray,
    alpha_top: float,
    alpha_bottom: float,
    y0: int,
    y1: int,
) -> tuple[np.ndarray, np.ndarray]:
    h = map16_x.shape[0]
    a = alpha_profile(h, alpha_top=alpha_top, alpha_bottom=alpha_bottom, y0=y0, y1=y1)[:, None]
    mx = ((1.0 - a) * map16_x + a * map17_x).astype(np.float32)
    my = ((1.0 - a) * map16_y + a * map17_y).astype(np.float32)
    return mx, my


def main() -> None:
    root = Path.cwd()

    report16_path = root / "python-testing" / "classification_v16_from_scratch_results.json"
    report17_path = root / "python-testing" / "classification_v17_from_scratch_results.json"
    if not report16_path.exists() or not report17_path.exists():
        raise RuntimeError("Missing v16 or v17 classification reports")

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

    # Baseline metrics from the two fixed blends the user liked.
    m045 = evaluate_maps(
        crops,
        *((0.55 * map16_x + 0.45 * map17_x).astype(np.float32), (0.55 * map16_y + 0.45 * map17_y).astype(np.float32)),
    )
    m050 = evaluate_maps(
        crops,
        *((0.50 * map16_x + 0.50 * map17_x).astype(np.float32), (0.50 * map16_y + 0.50 * map17_y).astype(np.float32)),
    )

    baseline_bottom = min(m045["bottom_abs_mean_px"], m050["bottom_abs_mean_px"])
    baseline_top = min(m045["top_abs_mean_px"], m050["top_abs_mean_px"])

    rows: list[dict[str, Any]] = []

    for alpha_bottom in (0.45, 0.50):
        for alpha_top in np.linspace(0.05, 0.95, 37):
            if abs(float(alpha_top) - alpha_bottom) < 0.03:
                continue
            for y0 in (0, 8, 16, 24, 32, 40):
                for y1 in (76, 88, 100, 112, 124, 136):
                    if y1 <= y0 + 20:
                        continue

                    mx, my = make_blended_maps(
                        map16_x,
                        map16_y,
                        map17_x,
                        map17_y,
                        alpha_top=float(alpha_top),
                        alpha_bottom=float(alpha_bottom),
                        y0=int(y0),
                        y1=int(y1),
                    )
                    m = evaluate_maps(crops, mx, my)

                    cost = (
                        4.2 * m["top_abs_mean_px"]
                        + 2.2 * m["top_spread_mean_px"]
                        + 2.8 * m["bottom_abs_mean_px"]
                        + 1.2 * m["bottom_spread_mean_px"]
                        + 0.4 * abs(m["top_signed_mean_px"])
                        + 0.04 * max(0.0, 140.0 - m["edge_confidence_mean"])
                        - 0.0022 * m["hv_hough_mean"]
                    )

                    # Guard rail: keep table/bottom close to what the user already liked.
                    if m["bottom_abs_mean_px"] > baseline_bottom + 0.35:
                        cost += 40.0 * (m["bottom_abs_mean_px"] - (baseline_bottom + 0.35))

                    row = {
                        "alpha_top": float(alpha_top),
                        "alpha_bottom": float(alpha_bottom),
                        "y_transition_start": int(y0),
                        "y_transition_end": int(y1),
                        **m,
                        "cost": float(cost),
                    }
                    rows.append(row)

    rows_sorted = sorted(rows, key=lambda r: r["cost"])

    preferred = [
        r
        for r in rows_sorted
        if r["bottom_abs_mean_px"] <= baseline_bottom + 0.25 and r["top_abs_mean_px"] <= baseline_top - 0.02
    ]
    if not preferred:
        preferred = [r for r in rows_sorted if r["bottom_abs_mean_px"] <= baseline_bottom + 0.25]
    if not preferred:
        preferred = rows_sorted

    best = preferred[0]

    mx_best, my_best = make_blended_maps(
        map16_x,
        map16_y,
        map17_x,
        map17_y,
        alpha_top=float(best["alpha_top"]),
        alpha_bottom=float(best["alpha_bottom"]),
        y0=int(best["y_transition_start"]),
        y1=int(best["y_transition_end"]),
    )

    out_dir = root / "python-testing" / "reconstruction-output-v19-topfix-spatialblend"
    out_dir.mkdir(parents=True, exist_ok=True)

    output_files: list[str] = []
    for p, crop in zip(image_paths, crops):
        rect = cv2.remap(
            crop,
            mx_best,
            my_best,
            interpolation=cv2.INTER_LINEAR,
            borderMode=cv2.BORDER_CONSTANT,
            borderValue=(0, 0, 0),
        )
        out_name = f"{p.stem}_rectified.png"
        out_path = out_dir / out_name
        ok = cv2.imwrite(str(out_path), rect)
        if not ok:
            raise RuntimeError(f"Failed to write {out_path}")
        output_files.append(out_name)

    report = {
        "source_reports": {
            "v16": str(report16_path),
            "v17": str(report17_path),
        },
        "crop_info": crop_info,
        "baseline": {
            "alpha_0_45": m045,
            "alpha_0_50": m050,
            "baseline_bottom_abs": baseline_bottom,
            "baseline_top_abs": baseline_top,
        },
        "search": {
            "candidate_count": len(rows),
            "alpha_top_range": [0.05, 0.95],
            "alpha_bottom_values": [0.45, 0.50],
            "y0_values": [0, 8, 16, 24, 32, 40],
            "y1_values": [76, 88, 100, 112, 124, 136],
        },
        "best": best,
        "top15": rows_sorted[:15],
        "output_dir": str(out_dir),
        "output_files": output_files,
    }

    out_json = root / "python-testing" / "spatial_blend_v19_topfix_report.json"
    out_json.write_text(json.dumps(report, indent=2), encoding="utf-8")

    print("BEST_V19")
    print(json.dumps(best, indent=2))
    print("BASELINE_045")
    print(json.dumps(m045, indent=2))
    print("BASELINE_050")
    print(json.dumps(m050, indent=2))
    print(f"REPORT_JSON={out_json}")
    print(f"OUTPUT_DIR={out_dir}")
    print("OUTPUT_FILES")
    for name in sorted(output_files):
        print(name)


if __name__ == "__main__":
    main()
