"""Apply ChArUco/checkerboard fisheye calibration to NTSC scene captures.

This script mirrors the map-generation/resampling approach used in
camera_calibration_charuco.py:
  - estimateNewCameraMatrixForUndistortRectify(...)
  - initUndistortRectifyMap(...)
  - remap(...)

It first crops the known 320x240 active image region from full 640x480 NTSC
captures and then undistorts that crop using the saved calibration.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Iterable

import cv2
import numpy as np


def parse_args() -> argparse.Namespace:
	parser = argparse.ArgumentParser(
		description=(
			"Apply ChArUco/checkerboard fisheye calibration to cropped NTSC captures."
		)
	)
	parser.add_argument(
		"--input-dir",
		type=Path,
		default=Path("test-ntsc-images"),
		help="Directory containing full-frame NTSC captures.",
	)
	parser.add_argument(
		"--output-dir",
		type=Path,
		default=Path("python-testing") / "reconstruction-output-charuco-calib",
		help="Directory for cropped and calibration-undistorted outputs.",
	)
	parser.add_argument(
		"--calibration-json",
		type=Path,
		default=Path("python-testing") / "calibration_results" / "calibration.json",
		help="Path to calibration JSON written by camera_calibration_charuco.py.",
	)
	parser.add_argument(
		"--crop-x",
		type=int,
		default=100,
		help="Active-region left offset in full-frame image.",
	)
	parser.add_argument(
		"--crop-y",
		type=int,
		default=50,
		help="Active-region top offset in full-frame image.",
	)
	parser.add_argument(
		"--crop-width",
		type=int,
		default=320,
		help="Active-region width.",
	)
	parser.add_argument(
		"--crop-height",
		type=int,
		default=240,
		help="Active-region height.",
	)
	parser.add_argument(
		"--balance",
		type=float,
		default=0.1,
		help="OpenCV fisheye balance parameter for new camera matrix.",
	)
	parser.add_argument(
		"--exts",
		nargs="+",
		default=["*.png", "*.jpg", "*.jpeg", "*.bmp"],
		help="Glob patterns used to collect images from --input-dir.",
	)
	parser.add_argument(
		"--save-debug",
		action="store_true",
		help="Write full-frame debug image with crop rectangle.",
	)
	return parser.parse_args()


def collect_images(input_dir: Path, exts: Iterable[str]) -> list[Path]:
	paths: list[Path] = []
	for pattern in exts:
		paths.extend(input_dir.glob(pattern))
	return sorted({p for p in paths if p.is_file()})


def load_calibration(calibration_json: Path) -> tuple[np.ndarray, np.ndarray, tuple[int, int], dict[str, object]]:
	payload = json.loads(calibration_json.read_text(encoding="utf-8"))
	model = payload.get("model", "")
	if model != "opencv_fisheye":
		raise ValueError(
			f"Unsupported calibration model {model!r}; expected 'opencv_fisheye'"
		)

	image_shape_hw_raw = payload.get("image_shape_hw")
	if not isinstance(image_shape_hw_raw, list) or len(image_shape_hw_raw) != 2:
		raise ValueError("calibration.json missing valid image_shape_hw")

	image_shape_hw = (int(image_shape_hw_raw[0]), int(image_shape_hw_raw[1]))
	camera_matrix = np.asarray(payload["camera_matrix"], dtype=np.float64)
	dist_coeffs = np.asarray(payload["dist_coeffs"], dtype=np.float64).reshape(-1, 1)

	if camera_matrix.shape != (3, 3):
		raise ValueError(f"camera_matrix must be 3x3; got shape {camera_matrix.shape}")
	if dist_coeffs.shape[0] != 4:
		raise ValueError(
			f"dist_coeffs must contain 4 fisheye terms; got shape {dist_coeffs.shape}"
		)

	return camera_matrix, dist_coeffs, image_shape_hw, payload


def build_undistort_map(
	camera_matrix: np.ndarray,
	dist_coeffs: np.ndarray,
	width: int,
	height: int,
	balance: float,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
	new_k = cv2.fisheye.estimateNewCameraMatrixForUndistortRectify(
		camera_matrix,
		dist_coeffs,
		(width, height),
		np.eye(3),
		balance=float(balance),
	)
	map_x, map_y = cv2.fisheye.initUndistortRectifyMap(
		camera_matrix,
		dist_coeffs,
		np.eye(3),
		new_k,
		(width, height),
		cv2.CV_32FC1,
	)
	return new_k, map_x, map_y


def crop_active_region(
	frame_bgr: np.ndarray,
	crop_x: int,
	crop_y: int,
	crop_w: int,
	crop_h: int,
) -> np.ndarray:
	h, w = frame_bgr.shape[:2]
	if crop_x < 0 or crop_y < 0 or crop_w <= 0 or crop_h <= 0:
		raise ValueError("Crop values must be non-negative with positive size")
	if crop_x + crop_w > w or crop_y + crop_h > h:
		raise ValueError(
			f"Crop ({crop_x}, {crop_y}, {crop_w}, {crop_h}) exceeds image size {w}x{h}"
		)
	return frame_bgr[crop_y : crop_y + crop_h, crop_x : crop_x + crop_w]


def process_image(
	image_path: Path,
	output_dir: Path,
	crop_x: int,
	crop_y: int,
	crop_w: int,
	crop_h: int,
	map_x: np.ndarray,
	map_y: np.ndarray,
	save_debug: bool,
) -> dict[str, object]:
	frame = cv2.imread(str(image_path), cv2.IMREAD_COLOR)
	if frame is None:
		raise ValueError(f"Failed to read image: {image_path}")

	crop = crop_active_region(frame, crop_x, crop_y, crop_w, crop_h)
	undistorted = cv2.remap(
		crop,
		map_x,
		map_y,
		interpolation=cv2.INTER_LINEAR,
		borderMode=cv2.BORDER_CONSTANT,
		borderValue=(0, 0, 0),
	)

	comparison = np.hstack([crop, undistorted])

	stem = image_path.stem
	crop_path = output_dir / f"{stem}_crop.png"
	undistorted_path = output_dir / f"{stem}_charuco_rectified.png"
	comparison_path = output_dir / f"{stem}_charuco_compare.png"

	cv2.imwrite(str(crop_path), crop)
	cv2.imwrite(str(undistorted_path), undistorted)
	cv2.imwrite(str(comparison_path), comparison)

	debug_path = None
	if save_debug:
		dbg = frame.copy()
		cv2.rectangle(
			dbg,
			(crop_x, crop_y),
			(crop_x + crop_w - 1, crop_y + crop_h - 1),
			(0, 255, 0),
			2,
		)
		debug_path = output_dir / f"{stem}_crop_debug.png"
		cv2.imwrite(str(debug_path), dbg)

	return {
		"input": str(image_path),
		"crop": str(crop_path),
		"rectified": str(undistorted_path),
		"comparison": str(comparison_path),
		"crop_box": {
			"x": crop_x,
			"y": crop_y,
			"width": crop_w,
			"height": crop_h,
		},
		"crop_debug": str(debug_path) if debug_path else None,
	}


def main() -> None:
	args = parse_args()
	output_dir = args.output_dir
	output_dir.mkdir(parents=True, exist_ok=True)

	image_paths = collect_images(args.input_dir, args.exts)
	if not image_paths:
		raise FileNotFoundError(
			f"No images found in {args.input_dir} matching {args.exts}"
		)

	camera_matrix, dist_coeffs, calib_shape_hw, payload = load_calibration(args.calibration_json)
	crop_w = int(args.crop_width)
	crop_h = int(args.crop_height)

	if (crop_h, crop_w) != calib_shape_hw:
		raise ValueError(
			"Crop size must match calibration image size. "
			f"Got crop {crop_w}x{crop_h}, calibration expects {calib_shape_hw[1]}x{calib_shape_hw[0]}"
		)

	new_k, map_x, map_y = build_undistort_map(
		camera_matrix=camera_matrix,
		dist_coeffs=dist_coeffs,
		width=crop_w,
		height=crop_h,
		balance=args.balance,
	)

	records: list[dict[str, object]] = []
	for image_path in image_paths:
		record = process_image(
			image_path=image_path,
			output_dir=output_dir,
			crop_x=int(args.crop_x),
			crop_y=int(args.crop_y),
			crop_w=crop_w,
			crop_h=crop_h,
			map_x=map_x,
			map_y=map_y,
			save_debug=args.save_debug,
		)
		records.append(record)

	report = {
		"calibration_json": str(args.calibration_json),
		"calibration_model": payload.get("model"),
		"calibration_rms": payload.get("rms"),
		"calibration_mean_reprojection_error": payload.get("mean_reprojection_error"),
		"balance": float(args.balance),
		"crop": {
			"x": int(args.crop_x),
			"y": int(args.crop_y),
			"width": crop_w,
			"height": crop_h,
		},
		"new_camera_matrix": new_k.tolist(),
		"images_processed": len(records),
		"results": records,
	}
	report_path = output_dir / "charuco_apply_report.json"
	report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")

	print(f"Processed {len(records)} image(s)")
	print(
		"Calibration apply settings: "
		f"crop=({args.crop_x}, {args.crop_y}, {crop_w}, {crop_h}), "
		f"balance={args.balance:.3f}, rms={payload.get('rms')}"
	)
	print(f"Report: {report_path}")
	for rec in records:
		print(
			f" - {Path(rec['input']).name}: "
			f"rectified={Path(rec['rectified']).name}, "
			f"comparison={Path(rec['comparison']).name}"
		)


if __name__ == "__main__":
	main()