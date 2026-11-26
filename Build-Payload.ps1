# Builds the offline "payload" folder from files already on THIS PC. Nothing is downloaded.
# Run this on your own PC before sharing the installer folder.
param(
    [string]$InstallerSource = "$env:USERPROFILE\Downloads\pyrevit_setup",
    [string]$ExtensionSource = "$PSScriptRoot\extension\mcp-server-for-revit-python.extension",
    [string]$PythonSource    = "$env:APPDATA\uv\python\cpython-3.13-windows-x86_64-none"
)
$ErrorActionPreference = 'Stop'
$payload = Join-Path $PSScriptRoot 'payload'

foreach ($p in $InstallerSource, $PythonSource) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Not found: $p" }
}

Write-Host '1/3 pyRevit installers'
New-Item -ItemType Directory -Force "$payload\pyrevit" | Out-Null
foreach ($name in 'pyRevit_7.1.0.26319_signed.exe', 'pyRevit_6.5.5.26237_signed.exe') {
    $src = Join-Path $InstallerSource $name
    $sig = Get-AuthenticodeSignature -LiteralPath $src
    if ($sig.Status -ne 'Valid') { throw "Signature of $name is $($sig.Status)" }
    Copy-Item -LiteralPath $src -Destination "$payload\pyrevit\$name" -Force
}

Write-Host '2/3 MCP extension'
$extDest = "$payload\extension\mcp-server-for-revit-python.extension"
if (Test-Path -LiteralPath (Join-Path $ExtensionSource 'revit_mcp\security.py')) {
    if (Test-Path -LiteralPath $extDest) { Remove-Item -LiteralPath $extDest -Recurse -Force }
    robocopy $ExtensionSource $extDest /MIR /XD .git .venv __pycache__ .pytest_cache tests /XF *.bak *.pyc /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Copying the extension failed (robocopy $LASTEXITCODE)" }
} elseif (Test-Path -LiteralPath (Join-Path $extDest 'revit_mcp\security.py')) {
    Write-Host "    No protected extension at $ExtensionSource, so the copy already in the payload is kept."
} else {
    throw "No MCP extension with the security key found at $ExtensionSource or in the payload."
}

Write-Host '3/3 Portable Python'
$pyDest = "$payload\python"
if (Test-Path -LiteralPath $pyDest) { Remove-Item -LiteralPath $pyDest -Recurse -Force }
robocopy $PythonSource $pyDest /MIR /XD __pycache__ /XF *.pyc /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "Copying Python failed (robocopy $LASTEXITCODE)" }

# Versions come from requirements.pinned.txt. --offline: use only the wheels folder and the uv cache.
$pinned = Join-Path $PSScriptRoot 'requirements.pinned.txt'
$wheels = Join-Path $PSScriptRoot 'wheels'
if (-not (Test-Path -LiteralPath $pinned)) { throw "Not found: $pinned" }
New-Item -ItemType Directory -Force $wheels | Out-Null
# uv prints progress to stderr, which must not count as a PowerShell error.
$ErrorActionPreference = 'Continue'
& uv pip install --offline --break-system-packages --link-mode copy --python "$pyDest\python.exe" --find-links $wheels -r $pinned
if ($LASTEXITCODE -ne 0) { throw 'Offline package install failed. A pinned package is not in the wheels folder or uv cache.' }
& uv pip check --python "$pyDest\python.exe"
if ($LASTEXITCODE -ne 0) { throw 'The installed packages are not compatible with each other.' }
& "$pyDest\python.exe" -I -B -c "import httpx; from mcp.server.fastmcp import FastMCP; print('Portable Python OK')"
if ($LASTEXITCODE -ne 0) { throw 'Portable Python cannot import the MCP packages.' }

$mb = (Get-ChildItem $payload -Recurse -File | Measure-Object Length -Sum).Sum / 1MB
# Record what was really installed.
& uv pip freeze --quiet --python "$pyDest\python.exe" | Set-Content -LiteralPath "$payload\requirements.lock.txt" -Encoding ascii
Write-Host ('Payload ready: {0:N0} MB in {1}' -f $mb, $payload)
