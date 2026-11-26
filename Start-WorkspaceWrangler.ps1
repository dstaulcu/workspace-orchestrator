# Compatibility stub. The script was renamed to Start-App.ps1 in v1.3.0 so the file names carry no product branding.
# Shortcuts, the startup launcher and in-place updates from older versions still point at this name, so this forwards
# every parameter to the real script. Safe to delete once nothing references the old name (planned for v2).
& (Join-Path $PSScriptRoot 'Start-App.ps1') @args
