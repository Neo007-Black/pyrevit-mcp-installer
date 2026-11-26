# Packs the installer and payload into one EXE. Uses only tools that ship with Windows.
# Run Build-Payload.ps1 first.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$root = $PSScriptRoot
$dist = Join-Path $root 'dist'
$zipPath = Join-Path $dist 'setup.zip'
$exe = Join-Path $dist 'PyRevitMCP-Setup.exe'
$csc = "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path -LiteralPath $csc)) { throw "C# compiler not found: $csc" }
foreach ($need in 'payload\pyrevit', 'payload\python\python.exe', 'payload\extension', 'assets\startup.wav', 'assets\app.ico') {
    if (-not (Test-Path -LiteralPath (Join-Path $root $need))) { throw "Missing: $need" }
}
New-Item -ItemType Directory -Force $dist | Out-Null
Remove-Item -LiteralPath $zipPath, $exe -Force -ErrorAction SilentlyContinue

Write-Host '1/2 Compressing files'
$files = @(Get-Item -LiteralPath (Join-Path $root 'Installer.ps1'))
$files += Get-Item -LiteralPath (Join-Path $root 'THIRD-PARTY-NOTICES.md')
foreach ($d in 'lib', 'assets', 'licenses', 'payload') { $files += Get-ChildItem -LiteralPath (Join-Path $root $d) -Recurse -File -Force }
$zip = [IO.Compression.ZipFile]::Open($zipPath, 'Create')
try {
    foreach ($f in $files) {
        if ($f.FullName -match '\\__pycache__\\') { continue }
        $name = $f.FullName.Substring($root.Length + 1).Replace('\', '/')
        $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $name, 'Optimal')
    }
} finally { $zip.Dispose() }

Write-Host '2/2 Building the EXE'
& $csc /nologo /target:winexe /platform:anycpu /optimize+ "/out:$exe" "/win32manifest:$root\exe\app.manifest" "/win32icon:$root\assets\app.ico" `
    "/resource:$zipPath,setup.zip" /r:System.IO.Compression.dll /r:System.Windows.Forms.dll /r:System.Drawing.dll "$root\exe\Launcher.cs"
if ($LASTEXITCODE -ne 0) { throw 'Compiling the EXE failed.' }
Remove-Item -LiteralPath $zipPath -Force

$hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
"$hash  $(Split-Path -Leaf $exe)" | Set-Content -LiteralPath "$exe.sha256.txt" -Encoding ascii
Write-Host ('Built {0} ({1:N0} MB)' -f $exe, ((Get-Item -LiteralPath $exe).Length / 1MB))
Write-Host "SHA-256 $hash"
