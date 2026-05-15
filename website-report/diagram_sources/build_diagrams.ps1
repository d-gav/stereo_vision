$ErrorActionPreference = "Stop"

$source_dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$site_dir = Split-Path -Parent $source_dir
$build_dir = Join-Path $source_dir "build"
$output_dir = Join-Path $site_dir "public\diagrams"

New-Item -ItemType Directory -Force -Path $build_dir | Out-Null
New-Item -ItemType Directory -Force -Path $output_dir | Out-Null

$latexmk = Get-Command "latexmk" -ErrorAction SilentlyContinue
$latex = Get-Command "latex" -ErrorAction SilentlyContinue
$lualatex = Get-Command "lualatex" -ErrorAction SilentlyContinue
$pdflatex = Get-Command "pdflatex" -ErrorAction SilentlyContinue

$dvisvgm = Get-Command "dvisvgm" -ErrorAction SilentlyContinue
$inkscape = Get-Command "inkscape" -ErrorAction SilentlyContinue
$pdf2svg = Get-Command "pdf2svg" -ErrorAction SilentlyContinue

if (-not ($latexmk -or $latex -or $lualatex -or $pdflatex)) {
  throw "No LaTeX compiler found. Install TeX Live or MiKTeX, then rerun this script."
}

if (-not ($dvisvgm -or $inkscape -or $pdf2svg)) {
  throw "No PDF-to-SVG converter found. Install dvisvgm, Inkscape, or pdf2svg."
}

$tex_files = Get-ChildItem -Path $source_dir -Filter "*.tex" |
  Where-Object { $_.Name -ne "diagram_style.tex" }

Push-Location $source_dir
try {
  foreach ($tex_file in $tex_files) {
    $base_name = [System.IO.Path]::GetFileNameWithoutExtension($tex_file.Name)
    $svg_path = Join-Path $output_dir "$base_name.svg"

    Write-Host "Building $($tex_file.Name)..."

    if ($dvisvgm) {
      $dvi_path = Join-Path $build_dir "$base_name.dvi"

      # Use a DVI pipeline for dvisvgm because PDF-mode conversion can drop text
      # in some local TeX distributions.
      if ($latexmk) {
        & latexmk -latex -interaction=nonstopmode -halt-on-error -outdir="$build_dir" $tex_file.Name
      } elseif ($latex) {
        & latex -interaction=nonstopmode -halt-on-error -output-directory="$build_dir" $tex_file.Name
      } else {
        throw "dvisvgm requires latexmk or latex for DVI generation."
      }

      if ($LASTEXITCODE -ne 0) {
        throw "LaTeX failed while building $($tex_file.Name)."
      }

      & dvisvgm --exact --no-fonts --output="$svg_path" "$dvi_path"
    } elseif ($inkscape) {
      $pdf_path = Join-Path $build_dir "$base_name.pdf"

      if ($latexmk) {
        & latexmk -pdf -interaction=nonstopmode -halt-on-error -outdir="$build_dir" $tex_file.Name
      } elseif ($lualatex) {
        & lualatex -interaction=nonstopmode -halt-on-error -output-directory="$build_dir" $tex_file.Name
      } elseif ($pdflatex) {
        & pdflatex -interaction=nonstopmode -halt-on-error -output-directory="$build_dir" $tex_file.Name
      } else {
        throw "No PDF-capable LaTeX compiler found for Inkscape conversion."
      }

      if ($LASTEXITCODE -ne 0) {
        throw "LaTeX failed while building $($tex_file.Name)."
      }

      & inkscape "$pdf_path" --export-type=svg --export-filename="$svg_path"
    } else {
      $pdf_path = Join-Path $build_dir "$base_name.pdf"

      if ($latexmk) {
        & latexmk -pdf -interaction=nonstopmode -halt-on-error -outdir="$build_dir" $tex_file.Name
      } elseif ($lualatex) {
        & lualatex -interaction=nonstopmode -halt-on-error -output-directory="$build_dir" $tex_file.Name
      } elseif ($pdflatex) {
        & pdflatex -interaction=nonstopmode -halt-on-error -output-directory="$build_dir" $tex_file.Name
      } else {
        throw "No PDF-capable LaTeX compiler found for pdf2svg conversion."
      }

      if ($LASTEXITCODE -ne 0) {
        throw "LaTeX failed while building $($tex_file.Name)."
      }

      & pdf2svg "$pdf_path" "$svg_path"
    }

    if ($LASTEXITCODE -ne 0) {
      throw "SVG conversion failed for $($tex_file.Name)."
    }
  }
}
finally {
  Pop-Location
}

Write-Host "Done. SVGs are in public\diagrams."
