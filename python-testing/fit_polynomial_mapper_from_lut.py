#!/usr/bin/env python3
"""Fit fixed-point polynomial camera mapping models from LUT MIF files.

This script approximates LUT-based per-pixel remap with 2D polynomials:
    src_x_local = f(dst_x, dst_y)
    src_y       = g(dst_x, dst_y)

Coordinates are normalized to [-1, 1] before fitting to improve numerical
conditioning. The script evaluates both:
- floating-point coefficients
- fixed-point simulation (quantized coefficients and fixed-point arithmetic)

It writes:
- JSON report with error metrics and recommended degree/fraction bits
- SystemVerilog include with fixed-point coefficient tables
- Optional image comparisons against LUT remap if a sample image is provided
"""

from __future__ import annotations

import argparse
import json
import math
import re
from dataclasses import dataclass
from pathlib import Path

import numpy as np

try:
    import cv2
except ImportError:  # pragma: no cover
    cv2 = None


MIF_LINE_RE = re.compile(r"^\s*(\d+)\s*:\s*([01]+)\s*;\s*$")


@dataclass
class LutMap:
    width: int
    height: int
    valid: np.ndarray  # uint8, shape [H, W]
    src_x_local: np.ndarray  # float64, shape [H, W]
    src_y: np.ndarray  # float64, shape [H, W]


@dataclass
class CameraFitResult:
    terms: list[tuple[int, int]]
    coeff_x: np.ndarray
    coeff_y: np.ndarray
    float_metrics: dict[str, float]


def parse_int_list(csv_text: str) -> list[int]:
    values: list[int] = []
    for token in csv_text.split(","):
        token = token.strip()
        if not token:
            continue
        values.append(int(token))
    if not values:
        raise ValueError(f"Could not parse integer list from: {csv_text}")
    return values


def parse_mif_21(path: Path, expected_depth: int) -> np.ndarray:
    if not path.exists():
        raise FileNotFoundError(f"MIF not found: {path}")

    words = np.zeros(expected_depth, dtype=np.uint32)
    seen = np.zeros(expected_depth, dtype=np.uint8)

    in_content = False
    with path.open("r", encoding="utf-8") as f:
        for raw_line in f:
            line = raw_line.strip()
            upper = line.upper()

            if "CONTENT BEGIN" in upper:
                in_content = True
                continue
            if not in_content:
                continue
            if upper.startswith("END"):
                break

            m = MIF_LINE_RE.match(line)
            if m is None:
                continue

            addr = int(m.group(1))
            data_bits = m.group(2)
            if addr < 0 or addr >= expected_depth:
                continue
            words[addr] = int(data_bits, 2)
            seen[addr] = 1

    if int(np.sum(seen)) != expected_depth:
        missing = expected_depth - int(np.sum(seen))
        raise RuntimeError(
            f"MIF parse incomplete for {path}: missing {missing} addresses "
            f"out of {expected_depth}"
        )

    return words


def load_lut_map(mif_path: Path, width: int, height: int) -> LutMap:
    depth = width * height
    words = parse_mif_21(mif_path, expected_depth=depth).reshape(height, width)

    valid = ((words >> 20) & 0x1).astype(np.uint8)
    src_y = ((words >> 10) & 0x3FF).astype(np.float64)
    src_x = (words & 0x3FF).astype(np.float64)

    return LutMap(
        width=width,
        height=height,
        valid=valid,
        src_x_local=src_x,
        src_y=src_y,
    )


def poly_terms(total_degree: int) -> list[tuple[int, int]]:
    terms: list[tuple[int, int]] = []
    for degree in range(total_degree + 1):
        for px in range(degree, -1, -1):
            py = degree - px
            terms.append((px, py))
    return terms


def norm_coord(values: np.ndarray, max_value: int) -> np.ndarray:
    if max_value <= 0:
        raise ValueError("max_value must be positive")
    return (2.0 * values / float(max_value)) - 1.0


def denorm_coord(values_norm: np.ndarray, max_value: int) -> np.ndarray:
    return 0.5 * (values_norm + 1.0) * float(max_value)


def build_design_matrix(xn: np.ndarray, yn: np.ndarray, terms: list[tuple[int, int]]) -> np.ndarray:
    cols: list[np.ndarray] = []
    for px, py in terms:
        col = np.power(xn, px) * np.power(yn, py)
        cols.append(col)
    return np.stack(cols, axis=1)


def metric_summary(pred_x: np.ndarray, pred_y: np.ndarray, tgt_x: np.ndarray, tgt_y: np.ndarray, width: int, height: int) -> dict[str, float]:
    dx = pred_x - tgt_x
    dy = pred_y - tgt_y
    e2 = dx * dx + dy * dy
    e = np.sqrt(e2)

    in_range = (
        (pred_x >= 0.0)
        & (pred_x <= (width - 1))
        & (pred_y >= 0.0)
        & (pred_y <= (height - 1))
    )

    return {
        "rmse_x_px": float(np.sqrt(np.mean(dx * dx))),
        "rmse_y_px": float(np.sqrt(np.mean(dy * dy))),
        "rmse_euclid_px": float(np.sqrt(np.mean(e2))),
        "mae_euclid_px": float(np.mean(e)),
        "p95_euclid_px": float(np.percentile(e, 95.0)),
        "max_euclid_px": float(np.max(e)),
        "in_range_fraction": float(np.mean(in_range.astype(np.float64))),
    }


def fit_camera_float(lut_map: LutMap, degree: int) -> CameraFitResult:
    ys, xs = np.indices((lut_map.height, lut_map.width), dtype=np.float64)
    mask = lut_map.valid.astype(bool)

    x = xs[mask]
    y = ys[mask]
    tgt_x = lut_map.src_x_local[mask]
    tgt_y = lut_map.src_y[mask]

    xn = norm_coord(x, lut_map.width - 1)
    yn = norm_coord(y, lut_map.height - 1)
    tgt_xn = norm_coord(tgt_x, lut_map.width - 1)
    tgt_yn = norm_coord(tgt_y, lut_map.height - 1)

    terms = poly_terms(degree)
    phi = build_design_matrix(xn, yn, terms)

    coeff_x, *_ = np.linalg.lstsq(phi, tgt_xn, rcond=None)
    coeff_y, *_ = np.linalg.lstsq(phi, tgt_yn, rcond=None)

    pred_xn = phi @ coeff_x
    pred_yn = phi @ coeff_y
    pred_x = denorm_coord(pred_xn, lut_map.width - 1)
    pred_y = denorm_coord(pred_yn, lut_map.height - 1)

    metrics = metric_summary(pred_x, pred_y, tgt_x, tgt_y, lut_map.width, lut_map.height)

    return CameraFitResult(
        terms=terms,
        coeff_x=coeff_x,
        coeff_y=coeff_y,
        float_metrics=metrics,
    )


def fixed_mul_q(a: np.ndarray | np.int64, b: np.ndarray | np.int64, frac_bits: int) -> np.ndarray:
    prod = np.asarray(a, dtype=np.int64) * np.asarray(b, dtype=np.int64)
    if frac_bits <= 0:
        return prod
    half = 1 << (frac_bits - 1)
    # Symmetric rounding for signed products.
    return np.where(prod >= 0, (prod + half) >> frac_bits, (prod - half) >> frac_bits)


def evaluate_camera_fixed(
    lut_map: LutMap,
    terms: list[tuple[int, int]],
    coeff_x: np.ndarray,
    coeff_y: np.ndarray,
    frac_bits: int,
) -> tuple[dict[str, float], np.ndarray, np.ndarray]:
    ys, xs = np.indices((lut_map.height, lut_map.width), dtype=np.float64)
    mask = lut_map.valid.astype(bool)

    x = xs[mask]
    y = ys[mask]
    tgt_x = lut_map.src_x_local[mask]
    tgt_y = lut_map.src_y[mask]

    xn = norm_coord(x, lut_map.width - 1)
    yn = norm_coord(y, lut_map.height - 1)

    scale = 1 << frac_bits
    xn_q = np.rint(xn * scale).astype(np.int64)
    yn_q = np.rint(yn * scale).astype(np.int64)

    coeff_x_q = np.rint(coeff_x * scale).astype(np.int64)
    coeff_y_q = np.rint(coeff_y * scale).astype(np.int64)

    max_pow_x = max(px for px, _ in terms)
    max_pow_y = max(py for _, py in terms)

    x_pows: list[np.ndarray] = [np.full_like(xn_q, scale, dtype=np.int64)]
    y_pows: list[np.ndarray] = [np.full_like(yn_q, scale, dtype=np.int64)]

    for _ in range(max_pow_x):
        x_pows.append(fixed_mul_q(x_pows[-1], xn_q, frac_bits))
    for _ in range(max_pow_y):
        y_pows.append(fixed_mul_q(y_pows[-1], yn_q, frac_bits))

    acc_x = np.zeros_like(xn_q, dtype=np.int64)
    acc_y = np.zeros_like(yn_q, dtype=np.int64)

    for idx, (px, py) in enumerate(terms):
        term_q = fixed_mul_q(x_pows[px], y_pows[py], frac_bits)
        acc_x += fixed_mul_q(term_q, coeff_x_q[idx], frac_bits)
        acc_y += fixed_mul_q(term_q, coeff_y_q[idx], frac_bits)

    pred_xn = acc_x.astype(np.float64) / float(scale)
    pred_yn = acc_y.astype(np.float64) / float(scale)

    pred_x = denorm_coord(pred_xn, lut_map.width - 1)
    pred_y = denorm_coord(pred_yn, lut_map.height - 1)

    metrics = metric_summary(pred_x, pred_y, tgt_x, tgt_y, lut_map.width, lut_map.height)
    return metrics, coeff_x_q, coeff_y_q


def predict_full_grid_float(
    width: int,
    height: int,
    terms: list[tuple[int, int]],
    coeff_x: np.ndarray,
    coeff_y: np.ndarray,
) -> tuple[np.ndarray, np.ndarray]:
    ys, xs = np.indices((height, width), dtype=np.float64)
    xn = norm_coord(xs.reshape(-1), width - 1)
    yn = norm_coord(ys.reshape(-1), height - 1)
    phi = build_design_matrix(xn, yn, terms)

    pred_x = denorm_coord(phi @ coeff_x, width - 1).reshape(height, width)
    pred_y = denorm_coord(phi @ coeff_y, height - 1).reshape(height, width)
    return pred_x, pred_y


def psnr(a: np.ndarray, b: np.ndarray) -> float:
    mse = float(np.mean((a.astype(np.float64) - b.astype(np.float64)) ** 2))
    if mse <= 0.0:
        return 99.0
    return 10.0 * math.log10((255.0 * 255.0) / mse)


def remap_from_lut(image: np.ndarray, lut_map: LutMap) -> np.ndarray:
    if cv2 is None:
        raise RuntimeError("opencv-python is required for image remap evaluation")

    map_x = np.where(lut_map.valid > 0, lut_map.src_x_local, 0.0).astype(np.float32)
    map_y = np.where(lut_map.valid > 0, lut_map.src_y, 0.0).astype(np.float32)

    return cv2.remap(
        image,
        map_x,
        map_y,
        interpolation=cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=0,
    )


def remap_from_poly(image: np.ndarray, pred_x: np.ndarray, pred_y: np.ndarray) -> np.ndarray:
    if cv2 is None:
        raise RuntimeError("opencv-python is required for image remap evaluation")

    h, w = image.shape[:2]
    in_range = (pred_x >= 0.0) & (pred_x <= (w - 1)) & (pred_y >= 0.0) & (pred_y <= (h - 1))

    map_x = np.where(in_range, pred_x, 0.0).astype(np.float32)
    map_y = np.where(in_range, pred_y, 0.0).astype(np.float32)

    return cv2.remap(
        image,
        map_x,
        map_y,
        interpolation=cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=0,
    )


def coeff_bit_width(*arrays: np.ndarray) -> int:
    max_abs = 1
    for arr in arrays:
        if arr.size == 0:
            continue
        max_abs = max(max_abs, int(np.max(np.abs(arr))))
    # +1 sign bit
    return int(math.ceil(math.log2(max_abs + 1))) + 1


def write_verilog_coeff_include(
    out_path: Path,
    degree: int,
    frac_bits: int,
    terms: list[tuple[int, int]],
    left_coeff_x_q: np.ndarray,
    left_coeff_y_q: np.ndarray,
    right_coeff_x_q: np.ndarray,
    right_coeff_y_q: np.ndarray,
) -> None:
    term_count = len(terms)
    width_bits = coeff_bit_width(left_coeff_x_q, left_coeff_y_q, right_coeff_x_q, right_coeff_y_q)

    def arr_literal(values: np.ndarray) -> str:
        parts = [str(int(v)) for v in values.tolist()]
        return "'{" + ", ".join(parts) + "}"

    lines: list[str] = []
    lines.append("// Auto-generated by fit_polynomial_mapper_from_lut.py")
    lines.append(f"localparam int POLY_DEGREE = {degree};")
    lines.append(f"localparam int POLY_TERM_COUNT = {term_count};")
    lines.append(f"localparam int POLY_FRAC_BITS = {frac_bits};")
    lines.append(f"localparam int POLY_COEFF_WIDTH = {width_bits};")
    lines.append("")
    lines.append("// Term order: index -> x_power, y_power")
    for idx, (px, py) in enumerate(terms):
        lines.append(f"// {idx:2d} -> x^{px} y^{py}")
    lines.append("")
    lines.append(
        "localparam logic signed [POLY_COEFF_WIDTH-1:0] LEFT_COEFF_X [0:POLY_TERM_COUNT-1] = "
        + arr_literal(left_coeff_x_q)
        + ";"
    )
    lines.append(
        "localparam logic signed [POLY_COEFF_WIDTH-1:0] LEFT_COEFF_Y [0:POLY_TERM_COUNT-1] = "
        + arr_literal(left_coeff_y_q)
        + ";"
    )
    lines.append(
        "localparam logic signed [POLY_COEFF_WIDTH-1:0] RIGHT_COEFF_X [0:POLY_TERM_COUNT-1] = "
        + arr_literal(right_coeff_x_q)
        + ";"
    )
    lines.append(
        "localparam logic signed [POLY_COEFF_WIDTH-1:0] RIGHT_COEFF_Y [0:POLY_TERM_COUNT-1] = "
        + arr_literal(right_coeff_y_q)
        + ";"
    )
    lines.append("")

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Fit fixed-point polynomial mapping from LUT MIF files")
    parser.add_argument(
        "--left-mif",
        type=Path,
        default=Path("python-testing") / "dual_camera_calibration_results_best_both_sets" / "left_camera" / "left_lut_315x288_21b.mif",
        help="Path to left camera LUT MIF",
    )
    parser.add_argument(
        "--right-mif",
        type=Path,
        default=Path("python-testing") / "dual_camera_calibration_results_best_both_sets" / "right_camera" / "right_lut_315x288_21b.mif",
        help="Path to right camera LUT MIF",
    )
    parser.add_argument("--width", type=int, default=315, help="Per-camera LUT width")
    parser.add_argument("--height", type=int, default=288, help="Per-camera LUT height")
    parser.add_argument("--degrees", type=str, default="2,3,4,5", help="Comma-separated polynomial total degrees to test")
    parser.add_argument(
        "--frac-bits",
        type=str,
        default="10,12,14,16",
        help="Comma-separated fixed-point fractional bits to test",
    )
    parser.add_argument(
        "--sample-image",
        type=Path,
        default=None,
        help="Optional combined stereo image for LUT-vs-polynomial remap comparison",
    )
    parser.add_argument("--sample-top-y", type=int, default=0, help="Sample image crop top y")
    parser.add_argument("--sample-left-x", type=int, default=0, help="Sample image left crop x")
    parser.add_argument("--sample-right-x", type=int, default=319, help="Sample image right crop x")
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("python-testing") / "polynomial_fit_results",
        help="Directory for fit report and coefficient output",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    degrees = parse_int_list(args.degrees)
    frac_bits_list = parse_int_list(args.frac_bits)

    if any(d < 1 for d in degrees):
        raise ValueError("All degrees must be >= 1")
    if any(f < 1 for f in frac_bits_list):
        raise ValueError("All frac-bits entries must be >= 1")

    args.output_dir.mkdir(parents=True, exist_ok=True)

    left_lut = load_lut_map(args.left_mif, args.width, args.height)
    right_lut = load_lut_map(args.right_mif, args.width, args.height)

    fit_cache: dict[str, dict[int, CameraFitResult]] = {"left": {}, "right": {}}
    fixed_metrics_rows: list[dict[str, object]] = []

    for degree in degrees:
        fit_cache["left"][degree] = fit_camera_float(left_lut, degree)
        fit_cache["right"][degree] = fit_camera_float(right_lut, degree)

        for frac_bits in frac_bits_list:
            left_fixed_metrics, _, _ = evaluate_camera_fixed(
                left_lut,
                fit_cache["left"][degree].terms,
                fit_cache["left"][degree].coeff_x,
                fit_cache["left"][degree].coeff_y,
                frac_bits,
            )
            right_fixed_metrics, _, _ = evaluate_camera_fixed(
                right_lut,
                fit_cache["right"][degree].terms,
                fit_cache["right"][degree].coeff_x,
                fit_cache["right"][degree].coeff_y,
                frac_bits,
            )

            combined_rmse = 0.5 * (
                left_fixed_metrics["rmse_euclid_px"] + right_fixed_metrics["rmse_euclid_px"]
            )

            fixed_metrics_rows.append(
                {
                    "degree": degree,
                    "frac_bits": frac_bits,
                    "combined_rmse_euclid_px": combined_rmse,
                    "left": left_fixed_metrics,
                    "right": right_fixed_metrics,
                }
            )

    best_row = min(fixed_metrics_rows, key=lambda row: float(row["combined_rmse_euclid_px"]))
    best_degree = int(best_row["degree"])
    best_frac = int(best_row["frac_bits"])

    left_best_fit = fit_cache["left"][best_degree]
    right_best_fit = fit_cache["right"][best_degree]

    left_best_fixed_metrics, left_coeff_x_q, left_coeff_y_q = evaluate_camera_fixed(
        left_lut,
        left_best_fit.terms,
        left_best_fit.coeff_x,
        left_best_fit.coeff_y,
        best_frac,
    )
    right_best_fixed_metrics, right_coeff_x_q, right_coeff_y_q = evaluate_camera_fixed(
        right_lut,
        right_best_fit.terms,
        right_best_fit.coeff_x,
        right_best_fit.coeff_y,
        best_frac,
    )

    coeff_path = args.output_dir / f"poly_coeff_deg{best_degree}_q{best_frac}.svh"
    write_verilog_coeff_include(
        coeff_path,
        degree=best_degree,
        frac_bits=best_frac,
        terms=left_best_fit.terms,
        left_coeff_x_q=left_coeff_x_q,
        left_coeff_y_q=left_coeff_y_q,
        right_coeff_x_q=right_coeff_x_q,
        right_coeff_y_q=right_coeff_y_q,
    )

    image_eval: dict[str, object] | None = None
    if args.sample_image is not None:
        if cv2 is None:
            raise RuntimeError("opencv-python is required when using --sample-image")

        sample = cv2.imread(str(args.sample_image), cv2.IMREAD_COLOR)
        if sample is None:
            raise RuntimeError(f"Failed to load sample image: {args.sample_image}")

        h, w = sample.shape[:2]
        left_x0 = args.sample_left_x
        right_x0 = args.sample_right_x
        y0 = args.sample_top_y
        y1 = y0 + args.height
        left_x1 = left_x0 + args.width
        right_x1 = right_x0 + args.width

        if y1 > h or left_x1 > w or right_x1 > w:
            raise RuntimeError(
                f"Sample crop exceeds image bounds: image={w}x{h}, "
                f"left=[{left_x0}:{left_x1}], right=[{right_x0}:{right_x1}], y=[{y0}:{y1}]"
            )

        left_in = sample[y0:y1, left_x0:left_x1]
        right_in = sample[y0:y1, right_x0:right_x1]

        left_lut_img = remap_from_lut(left_in, left_lut)
        right_lut_img = remap_from_lut(right_in, right_lut)

        left_pred_x, left_pred_y = predict_full_grid_float(
            args.width,
            args.height,
            left_best_fit.terms,
            left_best_fit.coeff_x,
            left_best_fit.coeff_y,
        )
        right_pred_x, right_pred_y = predict_full_grid_float(
            args.width,
            args.height,
            right_best_fit.terms,
            right_best_fit.coeff_x,
            right_best_fit.coeff_y,
        )

        left_poly_img = remap_from_poly(left_in, left_pred_x, left_pred_y)
        right_poly_img = remap_from_poly(right_in, right_pred_x, right_pred_y)

        left_diff = cv2.absdiff(left_lut_img, left_poly_img)
        right_diff = cv2.absdiff(right_lut_img, right_poly_img)

        pair_lut = np.hstack([left_lut_img, right_lut_img])
        pair_poly = np.hstack([left_poly_img, right_poly_img])
        pair_diff = np.hstack([left_diff, right_diff])

        cv2.imwrite(str(args.output_dir / "sample_pair_lut.png"), pair_lut)
        cv2.imwrite(str(args.output_dir / "sample_pair_poly.png"), pair_poly)
        cv2.imwrite(str(args.output_dir / "sample_pair_absdiff.png"), pair_diff)

        image_eval = {
            "sample_image": str(args.sample_image),
            "left_psnr_poly_vs_lut_db": psnr(left_lut_img, left_poly_img),
            "right_psnr_poly_vs_lut_db": psnr(right_lut_img, right_poly_img),
            "left_mae_poly_vs_lut": float(np.mean(np.abs(left_lut_img.astype(np.float64) - left_poly_img.astype(np.float64)))),
            "right_mae_poly_vs_lut": float(np.mean(np.abs(right_lut_img.astype(np.float64) - right_poly_img.astype(np.float64)))),
            "output_images": {
                "lut_pair": str(args.output_dir / "sample_pair_lut.png"),
                "poly_pair": str(args.output_dir / "sample_pair_poly.png"),
                "absdiff_pair": str(args.output_dir / "sample_pair_absdiff.png"),
            },
        }

    report = {
        "inputs": {
            "left_mif": str(args.left_mif),
            "right_mif": str(args.right_mif),
            "width": args.width,
            "height": args.height,
            "degrees_tested": degrees,
            "frac_bits_tested": frac_bits_list,
        },
        "lut_valid_fraction": {
            "left": float(np.mean(left_lut.valid.astype(np.float64))),
            "right": float(np.mean(right_lut.valid.astype(np.float64))),
        },
        "float_fit_by_degree": {
            str(d): {
                "left": fit_cache["left"][d].float_metrics,
                "right": fit_cache["right"][d].float_metrics,
            }
            for d in degrees
        },
        "fixed_fit_grid": fixed_metrics_rows,
        "recommended": {
            "degree": best_degree,
            "frac_bits": best_frac,
            "combined_rmse_euclid_px": float(best_row["combined_rmse_euclid_px"]),
            "left_fixed_metrics": left_best_fixed_metrics,
            "right_fixed_metrics": right_best_fixed_metrics,
            "coeff_include": str(coeff_path),
        },
        "image_eval": image_eval,
    }

    report_path = args.output_dir / "fit_report.json"
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")

    print("Done.")
    print(f"Report: {report_path}")
    print(f"Recommended degree={best_degree}, frac_bits={best_frac}")
    print(f"Coeff include: {coeff_path}")
    print(
        "RMSE euclid px (fixed): "
        f"left={left_best_fixed_metrics['rmse_euclid_px']:.4f}, "
        f"right={right_best_fixed_metrics['rmse_euclid_px']:.4f}"
    )


if __name__ == "__main__":
    main()
