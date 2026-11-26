# Creates assets\startup.wav (an original four-note chime). Run again after changing the notes.
# You can also replace assets\startup.wav with your own .wav file, or delete it for a silent start.
$ErrorActionPreference = 'Stop'
$rate = 44100; $length = 2.0; $volume = 0.22
$notes = @(                       # frequency in Hz, start time in seconds
    @(523.25, 0.00),   # C5
    @(659.25, 0.14),   # E5
    @(783.99, 0.28),   # G5
    @(1046.50, 0.46)   # C6
)
$count = [int]($rate * $length)
$mix = New-Object double[] $count
foreach ($n in $notes) {
    $freq = $n[0]; $first = [int]($rate * $n[1])
    for ($i = $first; $i -lt $count; $i++) {
        $t = ($i - $first) / $rate
        $env = [Math]::Min(1.0, $t / 0.012) * [Math]::Exp(-3.2 * $t)
        $w = 2 * [Math]::PI * $freq * $t
        $mix[$i] += $env * ([Math]::Sin($w) + 0.25 * [Math]::Sin(2 * $w))
    }
}
$dir = Join-Path $PSScriptRoot 'assets'
New-Item -ItemType Directory -Force $dir | Out-Null
$out = New-Object IO.BinaryWriter ([IO.File]::Create((Join-Path $dir 'startup.wav')))
$bytes = $count * 2
$out.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $out.Write([int](36 + $bytes))
$out.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt ')); $out.Write([int]16)
$out.Write([int16]1); $out.Write([int16]1); $out.Write([int]$rate); $out.Write([int]($rate * 2))
$out.Write([int16]2); $out.Write([int16]16)
$out.Write([Text.Encoding]::ASCII.GetBytes('data')); $out.Write([int]$bytes)
$fade = [int]($rate * 0.15)
for ($i = 0; $i -lt $count; $i++) {
    $tail = [Math]::Min(1.0, ($count - $i) / $fade)
    $v = [Math]::Max(-1.0, [Math]::Min(1.0, $mix[$i] * $volume * $tail))
    $out.Write([int16]($v * 32767))
}
$out.Close()
Write-Host "Created $dir\startup.wav"
