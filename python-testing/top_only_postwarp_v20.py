import json
import math
from pathlib import Path
from typing import Any

import cv2
import numpy as np


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


def top_weight(h: int, y_cut: int, power: float) -> np.ndarray:
    y = np.arange(h, dtype=np.float32)
    w = np.clip((float(y_cut) - y) / max(1.0, float(y_cut)), 0.0, 1.0)
    return np.power(w, power, dtype=np.float32)


def apply_top_postwarp(img: np.ndarray, k: float, y_cut: int, power: float) -> np.ndarray:
    h, w = img.shape[:2]
    cx = (w - 1) * 0.5

    xx, yy = np.meshgrid(np.arange(w, dtype=np.float32), np.arange(h, dtype=np.float32))
    wt = top_weight(h, y_cut=y_cut, power=power)[:, None]

    delta_y = (float(k) * ((xx - cx) ** 2) * wt).astype(np.float32)

    map_x = xx
    map_y = (yy + delta_y).astype(np.float32)

    return cv2.remap(
        img,
        map_x,
        map_y,
        interpolation=cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_REPLICATE,
    )


def evaluate_images(images: list[np.ndarray]) -> dict[str, float]:
    top_bands = [(8, 42), (18, 56), (30, 72), (42, 86)]
    bottom_bands = [(120, 172), (142, 194)]

    frame_top_abs: list[float] = []
    frame_top_spread: list[float] = []
    frame_top_signed_mean: list[float] = []

    frame_bottom_abs: list[float] = []
    frame_bottom_spread: list[float] = []

    confs: list[float] = []
    hvs: list[float] = []

    for img in images:
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)

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

    return {
        "top_abs_mean_px": float(np.mean(frame_top_abs)),
        "top_spread_mean_px": float(np.mean(frame_top_spread)),
        "top_signed_mean_px": float(np.mean(frame_top_signed_mean)),
        "bottom_abs_mean_px": float(np.mean(frame_bottom_abs)),
        "bottom_spread_mean_px": float(np.mean(frame_bottom_spread)),
        "edge_confidence_mean": float(np.mean(confs)),
        "hv_hough_mean": float(np.mean(hvs)),
    }


def main() -> None:
    root = Path.cwd()

    src_dir = root / "python-testing" / "reconstruction-output-v19-topfix-spatialblend"
    src_paths = sorted(src_dir.glob("*_rectified.png"))
    if not src_paths:
        raise RuntimeError(f"No rectified images found in {src_dir}")

    src_images: list[np.ndarray] = []
    for p in src_paths:
        img = cv2.imread(str(p), cv2.IMREAD_COLOR)
        if img is None:
            raise RuntimeError(f"Failed to load {p}")
        src_images.append(img)

    baseline = evaluate_images(src_images)
    baseline_bottom = baseline["bottom_abs_mean_px"]

    rows: list[dict[str, Any]] = []

    for k in np.linspace(-0.00045, 0.00045, 37):
        if abs(float(k)) < 1e-12:
            continue
        for y_cut in (84, 96, 108, 120, 132):
            for power in (1.5, 2.0, 2.5, 3.0):
                warped = [apply_top_postwarp(im, float(k), y_cut=y_cut, power=float(power)) for im in src_images]
                m = evaluate_images(warped)

                cost = (
                    5.0 * m["top_abs_mean_px"]
                    + 2.4 * m["top_spread_mean_px"]
                    + 0.6 * abs(m["top_signed_mean_px"])
                    + 0.8 * m["bottom_abs_mean_px"]
                    + 0.5 * m["bottom_spread_mean_px"]
                    + 0.05 * max(0.0, 150.0 - m["edge_confidence_mean"])
                    - 0.0022 * m["hv_hough_mean"]
                )

                if m["bottom_abs_mean_px"] > baseline_bottom + 0.10:
                    cost += 80.0 * (m["bottom_abs_mean_px"] - (baseline_bottom + 0.10))

                rows.append(
                    {
                        "k": float(k),
                        "y_cut": int(y_cut),
                        "power": float(power),
                        **m,
                        "cost": float(cost),
                    }
                )

    rows_sorted = sorted(rows, key=lambda r: r["cost"])

    preferred = [
        r
        for r in rows_sorted
        if r["bottom_abs_mean_px"] <= baseline_bottom + 0.08
        and r["top_abs_mean_px"] <= baseline["top_abs_mean_px"] - 0.10
    ]
    if not preferred:
        preferred = [r for r in rows_sorted if r["bottom_abs_mean_px"] <= baseline_bottom + 0.08]
    if not preferred:
        preferred = rows_sorted

    best = preferred[0]

    out_dir = root / "python-testing" / "reconstruction-output-v20-top-postwarp"
    out_dir.mkdir(parents=True, exist_ok=True)

    output_files: list[str] = []
    out_images: list[np.ndarray] = []
    for p, src in zip(src_paths, src_images):
        dst = apply_top_postwarp(src, k=float(best["k"]), y_cut=int(best["y_cut"]), power=float(best["power"]))
        out_path = out_dir / p.name
        ok = cv2.imwrite(str(out_path), dst)
        if not ok:
            raise RuntimeError(f"Failed to write {out_path}")
        output_files.append(p.name)
        out_images.append(dst)

    final_metrics = evaluate_images(out_images)

    report = {
        "source_dir": str(src_dir),
        "baseline": baseline,
        "search": {
            "candidate_count": len(rows),
            "k_values": [-0.00045, 0.00045, 37],
            "y_cut_values": [84, 96, 108, 120, 132],
            "power_values": [1.5, 2.0, 2.5, 3.0],
        },
        "best": best,
        "final_metrics": final_metrics,
        "top15": rows_sorted[:15],
        "output_dir": str(out_dir),
        "output_files": output_files,
    }

    out_json = root / "python-testing" / "top_only_postwarp_v20_report.json"
    out_json.write_text(json.dumps(report, indent=2), encoding="utf-8")

    print("BASELINE_V19")
    print(json.dumps(baseline, indent=2))
    print("BEST_V20")
    print(json.dumps(best, indent=2))
    print("FINAL_METRICS_V20")
    print(json.dumps(final_metrics, indent=2))
    print(f"REPORT_JSON={out_json}")
    print(f"OUTPUT_DIR={out_dir}")
    print("OUTPUT_FILES")
    for name in sorted(output_files):
        print(name)


if __name__ == "__main__":
    main()
