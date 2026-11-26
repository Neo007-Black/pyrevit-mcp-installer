# Draws assets\app.ico (blue MCP badge, same look as the opening animation).
# You can replace assets\app.ico with your own icon, then run Build-Exe.ps1 again.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function New-Badge([int]$Size) {
    $bmp = New-Object Drawing.Bitmap $Size, $Size, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'; $g.Clear([Drawing.Color]::Transparent)
    $s = [single]$Size

    # dark rounded square
    $r = $s * 0.22; $d = 2 * $r; $edge = $s - 1
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, $d, $d, 180, 90); $path.AddArc($edge - $d, 0, $d, $d, 270, 90)
    $path.AddArc($edge - $d, $edge - $d, $d, $d, 0, 90); $path.AddArc(0, $edge - $d, $d, $d, 90, 90); $path.CloseFigure()
    $g.FillPath((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 31, 42, 68))), $path)

    # dashed ring only where there are enough pixels
    $inset = 0.10
    if ($Size -ge 48) {
        $pen = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(255, 110, 160, 255)), ($s * 0.035)
        foreach ($a in 0..5) { $g.DrawArc($pen, $s * 0.09, $s * 0.09, $s * 0.82, $s * 0.82, [single]($a * 60 - 80), [single]40) }
        $inset = 0.17
    }
    $blue = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 47, 111, 237))
    $g.FillEllipse($blue, $s * $inset, $s * $inset, $s * (1 - 2 * $inset), $s * (1 - 2 * $inset))

    # "MCP" is unreadable when tiny, so small sizes show "M"
    if ($Size -ge 32) { $text = 'MCP'; $height = $s * 0.215 } else { $text = 'M'; $height = $s * 0.55 }
    $font = New-Object Drawing.Font 'Segoe UI', $height, ([Drawing.FontStyle]::Bold), ([Drawing.GraphicsUnit]::Pixel)
    $format = New-Object Drawing.StringFormat ([Drawing.StringFormat]::GenericTypographic)
    $format.Alignment = 'Center'; $format.LineAlignment = 'Center'
    $g.DrawString($text, $font, [Drawing.Brushes]::White, (New-Object Drawing.RectangleF 0, 0, $s, $s), $format)
    $g.Dispose()
    $bmp
}

# Small sizes are stored as plain bitmaps (understood everywhere); 256 px is stored as PNG.
function Get-ImageBytes($Bmp) {
    $ms = New-Object IO.MemoryStream
    if ($Bmp.Width -ge 256) { $Bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); return , $ms.ToArray() }
    $w = New-Object IO.BinaryWriter $ms
    $n = $Bmp.Width
    $w.Write([int]40); $w.Write([int]$n); $w.Write([int]($n * 2)); $w.Write([int16]1); $w.Write([int16]32)
    foreach ($i in 1..6) { $w.Write([int]0) }
    for ($y = $n - 1; $y -ge 0; $y--) { for ($x = 0; $x -lt $n; $x++) { $w.Write([int]$Bmp.GetPixel($x, $y).ToArgb()) } }
    $maskRow = [int][Math]::Floor(($n + 31) / 32) * 4
    $w.Write((New-Object byte[] ($maskRow * $n)))
    $w.Flush()
    return , $ms.ToArray()
}

$sizes = 16, 24, 32, 48, 64, 128, 256
$images = foreach ($z in $sizes) { $b = New-Badge $z; [pscustomobject]@{ Size = $z; Bytes = (Get-ImageBytes $b) }; if ($z -eq 256) { $script:preview = $b } }
$dir = Join-Path $PSScriptRoot 'assets'
New-Item -ItemType Directory -Force $dir | Out-Null
$out = New-Object IO.BinaryWriter ([IO.File]::Create((Join-Path $dir 'app.ico')))
$out.Write([int16]0); $out.Write([int16]1); $out.Write([int16]$images.Count)
$offset = 6 + 16 * $images.Count
foreach ($i in $images) {
    $side = [byte]($i.Size % 256)
    $out.Write($side); $out.Write($side); $out.Write([byte]0); $out.Write([byte]0)
    $out.Write([int16]1); $out.Write([int16]32); $out.Write([int]$i.Bytes.Length); $out.Write([int]$offset)
    $offset += $i.Bytes.Length
}
foreach ($i in $images) { $out.Write([byte[]]$i.Bytes) }
$out.Close()
$script:preview.Save((Join-Path $dir 'app-icon-preview.png'), [Drawing.Imaging.ImageFormat]::Png)
Write-Host "Created $dir\app.ico"
