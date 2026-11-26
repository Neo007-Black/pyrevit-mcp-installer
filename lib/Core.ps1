# Installer logic. The UI (Installer.ps1) only calls the functions in this file.
$ErrorActionPreference = 'Stop'

$script:Root       = Split-Path -Parent $PSScriptRoot
$script:Payload    = Join-Path $script:Root 'payload'
$script:ModernExe  = 'pyRevit_7.1.0.26319_signed.exe'
$script:LegacyExe  = 'pyRevit_6.5.5.26237_signed.exe'
$script:ModernVer  = '7.1.0.26319'
# Only these exact setup files are ever run. Update the values when you change versions.
$script:Hashes     = @{
    'pyRevit_7.1.0.26319_signed.exe' = '5F98862360DAADCF728617414816DF8406C19080E47847041DF62382A2577381'
    'pyRevit_6.5.5.26237_signed.exe' = '1E68BF525FCE2E94D70F8E4F9D8A1D2489C86B1F7C79E75BBD65932D91D4A8D6'
}
$script:ExtName    = 'mcp-server-for-revit-python.extension'
$script:Logger     = { param($m) Write-Host $m }
$script:Pump       = { }

function Write-Log([string]$Message) { & $script:Logger $Message }

# ---------- paths ----------
function Get-Paths {
    $home7 = Join-Path $env:APPDATA 'pyRevit-Master'
    $home6 = Join-Path $env:APPDATA 'pyRevit-6.5.5'
    $data  = Join-Path $env:LOCALAPPDATA 'PyRevitMCP'
    [pscustomobject]@{
        ModernHome = $home7
        LegacyHome = $home6
        ModernCli  = Join-Path $home7 'bin\pyrevit.exe'
        LegacyCli  = Join-Path $home6 'bin\pyrevit.exe'
        Config     = Join-Path $env:APPDATA 'pyRevit\pyRevit_config.ini'
        Extension  = Join-Path $env:APPDATA "pyRevit\Extensions\$($script:ExtName)"
        Data       = $data
        Python     = Join-Path $data 'python\python.exe'
        State      = Join-Path $data 'install-state.json'
    }
}

# ---------- detection ----------
function Get-RevitVersions {
    foreach ($year in 2017..2035) {
        if (Test-Path -LiteralPath "$env:ProgramFiles\Autodesk\Revit $year\Revit.exe") {
            $kind = if ($year -ge 2021) { 'Modern' } elseif ($year -ge 2019) { 'Legacy' } else { 'Unsupported' }
            [pscustomobject]@{ Year = $year; Kind = $kind }
        }
    }
}

# Leftover files after a failed removal do not count as an installation.
function Test-PyRevitInstalled([string]$Folder) {
    (Test-Path -LiteralPath (Join-Path $Folder 'bin\pyrevit.exe')) -and (Test-Path -LiteralPath (Join-Path $Folder 'pyrevitlib'))
}

# Programs running from a folder keep its files locked.
function Get-ProgramsUsing([string]$Folder) {
    @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path -like "$Folder\*" })
}
function Get-InUseMessage([string]$Folder) {
    $busy = @(Get-ProgramsUsing $Folder)
    if (-not $busy.Count) { return $null }
    $names = @($busy | ForEach-Object { "$($_.ProcessName) (process $($_.Id))" }) -join ', '
    "pyRevit files are in use by $names. Quit Claude completely (also from the tray), then try again."
}

function Get-PyRevitVersion([string]$Cli) {
    if (-not (Test-PyRevitInstalled (Split-Path -Parent (Split-Path -Parent $Cli)))) { return $null }
    $out = & $Cli --version
    if (($out -join ' ') -match 'v(\d+\.\d+\.\d+\.\d+)') { return $Matches[1] }
    return 'unknown'
}

# Which pyRevit each Revit version loads now, for this user and for all users.
function Get-PyRevitAttachments([int[]]$Years) {
    foreach ($y in $Years) {
        foreach ($scope in @(@('User', $env:APPDATA), @('AllUsers', $env:ProgramData))) {
            $dir = Join-Path $scope[1] "Autodesk\Revit\Addins\$y"
            foreach ($file in @(Get-ChildItem -LiteralPath $dir -Filter '*pyRevit*.addin' -File -ErrorAction SilentlyContinue)) {
                if ([IO.File]::ReadAllText($file.FullName) -notmatch '<Assembly>\s*(.*?)\s*</Assembly>') { continue }
                $dll = $Matches[1]
                if (-not [IO.Path]::IsPathRooted($dll)) { $dll = Join-Path $dir $dll }
                if (-not (Test-Path -LiteralPath $dll)) { continue }   # leftover file pointing nowhere
                $folder = if ($dll -match '^(.*?)\\bin\\') { $Matches[1] } else { Split-Path -Parent $dll }
                [pscustomobject]@{ Year = $y; Scope = $scope[0]; Folder = $folder; File = $file.FullName }
            }
        }
    }
}

# Folders a running Claude Desktop was started with (--user-data-dir).
function Get-ClaudeDataDirsInUse {
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='Claude.exe'" -ErrorAction SilentlyContinue)) {
        if ($p.CommandLine -match '--user-data-dir=(?:"([^"]+)"|(\S+))') { "$($Matches[1])$($Matches[2])" }
    }
}

function Get-DesktopConfigPaths {
    # Newer builds keep their own data folder; the app reads the config from there.
    $dirs = @(Get-ClaudeDataDirsInUse)
    $data = Join-Path $env:LOCALAPPDATA 'Claude-Data'
    if (Test-Path -LiteralPath $data) {
        $dirs += @(Get-ChildItem -LiteralPath $data -Directory -Filter 'claude*' | ForEach-Object { $_.FullName })
    }
    $own = @($dirs | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ 'claude_desktop_config.json')) } |
             ForEach-Object { Join-Path $_ 'claude_desktop_config.json' } | Sort-Object -Unique)
    if ($own.Count) { return $own }

    $list = @()
    # Microsoft Store (MSIX) build keeps its own copy of AppData.
    $packages = Join-Path $env:LOCALAPPDATA 'Packages'
    if (Test-Path -LiteralPath $packages) {
        foreach ($d in Get-ChildItem -LiteralPath $packages -Directory -Filter 'Claude_*') {
            $list += Join-Path $d.FullName 'LocalCache\Roaming\Claude\claude_desktop_config.json'
        }
    }
    # Classic installer build.
    $classicApp = Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'AnthropicClaude')
    $classicDir = Join-Path $env:APPDATA 'Claude'
    if ($classicApp -or ($list.Count -eq 0 -and (Test-Path -LiteralPath $classicDir))) {
        $list += Join-Path $classicDir 'claude_desktop_config.json'
    }
    return $list
}

# Claude Desktop rewrites its config while running, which would undo our change.
# (claude.exe from Claude Code has a different path and is not counted.)
function Test-ClaudeDesktopRunning {
    [bool]@(Get-Process -Name Claude -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -like '*\WindowsApps\Claude_*' -or $_.Path -like '*\AnthropicClaude\*' }).Count
}
function Get-ClaudeCode {
    $cmd = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $local = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    if (Test-Path -LiteralPath $local) { return $local }
    return $null
}

# ---------- helpers ----------
function Write-TextAtomic([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Force (Split-Path -Parent $Path) | Out-Null
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, $Text, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Invoke-Tool([string]$File, [string[]]$Arguments, [switch]$AllowFailure) {
    $quoted = foreach ($a in $Arguments) {
        if ($a -match '\s' -and $a -notmatch '"') { '"' + $a + '"' } else { $a }
    }
    $out = [IO.Path]::GetTempFileName(); $err = [IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath $File -ArgumentList ($quoted -join ' ') -PassThru -WindowStyle Hidden `
                           -RedirectStandardOutput $out -RedirectStandardError $err
        $null = $p.Handle   # keeps ExitCode readable in Windows PowerShell 5.1
        while (-not $p.HasExited) { & $script:Pump; Start-Sleep -Milliseconds 150 }
        $text = ((Get-Content -LiteralPath $out) + (Get-Content -LiteralPath $err)) -join "`n"
        if ($p.ExitCode -ne 0 -and -not $AllowFailure) {
            throw "$(Split-Path -Leaf $File) failed with exit code $($p.ExitCode). $text"
        }
        [pscustomobject]@{ ExitCode = $p.ExitCode; Output = $text }
    } finally {
        Remove-Item -LiteralPath $out, $err -Force -ErrorAction SilentlyContinue
    }
}

# Changes one key and leaves every other line of the file as it was.
function Set-IniValue([string]$Path, [string]$Section, [string]$Key, [string]$Value) {
    $lines = New-Object Collections.Generic.List[string]
    if (Test-Path -LiteralPath $Path) { $lines.AddRange([string[]][IO.File]::ReadAllLines($Path)) }
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -eq "[$Section]") { $start = $i; break } }
    if ($start -lt 0) {
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1].Trim()) { $lines.Add('') }
        $lines.Add("[$Section]"); $lines.Add("$Key = $Value")
    } else {
        $done = $false; $end = $lines.Count
        for ($i = $start + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*\[') { $end = $i; break }
            if ($lines[$i] -match ('^\s*' + [regex]::Escape($Key) + '\s*=')) { $lines[$i] = "$Key = $Value"; $done = $true; break }
        }
        if (-not $done) {
            while ($end -gt $start + 1 -and -not $lines[$end - 1].Trim()) { $end-- }
            $lines.Insert($end, "$Key = $Value")
        }
    }
    Write-TextAtomic $Path (($lines -join "`r`n") + "`r`n")
}

function Get-IniValue([string]$Path, [string]$Section, [string]$Key) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $inside = $false
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line -match '^\s*\[(.*)\]\s*$') { $inside = ($Matches[1] -eq $Section); continue }
        if ($inside -and $line -match ('^\s*' + [regex]::Escape($Key) + '\s*=\s*(.*)$')) { return $Matches[1].Trim() }
    }
    return $null
}

# ---------- install state (used by Uninstall) ----------
function Read-State {
    $path = (Get-Paths).State
    $state = [ordered]@{ desktop = @(); code = @(); routesBefore = $null; agentBefore = $null; python = $false; extension = $false
                         pyrevit = @(); addins = @(); appDataExisted = $null }
    if (Test-Path -LiteralPath $path) {
        $saved = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in @($state.Keys)) { if ($null -ne $saved.$k) { $state[$k] = $saved.$k } }
        foreach ($k in 'desktop', 'code', 'pyrevit', 'addins') { $state[$k] = @($state[$k]) }
    }
    return $state
}
function Save-State($State) { Write-TextAtomic (Get-Paths).State ($State | ConvertTo-Json -Depth 6) }

# Notes how each Revit version was set up before the first install.
function Save-Baseline([int[]]$Years) {
    $s = Read-State
    if ($null -eq $s.appDataExisted) { $s.appDataExisted = Test-Path -LiteralPath (Join-Path $env:APPDATA 'pyRevit') }
    foreach ($y in $Years) {
        if (@($s.addins | Where-Object { $_.year -eq $y }).Count) { continue }
        $f = Get-AddinFile $y
        $data = if (Test-Path -LiteralPath $f) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($f)) } else { '' }
        $s.addins = @($s.addins) + [pscustomobject]@{ year = $y; data = $data }
    }
    Save-State $s
}
function Add-InstalledPyRevit([string]$Name) {
    $s = Read-State; $s.pyrevit = @(@($s.pyrevit) + $Name | Select-Object -Unique); Save-State $s
}

# ---------- Claude Desktop ----------
function Read-DesktopConfig([string]$Path) {
    $raw = ''
    if (Test-Path -LiteralPath $Path) { $raw = [IO.File]::ReadAllText($Path) }
    if (-not $raw.Trim()) { return [pscustomobject]@{} }
    try { return ($raw | ConvertFrom-Json) }
    catch { throw "Claude config is not valid JSON, so it was left untouched: $Path" }
}

# Returns $true when the entry did not exist before.
function Set-DesktopServer([string]$Path, [string]$Name, [string]$Command, [string[]]$Arguments) {
    $config = Read-DesktopConfig $Path
    if (-not $config.PSObject.Properties['mcpServers']) {
        $config | Add-Member -NotePropertyName mcpServers -NotePropertyValue ([pscustomobject]@{})
    }
    $isNew = -not $config.mcpServers.PSObject.Properties[$Name]
    $entry = [pscustomobject]@{ command = $Command; args = @($Arguments) }
    $config.mcpServers | Add-Member -NotePropertyName $Name -NotePropertyValue $entry -Force
    Write-TextAtomic $Path ($config | ConvertTo-Json -Depth 32)
    return $isNew
}

function Remove-DesktopServer([string]$Path, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $config = Read-DesktopConfig $Path
    if ($config.PSObject.Properties['mcpServers'] -and $config.mcpServers.PSObject.Properties[$Name]) {
        $config.mcpServers.PSObject.Properties.Remove($Name)
        Write-TextAtomic $Path ($config | ConvertTo-Json -Depth 32)
    }
}

# ---------- pyRevit ----------
function Install-PyRevit([string]$ExeName, [string]$Destination) {
    $exe = Join-Path $script:Payload "pyrevit\$ExeName"
    if ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ne $script:Hashes[$ExeName]) {
        throw "$ExeName is not the expected file. Not running it."
    }
    $sig = Get-AuthenticodeSignature -LiteralPath $exe
    if ($sig.Status -ne 'Valid') { throw "Signature of $ExeName is $($sig.Status). Not running it." }
    $log = Join-Path (Get-Paths).Data "$ExeName.log"
    New-Item -ItemType Directory -Force (Split-Path -Parent $log) | Out-Null
    Invoke-Tool $exe @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/DIR=`"$Destination`"", "/LOG=`"$log`"") | Out-Null
}

function Get-AddinFile([int]$Year) { Join-Path $env:APPDATA "Autodesk\Revit\Addins\$Year\pyRevit.addin" }

function Get-AddinSnapshot([int[]]$Years) {
    $snap = @{}
    foreach ($y in $Years) {
        $f = Get-AddinFile $y
        $snap[$y] = if (Test-Path -LiteralPath $f) { [IO.File]::ReadAllBytes($f) } else { $null }
    }
    return $snap
}

# Puts Revit versions the user did NOT select back to how they were.
function Restore-AddinSnapshot($Snapshot) {
    foreach ($y in $Snapshot.Keys) {
        $f = Get-AddinFile $y
        if ($null -ne $Snapshot[$y]) {
            New-Item -ItemType Directory -Force (Split-Path -Parent $f) | Out-Null
            [IO.File]::WriteAllBytes($f, $Snapshot[$y])
        } elseif (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
    }
}

function Connect-Clone([string]$Cli, [string]$CloneName, [int]$Year) {
    $listed = (Invoke-Tool $Cli @('env') -AllowFailure).Output
    $cloneHome = Split-Path -Parent (Split-Path -Parent $Cli)
    $name = $CloneName
    if ($listed -match ('(?m)^(\S+) \|.*Path: "' + [regex]::Escape($cloneHome) + '"')) { $name = $Matches[1] }
    else { Invoke-Tool $Cli @('clones', 'add', 'this', $name, '--force') | Out-Null }
    Invoke-Tool $Cli @('attach', $name, 'default', "$Year") | Out-Null
}

# Takes a folder off the user PATH without expanding %VARIABLES% in other entries.
function Remove-FromUserPath([string]$Pattern) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    try {
        $value = $key.GetValue('Path', $null, 'DoNotExpandEnvironmentNames')
        if (-not $value) { return }
        $kept = ($value -split ';' | Where-Object { $_ -and $_ -notlike $Pattern }) -join ';'
        if ($kept -ne $value.TrimEnd(';')) { $key.SetValue('Path', $kept, $key.GetValueKind('Path')) }
    } finally { $key.Close() }
}

# ---------- plan ----------
# Values a step needs are passed in $Data. (Closures cannot see this file's functions.)
function New-Step([string]$Text, [scriptblock]$Action, $Data) { [pscustomobject]@{ Text = $Text; Action = $Action; Data = $Data } }

# Revit 2019-2020 always use the Routes method. Revit 2021+ can use Agent MCP, Routes, or both.
function Get-InstallPlan([int[]]$Years, [bool]$UseDesktop, [bool]$UseCode, [bool]$ModernAgent = $true, [bool]$ModernRoutes = $false) {
    $paths = Get-Paths
    $installed = @(Get-RevitVersions)
    $modern = @($installed | Where-Object { $_.Kind -eq 'Modern' -and $Years -contains $_.Year } | ForEach-Object { $_.Year })
    $legacy = @($installed | Where-Object { $_.Kind -eq 'Legacy' -and $Years -contains $_.Year } | ForEach-Object { $_.Year })
    $problems = @(); $warnings = @(); $steps = @()

    if (-not ($modern.Count + $legacy.Count)) { $problems += 'Select at least one Revit version.' }
    if ($modern.Count -and -not ($ModernAgent -or $ModernRoutes)) { $problems += 'Choose an MCP method for Revit 2021 and newer.' }
    $agentYears = @(if ($ModernAgent) { $modern })
    $routesYears = @($legacy) + @(if ($ModernRoutes) { $modern })
    if (Get-Process -Name Revit -ErrorAction SilentlyContinue) { $problems += 'Revit is running. Save your work and close all Revit windows.' }

    $modernVersion = Get-PyRevitVersion $paths.ModernCli
    $needModern = $modern.Count -and (-not $modernVersion -or $modernVersion -eq 'unknown' -or [version]$modernVersion -lt [version]'7.0.0.0')
    $needLegacy = $legacy.Count -and -not (Test-PyRevitInstalled $paths.LegacyHome)
    foreach ($pair in @(@($needModern, $paths.ModernHome), @($needLegacy, $paths.LegacyHome), @(($needLegacy -and $modernVersion -eq $script:ModernVer), $paths.ModernHome))) {
        if ($pair[0]) { $message = Get-InUseMessage $pair[1]; if ($message -and $problems -notcontains $message) { $problems += $message } }
    }

    # ---- what the user already has ----
    $confirm = @()
    $attached = @(Get-PyRevitAttachments ([int[]]@($modern + $legacy)))
    foreach ($a in @($attached | Where-Object { $_.Scope -eq 'AllUsers' })) {
        $problems += "Revit $($a.Year) already loads a pyRevit installed for all users ($($a.Folder)). Two copies would conflict. Untick Revit $($a.Year), or have an administrator remove that pyRevit first. File: $($a.File)"
    }
    foreach ($a in @($attached | Where-Object { $_.Scope -eq 'User' })) {
        $ours = if ($modern -contains $a.Year) { $paths.ModernHome } else { $paths.LegacyHome }
        if ($a.Folder -ne $ours) {
            $confirm += "Revit $($a.Year) now uses pyRevit in $($a.Folder). It will be switched to $ours. The old folder is not deleted."
        }
    }
    if ($needModern -and $modernVersion) {
        $old = if ($modernVersion -eq 'unknown') { 'an older version' } else { $modernVersion }
        $confirm += "UPGRADE: pyRevit ($old) in $($paths.ModernHome) will be replaced by $($script:ModernVer). Uninstall cannot bring the old version back."
    }
    if ($needLegacy -and $modernVersion -and $modernVersion -ne 'unknown' -and [version]$modernVersion -lt [version]'7.0.0.0' -and -not $needModern) {
        $confirm += "Your pyRevit $modernVersion stays, and a separate 6.5.5 is installed for the Revit 2019-2020 versions you ticked."
    }
    $warnings += $confirm

    $required = @()
    if ($needModern) { $required += "pyrevit\$($script:ModernExe)" }
    if ($needLegacy) {
        $required += "pyrevit\$($script:LegacyExe)"
        if ($modernVersion -eq $script:ModernVer) { $required += "pyrevit\$($script:ModernExe)" }
    }
    if ($routesYears.Count) { $required += 'python\python.exe', "extension\$($script:ExtName)\main.py" }
    foreach ($r in ($required | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath (Join-Path $script:Payload $r))) { $problems += "Missing from the package: payload\$r" }
    }

    $untouched = [int[]]@($installed | Where-Object { $_.Kind -ne 'Unsupported' -and $Years -notcontains $_.Year } | ForEach-Object { $_.Year })
    $context = @{ Years = $untouched; Snapshot = $null }

    $allYears = [int[]]@($installed | Where-Object { $_.Kind -ne 'Unsupported' } | ForEach-Object { $_.Year })
    $steps += New-Step 'Record the current setup (used by Uninstall)' { param($d) Save-Baseline $d } $allYears
    if ($needLegacy -or $needModern) {
        $steps += New-Step 'Remember pyRevit settings of the Revit versions you did not select' {
            param($d) $d.Snapshot = Get-AddinSnapshot $d.Years } $context
    }
    if ($needLegacy) {
        $steps += New-Step 'Install pyRevit 6.5.5 (for Revit 2019-2020)' {
            Install-PyRevit $script:LegacyExe (Get-Paths).LegacyHome; Add-InstalledPyRevit 'legacy' }
    }
    if ($needModern) {
        # An upgraded older pyRevit belonged to the user, so Uninstall will not remove it.
        $title = if ($modernVersion) { "UPGRADE existing pyRevit to 7.1 (for Revit 2021 and newer)" } else { 'Install pyRevit 7.1 (for Revit 2021 and newer)' }
        $steps += New-Step $title {
            param($d)
            Install-PyRevit $script:ModernExe (Get-Paths).ModernHome
            if ($d) { Add-InstalledPyRevit 'modern' } } (-not $modernVersion)
    } elseif ($needLegacy -and $modernVersion) {
        if ($modernVersion -eq $script:ModernVer) {
            $steps += New-Step 'Re-install pyRevit 7.1 so it stays the main version' { Install-PyRevit $script:ModernExe (Get-Paths).ModernHome }
        } else {
            $warnings += "pyRevit $modernVersion is already installed. Installing 6.5.5 may change which one is the main version; check it afterwards."
        }
    }
    if ($needLegacy -or $needModern) {
        $steps += New-Step 'Keep unselected Revit versions as they were' { param($d) Restore-AddinSnapshot $d.Snapshot } $context
    }
    if ($needLegacy) { $steps += New-Step 'Remove the 6.5.5 folder from your PATH' { Remove-FromUserPath '*pyRevit-6.5.5*' } }

    foreach ($y in $legacy) {
        $steps += New-Step "Attach pyRevit 6.5.5 to Revit $y" { param($d) Connect-Clone (Get-Paths).LegacyCli 'pyrevit655' $d } $y
    }
    foreach ($y in $modern) {
        $steps += New-Step "Attach pyRevit 7 to Revit $y" { param($d) Connect-Clone (Get-Paths).ModernCli 'master' $d } $y
    }

    $servers = @()
    if ($agentYears.Count) {
        $steps += New-Step "Agent MCP: turn on for Revit $($agentYears -join ', ') (changes need your approval)" {
            $ini = (Get-Paths).Config
            $s = Read-State
            if ($null -eq $s.agentBefore) { $s.agentBefore = [string](Get-IniValue $ini 'agent' 'enabled'); Save-State $s }
            Set-IniValue $ini 'agent' 'enabled' 'true'
            if (-not (Get-IniValue $ini 'agent' 'policy')) { Set-IniValue $ini 'agent' 'policy' '"ask"' }
        }
        $servers += [pscustomobject]@{ Name = 'pyrevit'; Command = $paths.ModernCli; Args = @('mcp') }
    }
    if ($routesYears.Count) {
        if (Test-Path -LiteralPath $paths.Extension) {
            if (Test-Path -LiteralPath (Join-Path $paths.Extension 'revit_mcp\security.py')) {
                $warnings += 'The MCP extension is already installed. Your copy is kept.'
            } else {
                $problems += "An older MCP extension without the security key is installed. Rename or remove this folder, then try again: $($paths.Extension)"
            }
        } else {
            $steps += New-Step 'Copy the MCP extension' {
                $to = (Get-Paths).Extension
                New-Item -ItemType Directory -Force (Split-Path -Parent $to) | Out-Null
                Copy-Item -LiteralPath (Join-Path $script:Payload "extension\$($script:ExtName)") -Destination $to -Recurse
                $s = Read-State; $s.extension = $true; Save-State $s
            }
        }
        $steps += New-Step 'Copy portable Python' {
            $to = Split-Path -Parent (Get-Paths).Python
            $r = Invoke-Tool "$env:SystemRoot\System32\robocopy.exe" @((Join-Path $script:Payload 'python'), $to, '/E', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP') -AllowFailure
            if ($r.ExitCode -ge 8) { throw "Copying Python failed. Close Claude and try again. $($r.Output)" }
            $s = Read-State; $s.python = $true; Save-State $s
        }
        $steps += New-Step "Routes: turn on for Revit $($routesYears -join ', '), this computer only (localhost:48884)" {
            $ini = (Get-Paths).Config
            $s = Read-State
            if ($null -eq $s.routesBefore) { $s.routesBefore = [string](Get-IniValue $ini 'routes' 'enabled'); Save-State $s }
            Set-IniValue $ini 'routes' 'host' '"localhost"'
            Set-IniValue $ini 'routes' 'port' '48884'
            Set-IniValue $ini 'routes' 'core_api' 'false'   # its reload command has no password
            Set-IniValue $ini 'routes' 'enabled' 'true'
        }
        $servers += [pscustomobject]@{ Name = 'pyrevit-routes'; Command = $paths.Python; Args = @((Join-Path $paths.Extension 'main.py')) }
        $warnings += 'Routes method: run only one Revit at a time (port 48884). It has no Keep/Discard step, so keep Claude permission prompts on. Requests need a secret key that Revit creates.'
        if ($ModernRoutes -and $modern.Count) { $warnings += 'Routes on Revit 2021 and newer (pyRevit 7.1) has not been tested yet.' }
    }

    if ($UseDesktop) {
        $configs = @(Get-DesktopConfigPaths)
        if (-not $configs.Count) { $warnings += 'Claude Desktop was not found. Install it, then run this installer again.' }
        elseif ($servers.Count -and (Test-ClaudeDesktopRunning)) { $problems += 'Claude Desktop is running. Quit it completely (tray icon, Quit), then try again.' }
        foreach ($c in $configs) {
            # Stop early if an existing file cannot be read safely.
            try { $null = Read-DesktopConfig $c } catch { $problems += $_.Exception.Message; continue }
            foreach ($srv in $servers) {
                $steps += New-Step "Claude Desktop: add '$($srv.Name)' to $c" {
                    param($d)
                    if (Set-DesktopServer $d.Path $d.Server.Name $d.Server.Command $d.Server.Args) {
                        $s = Read-State; $s.desktop = @($s.desktop) + [pscustomobject]@{ path = $d.Path; name = $d.Server.Name }; Save-State $s
                    }
                } @{ Path = $c; Server = $srv }
            }
        }
    }
    if ($UseCode) {
        $claude = Get-ClaudeCode
        if (-not $claude) { $warnings += 'Claude Code was not found. Install it, then run this installer again.' }
        else {
            foreach ($srv in $servers) {
                $steps += New-Step "Claude Code: register '$($srv.Name)'" {
                    param($d)
                    $name = $d.Server.Name
                    if ((Invoke-Tool $d.Claude @('mcp', 'get', $name) -AllowFailure).ExitCode -eq 0) {
                        Write-Log "    '$name' is already registered. Left as it is."
                        return
                    }
                    Invoke-Tool $d.Claude (@('mcp', 'add', '-s', 'user', $name, '--', $d.Server.Command) + $d.Server.Args) | Out-Null
                    $s = Read-State; $s.code = @($s.code) + $name; Save-State $s
                } @{ Claude = $claude; Server = $srv }
            }
        }
    }

    [pscustomobject]@{ Problems = $problems; Warnings = $warnings; Steps = $steps; Confirm = $confirm }
}

# An install stops at the first failure. A removal (KeepGoing) finishes the other steps,
# so settings and attachments are still tidied, and reports the failures at the end.
function Invoke-InstallPlan($Plan) {
    $i = 0; $failed = @()
    foreach ($step in $Plan.Steps) {
        $i++
        Write-Log "[$i/$($Plan.Steps.Count)] $($step.Text)"
        & $script:Pump
        try { & $step.Action $step.Data }
        catch {
            if (-not $Plan.KeepGoing) { throw }
            Write-Log "    FAILED: $($_.Exception.Message)"
            $failed += $step.Text
        }
    }
    if ($failed.Count) { throw "$($failed.Count) step(s) failed: $($failed -join '; '). Fix the cause, then run it again." }
}
# ---------- uninstall ----------
function Get-AddinTargetExists([byte[]]$Bytes) {
    if (-not $Bytes) { return $false }
    $text = [Text.Encoding]::UTF8.GetString($Bytes)
    $found = [regex]::Matches($text, '<Assembly>\s*(.*?)\s*</Assembly>')
    if (-not $found.Count) { return $false }
    return (Test-Path -LiteralPath $found[0].Groups[1].Value)
}

# Each Revit version goes back to its earlier pyRevit, or to none if that no longer exists.
function Restore-Attachments($Current) {
    $s = Read-State
    $target = @{}
    foreach ($y in $Current.Keys) { $target[[int]$y] = $Current[$y] }
    foreach ($a in @($s.addins)) {
        $target[[int]$a.year] = if ($a.data) { [Convert]::FromBase64String($a.data) } else { $null }
    }
    foreach ($y in @($target.Keys)) { if (-not (Get-AddinTargetExists $target[$y])) { $target[$y] = $null } }
    Restore-AddinSnapshot $target
    # Keep the record while a pyRevit still waits to be removed, so a second try can use it.
    if (-not @($s.pyrevit).Count) { $s.addins = @(); Save-State $s }
}

function Invoke-PyRevitUninstaller([string]$Folder) {
    $unins = Join-Path $Folder 'unins000.exe'
    $cli = Join-Path $Folder 'bin\pyrevit.exe'
    Invoke-Tool $unins @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') | Out-Null
    # The Windows uninstaller can return before it has finished.
    $limit = (Get-Date).AddMinutes(3); $graceEnd = $null
    while ((Test-Path -LiteralPath $cli) -or (Test-Path -LiteralPath $unins)) {
        if (-not (Test-Path -LiteralPath $unins)) {
            # The uninstaller has finished; give the last files a moment, then report them.
            if (-not $graceEnd) { $graceEnd = (Get-Date).AddSeconds(20) }
            if ((Get-Date) -gt $graceEnd) { throw "pyRevit was only partly removed; files are left in $Folder. They may be in use." }
        }
        if ((Get-Date) -gt $limit) { throw "pyRevit was not removed from $Folder." }
        & $script:Pump; Start-Sleep -Milliseconds 500
    }
}

function Uninstall-PyRevit([string]$Name) {
    $paths = Get-Paths
    $folder = if ($Name -eq 'legacy') { $paths.LegacyHome } else { $paths.ModernHome }
    $message = Get-InUseMessage $folder
    if ($message) { throw $message }
    if (Test-Path -LiteralPath (Join-Path $folder 'unins000.exe')) { Invoke-PyRevitUninstaller $folder }
    if (Test-Path -LiteralPath $folder) { Remove-Item -LiteralPath $folder -Recurse -Force }
    Remove-FromUserPath "*$(Split-Path -Leaf $folder)\*"
    $s = Read-State; $s.pyrevit = @($s.pyrevit | Where-Object { $_ -ne $Name }); Save-State $s
}

# Keeps the shared settings file, minus the pyRevit copies that no longer exist.
function Restore-PyRevitSettings([byte[]]$Bytes) {
    $paths = Get-Paths
    $kept = @($paths.ModernHome, $paths.LegacyHome | Where-Object { Test-Path -LiteralPath $_ })
    $s = Read-State
    $appData = Join-Path $env:APPDATA 'pyRevit'
    $userExtensions = @(Get-ChildItem -LiteralPath (Join-Path $appData 'Extensions') -Force -ErrorAction SilentlyContinue)
    if (-not $kept.Count -and $s.appDataExisted -eq $false -and -not $userExtensions.Count) {
        if (Test-Path -LiteralPath $appData) { Remove-Item -LiteralPath $appData -Recurse -Force }
        return
    }
    if (-not $Bytes) { return }
    [IO.File]::WriteAllBytes($paths.Config, $Bytes)
    $line = Get-IniValue $paths.Config 'environment' 'clones'
    if (-not $line) { return }
    $clones = $line | ConvertFrom-Json
    foreach ($c in @($clones.PSObject.Properties)) {
        if (-not (Test-Path -LiteralPath $c.Value)) { $clones.PSObject.Properties.Remove($c.Name) }
    }
    Set-IniValue $paths.Config 'environment' 'clones' ($clones | ConvertTo-Json -Compress)
}

# Deletes the installer's own folder once there is nothing left to undo.
function Complete-Uninstall {
    $s = Read-State
    $left = @($s.desktop).Count + @($s.code).Count + @($s.pyrevit).Count + @($s.addins).Count
    $data = (Get-Paths).Data
    if (-not $left -and -not $s.python -and -not $s.extension -and $null -eq $s.routesBefore -and $null -eq $s.agentBefore) {
        if (Test-Path -LiteralPath $data) { Remove-Item -LiteralPath $data -Recurse -Force }
        Write-Log '    Nothing from this installer is left.'
    } else {
        Write-Log "    A record is kept in $data for what is still installed."
    }
}

function Test-AttachmentsChanged($State) {
    foreach ($a in @($State.addins)) {
        $f = Get-AddinFile $a.year
        $now = if (Test-Path -LiteralPath $f) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($f)) } else { '' }
        if ($now -cne [string]$a.data) { return $true }
    }
    return $false
}

# Removes only what this installer recorded. Your own extensions are never touched.
function Get-UninstallPlan([bool]$RemoveMcp, [bool]$RemovePyRevit) {
    $paths = Get-Paths
    $problems = @(); $warnings = @(); $steps = @()
    if ($RemovePyRevit) { $RemoveMcp = $true }   # MCP cannot work without its pyRevit

    if (-not (Test-Path -LiteralPath $paths.State)) {
        return [pscustomobject]@{ Problems = @('This installer has no record of installing anything for this Windows user, so nothing will be removed.'); Warnings = @(); Steps = @() }
    }
    $s = Read-State
    if (-not $RemoveMcp) { $problems += 'Select what to uninstall.' }
    if (Get-Process -Name Revit -ErrorAction SilentlyContinue) { $problems += 'Revit is running. Save your work and close all Revit windows.' }
    $pyDir = Split-Path -Parent $paths.Python
    if ($RemoveMcp -and $s.python -and (Get-Process -Name python, pythonw -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$pyDir\*" })) {
        $problems += 'Claude is still using the MCP server. Quit Claude completely (also from the tray) and try again.'
    }

    if ($RemoveMcp) {
        if (@($s.desktop).Count -and (Test-ClaudeDesktopRunning)) { $problems += 'Claude Desktop is running. Quit it completely (tray icon, Quit), then try again.' }
        foreach ($d in @($s.desktop)) {
            try { $null = Read-DesktopConfig $d.path } catch { $problems += $_.Exception.Message; continue }
            $steps += New-Step "Claude Desktop: remove '$($d.name)'" {
                param($d)
                Remove-DesktopServer $d.path $d.name
                $s = Read-State; $s.desktop = @($s.desktop | Where-Object { -not ($_.path -eq $d.path -and $_.name -eq $d.name) }); Save-State $s
            } $d
        }
        $claude = Get-ClaudeCode
        if (@($s.code).Count -and -not $claude) { $warnings += "Claude Code was not found. Remove these entries yourself: $($s.code -join ', ')" }
        elseif ($claude) {
            foreach ($n in @($s.code)) {
                $steps += New-Step "Claude Code: remove '$n'" {
                    param($d)
                    Invoke-Tool $d.Claude @('mcp', 'remove', '-s', 'user', $d.Name) -AllowFailure | Out-Null
                    $s = Read-State; $s.code = @($s.code | Where-Object { $_ -ne $d.Name }); Save-State $s
                } @{ Claude = $claude; Name = $n }
            }
        }
        if ($null -ne $s.routesBefore) {
            $steps += New-Step 'Put the Routes setting back' {
                $s = Read-State
                if ($s.routesBefore -ne 'true') { Set-IniValue (Get-Paths).Config 'routes' 'enabled' 'false' }
                $s.routesBefore = $null; Save-State $s
            }
        }
        if ($null -ne $s.agentBefore) {
            $steps += New-Step 'Put the built-in MCP setting back' {
                $s = Read-State
                if ($s.agentBefore -ne 'true') { Set-IniValue (Get-Paths).Config 'agent' 'enabled' 'false' }
                $s.agentBefore = $null; Save-State $s
            }
        }
        if ($s.extension) {
            $steps += New-Step 'Delete the MCP extension' {
                $to = (Get-Paths).Extension
                if (Test-Path -LiteralPath $to) { Remove-Item -LiteralPath $to -Recurse -Force }
                $key = Join-Path $env:APPDATA 'pyRevit\mcp_routes.key'
                if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key -Force }
                $s = Read-State; $s.extension = $false; Save-State $s
            }
        }
        if ($s.python) {
            $steps += New-Step 'Delete portable Python' {
                $dir = Split-Path -Parent (Get-Paths).Python
                if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
                $s = Read-State; $s.python = $false; Save-State $s
            }
        }
    }

    $changed = Test-AttachmentsChanged $s
    if ($RemovePyRevit) {
        foreach ($name in @($s.pyrevit)) {
            $message = Get-InUseMessage $(if ($name -eq 'legacy') { $paths.LegacyHome } else { $paths.ModernHome })
            if ($message) { $problems += $message }
        }
    }
    if ($RemovePyRevit -and (@($s.pyrevit).Count -or $changed)) {
        $years = [int[]]@(2019..2035 | Where-Object { Test-Path -LiteralPath (Get-AddinFile $_) })
        $context = @{ Years = $years; Addins = $null; Config = $null }
        $steps += New-Step 'Remember the setup that must stay' {
            param($d)
            $d.Addins = Get-AddinSnapshot $d.Years
            $ini = (Get-Paths).Config
            if (Test-Path -LiteralPath $ini) { $d.Config = [IO.File]::ReadAllBytes($ini) }
        } $context
        foreach ($name in @($s.pyrevit)) {
            $label = if ($name -eq 'legacy') { '6.5.5' } else { '7.1' }
            $steps += New-Step "Uninstall pyRevit $label" { param($d) Uninstall-PyRevit $d } $name
        }
        $steps += New-Step 'Put Revit attachments back as before' { param($d) Restore-Attachments $d.Addins } $context
        $steps += New-Step 'Tidy pyRevit settings' { param($d) Restore-PyRevitSettings $d.Config } $context
        if (@($s.pyrevit).Count -eq 1) { $warnings += 'The two pyRevit versions share one entry in Windows "Installed apps". Check that list for the version you keep.' }
    } elseif ($RemovePyRevit) {
        $warnings += 'This installer did not install pyRevit here, so pyRevit stays.'
    }
    if ($RemoveMcp -and -not @($s.pyrevit).Count -and -not $changed) {
        $steps += New-Step 'Clear the setup record' { $s = Read-State; $s.addins = @(); Save-State $s }
    }
    if ($steps.Count) { $steps += New-Step 'Finish' { Complete-Uninstall } }

    [pscustomobject]@{ Problems = $problems; Warnings = $warnings; Steps = $steps; KeepGoing = $true }
}

. (Join-Path $PSScriptRoot 'Existing.ps1')
