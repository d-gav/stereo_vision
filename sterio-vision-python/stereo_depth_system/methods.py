from __future__ import annotations

from typing import Callable, Dict

import cv2
import numpy as np

from .config import StereoConfig


DisparityFn = Callable[[np.ndarray, np.ndarray, StereoConfig], np.ndarray]


def compute_bm(left: np.ndarray, right: np.ndarray, cfg: StereoConfig) -> np.ndarray:
    num_disp = _normalize_num_disparities(cfg.bm_num_disparities)
    block_size = _normalize_odd(cfg.bm_block_size, min_value=5)

    matcher = cv2.StereoBM_create(numDisparities=num_disp, blockSize=block_size)
    disp = matcher.compute(left, right).astype(np.float32) / 16.0
    disp[disp < 0] = np.nan
    return disp


def compute_sgbm(left: np.ndarray, right: np.ndarray, cfg: StereoConfig) -> np.ndarray:
    num_disp = _normalize_num_disparities(cfg.sgbm_num_disparities)
    block_size = _normalize_odd(cfg.sgbm_block_size, min_value=3)
    channels = 1

    matcher = cv2.StereoSGBM_create(
        minDisparity=0,
        numDisparities=num_disp,
        blockSize=block_size,
        P1=8 * channels * (block_size**2),
        P2=32 * channels * (block_size**2),
        disp12MaxDiff=1,
        uniquenessRatio=10,
        speckleWindowSize=50,
        speckleRange=2,
        preFilterCap=31,
        mode=cv2.STEREO_SGBM_MODE_SGBM_3WAY,
    )

    disp = matcher.compute(left, right).astype(np.float32) / 16.0
    disp[disp < 0] = np.nan
    return disp


def compute_sad(left: np.ndarray, right: np.ndarray, cfg: StereoConfig) -> np.ndarray:
    max_disp = max(1, int(cfg.sad_max_disparity))
    win = _normalize_odd(cfg.sad_window_size, min_value=3)
    half = win // 2

    left_f = left.astype(np.float32)
    right_f = right.astype(np.float32)
    h, w = left.shape
    disparity = np.full((h, w), np.nan, dtype=np.float32)

    if w <= max_disp + 2 * half or h <= 2 * half:
        return disparity

    for y in range(half, h - half):
        for x in range(half + max_disp, w - half):
            left_patch = left_f[y - half : y + half + 1, x - half : x + half + 1]
            best_cost = np.inf
            best_d = 0

            for d in range(0, max_disp + 1):
                xr = x - d
                if xr - half < 0:
                    break

                right_patch = right_f[y - half : y + half + 1, xr - half : xr + half + 1]
                cost = np.abs(left_patch - right_patch).sum()
                if cost < best_cost:
                    best_cost = cost
                    best_d = d

            disparity[y, x] = float(best_d)

    return disparity


def get_methods() -> Dict[str, DisparityFn]:
    return {
        "bm": compute_bm,
        "sgbm": compute_sgbm,
        "sad": compute_sad,
    }


def _normalize_num_disparities(value: int) -> int:
    v = max(16, int(value))
    if v % 16 != 0:
        v = ((v // 16) + 1) * 16
    return v


def _normalize_odd(value: int, min_value: int) -> int:
    v = max(min_value, int(value))
    if v % 2 == 0:
        v += 1
    return v

