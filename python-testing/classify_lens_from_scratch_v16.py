import importlib.util
import json
import math
import random
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import cv2
import numpy as np


@dataclass
class Candidate:
    projection_model: str
    input_hfov_deg: float
    output_hfov_deg: float
    correction_strength: float
    center_x_offset_px: float
    center_y_offset_px: float
    residual_k1: float
    residual_k2: float


def load_module(module_path: Path):
    spec = importlib.util.spec_from_file_location("fisheye_reconstruction_mod", module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load module from {module_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def clamp(x: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, x))


def track_horizontal_edge(
    gray: np.ndarray,
    y0: int,
    y1: int,
    max_step: int = 4,
) -> tuple[np.ndarray, float]:
    h, w = gray.shape
    y0 = max(1, min(h - 2, y0))
    y1 = max(y0 + 2, min(h - 1, y1))

    gy = cv2.Sobel(gray, cv2.CV_32F, 0, 1, ksize=3)
    mag = np.abs(gy)
    band = mag[y0:y1, :]
    ys = np.arange(y0, y1, dtype=np.int32)

    cx = w // 2
    center_col = band[:, cx]
    start_idx = int(np.argmax(center_col))

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


def track_vertical_edge(
    gray: np.ndarray,
    x0: int,
    x1: int,
    max_step: int = 4,
) -> tuple[np.ndarray, float]:
    h, w = gray.shape
    x0 = max(1, min(w - 2, x0))
    x1 = max(x0 + 2, min(w - 1, x1))

    gx = cv2.Sobel(gray, cv2.CV_32F, 1, 0, ksize=3)
    mag = np.abs(gx)

    cy = h // 2
    row = mag[cy, x0:x1]
    start_idx = int(np.argmax(row))
    start_x = x0 + start_idx

    x_path = np.zeros(h, dtype=np.float32)
    x_path[cy] = float(start_x)

    for y in range(cy + 1, h):
        prev = int(x_path[y - 1])
        lo = max(x0, prev - max_step)
        hi = min(x1 - 1, prev + max_step)
        segment = mag[y, lo : hi + 1]
        x_path[y] = float(lo + int(np.argmax(segment)))

    for y in range(cy - 1, -1, -1):
        prev = int(x_path[y + 1])
        lo = max(x0, prev - max_step)
        hi = min(x1 - 1, prev + max_step)
        segment = mag[y, lo : hi + 1]
        x_path[y] = float(lo + int(np.argmax(segment)))

    conf = float(np.mean(mag[np.arange(h, dtype=np.int32), x_path.astype(np.int32)]))
    return x_path, conf


def bow_metric_from_horizontal_path(y_path: np.ndarray) -> float:
    w = y_path.shape[0]
    x = np.arange(w, dtype=np.float64)
    cx = (w - 1) * 0.5
    xm = x - cx
    a, b, c = np.polyfit(xm, y_path.astype(np.float64), 2)
    _ = b, c
    return float(abs(a) * (cx**2))


def bow_metric_from_vertical_path(x_path: np.ndarray) -> float:
    h = x_path.shape[0]
    y = np.arange(h, dtype=np.float64)
    cy = (h - 1) * 0.5
    ym = y - cy
    a, b, c = np.polyfit(ym, x_path.astype(np.float64), 2)
    _ = b, c
    return float(abs(a) * (cy**2))


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


def evaluate_candidate(
    module: Any,
    crops: list[np.ndarray],
    cand: Candidate,
) -> dict[str, Any]:
    h, w = crops[0].shape[:2]
    map_x, map_y = module.build_lens_to_pinhole_map(
        src_width=w,
        src_height=h,
        input_hfov_deg=cand.input_hfov_deg,
        output_hfov_deg=cand.output_hfov_deg,
        correction_strength=cand.correction_strength,
        projection_model=cand.projection_model,
        center_x_offset_px=cand.center_x_offset_px,
        center_y_offset_px=cand.center_y_offset_px,
        residual_k1=cand.residual_k1,
        residual_k2=cand.residual_k2,
    )

    valid = (
        (map_x >= 0.0)
        & (map_x <= float(w - 1))
        & (map_y >= 0.0)
        & (map_y <= float(h - 1))
    )
    valid_ratio = float(valid.mean())

    table_bows: list[float] = []
    table_bows_alt: list[float] = []
    top_bows: list[float] = []
    vert_bows: list[float] = []
    confs: list[float] = []
    hv_scores: list[float] = []

    for crop in crops:
        rectified = cv2.remap(
            crop,
            map_x,
            map_y,
            interpolation=cv2.INTER_LINEAR,
            borderMode=cv2.BORDER_CONSTANT,
            borderValue=(0, 0, 0),
        )
        gray = cv2.cvtColor(rectified, cv2.COLOR_BGR2GRAY)

        y_table, c_table = track_horizontal_edge(gray, y0=144, y1=196, max_step=4)
        y_table_alt, c_table_alt = track_horizontal_edge(gray, y0=122, y1=174, max_step=4)
        y_top, c_top = track_horizontal_edge(gray, y0=16, y1=92, max_step=4)
        x_left, c_left = track_vertical_edge(gray, x0=18, x1=124, max_step=4)
        x_right, c_right = track_vertical_edge(gray, x0=w - 124, x1=w - 18, max_step=4)

        table_bows.append(bow_metric_from_horizontal_path(y_table))
        table_bows_alt.append(bow_metric_from_horizontal_path(y_table_alt))
        top_bows.append(bow_metric_from_horizontal_path(y_top))
        vert_bows.append(0.5 * (bow_metric_from_vertical_path(x_left) + bow_metric_from_vertical_path(x_right)))
        confs.append(0.20 * (c_table + c_table_alt + c_top + c_left + c_right))
        hv_scores.append(hv_hough_score(gray))

    m_table = float(np.mean(table_bows))
    s_table = float(np.std(table_bows))
    m_table_alt = float(np.mean(table_bows_alt))
    s_table_alt = float(np.std(table_bows_alt))
    m_top = float(np.mean(top_bows))
    m_vert = float(np.mean(vert_bows))
    s_vert = float(np.std(vert_bows))
    m_conf = float(np.mean(confs))
    m_hv = float(np.mean(hv_scores))

    param_reg = (
        0.05 * abs(cand.center_x_offset_px)
        + 0.05 * abs(cand.center_y_offset_px)
        + 6.0 * abs(cand.residual_k1)
        + 12.0 * abs(cand.residual_k2)
        + 2.0 * abs(cand.correction_strength - 1.0)
        + 0.04 * abs(cand.input_hfov_deg - 98.0)
        + 0.03 * abs(cand.output_hfov_deg - 82.0)
    )

    final_score = (
        24.0 * m_table
        + 9.0 * s_table
        + 8.0 * m_table_alt
        + 3.5 * s_table_alt
        + 1.8 * m_top
        + 0.8 * m_vert
        + 0.4 * s_vert
        + param_reg
        + 1800.0 * max(0.0, 0.997 - valid_ratio)
        + 0.05 * max(0.0, 130.0 - m_conf)
        - 0.0045 * m_hv
    )

    return {
        "projection_model": cand.projection_model,
        "input_hfov_deg": float(cand.input_hfov_deg),
        "output_hfov_deg": float(cand.output_hfov_deg),
        "correction_strength": float(cand.correction_strength),
        "center_x_offset_px": float(cand.center_x_offset_px),
        "center_y_offset_px": float(cand.center_y_offset_px),
        "residual_k1": float(cand.residual_k1),
        "residual_k2": float(cand.residual_k2),
        "table_bow_mean_px": m_table,
        "table_bow_std_px": s_table,
        "table_bow_alt_mean_px": m_table_alt,
        "table_bow_alt_std_px": s_table_alt,
        "top_bow_mean_px": m_top,
        "vertical_bow_mean_px": m_vert,
        "vertical_bow_std_px": s_vert,
        "edge_confidence_mean": m_conf,
        "hv_hough_mean": m_hv,
        "valid_ratio": valid_ratio,
        "param_reg": float(param_reg),
        "final_score": float(final_score),
    }


def random_candidate(model: str, rng: random.Random) -> Candidate:
    return Candidate(
        projection_model=model,
        input_hfov_deg=rng.uniform(92.0, 118.0),
        output_hfov_deg=rng.uniform(72.0, 95.0),
        correction_strength=rng.uniform(0.55, 1.70),
        center_x_offset_px=rng.uniform(-30.0, 30.0),
        center_y_offset_px=rng.uniform(-30.0, 30.0),
        residual_k1=rng.uniform(-0.14, 0.14),
        residual_k2=rng.uniform(-0.06, 0.06),
    )


def refined_candidate(base: dict[str, Any], rng: random.Random) -> Candidate:
    return Candidate(
        projection_model=str(base["projection_model"]),
        input_hfov_deg=clamp(rng.gauss(float(base["input_hfov_deg"]), 3.5), 92.0, 118.0),
        output_hfov_deg=clamp(rng.gauss(float(base["output_hfov_deg"]), 2.5), 72.0, 95.0),
        correction_strength=clamp(rng.gauss(float(base["correction_strength"]), 0.17), 0.55, 1.70),
        center_x_offset_px=clamp(rng.gauss(float(base["center_x_offset_px"]), 6.0), -30.0, 30.0),
        center_y_offset_px=clamp(rng.gauss(float(base["center_y_offset_px"]), 6.0), -30.0, 30.0),
        residual_k1=clamp(rng.gauss(float(base["residual_k1"]), 0.04), -0.14, 0.14),
        residual_k2=clamp(rng.gauss(float(base["residual_k2"]), 0.02), -0.06, 0.06),
    )


def to_reconstruction_args(best: dict[str, Any], out_dir: Path) -> list[str]:
    return [
        "python-testing/fisheye-reconstruction.py",
        "--input-dir",
        "test-ntsc-images",
        "--output-dir",
        str(out_dir).replace("\\", "/"),
        "--profile",
        "razer_v3",
        "--projection-model",
        str(best["projection_model"]),
        "--input-hfov-deg",
        str(best["input_hfov_deg"]),
        "--output-hfov-deg",
        str(best["output_hfov_deg"]),
        "--correction-strength",
        str(best["correction_strength"]),
        "--center-x-offset-px",
        str(best["center_x_offset_px"]),
        "--center-y-offset-px",
        str(best["center_y_offset_px"]),
        "--residual-k1",
        str(best["residual_k1"]),
        "--residual-k2",
        str(best["residual_k2"]),
    ]


def main() -> None:
    root = Path.cwd()
    module_path = root / "python-testing" / "fisheye-reconstruction.py"
    module = load_module(module_path)

    image_paths = sorted((root / "test-ntsc-images").glob("*.png"))
    if not image_paths:
        raise RuntimeError("No images found in test-ntsc-images")

    frames: list[tuple[Path, np.ndarray]] = []
    for p in image_paths:
        img = cv2.imread(str(p), cv2.IMREAD_COLOR)
        if img is None:
            raise RuntimeError(f"Failed to load {p}")
        frames.append((p, img))

    crops: list[np.ndarray] = []
    crop_info: list[dict[str, Any]] = []
    for p, frame in frames:
        x, y, w, h, sat = module.detect_active_bbox(frame, bbox_width=320, bbox_height=240)
        crop = frame[y : y + h, x : x + w]
        crops.append(crop)
        crop_info.append(
            {
                "file": p.name,
                "bbox": {"x": int(x), "y": int(y), "w": int(w), "h": int(h)},
                "mean_saturation": float(sat),
            }
        )

    models = ["equidistant", "equisolid", "stereographic", "orthographic", "rectilinear"]
    seed = 20260409 + 17
    rng = random.Random(seed)

    stage1_per_model = 320
    stage2_per_seed = 180
    stage2_seeds_per_model = 2

    all_results: list[dict[str, Any]] = []
    stage1_results_by_model: dict[str, list[dict[str, Any]]] = {m: [] for m in models}

    for model in models:
        for _ in range(stage1_per_model):
            cand = random_candidate(model, rng)
            result = evaluate_candidate(module, crops, cand)
            all_results.append(result)
            stage1_results_by_model[model].append(result)

    for model in models:
        model_stage1_sorted = sorted(stage1_results_by_model[model], key=lambda r: r["final_score"])
        seeds_for_refine = model_stage1_sorted[:stage2_seeds_per_model]
        for base in seeds_for_refine:
            for _ in range(stage2_per_seed):
                cand = refined_candidate(base, rng)
                result = evaluate_candidate(module, crops, cand)
                all_results.append(result)

    all_sorted = sorted(all_results, key=lambda r: r["final_score"])

    best_per_model: dict[str, dict[str, Any]] = {}
    for model in models:
        rows = [r for r in all_sorted if r["projection_model"] == model]
        best_per_model[model] = rows[0]

    best = all_sorted[0]

    output_dir = root / "python-testing" / "reconstruction-output-v17-from-scratch-classified"
    output_dir.mkdir(parents=True, exist_ok=True)

    py_exec = str(Path(sys.executable))
    cmd = [py_exec] + to_reconstruction_args(best, output_dir)
    proc = subprocess.run(cmd, cwd=str(root), capture_output=True, text=True)

    report = {
        "seed": seed,
        "crop_info": crop_info,
        "search": {
            "stage1_per_model": stage1_per_model,
            "stage2_seeds_per_model": stage2_seeds_per_model,
            "stage2_per_seed": stage2_per_seed,
            "total_candidates": len(all_results),
        },
        "best_overall": best,
        "best_per_model": best_per_model,
        "top20_overall": all_sorted[:20],
        "reconstruction": {
            "return_code": int(proc.returncode),
            "stdout": proc.stdout,
            "stderr": proc.stderr,
            "output_dir": str(output_dir),
        },
    }

    out_json = root / "python-testing" / "classification_v17_from_scratch_results.json"
    out_json.write_text(json.dumps(report, indent=2), encoding="utf-8")

    print("BEST_OVERALL")
    print(json.dumps(best, indent=2))
    print("BEST_PER_MODEL")
    for m in models:
        rec = best_per_model[m]
        print(
            f"{m:12s} score={rec['final_score']:.6f} table={rec['table_bow_mean_px']:.4f} "
            f"vert={rec['vertical_bow_mean_px']:.4f} top={rec['top_bow_mean_px']:.4f} "
            f"hv={rec['hv_hough_mean']:.1f}"
        )
    print(f"RECON_RETURN_CODE={proc.returncode}")
    print(f"RESULT_JSON={out_json}")
    print(f"OUTPUT_DIR={output_dir}")


if __name__ == "__main__":
    main()
