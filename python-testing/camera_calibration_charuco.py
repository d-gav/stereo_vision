#!/usr/bin/env python3
"""
Low-resolution checkerboard-based calibration.

This intentionally does not rely on ArUco/CharUco tag IDs. It uses the stronger
geometric constraints of the checker lattice: ordered grid corners, square cells,
and a fisheye projection model.
"""

import glob
import json
import os
import csv

import cv2
import numpy as np

# Paths
CALIBRATION_IMAGES_DIR = "../calibration-images"
OUTPUT_DIR = "calibration_results"

# Active 320x240 window location in original 640x480 captures.
ACTIVE_OFFSET_X = 100
ACTIVE_OFFSET_Y = 50

# Detection tuning for low-resolution images.
UPSCALE_FACTOR = 3.0
CLAHE_CLIP_LIMIT = 2.5
CLAHE_TILE_GRID = (8, 8)

# Candidate internal-corner patterns (cols, rows). Prioritize likely board sizes.
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


def preprocess_for_corners(image_bgr):
    """Upscale and improve local contrast before corner detection."""
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


def detect_checkerboard_corners(preprocessed_gray, pattern_size):
    """Detect ordered checkerboard corners for a specific internal corner pattern."""
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

    # Bring corners back to original image coordinates if we upscaled.
    if UPSCALE_FACTOR != 1.0:
        corners = corners / UPSCALE_FACTOR

    return corners.astype(np.float64)


def load_calibration_images(image_dir):
    image_files = sorted(glob.glob(os.path.join(image_dir, "*.png")))
    images = []

    for path in image_files:
        img = cv2.imread(path)
        if img is None:
            print(f"Failed to load: {path}")
            continue
        images.append((path, img))

    return images


def score_pattern(sample_preprocessed_grays, pattern_size):
    """Return number of successful detections for a candidate pattern."""
    hits = 0

    for gray in sample_preprocessed_grays:
        corners = detect_checkerboard_corners(gray, pattern_size)
        if corners is not None:
            hits += 1

    return hits


def choose_best_pattern(images):
    """Auto-select internal corner dimensions that detect most consistently."""
    candidates = []

    sample_images = images[:PATTERN_SEARCH_SAMPLE_LIMIT]
    sample_preprocessed_grays = [preprocess_for_corners(image) for _, image in sample_images]

    print(f"Pattern search sample size: {len(sample_preprocessed_grays)}")
    for pattern_size in PATTERN_CANDIDATES:
        hits = score_pattern(sample_preprocessed_grays, pattern_size)
        print(f"  pattern {pattern_size[0]}x{pattern_size[1]} -> {hits}/{len(sample_preprocessed_grays)} hits")
        if hits > 0:
            candidates.append((hits, pattern_size[0] * pattern_size[1], pattern_size[0], pattern_size[1]))

        # Early accept if detection is very consistent.
        if hits >= max(3, len(sample_preprocessed_grays) - 1):
            return pattern_size

    if not candidates:
        return None

    # Prefer highest hit count first, then larger grids.
    candidates.sort(reverse=True)
    best = candidates[0]
    print("Top candidate patterns (hits, corners, cols, rows):")
    for row in candidates[:8]:
        print(f"  {row}")

    return (best[2], best[3])


def collect_checkerboard_points(images, pattern_size):
    """Collect image/object points with known corner ordering from checkerboard."""
    cols, rows = pattern_size
    num_points = cols * rows

    obj_template = np.zeros((num_points, 1, 3), dtype=np.float64)
    grid = np.mgrid[0:cols, 0:rows].T.reshape(-1, 2)
    obj_template[:, 0, :2] = grid

    object_points = []
    image_points = []
    used_images = []

    for image_path, image in images:
        gray = preprocess_for_corners(image)
        corners = detect_checkerboard_corners(gray, pattern_size)

        if corners is None:
            print(f"✗ {os.path.basename(image_path)} - checkerboard detection failed")
            continue

        if corners.shape[0] != num_points:
            print(f"✗ {os.path.basename(image_path)} - unexpected corner count {corners.shape[0]}")
            continue

        object_points.append(obj_template.copy())
        image_points.append(corners.reshape(-1, 1, 2))
        used_images.append(image_path)
        print(f"✓ {os.path.basename(image_path)} - {corners.shape[0]} ordered corners")

    return object_points, image_points, used_images


def compute_fisheye_reprojection_errors(object_points, image_points, rvecs, tvecs, camera_matrix, dist_coeffs):
    errors = []

    for obj, img, rvec, tvec in zip(object_points, image_points, rvecs, tvecs):
        projected, _ = cv2.fisheye.projectPoints(obj.reshape(1, -1, 3), rvec, tvec, camera_matrix, dist_coeffs)
        diff = img.reshape(-1, 2) - projected.reshape(-1, 2)
        per_point = np.sqrt(np.sum(diff * diff, axis=1))
        errors.append(float(np.mean(per_point)))

    return np.array(errors, dtype=np.float64)


def calibrate_fisheye(image_shape_hw, object_points, image_points):
    """Fit fisheye intrinsics/extrinsics from checkerboard correspondences."""
    h, w = image_shape_hw
    image_size = (w, h)

    camera_matrix = np.eye(3, dtype=np.float64)
    dist_coeffs = np.zeros((4, 1), dtype=np.float64)

    flags_primary = (
        cv2.fisheye.CALIB_RECOMPUTE_EXTRINSIC
        | cv2.fisheye.CALIB_CHECK_COND
        | cv2.fisheye.CALIB_FIX_SKEW
    )

    criteria = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 200, 1e-8)

    try:
        rms, camera_matrix, dist_coeffs, rvecs, tvecs = cv2.fisheye.calibrate(
            object_points,
            image_points,
            image_size,
            camera_matrix,
            dist_coeffs,
            None,
            None,
            flags=flags_primary,
            criteria=criteria,
        )
    except cv2.error:
        flags_fallback = cv2.fisheye.CALIB_RECOMPUTE_EXTRINSIC | cv2.fisheye.CALIB_FIX_SKEW
        rms, camera_matrix, dist_coeffs, rvecs, tvecs = cv2.fisheye.calibrate(
            object_points,
            image_points,
            image_size,
            camera_matrix,
            dist_coeffs,
            None,
            None,
            flags=flags_fallback,
            criteria=criteria,
        )

    errors = compute_fisheye_reprojection_errors(
        object_points, image_points, rvecs, tvecs, camera_matrix, dist_coeffs
    )

    return {
        "rms": float(rms),
        "camera_matrix": camera_matrix,
        "dist_coeffs": dist_coeffs,
        "rvecs": rvecs,
        "tvecs": tvecs,
        "reprojection_errors": errors,
        "image_shape": image_shape_hw,
    }


def save_calibration(calib_data, output_dir, used_images, pattern_size):
    os.makedirs(output_dir, exist_ok=True)

    camera_matrix = calib_data["camera_matrix"]
    dist_coeffs = calib_data["dist_coeffs"]

    np.save(os.path.join(output_dir, "camera_matrix.npy"), camera_matrix)
    np.save(os.path.join(output_dir, "dist_coeffs.npy"), dist_coeffs)

    payload = {
        "model": "opencv_fisheye",
        "pattern_size_internal_corners": list(pattern_size),
        "image_shape_hw": list(calib_data["image_shape"]),
        "rms": calib_data["rms"],
        "mean_reprojection_error": float(np.mean(calib_data["reprojection_errors"])),
        "max_reprojection_error": float(np.max(calib_data["reprojection_errors"])),
        "num_images_used": len(used_images),
        "camera_matrix": camera_matrix.tolist(),
        "dist_coeffs": dist_coeffs.tolist(),
        "used_images": used_images,
    }

    with open(os.path.join(output_dir, "calibration.json"), "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)


def save_undistort_examples(calib_data, used_images, output_dir, num_examples=None):
    h, w = calib_data["image_shape"]
    camera_matrix = calib_data["camera_matrix"]
    dist_coeffs = calib_data["dist_coeffs"]

    if num_examples is None:
        num_examples = len(used_images)

    selected_images = used_images[:num_examples]

    # Remove prior comparisons so output always matches current run exactly.
    for existing in glob.glob(os.path.join(output_dir, "undistorted_comparison_*.png")):
        os.remove(existing)

    new_k = cv2.fisheye.estimateNewCameraMatrixForUndistortRectify(
        camera_matrix,
        dist_coeffs,
        (w, h),
        np.eye(3),
        balance=0.1,
    )

    map_x, map_y = cv2.fisheye.initUndistortRectifyMap(
        camera_matrix,
        dist_coeffs,
        np.eye(3),
        new_k,
        (w, h),
        cv2.CV_32FC1,
    )

    for i, image_path in enumerate(selected_images):
        src = cv2.imread(image_path)
        if src is None:
            continue
        und = cv2.remap(src, map_x, map_y, interpolation=cv2.INTER_LINEAR)
        comp = np.hstack([src, und])
        out = os.path.join(output_dir, f"undistorted_comparison_{i:02d}.png")
        cv2.imwrite(out, comp)


def save_original_to_new_lut(calib_data, output_dir, offset_x=ACTIVE_OFFSET_X, offset_y=ACTIVE_OFFSET_Y):
    """
    Save a forward LUT: distorted original pixel (x,y) -> undistorted pixel (x,y).

    Coordinates are exported in the original full-frame coordinate system using
    the known active-window offsets.
    """
    h, w = calib_data["image_shape"]
    camera_matrix = calib_data["camera_matrix"]
    dist_coeffs = calib_data["dist_coeffs"]

    new_k = cv2.fisheye.estimateNewCameraMatrixForUndistortRectify(
        camera_matrix,
        dist_coeffs,
        (w, h),
        np.eye(3),
        balance=0.1,
    )

    grid_x, grid_y = np.meshgrid(
        np.arange(w, dtype=np.float64),
        np.arange(h, dtype=np.float64),
    )
    distorted_points = np.stack([grid_x, grid_y], axis=-1).reshape(-1, 1, 2)

    undistorted_points = cv2.fisheye.undistortPoints(
        distorted_points,
        camera_matrix,
        dist_coeffs,
        R=np.eye(3),
        P=new_k,
    ).reshape(h, w, 2)

    new_x_crop = undistorted_points[:, :, 0].astype(np.float32)
    new_y_crop = undistorted_points[:, :, 1].astype(np.float32)

    new_x_full = (new_x_crop + float(offset_x)).astype(np.float32)
    new_y_full = (new_y_crop + float(offset_y)).astype(np.float32)

    valid = (
        (new_x_crop >= 0.0)
        & (new_x_crop <= float(w - 1))
        & (new_y_crop >= 0.0)
        & (new_y_crop <= float(h - 1))
    )

    np.save(os.path.join(output_dir, "lut_new_x_full.npy"), new_x_full)
    np.save(os.path.join(output_dir, "lut_new_y_full.npy"), new_y_full)
    np.save(os.path.join(output_dir, "lut_valid.npy"), valid.astype(np.uint8))

    csv_path = os.path.join(output_dir, "lookup_table_original_to_new_xy.csv")
    with open(csv_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(
            [
                "orig_x",
                "orig_y",
                "new_x",
                "new_y",
                "orig_x_crop",
                "orig_y_crop",
                "new_x_crop",
                "new_y_crop",
                "valid",
            ]
        )

        for y in range(h):
            for x in range(w):
                writer.writerow(
                    [
                        x + offset_x,
                        y + offset_y,
                        float(new_x_full[y, x]),
                        float(new_y_full[y, x]),
                        x,
                        y,
                        float(new_x_crop[y, x]),
                        float(new_y_crop[y, x]),
                        int(valid[y, x]),
                    ]
                )

    print(
        "Saved LUT files: "
        "lookup_table_original_to_new_xy.csv, lut_new_x_full.npy, lut_new_y_full.npy, lut_valid.npy"
    )


def main():
    print("=" * 60)
    print("Low-Resolution Checkerboard Calibration")
    print("=" * 60)

    images = load_calibration_images(CALIBRATION_IMAGES_DIR)
    if not images:
        print(f"No calibration images found in {CALIBRATION_IMAGES_DIR}")
        return

    print(f"Found {len(images)} calibration images")
    image_shape_hw = images[0][1].shape[:2]
    print(f"Image shape: {image_shape_hw}")

    print("\nSearching for best checkerboard pattern size...")
    pattern_size = choose_best_pattern(images)
    if pattern_size is None:
        print("Failed to find a checkerboard pattern in these images.")
        return

    print(f"Selected internal corner pattern: {pattern_size[0]}x{pattern_size[1]}")

    print("\nCollecting ordered checkerboard corners...")
    object_points, image_points, used_images = collect_checkerboard_points(images, pattern_size)
    if len(used_images) < MIN_USABLE_IMAGES:
        print(
            f"Not enough usable images for stable calibration: {len(used_images)} "
            f"(need at least {MIN_USABLE_IMAGES})"
        )
        return

    print(f"\nCalibrating fisheye model with {len(used_images)} images...")
    calib_data = calibrate_fisheye(image_shape_hw, object_points, image_points)

    print("\n" + "=" * 60)
    print("Calibration Results")
    print("=" * 60)
    print(f"RMS: {calib_data['rms']:.6f}")
    print(f"Mean reprojection error: {np.mean(calib_data['reprojection_errors']):.4f} px")
    print(f"Max reprojection error:  {np.max(calib_data['reprojection_errors']):.4f} px")
    print(f"Images used: {len(used_images)}/{len(images)}")
    print(f"Camera matrix:\n{calib_data['camera_matrix']}")
    print(f"Distortion coeffs:\n{calib_data['dist_coeffs'].ravel()}")

    save_calibration(calib_data, OUTPUT_DIR, used_images, pattern_size)
    save_undistort_examples(calib_data, used_images, OUTPUT_DIR)
    save_original_to_new_lut(calib_data, OUTPUT_DIR)

    print(f"\nSaved results in: {OUTPUT_DIR}")
    print("Done.")


if __name__ == "__main__":
    main()
