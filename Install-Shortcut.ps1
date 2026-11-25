<#
.SYNOPSIS
    Creates the Desktop "Workspace Wrangler" shortcut (idempotent: overwrites).
    Checks that Git and VS Code are installed first (stops with instructions if not).
    Also creates a "Wrangler - Cascade windows" shortcut with the hotkey Ctrl+Alt+W (-Hotkey to change, -NoHotkey to skip)
    that cascades all open workspace windows to the front.
    Optional -Project makes a per-project shortcut that skips the picker.
#>
param(
    [string]$Name = 'Workspace Wrangler',
    [string]$Project,
    [string]$Folder = [Environment]::GetFolderPath('Desktop'),
    [switch]$SkipPrereqCheck,
    [string]$Hotkey = 'Ctrl+Alt+W',
    [switch]$NoHotkey
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

# A second shortcut whose keyboard shortcut cascades every open workspace window to the front (-Cascade).
# Windows only honours shortcut hotkeys for shortcuts on the Desktop or in the Start Menu.
if (-not $Project -and -not $NoHotkey -and $Hotkey) {
    $hk = $sh.CreateShortcut((Join-Path $Folder 'Wrangler - Cascade windows.lnk'))
    $hk.TargetPath = 'powershell.exe'
    $hk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -Cascade"
    $hk.WorkingDirectory = $PSScriptRoot
    $hk.WindowStyle = 7   # minimized, so no console flash
    $hk.Hotkey = $Hotkey
    $hk.Description = 'Workspace Wrangler: cascade all open workspace windows and bring them to the front'
    if (Test-Path -LiteralPath $ico) { $hk.IconLocation = "$ico,0" } elseif ($wt) { $hk.IconLocation = "$wt,0" }
    $hk.Save()
    Write-Output "Created $($hk.FullName) (hotkey $Hotkey)"
}
