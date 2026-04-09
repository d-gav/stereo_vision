from pathlib import Path
import json
import cv2
import numpy as np

SRC_DIR = Path("python-testing/reconstruction-output-v7-near-perfect")
DST_DIR = Path("python-testing/reconstruction-output-v10-table-straight")
Y_MIN, Y_MAX = 90, 210


def track_table_edge(gray: np.ndarray, y_min: int, y_max: int, max_step: int = 6, penalty: float = 1.4):
    h, w = gray.shape
    y0 = max(0, y_min)
    y1 = min(h - 1, y_max)

    smooth = cv2.GaussianBlur(gray, (9, 5), 0)
    grad_y = cv2.Sobel(smooth, cv2.CV_32F, 0, 1, ksize=3)
    score = np.abs(grad_y[y0 : y1 + 1, :]).astype(np.float32)

    n_y, n_x = score.shape
    dp = np.full((n_y, n_x), -1e12, dtype=np.float32)
    prev = np.zeros((n_y, n_x), dtype=np.int16)

    y_mid = n_y // 2
    center_prior = -0.03 * (np.arange(n_y, dtype=np.float32) - y_mid) ** 2
    dp[:, 0] = score[:, 0] + center_prior

    y_indices = np.arange(n_y, dtype=np.int16)

    for x in range(1, n_x):
        prev_col = dp[:, x - 1]
        for y in range(n_y):
            lo = max(0, y - max_step)
            hi = min(n_y, y + max_step + 1)
            cand_idx = y_indices[lo:hi]
            cand = prev_col[lo:hi] - penalty * np.abs(cand_idx - y)
            best_rel = int(np.argmax(cand))
            best_prev = int(cand_idx[best_rel])
            dp[y, x] = score[y, x] + cand[best_rel]
            prev[y, x] = best_prev

    track_idx = np.empty(n_x, dtype=np.int32)
    track_idx[-1] = int(np.argmax(dp[:, -1]))
    for x in range(n_x - 2, -1, -1):
        track_idx[x] = int(prev[track_idx[x + 1], x + 1])

    y_track = track_idx + y0
    return y_track


def fit_quadratic(y_track: np.ndarray, width: int):
    x = np.arange(width, dtype=np.float64)
    cx = (width - 1) / 2.0
    xm = x - cx
    A = np.column_stack((xm * xm, xm, np.ones_like(xm)))
    coeffs, *_ = np.linalg.lstsq(A, y_track.astype(np.float64), rcond=None)
    a, b, c = coeffs
    return float(a), float(b), float(c), float(cx)


def apply_quadratic_vertical_correction(img: np.ndarray, a_global: float):
    h, w = img.shape[:2]
    cx = (w - 1) / 2.0
    x = np.arange(w, dtype=np.float32)
    y = np.arange(h, dtype=np.float32)

    delta_y = (a_global * (x - cx) ** 2).astype(np.float32)
    map_x = np.broadcast_to(x[None, :], (h, w)).copy()
    map_y = np.broadcast_to(y[:, None], (h, w)).copy() + delta_y[None, :]

    corrected = cv2.remap(
        img,
        map_x,
        map_y,
        interpolation=cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_REPLICATE,
    )
    return corrected


def main():
    image_paths = sorted(SRC_DIR.glob("*_rectified.png"))
    if len(image_paths) < 2:
        raise RuntimeError(f"Expected at least 2 rectified images in {SRC_DIR}, found {len(image_paths)}")

    DST_DIR.mkdir(parents=True, exist_ok=True)

    per_image = []
    loaded = []

    for path in image_paths[:2]:
        img = cv2.imread(str(path), cv2.IMREAD_COLOR)
        if img is None:
            raise RuntimeError(f"Failed to load image: {path}")

        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
        y_track = track_table_edge(gray, Y_MIN, Y_MAX)
        a, b, c, cx = fit_quadratic(y_track, gray.shape[1])

        per_image.append(
            {
                "filename": path.name,
                "a": a,
                "b": b,
                "c": c,
                "cx": cx,
            }
        )
        loaded.append((path.name, img))

    a_values = [item["a"] for item in per_image]
    a_global = float(np.mean(a_values))

    output_files = []
    for filename, img in loaded:
        corrected = apply_quadratic_vertical_correction(img, a_global)
        out_path = DST_DIR / filename
        ok = cv2.imwrite(str(out_path), corrected)
        if not ok:
            raise RuntimeError(f"Failed to write corrected image: {out_path}")
        output_files.append(out_path.name)

    report = {
        "source_dir": str(SRC_DIR),
        "output_dir": str(DST_DIR),
        "y_band": [Y_MIN, Y_MAX],
        "fit_model": "y = a*(x-cx)^2 + b*(x-cx) + c",
        "per_image": per_image,
        "a_values": a_values,
        "a_global": a_global,
        "output_files": output_files,
    }

    report_path = DST_DIR / "table_edge_quadratic_report.json"
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")

    print("Detected coefficients:")
    for item in per_image:
        print(f"  {item['filename']}: a={item['a']:.12f}, b={item['b']:.12f}")
    print(f"a_global={a_global:.12f}")

    print("Output files:")
    for name in sorted(output_files + [report_path.name]):
        print(f"  {name}")


if __name__ == "__main__":
    main()
