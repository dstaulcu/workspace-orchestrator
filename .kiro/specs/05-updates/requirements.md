# Requirements: Update management

## Introduction

Workspace Wrangler is distributed as GitHub releases. The picker should notice a newer release, tell the user, and upgrade in place without touching their settings.

## Requirements

### R1. Check on startup
1. WHEN the picker opens AND `checkForUpdates` is true AND the last check was at least `updateCheckHours` ago (default 24) THEN the system SHALL request the repository's releases list from the GitHub API (`updateRepo`, default `dstaulcu/workspace-wrangler`) without blocking the UI.
2. The newest non-draft release (prereleases included) by version number SHALL be compared with `$AppVersion`; the tag's `major.minor.patch` is used.
3. WHEN a check is skipped because of the throttle THEN a previously discovered newer release SHALL still be shown.
4. The request SHALL carry only a generic user agent, and failures (offline, rate limit, missing repo) SHALL be silent.
5. Agent modes (`-List`, `-Project`, `-All`, `-Focus`, `-DryRun`) SHALL NOT check automatically. `-CheckUpdate` SHALL check once and print JSON `{ current, checked, latest, updateAvailable, url }`.

### R2. Notice and choices
1. WHEN a newer release exists THEN the picker SHALL show "Update available: vX.Y.Z" with links **What's new** (release page), **Update now** and **Skip this version**, in place of the hint line.
2. **Skip this version** SHALL hide that tag until a newer one is released and SHALL persist in `state.json` (`skipVersion`).
3. **Settings > Check for updates now** SHALL check immediately, ignore the throttle and any skip, and report "up to date" or the available version in the status line.

### R3. Applying an update
1. **Update now** SHALL ask for confirmation, then update in place and restart the picker. Open terminal windows SHALL NOT be affected.
2. WHEN the install folder is a git clone THEN the system SHALL refuse if the working tree has uncommitted changes, else `git fetch --tags` and `git merge --ff-only <tag>`.
3. OTHERWISE the system SHALL download the release zip, verify it contains `Start-WorkspaceWrangler.ps1`, back up every file it is about to replace under `~\.config\workspace_wrangler\backup\v<old version>\`, and copy the new files over the install folder.
4. Settings (`config.json`, `presets.json`, `state.json`, `layouts.json`) live outside the install folder and SHALL NOT be modified by an update.
5. ON failure the system SHALL report the reason and leave the running picker usable.

### R4. Versioning
1. The version is the `$AppVersion` constant in the script, bumped in each release commit; releases are tagged `vX.Y.Z[-suffix]`.
