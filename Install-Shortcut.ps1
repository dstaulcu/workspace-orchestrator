<#
.SYNOPSIS
    Creates the Desktop "Workspace Wrangler" shortcut (idempotent: overwrites).
    Checks that Git and VS Code are installed first (stops with instructions if not).
    Optional -Project makes a per-project shortcut that skips the picker.
#>
param(
    [string]$Name = 'Workspace Wrangler',
    [string]$Project,
    [string]$Folder = [Environment]::GetFolderPath('Desktop'),
    [switch]$SkipPrereqCheck
)

# Prerequisites: Git and Visual Studio Code are expected to be installed already. Stop and say so if not.
if (-not $SkipPrereqCheck) {
    $missing = @()
    if (-not (Get-Command git.exe -ErrorAction SilentlyContinue) -and
        -not (@("$env:ProgramFiles\Git\cmd\git.exe", "${env:ProgramFiles(x86)}\Git\cmd\git.exe", "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe") | Where-Object { Test-Path -LiteralPath $_ })) {
        $missing += 'Git for Windows (git.exe)  https://git-scm.com/download/win'
    }
    $vscode = @("$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe", "$env:ProgramFiles\Microsoft VS Code\Code.exe", "${env:ProgramFiles(x86)}\Microsoft VS Code\Code.exe")
    if (-not (Get-Command code.cmd -ErrorAction SilentlyContinue) -and -not (Get-Command code.exe -ErrorAction SilentlyContinue) -and
        -not ($vscode | Where-Object { Test-Path -LiteralPath $_ })) {
        $missing += 'Visual Studio Code  https://code.visualstudio.com/'
    }
    if ($missing) {
        Write-Warning 'Workspace Wrangler expects these to be installed first:'
        $missing | ForEach-Object { Write-Warning "  - $_" }
        Write-Warning 'Install them, then run Install-Shortcut.ps1 again to continue (-SkipPrereqCheck overrides this check).'
        exit 1
    }
}

$script = Join-Path $PSScriptRoot 'Start-WorkspaceWrangler.ps1'
$psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
if ($Project) { $psArgs += " -Project `"$Project`"" }

$wt = (Get-Command wt.exe -ErrorAction SilentlyContinue).Source
$sh = New-Object -ComObject WScript.Shell
$lnk = $sh.CreateShortcut((Join-Path $Folder "$Name.lnk"))
$lnk.TargetPath = 'powershell.exe'
$lnk.Arguments = $psArgs
$lnk.WorkingDirectory = $PSScriptRoot
$ico = Join-Path $PSScriptRoot 'assets\wrangler.ico'
if (Test-Path -LiteralPath $ico) { $lnk.IconLocation = "$ico,0" } elseif ($wt) { $lnk.IconLocation = "$wt,0" }
$lnk.Save()

# Retarget shortcuts left over from the old script name (Start-WorkspaceOrchestrator.ps1), so they keep working.
# Also drop the old "Workspace Picker.lnk" (only if it is ours, and never the one just saved).
foreach ($f in @(Get-ChildItem -LiteralPath $Folder -Filter '*.lnk' -ErrorAction SilentlyContinue)) {
    if ($f.FullName -ieq $lnk.FullName) { continue }
    try { $old = $sh.CreateShortcut($f.FullName) } catch { continue }
    if ($old.Arguments -notmatch 'Start-WorkspaceOrchestrator\.ps1') { continue }
    if ($f.Name -eq 'Workspace Picker.lnk' -and -not $Project) { Remove-Item -LiteralPath $f.FullName; Write-Output "Removed old shortcut $($f.FullName)"; continue }
    $old.Arguments = $old.Arguments -replace 'Start-WorkspaceOrchestrator\.ps1', 'Start-WorkspaceWrangler.ps1'
    $old.Save(); Write-Output "Updated old shortcut $($f.FullName)"
}
Write-Output "Created $($lnk.FullName)"

# v0.6.0 created a separate "Wrangler - Cascade windows" shortcut for the hotkey. The hotkey is now built into the
# picker (config.json "hotkey"), so remove that shortcut from the Desktop / Start Menu if it is there.
foreach ($dir in @($Folder, [Environment]::GetFolderPath('Programs'))) {
    $legacyHk = Join-Path $dir 'Wrangler - Cascade windows.lnk'
    if (Test-Path -LiteralPath $legacyHk) { Remove-Item -LiteralPath $legacyHk -Force; Write-Output "Removed old hotkey shortcut $legacyHk (the hotkey is now built into the picker)" }
}
