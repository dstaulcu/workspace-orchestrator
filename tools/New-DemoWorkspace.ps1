<#
.SYNOPSIS
    Builds a throwaway demo workspace so you can try the picker (or take screenshots) without touching your own projects.

.DESCRIPTION
    Creates, under -Path (default: C:\workspace-app-demo, a short path with no user name in it):
      code\  and  work\   eight fake projects across two project folders: dirty and clean repos, a feature branch,
                          fake remotes on GitHub, GitLab and Azure DevOps, one non-git folder, a repo last touched
                          months ago, and two projects named "api" (to show the name (parentfolder) labels)
      settings\           its own config.json, presets.json and state.json (the picker reads them through the
                          WORKSPACE_APP_CONFIG environment variable, so your real settings are never touched)
      bin\claude.cmd      a stand-in for `claude` that just prints a banner, so launching a demo project never opens
                          a real Claude Code session (skip it with -RealClaude)
    Everything is fake: names, remotes (example.invalid-style URLs), authors. Nothing leaves this computer.

.PARAMETER Path
    Where to build the demo. Rebuilt from scratch each time (only a folder this script made is ever deleted).
.PARAMETER Launch
    Start the picker on the demo workspace afterwards.
.PARAMETER RealClaude
    With -Launch: let the Claude tabs run your real `claude` instead of the stand-in.
.PARAMETER Remove
    Delete the demo folder and exit.

.EXAMPLE
    .\tools\New-DemoWorkspace.ps1 -Launch
#>
[CmdletBinding()]
param(
    [string]$Path = (Join-Path $env:SystemDrive '\workspace-app-demo'),
    [switch]$Launch,
    [switch]$RealClaude,
    [switch]$Remove
)
$ErrorActionPreference = 'Stop'
$marker = Join-Path $Path '.workspace-app-demo'

function Remove-Demo {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (-not (Test-Path -LiteralPath $marker)) { throw "$Path exists but was not made by this script (no .workspace-app-demo marker); not touching it." }
    Remove-Item -LiteralPath $Path -Recurse -Force
}
if ($Remove) { Remove-Demo; "Removed $Path"; return }

$git = (Get-Command git -ErrorAction SilentlyContinue).Source
if (-not $git) { Write-Warning 'git was not found: the demo projects will not be repositories (no branch/state/remote columns).' }

Remove-Demo
$codeDir = Join-Path $Path 'code'; $workDir = Join-Path $Path 'work'; $setDir = Join-Path $Path 'settings'; $binDir = Join-Path $Path 'bin'
New-Item -ItemType Directory -Force -Path $codeDir, $workDir, $setDir, $binDir | Out-Null
Set-Content -LiteralPath $marker -Value 'Made by tools/New-DemoWorkspace.ps1. Safe to delete.'

function Invoke-DemoGit([string]$Dir, [string]$When, [string[]]$GitArgs) {
    $env:GIT_AUTHOR_NAME = 'Demo Dev'; $env:GIT_AUTHOR_EMAIL = 'demo@example.invalid'
    $env:GIT_COMMITTER_NAME = 'Demo Dev'; $env:GIT_COMMITTER_EMAIL = 'demo@example.invalid'
    if ($When) { $env:GIT_AUTHOR_DATE = $When; $env:GIT_COMMITTER_DATE = $When }
    try {
        $out = & $git -C $Dir -c commit.gpgsign=false -c core.autocrlf=false @GitArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed in $Dir : $out" }
    } finally { Remove-Item Env:GIT_AUTHOR_DATE, Env:GIT_COMMITTER_DATE -ErrorAction SilentlyContinue }
}

# $Spec: Age (minutes since the last activity), Branch, Dirty, Remote, Git (default $true), Files (names to create).
function New-DemoProject([string]$Root, [string]$Name, [hashtable]$Spec) {
    $dir = Join-Path $Root $Name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $when = (Get-Date).AddMinutes(-[double]$Spec.Age)
    $files = @('README.md'); if ($Spec.Files) { $files = @($Spec.Files) }
    foreach ($f in $files) {
        $p = Join-Path $dir $f
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null
        Set-Content -LiteralPath $p -Value "# $Name`r`nDemo project for Workspace Wrangler screenshots.`r`n"
    }
    $useGit = $git -and ($Spec.Git -ne $false)
    if ($useGit) {
        $iso = $when.ToString('yyyy-MM-ddTHH:mm:ss')
        Invoke-DemoGit $dir $null @('init', '-q')
        $branch = 'main'; if ($Spec.Branch) { $branch = [string]$Spec.Branch }
        Invoke-DemoGit $dir $null @('symbolic-ref', 'HEAD', "refs/heads/$branch")
        Invoke-DemoGit $dir $iso @('add', '-A')
        Invoke-DemoGit $dir $iso @('commit', '-q', '-m', 'Initial commit')
        if ($Spec.Remote) { Invoke-DemoGit $dir $null @('remote', 'add', 'origin', [string]$Spec.Remote) }
        if ($Spec.Dirty) { Set-Content -LiteralPath (Join-Path $dir 'notes.txt') -Value "work in progress`r`n" }
    }
    foreach ($f in (Get-ChildItem -LiteralPath $dir -File -Recurse -Force | Where-Object { $_.FullName -notmatch '\\\.git\\' })) { $f.LastWriteTime = $when }
    # Folders too: for a non-git project the picker's "last active" also counts the folder's own time.
    foreach ($d in (@(Get-Item -LiteralPath $dir) + @(Get-ChildItem -LiteralPath $dir -Directory -Recurse -Force | Where-Object { $_.FullName -notmatch '\\\.git(\\|$)' }))) { $d.LastWriteTime = $when }
}

# name -> spec. Ages: minutes.
New-DemoProject $codeDir 'page-distill'  @{ Age = 12;    Remote = 'https://github.com/example-dev/page-distill.git' }
New-DemoProject $codeDir 'invoice-send'  @{ Age = 140;   Remote = 'https://github.com/example-dev/invoice-send.git'; Dirty = $true; Files = @('README.md', 'package.json', 'src\index.js') }
New-DemoProject $codeDir 'log-triage'    @{ Age = 1500;  Remote = 'https://gitlab.com/example-dev/log-triage.git'; Branch = 'feature/triage-rules'; Dirty = $true }
New-DemoProject $codeDir 'tag-registry'  @{ Age = 4300;  Remote = 'https://github.com/example-dev/tag-registry.git' }
New-DemoProject $codeDir 'report-build'  @{ Age = 13000; Branch = 'master' }
New-DemoProject $codeDir 'sketch-pad'    @{ Age = 86000; Git = $false; Files = @('ideas.md', 'wireframe.txt') }
New-DemoProject $codeDir 'api'           @{ Age = 20000; Remote = 'https://github.com/example-dev/api.git' }
New-DemoProject $workDir 'notes-sync'    @{ Age = 30000; Remote = 'https://dev.azure.com/example-org/demo/_git/notes-sync'; Dirty = $true }
New-DemoProject $workDir 'api'           @{ Age = 700;   Remote = 'https://github.com/example-org/api.git' }
New-DemoProject $workDir 'data-clean'    @{ Age = 3000;  Remote = 'https://github.com/example-org/data-clean.git' }

# Settings for the demo (read via WORKSPACE_APP_CONFIG).
$config = [ordered]@{ roots = @($codeDir, $workDir); root = $codeDir; checkForUpdates = $false; shell = $true; diff = $true }
($config | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath (Join-Path $setDir 'config.json') -Encoding UTF8
$presets = @(
    [ordered]@{ name = 'invoice-send'; startupCommand = 'npm run dev'; urls = @('http://localhost:3000'); tabColor = '#2E86AB' },
    [ordered]@{ name = 'log-triage'; claudeArgs = '--model sonnet'; extraTabs = @([ordered]@{ title = 'logs'; path = (Join-Path $workDir 'data-clean') }) }
)
(ConvertTo-Json -InputObject @($presets) -Depth 6) | Set-Content -LiteralPath (Join-Path $setDir 'presets.json') -Encoding UTF8
([ordered]@{ last = @((Join-Path $codeDir 'page-distill'), (Join-Path $codeDir 'invoice-send')) } | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $setDir 'state.json') -Encoding UTF8

# Stand-in for `claude` (so launching a demo project never starts a real session).
Set-Content -LiteralPath (Join-Path $binDir 'claude.cmd') -Encoding ASCII -Value @(
    '@echo off',
    'echo.',
    'echo   [demo] Claude Code would start here:',
    'echo   %CD%',
    'echo.',
    'echo   This is a stand-in so the demo never opens a real session.'
)

Write-Output "Demo workspace ready: $Path"
Write-Output "  projects : $codeDir , $workDir"
Write-Output "  settings : $setDir  (WORKSPACE_APP_CONFIG)"
Write-Output "  start it : tools\New-DemoWorkspace.ps1 -Launch   (remove: tools\New-DemoWorkspace.ps1 -Remove)"

if ($Launch) {
    $script = Join-Path $PSScriptRoot '..\Start-App.ps1'
    $old = @{ Cfg = $env:WORKSPACE_APP_CONFIG; Path = $env:PATH }
    try {
        $env:WORKSPACE_APP_CONFIG = $setDir
        if (-not $RealClaude) { $env:PATH = "$binDir;$($env:PATH)" }
        Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$((Resolve-Path $script).ProviderPath)`""
    } finally { $env:WORKSPACE_APP_CONFIG = $old.Cfg; $env:PATH = $old.Path }
}
