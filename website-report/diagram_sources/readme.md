# Diagram Sources

This folder is intentionally outside `src/` and `public/`, so Astro does not compile or copy these LaTeX sources into the website build.

The `.tex` files here use TikZ to generate clean SVG diagrams for the final report. Run the build script when you want to update the rendered website assets:

```powershell
.\diagram_sources\build_diagrams.ps1
```

Rendered SVGs are written to:

```txt
public/diagrams/
```

Note: the build script uses a `latex -> dvi -> dvisvgm` pipeline when `dvisvgm` is available. This avoids a common `dvisvgm --pdf` issue where text labels are dropped from SVG output on some local TeX setups.

Use those generated files in Astro pages with paths like:

```html
<img src="diagrams/system_architecture.svg" alt="System architecture diagram">
```

## Tools Needed

The script expects a LaTeX installation and one PDF-to-SVG converter:

- LaTeX: `latexmk`, `lualatex`, or `pdflatex`
- Converter: `dvisvgm`, `inkscape`, or `pdf2svg`

Recommended Windows setup: install MiKTeX or TeX Live, then install `dvisvgm` if it is not already included.

## Current Diagrams

- `system_architecture.tex` -> `system_architecture.svg`
- `frame_layout_memory_map.tex` -> `frame_layout_memory_map.svg`
- `sad_block_matching.tex` -> `sad_block_matching.svg`
- `rtl_data_path.tex` -> `rtl_data_path.svg`
- `model_alignment_workflow.tex` -> `model_alignment_workflow.svg`
- `mem_block_intf_fsm.tex` -> `mem_block_intf_fsm.svg`

## Interactive animations

These live under `public/animations/` (HTML, not TeX) and are served as-is by Astro:

- `mem_block_intf.html` — cycle-by-cycle visualization of the SAD matcher's FSM.
  Shows the reference block, search window, candidate match, memory request,
  sliding-window control signals and best-SAD scoreboard. Auto-plays or steps
  through ~70 logical cycles using toy parameters (`BLOCK_SIZE=3, MAX_DISP=5`).
  Deep-link a specific cycle with `?cycle=N`.
