param(
    [Parameter(Mandatory = $true)]
    [string]$InputDir,

    [Parameter(Mandatory = $false)]
    [string]$OutputDir,

    [Parameter(Mandatory = $false)]
    [int]$CropHeight = 288,

    [Parameter(Mandatory = $false)]
    [double]$DarkThreshold = 35.0,

    [Parameter(Mandatory = $false)]
    [double]$MinDarkRatio = 0.75
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path $InputDir)) {
    throw "InputDir does not exist: $InputDir"
}

if (-not $OutputDir) {
    $OutputDir = Join-Path $InputDir "split"
}

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

Add-Type -AssemblyName System.Drawing

function Get-DarkRuns {
    param(
        [System.Drawing.Bitmap]$Bitmap,
        [int]$HeightLimit,
        [double]$LumThreshold,
        [double]$DarkRatio
    )

    $height = [Math]::Min($HeightLimit, $Bitmap.Height)
    if ($height -le 0) {
        return @()
    }

    $minDarkPixels = [int][Math]::Ceiling($height * $DarkRatio)
    $darkColumns = New-Object System.Collections.Generic.List[int]

    for ($x = 0; $x -lt $Bitmap.Width; $x++) {
        $darkCount = 0
        for ($y = 0; $y -lt $height; $y++) {
            $pixel = $Bitmap.GetPixel($x, $y)
            $lum = (0.299 * $pixel.R) + (0.587 * $pixel.G) + (0.114 * $pixel.B)
            if ($lum -lt $LumThreshold) {
                $darkCount++
            }
        }
        if ($darkCount -ge $minDarkPixels) {
            [void]$darkColumns.Add($x)
        }
    }

    if ($darkColumns.Count -eq 0) {
        return @()
    }

    $runs = New-Object System.Collections.Generic.List[object]
    $runStart = $darkColumns[0]
    $prev = $darkColumns[0]

    for ($i = 1; $i -lt $darkColumns.Count; $i++) {
        $current = $darkColumns[$i]
        if ($current -eq ($prev + 1)) {
            $prev = $current
            continue
        }

        $runs.Add([pscustomobject]@{
                Start  = $runStart
                End    = $prev
                Center = ($runStart + $prev) / 2.0
            })
        $runStart = $current
        $prev = $current
    }

    $runs.Add([pscustomobject]@{
            Start  = $runStart
            End    = $prev
            Center = ($runStart + $prev) / 2.0
        })

    return $runs
}

$images = Get-ChildItem -Path $InputDir -Filter *.png | Sort-Object Name
if ($images.Count -eq 0) {
    throw "No PNG files found in: $InputDir"
}

foreach ($file in $images) {
    $bmp = New-Object System.Drawing.Bitmap($file.FullName)
    try {
        $runs = Get-DarkRuns -Bitmap $bmp -HeightLimit $CropHeight -LumThreshold $DarkThreshold -DarkRatio $MinDarkRatio
        if ($runs.Count -eq 0) {
            Write-Warning "Skipping $($file.Name): no vertical dark bar runs found."
            continue
        }

        $imageCenter = $bmp.Width / 2.0
        $centerBar = $runs | Sort-Object { [Math]::Abs($_.Center - $imageCenter) } | Select-Object -First 1
        $rightBar = $runs | Where-Object { $_.Center -gt ($bmp.Width * 0.75) } | Sort-Object Center -Descending | Select-Object -First 1

        $leftStart = 0
        $leftEnd = $centerBar.Start - 1
        $rightStart = $centerBar.End + 1
        $rightEnd = if ($null -ne $rightBar) { $rightBar.Start - 1 } else { $bmp.Width - 1 }

        $leftWidth = $leftEnd - $leftStart + 1
        $rightWidth = $rightEnd - $rightStart + 1
        $cropWidth = [Math]::Min($leftWidth, $rightWidth)
        $height = [Math]::Min($CropHeight, $bmp.Height)

        if ($cropWidth -le 0 -or $height -le 0) {
            Write-Warning "Skipping $($file.Name): invalid crop bounds. leftWidth=$leftWidth rightWidth=$rightWidth height=$height"
            continue
        }

        $leftRect = New-Object System.Drawing.Rectangle($leftStart, 0, $cropWidth, $height)
        $rightRect = New-Object System.Drawing.Rectangle($rightStart, 0, $cropWidth, $height)

        $leftBmp = $bmp.Clone($leftRect, $bmp.PixelFormat)
        $rightBmp = $bmp.Clone($rightRect, $bmp.PixelFormat)

        try {
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
            $leftOutPath = Join-Path $OutputDir ($baseName + "_left.png")
            $rightOutPath = Join-Path $OutputDir ($baseName + "_right.png")

            $leftBmp.Save($leftOutPath, [System.Drawing.Imaging.ImageFormat]::Png)
            $rightBmp.Save($rightOutPath, [System.Drawing.Imaging.ImageFormat]::Png)

            $rightBarText = if ($null -ne $rightBar) { "$($rightBar.Start)-$($rightBar.End)" } else { "none" }
            Write-Output ("{0}: centerBar={1}-{2}, rightBar={3}, size={4}x{5}" -f $file.Name, $centerBar.Start, $centerBar.End, $rightBarText, $cropWidth, $height)
        }
        finally {
            $leftBmp.Dispose()
            $rightBmp.Dispose()
        }
    }
    finally {
        $bmp.Dispose()
    }
}
