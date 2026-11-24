# Tasks: Interactive Picker

- [x] 1. Baseline picker with `Out-GridView -PassThru` (R1, R6)
- [x] 2. Replace default with WinForms `Show-FormsPicker`
  - [x] 2.1 ListView with checkboxes and columns (project, when, timestamp, branch, state, path)
  - [x] 2.2 Launch / Cancel with Enter / Esc; stay open when nothing is chosen
  - [x] 2.3 Filter box with persistent checked state (R2)
  - [x] 2.4 Pin / Unpin with ★ marker and pinned-first sort (R3)
  - [x] 2.5 "Fresh sessions" checkbox (R5)
  - [x] 2.6 Shared mutable state via `$ctx` (closure scoping fix)
- [x] 3. Persistence (R3, R4, R7)
  - [x] 3.1 `state.json` load/save (`pinned`, `last`)
  - [x] 3.2 Pre-check last selection
  - [x] 3.3 Skip saving on `-DryRun`
- [x] 4. Git info columns (`Get-GitInfo`, branch + dirty)
- [x] 5. Keep `-Picker Grid` as a fallback

## Not done / ideas

- [ ] Hands-on UI test pass (only dry-run verified so far)
- [ ] Column sorting by click, keyboard shortcut for pin
- [ ] Remember window size and position
