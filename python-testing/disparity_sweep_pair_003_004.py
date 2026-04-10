import json
from pathlib import Path

import cv2
import numpy as np


IMG_003 = Path("stero-vision-test-images") / "vga_capture_19700101_003350_003.png"
IMG_004 = Path("stero-vision-test-images") / "vga_capture_19700101_003402_004.png"
OUTPUT_DIR = Path("python-testing") / "stereo-disparity-sweeps-sad-pair-004-left-003-right-highdisp-highpass"

WINDOW_SIZES = [3, 5, 7, 9, 11, 13, 15, 17, 19, 21, 25, 29, 33]
MAX_SHIFTS = [64, 96, 128, 160, 192, 224]
HIGHPASS_SIGMA = 2.0

CROP_X = 100
CROP_Y = 50
CROP_W = 320
CROP_H = 240


def ensure_active_crop(frame_bgr: np.ndarray) -> np.ndarray:
    h, w = frame_bgr.shape[:2]
    if CROP_X + CROP_W <= w and CROP_Y + CROP_H <= h:
        return frame_bgr[CROP_Y : CROP_Y + CROP_H, CROP_X : CROP_X + CROP_W]
    if w == CROP_W and h == CROP_H:
        return frame_bgr
    raise ValueError(
        f"Unexpected frame size {w}x{h}; cannot apply active crop {CROP_W}x{CROP_H} at ({CROP_X}, {CROP_Y})"
    )


def highpass_preprocess(gray_u8: np.ndarray, sigma: float) -> np.ndarray:
    if sigma <= 0.0:
        raise ValueError(f"sigma must be > 0, got {sigma}")

    blur = cv2.GaussianBlur(
        gray_u8,
        ksize=(0, 0),
        sigmaX=sigma,
        sigmaY=sigma,
        borderType=cv2.BORDER_REPLICATE,
    )

    # High-pass by subtracting a low-pass image, then shift to unsigned range.
    hp = gray_u8.astype(np.int16) - blur.astype(np.int16)
    return np.clip(hp + 128, 0, 255).astype(np.uint8)


def build_sad_cost_volume(
    left_gray: np.ndarray,
    right_gray: np.ndarray,
    window_size: int,
    max_shift: int,
) -> np.ndarray:
    if window_size <= 0 or window_size % 2 == 0:
        raise ValueError(f"window_size must be odd and positive, got {window_size}")
    if max_shift < 0:
        raise ValueError(f"max_shift must be >= 0, got {max_shift}")

    h, w = left_gray.shape
    left_i16 = left_gray.astype(np.int16)
    right_i16 = right_gray.astype(np.int16)

    num_disp = max_shift + 1
    volume = np.empty((num_disp, h, w), dtype=np.float32)
    large_cost = np.float32(1e12)

    for d in range(num_disp):
        diff = np.full((h, w), 255.0, dtype=np.float32)
        if d == 0:
            diff = np.abs(left_i16 - right_i16).astype(np.float32)
        else:
            diff[:, d:] = np.abs(left_i16[:, d:] - right_i16[:, : w - d]).astype(np.float32)

        cost = cv2.boxFilter(
            diff,
            ddepth=-1,
            ksize=(window_size, window_size),
            normalize=False,
            borderType=cv2.BORDER_REPLICATE,
        )
        if d > 0:
            cost[:, :d] = large_cost

        volume[d] = cost

    return volume


def disparity_sad_from_cost_volume(cost_volume: np.ndarray, max_shift: int, window_size: int) -> np.ndarray:
    h, w = cost_volume.shape[1:]
    disparity = np.argmin(cost_volume[: max_shift + 1], axis=0).astype(np.float32)

    # Avoid unstable borders where the matching window spills outside image support.
    r = window_size // 2
    if r > 0:
        disparity[:r, :] = 0.0
        disparity[h - r :, :] = 0.0
        disparity[:, :r] = 0.0
        disparity[:, w - r :] = 0.0

    return disparity


def disparity_to_color(disparity: np.ndarray, max_shift: int) -> np.ndarray:
    clipped = np.clip(disparity, 0.0, float(max_shift))
    u8 = (clipped * (255.0 / float(max_shift))).astype(np.uint8)
    return cv2.applyColorMap(u8, cv2.COLORMAP_TURBO)


def add_bar(image_bgr: np.ndarray, title: str) -> np.ndarray:
    bar_h = 28
    h, w = image_bgr.shape[:2]
    out = np.zeros((h + bar_h, w, 3), dtype=np.uint8)
    out[:bar_h, :] = (20, 20, 20)
    out[bar_h:, :] = image_bgr
    cv2.putText(out, title, (6, 19), cv2.FONT_HERSHEY_SIMPLEX, 0.47, (235, 235, 235), 1, cv2.LINE_AA)
    return out


def make_grid(label: str, left_bgr: np.ndarray, right_bgr: np.ndarray, out_dir: Path) -> tuple[np.ndarray, list[dict[str, float]]]:
    left_gray_raw = cv2.cvtColor(left_bgr, cv2.COLOR_BGR2GRAY)
    right_gray_raw = cv2.cvtColor(right_bgr, cv2.COLOR_BGR2GRAY)

    left_gray = highpass_preprocess(left_gray_raw, sigma=HIGHPASS_SIGMA)
    right_gray = highpass_preprocess(right_gray_raw, sigma=HIGHPASS_SIGMA)

    cv2.imwrite(str(out_dir / f"{label}_left_highpass.png"), left_gray)
    cv2.imwrite(str(out_dir / f"{label}_right_highpass.png"), right_gray)

    metrics: list[dict[str, float]] = []
    rows: list[np.ndarray] = []

    max_shift_global = int(max(MAX_SHIFTS))
    disparity_by_window_and_shift: dict[int, dict[int, np.ndarray]] = {}

    for block_size in WINDOW_SIZES:
        volume = build_sad_cost_volume(
            left_gray=left_gray,
            right_gray=right_gray,
            window_size=block_size,
            max_shift=max_shift_global,
        )
        disparity_by_window_and_shift[block_size] = {}
        for max_shift in MAX_SHIFTS:
            disparity_by_window_and_shift[block_size][max_shift] = disparity_sad_from_cost_volume(
                cost_volume=volume,
                max_shift=max_shift,
                window_size=block_size,
            )

    for max_shift in MAX_SHIFTS:
        tiles: list[np.ndarray] = []
        for block_size in WINDOW_SIZES:
            disparity = disparity_by_window_and_shift[block_size][max_shift]
            color = disparity_to_color(disparity, max_shift=max_shift)

            valid = disparity > 0.0
            valid_ratio = float(np.mean(valid))
            vals = disparity[valid]
            median_disp = float(np.median(vals)) if vals.size > 0 else 0.0

            metrics.append(
                {
                    "pair_direction": label,
                    "block_size": int(block_size),
                    "max_shift": int(max_shift),
                    "valid_ratio": valid_ratio,
                    "median_disparity": median_disp,
                }
            )

            title = f"win={block_size}, max={max_shift}, valid={valid_ratio:.2f}, med={median_disp:.1f}"
            tile = add_bar(color, title)
            tiles.append(tile)

            indiv = out_dir / f"{label}_sad_win{block_size:02d}_max{max_shift:03d}.png"
            cv2.imwrite(str(indiv), tile)

        row = np.hstack(tiles)
        rows.append(add_bar(row, f"Row: max horizontal shift = {max_shift} px"))

    ref = np.hstack([left_bgr, right_bgr])
    ref = add_bar(ref, f"Reference pair: {label}")

    target_w = rows[0].shape[1]
    if ref.shape[1] < target_w:
        padded = np.zeros((ref.shape[0], target_w, 3), dtype=np.uint8)
        padded[:, : ref.shape[1]] = ref
        ref = padded

    grid = np.vstack([ref] + rows)
    return grid, metrics


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    frame_003 = cv2.imread(str(IMG_003), cv2.IMREAD_COLOR)
    frame_004 = cv2.imread(str(IMG_004), cv2.IMREAD_COLOR)
    if frame_003 is None or frame_004 is None:
        raise FileNotFoundError("Could not load one or both input images")

    crop_003 = ensure_active_crop(frame_003)
    crop_004 = ensure_active_crop(frame_004)

    cv2.imwrite(str(OUTPUT_DIR / f"{IMG_003.stem}_active_crop.png"), crop_003)
    cv2.imwrite(str(OUTPUT_DIR / f"{IMG_004.stem}_active_crop.png"), crop_004)

    all_metrics: list[dict[str, float]] = []

    grid_004_003, m_004_003 = make_grid("img004_left_img003_right", crop_004, crop_003, OUTPUT_DIR)
    cv2.imwrite(str(OUTPUT_DIR / "pair_img004_left_img003_right_grid.png"), grid_004_003)
    all_metrics.extend(m_004_003)

    report = {
        "images": [str(IMG_004), str(IMG_003)],
        "window_sizes": WINDOW_SIZES,
        "max_shifts": MAX_SHIFTS,
        "matcher": "SAD (sum of absolute differences)",
        "preprocessing": {
            "type": "highpass (gray - gaussian_blur + 128)",
            "gaussian_sigma": HIGHPASS_SIGMA,
        },
        "output_dir": str(OUTPUT_DIR),
        "results": all_metrics,
    }
    report_path = OUTPUT_DIR / "pair_disparity_sweep_report.json"
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")

    print(f"Wrote report: {report_path}")
    print(f"Output directory: {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
