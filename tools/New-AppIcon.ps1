<#
.SYNOPSIS
    Draws the Workspace Wrangler icon (a cowboy hat with a cyan visor, in the concept art's night-sky/neon palette) and writes assets\app.ico + assets\app.png.
    Re-run only if you want to change the artwork; the .ico is committed.
#>
param([string]$OutDir = (Join-Path $PSScriptRoot '..\assets'))
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

function C([string]$hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }
function Br([string]$hex) { New-Object System.Drawing.SolidBrush (C $hex) }

# Draws the badge at 256 px. -Simple drops the fine detail (grid, lasso, glow) and thickens outlines so it survives
# being shrunk to 16-48 px; the detailed version is used for 64 px and up.
function New-Badge([bool]$Simple, [int]$Size = 256) {
    # Drawn natively at $Size (scaled coordinates), not shrunk from 256, so small sizes keep crisp edges.
    $bmp = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'; $g.CompositingQuality = 'HighQuality'; $g.Clear([System.Drawing.Color]::Transparent)
    $g.ScaleTransform($Size / 256.0, $Size / 256.0)
    $rect = New-Object System.Drawing.Rectangle 4, 4, 248, 248
    $sky = New-Object System.Drawing.Drawing2D.LinearGradientBrush $rect, (C '#0B1322'), (C '#F29A3C'), 90
    $blend = New-Object System.Drawing.Drawing2D.ColorBlend 4
    $blend.Colors = [System.Drawing.Color[]]@((C '#0B1322'), (C '#0F5E73'), (C '#F29A3C'), (C '#1A2C4A'))
    $blend.Positions = [single[]]@(0.0, 0.45, 0.72, 1.0)
    $sky.InterpolationColors = $blend
    $g.FillEllipse($sky, $rect)

    function P([float]$x, [float]$y) { New-Object System.Drawing.PointF($x, $y) }
    $inkW = 9; $bandW = 6; if ($Simple) { $inkW = 15; $bandW = 10; if ($Size -le 24) { $inkW = 20; $bandW = 13 } }
    $ink = New-Object System.Drawing.Pen (C '#0B1322'), $inkW
    $ink.LineJoin = 'Round'

    if (-not $Simple) {
        # Perspective grid floor (clipped to the badge)
        $clip = New-Object System.Drawing.Drawing2D.GraphicsPath; $clip.AddEllipse($rect)
        $g.SetClip($clip)
        $gridPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(150, 53, 224, 240)), 2.5
        foreach ($x in -60, 20, 80, 128, 176, 236, 316) { $g.DrawLine($gridPen, 128 + ($x - 128) * 0.25, 184, $x * 1.0 + ($x - 128) * 1.1, 262) }
        foreach ($y in 194, 210, 232) { $g.DrawLine($gridPen, 0, $y, 256, $y) }
        $g.ResetClip()
        # Energy lasso: a golden loop with a cyan core swinging over the hat
        $lasso = New-Object System.Drawing.Pen (C '#F4D35E'), 9; $lasso.StartCap = 'Round'; $lasso.EndCap = 'Round'
        $core  = New-Object System.Drawing.Pen (C '#35E0F0'), 3.5; $core.StartCap = 'Round'; $core.EndCap = 'Round'
        $g.DrawArc($lasso, 30, 14, 196, 120, 200, 250)
        $g.DrawArc($core, 30, 14, 196, 120, 200, 250)
    }

    # Visor: glowing cyan band peeking out under the brim (taller in the simple version so it still shows)
    $vt = 150; $vh = 40; if ($Simple) { $vt = 146; $vh = 52 }
    $vis = New-Object System.Drawing.Drawing2D.GraphicsPath
    $vis.AddArc(70, $vt, 28, $vh, 90, 180); $vis.AddArc(158, $vt, 28, $vh, 270, 180); $vis.CloseFigure()
    $g.FillPath((New-Object System.Drawing.SolidBrush (C '#35E0F0')), $vis); $g.DrawPath((New-Object System.Drawing.Pen (C '#0B1322'), $bandW), $vis)

    # Hat
    $crown = New-Object System.Drawing.Drawing2D.GraphicsPath
    $crown.AddCurve([System.Drawing.PointF[]]@((P 72 140), (P 70 84), (P 84 46), (P 128 64), (P 172 46), (P 186 84), (P 184 140)), 0.5)
    $crown.CloseFigure()
    $g.FillPath((Br '#8B5A2B'), $crown); $g.DrawPath($ink, $crown)
    $brim = New-Object System.Drawing.Drawing2D.GraphicsPath
    $brim.AddCurve([System.Drawing.PointF[]]@((P 14 98), (P 50 160), (P 128 174), (P 206 160), (P 242 98)), 0.6)
    $brim.AddCurve([System.Drawing.PointF[]]@((P 242 98), (P 196 132), (P 128 140), (P 60 132), (P 14 98)), 0.6)
    $brim.CloseFigure()
    $g.FillPath((Br '#B07A3F'), $brim); $g.DrawPath($ink, $brim)
    $band = New-Object System.Drawing.Drawing2D.GraphicsPath
    $band.AddPolygon([System.Drawing.PointF[]]@((P 72 132), (P 71 108), (P 185 108), (P 184 132)))
    $g.FillPath((Br '#F4D35E'), $band); $g.DrawPath((New-Object System.Drawing.Pen (C '#0B1322'), $bandW), $band)

    # Neon ring: crisp cyan edge (soft glow only in the detailed version)
    if (-not $Simple) { $g.DrawEllipse((New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(70, 53, 224, 240)), 16), 8, 8, 240, 240) }
    $ringW = 6; if ($Simple) { $ringW = 14; if ($Size -le 24) { $ringW = 18 } }
    $g.DrawEllipse((New-Object System.Drawing.Pen (C '#35E0F0'), $ringW), (4 + $ringW / 2), (4 + $ringW / 2), (248 - $ringW), (248 - $ringW))
    $g.Dispose()
    $bmp
}

$bmp = New-Badge $false 256
$bmp.Save((Join-Path $OutDir 'app.png'), [System.Drawing.Imaging.ImageFormat]::Png)

# Pack a multi-size .ico (PNG-compressed entries)
$sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256   # 20 and 40 are the title-bar/taskbar sizes at 125% display scaling
$pngs = foreach ($sz in $sizes) {
    $b = New-Badge ($sz -le 48) $sz   # bolder drawing for the small sizes, each drawn natively at its own size
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
[System.IO.File]::WriteAllBytes((Join-Path $OutDir 'app.ico'), $out.ToArray())
$bmp.Dispose()
Write-Output "Wrote $OutDir\app.ico and app.png"
