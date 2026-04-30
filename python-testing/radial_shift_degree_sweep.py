#!/usr/bin/env python3
"""Sweep radial-model center shifts and polynomial degree against LUT maps.

Outputs JSON + CSV with:
- best center shift in +/- 25 px window (deg=5)
- degree sweep at nominal center
- degree sweep at best-shift center
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path

import numpy as np

MIF_LINE_RE = re.compile(r"^\s*(\d+)\s*:\s*([01]+)\s*;\s*$")

W = 315
H = 288
NOM_CX = (W - 1) / 2.0
NOM_CY = (H - 1) / 2.0
RMAX2 = NOM_CX * NOM_CX + NOM_CY * NOM_CY


@dataclass
class FitMetrics:
    deg: int
    cdx: float
    cdy: float
    csx: float
    csy: float
    rmse: float
    p95: float
    max_err: float
    dx: int | None = None
    dy: int | None = None

    def to_dict(self) -> dict[str, float | int | None]:
        return {
            "deg": self.deg,
            "cdx": self.cdx,
            "cdy": self.cdy,
            "csx": self.csx,
            "csy": self.csy,
            "rmse": self.rmse,
            "p95": self.p95,
            "max": self.max_err,
            "dx": self.dx,
            "dy": self.dy,
        }


def parse_mif(path: Path, w: int = W, h: int = H) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    depth = w * h
    words = np.zeros(depth, dtype=np.uint32)
    seen = np.zeros(depth, dtype=np.uint8)

    in_content = False
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            upper = line.strip().upper()
            if "CONTENT BEGIN" in upper:
                in_content = True
                continue
            if not in_content:
                continue
            if upper.startswith("END"):
                break

            m = MIF_LINE_RE.match(line)
            if not m:
                continue

            addr = int(m.group(1))
            if 0 <= addr < depth:
                words[addr] = int(m.group(2), 2)
                seen[addr] = 1

    if int(np.sum(seen)) != depth:
        missing = depth - int(np.sum(seen))
        raise RuntimeError(f"Incomplete MIF parse for {path}, missing {missing} entries")

    words = words.reshape(h, w)
    valid = ((words >> 20) & 1).astype(bool)
    sy = ((words >> 10) & 0x3FF).astype(np.float64)
    sx = (words & 0x3FF).astype(np.float64)

    ys, xs = np.indices((h, w), dtype=np.float64)
    return xs[valid], ys[valid], sx[valid], sy[valid]


def fit_radial(xs: np.ndarray, ys: np.ndarray, sx: np.ndarray, sy: np.ndarray, cdx: float, cdy: float, deg: int) -> FitMetrics:
    vdx = xs - cdx
    vdy = ys - cdy
    t = (vdx * vdx + vdy * vdy) / RMAX2

    k = deg + 1
    n = xs.size

    A = np.zeros((2 * n, 2 + k), dtype=np.float64)
    b = np.zeros((2 * n,), dtype=np.float64)

    tk = np.stack([t**i for i in range(k)], axis=1)

    A[:n, 0] = 1.0
    A[:n, 2:] = vdx[:, None] * tk
    b[:n] = sx

    A[n:, 1] = 1.0
    A[n:, 2:] = vdy[:, None] * tk
    b[n:] = sy

    p, *_ = np.linalg.lstsq(A, b, rcond=None)
    csx = float(p[0])
    csy = float(p[1])
    coeff = p[2:]

    s = np.polyval(coeff[::-1], t)
    px = csx + s * vdx
    py = csy + s * vdy
    e = np.sqrt((px - sx) ** 2 + (py - sy) ** 2)

    return FitMetrics(
        deg=deg,
        cdx=float(cdx),
        cdy=float(cdy),
        csx=csx,
        csy=csy,
        rmse=float(np.sqrt(np.mean(e * e))),
        p95=float(np.percentile(e, 95)),
        max_err=float(np.max(e)),
    )


def center_sweep(
    xs: np.ndarray,
    ys: np.ndarray,
    sx: np.ndarray,
    sy: np.ndarray,
    deg: int,
    shift_max: int,
    step: int,
) -> tuple[FitMetrics, list[FitMetrics]]:
    best: FitMetrics | None = None
    all_results: list[FitMetrics] = []

    for dx in range(-shift_max, shift_max + 1, step):
        for dy in range(-shift_max, shift_max + 1, step):
            fm = fit_radial(xs, ys, sx, sy, NOM_CX + dx, NOM_CY + dy, deg)
            fm.dx = dx
            fm.dy = dy
            all_results.append(fm)
            if best is None or fm.rmse < best.rmse:
                best = fm

    assert best is not None
    top10 = sorted(all_results, key=lambda z: z.rmse)[:10]
    return best, top10


def degree_sweep(xs: np.ndarray, ys: np.ndarray, sx: np.ndarray, sy: np.ndarray, cdx: float, cdy: float, degrees: list[int]) -> list[FitMetrics]:
    return [fit_radial(xs, ys, sx, sy, cdx, cdy, d) for d in degrees]


def downsample_for_search(xs: np.ndarray, ys: np.ndarray, sx: np.ndarray, sy: np.ndarray, n: int = 12000) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    if xs.size <= n:
        return xs, ys, sx, sy
    rng = np.random.default_rng(0)
    idx = rng.choice(xs.size, size=n, replace=False)
    return xs[idx], ys[idx], sx[idx], sy[idx]


def to_rows(tag: str, vals: list[FitMetrics]) -> list[dict[str, float | int | str | None]]:
    rows: list[dict[str, float | int | str | None]] = []
    for v in vals:
        r = v.to_dict()
        r["series"] = tag
        rows.append(r)
    return rows


def main() -> None:
    root = Path(r"c:\Users\er495\Downloads\stereo_vision")
    left_mif = root / r"python-testing\dual_camera_calibration_results_best_both_sets\left_camera\left_lut_315x288_21b.mif"
    right_mif = root / r"python-testing\dual_camera_calibration_results_best_both_sets\right_camera\right_lut_315x288_21b.mif"

    out_dir = root / r"python-testing\radial_symmetry_sweep_results"
    out_dir.mkdir(parents=True, exist_ok=True)

    left_full = parse_mif(left_mif)
    right_full = parse_mif(right_mif)

    left_srch = downsample_for_search(*left_full, n=10000)
    right_srch = downsample_for_search(*right_full, n=10000)

    print("Starting center sweep (degree 5, +/-25 px, 1 px step) ...", flush=True)

    # Center shift search in +/-25 window using degree 5.
    left_best_d5_srch, left_top10_srch = center_sweep(*left_srch, deg=5, shift_max=25, step=1)
    right_best_d5_srch, right_top10_srch = center_sweep(*right_srch, deg=5, shift_max=25, step=1)

    # Re-evaluate best shifts and nominal on full set for accurate metrics.
    print("Evaluating best-shift and nominal-center metrics on full dataset ...", flush=True)
    left_best_d5_full = fit_radial(*left_full, left_best_d5_srch.cdx, left_best_d5_srch.cdy, 5)
    left_best_d5_full.dx = left_best_d5_srch.dx
    left_best_d5_full.dy = left_best_d5_srch.dy

    right_best_d5_full = fit_radial(*right_full, right_best_d5_srch.cdx, right_best_d5_srch.cdy, 5)
    right_best_d5_full.dx = right_best_d5_srch.dx
    right_best_d5_full.dy = right_best_d5_srch.dy

    left_nom_d5_full = fit_radial(*left_full, NOM_CX, NOM_CY, 5)
    left_nom_d5_full.dx = 0
    left_nom_d5_full.dy = 0
    right_nom_d5_full = fit_radial(*right_full, NOM_CX, NOM_CY, 5)
    right_nom_d5_full.dx = 0
    right_nom_d5_full.dy = 0

    # Degree sweep.
    print("Running degree sweep (1..12) at nominal center and best-shift center ...", flush=True)
    degrees = list(range(1, 13))
    left_deg_nom_full = degree_sweep(*left_full, NOM_CX, NOM_CY, degrees)
    right_deg_nom_full = degree_sweep(*right_full, NOM_CX, NOM_CY, degrees)

    left_deg_at_best_d5_full = degree_sweep(*left_full, left_best_d5_full.cdx, left_best_d5_full.cdy, degrees)
    right_deg_at_best_d5_full = degree_sweep(*right_full, right_best_d5_full.cdx, right_best_d5_full.cdy, degrees)

    report = {
        "image_size": {"w": W, "h": H},
        "nominal_center": {"cx": NOM_CX, "cy": NOM_CY},
        "center_shift_sweep_deg5": {
            "left_nominal_full": left_nom_d5_full.to_dict(),
            "right_nominal_full": right_nom_d5_full.to_dict(),
            "left_best_full": left_best_d5_full.to_dict(),
            "right_best_full": right_best_d5_full.to_dict(),
            "left_top10_search": [m.to_dict() for m in left_top10_srch],
            "right_top10_search": [m.to_dict() for m in right_top10_srch],
        },
        "degree_sweep_nominal_center_full": {
            "left": [m.to_dict() for m in left_deg_nom_full],
            "right": [m.to_dict() for m in right_deg_nom_full],
        },
        "degree_sweep_at_best_deg5_center_full": {
            "left": [m.to_dict() for m in left_deg_at_best_d5_full],
            "right": [m.to_dict() for m in right_deg_at_best_d5_full],
        },
    }

    out_json = out_dir / "radial_center_degree_sweep.json"
    out_json.write_text(json.dumps(report, indent=2), encoding="utf-8")

    csv_rows: list[dict[str, float | int | str | None]] = []
    csv_rows += to_rows("left_deg_nom_full", left_deg_nom_full)
    csv_rows += to_rows("right_deg_nom_full", right_deg_nom_full)
    csv_rows += to_rows("left_deg_at_bestd5_full", left_deg_at_best_d5_full)
    csv_rows += to_rows("right_deg_at_bestd5_full", right_deg_at_best_d5_full)

    out_csv = out_dir / "radial_center_degree_sweep.csv"
    header = ["series", "deg", "dx", "dy", "cdx", "cdy", "csx", "csy", "rmse", "p95", "max"]
    lines = [",".join(header)]
    for r in csv_rows:
        lines.append(
            f"{r['series']},{r['deg']},{r.get('dx','')},{r.get('dy','')},{r['cdx']:.6f},{r['cdy']:.6f},{r['csx']:.6f},{r['csy']:.6f},{r['rmse']:.6f},{r['p95']:.6f},{r['max']:.6f}"
        )
    out_csv.write_text("\n".join(lines) + "\n", encoding="utf-8")

    best_left_nom = min(left_deg_nom_full, key=lambda z: z.rmse)
    best_right_nom = min(right_deg_nom_full, key=lambda z: z.rmse)

    print(f"LEFT best shift (deg5, full): dx={left_best_d5_full.dx} dy={left_best_d5_full.dy} rmse={left_best_d5_full.rmse:.4f} p95={left_best_d5_full.p95:.4f}")
    print(f"RIGHT best shift (deg5, full): dx={right_best_d5_full.dx} dy={right_best_d5_full.dy} rmse={right_best_d5_full.rmse:.4f} p95={right_best_d5_full.p95:.4f}")
    print(f"BEST DEG @ NOM CENTER: left deg={best_left_nom.deg} rmse={best_left_nom.rmse:.4f} | right deg={best_right_nom.deg} rmse={best_right_nom.rmse:.4f}")

    best_left_at_bestd5 = min(left_deg_at_best_d5_full, key=lambda z: z.rmse)
    best_right_at_bestd5 = min(right_deg_at_best_d5_full, key=lambda z: z.rmse)
    print(
        "BEST DEG @ BEST-D5-SHIFT CENTER: "
        f"left deg={best_left_at_bestd5.deg} rmse={best_left_at_bestd5.rmse:.4f} | "
        f"right deg={best_right_at_bestd5.deg} rmse={best_right_at_bestd5.rmse:.4f}"
    )
    print(f"REPORT_JSON: {out_json}")
    print(f"REPORT_CSV: {out_csv}")


if __name__ == "__main__":
    main()
