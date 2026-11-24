# Requirements: Interactive Picker

## Introduction

When run without selection arguments, the launcher shows a picker so the user can choose which projects to open. It should make "what was I working on?" obvious and remember preferences.

## Requirements

### R1. Multi-select list
**User story:** As a developer, I want to see all my projects, newest first, and select several.

1. WHEN no `-Project`, `-All` or `-List` is given THEN the system SHALL show a picker listing every project (unless `-Top N` limits it).
2. The picker SHALL show name, relative time, absolute time, git branch, clean/dirty state and path.
2a. WHEN the mouse hovers a column header THEN the picker SHALL show a tooltip explaining that column (Project, Open, Last active, When, Branch, State, Path). Buttons, checkboxes and the filter box SHALL likewise have hover tooltips.
3. WHEN the user cancels or closes the picker THEN the system SHALL launch nothing.
4. WHEN the user clicks Launch with nothing checked but rows highlighted THEN the highlighted rows SHALL be used; with neither, the picker SHALL stay open.

### R2. Filter
1. WHEN the user types in the filter box THEN the list SHALL narrow to projects whose name or path contains the text (case-insensitive) while preserving checked state.
2. WHEN `-Filter <text>` is given THEN the box SHALL be pre-filled.

### R3. Pinning
1. WHEN the user selects rows and clicks Pin/Unpin THEN each row's pinned state SHALL toggle and the list SHALL re-sort with pinned projects (marked ★) first.
2. Pins SHALL persist across runs in `state.json`, including when the picker is cancelled.

### R4. Remember last selection
1. WHEN a launch is made through the picker THEN the system SHALL save the launched projects to `state.json`.
2. WHEN the picker opens THEN the previously launched projects SHALL be pre-checked.

### R5. Fresh sessions
1. The picker SHALL offer a "Fresh sessions" checkbox that makes the launch use plain `claude`.

### R6. Alternate picker
1. WHEN `-Picker Grid` (or config `picker: Grid`) is set THEN the system SHALL use `Out-GridView -PassThru` instead.

### R8. Persistent picker and switching to open workspaces
**User story:** As a developer with many terminal windows, I want to find and bring forward a workspace that is already open.

1. WHEN `keepOpen` is true (default; also a checkbox) THEN the picker SHALL remain open after Launch and SHALL uncheck the launched projects.
2. The picker SHALL show which projects have an open `claude-code-<project>` or `shell-<project>` tab in any Windows Terminal window (● column and highlighted row).
3. The open-project list SHALL refresh on opening, on a Refresh button, when the picker regains focus (throttled to once per 3 s), and about 4 s after a launch.
4. WHEN the user highlights a project and clicks Switch THEN the system SHALL select that project's `claude-code-` tab (else its `shell-` tab) and bring its window to the foreground, restoring it if minimized.
5. IF no matching tab exists THEN the picker SHALL say so and leave the list unchanged.
6. IF UI Automation is unavailable THEN no project SHALL be shown as open and launching SHALL still work.

### R7. Non-destructive
1. A `-DryRun` through the picker SHALL NOT save last-selection (pins are still saved only when not a dry run).

