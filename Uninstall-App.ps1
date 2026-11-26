<#
.SYNOPSIS
    Removes what Workspace Wrangler installed outside its own folder: Desktop shortcuts, a running picker and,
    only if you ask, your settings. Supports -WhatIf.

.DESCRIPTION
    * Stops running Workspace Wrangler pickers (the hidden PowerShell the shortcut starts).
    * Deletes Desktop shortcuts that launch Start-App.ps1 (or its old names,
      Start-WorkspaceWrangler.ps1 and Start-WorkspaceOrchestrator.ps1), including per-project shortcuts made with Install-Shortcut -Project.
    * With -RemoveSettings, deletes ~\.config\workspace_app (config, presets, state, saved layouts, update
      backups) and the older ~\.config\workspace_wrangler / workspace_picker folders if they are still there. Without it, settings are kept
      so a reinstall picks up where you left off.
    * Never deletes this program folder; it prints that last step for you. Terminals and projects are never touched.
.PARAMETER RemoveSettings  Also delete the settings folder(s).
.PARAMETER Folder          Where to look for shortcuts (default: your Desktop; the Start Menu is checked too).
.EXAMPLE
    .\Uninstall-App.ps1 -WhatIf          # preview
    .\Uninstall-App.ps1                   # remove shortcuts, keep settings
    .\Uninstall-App.ps1 -RemoveSettings   # remove everything except this folder
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [switch]$RemoveSettings,
    [string]$Folder = [Environment]::GetFolderPath('Desktop'),
    [string]$StartMenuFolder = [Environment]::GetFolderPath('Programs')
)

# Match only THIS folder's scripts (current and earlier names), so an unrelated Start-App.ps1 or shortcut elsewhere is never touched.
$pattern = [regex]::Escape($PSScriptRoot) + '[\\/]Start-(App|WorkspaceWrangler|WorkspaceOrchestrator)\.ps1'
$removed = 0

# 1. Running pickers (not this script).
$wi = $WhatIfPreference; $WhatIfPreference = $false   # keep -WhatIf from touching module auto-loading
$procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match $pattern -and $_.CommandLine -match '-WindowStyle\s+Hidden' -and $_.CommandLine -notmatch '-(List|DryRun|CheckUpdate|Focus)' -and $_.CommandLine -notmatch 'Uninstall-' })
$WhatIfPreference = $wi
foreach ($p in $procs) {
    if ($PSCmdlet.ShouldProcess("process $($p.ProcessId)", 'Stop running Workspace Wrangler picker')) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue; $removed++
    }
}

# 2. Desktop shortcuts that point at the script.
$sh = New-Object -ComObject WScript.Shell
foreach ($f in @(Get-ChildItem -LiteralPath $Folder, $StartMenuFolder -Filter '*.lnk' -ErrorAction SilentlyContinue)) {
    try { $lnk = $sh.CreateShortcut($f.FullName) } catch { continue }
    if ($lnk.Arguments -match $pattern) {
        if ($PSCmdlet.ShouldProcess($f.FullName, 'Delete shortcut')) { Remove-Item -LiteralPath $f.FullName -Force; $removed++; Write-Output "Removed shortcut: $($f.FullName)" }
    }
}

# 3. Settings (opt-in).
$dirs = @((Join-Path $env:USERPROFILE '.config\workspace_app'), (Join-Path $env:USERPROFILE '.config\workspace_wrangler'), (Join-Path $env:USERPROFILE '.config\workspace_picker'))
foreach ($d in $dirs) {
    if (-not (Test-Path -LiteralPath $d)) { continue }
    if ($RemoveSettings) {
        if ($PSCmdlet.ShouldProcess($d, 'Delete settings folder')) { Remove-Item -LiteralPath $d -Recurse -Force; $removed++; Write-Output "Removed settings: $d" }
    } else {
        Write-Output "Kept settings: $d  (re-run with -RemoveSettings to delete them)"
    }
}

Write-Output ''
if ($removed -eq 0 -and -not $WhatIfPreference) { Write-Output 'Nothing to remove.' }
Write-Output "To finish, delete this program folder yourself:  $PSScriptRoot"
Write-Output '(Your projects, terminals and Claude sessions are untouched.)'
