"""Crop active NTSC capture region and resample fisheye images for stereo work.

The VGA captures in this repo include a noisy full-frame background with a
320x240 active image embedded inside. This script finds that active region,
crops it, then applies an equidistant-fisheye -> pinhole remap so the result
is more suitable for stereo correspondence tuning.
"""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

import cv2
import numpy as np


@dataclass(frozen=True)
class CameraProfile:
	name: str
	input_hfov_deg: float
	recommended_output_hfov_deg: float
	default_correction_strength: float


# These are practical defaults for the two candidate cameras/lens families.
# You can override with --input-hfov-deg if your lens variant differs.
CAMERA_PROFILES: dict[str, CameraProfile] = {
	# User-provided published specs:
	# - Razer Mini V2 (4:3): HFOV 125 deg, DFOV 155 deg
	# - Razer Mini V3 (4:3): HFOV 98 deg
	"razer_v2": CameraProfile(
		name="razer_v2",
		input_hfov_deg=125.0,
		recommended_output_hfov_deg=100.0,
		default_correction_strength=0.65,
	),
	"razer_v3": CameraProfile(
		name="razer_v3",
		input_hfov_deg=98.0,
		recommended_output_hfov_deg=92.0,
		default_correction_strength=0.35,
	),
}


def parse_args() -> argparse.Namespace:
	parser = argparse.ArgumentParser(
		description="Find 320x240 active region in NTSC captures and defisheye it."
	)
	parser.add_argument(
		"--input-dir",
		type=Path,
		default=Path("test-ntsc-images"),
		help="Directory containing captured NTSC images.",
	)
	parser.add_argument(
		"--output-dir",
		type=Path,
		default=Path("python-testing") / "reconstruction-output",
		help="Directory for cropped and rectified outputs.",
	)
	parser.add_argument(
		"--profile",
		type=str,
		default="razer_v2",
		choices=sorted(CAMERA_PROFILES.keys()),
		help="Camera profile to use for fisheye remapping.",
	)
	parser.add_argument(
		"--input-hfov-deg",
		type=float,
		default=None,
		help="Override profile horizontal FOV (degrees).",
	)
	parser.add_argument(
		"--output-hfov-deg",
		type=float,
		default=None,
		help=(
			"Horizontal FOV for the undistorted output image. "
			"If omitted, uses profile-recommended value."
		),
	)
	parser.add_argument(
		"--correction-strength",
		type=float,
		default=None,
		help=(
			"Blend factor in [0,1] between identity remap (0) and full model (1). "
			"If omitted, uses profile default."
		),
	)
	parser.add_argument(
		"--bbox-width",
		type=int,
		default=320,
		help="Expected active-region width.",
	)
	parser.add_argument(
		"--bbox-height",
		type=int,
		default=240,
		help="Expected active-region height.",
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
		help="Write debug frames with detected crop bounding boxes.",
	)
	return parser.parse_args()


def collect_images(input_dir: Path, exts: Iterable[str]) -> list[Path]:
	paths: list[Path] = []
	for pattern in exts:
		paths.extend(input_dir.glob(pattern))
	return sorted({p for p in paths if p.is_file()})


def detect_active_bbox(
	frame_bgr: np.ndarray,
	bbox_width: int = 320,
	bbox_height: int = 240,
) -> tuple[int, int, int, int, float]:
	"""Find the active capture region by minimizing window saturation.

	The inactive VGA background in these captures is highly saturated and noisy,
	while the real camera content is less saturated. Sliding a fixed-size window
	and selecting the minimum mean saturation robustly isolates the active area.
	"""

	frame_h, frame_w = frame_bgr.shape[:2]
	if bbox_width > frame_w or bbox_height > frame_h:
		raise ValueError(
			f"Requested bbox {bbox_width}x{bbox_height} exceeds frame size "
			f"{frame_w}x{frame_h}"
		)

	hsv = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2HSV)
	sat = hsv[:, :, 1].astype(np.float32)

	# Integral image gives O(1) rectangular sum lookup for each window.
	ii = np.pad(sat, ((1, 0), (1, 0)), mode="constant").cumsum(0).cumsum(1)
	sums = (
		ii[bbox_height:, bbox_width:]
		- ii[:-bbox_height, bbox_width:]
		- ii[bbox_height:, :-bbox_width]
		+ ii[:-bbox_height, :-bbox_width]
	)

	min_idx = int(np.argmin(sums))
	y, x = np.unravel_index(min_idx, sums.shape)
	mean_saturation = float(sums[y, x] / (bbox_width * bbox_height))
	return int(x), int(y), int(bbox_width), int(bbox_height), mean_saturation


def build_equidistant_to_pinhole_map(
	src_width: int,
	src_height: int,
	input_hfov_deg: float,
	output_hfov_deg: float,
	correction_strength: float,
) -> tuple[np.ndarray, np.ndarray]:
	"""Create remap grids from equidistant fisheye to pinhole projection."""

	input_hfov_rad = np.deg2rad(float(input_hfov_deg))
	output_hfov_rad = np.deg2rad(float(output_hfov_deg))
	if not (0.0 < output_hfov_rad < np.pi):
		raise ValueError("output_hfov_deg must be in (0, 180)")
	if not (0.0 < input_hfov_rad < np.pi):
		raise ValueError("input_hfov_deg must be in (0, 180)")
	if not (0.0 <= correction_strength <= 1.0):
		raise ValueError("correction_strength must be in [0, 1]")

	cx_src = (src_width - 1) * 0.5
	cy_src = (src_height - 1) * 0.5
	cx_out = cx_src
	cy_out = cy_src

	# Equidistant fisheye model: r = f_fish * theta
	f_fish = (src_width * 0.5) / (input_hfov_rad * 0.5)

	# Pinhole model for output image.
	f_out = (src_width * 0.5) / np.tan(output_hfov_rad * 0.5)

	uu, vv = np.meshgrid(np.arange(src_width), np.arange(src_height))
	x = (uu.astype(np.float32) - cx_out) / f_out
	y = (vv.astype(np.float32) - cy_out) / f_out

	rho = np.sqrt(x * x + y * y)
	theta = np.arctan(rho)
	r_model = f_fish * theta

	# Blend with identity mapping to handle unknown lens projection differences.
	r_identity = rho * f_out
	r_src = (1.0 - correction_strength) * r_identity + correction_strength * r_model

	scale = np.ones_like(rho, dtype=np.float32)
	valid = rho > 1e-8
	scale[valid] = r_src[valid] / rho[valid]

	map_x = (cx_src + x * scale).astype(np.float32)
	map_y = (cy_src + y * scale).astype(np.float32)
	return map_x, map_y


def defisheye_crop(
	crop_bgr: np.ndarray,
	input_hfov_deg: float,
	output_hfov_deg: float,
	correction_strength: float,
) -> np.ndarray:
	h, w = crop_bgr.shape[:2]
	map_x, map_y = build_equidistant_to_pinhole_map(
		src_width=w,
		src_height=h,
		input_hfov_deg=input_hfov_deg,
		output_hfov_deg=output_hfov_deg,
		correction_strength=correction_strength,
	)
	return cv2.remap(
		crop_bgr,
		map_x,
		map_y,
		interpolation=cv2.INTER_LINEAR,
		borderMode=cv2.BORDER_CONSTANT,
		borderValue=(0, 0, 0),
	)


def process_image(
	image_path: Path,
	output_dir: Path,
	bbox_width: int,
	bbox_height: int,
	input_hfov_deg: float,
	output_hfov_deg: float,
	correction_strength: float,
	save_debug: bool,
) -> dict[str, object]:
	frame = cv2.imread(str(image_path), cv2.IMREAD_COLOR)
	if frame is None:
		raise ValueError(f"Failed to read image: {image_path}")

	x, y, w, h, sat_score = detect_active_bbox(
		frame_bgr=frame,
		bbox_width=bbox_width,
		bbox_height=bbox_height,
	)
	crop = frame[y : y + h, x : x + w]
	rectified = defisheye_crop(
		crop_bgr=crop,
		input_hfov_deg=input_hfov_deg,
		output_hfov_deg=output_hfov_deg,
		correction_strength=correction_strength,
	)

	stem = image_path.stem
	crop_path = output_dir / f"{stem}_crop.png"
	rectified_path = output_dir / f"{stem}_rectified.png"
	cv2.imwrite(str(crop_path), crop)
	cv2.imwrite(str(rectified_path), rectified)

	debug_path = None
	if save_debug:
		dbg = frame.copy()
		cv2.rectangle(dbg, (x, y), (x + w - 1, y + h - 1), (0, 255, 0), 2)
		debug_path = output_dir / f"{stem}_bbox_debug.png"
		cv2.imwrite(str(debug_path), dbg)

	return {
		"input": str(image_path),
		"bbox": {"x": x, "y": y, "width": w, "height": h},
		"mean_saturation": sat_score,
		"crop": str(crop_path),
		"rectified": str(rectified_path),
		"bbox_debug": str(debug_path) if debug_path else None,
	}


def main() -> None:
	args = parse_args()
	input_dir = args.input_dir
	output_dir = args.output_dir
	output_dir.mkdir(parents=True, exist_ok=True)

	image_paths = collect_images(input_dir=input_dir, exts=args.exts)
	if not image_paths:
		raise FileNotFoundError(f"No images found in {input_dir} matching {args.exts}")

	profile = CAMERA_PROFILES[args.profile]
	input_hfov_deg = args.input_hfov_deg or profile.input_hfov_deg
	output_hfov_deg = args.output_hfov_deg or profile.recommended_output_hfov_deg
	correction_strength = (
		args.correction_strength
		if args.correction_strength is not None
		else profile.default_correction_strength
	)

	records = []
	for image_path in image_paths:
		record = process_image(
			image_path=image_path,
			output_dir=output_dir,
			bbox_width=args.bbox_width,
			bbox_height=args.bbox_height,
			input_hfov_deg=input_hfov_deg,
				output_hfov_deg=output_hfov_deg,
				correction_strength=correction_strength,
			save_debug=args.save_debug,
		)
		records.append(record)

	report = {
		"profile": args.profile,
		"input_hfov_deg": input_hfov_deg,
		"output_hfov_deg": output_hfov_deg,
		"correction_strength": correction_strength,
		"images_processed": len(records),
		"results": records,
	}
	report_path = output_dir / "reconstruction_report.json"
	report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")

	print(f"Processed {len(records)} image(s)")
	print(
		f"Profile: {args.profile}, input_hfov={input_hfov_deg:.2f}, "
		f"output_hfov={output_hfov_deg:.2f}, strength={correction_strength:.2f}"
	)
	print(f"Report: {report_path}")
	for rec in records:
		bbox = rec["bbox"]
		print(
			f" - {Path(rec['input']).name}: bbox=(x={bbox['x']}, y={bbox['y']}, "
			f"w={bbox['width']}, h={bbox['height']}), rectified={Path(rec['rectified']).name}"
		)


if __name__ == "__main__":
	main()
