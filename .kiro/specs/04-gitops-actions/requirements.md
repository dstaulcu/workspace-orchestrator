# Requirements: Git actions

## Introduction

A category of GitOps-oriented actions in the picker, so getting a project under version control and onto GitHub doesn't mean leaving the picker for a terminal and a browser. Tracks issue #4.

## Requirements

### R1. Git menu
**User story:** As a developer, I want git actions for the highlighted project in one place.

1. The picker SHALL have a **Git** button that opens a menu of actions for the highlighted project; the same menu SHALL be the list's right-click menu.
2. Each action SHALL be enabled only where it applies (R2-R4), with a tooltip saying why when it is disabled. With no row highlighted, every action SHALL be disabled.
3. The outcome of every action (success, cancel, or the first line of the error) SHALL be shown on the status line.

### R2. Open repository
1. WHEN the project has a browsable remote (as in the Remote column) THEN **Open repository in browser** SHALL open it in the default browser.

### R3. Initialize local repository
1. WHEN the project folder is not a git repository THEN **Initialize local repository** SHALL ask Yes/No and, on Yes, run `git init` in it.
2. On success the row's branch and state SHALL refresh without restarting the picker.

### R4. Create remote repository on GitHub
**User story:** As a developer, I want to create a GitHub repository for a project in a specified organization and connect it, without leaving the picker.

1. WHEN the project has no remote THEN **Create remote repository on GitHub** SHALL open a dialog with: owner (an editable list of the signed-in user's account and organizations from the GitHub CLI, pre-filled with `gitOpsOrg` or else the user's account), repository name (the folder name with characters GitHub doesn't allow replaced by `-`), visibility (`private`, `internal`, `public`; default `gitOpsVisibility`, else private), and **Push the current branch** (enabled only when the repo has commits).
2. The dialog SHALL state in one sentence what will happen, updated as the fields change.
3. ON Create THEN the system SHALL run `gh repo create <owner>/<name> --<visibility> --source <folder> --remote origin` (plus `--push` if ticked); blank owner means the user's own account. If the folder is not a repo, `git init` SHALL run first.
4. Invalid repository or owner names SHALL be rejected in the dialog without running anything.
5. IF `gh` is not installed THEN the system SHALL say how to get it and run nothing. IF the project already has an `origin` remote THEN nothing SHALL run.
6. On success the Remote column SHALL show the new repository and link to it.

### R5. Safety
1. Nothing SHALL change a project without the confirmation in R3 or the Create button in R4.
2. WHEN `-DryRun` is set THEN actions SHALL report the command they would run and change nothing.
3. The script SHALL NOT read, store or log GitHub tokens; it relies on the user's existing `gh` sign-in.
4. Agent mode (`-List`, `-Project`, `-All`, `-Focus`) SHALL stay free of these actions and of any UI.
