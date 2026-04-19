import cv2
import numpy as np


def preprocess_image(
    image: np.ndarray,
    crop_height: int | None,
    use_clahe: bool,
    median_blur_ksize: int,
) -> np.ndarray:
    out = image.copy()

    if crop_height is not None and crop_height > 0 and out.shape[0] > crop_height:
        out = out[:crop_height, :]

    if median_blur_ksize >= 3 and median_blur_ksize % 2 == 1:
        out = cv2.medianBlur(out, median_blur_ksize)

    if use_clahe:
        clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
        out = clahe.apply(out)

    return out

