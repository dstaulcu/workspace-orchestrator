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

- [x] 6. Persistent picker and switching (R8)
  - [x] 6.1 Spike: UI Automation enumerates tabs, selects a tab, raises its window across multiple Windows Terminal windows
  - [x] 6.2 `Get-TerminalTabs`, `Get-RunningNames`, `Switch-ToProject`
  - [x] 6.3 Extract `Invoke-Launch`; picker launches via `$OnLaunch` callback
  - [x] 6.4 "Open" column + green rows; Refresh button; refresh on Shown / Activated / after launch
  - [x] 6.5 Switch button; "Keep open after launch" checkbox; `keepOpen` config
  - [x] 6.6 Smoke test: picker opens and reports an open project found

- [x] 7. Column header tooltips (R1.2a): ListView headers have no native tooltips, so `MouseMove` hit-tests the header strip and shows a `ToolTip` per column

- [x] 8. Help links (R9): LinkLabel to repo, issues and new-issue page

- [x] 9. GitHub links (R10): `ConvertTo-GitHubUrl` + remote lookup in `Get-GitInfo`, GitHub column with link styling, click-to-open, `githubUrl` in `-List`

## Not done / ideas

- [ ] Hover-test the tooltips by hand (only load-tested)
- [ ] Hands-on test of Launch / Switch button clicks (UI Automation can't see WinForms rows)
- [ ] Double-click a row: switch if open, launch if not
- [ ] System tray icon instead of a normal window
- [ ] Hands-on UI test pass (only dry-run verified so far)
- [ ] Column sorting by click, keyboard shortcut for pin
- [ ] Remember window size and position


