# Tasks: Project Discovery and Launch

- [x] 1. Discovery (R1)
  - [x] 1.1 Enumerate subfolders of root; apply ignore list and skip dot-folders
  - [x] 1.2 Warn and exit 1 when root is missing
- [x] 2. Last-active ranking (R2)
  - [x] 2.1 Git commit time via `git log -1 --format=%ct`
  - [x] 2.2 Capped file-time fallback with noise-dir exclusion (explicit stack walk)
  - [x] 2.3 Relative time formatter
- [x] 3. Tab construction (R3, R4)
  - [x] 3.1 `New-TabClause` with title, color, `-d`, explicit `Set-Location`, `\;` escaping
  - [x] 3.2 Claude tab: `--continue` only with session history (`Test-ClaudeHistory`)
  - [x] 3.3 Shell tab with `git status -sb; git diff --stat` for repos
  - [x] 3.4 Deterministic tab colors (`Get-TabColor`)
  - [x] 3.5 `focus-tab -t 0`, skipped when `-Window` targets an existing window
  - [x] 3.6 Skip and warn on missing directories
- [x] 4. Launch (R3.1)
  - [x] 4.1 Single `Start-Process wt.exe -ArgumentList <string>`
  - [x] 4.2 `-DryRun` prints the string instead
- [x] 5. Entry point (R6)
  - [x] 5.1 `Install-Shortcut.ps1` (Desktop `.lnk`, hidden window, WT icon, optional `-Project`)
- [x] 6. Verified by dry run under Windows PowerShell 5.1 (paths with spaces, `\;` placement)

- [x] 7. Tab naming (issue #1, naming part): harness tab `cc:<project>`, other tabs `sh:<scope>`
- [x] 8. Window per project (`-w new`), compact `cc:`/`sh:` titles, focus-if-open, Shift+Launch (R9)

## Not done / ideas

- [ ] Configurable harnesses (rest of issue #1; deliberately deferred, the tool stays Claude Code-centric)
- [ ] Automated tests (Pester) asserting the generated `wt` string
- [ ] Per-project startup command
- [ ] Non-Windows terminals (tmux, iTerm)
