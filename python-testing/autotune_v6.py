import importlib.util
import itertools
import json
import subprocess
import sys
from pathlib import Path

import cv2
import numpy as np


def load_module(module_path: Path):
    spec = importlib.util.spec_from_file_location("fisheye_reconstruction", str(module_path))
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not load module spec from {module_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def hv_line_length_score(rectified_bgr: np.ndarray, angle_tolerance_deg: float = 12.0) -> float:
    gray = cv2.cvtColor(rectified_bgr, cv2.COLOR_BGR2GRAY)
    edges = cv2.Canny(gray, 50, 150, apertureSize=3, L2gradient=True)
    lines = cv2.HoughLinesP(
        edges,
        rho=1,
        theta=np.pi / 180.0,
        threshold=35,
        minLineLength=20,
        maxLineGap=6,
    )
    if lines is None:
        return 0.0

    total_length = 0.0
    for line in lines[:, 0, :]:
        x1, y1, x2, y2 = [float(v) for v in line]
        dx = x2 - x1
        dy = y2 - y1
        length = float(np.hypot(dx, dy))
        angle = abs(float(np.degrees(np.arctan2(dy, dx))))
        if angle > 90.0:
            angle = 180.0 - angle
        is_near_horizontal = angle <= angle_tolerance_deg
        is_near_vertical = abs(angle - 90.0) <= angle_tolerance_deg
        if is_near_horizontal or is_near_vertical:
            total_length += length
    return total_length


def main() -> None:
    root = Path.cwd()
    module_path = root / "python-testing" / "fisheye-reconstruction.py"
    input_dir = root / "test-ntsc-images"
    output_dir = root / "python-testing" / "reconstruction-output-v6-autotuned"

    mod = load_module(module_path)

    image_paths = sorted(input_dir.glob("*.png"))
    if not image_paths:
        raise FileNotFoundError(f"No PNG images found in {input_dir}")

    crops = []
    for image_path in image_paths:
        frame = cv2.imread(str(image_path), cv2.IMREAD_COLOR)
        if frame is None:
            raise ValueError(f"Failed to read image: {image_path}")
        x, y, w, h, sat = mod.detect_active_bbox(frame_bgr=frame, bbox_width=320, bbox_height=240)
        crop = frame[y : y + h, x : x + w]
        crops.append((image_path, crop, sat))

    projection_models = ["rectilinear", "equidistant", "equisolid", "stereographic", "orthographic"]
    input_hfov_vals = [92, 95, 98, 101, 104]
    output_hfov_vals = [88, 90, 92, 94, 96, 98]
    correction_vals = [0.7, 0.85, 1.0, 1.15, 1.3]

    results = []
    for projection_model, input_hfov_deg, output_hfov_deg, correction_strength in itertools.product(
        projection_models,
        input_hfov_vals,
        output_hfov_vals,
        correction_vals,
    ):
        h, w = crops[0][1].shape[:2]
        map_x, map_y = mod.build_lens_to_pinhole_map(
            src_width=w,
            src_height=h,
            input_hfov_deg=float(input_hfov_deg),
            output_hfov_deg=float(output_hfov_deg),
            correction_strength=float(correction_strength),
            projection_model=projection_model,
        )
        valid_ratio = float(
            np.mean((map_x >= 0.0) & (map_x <= (w - 1)) & (map_y >= 0.0) & (map_y <= (h - 1)))
        )

        per_image_scores = []
        line_sums = []
        for _, crop, _ in crops:
            rectified = mod.rectify_crop(
                crop_bgr=crop,
                input_hfov_deg=float(input_hfov_deg),
                output_hfov_deg=float(output_hfov_deg),
                correction_strength=float(correction_strength),
                projection_model=projection_model,
            )
            line_sum = hv_line_length_score(rectified)
            line_sums.append(line_sum)
            per_image_scores.append(line_sum * valid_ratio)

        avg_score = float(np.mean(per_image_scores))
        avg_line_sum = float(np.mean(line_sums))
        results.append(
            {
                "projection_model": projection_model,
                "input_hfov_deg": float(input_hfov_deg),
                "output_hfov_deg": float(output_hfov_deg),
                "correction_strength": float(correction_strength),
                "valid_mapping_ratio": valid_ratio,
                "avg_line_sum": avg_line_sum,
                "score": avg_score,
            }
        )

    results.sort(key=lambda r: r["score"], reverse=True)
    top12 = results[:12]

    print("Top 12 candidates by score (descending):")
    print(
        f"{'rank':>4} {'score':>12} {'line_sum':>12} {'valid_ratio':>11} "
        f"{'projection':>13} {'in_hfov':>8} {'out_hfov':>9} {'strength':>9}"
    )
    for idx, r in enumerate(top12, start=1):
        print(
            f"{idx:4d} {r['score']:12.2f} {r['avg_line_sum']:12.2f} {r['valid_mapping_ratio']:11.4f} "
            f"{r['projection_model']:>13} {r['input_hfov_deg']:8.1f} {r['output_hfov_deg']:9.1f} {r['correction_strength']:9.2f}"
        )

    best = top12[0]
    best_params = {
        "projection_model": best["projection_model"],
        "input_hfov_deg": best["input_hfov_deg"],
        "output_hfov_deg": best["output_hfov_deg"],
        "correction_strength": best["correction_strength"],
    }
    print("BEST_PARAMETERS:")
    print(json.dumps(best_params, indent=2))

    output_dir.mkdir(parents=True, exist_ok=True)
    cmd = [
        sys.executable,
        str(module_path),
        "--input-dir",
        str(input_dir),
        "--output-dir",
        str(output_dir),
        "--input-hfov-deg",
        str(best_params["input_hfov_deg"]),
        "--output-hfov-deg",
        str(best_params["output_hfov_deg"]),
        "--correction-strength",
        str(best_params["correction_strength"]),
        "--projection-model",
        str(best_params["projection_model"]),
    ]
    subprocess.run(cmd, check=True)
    print(f"Autotuned reconstruction output: {output_dir}")


if __name__ == "__main__":
    main()
