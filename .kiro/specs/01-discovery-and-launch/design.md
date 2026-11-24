# Design: Project Discovery and Launch

## Overview

A single PowerShell 5.1 script (`Start-WorkspaceOrchestrator.ps1`) plus `Install-Shortcut.ps1`. No dependencies beyond Windows Terminal, and optionally git and the Claude Code CLI.

```mermaid
flowchart LR
    A[Get-ChildItem root] --> B[Filter ignore / dot folders]
    B --> C[Get-LastActive per project]
    C --> D[Sort newest first]
    D --> E[Selection]
    E --> F[Build tab clauses]
    F --> G["Start-Process wt.exe -ArgumentList"]
```

## Components

| Function | Responsibility |
|---|---|
| `Get-LastActive` | `git log -1 --format=%ct` if `.git`; else iterative directory walk (explicit stack) tracking max `LastWriteTime`, skipping noise dirs, capped by `maxScanFiles` / `maxScanDepth` |
| `Format-Relative` | "12 min ago", "3 d ago" for display |
| `Test-ClaudeHistory` | Encodes the path (`[^A-Za-z0-9]` → `-`) and checks `~\.claude\projects\<enc>` |
| `Get-TabColor` | Hash of name → hue (0-359) → HSL (s=.55, l=.42) → `#RRGGBB` |
| `ConvertTo-PsLiteral` | Wraps in single quotes, doubling embedded `'` |
| `New-TabClause` | Emits one `new-tab` clause (see below) |

## `wt` command anatomy

```
new-tab --title "claude-code-<project>" --tabColor "#RRGGBB" --suppressApplicationTitle -d "<dir>" powershell.exe -NoExit -Command "Set-Location -LiteralPath '<dir>'\; claude --continue"
 ; new-tab ... ; focus-tab -t 0
```

Decisions driven by observed failures:

- `;` is a wt separator even inside quotes → `\;` inside a tab command (a bare `;` spawned a bogus extra tab).
- One verbatim string, not an args array, because wt does its own parsing.
- `-d` alone did not reliably set cwd → also `Set-Location -LiteralPath`.
- Double quotes for wt/`-d` paths, single quotes inside `-Command`.

## Tab order and focus

Per project: Claude tab, shell tab, then preset extras. `focus-tab -t 0` returns focus to the first Claude tab (omitted with `-Window`, since index 0 would be in another window).

## Error handling

Missing root → warn, exit 1. Missing project dir or preset path → `Write-Warning`, skip that item. Git failures fall back silently to file times.

## Shortcut

`Install-Shortcut.ps1` uses `WScript.Shell` COM: target `powershell.exe`, arguments `-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "<script>" [-Project "<name>"]`, working dir = script folder, icon = `wt.exe,0`.
