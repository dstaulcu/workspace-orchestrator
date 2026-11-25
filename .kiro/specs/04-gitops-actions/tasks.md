# Tasks: Git actions

- [x] 1. `Invoke-GitOp` core: `init`, `remote` (gh repo create), `-DryRun` reporting (R3, R4, R5)
- [x] 2. `Get-GitHubOwners`, `ConvertTo-RepoName`, `Test-GitHasCommits` helpers (R4)
- [x] 3. `Show-NewRemoteDialog`: owner, name, visibility, push, live summary, validation (R4)
- [x] 4. `Invoke-PickerGitOp`: confirm, run, refresh the row in place (R3, R4)
- [x] 5. Git button + row right-click menu with per-row enablement and tooltips; `$OnGitOp` callback (R1, R2)
- [x] 6. `gitOpsOrg`, `gitOpsVisibility` in config, schema and README; Safety section updated (R5)

## Not done / ideas

- [ ] Hands-on test under Windows PowerShell 5.1 (written without a Windows machine; not yet run)
- [ ] Optional first commit after `git init` so the push option is available right away
- [ ] Agent-mode switches (e.g. `-GitInit`, `-GitRemote <org>`) that call `Invoke-GitOp`
- [ ] Other hosts (GitLab, Azure DevOps) and other version control systems (#2)
