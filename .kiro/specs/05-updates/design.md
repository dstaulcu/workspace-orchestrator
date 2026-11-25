# Design: Update management

- `Start-UpdateCheck` returns a `Task` from `HttpClient.GetStringAsync` (10 s timeout), or `$null` when disabled or throttled. The picker polls `Task.IsCompleted` from a WinForms timer, so startup never waits on the network.
- `Complete-UpdateCheck` parses the JSON (PowerShell 5.1 emits a JSON array as a single object, so it is enumerated with `foreach`), keeps the highest version, stores `{ tag, url, zip }` as `state.update` with `lastUpdateCheck`, and returns `Get-UpdateInfo`.
- `Get-UpdateInfo` compares `state.update` with `$AppVersion` and honors `skipVersion`; it also serves the cached notice when the throttle skips the network.
- `Install-Update` has two paths (git fast-forward, zip copy with backup); see R3. `Restart-Wrangler` starts a new hidden-window picker the same way the desktop shortcut does, then the old picker closes.
- WinForms closures cannot see script functions, so the picker receives a hashtable of scriptblocks (`Start`, `Done`, `Cached`, `Install`, `Skip`, `Restart`, plus `Current`).
- State keys added to `state.json`: `lastUpdateCheck`, `update`, `skipVersion`.

## Verified

- `-CheckUpdate` against a repo with releases (current and an older pretend version), the update notice in the picker, and the zip path against a fabricated release (new files copied, old ones backed up) and a wrong zip (refused, nothing changed).
- Not click-tested: the confirmation dialog and restart.
