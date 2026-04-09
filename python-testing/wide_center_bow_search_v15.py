import json
import math
from pathlib import Path
import random
import subprocess
import cv2
import numpy as np

ROOT = Path(r"C:/Users/ezrar/cornell-classes/Spring 2026/ECE 5760/stereo_vision")
IMG_DIR = ROOT / "test-ntsc-images"
OUT_JSON = ROOT / "python-testing/wide_center_bow_search_v15_results.json"
OUT_DIR = ROOT / "python-testing/reconstruction-output-v15-wide-center-opt"
SCRIPT = ROOT / "python-testing/fisheye-reconstruction.py"

random.seed(0)

SOURCES = [
    IMG_DIR / "vga_capture_19700101_004956_000.png",
    IMG_DIR / "vga_capture_19700101_005020_001.png",
]
BBOX = (100, 50, 320, 240)


def build_map(h, w, input_hfov_deg, output_hfov_deg, strength, cx_off, cy_off, k1, k2):
    f_in = (w / 2.0) / math.tan(math.radians(input_hfov_deg) / 2.0)
    f_out = (w / 2.0) / math.tan(math.radians(output_hfov_deg) / 2.0)
    cx = (w - 1) / 2.0 + cx_off
    cy = (h - 1) / 2.0 + cy_off

    yy, xx = np.indices((h, w), dtype=np.float32)
    x = (xx - cx) / f_out
    y = (yy - cy) / f_out
    r_dst = np.sqrt(x * x + y * y)

    theta = np.arctan(r_dst)
    r_src = np.tan(theta)  # rectilinear source model

    r_blend = (1.0 - strength) * r_dst + strength * r_src

    eps = 1e-9
    scale = np.ones_like(r_dst, dtype=np.float32)
    mask = r_dst > eps
    scale[mask] = (r_blend[mask] / r_dst[mask]).astype(np.float32)

    x_u = x * scale
    y_u = y * scale

    r2 = x_u * x_u + y_u * y_u
    radial = 1.0 + k1 * r2 + k2 * (r2 * r2)
    x_u = x_u * radial
    y_u = y_u * radial

    map_x = (x_u * f_in + cx).astype(np.float32)
    map_y = (y_u * f_in + cy).astype(np.float32)
    return map_x, map_y


def track_table_edge(gray, y0=145, y1=190, max_step=4):
    h, w = gray.shape
    y0 = max(1, min(h - 2, y0))
    y1 = max(y0 + 2, min(h - 1, y1))

    gy = cv2.Sobel(gray, cv2.CV_32F, 0, 1, ksize=3)
    mag = np.abs(gy)
    band = mag[y0:y1, :]
    ys = np.arange(y0, y1)

    cx = w // 2
    center_col = band[:, cx]
    start_idx = int(np.argmax(center_col))
    y_path = np.zeros(w, dtype=np.float32)
    y_path[cx] = ys[start_idx]

    for x in range(cx + 1, w):
        prev = int(y_path[x - 1])
        lo = max(y0, prev - max_step)
        hi = min(y1 - 1, prev + max_step)
        col = mag[lo:hi + 1, x]
        y_path[x] = lo + int(np.argmax(col))

    for x in range(cx - 1, -1, -1):
        prev = int(y_path[x + 1])
        lo = max(y0, prev - max_step)
        hi = min(y1 - 1, prev + max_step)
        col = mag[lo:hi + 1, x]
        y_path[x] = lo + int(np.argmax(col))

    grad_conf = float(np.mean(mag[y_path.astype(np.int32), np.arange(w)]))

    X = np.arange(w, dtype=np.float32)
    xc = (w - 1) / 2.0
    x = X - xc
    a, b, c = np.polyfit(x, y_path, 2)
    bow_px = float(abs(a) * (xc ** 2))
    return bow_px, grad_conf


def rectify_score(img, p):
    x, y, w, h = BBOX
    crop = img[y:y+h, x:x+w]
    map_x, map_y = build_map(
        h,
        w,
        p["input_hfov_deg"],
        p["output_hfov_deg"],
        p["correction_strength"],
        p["center_x_offset_px"],
        p["center_y_offset_px"],
        p["residual_k1"],
        p["residual_k2"],
    )
    rect = cv2.remap(crop, map_x, map_y, interpolation=cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT)
    gray = cv2.cvtColor(rect, cv2.COLOR_BGR2GRAY)
    bow, conf = track_table_edge(gray)
    return bow, conf


def objective(bows, confs):
    m = float(np.mean(bows))
    s = float(np.std(bows))
    c = float(np.mean(confs))
    penalty = 0.0
    if c < 16.0:
        penalty += (16.0 - c) * 0.9
    return m + 0.08 * s + penalty


imgs = []
for p in SOURCES:
    im = cv2.imread(str(p), cv2.IMREAD_COLOR)
    if im is None:
        raise RuntimeError(f"Failed to load {p}")
    imgs.append(im)

trials = []
N = 600
for _ in range(N):
    params = {
        "projection_model": "rectilinear",
        "input_hfov_deg": random.uniform(96.0, 116.0),
        "output_hfov_deg": random.uniform(74.0, 92.0),
        "correction_strength": random.uniform(0.9, 1.8),
        "center_x_offset_px": random.uniform(-40.0, 40.0),
        "center_y_offset_px": random.uniform(-40.0, 40.0),
        "residual_k1": random.uniform(-0.15, 0.15),
        "residual_k2": random.uniform(-0.08, 0.08),
    }

    bows = []
    confs = []
    ok = True
    for im in imgs:
        try:
            bow, conf = rectify_score(im, params)
        except Exception:
            ok = False
            break
        bows.append(bow)
        confs.append(conf)

    if not ok:
        continue

    score = objective(bows, confs)
    row = dict(params)
    row.update(
        {
            "bow_mean_px": float(np.mean(bows)),
            "bow_std_px": float(np.std(bows)),
            "confidence_mean": float(np.mean(confs)),
            "score": float(score),
        }
    )
    trials.append(row)

trials.sort(key=lambda r: r["score"])
if not trials:
    raise RuntimeError("No valid trials")

best = trials[0]
top12 = trials[:12]

OUT_JSON.parent.mkdir(parents=True, exist_ok=True)
OUT_JSON.write_text(json.dumps({"best": best, "top12": top12}, indent=2), encoding="utf-8")

print("TOP12")
for i, r in enumerate(top12, start=1):
    print(
        f"{i:02d} score={r['score']:.4f} bow_mean={r['bow_mean_px']:.4f} bow_std={r['bow_std_px']:.4f} conf={r['confidence_mean']:.2f} "
        f"in={r['input_hfov_deg']:.2f} out={r['output_hfov_deg']:.2f} str={r['correction_strength']:.3f} "
        f"cx={r['center_x_offset_px']:.2f} cy={r['center_y_offset_px']:.2f} k1={r['residual_k1']:.4f} k2={r['residual_k2']:.4f}"
    )

cmd = [
    "python-testing/fisheye-reconstruction.py",
    "--input-dir", "test-ntsc-images",
    "--output-dir", str(OUT_DIR.relative_to(ROOT)).replace("\\", "/"),
    "--profile", "razer_v3",
    "--projection-model", "rectilinear",
    "--input-hfov", str(best["input_hfov_deg"]),
    "--output-hfov", str(best["output_hfov_deg"]),
    "--correction-strength", str(best["correction_strength"]),
    "--center-x-offset-px", str(best["center_x_offset_px"]),
    "--center-y-offset-px", str(best["center_y_offset_px"]),
    "--residual-k1", str(best["residual_k1"]),
    "--residual-k2", str(best["residual_k2"]),
]

import sys
py = ROOT / ".venv/Scripts/python.exe"
subprocess.run([str(py)] + cmd, cwd=str(ROOT), check=True)

print("BEST", json.dumps(best))
print("OUT_JSON", OUT_JSON)
print("OUT_DIR", OUT_DIR)
print("OUT_FILES", [p.name for p in sorted(OUT_DIR.glob("*"))])
