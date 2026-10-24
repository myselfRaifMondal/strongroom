# Converts the shared 1024 px app icon (apps/macos/Resources/AppIcon-1024.png)
# into a multi-size Windows .ico for the EXE, the shortcuts and the installer.
#
#   powershell -File apps/windows/installer/make-icon.ps1 [-Source PNG] [-Out ICO]
#
# Sizes 16..128 are stored as 32-bit BMP (DIB) entries, which every Windows
# component reads (resource compiler, shell, Inno Setup); 256 is stored as PNG,
# the standard way for the large size. Runs on Windows PowerShell 5.1 or
# PowerShell 7 on Windows (System.Drawing). The output is generated in CI and
# not committed.
param(
    [string]$Source = (Join-Path $PSScriptRoot "..\..\macos\Resources\AppIcon-1024.png"),
    [string]$Out = (Join-Path $PSScriptRoot "..\src\Strongroom.App\Assets\Strongroom.ico")
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256
$src = [System.Drawing.Image]::FromFile((Resolve-Path $Source))

function Get-Resized([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.DrawImage($src, 0, 0, $size, $size)
    $g.Dispose()
    return $bmp
}

function Get-DibBytes([System.Drawing.Bitmap]$bmp) {
    $s = $bmp.Width
    $rect = New-Object System.Drawing.Rectangle 0, 0, $s, $s
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $rowBytes = $s * 4
    $pixels = New-Object byte[] ($rowBytes * $s)
    for ($y = 0; $y -lt $s; $y++) {
        # DIB rows are bottom-up; LockBits rows are top-down (BGRA, straight alpha).
        $srcPtr = [IntPtr]::Add($data.Scan0, $y * $data.Stride)
        [System.Runtime.InteropServices.Marshal]::Copy($srcPtr, $pixels, ($s - 1 - $y) * $rowBytes, $rowBytes)
    }
    $bmp.UnlockBits($data)
    $maskRow = [int]([math]::Ceiling($s / 32.0) * 4)
    $mask = New-Object byte[] ($maskRow * $s)   # all zero: alpha channel decides
    $ms = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter $ms
    $w.Write([int]40); $w.Write([int]$s); $w.Write([int]($s * 2))
    $w.Write([int16]1); $w.Write([int16]32); $w.Write([int]0)
    $w.Write([int]($pixels.Length + $mask.Length)); $w.Write([int]0); $w.Write([int]0); $w.Write([int]0); $w.Write([int]0)
    $w.Write($pixels); $w.Write($mask); $w.Flush()
    return , $ms.ToArray()
}

$images = @()
foreach ($size in $sizes) {
    $bmp = Get-Resized $size
    if ($size -ge 256) {
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $bytes = $ms.ToArray()
    } else {
        $bytes = Get-DibBytes $bmp
    }
    $bmp.Dispose()
    $images += , @{ Size = $size; Bytes = $bytes }
}
$src.Dispose()

New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null
$fs = [System.IO.File]::Create($Out)
$w = New-Object System.IO.BinaryWriter $fs
$w.Write([int16]0); $w.Write([int16]1); $w.Write([int16]$images.Count)
$offset = 6 + 16 * $images.Count
foreach ($img in $images) {
    $dim = if ($img.Size -ge 256) { 0 } else { $img.Size }
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([int16]1); $w.Write([int16]32)
    $w.Write([int]$img.Bytes.Length); $w.Write([int]$offset)
    $offset += $img.Bytes.Length
}
foreach ($img in $images) { $w.Write([byte[]]$img.Bytes) }
$w.Flush(); $fs.Dispose()
"wrote $Out ($((Get-Item $Out).Length) bytes, sizes: $($sizes -join ', '))"
