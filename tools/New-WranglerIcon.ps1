<#
.SYNOPSIS
    Draws the Workspace Wrangler icon (a bold cowboy hat) and writes assets\wrangler.ico + assets\wrangler.png.
    Re-run only if you want to change the artwork; the .ico is committed.
#>
param([string]$OutDir = (Join-Path $PSScriptRoot '..\assets'))
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

function C([string]$hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }
function Br([string]$hex) { New-Object System.Drawing.SolidBrush (C $hex) }

$S = 256
$bmp = New-Object System.Drawing.Bitmap $S, $S, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'; $g.Clear([System.Drawing.Color]::Transparent)

# Badge: warm sunset circle so the hat reads at any size
$rect = New-Object System.Drawing.Rectangle 4, 4, 248, 248
$grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush $rect, (C '#FFB347'), (C '#E4572E'), 90
$g.FillEllipse($grad, $rect)
$g.DrawEllipse((New-Object System.Drawing.Pen (C '#3B1F0E'), 10), 9, 9, 238, 238)

function P([float]$x, [float]$y) { New-Object System.Drawing.PointF($x, $y) }
$ink = New-Object System.Drawing.Pen (C '#2A1608'), 9
$ink.LineJoin = 'Round'

# Crown: tall, pinched at the top centre
$crown = New-Object System.Drawing.Drawing2D.GraphicsPath
$crown.AddCurve([System.Drawing.PointF[]]@((P 72 160), (P 70 100), (P 84 62), (P 128 80), (P 172 62), (P 186 100), (P 184 160)), 0.5)
$crown.CloseFigure()
$g.FillPath((Br '#8B5A2B'), $crown); $g.DrawPath($ink, $crown)

# Brim: wide, curled up at both ends
$brim = New-Object System.Drawing.Drawing2D.GraphicsPath
$brim.AddCurve([System.Drawing.PointF[]]@((P 14 112), (P 50 178), (P 128 198), (P 206 178), (P 242 112)), 0.6)
$brim.AddCurve([System.Drawing.PointF[]]@((P 242 112), (P 196 150), (P 128 158), (P 60 150), (P 14 112)), 0.6)
$brim.CloseFigure()
$g.FillPath((Br '#B07A3F'), $brim); $g.DrawPath($ink, $brim)

# Band
$band = New-Object System.Drawing.Drawing2D.GraphicsPath
$band.AddPolygon([System.Drawing.PointF[]]@((P 72 150), (P 71 126), (P 185 126), (P 184 150)))
$g.FillPath((Br '#F4D35E'), $band); $g.DrawPath((New-Object System.Drawing.Pen (C '#2A1608'), 6), $band)
$g.Dispose()

$bmp.Save((Join-Path $OutDir 'wrangler.png'), [System.Drawing.Imaging.ImageFormat]::Png)

# Pack a multi-size .ico (PNG-compressed entries)
$sizes = 16, 24, 32, 48, 64, 128, 256
$pngs = foreach ($sz in $sizes) {
    $b = New-Object System.Drawing.Bitmap $sz, $sz, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $gg = [System.Drawing.Graphics]::FromImage($b); $gg.InterpolationMode = 'HighQualityBicubic'; $gg.SmoothingMode = 'AntiAlias'
    $gg.DrawImage($bmp, 0, 0, $sz, $sz); $gg.Dispose()
    $ms = New-Object System.IO.MemoryStream; $b.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $b.Dispose()
    ,$ms.ToArray()
}
$out = New-Object System.IO.MemoryStream; $w = New-Object System.IO.BinaryWriter $out
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $sz = $sizes[$i]; $dim = if ($sz -ge 256) { 0 } else { $sz }
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$pngs[$i].Length); $w.Write([uint32]$offset)
    $offset += $pngs[$i].Length
}
foreach ($p in $pngs) { $w.Write($p) }
$w.Flush()
[System.IO.File]::WriteAllBytes((Join-Path $OutDir 'wrangler.ico'), $out.ToArray())
$bmp.Dispose()
Write-Output "Wrote $OutDir\wrangler.ico and wrangler.png"
