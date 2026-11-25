# Changelog

All notable changes to Workspace Wrangler. Newest first. The picker opens this file from **Settings > Changelog**
and offers it after an update. Add new entries under **Unreleased** as you work; rename that heading to the
version when you release.

## Unreleased

## 1.0.0 - 2026-11-25

First stable release: no more `-experimental` suffix or pre-release flag. Everything since 0.6.1 ships in it.

### Added
- **New project** (a **+ New project** button beside the filter box, also on a right-click in empty space) and **Rename project** (right-click menu). New creates the folder in your projects folder with optional `git init`, README and open-in-IDE. Rename moves the folder together with its Claude conversation history, `presets.json` entry, saved window position and remembered selection, and refuses while the project has terminal tabs open. The dialog can also leave Claude a message ("I just renamed this folder from X to Y, please update artifacts as appropriate", editable) that is sent once as the first message of the project's next launched Claude session. Both ask first and reload the list.
- **Claude session** choices under right-click > Launch: continue the last conversation, pick one to resume (`claude --resume`), start fresh, plus your own variants from the new `claudeVariants` setting (the example config has *Plan mode*).
- **Right-click menu on a project** with submenus: **Launch** (Claude + shell, Claude only, shell only, fresh session, new window even if open), **Switch** (Claude tab or shell tab), **IDE** (open in your IDE, open in File Explorer, copy path) and **Git** (the same items as the Git button). Launch, Switch and IDE act on all highlighted projects.
- **First-run folder prompt:** if the projects folder (default `C:\code`) is missing or empty, the picker asks where your projects live instead of exiting silently. It suggests the folders your tools already use (the parents of projects you opened in Claude Code, read from `~\.claude.json`, and in VS Code / Cursor / VSCodium, read from their `storage.json`; most opened projects first) plus common names like `~\source
epos`, lets you Browse, and saves the answer as `root` in `config.json`. **Settings > Change projects folder...** does the same later. Agent mode never prompts; it now says how to set `root`.

### Fixed
- **Right-click Switch, Launch and Git submenu items did nothing or got scrambled arguments** (their handlers lost their variables and passed their arguments as one array); they now work.
- **Presets:** with two or more entries in `presets.json`, each project's lookup returned all of them mixed together, so its `shell`, `diff`, `claudeArgs` and tabs came from the wrong entries. Each project now gets only its own preset.

### Changed
- Removed the **Keep open after launch** checkbox and the `keepOpen` setting: the picker always stays open after launching. (An old `keepOpen` in your `config.json` is ignored.)
- Dropped the "agent mode" framing: the README section is now a short *Command line* section, and `CLAUDE.md` no longer requires the command-line switches to stay UI-free (they just must not block on dialogs). All switches still work.
- Removed the **Fresh sessions (no --continue)** checkbox from the picker; right-click > **Launch > Claude session** covers it per launch (`-Fresh` still works on the command line).
- The cascade hotkey now also places the Wrangler: top aligned with the first window and just right of the last one (against the right edge of the screen if there is no room), keeping its own size, so it is never buried behind the cascaded windows.
- **Faster startup** (about 3.3 s to 1.5 s on a 33-project folder): each project's last-active time and git info are now gathered in parallel, and git info needs two git calls per repository instead of four or more. Results are identical.
- Every control now has a tooltip: dialog fields and buttons, the update notice, the help links, and the Arrange, Settings and Git menu items (including the provider submenus).

## 0.6.1 - 2026-11-24

### Changed
- The cascade hotkey (default **Ctrl+Alt+W**) is now built into the picker and works while it is open, so there is no second shortcut file or icon. Pressing it cascades every open workspace and brings the Wrangler itself up on top. Set `hotkey` in `config.json` to change it (needs a modifier; empty = off). The status bar says so if another program already owns the key. `Install-Shortcut.ps1` removes the *Wrangler - Cascade windows* shortcut that v0.6.0 created, and its `-Hotkey` / `-NoHotkey` switches are gone.
- The hotkey is shown in the picker: in the hint line, on the **Arrange** tooltip and next to **Cascade** in the Arrange menu.

## 0.6.0 - 2026-11-24

### Added
- **IDE button:** opens every checked and highlighted project in your IDE, one window per project (`ide`, default `code`; `ideArgs`, default `-n`).
- **Create remote repository** now supports GitHub (`gh`), GitLab (`glab`) and Azure DevOps (`az repos`) as submenus, plus **Add existing remote URL...** for any host. Configure the entries with `gitOpsTargets` (replaces the unreleased `gitOpsOrgs`).
- **Hotkey:** `Install-Shortcut.ps1` creates *Wrangler - Cascade windows* (default Ctrl+Alt+W) that finds open workspaces, restores minimized ones, cascades them and brings them to the front. Same action: `-Cascade`.
- `git` setting: point at a portable `git.exe` that is not on PATH.
- `Install-Shortcut.ps1` checks that Git and Visual Studio Code are installed and stops with instructions if not (`-SkipPrereqCheck` overrides).
- This changelog, linked from Settings and offered after an update.

### Changed
- README simplified and install steps added; the configuration reference moved to `docs/configuration.md`. Release notes now carry install instructions (`tools/release-install.md`).

### Fixed
- Azure DevOps SSH remotes now produce a working web link.

## 0.5.0 - 2026-11-24

### Added
- Renamed to **Workspace Wrangler** (`Start-WorkspaceWrangler.ps1`); `Install-Shortcut.ps1` retargets shortcuts that still use the old script name.
- **Updates from GitHub releases:** non-blocking check at startup, an update bar with What's new / Update now / Skip this version, in-place install (git fast-forward or zip) running in the background with rollback, and `-CheckUpdate` for agents.
- Cowboy-hat icon and `Uninstall-WorkspaceWrangler.ps1` (supports `-WhatIf`).

### Changed
- Pinning was removed; the list is always ordered by newest activity.

## 0.4.0 - 2026-11-24

### Added
- Window arrangement: cascade on launch, **Arrange** button (cascade, grid, side by side, stacked, reset size), saved layouts per monitor setup, `keepDesktopIconsClear`.

## 0.3.1 - 2026-11-24

### Added
- Background refresh of open-project detection (`refreshSeconds`).
### Changed
- README rewritten around the "restart your workday in one click" idea; specs refreshed.

## 0.3.0 - 2026-11-24

### Added
- Remote column for any git host; settings moved to `~\.config\workspace_picker\` (later `workspace_wrangler`); one terminal window per project; compact tab titles `cc:` / `sh:`; launching an open project focuses it (Shift+Launch opens a new copy).

## 0.2.0 - 2026-11-24

### Added
- Persistent picker with open-project detection and **Switch**; `-Focus`; `running` in `-List`; clickable GitHub column.

## 0.1.0 - 2026-11-24

- First experimental release: discover projects, pick, launch Claude Code and shell tabs in Windows Terminal.
