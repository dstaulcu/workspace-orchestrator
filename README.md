<p align="center"><img src="assets/wrangler.png" alt="Workspace Wrangler: a cowboy hat" width="160"></p>

# Workspace Wrangler

> **Experimental (v0.6).** Windows only. Works on my machine; expect rough edges. Issues and ideas welcome.

**Tame your sea of projects and terminals, and restart your whole workday in one click.**

A small picker that lists your project folders (newest activity first) and opens each one as its own [Windows Terminal](https://aka.ms/terminal) window: a [Claude Code](https://claude.com/claude-code) session that resumes your last conversation, plus a shell tab with `git status`, already in the right folder and color-coded.

- **Start the day in one click:** yesterday's selection is pre-checked; press **Launch**.
- **Always know what's open:** the picker marks projects that already have tabs open; **Switch** jumps to the right window, **Launch** never duplicates one.
- **See where things stand:** last activity, branch, dirty/clean and a link to each repo's remote.
- **Do the chores:** open projects in your IDE, create repositories on GitHub / GitLab / Azure DevOps, cascade all windows with a hotkey.
- **Scriptable:** AI agents and scripts can drive it too (see [Agent mode](#agent-mode)).

## Install

**Requirements:** Windows 10/11, [Windows Terminal](https://aka.ms/terminal), the built-in Windows PowerShell 5.1, [Claude Code](https://claude.com/claude-code) (`claude` on PATH), [Git](https://git-scm.com/download/win) and [Visual Studio Code](https://code.visualstudio.com/). The installer checks for Git and VS Code and stops with instructions if either is missing. Optional: `gh` / `glab` / `az` only for creating remote repositories.

1. Download **Source code (zip)** from the [latest release](https://github.com/dstaulcu/workspace-wrangler/releases/latest) and extract it somewhere permanent (for example `C:\tools\workspace-wrangler`). Or clone: `git clone https://github.com/dstaulcu/workspace-wrangler.git`.
2. In that folder, run:
   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-Shortcut.ps1
   ```
   This puts **Workspace Wrangler** and **Wrangler - Cascade windows** (hotkey **Ctrl+Alt+W**) on your Desktop.
3. Double-click **Workspace Wrangler**. Projects are the subfolders of `C:\code` by default; change `root` under **Settings > Edit config.json**.

To try it without installing: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-WorkspaceWrangler.ps1`.
**Update:** the picker offers new releases itself (see below). **Uninstall:** `.\Uninstall-WorkspaceWrangler.ps1` (add `-WhatIf` to preview, `-RemoveSettings` to also delete settings).

## Using the picker

Check projects and press **Launch** (or Enter). Type in the filter box to narrow the list.

| Button | What it does |
|---|---|
| **Launch** | Open checked (or highlighted) projects, one window each. Already-open projects are raised instead; **Shift** forces a new copy. |
| **Switch** | Bring the highlighted project's open tab and window to the front. |
| **Refresh** | Re-detect open projects (also automatic every `refreshSeconds`). |
| **Arrange** | Cascade, grid, side by side, stacked, reset size. **Shift** ignores saved spots. |
| **Git** | Open the repo in a browser, `git init`, create a remote (GitHub / GitLab / Azure DevOps submenus) or add an existing remote URL. Also on the right-click menu. |
| **IDE** | Open every checked and highlighted project in your IDE, one window each (`ide`, default `code`). |
| **Settings** | Edit `config.json` / `presets.json`, save window layout, check for updates, open the changelog. |

**Fresh sessions** starts plain `claude` instead of `claude --continue`. **Keep open after launch** leaves the picker running. Tabs are titled `cc:<project>` and `sh:<scope>`; that is how open projects are found, so don't rename them.

**Hotkey:** **Ctrl+Alt+W** (the *Wrangler - Cascade windows* shortcut; change it with `Install-Shortcut.ps1 -Hotkey`) finds all open workspaces, restores minimized ones, cascades them and brings them to the front. From a script: `Start-WorkspaceWrangler.ps1 -Cascade`.

**Window layout:** new windows are cascaded (`arrangeStyle`: `cascade`, `grid`, `columns`, `rows`). **Settings > Save window layout** remembers where each open project's window is, per monitor setup, and later launches put them back.

## Updates

On startup the picker checks GitHub **releases** (at most daily, without slowing startup; nothing happens until a release is published). When a newer one exists you can click **What's new**, **Update now** (in place, with backup and rollback; settings are kept) or **Skip this version**. After an update it offers to open the [changelog](CHANGELOG.md), which is also under **Settings > Changelog**. Turn the check off with `checkForUpdates: false`.

## Agent mode

No UI, no dialogs. Projects already open are focused instead of launched again.

```powershell
$s = '.\Start-WorkspaceWrangler.ps1'
powershell.exe -NoProfile -File $s -List -Top 5          # discover (JSON)
powershell.exe -NoProfile -File $s -Project a,b -DryRun  # preview the wt command
powershell.exe -NoProfile -File $s -Project a,b          # launch
powershell.exe -NoProfile -File $s -All -Top 3           # launch the 3 most recent
powershell.exe -NoProfile -File $s -Focus a              # raise a's open tab (exit 1 if not open)
powershell.exe -NoProfile -File $s -Cascade              # cascade all open workspaces to the front
powershell.exe -NoProfile -File $s -CheckUpdate          # JSON: current, latest, updateAvailable
```

Other switches: `-Root`, `-Filter`, `-Fresh`, `-NoShell`, `-NoDiff`, `-NoColor`, `-Picker Grid` (plain list), `-Window <id>` (all tabs in one existing window).

## Configuration

Settings live outside the repo in `~\.config\workspace_wrangler\` (`config.json` global defaults, `presets.json` per-project tabs and arguments, `state.json` and `layouts.json` written for you), so updates never touch them. Precedence: command-line switch > per-project preset > `config.json`. Full reference with every key: **[docs/configuration.md](docs/configuration.md)**; JSON schemas give editors hover help.

## Safety

Launching never modifies your projects; the app writes only its own files in the settings folder. The only network call is the update check (one read of the public releases list). The **Git** menu is the one thing that changes a project, and only after you confirm; it uses your existing `gh` / `glab` / `az` sign-in and never sees a token.

## More

- Design docs (requirements, design, tasks per feature): [`.kiro/specs/`](.kiro/specs/)
- Ideas: macOS/Linux terminals, other agent CLIs, saved sets of projects, a test suite.
- [MIT license](LICENSE)
