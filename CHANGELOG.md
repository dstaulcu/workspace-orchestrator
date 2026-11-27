# Changelog

All notable changes to Workspace Wrangler. Newest first. The picker opens this file from **Settings > Changelog**
and offers it after an update. Add new entries under **Unreleased** as you work; rename that heading to the
version when you release.

## Unreleased

### Added
- **Dark mode.** The picker and its dialogs (New project, Rename, Launch options, Create remote, Add remote, Projects folders, Data health, About) now follow Windows' app mode (**Settings > Personalization > Colors > Choose your default app mode**): dark backgrounds, text boxes, buttons, list and column headers, menus, tooltips and a dark title bar. Change the Windows setting while the picker is open and it switches without a restart. The list's colors have dark versions too (open projects stay green, the Remote link stays blue, the branch cue stays orange), and its grid lines are a dim gray instead of white.
- **Settings > Theme** (Match Windows, Light, Dark), saved as the new `theme` setting in `config.json` (`system`, `light` or `dark`; default `system`). High contrast mode always wins over dark.

### Fixed
- **Launch options** no longer logs an error when a project has no fixed tab color; the color swatch now shows the dialog's background in that case.

### Known limits
- Message boxes (confirmations, results) and the folder and color pickers are drawn by Windows and keep its own look. Tooltips on menu items stay light.

## 1.9.0 - 2026-11-27

### Added
- **Git > Push current branch to origin...** pushes the current branch after showing the project, the remote URL, the branch, how many commits will go and the exact command (`git push -u origin <branch>` the first time, `git push` after that). It is a plain push: never forced, no tags, no other branches. It is greyed out without an `origin`, refuses when there are no commits or nothing new to push, and when the remote rejects the push it stops and explains (the remote has newer commits; this app does not pull). Results use the same message box and `app.log` entry as the other Git actions.

### Changed
- The IDE entry on the right-click menu now shows the product name (for example **Open in Visual Studio Code**) instead of the command in `config.json` (`code`); the command is kept in the tooltip. Known commands (VS Code and Insiders, VSCodium, Cursor, Windsurf, Zed, Sublime Text, the JetBrains IDEs, Visual Studio, Notepad++, Emacs, Vim) get their product name; anything else shows the command name. The IDE button's result message uses it too.

## 1.8.2 - 2026-11-27

### Added
- **Branch name cue.** When a clone is on `main` but remembers origin's default branch as `master` (or the reverse), typically after renaming on only one side, the Branch cell turns orange and its hover explains which command fixes it (`git remote set-head origin -a`, or the fetch / rename / upstream sequence). It reads git's local `origin/HEAD` ref, so there is no network call; feature branches and matching repositories show nothing.
- README section **Branch names (main, not master)** with the policy and the exact host-side rename and local sync sequence.

## 1.8.1 - 2026-11-27

### Changed
- **Rename branch to main is now local-only and refuses when `origin` already has branches.** It no longer pushes anything. The host owns the default branch, pull request targets and branch protection, and pushing a second `main` next to an existing `master` splits the history. When `origin` has branches (or cannot be reached) it changes nothing and shows the safe sequence instead: rename the branch on the host (GitHub: Settings > Branches), then `git fetch origin --prune`, `git branch -m <old> main`, `git branch -u origin/main main`, `git remote set-head origin -a`. With no remote, or an empty one, it renames the local branch as before.
- **Create remote repository** warns, in the dialog summary, when the local branch is `master` (it becomes the host's default branch), and points to the rename item.

## 1.8.0 - 2026-11-27

### Added
- **Git > Rename branch to main...** renames an existing repository's current branch to `main` after showing the exact commands and asking. With no commits it only changes the branch name; with commits it runs `git branch -m <old> main`. If `origin` has the old branch, it also pushes `main` and sets it as upstream (the old remote branch is left in place, and you are told to switch the host's default branch and delete it when ready). It refuses when `main` already exists, when HEAD is detached, or when the branch is already `main`. The result message also says what happened on origin (nothing to rename when it has no branches yet, or when the old branch was never pushed).

## 1.7.2 - 2026-11-27

### Changed
- **New repositories start on `main`.** `git init` from the Git menu, **+ New project** and **Create remote repository** now use `git init -b main` instead of whatever git defaults to (often `master`). The name comes from the new `defaultBranch` setting; git's own `init.defaultBranch`, if you set it, still wins. Older git without `-b` falls back to a plain init plus renaming the empty branch. Existing repositories are not renamed.

## 1.7.1 - 2026-11-27

### Added
- `docs/data-flow.md`: diagrams of how the Cost feature reads Claude Code's session files, what it keeps in `costs.json` and what it drops, when the scan happens, and what that means for choosing `cleanupPeriodDays`; linked from the README's Project cost section.

## 1.7.0 - 2026-11-27

### Fixed
- **Creating a GitHub repository with visibility `internal` on a personal account** (which GitHub rejects) is now caught up front with a clear message, and the dialog will not accept it; error text from `gh`, `glab` and `git` no longer carries PowerShell's "At line:..." decoration.
- **Errors go to a log.** Failed Git actions are written to `app.log` in the settings folder. **Settings > Copy diagnostics** copies versions plus the recent log (user name and home folder masked) for pasting into an issue; **Settings > Open the log** opens it.
- **Git actions now always report their outcome.** Results of Git > Initialize / Create remote repository / Add existing remote used to appear only in the small status line, which the window overwrites when it is re-activated after a dialog, so a failed or successful action could look like nothing happened. A message box now shows the result (with the first lines of the tool's error and the exact command for a failed GitHub or GitLab create).

### Added
- **Project cost (opt-in):** an optional Cost column with each project's estimated API-equivalent Claude Code cost, computed from Claude Code's local session files (de-duplicated, subagents included) and kept in the Wrangler's own ledger (`costs.json`) so it survives Claude Code's cleanup. Prices live in `assets/model-prices.json` (override in `~/.config/workspace_app/model-prices.json`). Settings > Show project cost turns it on; Settings > Claude Code data health... shows retention/telemetry status and, after confirmation, can set `cleanupPeriodDays`. `-List` includes `costUsd` when enabled.

## 1.6.0 - 2026-11-26

### Changed
- **One selection instead of two.** Ticking a box and highlighting a row used to be separate (Launch used the ticked rows; Switch, IDE, Git and the right-click menu used the highlighted ones). They are now the same selection: ticking a box highlights the row, and Ctrl-clicking, Shift-clicking or Ctrl+A selecting rows ticks them. Every button and the right-click menu act on that one set, it survives filtering and sorting (the status line says how many selected rows the filter is hiding), and right-clicking an unselected row selects just that row first. The hint line and tooltips now teach Ctrl/Shift.

## 1.5.1 - 2026-11-26

### Fixed
- **Refresh now rescans your project folders.** A project folder created (or deleted) while the picker is open used to be missing (or stale) until you restarted it; Refresh now adds new folders, drops vanished ones and says so in the status line (for example "1 new, 0 gone"). It skips this when the list was narrowed with `-Filter`, `-Top` or `-Project`.

## 1.5.0 - 2026-11-26

### Added
- **Demo workspace:** `tools/New-DemoWorkspace.ps1 -Launch` builds a throwaway set of fake projects (dirty and clean repos, fake GitHub, GitLab and Azure remotes, two `api` projects) with its own settings and a stand-in for `claude`, so you can try the picker without touching your own folders; `-Remove` deletes it. It uses the new `WORKSPACE_APP_CONFIG` environment variable, which points the app at any settings folder.
- A screenshot tour (`docs/tour.md`, images in `docs/images/`), a short animated demo (`docs/images/demo.gif`) and a gallery in the README, all captured from the demo workspace.

## 1.4.0 - 2026-11-26

### Added
- **Several project folders.** `config.json` takes a `roots` list (the single `root` still works) and a `projects` list for individual folders that are projects themselves. The first-run dialog and **Settings > Projects folders...** now let you check several folders (with the optional, on-request folder suggestions), and everything merges into one list. If two projects share a folder name, the later one is shown as `name (parentfolder)`, so tab titles, presets and saved layouts stay unique. **New project** asks which folder to create the project in when you use more than one. `-Root a,b` accepts several folders too.

## 1.3.1 - 2026-11-26

### Fixed
- **First run now always asks where your projects are.** Previously the dialog only appeared if the default `C:\code` was missing or empty, so a fresh install on a machine that has `C:\code` silently used it. Now, when there is no `config.json` and no `state.json` (new install, or settings removed), the picker shows the folder dialog first, with the likely folders pre-listed. Existing installs are not asked again; cancelling the dialog asks again next time.
- **The folder dialog no longer scans anything on its own.** It explains what suggesting folders would read (the project list in Claude Code's `~\.claude.json`, VS Code's recent-folders list, and whether common folders like `code` or `src` exist; folder names only, nothing changed, saved or sent) and only does it when you click **Look for likely folders**; **Browse...** works without it. The dialog also shows the app's hat icon instead of the concept art, which looked poor at that size.

## 1.3.0 - 2026-11-26

### Changed
- **File names no longer carry the product name**, so a fork can rebrand without renaming files: `Start-WorkspaceWrangler.ps1` is now `Start-App.ps1`, `Uninstall-WorkspaceWrangler.ps1` is `Uninstall-App.ps1`, the tools are `tools/New-AppIcon.ps1` and `tools/New-ArtAssets.ps1`, and the images are `assets/app.ico`, `app.png`, `concept.jpg`, `mark.png`, `splash.jpg` and `social-preview.jpg`.
- Settings are copied once from `~\.config\workspace_wrangler` to `~\.config\workspace_app` the first time the picker starts (the old folder is left in place as a backup; `-List`, `-DryRun` and the other switches read it in place). `Install-Shortcut.ps1` re-points existing shortcuts at `Start-App.ps1` and gives them the new icon.
- Small `Start-WorkspaceWrangler.ps1` and `Uninstall-WorkspaceWrangler.ps1` stubs remain and forward to `Start-App.ps1` / `Uninstall-App.ps1`, so shortcuts, in-place updates and old habits from 1.2.x and earlier keep working. They will be removed in v2.
- `Uninstall-App.ps1` now matches only this folder's scripts when stopping pickers and deleting shortcuts, so an unrelated `Start-App.ps1` elsewhere is never touched.
- The app icon is redrawn in the concept art's palette (night sky, sunset glow, neon cyan, cyan visor). Small sizes (16 to 48 px) are drawn natively with bolder shapes instead of shrunk from the large drawing, and 20 and 40 px sizes were added for 125% display scaling, so the title bar and taskbar are crisp.

### Added
- **Branding:** concept art on the README, a **startup splash** shown while your projects are scanned, a rider mark in the first-run folder dialog, a redrawn app icon in the same night-sky/neon palette as the art, and an **About** box (Help links, or Settings > About Workspace Wrangler...) with the full art, version and links. The image prompt is kept in `docs/concept-art.md` as the baseline for future variations; `tools/New-ArtAssets.ps1` makes the smaller derived images.

## 1.2.2 - 2026-11-26

### Changed
- The **Rename project** dialog shows the same noun-verb naming tip as New project.

## 1.2.1 - 2026-11-26

### Changed
- The **New project** dialog suggests noun-verb names (gray example text in the name box and a short tip, e.g. `page-distill`). It is a suggestion only; any valid folder name still works.

## 1.2.0 - 2026-11-26

### Added
- **State filter** dropdown beside the filter box: show only dirty (uncommitted), clean, open, not-open or non-git projects. It combines with the text filter, which now also matches the branch.
- **Click a column header to sort** the list (click again to reverse); the header shows the direction.

## 1.1.2 - 2026-11-26

### Fixed
- **Refresh** no longer freezes the window: the git re-read runs in the background, the button is disabled while it works, and the list is re-sorted by the new activity times.
- Refresh no longer blanks the git columns when git info is off, and reports an error instead of claiming success when the check fails.

## 1.1.1 - 2026-11-25

### Changed
- **Refresh** now also re-reads each project's git branch, clean/dirty state, remote and last-activity time, not just which projects have tabs open.

## 1.1.0 - 2026-11-25

### Added
- **Launch options...** on the right-click menu: edit a project's `presets.json` entry from a dialog (Claude arguments, shell tab and git summary on/off, tab color) plus two new preset fields, **`startupCommand`** (runs in the shell tab, e.g. `npm run dev`) and **`urls`** (http/https addresses opened in your default browser each time the project is launched, not when an already-open project is only raised). Other keys in the entry (extra tabs, extra apps) are preserved.

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
