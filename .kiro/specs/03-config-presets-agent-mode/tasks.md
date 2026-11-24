# Tasks: Configuration, Presets and Agent Mode

- [x] 1. Configuration (R1)
  - [x] 1.1 Built-in defaults hashtable
  - [x] 1.2 Overlay `config.json` with parse-failure warning
  - [x] 1.3 Parameters override config via `PSBoundParameters`
- [x] 2. Presets (R2, R3)
  - [x] 2.1 Load `presets.json`; match by folder name
  - [x] 2.2 `extraTabs` and `launch` (extra apps) with missing-path warnings
  - [x] 2.3 Per-project `claudeArgs`, `shell`, `diff`, `tabColor`
  - [x] 2.4 `presets.example.json`; git-ignore `presets.json` and `state.json`
- [x] 3. Agent mode (R4)
  - [x] 3.1 `-List` JSON output with stable schema
  - [x] 3.2 `-Project a,b` (comma split, name or path, fast path without scan)
  - [x] 3.3 Exit code 1 when nothing matches
  - [x] 3.4 `-All` with default cap of 15
  - [x] 3.5 `-DryRun` prints `wt` args and app launches; no state writes
- [x] 4. Switches (R5): `-Fresh`, `-NoShell`, `-NoDiff`, `-NoColor`, `-Window`, `-Filter`, `-Top`
- [x] 5. Verified by dry runs under Windows PowerShell 5.1 (`-List`, multi-name `-Project` with an unknown name, `-Window`)

- [x] 6. Focus (R6): `-Focus <project>` (exit 1 if not open); `running` in `-List`; `keepOpen` config

## Not done / ideas

- [ ] Pester tests for precedence and the JSON contract
- [ ] JSON schema file for `config.json` / `presets.json`
- [ ] Named workspace sets ("morning", "release") that map to project lists
