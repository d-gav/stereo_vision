import argparse
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np


def focal_length_px(image_width_px: float, horizontal_fov_deg: float) -> float:
    half_angle_rad = np.deg2rad(horizontal_fov_deg / 2.0)
    return (image_width_px / 2.0) / np.tan(half_angle_rad)


def parse_float_list(csv_string: str) -> np.ndarray:
    values = [v.strip() for v in csv_string.split(",") if v.strip()]
    if not values:
        return np.array([], dtype=float)
    return np.array([float(v) for v in values], dtype=float)


def representative_baselines_cm(
    baselines_cm: np.ndarray, count: int = 5
) -> np.ndarray:
    if baselines_cm.size == 0:
        return np.array([], dtype=float)
    count = max(1, min(count, baselines_cm.size))
    idx = np.linspace(0, baselines_cm.size - 1, count).round().astype(int)
    return np.unique(baselines_cm[idx])


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Visualize stereo depth range and depth resolution as a function of "
            "camera baseline spacing."
        )
    )
    parser.add_argument("--fov-deg", type=float, default=108.0, help="Horizontal FOV in degrees.")
    parser.add_argument(
        "--image-width-px",
        type=float,
        default=320.0,
        help="Horizontal image resolution in pixels.",
    )
    parser.add_argument("--baseline-min-cm", type=float, default=2.0, help="Minimum baseline in cm.")
    parser.add_argument("--baseline-max-cm", type=float, default=30.0, help="Maximum baseline in cm.")
    parser.add_argument(
        "--baseline-steps",
        type=int,
        default=120,
        help="Number of baseline samples in the sweep.",
    )
    parser.add_argument("--depth-min-m", type=float, default=0.2, help="Minimum depth shown (m).")
    parser.add_argument(
        "--depth-max-m",
        type=float,
        default=0.0,
        help="Maximum depth shown (m). Set <= 0 for automatic range.",
    )
    parser.add_argument("--depth-steps", type=int, default=320, help="Number of depth samples.")
    parser.add_argument(
        "--disparity-precision-px",
        type=float,
        default=1.0,
        help="Disparity estimation precision (px). 1.0 means integer-pixel precision.",
    )
    parser.add_argument(
        "--min-disparity-px",
        type=float,
        default=1.0,
        help="Minimum measurable disparity (px), controls max measurable depth.",
    )
    parser.add_argument(
        "--max-disparity-px",
        type=float,
        default=0.0,
        help="Maximum measurable disparity (px), controls nearest measurable depth. "
        "Set <= 0 to auto-use image_width_px - 1.",
    )
    parser.add_argument(
        "--target-depths-m",
        type=str,
        default="1,2,5,10",
        help="Comma-separated target depths for line plots (meters).",
    )
    parser.add_argument(
        "--disparity-baselines-cm",
        type=str,
        default="",
        help="Optional comma-separated baselines (cm) for disparity-vs-distance curves. "
        "If empty, representative sweep baselines are used.",
    )
    parser.add_argument(
        "--disparity-log-y",
        action="store_true",
        help="Use logarithmic Y axis for disparity-vs-distance plot.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("output"),
        help="Directory where plots and CSV are saved.",
    )
    parser.add_argument("--show", action="store_true", help="Show figures interactively.")
    return parser


def main() -> None:
    args = build_parser().parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)

    f_px = focal_length_px(args.image_width_px, args.fov_deg)
    baselines_m = np.linspace(args.baseline_min_cm, args.baseline_max_cm, args.baseline_steps) / 100.0

    max_disparity_px = args.max_disparity_px if args.max_disparity_px > 0.0 else (args.image_width_px - 1.0)
    min_depths_m = (f_px * baselines_m) / max_disparity_px
    max_depths_m = (f_px * baselines_m) / args.min_disparity_px

    auto_depth_max = float(np.max(max_depths_m) * 1.05)
    depth_max_m = args.depth_max_m if args.depth_max_m > 0.0 else auto_depth_max
    depths_m = np.linspace(args.depth_min_m, depth_max_m, args.depth_steps)

    b_grid, z_grid = np.meshgrid(baselines_m, depths_m)
    disparity_grid = (f_px * b_grid) / z_grid

    valid = (disparity_grid >= args.min_disparity_px) & (disparity_grid <= max_disparity_px)
    dz_grid = (z_grid**2 / (f_px * b_grid)) * args.disparity_precision_px
    dz_grid = np.where(valid, dz_grid, np.nan)
    rel_err_grid = np.where(valid, dz_grid / z_grid, np.nan)

    target_depths = parse_float_list(args.target_depths_m)
    target_depths = target_depths[target_depths > 0.0]
    target_depth_errors = []
    for z in target_depths:
        dz_at_z = (z**2 / (f_px * baselines_m)) * args.disparity_precision_px
        d_at_z = (f_px * baselines_m) / z
        dz_at_z[(d_at_z < args.min_disparity_px) | (d_at_z > max_disparity_px)] = np.nan
        target_depth_errors.append(dz_at_z)
    target_depth_errors = np.array(target_depth_errors, dtype=float)
    baselines_cm = baselines_m * 100.0

    disparity_curve_baselines_cm = parse_float_list(args.disparity_baselines_cm)
    if disparity_curve_baselines_cm.size == 0:
        disparity_curve_baselines_cm = representative_baselines_cm(baselines_cm, count=5)
    disparity_curve_baselines_m = disparity_curve_baselines_cm / 100.0

    summary_csv_path = args.output_dir / "baseline_depth_summary.csv"
    table = np.column_stack([baselines_cm, min_depths_m, max_depths_m])
    np.savetxt(
        summary_csv_path,
        table,
        delimiter=",",
        header="baseline_cm,min_depth_m,max_depth_m",
        comments="",
    )

    fig, axes = plt.subplots(1, 3, figsize=(18, 5))

    axes[0].plot(baselines_m * 100.0, max_depths_m, label="max measurable depth")
    axes[0].plot(baselines_m * 100.0, min_depths_m, label="min measurable depth")
    axes[0].set_title("Depth Range vs Baseline")
    axes[0].set_xlabel("Baseline (cm)")
    axes[0].set_ylabel("Depth (m)")
    axes[0].grid(True, alpha=0.3)
    axes[0].legend()

    im = axes[1].imshow(
        dz_grid,
        origin="lower",
        aspect="auto",
        extent=[args.baseline_min_cm, args.baseline_max_cm, args.depth_min_m, depth_max_m],
        cmap="viridis",
    )
    axes[1].set_title("Depth Resolution (absolute error, m)")
    axes[1].set_xlabel("Baseline (cm)")
    axes[1].set_ylabel("Depth (m)")
    fig.colorbar(im, ax=axes[1], label="Depth error per disparity step (m)")

    im_rel = axes[2].imshow(
        100.0 * rel_err_grid,
        origin="lower",
        aspect="auto",
        extent=[args.baseline_min_cm, args.baseline_max_cm, args.depth_min_m, depth_max_m],
        cmap="magma",
    )
    axes[2].set_title("Depth Resolution (relative error, %)")
    axes[2].set_xlabel("Baseline (cm)")
    axes[2].set_ylabel("Depth (m)")
    fig.colorbar(im_rel, ax=axes[2], label="Relative depth error (%)")

    fig.suptitle(
        "Stereo depth capability | FOV={:.1f} deg, width={} px, f={:.1f} px".format(
            args.fov_deg, int(args.image_width_px), f_px
        )
    )
    fig.tight_layout()
    combined_plot_path = args.output_dir / "depth_capability_vs_baseline.png"
    fig.savefig(combined_plot_path, dpi=180)

    fig2, ax2 = plt.subplots(figsize=(8, 5))
    for idx, z in enumerate(target_depths):
        ax2.plot(baselines_m * 100.0, target_depth_errors[idx], label=f"{z:g} m target")
    ax2.set_title("Depth Error at Fixed Distances")
    ax2.set_xlabel("Baseline (cm)")
    ax2.set_ylabel("Depth error per disparity step (m)")
    ax2.grid(True, alpha=0.3)
    if len(target_depths) > 0:
        ax2.legend()
    fig2.tight_layout()
    target_plot_path = args.output_dir / "depth_error_at_target_distances.png"
    fig2.savefig(target_plot_path, dpi=180)

    fig3, ax3 = plt.subplots(figsize=(8, 5))
    plotted_disparity_values = []
    for baseline_cm, baseline_m in zip(disparity_curve_baselines_cm, disparity_curve_baselines_m):
        d_curve = (f_px * baseline_m) / depths_m
        d_curve[(d_curve < args.min_disparity_px) | (d_curve > max_disparity_px)] = np.nan
        finite_vals = d_curve[np.isfinite(d_curve)]
        if finite_vals.size > 0:
            plotted_disparity_values.append(finite_vals)
        ax3.plot(depths_m, d_curve, label=f"{baseline_cm:g} cm baseline")
    ax3.axhline(args.min_disparity_px, color="gray", linestyle="--", linewidth=1, label="min disparity limit")
    ax3.set_title("Disparity vs Distance" + (" (log Y)" if args.disparity_log_y else ""))
    ax3.set_xlabel("Distance / depth (m)")
    ax3.set_ylabel("Disparity (pixels)")
    if args.disparity_log_y:
        ax3.set_yscale("log")

    if plotted_disparity_values:
        all_plotted = np.concatenate(plotted_disparity_values)
        y_min = max(args.min_disparity_px * 0.9, float(np.nanmin(all_plotted)) * 0.9)
        y_max = float(np.nanmax(all_plotted)) * 1.1
        ax3.set_ylim(y_min, y_max)

    ax3.grid(True, alpha=0.3)
    ax3.legend()
    fig3.tight_layout()
    disparity_plot_path = args.output_dir / "disparity_vs_distance.png"
    fig3.savefig(disparity_plot_path, dpi=180)

    print("Camera model:")
    print(f"  FOV: {args.fov_deg:.2f} deg")
    print(f"  Width: {args.image_width_px:.0f} px")
    print(f"  Focal length: {f_px:.3f} px")
    print(f"  Baseline sweep: {args.baseline_min_cm:.2f} to {args.baseline_max_cm:.2f} cm")
    print(f"  Measurable disparity range: [{args.min_disparity_px:.2f}, {max_disparity_px:.2f}] px")
    print()
    print("Outputs:")
    print(f"  {summary_csv_path}")
    print(f"  {combined_plot_path}")
    print(f"  {target_plot_path}")
    print(f"  {disparity_plot_path}")

    if args.show:
        plt.show()
    else:
        plt.close("all")


if __name__ == "__main__":
    main()
