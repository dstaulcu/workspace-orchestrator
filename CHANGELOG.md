# Changelog

All notable changes to Workspace Wrangler. Newest first. The picker opens this file from **Settings > Changelog**
and offers it after an update. Add new entries under **Unreleased** as you work; rename that heading to the
version when you release.

## Unreleased

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
