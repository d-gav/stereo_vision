#!/usr/bin/env python3
"""Split dual-camera captures, calibrate each camera, generate LUTs, and compare remaps.

Input frames are expected to contain two side-by-side camera views in one image.
Crop geometry is configurable so a center gap/black band can be excluded.

Outputs:
- split left/right images
- independent fisheye calibrations for left and right cameras
- independent 21-bit LUT files (.memb and .mif)
- side-by-side remapped comparison images
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import cv2
import numpy as np

# Detection tuning reused from existing checkerboard calibration workflow.
UPSCALE_FACTOR = 3.0
CLAHE_CLIP_LIMIT = 2.5
CLAHE_TILE_GRID = (8, 8)
PATTERN_CANDIDATES = [
    (10, 7),
    (9, 7),
    (9, 6),
    (8, 6),
    (8, 5),
    (7, 5),
    (11, 8),
    (10, 8),
    (12, 9),
    (6, 4),
]
PATTERN_SEARCH_SAMPLE_LIMIT = 8
MIN_USABLE_IMAGES = 6
# Reprojection pruning can destabilize calibration if too few views remain.
MIN_REPROJ_KEEP_IMAGES = 10


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Split stereo captures into left/right crops, calibrate each side, "
            "generate separate LUTs, and save side-by-side remap comparisons."
        )
    )
    parser.add_argument(
        "--input-dir",
        type=Path,
        default=Path("dual camera calibration photos"),
        help="Directory with combined side-by-side stereo images.",
    )
    parser.add_argument(
        "--extra-input-dirs",
        type=Path,
        nargs="*",
        default=[],
        help="Additional image directories to merge with --input-dir.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("python-testing") / "dual_camera_calibration_results",
        help="Root directory for split outputs, calibrations, LUTs, and comparisons.",
    )
    parser.add_argument("--left-x", type=int, default=0, help="Left crop x origin.")
    parser.add_argument(
        "--right-x",
        type=int,
        default=-1,
        help=(
            "Right crop x origin. If negative, computed as "
            "left_x + crop_width + gap_width."
        ),
    )
    parser.add_argument("--top-y", type=int, default=0, help="Crop y origin.")
    parser.add_argument(
        "--crop-width",
        type=int,
        default=320,
        help="Left crop width (and right width if --right-width is 0).",
    )
    parser.add_argument(
        "--right-width",
        type=int,
        default=0,
        help="Right crop width (0 means same as --crop-width).",
    )
    parser.add_argument(
        "--gap-width",
        type=int,
        default=0,
        help="Pixel gap between left crop end and right crop start (auto mode only).",
    )
    parser.add_argument("--crop-height", type=int, default=288, help="Per-camera crop height.")
    parser.add_argument(
        "--balance",
        type=float,
        default=0.10,
        help="OpenCV fisheye balance parameter used for remap/LUT generation.",
    )
    parser.add_argument(
        "--max-comparisons",
        type=int,
        default=0,
        help="Maximum number of comparison images to save (0 means all).",
    )
    parser.add_argument(
        "--pattern-cols",
        type=int,
        default=0,
        help="Force checkerboard internal corner columns (0 means auto-detect).",
    )
    parser.add_argument(
        "--pattern-rows",
        type=int,
        default=0,
        help="Force checkerboard internal corner rows (0 means auto-detect).",
    )
    parser.add_argument(
        "--min-board-span-frac",
        type=float,
        default=0.0,
        help=(
            "Reject detections where checkerboard bbox spans less than this fraction "
            "of image width or height (0 disables)."
        ),
    )
    parser.add_argument(
        "--min-board-margin-px",
        type=float,
        default=0.0,
        help=(
            "Reject detections where checkerboard bbox is closer than this many "
            "pixels to any image edge (0 disables)."
        ),
    )
    parser.add_argument(
        "--max-reprojection-error",
        type=float,
        default=0.0,
        help=(
            "If > 0, drop images above this per-image reprojection error and "
            "recalibrate."
        ),
    )
    parser.add_argument(
        "--min-valid-frac",
        type=float,
        default=0.05,
        help=(
            "Minimum LUT valid-pixel fraction required after filtering. If lower, "
            "the script retries that camera with filters disabled."
        ),
    )
    return parser.parse_args()


def list_input_images(input_dirs: list[Path]) -> list[Path]:
    if not input_dirs:
        raise ValueError("At least one input directory is required")

    missing = [d for d in input_dirs if not d.exists()]
    if missing:
        missing_str = ", ".join(str(p) for p in missing)
        raise FileNotFoundError(f"Input directory not found: {missing_str}")

    paths: list[Path] = []
    for input_dir in input_dirs:
        for pattern in ("*.png", "*.jpg", "*.jpeg", "*.bmp"):
            paths.extend(sorted(input_dir.glob(pattern)))

    # Deduplicate if multiple globs match unusual names or same file appears twice.
    unique = sorted({p.resolve(): p for p in paths}.values(), key=lambda p: (str(p.parent), p.name))
    return unique


def split_stereo_images(
    image_paths: list[Path],
    left_out_dir: Path,
    right_out_dir: Path,
    left_x: int,
    right_x: int,
    top_y: int,
    left_w: int,
    right_w: int,
    crop_h: int,
) -> list[tuple[Path, Path, Path]]:
    left_out_dir.mkdir(parents=True, exist_ok=True)
    right_out_dir.mkdir(parents=True, exist_ok=True)

    split_records: list[tuple[Path, Path, Path]] = []
    used_out_names: set[str] = set()

    for in_path in image_paths:
        image = cv2.imread(str(in_path), cv2.IMREAD_COLOR)
        if image is None:
            print(f"Warning: failed to load image, skipping: {in_path}")
            continue

        h, w = image.shape[:2]

        if top_y < 0 or left_x < 0 or right_x < 0:
            print(f"Warning: negative crop origin, skipping: {in_path}")
            continue
        if top_y + crop_h > h or left_x + left_w > w or right_x + right_w > w:
            print(
                "Warning: image too small for requested dual crop, "
                f"skipping {in_path.name} (image={w}x{h}, needs >= "
                f"{max(left_x + left_w, right_x + right_w)}x{top_y + crop_h})"
            )
            continue

        left = image[top_y : top_y + crop_h, left_x : left_x + left_w]
        right = image[top_y : top_y + crop_h, right_x : right_x + right_w]

        out_name = in_path.name
        if out_name in used_out_names:
            out_name = f"{in_path.parent.name}__{in_path.name}"
        if out_name in used_out_names:
            stem = Path(out_name).stem
            suffix = Path(out_name).suffix
            index = 1
            candidate = f"{stem}__{index}{suffix}"
            while candidate in used_out_names:
                index += 1
                candidate = f"{stem}__{index}{suffix}"
            out_name = candidate
        used_out_names.add(out_name)

        left_path = left_out_dir / out_name
        right_path = right_out_dir / out_name
        cv2.imwrite(str(left_path), left)
        cv2.imwrite(str(right_path), right)

        split_records.append((in_path, left_path, right_path))

    return split_records


def preprocess_for_corners(image_bgr: np.ndarray) -> np.ndarray:
    gray = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2GRAY)

    if UPSCALE_FACTOR != 1.0:
        gray = cv2.resize(
            gray,
            None,
            fx=UPSCALE_FACTOR,
            fy=UPSCALE_FACTOR,
            interpolation=cv2.INTER_CUBIC,
        )

    clahe = cv2.createCLAHE(clipLimit=CLAHE_CLIP_LIMIT, tileGridSize=CLAHE_TILE_GRID)
    gray = clahe.apply(gray)
    return gray


def detect_checkerboard_corners(preprocessed_gray: np.ndarray, pattern_size: tuple[int, int]) -> np.ndarray | None:
    flags_sb = cv2.CALIB_CB_NORMALIZE_IMAGE

    corners = None
    found = False

    if hasattr(cv2, "findChessboardCornersSB"):
        found, corners = cv2.findChessboardCornersSB(preprocessed_gray, pattern_size, flags=flags_sb)

    if not found:
        flags_std = cv2.CALIB_CB_ADAPTIVE_THRESH | cv2.CALIB_CB_NORMALIZE_IMAGE
        found, corners = cv2.findChessboardCorners(preprocessed_gray, pattern_size, flags=flags_std)
        if found:
            term = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 80, 1e-4)
            cv2.cornerSubPix(preprocessed_gray, corners, (7, 7), (-1, -1), term)

    if not found or corners is None:
        return None

    if UPSCALE_FACTOR != 1.0:
        corners = corners / UPSCALE_FACTOR

    return corners.astype(np.float64)


def score_pattern(sample_preprocessed: list[np.ndarray], pattern_size: tuple[int, int]) -> int:
    hits = 0
    for gray in sample_preprocessed:
        corners = detect_checkerboard_corners(gray, pattern_size)
        if corners is not None:
            hits += 1
    return hits


def choose_best_pattern(images: list[np.ndarray]) -> tuple[int, int] | None:
    sample = images[:PATTERN_SEARCH_SAMPLE_LIMIT]
    sample_preprocessed = [preprocess_for_corners(img) for img in sample]

    if not sample_preprocessed:
        return None

    candidates: list[tuple[int, int, int, int]] = []

    for pattern_size in PATTERN_CANDIDATES:
        hits = score_pattern(sample_preprocessed, pattern_size)
        if hits > 0:
            candidates.append((hits, pattern_size[0] * pattern_size[1], pattern_size[0], pattern_size[1]))

        if hits >= max(3, len(sample_preprocessed) - 1):
            return pattern_size

    if not candidates:
        return None

    candidates.sort(reverse=True)
    best = candidates[0]
    return (best[2], best[3])


def checkerboard_visibility_ok(
    corners: np.ndarray,
    image_shape_hw: tuple[int, int],
    min_board_span_frac: float,
    min_board_margin_px: float,
) -> bool:
    if min_board_span_frac <= 0.0 and min_board_margin_px <= 0.0:
        return True

    h, w = image_shape_hw
    pts = corners.reshape(-1, 2)
    min_x = float(np.min(pts[:, 0]))
    max_x = float(np.max(pts[:, 0]))
    min_y = float(np.min(pts[:, 1]))
    max_y = float(np.max(pts[:, 1]))

    denom_w = max(float(w - 1), 1.0)
    denom_h = max(float(h - 1), 1.0)
    span_x_frac = (max_x - min_x) / denom_w
    span_y_frac = (max_y - min_y) / denom_h
    min_margin = min(min_x, min_y, (w - 1) - max_x, (h - 1) - max_y)

    if min_board_span_frac > 0.0 and (span_x_frac < min_board_span_frac or span_y_frac < min_board_span_frac):
        return False
    if min_board_margin_px > 0.0 and min_margin < min_board_margin_px:
        return False

    return True


def collect_checkerboard_points(
    image_paths: list[Path],
    pattern_size: tuple[int, int],
    min_board_span_frac: float,
    min_board_margin_px: float,
) -> tuple[list[np.ndarray], list[np.ndarray], list[Path], int]:
    cols, rows = pattern_size
    num_points = cols * rows

    obj_template = np.zeros((num_points, 1, 3), dtype=np.float64)
    obj_template[:, 0, :2] = np.mgrid[0:cols, 0:rows].T.reshape(-1, 2)

    object_points: list[np.ndarray] = []
    image_points: list[np.ndarray] = []
    used_paths: list[Path] = []
    rejected_visibility = 0

    for path in image_paths:
        image = cv2.imread(str(path), cv2.IMREAD_COLOR)
        if image is None:
            continue

        gray = preprocess_for_corners(image)
        corners = detect_checkerboard_corners(gray, pattern_size)

        if corners is None:
            continue
        if corners.shape[0] != num_points:
            continue
        if not checkerboard_visibility_ok(
            corners=corners,
            image_shape_hw=image.shape[:2],
            min_board_span_frac=min_board_span_frac,
            min_board_margin_px=min_board_margin_px,
        ):
            rejected_visibility += 1
            continue

        object_points.append(obj_template.copy())
        image_points.append(corners.reshape(-1, 1, 2))
        used_paths.append(path)

    return object_points, image_points, used_paths, rejected_visibility


def compute_fisheye_reprojection_errors(
    object_points: list[np.ndarray],
    image_points: list[np.ndarray],
    rvecs: list[np.ndarray],
    tvecs: list[np.ndarray],
    camera_matrix: np.ndarray,
    dist_coeffs: np.ndarray,
) -> np.ndarray:
    errors = []

    for obj, img, rvec, tvec in zip(object_points, image_points, rvecs, tvecs):
        projected, _ = cv2.fisheye.projectPoints(obj.reshape(1, -1, 3), rvec, tvec, camera_matrix, dist_coeffs)
        diff = img.reshape(-1, 2) - projected.reshape(-1, 2)
        per_point = np.sqrt(np.sum(diff * diff, axis=1))
        errors.append(float(np.mean(per_point)))

    return np.array(errors, dtype=np.float64)


def calibrate_fisheye(
    image_shape_hw: tuple[int, int],
    object_points: list[np.ndarray],
    image_points: list[np.ndarray],
) -> dict[str, object]:
    h, w = image_shape_hw
    image_size = (w, h)

    if len(object_points) < MIN_USABLE_IMAGES or len(image_points) < MIN_USABLE_IMAGES:
        raise RuntimeError(
            f"Need at least {MIN_USABLE_IMAGES} views for fisheye calibration; "
            f"got object_points={len(object_points)} image_points={len(image_points)}"
        )

    flags_try_order = [
        cv2.fisheye.CALIB_RECOMPUTE_EXTRINSIC | cv2.fisheye.CALIB_CHECK_COND | cv2.fisheye.CALIB_FIX_SKEW,
        cv2.fisheye.CALIB_RECOMPUTE_EXTRINSIC | cv2.fisheye.CALIB_FIX_SKEW,
        cv2.fisheye.CALIB_FIX_SKEW,
        0,
    ]
    criteria = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 200, 1e-8)

    last_error: str | None = None
    calibrated = False

    for flags in flags_try_order:
        camera_matrix = np.eye(3, dtype=np.float64)
        dist_coeffs = np.zeros((4, 1), dtype=np.float64)

        try:
            rms, camera_matrix, dist_coeffs, rvecs, tvecs = cv2.fisheye.calibrate(
                object_points,
                image_points,
                image_size,
                camera_matrix,
                dist_coeffs,
                None,
                None,
                flags=flags,
                criteria=criteria,
            )
            calibrated = True
            break
        except cv2.error as exc:
            last_error = str(exc)

    if not calibrated:
        raise RuntimeError(
            "OpenCV fisheye calibration failed for all flag combinations. "
            f"Last error: {last_error}"
        )

    reproj = compute_fisheye_reprojection_errors(
        object_points=object_points,
        image_points=image_points,
        rvecs=rvecs,
        tvecs=tvecs,
        camera_matrix=camera_matrix,
        dist_coeffs=dist_coeffs,
    )

    return {
        "rms": float(rms),
        "camera_matrix": camera_matrix,
        "dist_coeffs": dist_coeffs,
        "rvecs": rvecs,
        "tvecs": tvecs,
        "reprojection_errors": reproj,
        "image_shape_hw": image_shape_hw,
    }


def build_maps(
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
        balance=balance,
    )

    map_x, map_y = cv2.fisheye.initUndistortRectifyMap(
        camera_matrix,
        dist_coeffs,
        np.eye(3),
        new_k,
        (width, height),
        cv2.CV_32FC1,
    )

    return map_x, map_y, new_k


def lut_from_maps(map_x: np.ndarray, map_y: np.ndarray, width: int, height: int) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    finite = np.isfinite(map_x) & np.isfinite(map_y)
    in_bounds = (map_x >= 0.0) & (map_x <= (width - 1)) & (map_y >= 0.0) & (map_y <= (height - 1))
    valid = (finite & in_bounds).astype(np.uint8)

    map_x_safe = np.nan_to_num(map_x, nan=0.0, posinf=0.0, neginf=0.0)
    map_y_safe = np.nan_to_num(map_y, nan=0.0, posinf=0.0, neginf=0.0)

    src_x = np.rint(np.clip(map_x_safe, 0.0, float(width - 1))).astype(np.int32)
    src_y = np.rint(np.clip(map_y_safe, 0.0, float(height - 1))).astype(np.int32)

    packed = (
        ((valid.astype(np.uint32) & 0x1) << 20)
        | ((src_y.astype(np.uint32) & 0x3FF) << 10)
        | (src_x.astype(np.uint32) & 0x3FF)
    ).astype(np.uint32)

    return src_x, src_y, valid, packed


def write_memb_21(path: Path, packed: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)

    if np.any(packed > 0x1FFFFF):
        raise ValueError("Packed LUT contains values wider than 21 bits")

    with path.open("w", encoding="utf-8") as f:
        for word in packed.reshape(-1):
            f.write(f"{int(word):021b}\n")


def write_mif_21(path: Path, packed: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)

    flat = packed.reshape(-1)

    if np.any(flat > 0x1FFFFF):
        raise ValueError("Packed LUT contains values wider than 21 bits")

    with path.open("w", encoding="utf-8") as f:
        f.write("WIDTH=21;\n")
        f.write(f"DEPTH={flat.size};\n")
        f.write("\n")
        f.write("ADDRESS_RADIX=UNS;\n")
        f.write("DATA_RADIX=BIN;\n")
        f.write("\n")
        f.write("CONTENT BEGIN\n")
        for idx, word in enumerate(flat):
            f.write(f"    {idx} : {int(word):021b};\n")
        f.write("END;\n")


def save_camera_outputs(
    camera_name: str,
    out_dir: Path,
    lut_width: int,
    lut_height: int,
    calibration: dict[str, object],
    pattern_size: tuple[int, int],
    used_images: list[Path],
    map_x: np.ndarray,
    map_y: np.ndarray,
    new_k: np.ndarray,
    src_x: np.ndarray,
    src_y: np.ndarray,
    valid: np.ndarray,
    packed: np.ndarray,
) -> tuple[Path, Path]:
    out_dir.mkdir(parents=True, exist_ok=True)

    camera_matrix = calibration["camera_matrix"]
    dist_coeffs = calibration["dist_coeffs"]
    reproj = calibration["reprojection_errors"]

    np.save(out_dir / "camera_matrix.npy", camera_matrix)
    np.save(out_dir / "dist_coeffs.npy", dist_coeffs)
    np.save(out_dir / "new_camera_matrix.npy", new_k)
    np.save(out_dir / "map_x.npy", map_x)
    np.save(out_dir / "map_y.npy", map_y)
    np.save(out_dir / "lut_src_x.npy", src_x)
    np.save(out_dir / "lut_src_y.npy", src_y)
    np.save(out_dir / "lut_valid.npy", valid)

    memb_path = out_dir / f"{camera_name}_lut_{lut_width}x{lut_height}_21b.memb"
    mif_path = out_dir / f"{camera_name}_lut_{lut_width}x{lut_height}_21b.mif"
    write_memb_21(memb_path, packed)
    write_mif_21(mif_path, packed)

    payload = {
        "camera": camera_name,
        "model": "opencv_fisheye",
        "image_shape_hw": list(calibration["image_shape_hw"]),
        "pattern_size_internal_corners": list(pattern_size),
        "rms": calibration["rms"],
        "mean_reprojection_error": float(np.mean(reproj)),
        "max_reprojection_error": float(np.max(reproj)),
        "num_images_used": len(used_images),
        "camera_matrix": camera_matrix.tolist(),
        "dist_coeffs": dist_coeffs.tolist(),
        "used_images": [str(p) for p in used_images],
        "lut_memb": str(memb_path),
        "lut_mif": str(mif_path),
    }

    (out_dir / "calibration.json").write_text(json.dumps(payload, indent=2), encoding="utf-8")
    return memb_path, mif_path


def save_remap_comparisons(
    split_records: list[tuple[Path, Path, Path]],
    map_x_left: np.ndarray,
    map_y_left: np.ndarray,
    map_x_right: np.ndarray,
    map_y_right: np.ndarray,
    out_dir: Path,
    max_comparisons: int,
) -> int:
    out_dir.mkdir(parents=True, exist_ok=True)

    if max_comparisons <= 0:
        max_comparisons = len(split_records)

    count = 0
    for idx, (_, left_path, right_path) in enumerate(split_records):
        if idx >= max_comparisons:
            break

        left = cv2.imread(str(left_path), cv2.IMREAD_COLOR)
        right = cv2.imread(str(right_path), cv2.IMREAD_COLOR)
        if left is None or right is None:
            continue

        left_und = cv2.remap(
            left,
            map_x_left,
            map_y_left,
            interpolation=cv2.INTER_LINEAR,
            borderMode=cv2.BORDER_CONSTANT,
            borderValue=0,
        )
        right_und = cv2.remap(
            right,
            map_x_right,
            map_y_right,
            interpolation=cv2.INTER_LINEAR,
            borderMode=cv2.BORDER_CONSTANT,
            borderValue=0,
        )

        pair = np.hstack([left_und, right_und])
        debug = np.hstack([left, left_und, right, right_und])

        stem = left_path.stem
        cv2.imwrite(str(out_dir / f"remapped_pair_{idx:03d}_{stem}.png"), pair)
        cv2.imwrite(str(out_dir / f"remap_debug_{idx:03d}_{stem}.png"), debug)

        count += 1

    return count


def run_single_camera_calibration(
    camera_name: str,
    image_paths: list[Path],
    width: int,
    height: int,
    balance: float,
    forced_pattern: tuple[int, int] | None,
    min_board_span_frac: float,
    min_board_margin_px: float,
    max_reprojection_error: float,
    min_valid_frac: float,
) -> tuple[
    dict[str, object],
    tuple[int, int],
    list[Path],
    np.ndarray,
    np.ndarray,
    np.ndarray,
    np.ndarray,
    np.ndarray,
    np.ndarray,
    np.ndarray,
    dict[str, object],
]:
    images_for_pattern = []
    for path in image_paths:
        image = cv2.imread(str(path), cv2.IMREAD_COLOR)
        if image is None:
            continue
        images_for_pattern.append(image)

    if not images_for_pattern:
        raise RuntimeError(f"No readable images for {camera_name} calibration")

    image_shape_hw = images_for_pattern[0].shape[:2]
    if image_shape_hw != (height, width):
        raise RuntimeError(
            f"Unexpected {camera_name} image shape {image_shape_hw}; expected {(height, width)}"
        )

    if forced_pattern is not None:
        pattern_size = forced_pattern
    else:
        pattern_size = choose_best_pattern(images_for_pattern)

    if pattern_size is None:
        raise RuntimeError(f"Could not detect checkerboard pattern for {camera_name} camera")

    object_points, image_points, used_images, rejected_visibility = collect_checkerboard_points(
        image_paths=image_paths,
        pattern_size=pattern_size,
        min_board_span_frac=min_board_span_frac,
        min_board_margin_px=min_board_margin_px,
    )

    if len(used_images) < MIN_USABLE_IMAGES:
        raise RuntimeError(
            f"{camera_name} camera has only {len(used_images)} usable images; "
            f"need at least {MIN_USABLE_IMAGES}"
        )

    if rejected_visibility > 0:
        print(
            f"{camera_name}: rejected {rejected_visibility} images by visibility filter "
            f"(min span frac={min_board_span_frac}, min margin px={min_board_margin_px})"
        )

    calibration = calibrate_fisheye(image_shape_hw, object_points, image_points)
    reproj_rejected = 0
    reverted_to_prereproj = False
    prereproj_backup: tuple[dict[str, object], list[Path]] | None = None

    if max_reprojection_error > 0.0:
        reproj = calibration["reprojection_errors"]
        keep_mask = reproj <= max_reprojection_error
        dropped = int(np.sum(~keep_mask))

        if dropped > 0:
            kept = len(used_images) - dropped
            if kept >= MIN_REPROJ_KEEP_IMAGES:
                cand_object_points = [obj for obj, keep in zip(object_points, keep_mask) if bool(keep)]
                cand_image_points = [img for img, keep in zip(image_points, keep_mask) if bool(keep)]
                cand_used_images = [p for p, keep in zip(used_images, keep_mask) if bool(keep)]

                try:
                    cand_calibration = calibrate_fisheye(image_shape_hw, cand_object_points, cand_image_points)
                except RuntimeError as exc:
                    print(
                        f"{camera_name}: reprojection-filter recalibration failed ({exc}); "
                        "keeping original calibration"
                    )
                else:
                    prereproj_backup = (calibration, list(used_images))
                    object_points = cand_object_points
                    image_points = cand_image_points
                    used_images = cand_used_images
                    calibration = cand_calibration
                    reproj_rejected = dropped
                    print(
                        f"{camera_name}: rejected {dropped} images above reprojection error "
                        f"{max_reprojection_error} and recalibrated with {kept} images"
                    )
            else:
                print(
                    f"{camera_name}: reprojection filter would drop {dropped} images, "
                    f"leaving only {kept}; need at least {MIN_REPROJ_KEEP_IMAGES}, keeping original set"
                )
    map_x, map_y, new_k = build_maps(
        camera_matrix=calibration["camera_matrix"],
        dist_coeffs=calibration["dist_coeffs"],
        width=width,
        height=height,
        balance=balance,
    )
    src_x, src_y, valid, packed = lut_from_maps(map_x, map_y, width=width, height=height)
    valid_frac = float(np.mean(valid))

    filters_enabled = (min_board_span_frac > 0.0) or (min_board_margin_px > 0.0) or (max_reprojection_error > 0.0)
    fallback_used = False
    fallback_valid_frac: float | None = None

    if filters_enabled and valid_frac < min_valid_frac:
        print(
            f"{camera_name}: valid LUT fraction {valid_frac:.4f} is below "
            f"min-valid-frac {min_valid_frac:.4f}; retrying without filters"
        )

        fb_obj, fb_img, fb_used, _ = collect_checkerboard_points(
            image_paths=image_paths,
            pattern_size=pattern_size,
            min_board_span_frac=0.0,
            min_board_margin_px=0.0,
        )

        if len(fb_used) >= MIN_USABLE_IMAGES:
            try:
                fb_cal = calibrate_fisheye(image_shape_hw, fb_obj, fb_img)
            except RuntimeError as exc:
                print(f"{camera_name}: unfiltered fallback calibration failed ({exc}); keeping filtered result")
            else:
                fb_map_x, fb_map_y, fb_new_k = build_maps(
                    camera_matrix=fb_cal["camera_matrix"],
                    dist_coeffs=fb_cal["dist_coeffs"],
                    width=width,
                    height=height,
                    balance=balance,
                )
                fb_src_x, fb_src_y, fb_valid, fb_packed = lut_from_maps(
                    fb_map_x,
                    fb_map_y,
                    width=width,
                    height=height,
                )
                fallback_valid_frac = float(np.mean(fb_valid))

                if fallback_valid_frac > valid_frac:
                    calibration = fb_cal
                    used_images = fb_used
                    map_x, map_y, new_k = fb_map_x, fb_map_y, fb_new_k
                    src_x, src_y, valid, packed = fb_src_x, fb_src_y, fb_valid, fb_packed
                    valid_frac = fallback_valid_frac
                    fallback_used = True
                    reproj_rejected = 0
                    print(
                        f"{camera_name}: unfiltered fallback accepted "
                        f"(valid fraction {fallback_valid_frac:.4f})"
                    )
                else:
                    print(
                        f"{camera_name}: unfiltered fallback not better "
                        f"(valid fraction {fallback_valid_frac:.4f}); keeping filtered result"
                    )
        else:
            print(
                f"{camera_name}: unfiltered fallback has only {len(fb_used)} usable images; "
                "keeping filtered result"
            )

    if valid_frac < min_valid_frac and prereproj_backup is not None:
        prev_cal, prev_used_images = prereproj_backup
        prev_map_x, prev_map_y, prev_new_k = build_maps(
            camera_matrix=prev_cal["camera_matrix"],
            dist_coeffs=prev_cal["dist_coeffs"],
            width=width,
            height=height,
            balance=balance,
        )
        prev_src_x, prev_src_y, prev_valid, prev_packed = lut_from_maps(
            prev_map_x,
            prev_map_y,
            width=width,
            height=height,
        )
        prev_valid_frac = float(np.mean(prev_valid))

        if prev_valid_frac > valid_frac:
            calibration = prev_cal
            used_images = prev_used_images
            map_x, map_y, new_k = prev_map_x, prev_map_y, prev_new_k
            src_x, src_y, valid, packed = prev_src_x, prev_src_y, prev_valid, prev_packed
            valid_frac = prev_valid_frac
            reproj_rejected = 0
            reverted_to_prereproj = True
            print(
                f"{camera_name}: reverted to pre-reprojection calibration "
                f"(valid fraction {prev_valid_frac:.4f})"
            )

    if valid_frac < min_valid_frac:
        print(
            f"Warning: {camera_name} final LUT valid fraction is {valid_frac:.4f}, "
            "remapped output may appear mostly black"
        )

    filter_stats = {
        "num_input_images": len(image_paths),
        "num_visibility_rejected": rejected_visibility,
        "num_reprojection_rejected": reproj_rejected,
        "lut_valid_fraction": valid_frac,
        "fallback_unfiltered_used": fallback_used,
        "fallback_unfiltered_valid_fraction": fallback_valid_frac,
        "reverted_to_prereprojection": reverted_to_prereproj,
    }

    return calibration, pattern_size, used_images, map_x, map_y, new_k, src_x, src_y, valid, packed, filter_stats


def main() -> None:
    args = parse_args()

    if (args.pattern_cols == 0) ^ (args.pattern_rows == 0):
        raise ValueError("Provide both --pattern-cols and --pattern-rows, or leave both at 0 for auto mode")

    forced_pattern = None
    if args.pattern_cols > 0 and args.pattern_rows > 0:
        forced_pattern = (args.pattern_cols, args.pattern_rows)

    input_dirs = [args.input_dir, *args.extra_input_dirs]
    image_paths = list_input_images(input_dirs)
    if not image_paths:
        raise RuntimeError(f"No images found in input directories: {[str(p) for p in input_dirs]}")

    left_w = args.crop_width
    right_w = args.right_width if args.right_width > 0 else left_w
    right_x = args.right_x if args.right_x >= 0 else args.left_x + left_w + args.gap_width

    if left_w <= 0 or right_w <= 0:
        raise ValueError("Crop widths must be > 0")
    if args.crop_height <= 0:
        raise ValueError("--crop-height must be > 0")

    effective_gap = right_x - (args.left_x + left_w)
    if effective_gap < 0:
        print("Warning: right crop overlaps left crop")

    split_root = args.output_dir / "split"
    left_split_dir = split_root / "left"
    right_split_dir = split_root / "right"

    split_records = split_stereo_images(
        image_paths=image_paths,
        left_out_dir=left_split_dir,
        right_out_dir=right_split_dir,
        left_x=args.left_x,
        right_x=right_x,
        top_y=args.top_y,
        left_w=left_w,
        right_w=right_w,
        crop_h=args.crop_height,
    )

    if not split_records:
        raise RuntimeError("No images were split successfully")

    left_paths = [rec[1] for rec in split_records]
    right_paths = [rec[2] for rec in split_records]

    print(f"Split {len(split_records)} combined images into left/right crops")

    (
        left_cal,
        left_pattern,
        left_used,
        map_x_left,
        map_y_left,
        new_k_left,
        src_x_left,
        src_y_left,
        valid_left,
        packed_left,
        left_filter_stats,
    ) = run_single_camera_calibration(
        camera_name="left",
        image_paths=left_paths,
        width=left_w,
        height=args.crop_height,
        balance=args.balance,
        forced_pattern=forced_pattern,
        min_board_span_frac=args.min_board_span_frac,
        min_board_margin_px=args.min_board_margin_px,
        max_reprojection_error=args.max_reprojection_error,
        min_valid_frac=args.min_valid_frac,
    )

    (
        right_cal,
        right_pattern,
        right_used,
        map_x_right,
        map_y_right,
        new_k_right,
        src_x_right,
        src_y_right,
        valid_right,
        packed_right,
        right_filter_stats,
    ) = run_single_camera_calibration(
        camera_name="right",
        image_paths=right_paths,
        width=right_w,
        height=args.crop_height,
        balance=args.balance,
        forced_pattern=forced_pattern,
        min_board_span_frac=args.min_board_span_frac,
        min_board_margin_px=args.min_board_margin_px,
        max_reprojection_error=args.max_reprojection_error,
        min_valid_frac=args.min_valid_frac,
    )

    left_out = args.output_dir / "left_camera"
    right_out = args.output_dir / "right_camera"

    _, left_mif_path = save_camera_outputs(
        camera_name="left",
        out_dir=left_out,
        lut_width=left_w,
        lut_height=args.crop_height,
        calibration=left_cal,
        pattern_size=left_pattern,
        used_images=left_used,
        map_x=map_x_left,
        map_y=map_y_left,
        new_k=new_k_left,
        src_x=src_x_left,
        src_y=src_y_left,
        valid=valid_left,
        packed=packed_left,
    )

    _, right_mif_path = save_camera_outputs(
        camera_name="right",
        out_dir=right_out,
        lut_width=right_w,
        lut_height=args.crop_height,
        calibration=right_cal,
        pattern_size=right_pattern,
        used_images=right_used,
        map_x=map_x_right,
        map_y=map_y_right,
        new_k=new_k_right,
        src_x=src_x_right,
        src_y=src_y_right,
        valid=valid_right,
        packed=packed_right,
    )

    comparisons_dir = args.output_dir / "comparisons"
    comparison_count = save_remap_comparisons(
        split_records=split_records,
        map_x_left=map_x_left,
        map_y_left=map_y_left,
        map_x_right=map_x_right,
        map_y_right=map_y_right,
        out_dir=comparisons_dir,
        max_comparisons=args.max_comparisons,
    )

    report = {
        "input_dir": str(args.input_dir),
        "input_dirs": [str(p) for p in input_dirs],
        "num_input_images": len(image_paths),
        "num_split_images": len(split_records),
        "crop": {
            "left_x": args.left_x,
            "left_width": left_w,
            "right_x": right_x,
            "right_width": right_w,
            "gap_width": effective_gap,
            "top_y": args.top_y,
            "height": args.crop_height,
        },
        "filters": {
            "min_board_span_frac": args.min_board_span_frac,
            "min_board_margin_px": args.min_board_margin_px,
            "max_reprojection_error": args.max_reprojection_error,
            "min_valid_frac": args.min_valid_frac,
        },
        "left_camera": {
            "pattern": list(left_pattern),
            "rms": left_cal["rms"],
            "mean_reprojection_error": float(np.mean(left_cal["reprojection_errors"])),
            "num_images_used": len(left_used),
            "num_visibility_rejected": left_filter_stats["num_visibility_rejected"],
            "num_reprojection_rejected": left_filter_stats["num_reprojection_rejected"],
            "lut_valid_fraction": left_filter_stats["lut_valid_fraction"],
            "fallback_unfiltered_used": left_filter_stats["fallback_unfiltered_used"],
            "output_dir": str(left_out),
        },
        "right_camera": {
            "pattern": list(right_pattern),
            "rms": right_cal["rms"],
            "mean_reprojection_error": float(np.mean(right_cal["reprojection_errors"])),
            "num_images_used": len(right_used),
            "num_visibility_rejected": right_filter_stats["num_visibility_rejected"],
            "num_reprojection_rejected": right_filter_stats["num_reprojection_rejected"],
            "lut_valid_fraction": right_filter_stats["lut_valid_fraction"],
            "fallback_unfiltered_used": right_filter_stats["fallback_unfiltered_used"],
            "output_dir": str(right_out),
        },
        "num_comparison_images": comparison_count,
        "comparisons_dir": str(comparisons_dir),
    }

    args.output_dir.mkdir(parents=True, exist_ok=True)
    (args.output_dir / "run_report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")

    print("\nDone.")
    print(f"Results root: {args.output_dir}")
    print(f"Left LUT:  {left_mif_path}")
    print(f"Right LUT: {right_mif_path}")
    print(f"Comparisons: {comparisons_dir}")


if __name__ == "__main__":
    main()
