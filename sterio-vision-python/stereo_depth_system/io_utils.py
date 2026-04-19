from pathlib import Path
from typing import List, Tuple

import cv2
import numpy as np


StereoPair = Tuple[str, Path, Path]


def find_stereo_pairs(input_dir: Path) -> List[StereoPair]:
    left_files = sorted(input_dir.glob("*_left.png"))
    pairs: List[StereoPair] = []

    for left_path in left_files:
        stem = left_path.stem
        base_name = stem[: -len("_left")]
        right_path = input_dir / f"{base_name}_right.png"
        if right_path.exists():
            pairs.append((base_name, left_path, right_path))

    return pairs


def load_grayscale(path: Path) -> np.ndarray:
    image = cv2.imread(str(path), cv2.IMREAD_GRAYSCALE)
    if image is None:
        raise ValueError(f"Failed to load image: {path}")
    return image


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def save_float_map(path: Path, array: np.ndarray) -> None:
    np.save(str(path), array)


def save_preview_png(path: Path, array: np.ndarray) -> None:
    preview = normalize_for_display(array)
    cv2.imwrite(str(path), preview)


def normalize_for_display(array: np.ndarray) -> np.ndarray:
    arr = np.array(array, dtype=np.float32)
    finite = np.isfinite(arr)
    if not np.any(finite):
        return np.zeros(arr.shape, dtype=np.uint8)

    values = arr[finite]
    lo = np.percentile(values, 2)
    hi = np.percentile(values, 98)
    if hi <= lo:
        hi = lo + 1.0

    clipped = np.clip(arr, lo, hi)
    normalized = ((clipped - lo) / (hi - lo) * 255.0).astype(np.uint8)
    normalized[~finite] = 0
    return normalized

