# Requirements: Configuration, Presets and Agent Mode

## Introduction

Defaults and per-project behavior are data, not code. A UI-free mode lets scripts and AI agents discover projects and open workspaces.

## Requirements

### R1. Global configuration
1. WHEN `config.json` exists THEN the system SHALL load it over built-in defaults; invalid JSON SHALL produce a warning and fall back to defaults.
2. Configurable keys SHALL include `root`, `top`, `ignore`, `noiseDirs`, `maxScanFiles`, `maxScanDepth`, `picker`, `shell`, `diff`, `tabColors`, `gitInfo`, `claudeArgs`.
3. WHEN a command-line parameter is supplied THEN it SHALL override the config value.

### R2. Per-project presets
1. WHEN `presets.json` has an entry whose `name` matches a project folder (case-insensitive) THEN the system SHALL apply it.
2. A preset MAY define `extraTabs` (`title`, `path`), `launch` (`exe`, `args`), `claudeArgs`, `shell`, `diff`, `tabColor`.
3. Preset values SHALL override global config for that project; projects without a preset SHALL get only the defaults.
4. A missing extra-tab path SHALL warn and skip that tab; a missing executable SHALL warn and skip that app.
5. Machine-specific files (`presets.json`, `state.json`) SHALL be git-ignored; a `presets.example.json` SHALL document the shape.

### R3. Claude arguments
1. WHEN `claudeArgs` is set THEN it SHALL be appended to the `claude` command; semicolons SHALL be escaped for `wt`.

### R4. Agent mode (no UI)
1. WHEN `-List` is given THEN the system SHALL print a JSON array (name, path, lastActive ISO-8601, pinned, isGit, branch, dirty, hasClaudeHistory, hasPreset) and launch nothing.
2. `-List` SHALL honor `-Filter`, `-Top`, and `-Project`.
3. WHEN `-Project a,b` is given THEN the system SHALL launch exactly those projects (by folder name or full path), in the given order, without a picker and without scanning activity.
4. WHEN a requested project is not found THEN the system SHALL warn and continue; IF none are found THEN it SHALL exit with code 1.
5. WHEN `-All` is given THEN the system SHALL launch the top N (default 15) without a picker.
6. WHEN `-DryRun` is given THEN the system SHALL print the `wt` arguments (and extra app launches) and SHALL NOT start any process or write state.
7. Agent mode SHALL never open a dialog.

### R5. Window targeting and switches
1. `-Fresh`, `-NoShell`, `-NoDiff`, `-NoColor` SHALL override the corresponding defaults for one run.
2. `-Window <id>` SHALL be passed to `wt` as `-w <id>`.
