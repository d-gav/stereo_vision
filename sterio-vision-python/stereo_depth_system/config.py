from dataclasses import dataclass, field
from pathlib import Path
from typing import List


@dataclass
class StereoConfig:
    input_dir: Path
    output_dir: Path
    methods: List[str] = field(default_factory=lambda: ["bm", "sgbm", "sad"])
    swap_inputs: bool = True
    crop_height: int | None = 288
    use_clahe: bool = True
    median_blur_ksize: int = 3
    bm_num_disparities: int = 128
    bm_block_size: int = 15
    sgbm_num_disparities: int = 128
    sgbm_block_size: int = 5
    sad_max_disparity: int = 96
    sad_window_size: int = 9

