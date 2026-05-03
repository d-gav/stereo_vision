Stereo RTL Image Testbench
==========================

This folder contains an image-driven test flow for mem_block_intf:

- Input: one PNG image at least 640x288 (typically 640x480).
- ROI used for stereo: top 640x288.
- Left frame: x=[0..319], right frame: x=[320..639].
- DUT memory model: row-banked, single-pixel read interface via mem_req/mem_bank/mem_row/mem_col.
- Output: disparity PNG of size 320x288.

Files
-----

- tb_mem_block_intf.sv: SystemVerilog testbench with memory model and completion tracking.
- run_interactive_tb.py: Interactive Python runner for PNG -> simulation -> PNG.
- requirements.txt: Python dependency list.

Setup
-----

1) Install Icarus Verilog (iverilog + vvp).
2) Install Python dependency:

   python -m pip install -r requirements.txt

Run (interactive)
-----------------

From this directory:

python run_interactive_tb.py

You will be prompted for:

- input PNG path
- output PNG path
- whether to scale disparity values for visualization

Run (non-interactive)
---------------------

python run_interactive_tb.py --input-png path/to/input.png --output-png path/to/output.png

Useful options:

- --max-disp N
  - Override DUT max disparity (default: 63). Lower values run much faster for smoke tests.
- --rst-cycles N
  - Number of reset cycles in testbench (default: 1).
- --raw-disp
  - Save raw disparity values (0..63) directly into PNG intensity.
- --no-vcd
  - Disable VCD dumping for faster runs.
- --max-cycles N
  - Simulation timeout guard (default: 150000000).
- --progress-stride N
  - TB progress print interval in cycles (default: 50000).
- --keep-intermediate
  - Keep generated left/right/disparity hex files in build/.
- --iverilog PATH
  - Override iverilog executable.
- --vvp PATH
  - Override vvp executable.

Notes
-----

- This testbench expects a one-cycle memory read latency in the memory model.
- Full-size run can be computationally heavy; progress is printed periodically.
- Quick smoke example:

  python run_interactive_tb.py --max-disp 15 --progress-stride 10000
