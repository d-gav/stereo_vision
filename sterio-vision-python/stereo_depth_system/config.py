from dataclasses import dataclass, field
from pathlib import Path
from typing import List


@dataclass
class StereoConfig:
    input_dir: Path
    output_dir: Path
    methods: List[str] = field(default_factory=lambda: ["bm", "sgbm", "sad_l1", "census_hamming"])
    swap_inputs: bool = True
    crop_height: int | None = 288
    use_clahe: bool = True
    median_blur_ksize: int = 3
    min_disparity: int = 0
    bm_num_disparities: int = 128
    bm_block_size: int = 15
    sgbm_num_disparities: int = 128
    sgbm_block_size: int = 5
    sad_max_disparities: List[int] = field(default_factory=lambda: [96])
    sad_window_sizes: List[int] = field(default_factory=lambda: [9])
    sad_window_widths: List[int] = field(default_factory=lambda: [9])
    sad_window_heights: List[int] = field(default_factory=lambda: [9])
    sad_vshift_values: List[int] = field(default_factory=lambda: [2])
    sad_vshift_grid_row_param: str = "window_height"
    sad_vshift_grid_col_param: str = "vshift"
    sad_vshift_grid_panel_param: str = "max_disparity"
    sgbm_vshift_values: List[int] = field(default_factory=lambda: [0, 2, 4])
    sgbm_vshift_block_sizes: List[int] = field(default_factory=lambda: [5])
    sgbm_vshift_validation_windows: List[int] = field(default_factory=lambda: [7])
    sgbm_vshift_validation_height_scale: int = 1
    # Legacy scalar used as fallback when the list fields are empty.
    sgbm_vshift_validation_window: int = 7
    census_max_disparities: List[int] = field(default_factory=lambda: [64])
    census_window_sizes: List[int] = field(default_factory=lambda: [7])
    census_aggregation_window: int = 5
    census_vshift_values: List[int] = field(default_factory=lambda: [2])
    census_vshift_aggregation_windows: List[int] = field(default_factory=lambda: [5])

