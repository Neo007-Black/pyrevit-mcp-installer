# "Remove existing setup": for pyRevit / MCP parts that were NOT installed by this installer.
# Nothing here runs unless the user ticks an item. Loaded by Core.ps1.

$script:McpNames = 'pyrevit', 'pyrevit-routes', 'pyrevit-legacy', 'pyRevit-MCP'

function New-FoundItem([string]$Kind, [string]$Label, $Data) { [pscustomobject]@{ Kind = $Kind; Label = $Label; Data = $Data } }

# An entry counts as a pyRevit MCP server by its name or by what it starts.
function Test-McpEntry([string]$Name, $Entry) {
    if ($script:McpNames -contains $Name) { return $true }
    $line = "$($Entry.command) $(@($Entry.args) -join ' ')"
    return ($line -match 'mcp-server-for-revit' -or $line -match 'pyrevit(\.exe)?"?\s+mcp(\s|$)')
}

function Get-ExistingSetup {
    $paths = Get-Paths

    foreach ($config in @(Get-DesktopConfigPaths)) {
        if (-not (Test-Path -LiteralPath $config)) { continue }
        try { $json = Read-DesktopConfig $config } catch { Write-Log "NOTE: $($_.Exception.Message)"; continue }
        if (-not $json.PSObject.Properties['mcpServers']) { continue }
        foreach ($p in @($json.mcpServers.PSObject.Properties)) {
            if (Test-McpEntry $p.Name $p.Value) {
                New-FoundItem 'Desktop' "Claude Desktop entry '$($p.Name)'  ($config)" @{ Path = $config; Name = $p.Name }
            }
        }
    }

    $claude = Get-ClaudeCode
    if ($claude) {
        foreach ($name in $script:McpNames) {
            if ((Invoke-Tool $claude @('mcp', 'get', $name) -AllowFailure).ExitCode -eq 0) {
                New-FoundItem 'Code' "Claude Code entry '$name'" @{ Claude = $claude; Name = $name }
            }
        }
    }

    if ((Get-IniValue $paths.Config 'routes' 'enabled') -eq 'true') {
        New-FoundItem 'Setting' 'Turn off pyRevit Routes (local web server)' @{ Section = 'routes' }
    }
    if ((Get-IniValue $paths.Config 'agent' 'enabled') -eq 'true') {
        New-FoundItem 'Setting' 'Turn off pyRevit Agent MCP' @{ Section = 'agent' }
    }

    if (Test-Path -LiteralPath $paths.Extension) {
        New-FoundItem 'Extension' "MCP extension, including your own changes to it  (to Recycle Bin: $($paths.Extension))" @{ Path = $paths.Extension }
    }

    foreach ($pair in @(@('modern', $paths.ModernHome), @('legacy', $paths.LegacyHome))) {
        $folder = $pair[1]
        if (-not (Test-Path -LiteralPath (Join-Path $folder 'unins000.exe'))) { continue }
        $version = Get-PyRevitVersion (Join-Path $folder 'bin\pyrevit.exe')
        New-FoundItem 'PyRevit' "pyRevit $version program  (cannot be undone: $folder)" @{ Folder = $folder }
    }
}

function Send-ToRecycleBin([string]$Folder) {
    Add-Type -AssemblyName Microsoft.VisualBasic
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Folder, 'OnlyErrorDialogs', 'SendToRecycleBin')
}

function Remove-FoundPyRevit([string]$Folder) {
    $message = Get-InUseMessage $Folder
    if ($message) { throw $message }
    Invoke-PyRevitUninstaller $Folder
    if (Test-Path -LiteralPath $Folder) { Write-Log "    Some files were left in $Folder (not deleted)." }
    Remove-FromUserPath "*$(Split-Path -Leaf $Folder)\*"
}
function Get-ExistingRemovalPlan($Items) {
    $Items = @($Items)
    $problems = @(); $warnings = @(); $steps = @()
    if (-not $Items.Count) { $problems += 'Tick at least one item to remove.' }
    if (Get-Process -Name Revit -ErrorAction SilentlyContinue) { $problems += 'Revit is running. Save your work and close all Revit windows.' }

    if (@($Items | Where-Object { $_.Kind -eq 'Desktop' }).Count -and (Test-ClaudeDesktopRunning)) { $problems += 'Claude Desktop is running. Quit it completely (tray icon, Quit), then try again.' }
    foreach ($i in @($Items | Where-Object { $_.Kind -eq 'Desktop' })) {
        try { $null = Read-DesktopConfig $i.Data.Path } catch { $problems += $_.Exception.Message; continue }
        $steps += New-Step "Remove $($i.Label)" { param($d) Remove-DesktopServer $d.Path $d.Name } $i.Data
    }
    foreach ($i in @($Items | Where-Object { $_.Kind -eq 'Code' })) {
        $steps += New-Step "Remove $($i.Label)" { param($d) Invoke-Tool $d.Claude @('mcp', 'remove', '-s', 'user', $d.Name) | Out-Null } $i.Data
    }
    foreach ($i in @($Items | Where-Object { $_.Kind -eq 'Setting' })) {
        $steps += New-Step $i.Label { param($d) Set-IniValue (Get-Paths).Config $d.Section 'enabled' 'false' } $i.Data
    }
    foreach ($i in @($Items | Where-Object { $_.Kind -eq 'Extension' })) {
        $warnings += 'Quit Claude first, so the MCP extension is not in use.'
        $steps += New-Step 'Move the MCP extension to the Recycle Bin' {
            param($d)
            Send-ToRecycleBin $d.Path
            $key = Join-Path $env:APPDATA 'pyRevit\mcp_routes.key'
            if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key -Force }
        } $i.Data
    }

    $programs = @($Items | Where-Object { $_.Kind -eq 'PyRevit' })
    foreach ($i in $programs) { $message = Get-InUseMessage $i.Data.Folder; if ($message) { $problems += $message } }
    if ($programs.Count) {
        $warnings += 'Removing a pyRevit program cannot be undone here. Keep its setup file if you may want it back.'
        $years = [int[]]@(2017..2035 | Where-Object { Test-Path -LiteralPath (Get-AddinFile $_) })
        $context = @{ Years = $years; Addins = $null; Config = $null }
        # pyRevit's uninstaller detaches every Revit version, so the others are saved and restored.
        $steps += New-Step 'Remember the setup that must stay' {
            param($d)
            $d.Addins = Get-AddinSnapshot $d.Years
            $ini = (Get-Paths).Config
            if (Test-Path -LiteralPath $ini) { $d.Config = [IO.File]::ReadAllBytes($ini) }
        } $context
        foreach ($i in $programs) { $steps += New-Step "Uninstall $($i.Label)" { param($d) Remove-FoundPyRevit $d.Folder } $i.Data }
        $steps += New-Step 'Restore Revit versions that use a pyRevit you kept' {
            param($d)
            foreach ($y in @($d.Addins.Keys)) { if (-not (Get-AddinTargetExists $d.Addins[$y])) { $d.Addins[$y] = $null } }
            Restore-AddinSnapshot $d.Addins
        } $context
        $steps += New-Step 'Tidy pyRevit settings' { param($d) Restore-PyRevitSettings $d.Config } $context
    }

    $warnings += 'Your other extensions and projects are not touched. Claude Desktop extensions (in its Settings) are not listed here.'
    [pscustomobject]@{ Problems = $problems; Warnings = $warnings; Steps = $steps; KeepGoing = $true }
}
