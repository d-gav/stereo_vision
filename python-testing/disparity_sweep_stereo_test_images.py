import json
from pathlib import Path

import cv2
import numpy as np


INPUT_IMAGES = [
    Path("stero-vision-test-images") / "vga_capture_19700101_003350_003.png",
    Path("stero-vision-test-images") / "vga_capture_19700101_003402_004.png",
]

OUTPUT_DIR = Path("python-testing") / "stereo-disparity-sweeps"

# StereoBM settings sweep.
WINDOW_SIZES = [5, 9, 13, 17, 21]
MAX_SHIFTS = [16, 32, 48, 64, 80, 96]

# Active image region in full NTSC captures.
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


def split_stereo_halves(crop_bgr: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    h, w = crop_bgr.shape[:2]
    if w != 320 or h != 240:
        raise ValueError(f"Expected 320x240 crop, got {w}x{h}")

    left = crop_bgr[:, :160]
    right = crop_bgr[:, 160:]
    return left, right


def compute_bm_disparity(
    left_gray: np.ndarray,
    right_gray: np.ndarray,
    block_size: int,
    max_shift: int,
) -> np.ndarray:
    num_disparities = max(16, ((max_shift + 15) // 16) * 16)

    bm = cv2.StereoBM_create(numDisparities=num_disparities, blockSize=block_size)
    bm.setPreFilterType(cv2.STEREO_BM_PREFILTER_XSOBEL)
    bm.setPreFilterSize(9)
    bm.setPreFilterCap(31)
    bm.setTextureThreshold(10)
    bm.setUniquenessRatio(8)
    bm.setSpeckleWindowSize(100)
    bm.setSpeckleRange(16)
    bm.setDisp12MaxDiff(1)

    disparity = bm.compute(left_gray, right_gray).astype(np.float32) / 16.0
    return disparity


def disparity_to_colormap(disparity: np.ndarray, max_shift: int) -> np.ndarray:
    clipped = np.clip(disparity, 0.0, float(max_shift))
    disp_u8 = (clipped * (255.0 / float(max_shift))).astype(np.uint8)
    return cv2.applyColorMap(disp_u8, cv2.COLORMAP_TURBO)


def add_title_bar(image_bgr: np.ndarray, title: str) -> np.ndarray:
    title_h = 26
    h, w = image_bgr.shape[:2]
    out = np.zeros((h + title_h, w, 3), dtype=np.uint8)
    out[:title_h, :] = (20, 20, 20)
    out[title_h:, :] = image_bgr
    cv2.putText(
        out,
        title,
        (6, 18),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.45,
        (235, 235, 235),
        1,
        cv2.LINE_AA,
    )
    return out


def make_reference_strip(left_bgr: np.ndarray, right_bgr: np.ndarray) -> np.ndarray:
    pair = np.hstack([left_bgr, right_bgr])
    return add_title_bar(pair, "Reference: left (x=0..159) | right (x=160..319)")


def pad_to_width(image_bgr: np.ndarray, target_w: int) -> np.ndarray:
    h, w = image_bgr.shape[:2]
    if w == target_w:
        return image_bgr
    if w > target_w:
        return image_bgr[:, :target_w]

    out = np.zeros((h, target_w, 3), dtype=np.uint8)
    out[:, :w] = image_bgr
    return out


def make_grid(
    image_tag: str,
    left_bgr: np.ndarray,
    right_bgr: np.ndarray,
    left_gray: np.ndarray,
    right_gray: np.ndarray,
    out_dir: Path,
) -> tuple[np.ndarray, list[dict[str, float]]]:
    rows: list[np.ndarray] = []
    metrics: list[dict[str, float]] = []

    for max_shift in MAX_SHIFTS:
        tiles: list[np.ndarray] = []
        for block_size in WINDOW_SIZES:
            disparity = compute_bm_disparity(left_gray, right_gray, block_size=block_size, max_shift=max_shift)
            color = disparity_to_colormap(disparity, max_shift=max_shift)

            valid_mask = disparity > 0.0
            valid_ratio = float(np.mean(valid_mask))
            valid_values = disparity[valid_mask]
            median_disp = float(np.median(valid_values)) if valid_values.size > 0 else 0.0

            metrics.append(
                {
                    "image": image_tag,
                    "block_size": int(block_size),
                    "max_shift": int(max_shift),
                    "valid_ratio": valid_ratio,
                    "median_disparity": median_disp,
                }
            )

            title = (
                f"win={block_size}, max={max_shift}, "
                f"valid={valid_ratio:.2f}, med={median_disp:.1f}"
            )
            tile = add_title_bar(color, title)
            tiles.append(tile)

            indiv_name = f"{image_tag}_bm_win{block_size:02d}_max{max_shift:03d}.png"
            cv2.imwrite(str(out_dir / indiv_name), tile)

        row = np.hstack(tiles)
        row = add_title_bar(row, f"Row: max horizontal shift = {max_shift} px")
        rows.append(row)

    reference = make_reference_strip(left_bgr, right_bgr)
    row_width = rows[0].shape[1]
    reference = pad_to_width(reference, row_width)
    grid = np.vstack([reference] + rows)
    return grid, metrics


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    all_metrics: list[dict[str, float]] = []
    created_files: list[str] = []

    for image_path in INPUT_IMAGES:
        full = cv2.imread(str(image_path), cv2.IMREAD_COLOR)
        if full is None:
            raise FileNotFoundError(f"Could not read image: {image_path}")

        crop = ensure_active_crop(full)
        left_bgr, right_bgr = split_stereo_halves(crop)

        left_gray = cv2.cvtColor(left_bgr, cv2.COLOR_BGR2GRAY)
        right_gray = cv2.cvtColor(right_bgr, cv2.COLOR_BGR2GRAY)

        image_tag = image_path.stem
        grid, metrics = make_grid(
            image_tag=image_tag,
            left_bgr=left_bgr,
            right_bgr=right_bgr,
            left_gray=left_gray,
            right_gray=right_gray,
            out_dir=OUTPUT_DIR,
        )

        all_metrics.extend(metrics)

        grid_name = f"{image_tag}_bm_grid.png"
        grid_path = OUTPUT_DIR / grid_name
        cv2.imwrite(str(grid_path), grid)
        created_files.append(grid_name)

        crop_name = f"{image_tag}_active_crop.png"
        crop_path = OUTPUT_DIR / crop_name
        cv2.imwrite(str(crop_path), crop)
        created_files.append(crop_name)

    report = {
        "input_images": [str(p) for p in INPUT_IMAGES],
        "window_sizes": WINDOW_SIZES,
        "max_shifts": MAX_SHIFTS,
        "output_dir": str(OUTPUT_DIR),
        "results": all_metrics,
    }
    report_path = OUTPUT_DIR / "disparity_sweep_report.json"
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")

    print(f"Wrote report: {report_path}")
    print(f"Output directory: {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
