# Requirements: Project Discovery and Launch

## Introduction

A launcher that finds recently active project folders and opens them as workspaces, each project in its own Windows Terminal window: a Claude Code tab and a PowerShell tab per project. Generalizes a hand-built, single-project launcher.

## Requirements

### R1. Discover projects
**User story:** As a developer, I want my project folders found automatically so I don't maintain a list.

1. WHEN the launcher runs THEN the system SHALL treat each immediate subfolder of the configured root as a project.
2. WHEN a folder name is in the ignore list or starts with `.` THEN the system SHALL exclude it.
3. IF the root does not exist THEN the system SHALL warn and exit with code 1.

### R2. Rank by recent activity
**User story:** As a developer, I want the projects I touched last at the top.

1. WHEN a project contains `.git` and has at least one commit THEN the system SHALL use the latest commit time as its last-active time.
2. IF git is unavailable, the repo has no commits, or there is no `.git` THEN the system SHALL use the newest file `LastWriteTime`.
3. WHEN scanning files THEN the system SHALL skip configured noise directories and SHALL stop after a maximum file count and directory depth.
4. The system SHALL order projects newest first.

### R3. Open a window per project with its tabs
**User story:** As a developer, I want each selected project open in its own terminal window with no manual `cd`.

1. WHEN projects are launched THEN the system SHALL invoke `wt.exe` once per project (`-w new`), producing one window each (see R9).
2. FOR each project the system SHALL create a Claude Code tab titled `cc:<project>`, starting in the project directory.
3. WHEN a project has Claude session history (`~\.claude\projects\<path-encoded>`) AND fresh mode is not requested THEN the Claude tab SHALL run `claude --continue`; otherwise `claude`.
4. WHEN the shell tab is enabled (default) THEN the system SHALL create a PowerShell tab titled `sh:<project>` in the project directory. Preset extra tabs SHALL be titled `sh:<title>`.
5. WHEN the project is a git repository AND diff is enabled (default) THEN the shell tab SHALL run `git status -sb` and `git diff --stat` on open.
6. WHEN tab colors are enabled (default) THEN all tabs of a project SHALL share a color derived deterministically from the project name.
7. WHEN launching into a new window THEN each window SHALL finish by focusing its first tab.
8. WHEN `-Window <id>` is given THEN the system SHALL add tabs to that window and SHALL NOT emit `focus-tab`.

### R4. Robust `wt` command construction
1. The system SHALL build a single argument string and pass it verbatim to `Start-Process wt.exe`.
2. Any `;` inside a tab's command SHALL be escaped as `\;`; only the separators between tab clauses SHALL be bare `;`.
3. Each tab SHALL both pass `-d <dir>` and run `Set-Location -LiteralPath <dir>`.
4. Paths containing spaces or single quotes SHALL be handled.
5. IF a project directory is missing THEN the system SHALL warn and skip it without failing the others.

### R5. Safety
1. Launching SHALL NOT modify any project folder.
2. No credentials or secrets SHALL be stored or required.

### R6. Entry point
1. The system SHALL provide an installer that creates a Desktop `.lnk` ("Workspace Picker") targeting `powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File <script>` with the Windows Terminal icon.
2. WHEN `-Project <name>` is passed to the installer THEN the shortcut SHALL launch that project directly.
3. Re-running the installer SHALL overwrite the shortcut (idempotent).

### R9. Window per project, compact titles
1. WHEN several projects are launched THEN each SHALL open in its own new Windows Terminal window (one `wt -w new` call per project); `-Window <id>` SHALL instead put all tabs in that window.
2. Tab titles SHALL be short: `cc:<project>` for the Claude tab and `sh:<scope>` for others. Detection SHALL also accept the legacy `claude-code-` / `shell-` prefixes so tabs opened by older versions still show as open.
3. WHEN a selected project already has an open `cc:`/`sh:` tab THEN launching it SHALL bring that tab's window to the foreground instead of opening a second copy; the remaining projects SHALL launch normally. `-DryRun` SHALL print `FOCUS (already open): <name>` for these.
4. Shift+Launch in the picker SHALL skip that check and open a new window even if the project is already open.

### R10. Window arrangement
1. WHEN 2 or more new windows are launched AND `arrangeOnLaunch` is true THEN the system SHALL arrange them on the primary screen's work area once they appear (waiting up to 15 s), using `arrangeStyle`: `cascade` (default; overlapping, offset so title bars stay visible), `grid`, `columns` or `rows`.
2. The picker's Settings menu SHALL offer "Save window layout", recording each open project's window rectangle and maximized state into `layouts.json`, keyed by the monitor configuration.
3. WHEN `restoreLayouts` is true AND a saved layout exists for the current monitor configuration THEN a launched project's window SHALL be placed at its saved position; remaining windows SHALL be arranged per item 1.
4. The picker SHALL have an Arrange button with a menu (Cascade, Tile in a grid, Side by side, Stacked, Reset window size, Restore saved layout only) that applies items 1 and 3 to all currently open project windows on demand (Shift = ignore saved layouts).
5. Cascade and Reset window size SHALL size windows to `windowWidth` x `windowHeight` (default 1100 x 750 px, clamped to the screen); grid, columns and rows SHALL fill their cells.
6. WHEN `keepDesktopIconsClear` is true (default) THEN arrangement SHALL start at the second desktop-icon row and column (offset by the Windows icon spacing), leaving the first column and row of desktop icons uncovered.
7. Launch-time arrangement SHALL NOT run in `-DryRun` or when `-Window <id>` is used, and a failure SHALL only warn.
