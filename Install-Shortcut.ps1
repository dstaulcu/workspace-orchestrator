<#
.SYNOPSIS
    Creates the Desktop "Workspace Picker" shortcut (idempotent: overwrites).
    Optional -Project makes a per-project shortcut that skips the picker.
#>
param(
    [string]$Name = 'Workspace Picker',
    [string]$Project,
    [string]$Folder = [Environment]::GetFolderPath('Desktop')
)

$script = Join-Path $PSScriptRoot 'Start-WorkspaceOrchestrator.ps1'
$psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
if ($Project) { $psArgs += " -Project `"$Project`"" }

$wt = (Get-Command wt.exe -ErrorAction SilentlyContinue).Source
$sh = New-Object -ComObject WScript.Shell
$lnk = $sh.CreateShortcut((Join-Path $Folder "$Name.lnk"))
$lnk.TargetPath = 'powershell.exe'
$lnk.Arguments = $psArgs
$lnk.WorkingDirectory = $PSScriptRoot
if ($wt) { $lnk.IconLocation = "$wt,0" }
$lnk.Save()
Write-Output "Created $($lnk.FullName)"
