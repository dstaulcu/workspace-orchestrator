# Compatibility stub. The script was renamed to Uninstall-App.ps1 in v1.3.0 (see Start-WorkspaceWrangler.ps1).
# Forwards every parameter (-WhatIf, -RemoveSettings, ...) to the real script. Safe to delete in v2.
& (Join-Path $PSScriptRoot 'Uninstall-App.ps1') @args
