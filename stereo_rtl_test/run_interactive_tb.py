#!/usr/bin/env python3
"""Interactive image-driven testbench runner for mem_block_intf.

Flow:
1) Read one 640x480 input PNG (or larger).
2) Use only top 640x288 pixels.
3) Split into left [0..319] and right [320..639] grayscale frames.
4) Write left/right frame data to hex files for the SV testbench memory model.
5) Compile and run tb_mem_block_intf.sv via iverilog/vvp.
6) Convert DUT disparity hex output to a PNG image.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path
from typing import Iterable

from PIL import Image


FRAME_HEIGHT = 288
HALF_FRAME_WIDTH = 320
FULL_FRAME_WIDTH = 640
MAX_DISP = 63


def _prompt(text: str, default: str | None = None) -> str:
    if default is None:
        raw = input(f"{text}: ").strip()
    else:
        raw = input(f"{text} [{default}]: ").strip()
    if raw:
        return raw
    if default is None:
        return ""
    return default


def _parse_yes_no(raw: str, default: bool) -> bool:
    text = raw.strip().lower()
    if not text:
        return default
    if text in {"y", "yes", "1", "true", "t"}:
        return True
    if text in {"n", "no", "0", "false", "f"}:
        return False
    raise ValueError(f"Invalid yes/no value: {raw}")


def _write_hex(pixels: Iterable[int], out_path: Path) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="ascii", newline="\n") as f:
        for px in pixels:
            f.write(f"{int(px) & 0xFF:02x}\n")


def _read_hex(path: Path, expected_count: int) -> list[int]:
    vals: list[int] = []
    with path.open("r", encoding="ascii") as f:
        for line in f:
            s = line.strip()
            if not s:
                continue
            vals.append(int(s, 16) & 0xFF)
    if len(vals) < expected_count:
        raise RuntimeError(
            f"Disparity hex has too few entries: got {len(vals)}, expected {expected_count}"
        )
    if len(vals) > expected_count:
        vals = vals[:expected_count]
    return vals


def _extract_stereo_halves(input_png: Path) -> tuple[Image.Image, Image.Image]:
    img = Image.open(input_png).convert("L")
    if img.width < FULL_FRAME_WIDTH or img.height < FRAME_HEIGHT:
        raise RuntimeError(
            f"Input image must be at least {FULL_FRAME_WIDTH}x{FRAME_HEIGHT}; "
            f"got {img.width}x{img.height}"
        )

    top = img.crop((0, 0, FULL_FRAME_WIDTH, FRAME_HEIGHT))
    left = top.crop((0, 0, HALF_FRAME_WIDTH, FRAME_HEIGHT))
    right = top.crop((HALF_FRAME_WIDTH, 0, FULL_FRAME_WIDTH, FRAME_HEIGHT))
    return left, right


def _compile_and_run(
    script_dir: Path,
    left_hex: Path,
    right_hex: Path,
    out_hex: Path,
    max_disp: int,
    rst_cycles: int,
    max_cycles: int,
    progress_stride: int,
    iverilog_bin: str,
    vvp_bin: str,
) -> None:
    build_dir = script_dir / "build"
    build_dir.mkdir(parents=True, exist_ok=True)
    vvp_out = build_dir / "tb_mem_block_intf.vvp"

    rtl_files = [
        "block_match_pkg.sv",
        "block_match.sv",
        "sliding_window.sv",
        "mem_block_intf.v",
        "tb_mem_block_intf.sv",
    ]

    compile_cmd = [
        iverilog_bin,
        "-g2012",
        "-P",
        f"tb_mem_block_intf.MAX_DISP={max_disp}",
        "-o",
        str(vvp_out),
        *rtl_files,
    ]
    print("[RUN] Compiling testbench...")
    subprocess.run(compile_cmd, cwd=str(script_dir), check=True)

    run_cmd = [
        vvp_bin,
        str(vvp_out),
        f"+LEFT_HEX={left_hex.as_posix()}",
        f"+RIGHT_HEX={right_hex.as_posix()}",
        f"+OUT_HEX={out_hex.as_posix()}",
        f"+RST_CYCLES={rst_cycles}",
        f"+MAX_CYCLES={max_cycles}",
        f"+PROGRESS_STRIDE={progress_stride}",
    ]
    print(
        f"[RUN] Running simulation (this can take a while for full 320x288, max_disp={max_disp})..."
    )
    subprocess.run(run_cmd, cwd=str(script_dir), check=True)


def _save_disparity_png(
    out_hex: Path,
    output_png: Path,
    scale_for_view: bool,
    max_disp: int,
) -> None:
    count = FRAME_HEIGHT * HALF_FRAME_WIDTH
    vals = _read_hex(out_hex, count)

    if scale_for_view:
        if max_disp <= 0:
            scaled = vals
        else:
            scale = 255.0 / float(max_disp)
            scaled = [min(255, int(round(v * scale))) for v in vals]
        data = scaled
    else:
        data = vals

    out_img = Image.new("L", (HALF_FRAME_WIDTH, FRAME_HEIGHT))
    out_img.putdata(data)
    output_png.parent.mkdir(parents=True, exist_ok=True)
    out_img.save(output_png)



def main() -> int:
    parser = argparse.ArgumentParser(description="Interactive RTL stereo disparity testbench runner")
    parser.add_argument("--input-png", type=Path, help="Input 640x480 PNG path")
    parser.add_argument("--output-png", type=Path, help="Output disparity PNG path")
    parser.add_argument("--work-dir", type=Path, default=Path("build"), help="Directory for generated hex/temp files")
    parser.add_argument("--max-disp", type=int, default=MAX_DISP, help="Maximum disparity used by DUT")
    parser.add_argument("--rst-cycles", type=int, default=1, help="Reset cycles held high in testbench")
    parser.add_argument("--max-cycles", type=int, default=150_000_000, help="Simulation timeout in cycles")
    parser.add_argument("--progress-stride", type=int, default=50_000, help="TB progress print interval")
    parser.add_argument("--raw-disp", action="store_true", help="Do not scale disparity for display")
    parser.add_argument("--iverilog", default=os.environ.get("IVERILOG", "iverilog"), help="iverilog executable")
    parser.add_argument("--vvp", default=os.environ.get("VVP", "vvp"), help="vvp executable")
    parser.add_argument("--keep-intermediate", action="store_true", help="Keep generated hex files")
    args = parser.parse_args()

    script_dir = Path(__file__).resolve().parent

    input_png = args.input_png
    if input_png is None:
        raw = _prompt("Input PNG path")
        if not raw:
            print("Input PNG is required.")
            return 1
        input_png = Path(raw)

    output_png = args.output_png
    if output_png is None:
        raw = _prompt("Output disparity PNG path", "disparity_map.png")
        output_png = Path(raw)

    scale_for_view = not args.raw_disp
    if args.input_png is None or args.output_png is None:
        try:
            ans = _prompt("Scale disparity to 0..255 for visualization? (y/n)", "y")
            scale_for_view = _parse_yes_no(ans, default=True)
        except ValueError as exc:
            print(str(exc))
            return 1

    if not input_png.exists():
        print(f"Input PNG does not exist: {input_png}")
        return 1

    work_dir = (script_dir / args.work_dir).resolve()
    work_dir.mkdir(parents=True, exist_ok=True)

    left_hex = work_dir / "left_frame.hex"
    right_hex = work_dir / "right_frame.hex"
    out_hex = work_dir / "disparity_out.hex"

    try:
        print("[RUN] Loading and splitting stereo image...")
        left_img, right_img = _extract_stereo_halves(input_png)

        _write_hex(left_img.getdata(), left_hex)
        _write_hex(right_img.getdata(), right_hex)

        _compile_and_run(
            script_dir=script_dir,
            left_hex=left_hex,
            right_hex=right_hex,
            out_hex=out_hex,
            max_disp=args.max_disp,
            rst_cycles=args.rst_cycles,
            max_cycles=args.max_cycles,
            progress_stride=args.progress_stride,
            iverilog_bin=args.iverilog,
            vvp_bin=args.vvp,
        )

        _save_disparity_png(
            out_hex=out_hex,
            output_png=output_png,
            scale_for_view=scale_for_view,
            max_disp=args.max_disp,
        )

        print(f"[DONE] Disparity PNG written to: {output_png}")

    except KeyboardInterrupt:
        print("\n[STOP] Simulation interrupted by user.")
        return 130
    except subprocess.CalledProcessError as exc:
        print(f"Simulation command failed with exit code {exc.returncode}")
        return exc.returncode
    except Exception as exc:  # pylint: disable=broad-except
        print(f"Error: {exc}")
        return 1
    finally:
        if not args.keep_intermediate:
            for path in (left_hex, right_hex, out_hex):
                if path.exists():
                    path.unlink()

    return 0


if __name__ == "__main__":
    sys.exit(main())
