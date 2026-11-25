<#
.SYNOPSIS
    Creates the Desktop "Workspace Wrangler" shortcut (idempotent: overwrites).
    Optional -Project makes a per-project shortcut that skips the picker.
#>
param(
    [string]$Name = 'Workspace Wrangler',
    [string]$Project,
    [string]$Folder = [Environment]::GetFolderPath('Desktop')
)

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
