import numpy as np


def disparity_to_relative_depth(disparity: np.ndarray, epsilon: float = 1e-6) -> np.ndarray:
    depth = np.full_like(disparity, np.nan, dtype=np.float32)
    valid = np.isfinite(disparity) & (disparity > 0)
    depth[valid] = 1.0 / (disparity[valid] + epsilon)
    return depth

