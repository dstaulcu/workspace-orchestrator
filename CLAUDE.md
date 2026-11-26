# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Status

Stable (v1.x). `README.md` covers usage, `docs/configuration.md` every setting, `CHANGELOG.md` the history. No test suite; verify with `-DryRun` and `-List`.

Files: `Start-App.ps1` (everything; file names carry no product branding on purpose, so a fork can rebrand by changing display strings only), `Start-WorkspaceWrangler.ps1` (3-line compatibility stub that forwards to it, because old shortcuts and in-place updates from <= 1.2.x point at that name; remove in v2; `Uninstall-WorkspaceWrangler.ps1` is the same kind of stub), `assets/app.ico` + `tools/New-AppIcon.ps1` (the cowboy-hat icon and its generator), `assets/concept.jpg` + derived `mark.png` / `splash.jpg` / `social-preview.jpg` (`tools/New-ArtAssets.ps1`, prompt in `docs/concept-art.md`; used by the splash, About box and first-run dialog), `Install-Shortcut.ps1` (Desktop .lnk; `-Project <name>` makes a per-project one), `Uninstall-App.ps1` (removes shortcuts, stops the picker, `-RemoveSettings` deletes `~\.config\workspace_app`; supports `-WhatIf`), `config.example.json` / `presets.example.json` (templates; the picker's Settings button copies them into place), `config.schema.json` / `presets.schema.json`. User settings live OUTSIDE the repo in `~\.config\workspace_wrangler\`: `config.json` (defaults; parameters override), `presets.json` (per-project `extraTabs`, `launch`, `claudeArgs`, `shell`, `diff`, `tabColor`, `startupCommand`, `urls`), `state.json` (auto-written: last selection, update check, and `pending` one-shot messages for Claude's next session in a project, e.g. after a rename), `layouts.json` (saved window positions per monitor setup). Old copies next to the script are moved there once.

## Commands

```powershell
# Always use Windows PowerShell 5.1 (powershell.exe), not pwsh
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-App.ps1                          # interactive picker
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-App.ps1 -List                    # JSON, no UI
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-App.ps1 -Project a,b -DryRun     # print wt args only
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-Shortcut.ps1                        # Desktop shortcut
```

## Architecture

One script, pipeline: load config/state/presets → discover project folders under `Root` → last-active per project → sort (newest first) → pick (WinForms, Out-GridView, or none with the command-line switches) → build one `wt` argument string per project (each opens its own new window; `-Window <id>` merges them into one call) → `Start-Process wt.exe`.

- **Last active**: latest git commit time if `.git` exists; otherwise newest file time, skipping noise dirs, capped by file count and depth.
- **`claude --continue`** only if `~\.claude\projects\<path with every non-alphanumeric char → '-'>` exists (e.g. `C:\code\foo` → `C--code-foo`) and `-Fresh` isn't set.
- **Per project tabs**: Claude tab, shell tab (runs `git status -sb; git diff --stat` in git repos), plus preset `extraTabs`. Tab color is a hash of the project name unless the preset sets `tabColor`.
- **Command-line switches** (`-List` JSON, `-Project a,b`, `-All`, `-Focus <name>`, `-Cascade`, `-CheckUpdate`, `-DryRun`) are conveniences for per-project shortcuts and for verifying changes (`-DryRun`, `-List`). They are not a supported agent interface, so UI is fine wherever it helps; they just shouldn't hang waiting on a dialog, so prompts (like the first-run folder dialog) stay in the picker path.
- **Open-tab detection / switching** uses Windows UI Automation over `CASCADIA_HOSTING_WINDOW_CLASS` windows, matching tab titles `cc:<project>` / `sh:<scope>` (`Get-TerminalTabs`, `Get-RunningNames`, `Switch-ToProject`). Changing the tab-title scheme breaks this.
- **WinForms handlers are closures** (`.GetNewClosure()`): they can't see script functions or `$script:` state. Share mutable state through the `$ctx` hashtable and call back into the script via scriptblocks passed to `Show-FormsPicker` (`$OnLaunch`, `$OnSwitch`, `$GetRunning`, `$OnGitOp`). **Closures created inside a closure (e.g. menu items built in a `ContextMenuStrip` `Opening` handler) see none of the outer variables**: give each item `.Tag = @{ Fn = <scriptblock>; A = @(args) }` and one shared top-level click handler (`$menuClick`, which splats with `$a = @($tg.A); & $tg.Fn @a`; `@($tg.A)` would pass one array argument) instead of nested `.GetNewClosure()` handlers. Launching lives in `Invoke-Launch`, which focuses projects that already have an open tab instead of launching them again.

## `wt.exe` quoting rules (the fragile part)

- Build **one** argument string per window (`-w new ` prefix, one window per project by default), clauses joined with ` ; `, passed to `Start-Process wt.exe -ArgumentList`. wt does its own parsing; never pass an array.
- A `;` **inside** a tab's command is still a wt separator, even in quotes. Write `\;` (e.g. `Set-Location -LiteralPath '<dir>'\; claude --continue`). A bare `;` spawns a bogus extra tab.
- Each tab: `--title`, `--suppressApplicationTitle`, `-d "<dir>"`, **and** explicit `Set-Location -LiteralPath` in `powershell.exe -NoExit -Command "..."` (`-d` alone was unreliable).
- Paths with spaces: escaped double quotes for wt/`-d`, single quotes (doubled if they contain `'`) inside `-Command`.
- `focus-tab -t 0` at the end, except when targeting an existing window with `-Window`.
- `claudeArgs` must not contain double quotes.

## Releases and updates

`$AppVersion` at the top of the script is the app version. Bump it in the release commit, move `CHANGELOG.md`'s Unreleased entries under the new version, then tag `vX.Y.Z` (no suffix) and publish a normal GitHub release (not a pre-release; notes = the changelog section + `tools/release-install.md`): the startup update check compares `$AppVersion` with the latest release tag (`Start-UpdateCheck`, `Complete-UpdateCheck`, `Install-Update`; settings in `state.json`: `lastUpdateCheck`, `update`, `skipVersion`). The update check is the only network call; keep it non-blocking (async `HttpClient`, polled by a timer) and keep it out of the non-interactive switches except `-CheckUpdate`.

## Constraints

Launching never modifies projects (only the Wrangler's own `state.json` in `~\.config\workspace_app\`). The picker's **Git** menu (`Invoke-GitOp` core, `Invoke-PickerGitOp` UI, via the `$OnGitOp` callback) and the project-management actions **New project** / **Rename project** and the **Launch options...** dialog (`Save-ProjectPreset`, which edits only that project's entry in `presets.json`) (`Invoke-NewProject`, `Invoke-RenameProject`, via `$Actions`) are the only code that changes a project or its folder, and only after the user confirms (Yes/No for `git init` and rename, the Create/New/Rename dialogs); `-DryRun` reports instead. Keep it that way. No credentials or personal paths in committed files: settings live outside the repo, and `REQUIREMENTS.md` is git-ignored on purpose.
