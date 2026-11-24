# Requirements: Interactive Picker

## Introduction

When run without selection arguments, the launcher shows a picker so the user can choose which projects to open. It should make "what was I working on?" obvious and remember preferences.

## Requirements

### R1. Multi-select list
**User story:** As a developer, I want to see all my projects, newest first, and select several.

1. WHEN no `-Project`, `-All` or `-List` is given THEN the system SHALL show a picker listing every project (unless `-Top N` limits it).
2. The picker SHALL show name, relative time, absolute time, git branch, clean/dirty state and path.
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

### R7. Non-destructive
1. A `-DryRun` through the picker SHALL NOT save last-selection (pins are still saved only when not a dry run).
