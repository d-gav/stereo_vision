#!/usr/bin/env python3
"""Generate a 640x288 stereo Verilog LUT from an existing fisheye calibration.

This script does NOT recalibrate. It loads an existing calibration JSON
(camera_matrix + dist_coeffs) and builds a per-lens undistort gather map for
320x288, then packs a full stereo LUT (left+right) into the Verilog format:

    {valid[20], src_y[19:10], src_x[9:0]}

Output coordinates are full-frame stereo coordinates:
- out x: 0..319   -> left lens source x: 0..319
- out x: 320..639 -> right lens source x: 320..639
- out y: 0..287   -> source y: 0..287

The script writes both:
- .memb (binary words, convenient for quick inspection/simulation)
- .mif  (Quartus memory initialization flow for fast LUT-only updates)
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import cv2
import numpy as np


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate stereo LUT from existing calibration JSON")
    parser.add_argument(
        "--calibration-json",
        type=Path,
        default=Path("python-testing") / "calibration_results" / "calibration.json",
        help="Path to existing calibration JSON",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("python-testing") / "calibration_results",
        help="Directory to write LUT outputs",
    )
    parser.add_argument(
        "--verilog-copy",
        type=Path,
        default=Path("computer_15_640_video_mod")
        / "computer_15_640_video_mod"
        / "verilog"
        / "undistort_lut_640x288_stereo_from_existing_calib_21b.memb",
        help="Optional copy target for packed Verilog memb file",
    )
    parser.add_argument(
        "--verilog-copy-mif",
        type=Path,
        default=Path("computer_15_640_video_mod")
        / "computer_15_640_video_mod"
        / "verilog"
        / "undistort_lut_640x288_stereo_from_existing_calib_21b.mif",
        help="Optional copy target for Quartus MIF file",
    )
    parser.add_argument("--lens-width", type=int, default=320, help="Per-lens input width")
    parser.add_argument("--lens-height", type=int, default=288, help="Per-lens input height")
    parser.add_argument(
        "--balance",
        type=float,
        default=0.10,
        help="balance for estimateNewCameraMatrixForUndistortRectify",
    )
    parser.add_argument(
        "--intrinsics-mode",
        choices=["copy", "scale"],
        default="copy",
        help=(
            "How to adapt old intrinsics to new lens size: "
            "copy=keep fx/fy/cx/cy as-is, scale=scale by new/old dimensions"
        ),
    )
    parser.add_argument("--cx-shift", type=float, default=0.0, help="Optional cx shift in pixels")
    parser.add_argument("--cy-shift", type=float, default=0.0, help="Optional cy shift in pixels")
    return parser.parse_args()


def load_calibration(path: Path) -> tuple[np.ndarray, np.ndarray, tuple[int, int], dict]:
    payload = json.loads(path.read_text(encoding="utf-8"))

    if payload.get("model") != "opencv_fisheye":
        raise ValueError(f"Unsupported calibration model {payload.get('model')!r}")

    shape_hw = payload.get("image_shape_hw")
    if not isinstance(shape_hw, list) or len(shape_hw) != 2:
        raise ValueError("calibration JSON missing image_shape_hw")

    h_old = int(shape_hw[0])
    w_old = int(shape_hw[1])

    camera_matrix = np.asarray(payload["camera_matrix"], dtype=np.float64)
    dist_coeffs = np.asarray(payload["dist_coeffs"], dtype=np.float64).reshape(-1, 1)

    if camera_matrix.shape != (3, 3):
        raise ValueError(f"camera_matrix shape must be (3,3), got {camera_matrix.shape}")
    if dist_coeffs.shape[0] != 4:
        raise ValueError(f"dist_coeffs must contain 4 coefficients, got {dist_coeffs.shape}")

    return camera_matrix, dist_coeffs, (h_old, w_old), payload


def adapt_intrinsics(
    k_old: np.ndarray,
    old_hw: tuple[int, int],
    new_hw: tuple[int, int],
    mode: str,
    cx_shift: float,
    cy_shift: float,
) -> np.ndarray:
    h_old, w_old = old_hw
    h_new, w_new = new_hw

    k = k_old.copy().astype(np.float64)

    if mode == "scale":
        sx = float(w_new) / float(w_old)
        sy = float(h_new) / float(h_old)
        k[0, 0] *= sx
        k[1, 1] *= sy
        k[0, 2] *= sx
        k[1, 2] *= sy

    k[0, 2] += cx_shift
    k[1, 2] += cy_shift
    return k


def build_lens_map(
    k: np.ndarray,
    d: np.ndarray,
    lens_w: int,
    lens_h: int,
    balance: float,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    size = (lens_w, lens_h)
    new_k = cv2.fisheye.estimateNewCameraMatrixForUndistortRectify(
        k,
        d,
        size,
        np.eye(3),
        balance=balance,
    )
    map_x, map_y = cv2.fisheye.initUndistortRectifyMap(
        k,
        d,
        np.eye(3),
        new_k,
        size,
        cv2.CV_32FC1,
    )

    finite = np.isfinite(map_x) & np.isfinite(map_y)
    in_bounds = (map_x >= 0.0) & (map_x <= (lens_w - 1)) & (map_y >= 0.0) & (map_y <= (lens_h - 1))
    valid = finite & in_bounds

    map_x_safe = np.nan_to_num(map_x, nan=0.0, posinf=0.0, neginf=0.0)
    map_y_safe = np.nan_to_num(map_y, nan=0.0, posinf=0.0, neginf=0.0)

    src_x = np.rint(np.clip(map_x_safe, 0.0, float(lens_w - 1))).astype(np.int32)
    src_y = np.rint(np.clip(map_y_safe, 0.0, float(lens_h - 1))).astype(np.int32)

    return src_x, src_y, valid.astype(np.uint8)


def build_stereo_packed(
    left_x: np.ndarray,
    left_y: np.ndarray,
    left_valid: np.ndarray,
    right_x: np.ndarray,
    right_y: np.ndarray,
    right_valid: np.ndarray,
    lens_w: int,
) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    h, w = left_x.shape
    if w != lens_w:
        raise ValueError("left map width mismatch")

    out_w = lens_w * 2

    stereo_src_x = np.zeros((h, out_w), dtype=np.int32)
    stereo_src_y = np.zeros((h, out_w), dtype=np.int32)
    stereo_valid = np.zeros((h, out_w), dtype=np.uint8)

    stereo_src_x[:, :lens_w] = left_x
    stereo_src_y[:, :lens_w] = left_y
    stereo_valid[:, :lens_w] = left_valid

    stereo_src_x[:, lens_w:] = right_x + lens_w
    stereo_src_y[:, lens_w:] = right_y
    stereo_valid[:, lens_w:] = right_valid

    packed = (
        ((stereo_valid.astype(np.uint32) & 0x1) << 20)
        | ((stereo_src_y.astype(np.uint32) & 0x3FF) << 10)
        | (stereo_src_x.astype(np.uint32) & 0x3FF)
    ).astype(np.uint32)

    return packed, stereo_src_x, stereo_src_y, stereo_valid


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


def main() -> None:
    args = parse_args()

    k_old, d, old_hw, payload = load_calibration(args.calibration_json)
    lens_hw = (args.lens_height, args.lens_width)

    k_use = adapt_intrinsics(
        k_old=k_old,
        old_hw=old_hw,
        new_hw=lens_hw,
        mode=args.intrinsics_mode,
        cx_shift=args.cx_shift,
        cy_shift=args.cy_shift,
    )

    left_x, left_y, left_valid = build_lens_map(
        k=k_use,
        d=d,
        lens_w=args.lens_width,
        lens_h=args.lens_height,
        balance=args.balance,
    )

    # No separate right calibration available; reuse same lens model for right.
    right_x, right_y, right_valid = left_x.copy(), left_y.copy(), left_valid.copy()

    packed, stereo_src_x, stereo_src_y, stereo_valid = build_stereo_packed(
        left_x=left_x,
        left_y=left_y,
        left_valid=left_valid,
        right_x=right_x,
        right_y=right_y,
        right_valid=right_valid,
        lens_w=args.lens_width,
    )

    out_dir = args.output_dir
    out_dir.mkdir(parents=True, exist_ok=True)

    memb_name = "undistort_lut_640x288_stereo_from_existing_calib_21b.memb"
    mif_name = "undistort_lut_640x288_stereo_from_existing_calib_21b.mif"
    memb_path = out_dir / memb_name
    mif_path = out_dir / mif_name
    write_memb_21(memb_path, packed)
    write_mif_21(mif_path, packed)

    np.save(out_dir / "lut_left_src_x_local_320x288.npy", left_x)
    np.save(out_dir / "lut_left_src_y_local_320x288.npy", left_y)
    np.save(out_dir / "lut_left_valid_320x288.npy", left_valid)
    np.save(out_dir / "lut_right_src_x_local_320x288.npy", right_x)
    np.save(out_dir / "lut_right_src_y_local_320x288.npy", right_y)
    np.save(out_dir / "lut_right_valid_320x288.npy", right_valid)
    np.save(out_dir / "lut_stereo_src_x_full_640x288.npy", stereo_src_x)
    np.save(out_dir / "lut_stereo_src_y_full_640x288.npy", stereo_src_y)
    np.save(out_dir / "lut_stereo_valid_640x288.npy", stereo_valid)

    meta = {
        "source_calibration_json": str(args.calibration_json),
        "calibration_model": payload.get("model"),
        "calibration_image_shape_hw": list(old_hw),
        "lens_size_wh": [args.lens_width, args.lens_height],
        "stereo_size_wh": [args.lens_width * 2, args.lens_height],
        "intrinsics_mode": args.intrinsics_mode,
        "cx_shift": args.cx_shift,
        "cy_shift": args.cy_shift,
        "balance": args.balance,
        "note": "Right lens LUT reused from same calibration (no separate right camera calibration provided).",
        "verilog_memb": str(memb_path),
        "verilog_mif": str(mif_path),
    }
    (out_dir / "stereo_lut_generation_report.json").write_text(
        json.dumps(meta, indent=2),
        encoding="utf-8",
    )

    copied_memb = False
    copied_mif = False
    try:
        args.verilog_copy.parent.mkdir(parents=True, exist_ok=True)
        args.verilog_copy.write_text(memb_path.read_text(encoding="utf-8"), encoding="utf-8")
        copied_memb = True
    except OSError as exc:
        print(f"Warning: unable to copy memb to verilog folder: {exc}")

    try:
        args.verilog_copy_mif.parent.mkdir(parents=True, exist_ok=True)
        args.verilog_copy_mif.write_text(mif_path.read_text(encoding="utf-8"), encoding="utf-8")
        copied_mif = True
    except OSError as exc:
        print(f"Warning: unable to copy mif to verilog folder: {exc}")

    valid_ratio = float(np.mean(stereo_valid.astype(np.float32)))

    print("Generated stereo LUT from existing calibration (no recalibration).")
    print(f"- Calibration JSON: {args.calibration_json}")
    print(f"- Intrinsics mode: {args.intrinsics_mode}")
    print(f"- Lens size: {args.lens_width}x{args.lens_height}")
    print(f"- Stereo size: {args.lens_width * 2}x{args.lens_height}")
    print(f"- Valid ratio: {valid_ratio:.4f}")
    print(f"- Saved memb: {memb_path}")
    print(f"- Saved mif: {mif_path}")
    if copied_memb:
        print(f"- Copied memb: {args.verilog_copy}")
    if copied_mif:
        print(f"- Copied mif: {args.verilog_copy_mif}")


if __name__ == "__main__":
    main()
