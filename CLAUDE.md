# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Status

Experimental (v0.1.x). Specs live in `.kiro/specs/` (requirements, design, tasks per feature); `README.md` explains the concepts. No test suite; verify with `-DryRun` and `-List`.

Files: `Start-WorkspaceOrchestrator.ps1` (everything), `Install-Shortcut.ps1` (Desktop .lnk; `-Project <name>` makes a per-project one), `config.json` (defaults; parameters override), `presets.example.json` (copy to the git-ignored `presets.json`; per-project `extraTabs`, `launch`, `claudeArgs`, `shell`, `diff`, `tabColor`), `state.json` (auto-written, git-ignored: pins + last selection).

## Commands

```powershell
# Always use Windows PowerShell 5.1 (powershell.exe), not pwsh
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-WorkspaceOrchestrator.ps1            # interactive picker
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-WorkspaceOrchestrator.ps1 -List      # JSON, no UI
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-WorkspaceOrchestrator.ps1 -Project a,b -DryRun   # print wt args only
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-Shortcut.ps1                        # Desktop shortcut
```

## Architecture

One script, pipeline: load config/state/presets → discover project folders under `Root` → last-active per project → sort (pinned first, then newest) → pick (WinForms, Out-GridView, or none in agent mode) → build ONE `wt` argument string → `Start-Process wt.exe`.

- **Last active**: latest git commit time if `.git` exists; otherwise newest file time, skipping noise dirs, capped by file count and depth.
- **`claude --continue`** only if `~\.claude\projects\<path with every non-alphanumeric char → '-'>` exists (e.g. `C:\code\foo` → `C--code-foo`) and `-Fresh` isn't set.
- **Per project tabs**: Claude tab, shell tab (runs `git status -sb; git diff --stat` in git repos), plus preset `extraTabs`. Tab color is a hash of the project name unless the preset sets `tabColor`.
- **Agent mode**: `-List` (JSON, includes `running`), `-Project a,b` (skips scan), `-All`, `-Focus <name>` (raise an open tab), `-DryRun`. Keep these free of any UI.
- **Open-tab detection / switching** uses Windows UI Automation over `CASCADIA_HOSTING_WINDOW_CLASS` windows, matching tab titles `claude-code-<project>` / `shell-<scope>` (`Get-TerminalTabs`, `Get-RunningNames`, `Switch-ToProject`). Changing the tab-title scheme breaks this.
- **WinForms handlers are closures** (`.GetNewClosure()`): they can't see script functions or `$script:` state. Share mutable state through the `$ctx` hashtable and call back into the script via scriptblocks passed to `Show-FormsPicker` (`$OnLaunch`, `$OnSwitch`, `$GetRunning`). Launching lives in `Invoke-Launch`.

## `wt.exe` quoting rules (the fragile part)

- Build **one** argument string, clauses joined with ` ; `, passed to `Start-Process wt.exe -ArgumentList`. wt does its own parsing; never pass an array.
- A `;` **inside** a tab's command is still a wt separator, even in quotes. Write `\;` (e.g. `Set-Location -LiteralPath '<dir>'\; claude --continue`). A bare `;` spawns a bogus extra tab.
- Each tab: `--title`, `--suppressApplicationTitle`, `-d "<dir>"`, **and** explicit `Set-Location -LiteralPath` in `powershell.exe -NoExit -Command "..."` (`-d` alone was unreliable).
- Paths with spaces: escaped double quotes for wt/`-d`, single quotes (doubled if they contain `'`) inside `-Command`.
- `focus-tab -t 0` at the end, except when targeting an existing window with `-Window`.
- `claudeArgs` must not contain double quotes.

## Constraints

Launching never modifies projects (only the orchestrator's own `state.json`). No credentials or personal paths in committed files: `presets.json`, `state.json` and `REQUIREMENTS.md` are git-ignored on purpose.
