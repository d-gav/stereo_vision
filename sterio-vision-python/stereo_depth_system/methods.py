from __future__ import annotations

from typing import Callable, Dict, Literal, Tuple

import cv2
import numpy as np

from .config import StereoConfig


DisparityFn = Callable[[np.ndarray, np.ndarray, StereoConfig], np.ndarray]
POPCOUNT_LUT = np.array([bin(i).count("1") for i in range(256)], dtype=np.uint8)


def compute_bm(left: np.ndarray, right: np.ndarray, cfg: StereoConfig) -> np.ndarray:
    num_disp = _normalize_num_disparities(cfg.bm_num_disparities)
    block_size = _normalize_odd(cfg.bm_block_size, min_value=5)
    min_disp = max(0, int(cfg.min_disparity))

    matcher = cv2.StereoBM_create(numDisparities=num_disp, blockSize=block_size)
    disp = matcher.compute(left, right).astype(np.float32) / 16.0
    disp[disp < min_disp] = np.nan
    return disp


def compute_sgbm(left: np.ndarray, right: np.ndarray, cfg: StereoConfig) -> np.ndarray:
    num_disp = _normalize_num_disparities(cfg.sgbm_num_disparities)
    block_size = _normalize_odd(cfg.sgbm_block_size, min_value=3)
    min_disp = max(0, int(cfg.min_disparity))
    channels = 1

    matcher = cv2.StereoSGBM_create(
        minDisparity=min_disp,
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
    disp[disp < min_disp] = np.nan
    return disp


def compute_sad_custom(
    left: np.ndarray,
    right: np.ndarray,
    max_disparity: int,
    window_width: int,
    window_height: int,
    min_disparity: int,
    cost_mode: Literal["l1", "l2"],
) -> np.ndarray:
    max_disp = max(1, int(max_disparity))
    min_disp = max(0, int(min_disparity))
    if min_disp > max_disp:
        min_disp = max_disp
    win_w = _normalize_odd(window_width, min_value=3)
    win_h = _normalize_odd(window_height, min_value=3)
    half_w = win_w // 2
    half_h = win_h // 2

    left_f = left.astype(np.float32)
    right_f = right.astype(np.float32)
    h, w = left.shape
    disparity = np.full((h, w), np.nan, dtype=np.float32)

    if w <= max_disp + 2 * half_w or h <= 2 * half_h:
        return disparity

    best_cost = np.full((h, w), np.inf, dtype=np.float32)
    best_disp = np.zeros((h, w), dtype=np.float32)

    # Use C-optimized filtering for window aggregation, and only loop over disparity.
    for d in range(min_disp, max_disp + 1):
        shifted = np.zeros_like(right_f)
        if d == 0:
            shifted[:, :] = right_f
        else:
            shifted[:, d:] = right_f[:, : w - d]

        diff = left_f - shifted
        if cost_mode == "l2":
            pixel_cost = diff * diff
        else:
            pixel_cost = np.abs(diff)

        agg_cost = cv2.boxFilter(
            pixel_cost,
            ddepth=-1,
            ksize=(win_w, win_h),
            normalize=False,
            borderType=cv2.BORDER_REPLICATE,
        )

        # Force invalid regions to +inf for this disparity.
        if d + half_w > 0:
            agg_cost[:, : d + half_w] = np.inf
        if half_w > 0:
            agg_cost[:, w - half_w :] = np.inf
        if half_h > 0:
            agg_cost[:half_h, :] = np.inf
            agg_cost[h - half_h :, :] = np.inf

        improve = agg_cost < best_cost
        best_cost[improve] = agg_cost[improve]
        best_disp[improve] = float(d)

    valid = np.isfinite(best_cost)
    disparity[valid] = best_disp[valid]

    return disparity


def compute_sad_l1(left: np.ndarray, right: np.ndarray, cfg: StereoConfig) -> np.ndarray:
    widths = cfg.sad_window_widths or cfg.sad_window_sizes
    heights = cfg.sad_window_heights or cfg.sad_window_sizes
    return compute_sad_custom(
        left,
        right,
        max_disparity=cfg.sad_max_disparities[0],
        window_width=widths[0],
        window_height=heights[0],
        min_disparity=0,
        cost_mode="l1",
    )


def compute_sad_l2(left: np.ndarray, right: np.ndarray, cfg: StereoConfig) -> np.ndarray:
    widths = cfg.sad_window_widths or cfg.sad_window_sizes
    heights = cfg.sad_window_heights or cfg.sad_window_sizes
    return compute_sad_custom(
        left,
        right,
        max_disparity=cfg.sad_max_disparities[0],
        window_width=widths[0],
        window_height=heights[0],
        min_disparity=0,
        cost_mode="l2",
    )


def compute_sad_custom_vshift(
    left: np.ndarray,
    right: np.ndarray,
    max_disparity: int,
    window_width: int,
    window_height: int,
    min_disparity: int,
    max_vertical_shift: int,
    cost_mode: Literal["l1", "l2"],
) -> Tuple[np.ndarray, np.ndarray]:
    """Windowed SAD with an additional vertical search range.

    For each horizontal disparity d in [0, max_disparity] and each vertical shift
    vy in [-V, +V] (V = max_vertical_shift), shift the right image by (vy rows, d cols),
    compute aggregated L1 or L2 block cost, and keep the (d, vy) pair with the
    smallest cost per pixel. Useful when rectification is imperfect (e.g. residual
    fisheye tilt) so epipolar lines are not perfectly horizontal.

    Returns (disparity, vshift_map); both have NaN where no valid match was found.
    """
    max_disp = max(1, int(max_disparity))
    min_disp = max(0, int(min_disparity))
    if min_disp > max_disp:
        min_disp = max_disp
    win_w = _normalize_odd(window_width, min_value=3)
    win_h = _normalize_odd(window_height, min_value=3)
    half_w = win_w // 2
    half_h = win_h // 2
    vmax = max(0, int(max_vertical_shift))

    left_f = left.astype(np.float32)
    right_f = right.astype(np.float32)
    h, w = left.shape
    disparity = np.full((h, w), np.nan, dtype=np.float32)
    vshift_map = np.full((h, w), np.nan, dtype=np.float32)

    if w <= max_disp + 2 * half_w or h <= 2 * half_h + 2 * vmax:
        return disparity, vshift_map

    best_cost = np.full((h, w), np.inf, dtype=np.float32)
    best_disp = np.zeros((h, w), dtype=np.float32)
    best_vy = np.zeros((h, w), dtype=np.float32)

    for vy in range(-vmax, vmax + 1):
        shifted_v = _shift_image_vertical(right_f, vy)

        for d in range(min_disp, max_disp + 1):
            shifted = np.zeros_like(right_f)
            if d == 0:
                shifted[:, :] = shifted_v
            else:
                shifted[:, d:] = shifted_v[:, : w - d]

            diff = left_f - shifted
            if cost_mode == "l2":
                pixel_cost = diff * diff
            else:
                pixel_cost = np.abs(diff)

            agg_cost = cv2.boxFilter(
                pixel_cost,
                ddepth=-1,
                ksize=(win_w, win_h),
                normalize=False,
                borderType=cv2.BORDER_REPLICATE,
            )

            if d + half_w > 0:
                agg_cost[:, : d + half_w] = np.inf
            if half_w > 0:
                agg_cost[:, w - half_w :] = np.inf
            top_invalid = half_h + max(0, vy)
            bot_invalid = half_h + max(0, -vy)
            if top_invalid > 0:
                agg_cost[:top_invalid, :] = np.inf
            if bot_invalid > 0:
                agg_cost[h - bot_invalid :, :] = np.inf

            improve = agg_cost < best_cost
            best_cost[improve] = agg_cost[improve]
            best_disp[improve] = float(d)
            best_vy[improve] = float(vy)

    valid = np.isfinite(best_cost)
    disparity[valid] = best_disp[valid]
    vshift_map[valid] = best_vy[valid]
    return disparity, vshift_map


def compute_sgbm_vshift(
    left: np.ndarray,
    right: np.ndarray,
    num_disparities: int,
    block_size: int,
    max_vertical_shift: int,
    min_disparity: int = 0,
    validation_window: int = 7,
    validation_height_scale: int = 1,
) -> Tuple[np.ndarray, np.ndarray]:
    """Run SGBM at multiple vertical offsets of the right image and pick the best per pixel.

    For each vy in [-V, +V] the right image is shifted by vy rows (down for vy>0,
    up for vy<0) and OpenCV StereoSGBM is run. A per-pixel validation cost
    (windowed L1 between the left image and the right image warped by the SGBM
    disparity at that vy) selects the vertical offset that best explains each
    pixel. Pixels where no SGBM offset produced a valid disparity are left NaN.

    Returns (disparity, vshift_map).
    """
    num_disp = _normalize_num_disparities(num_disparities)
    min_disp = max(0, int(min_disparity))
    bs = _normalize_odd(block_size, min_value=3)
    vmax = max(0, int(max_vertical_shift))
    val_win = _normalize_odd(validation_window, min_value=3)
    val_scale = max(1, int(validation_height_scale))
    val_win_h = _normalize_odd(val_win * val_scale, min_value=3)
    channels = 1

    h, w = left.shape
    left_f = left.astype(np.float32)
    best_cost = np.full((h, w), np.inf, dtype=np.float32)
    best_disp = np.full((h, w), np.nan, dtype=np.float32)
    best_vy = np.full((h, w), np.nan, dtype=np.float32)

    xs_row = np.arange(w, dtype=np.int32)
    xs_grid = np.broadcast_to(xs_row, (h, w))
    ys_grid = np.broadcast_to(np.arange(h, dtype=np.int32).reshape(-1, 1), (h, w))

    for vy in range(-vmax, vmax + 1):
        right_shifted = _shift_image_vertical(right, vy).astype(right.dtype)

        matcher = cv2.StereoSGBM_create(
            minDisparity=min_disp,
            numDisparities=num_disp,
            blockSize=bs,
            P1=8 * channels * (bs**2),
            P2=32 * channels * (bs**2),
            disp12MaxDiff=1,
            uniquenessRatio=10,
            speckleWindowSize=50,
            speckleRange=2,
            preFilterCap=31,
            mode=cv2.STEREO_SGBM_MODE_SGBM_3WAY,
        )
        disp_raw = matcher.compute(left, right_shifted).astype(np.float32) / 16.0
        valid_sgbm = disp_raw >= min_disp

        right_shifted_f = right_shifted.astype(np.float32)
        src_x = xs_grid.astype(np.float32) - disp_raw
        src_x_int = np.clip(np.round(src_x).astype(np.int32), 0, w - 1)
        sampled = right_shifted_f[ys_grid, src_x_int]
        pixel_cost = np.abs(left_f - sampled)

        cost = cv2.boxFilter(
            pixel_cost,
            ddepth=-1,
            ksize=(val_win, val_win_h),
            normalize=False,
            borderType=cv2.BORDER_REPLICATE,
        )

        top_invalid = max(0, vy)
        bot_invalid = max(0, -vy)
        if top_invalid > 0:
            cost[:top_invalid, :] = np.inf
        if bot_invalid > 0:
            cost[h - bot_invalid :, :] = np.inf
        cost[~valid_sgbm] = np.inf

        improve = cost < best_cost
        best_cost[improve] = cost[improve]
        best_disp[improve] = disp_raw[improve]
        best_vy[improve] = float(vy)

    invalid = ~np.isfinite(best_cost)
    best_disp[invalid] = np.nan
    best_vy[invalid] = np.nan
    return best_disp, best_vy


def _shift_image_vertical(image: np.ndarray, vy: int) -> np.ndarray:
    """Shift image vertically by vy rows. Positive vy shifts DOWN (new rows at top are 0).
    Negative vy shifts UP (new rows at bottom are 0). Exposed for tests / debug viz.
    """
    h = image.shape[0]
    out = np.zeros_like(image)
    if vy == 0:
        out[:] = image
    elif vy > 0:
        v = min(vy, h)
        out[v:, ...] = image[: h - v, ...]
    else:
        v = min(-vy, h)
        out[: h - v, ...] = image[v:, ...]
    return out


def render_vshift_preview(vshift_map: np.ndarray, vmax: int) -> np.ndarray:
    """Color-code a vertical-shift map: blue = shift up, green = zero, red = shift down."""
    h, w = vshift_map.shape
    img = np.full((h, w, 3), 40, dtype=np.uint8)
    valid = np.isfinite(vshift_map)
    if not np.any(valid) or vmax <= 0:
        img[valid] = (80, 160, 80)
        return img

    norm = np.clip(vshift_map, -vmax, vmax) / float(vmax)
    neg = norm < 0
    pos = norm > 0
    zero = norm == 0

    abs_norm = np.abs(norm)
    mag = np.clip(abs_norm, 0.0, 1.0)

    img[valid & zero] = (80, 200, 80)

    neg_mask = valid & neg
    if np.any(neg_mask):
        m = mag[neg_mask]
        img[neg_mask] = np.stack([
            (80 + 175 * m).astype(np.uint8),
            (160 * (1 - m) + 80 * m).astype(np.uint8),
            (80 * (1 - m)).astype(np.uint8),
        ], axis=-1)

    pos_mask = valid & pos
    if np.any(pos_mask):
        m = mag[pos_mask]
        img[pos_mask] = np.stack([
            (80 * (1 - m)).astype(np.uint8),
            (160 * (1 - m) + 80 * m).astype(np.uint8),
            (80 + 175 * m).astype(np.uint8),
        ], axis=-1)

    return img


def compute_census_hamming_custom(
    left: np.ndarray,
    right: np.ndarray,
    max_disparity: int,
    census_window: int,
    aggregation_window: int,
    min_disparity: int = 0,
    left_desc: np.ndarray | None = None,
    right_desc: np.ndarray | None = None,
) -> np.ndarray:
    max_disp = max(1, int(max_disparity))
    min_disp = max(0, int(min_disparity))
    if min_disp > max_disp:
        min_disp = max_disp
    census_win = _normalize_odd(census_window, min_value=3)
    agg_win = _normalize_odd(aggregation_window, min_value=1)
    census_half = census_win // 2
    agg_half = agg_win // 2

    h, w = left.shape
    disparity = np.full((h, w), np.nan, dtype=np.float32)
    if w <= max_disp + 2 * census_half or h <= 2 * census_half:
        return disparity

    if left_desc is None:
        left_desc = _census_transform_bytes(left, census_win)
    if right_desc is None:
        right_desc = _census_transform_bytes(right, census_win)

    best_cost = np.full((h, w), np.inf, dtype=np.float32)
    best_disp = np.zeros((h, w), dtype=np.float32)

    for d in range(min_disp, max_disp + 1):
        shifted = np.zeros_like(right_desc)
        if d == 0:
            shifted[:, :] = right_desc
        else:
            shifted[:, d:] = right_desc[:, : w - d]

        xor = np.bitwise_xor(left_desc, shifted)
        cost = _popcount_bytes(xor).astype(np.float32)

        if agg_win > 1:
            cost = cv2.boxFilter(
                cost,
                ddepth=-1,
                ksize=(agg_win, agg_win),
                normalize=False,
                borderType=cv2.BORDER_REPLICATE,
            )

        invalid_left = d + census_half + agg_half
        if invalid_left > 0:
            cost[:, :invalid_left] = np.inf

        invalid_right = census_half + agg_half
        if invalid_right > 0:
            cost[:, w - invalid_right :] = np.inf
            cost[:invalid_right, :] = np.inf
            cost[h - invalid_right :, :] = np.inf

        improve = cost < best_cost
        best_cost[improve] = cost[improve]
        best_disp[improve] = float(d)

    valid = np.isfinite(best_cost)
    disparity[valid] = best_disp[valid]
    return disparity


def compute_census_hamming_custom_vshift(
    left: np.ndarray,
    right: np.ndarray,
    max_disparity: int,
    census_window: int,
    aggregation_window: int,
    max_vertical_shift: int,
    min_disparity: int = 0,
    left_desc: np.ndarray | None = None,
    right_desc: np.ndarray | None = None,
) -> Tuple[np.ndarray, np.ndarray]:
    """Census + Hamming matcher with an additional vertical search range.

    For each horizontal disparity d in [0, max_disparity] and each vertical shift
    vy in [-V, +V] (V = max_vertical_shift), the right-image Census descriptor is
    shifted by (vy rows, d cols), XORed with the left descriptor, popcounted and
    aggregated with a box filter. The (d, vy) with minimum aggregated Hamming
    cost is stored per pixel. Returns (disparity, vshift_map); both have NaN
    where no valid match was found.
    """
    max_disp = max(1, int(max_disparity))
    min_disp = max(0, int(min_disparity))
    if min_disp > max_disp:
        min_disp = max_disp
    census_win = _normalize_odd(census_window, min_value=3)
    agg_win = _normalize_odd(aggregation_window, min_value=1)
    census_half = census_win // 2
    agg_half = agg_win // 2
    vmax = max(0, int(max_vertical_shift))

    h, w = left.shape
    disparity = np.full((h, w), np.nan, dtype=np.float32)
    vshift_map = np.full((h, w), np.nan, dtype=np.float32)
    if w <= max_disp + 2 * census_half or h <= 2 * census_half + 2 * vmax:
        return disparity, vshift_map

    if left_desc is None:
        left_desc = _census_transform_bytes(left, census_win)
    if right_desc is None:
        right_desc = _census_transform_bytes(right, census_win)

    best_cost = np.full((h, w), np.inf, dtype=np.float32)
    best_disp = np.zeros((h, w), dtype=np.float32)
    best_vy = np.zeros((h, w), dtype=np.float32)

    for vy in range(-vmax, vmax + 1):
        shifted_v = _shift_image_vertical(right_desc, vy)

        for d in range(min_disp, max_disp + 1):
            shifted = np.zeros_like(right_desc)
            if d == 0:
                shifted[:, :] = shifted_v
            else:
                shifted[:, d:] = shifted_v[:, : w - d]

            xor = np.bitwise_xor(left_desc, shifted)
            cost = _popcount_bytes(xor).astype(np.float32)

            if agg_win > 1:
                cost = cv2.boxFilter(
                    cost,
                    ddepth=-1,
                    ksize=(agg_win, agg_win),
                    normalize=False,
                    borderType=cv2.BORDER_REPLICATE,
                )

            invalid_left = d + census_half + agg_half
            if invalid_left > 0:
                cost[:, :invalid_left] = np.inf

            invalid_right = census_half + agg_half
            if invalid_right > 0:
                cost[:, w - invalid_right :] = np.inf

            top_invalid = census_half + agg_half + max(0, vy)
            bot_invalid = census_half + agg_half + max(0, -vy)
            if top_invalid > 0:
                cost[:top_invalid, :] = np.inf
            if bot_invalid > 0:
                cost[h - bot_invalid :, :] = np.inf

            improve = cost < best_cost
            best_cost[improve] = cost[improve]
            best_disp[improve] = float(d)
            best_vy[improve] = float(vy)

    valid = np.isfinite(best_cost)
    disparity[valid] = best_disp[valid]
    vshift_map[valid] = best_vy[valid]
    return disparity, vshift_map


def compute_census_hamming(left: np.ndarray, right: np.ndarray, cfg: StereoConfig) -> np.ndarray:
    return compute_census_hamming_custom(
        left=left,
        right=right,
        max_disparity=cfg.census_max_disparities[0],
        census_window=cfg.census_window_sizes[0],
        aggregation_window=cfg.census_aggregation_window,
        min_disparity=cfg.min_disparity,
    )


def compute_census_descriptors(
    left: np.ndarray,
    right: np.ndarray,
    census_window: int,
) -> Tuple[np.ndarray, np.ndarray]:
    """Build Census descriptor-byte volumes for a stereo pair."""
    win = _normalize_odd(census_window, min_value=3)
    return _census_transform_bytes(left, win), _census_transform_bytes(right, win)


def compute_census_debug_views(
    image: np.ndarray,
    census_window: int,
    descriptor: np.ndarray | None = None,
) -> Dict[str, np.ndarray]:
    """
    Return visualization-friendly images for the Census descriptor.
    """
    desc = descriptor if descriptor is not None else _census_transform_bytes(image, census_window)
    popcount = _popcount_bytes(desc).astype(np.float32)

    bits = (_normalize_odd(census_window, min_value=3) ** 2) - 1
    if bits <= 0:
        bits = 1

    popcount_norm = np.clip((popcount / float(bits)) * 255.0, 0.0, 255.0).astype(np.uint8)

    # RGB-style view from the first three descriptor bytes (or repeated channels if fewer bytes).
    channels = []
    nbytes = desc.shape[2]
    for i in range(3):
        idx = min(i, nbytes - 1)
        channels.append(desc[:, :, idx])
    descriptor_rgb = cv2.merge(channels)

    return {
        "census_popcount": popcount_norm,
        "census_descriptor_rgb": descriptor_rgb,
    }


def compute_sad_l1_vshift(left: np.ndarray, right: np.ndarray, cfg: StereoConfig) -> np.ndarray:
    widths = cfg.sad_window_widths or cfg.sad_window_sizes
    heights = cfg.sad_window_heights or cfg.sad_window_sizes
    disp, _ = compute_sad_custom_vshift(
        left,
        right,
        max_disparity=cfg.sad_max_disparities[0],
        window_width=widths[0],
        window_height=heights[0],
        min_disparity=0,
        max_vertical_shift=cfg.sad_vshift_values[0] if cfg.sad_vshift_values else 0,
        cost_mode="l1",
    )
    return disp


def compute_sad_l2_vshift(left: np.ndarray, right: np.ndarray, cfg: StereoConfig) -> np.ndarray:
    widths = cfg.sad_window_widths or cfg.sad_window_sizes
    heights = cfg.sad_window_heights or cfg.sad_window_sizes
    disp, _ = compute_sad_custom_vshift(
        left,
        right,
        max_disparity=cfg.sad_max_disparities[0],
        window_width=widths[0],
        window_height=heights[0],
        min_disparity=0,
        max_vertical_shift=cfg.sad_vshift_values[0] if cfg.sad_vshift_values else 0,
        cost_mode="l2",
    )
    return disp


def compute_sgbm_vshift_default(left: np.ndarray, right: np.ndarray, cfg: StereoConfig) -> np.ndarray:
    disp, _ = compute_sgbm_vshift(
        left,
        right,
        num_disparities=cfg.sgbm_num_disparities,
        block_size=cfg.sgbm_block_size,
        max_vertical_shift=cfg.sgbm_vshift_values[0] if cfg.sgbm_vshift_values else 0,
        min_disparity=cfg.min_disparity,
        validation_window=cfg.sgbm_vshift_validation_window,
        validation_height_scale=cfg.sgbm_vshift_validation_height_scale,
    )
    return disp


def compute_census_hamming_vshift_default(left: np.ndarray, right: np.ndarray, cfg: StereoConfig) -> np.ndarray:
    agg_list = getattr(cfg, "census_vshift_aggregation_windows", None)
    agg_win = int(agg_list[0]) if agg_list else int(cfg.census_aggregation_window)
    vshift_list = getattr(cfg, "census_vshift_values", None)
    vshift = int(vshift_list[0]) if vshift_list else 0
    disp, _ = compute_census_hamming_custom_vshift(
        left,
        right,
        max_disparity=cfg.census_max_disparities[0],
        census_window=cfg.census_window_sizes[0],
        aggregation_window=agg_win,
        max_vertical_shift=vshift,
        min_disparity=cfg.min_disparity,
    )
    return disp


def get_methods() -> Dict[str, DisparityFn]:
    return {
        "bm": compute_bm,
        "sgbm": compute_sgbm,
        "sad": compute_sad_l1,
        "sad_l1": compute_sad_l1,
        "sad_l2": compute_sad_l2,
        "sad_vshift": compute_sad_l1_vshift,
        "sad_l1_vshift": compute_sad_l1_vshift,
        "sad_l2_vshift": compute_sad_l2_vshift,
        "sgbm_vshift": compute_sgbm_vshift_default,
        "census": compute_census_hamming,
        "census_hamming": compute_census_hamming,
        "census_vshift": compute_census_hamming_vshift_default,
        "census_hamming_vshift": compute_census_hamming_vshift_default,
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


def _census_transform_bytes(image: np.ndarray, window_size: int) -> np.ndarray:
    win = _normalize_odd(window_size, min_value=3)
    half = win // 2
    bits = (win * win) - 1
    nbytes = (bits + 7) // 8

    padded = cv2.copyMakeBorder(
        image,
        half,
        half,
        half,
        half,
        borderType=cv2.BORDER_REPLICATE,
    )
    center = padded[half : half + image.shape[0], half : half + image.shape[1]]
    desc = np.zeros((image.shape[0], image.shape[1], nbytes), dtype=np.uint8)

    bit = 0
    for dy in range(-half, half + 1):
        for dx in range(-half, half + 1):
            if dx == 0 and dy == 0:
                continue
            neighbor = padded[
                half + dy : half + dy + image.shape[0],
                half + dx : half + dx + image.shape[1],
            ]
            byte_idx = bit // 8
            bit_idx = bit % 8
            mask = ((neighbor >= center).astype(np.uint8) << np.uint8(bit_idx))
            desc[:, :, byte_idx] |= mask
            bit += 1
    return desc


def _popcount_bytes(values: np.ndarray) -> np.ndarray:
    return POPCOUNT_LUT[values].sum(axis=2, dtype=np.uint16)

