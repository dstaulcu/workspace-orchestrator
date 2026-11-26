<#
.SYNOPSIS
    Makes the smaller images derived from assets\concept.jpg (see docs\concept-art.md):
      mark.png     rider-only square used in the first-run folder dialog
      splash.jpg   640 px wide copy used by the startup splash and the About box
      social-preview.jpg    1280 x 640 crop for the GitHub repository social preview (upload it in the repo's Settings)
    Re-run after replacing the concept art. The outputs are committed.
#>
param([string]$Dir = (Join-Path $PSScriptRoot '..\assets'))
Add-Type -AssemblyName System.Drawing
$src = [System.Drawing.Image]::FromFile((Resolve-Path (Join-Path $Dir 'concept.jpg')))
function Save-Crop($Rect, $W, $H, $Name, $Format) {
    $bmp = New-Object System.Drawing.Bitmap($W, $H)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = 'HighQualityBicubic'; $g.SmoothingMode = 'HighQuality'; $g.PixelOffsetMode = 'HighQuality'
    $g.DrawImage($src, (New-Object System.Drawing.Rectangle(0, 0, $W, $H)), $Rect, [System.Drawing.GraphicsUnit]::Pixel)
    $g.Dispose()
    $out = Join-Path (Resolve-Path $Dir) $Name
    if ($Format -eq 'jpg') {
        $enc = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
        $p = New-Object System.Drawing.Imaging.EncoderParameters(1)
        $p.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]88)
        $bmp.Save($out, $enc, $p)
    } else { $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png) }
    $bmp.Dispose(); "wrote $out"
}
$w = $src.Width; $h = $src.Height
Save-Crop (New-Object System.Drawing.Rectangle(440, 140, 620, 620)) 128 128 'mark.png' 'png'
Save-Crop (New-Object System.Drawing.Rectangle(0, 0, $w, $h)) 640 ([int][Math]::Round(640 * $h / $w)) 'splash.jpg' 'jpg'
$ch = [int][Math]::Round($w / 2)   # 2:1 crop, vertically centered
Save-Crop (New-Object System.Drawing.Rectangle(0, [int](($h - $ch) / 2), $w, $ch)) 1280 640 'social-preview.jpg' 'jpg'
$src.Dispose()
