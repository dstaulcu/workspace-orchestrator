<#
.SYNOPSIS
    Scans a code root for projects (newest activity first), lets you pick some, and opens
    a Windows Terminal window per project, each with a Claude Code tab and a PowerShell tab.
    Projects that are already open are brought to the front instead of being opened twice.

.DESCRIPTION
    Interactive (default): WinForms picker with filter, pre-checked last
    selection, branch/dirty columns. Use -Picker Grid for plain Out-GridView.

    Command-line use (no UI):
      -List                      print all projects as JSON and exit (launches nothing)
      -Project a,b               launch exactly those projects (by folder name or full path)
      -All [-Top N]              launch the N most recent (default 15)
      add -DryRun to print the wt command line instead of launching

    Settings live in ~\.config\workspace_app\: config.json (defaults; switches/parameters override it),
    presets.json (per-project overrides) and state.json (last selection).

.PARAMETER Root       Folder whose immediate subfolders are projects.
.PARAMETER Top        Limit list/picker to the N most recent (0 = all). With -All: how many to launch (default 15).
.PARAMETER Filter     Pre-fill the picker filter / filter -List output (substring of name or path).
.PARAMETER Project    One or more project names (comma-separated) or paths to launch without a picker.
.PARAMETER All        Launch the top N without a picker.
.PARAMETER List       Emit project metadata as JSON and exit.
.PARAMETER Picker     Forms (default) or Grid.
.PARAMETER Ignore     Folder names to skip.
.PARAMETER Fresh      Use plain `claude` even when session history exists.
.PARAMETER NoShell    Skip the PowerShell tab.
.PARAMETER NoDiff     Don't run `git status -sb; git diff --stat` in the shell tab.
.PARAMETER NoColor    Don't set tab colors.
.PARAMETER Focus      Bring an already-open project's tab (and its window) to the foreground; exit 1 if none is open.
.PARAMETER Window     Value for wt's -w (e.g. 0 = most recent existing window): put all tabs in that window. Default: a new window per project.
.PARAMETER Cascade    Find every open workspace window, restore it if minimized, cascade them on the primary screen and bring them to the front; no UI. The picker's global hotkey (config `hotkey`) does the same.
.PARAMETER CheckUpdate Check GitHub for a newer release, print the result as JSON and exit (no UI).
.PARAMETER DryRun     Print the wt arguments instead of launching.
#>
[CmdletBinding()]
param(
    [string[]]$Root,
    [int]$Top,
    [string]$Filter,
    [string[]]$Project,
    [switch]$All,
    [switch]$List,
    [ValidateSet('Forms','Grid')][string]$Picker,
    [string[]]$Ignore,
    [switch]$Fresh,
    [switch]$NoShell,
    [switch]$NoDiff,
    [switch]$NoColor,
    [string]$Window,
    [string]$Focus,
    [switch]$Cascade,
    [switch]$CheckUpdate,
    [switch]$DryRun
)

# ---------------------------------------------------------------- config / state
$AppVersion = '1.7.0'   # bump on every release; the update check compares it with the latest GitHub release tag
$cfg = @{
    root = 'C:\code'; roots = @(); projects = @(); top = 0; ignore = @()
    noiseDirs = @('.git','node_modules','.venv','venv','__pycache__','dist','build','.next','bin','obj','.idea','.vscode')
    maxScanFiles = 5000; maxScanDepth = 6; picker = 'Forms'
    shell = $true; diff = $true; tabColors = $true; gitInfo = $true; claudeArgs = ''; refreshSeconds = 60; arrangeOnLaunch = $true; arrangeStyle = 'cascade'; keepDesktopIconsClear = $true; windowWidth = 1100; windowHeight = 750; restoreLayouts = $true
    checkForUpdates = $true; updateCheckHours = 24; updateRepo = 'dstaulcu/workspace-wrangler'
    gitOpsOrg = ''; gitOpsTargets = @(); gitOpsVisibility = 'private'
    ide = 'code'; ideArgs = '-n'; git = 'git'; hotkey = 'Ctrl+Alt+W'; claudeVariants = @()
}
# Settings live outside the repo so they survive updates; files from older versions are moved over once.
$ConfigDir = Join-Path $env:USERPROFILE '.config\workspace_app'
# WORKSPACE_APP_CONFIG points the app at a different settings folder (used by tools/New-DemoWorkspace.ps1; handy for a portable or throwaway setup).
$ConfigOverride = [bool]$env:WORKSPACE_APP_CONFIG
if ($ConfigOverride) { $ConfigDir = $env:WORKSPACE_APP_CONFIG }
# Earlier versions kept settings in ~\.config\workspace_wrangler (and before that workspace_picker): carry the newest one over once (read it in place during -DryRun).
# Only the interactive picker copies them (the folder is left in place as a backup, so an older picker still running is not
# broken); -DryRun and the command-line switches just read the old folder in place. Runs when the new folder has none of our files yet.
$hasOwn = @('config.json', 'state.json', 'presets.json', 'layouts.json' | Where-Object { Test-Path -LiteralPath (Join-Path $ConfigDir $_) }).Count -gt 0
if (-not $hasOwn -and -not $ConfigOverride) {
    $readOnlyRun = $DryRun -or $List -or $All -or $CheckUpdate -or $Cascade -or [bool]$Focus -or ($Project.Count -gt 0)
    foreach ($legacyName in 'workspace_wrangler', 'workspace_picker') {
        $legacyDir = Join-Path $env:USERPROFILE (Join-Path '.config' $legacyName)
        if (-not (Test-Path -LiteralPath $legacyDir)) { continue }
        if ($readOnlyRun) { $ConfigDir = $legacyDir }
        else {
            try { New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null; Copy-Item -Path (Join-Path $legacyDir '*') -Destination $ConfigDir -Recurse -ErrorAction Stop }
            catch { Write-Warning "Could not copy settings from $legacyDir : $_"; $ConfigDir = $legacyDir }
        }
        break
    }
}
foreach ($f in 'presets.json','state.json') {
    $old = Join-Path $PSScriptRoot $f; $new = Join-Path $ConfigDir $f
    if ((Test-Path -LiteralPath $old) -and -not (Test-Path -LiteralPath $new) -and -not $DryRun) {
        try { New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null; Move-Item -LiteralPath $old -Destination $new } catch { Write-Warning "Could not migrate ${f}: $_" }
    }
}
$cfgFile = Join-Path $ConfigDir 'config.json'
# First run = no config.json and no state.json yet (fresh install, or settings were removed). The picker then asks where the projects are,
# even if the default folder happens to exist. Cancelling the dialog writes nothing, so it asks again next time.
$firstRun = -not (Test-Path -LiteralPath $cfgFile) -and -not (Test-Path -LiteralPath (Join-Path $ConfigDir 'state.json'))
if (Test-Path -LiteralPath $cfgFile) {
    try { (Get-Content -LiteralPath $cfgFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $cfg[$_.Name] = $_.Value } }
    catch { Write-Warning "Could not parse config.json: $_" }
}
# A custom git (portable install, not on PATH): put its folder first on PATH for this process, so every `git` call and child process uses it.
if ([string]$cfg.git -and [string]$cfg.git -ne 'git') {
    $gitExe = [string]$cfg.git
    if (Test-Path -LiteralPath $gitExe -PathType Leaf) { $env:PATH = (Split-Path -Parent $gitExe) + ';' + $env:PATH }
    elseif (Test-Path -LiteralPath $gitExe -PathType Container) { $env:PATH = $gitExe + ';' + $env:PATH }
    else { Write-Warning "config.json: git path not found: $gitExe (using git from PATH)" }
}
# Project folders: -Root a,b wins; else config "roots" (a list); else the single legacy "root". "projects" lists individual folders that are
# projects themselves (not parents of projects).
if ($PSBoundParameters.ContainsKey('Root')) { $Roots = @($Root | Where-Object { $_ }) }
else {
    $Roots = @($cfg.roots | Where-Object { $_ } | ForEach-Object { [string]$_ })
    if (-not $Roots.Count -and $cfg.root) { $Roots = @([string]$cfg.root) }
}
$ExtraProjects = @($cfg.projects | Where-Object { $_ } | ForEach-Object { [string]$_ })
if ($PSBoundParameters.ContainsKey('Root')) { $ExtraProjects = @() }   # -Root means exactly these folders
if (-not $PSBoundParameters.ContainsKey('Top'))    { $Top = [int]$cfg.top }
if (-not $PSBoundParameters.ContainsKey('Ignore')) { $Ignore = @($cfg.ignore) }
if (-not $PSBoundParameters.ContainsKey('Picker')) { $Picker = $cfg.picker }
$NoiseDirs = @($cfg.noiseDirs); $MaxScanFiles = [int]$cfg.maxScanFiles; $MaxScanDepth = [int]$cfg.maxScanDepth
$wantShell = (-not $NoShell) -and [bool]$cfg.shell
$wantDiff  = (-not $NoDiff)  -and [bool]$cfg.diff
$wantColor = (-not $NoColor) -and [bool]$cfg.tabColors
$Project = @($Project | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$stateFile = Join-Path $ConfigDir 'state.json'
$state = @{ last = @(); pending = @{} }   # pending: project path -> message for Claude on its next launch
if (Test-Path -LiteralPath $stateFile) {
    try {
        $s = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
        $state.last = @($s.last | Where-Object { $_ })
        if ($s.lastUpdateCheck) { $state.lastUpdateCheck = [string]$s.lastUpdateCheck }
        if ($s.skipVersion) { $state.skipVersion = [string]$s.skipVersion }
        if ($s.update) { $state.update = $s.update }
        if ($s.pending) { foreach ($pp in $s.pending.PSObject.Properties) { $state.pending[$pp.Name] = [string]$pp.Value } }
    } catch { Write-Warning "Could not parse state.json: $_" }
}
function Save-State {
    try { New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null; ([pscustomobject]@{ last = @($state.last); lastUpdateCheck = $state.lastUpdateCheck; skipVersion = $state.skipVersion; update = $state.update; pending = $state.pending } | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $stateFile -Encoding UTF8 }
    catch { Write-Warning "Could not save state.json: $_" }
}

$presets = @()
$presetFile = Join-Path $ConfigDir 'presets.json'
if (Test-Path -LiteralPath $presetFile) {
    # PS 5.1 emits a JSON array as ONE object, so enumerate it explicitly (otherwise every lookup returns the whole list).
    try { foreach ($x in (Get-Content -LiteralPath $presetFile -Raw | ConvertFrom-Json)) { if ($x) { $presets += $x } } }
    catch { Write-Warning "Could not parse presets.json: $_" }
}
function Get-Preset([string]$Name) { $presets | Where-Object { $_.name -ieq $Name } | Select-Object -First 1 }

# ---------------------------------------------------------------- discovery helpers
function Get-LastActive([string]$Dir) {
    # Git repos: latest commit time; falls through to file times if git is missing or no commits.
    if (Test-Path -LiteralPath (Join-Path $Dir '.git')) {
        try {
            $ts = & git -C $Dir log -1 --format=%ct 2>$null
            if ($LASTEXITCODE -eq 0 -and $ts -match '^\d+$') {
                return [DateTimeOffset]::FromUnixTimeSeconds([long]$ts).LocalDateTime
            }
        } catch { }
    }
    # Otherwise newest file LastWriteTime, skipping noise dirs; depth and file count capped.
    $newest = (Get-Item -LiteralPath $Dir).LastWriteTime
    $count = 0
    $stack = New-Object System.Collections.Stack
    $stack.Push(@{ P = $Dir; D = 0 })
    while ($stack.Count -gt 0 -and $count -lt $MaxScanFiles) {
        $e = $stack.Pop(); $d = $e.P; $depth = [int]$e.D
        try { $items = Get-ChildItem -LiteralPath $d -Force -ErrorAction Stop } catch { continue }
        foreach ($i in $items) {
            if ($i.PSIsContainer) {
                if ($NoiseDirs -notcontains $i.Name -and $depth -lt $MaxScanDepth) { $stack.Push(@{ P = $i.FullName; D = $depth + 1 }) }
            } else {
                $count++
                if ($i.LastWriteTime -gt $newest) { $newest = $i.LastWriteTime }
            }
        }
    }
    return $newest
}

function Format-Relative([DateTime]$When) {
    $s = (Get-Date) - $When
    if ($s.TotalMinutes -lt 60) { return '{0} min ago' -f [int][Math]::Max(1, $s.TotalMinutes) }
    if ($s.TotalHours   -lt 24) { return '{0} h ago'   -f [int]$s.TotalHours }
    if ($s.TotalDays    -lt 60) { return '{0} d ago'   -f [int]$s.TotalDays }
    return '{0} mo ago' -f [int]($s.TotalDays / 30)
}

function Test-ClaudeHistory([string]$Dir) {
    # Claude Code stores sessions under ~\.claude\projects\<path with every non-alphanumeric -> '-'>
    $enc = $Dir -replace '[^A-Za-z0-9]', '-'
    return (Test-Path -LiteralPath (Join-Path $env:USERPROFILE ".claude\projects\$enc"))
}

# ---------------------------------------------------------------- project cost (opt-in; reads Claude Code's local session files)
# Claude Code logs every API reply (model + token usage) in ~\.claude\projects\<folder>\<session>.jsonl, subagents in <session>\subagents\.
# We turn that into an estimated API-equivalent cost per project. Token counts are kept in our own ledger (costs.json) so totals survive
# Claude Code's cleanup of old transcripts; dollars are computed when shown, so the price table can be updated.
function ConvertTo-PriceModelId([string]$m) { (($m -replace '\[[^\]]*\]$', '') -replace '-\d{8}$', '').ToLowerInvariant() }

function Get-ModelPrices {
    $p = @{ Models = @{}; WebPer1000 = 10.0; FastMult = 2.0 }
    foreach ($f in @((Join-Path $PSScriptRoot 'assets\model-prices.json'), (Join-Path $ConfigDir 'model-prices.json'))) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        try {
            $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
            if ($j.webSearchPer1000) { $p.WebPer1000 = [double]$j.webSearchPer1000 }
            if ($j.speedMultiplier -and $j.speedMultiplier.fast) { $p.FastMult = [double]$j.speedMultiplier.fast }
            foreach ($m in $j.models.PSObject.Properties) { $p.Models[$m.Name.ToLowerInvariant()] = $m.Value }
        } catch { Write-Warning "Could not read $f : $_" }
    }
    $p
}

function Get-ModelRates($Prices, [string]$Model) {
    $m = $Prices.Models[(ConvertTo-PriceModelId $Model)]
    if (-not $m) { return $null }
    $in = [double]$m.input
    [pscustomobject]@{
        In = $in; Out = [double]$m.output
        Cr  = $(if ($null -ne $m.cacheRead)    { [double]$m.cacheRead }    else { $in * 0.1 })
        Cw5 = $(if ($null -ne $m.cacheWrite5m) { [double]$m.cacheWrite5m } else { $in * 1.25 })
        Cw1 = $(if ($null -ne $m.cacheWrite1h) { [double]$m.cacheWrite1h } else { $in * 2 })
    }
}

# $c = [in, out, cacheRead, cacheWrite5m, cacheWrite1h, webSearches]
function Get-UsageCost($Rates, $Prices, $c, [bool]$Fast) {
    $tok = ([double]$c[0] * $Rates.In + [double]$c[1] * $Rates.Out + [double]$c[2] * $Rates.Cr + [double]$c[3] * $Rates.Cw5 + [double]$c[4] * $Rates.Cw1) / 1e6
    if ($Fast) { $tok = $tok * $Prices.FastMult }
    $tok + [double]$c[5] * $Prices.WebPer1000 / 1000
}

# One transcript -> token counts per day per model. Replies repeat once per content block, so de-duplicate by message id.
function Read-TranscriptUsage([string]$File) {
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $days = @{}; $first = ''; $last = ''
    foreach ($ln in [IO.File]::ReadLines($File)) {
        if (-not $ln.Contains('"type":"assistant"')) { continue }
        $m = [regex]::Match($ln, '"id":"(msg_[^"]+)"')
        if ($m.Success -and -not $seen.Add($m.Groups[1].Value)) { continue }
        try { $o = $ln | ConvertFrom-Json } catch { continue }
        $msg = $o.message; if (-not $msg -or -not $msg.usage) { continue }
        $model = [string]$msg.model; if (-not $model -or $model.StartsWith('<')) { continue }   # <synthetic> = error placeholder, no usage
        $u = $msg.usage
        $ts = [string]$o.timestamp; $day = 'unknown'; if ($ts.Length -ge 10) { $day = $ts.Substring(0, 10); if (-not $first -or $ts -lt $first) { $first = $ts }; if ($ts -gt $last) { $last = $ts } }
        $cw5 = 0.0; $cw1 = 0.0
        if ($u.cache_creation) { $cw5 = [double]$u.cache_creation.ephemeral_5m_input_tokens; $cw1 = [double]$u.cache_creation.ephemeral_1h_input_tokens } else { $cw5 = [double]$u.cache_creation_input_tokens }
        $web = 0.0; if ($u.server_tool_use) { $web = [double]$u.server_tool_use.web_search_requests }
        $key = $model; if ([string]$u.speed -eq 'fast') { $key = $model + '#fast' }
        if (-not $days.ContainsKey($day)) { $days[$day] = @{} }
        if (-not $days[$day].ContainsKey($key)) { $days[$day][$key] = @(0.0, 0.0, 0.0, 0.0, 0.0, 0.0) }
        $a = $days[$day][$key]
        $a[0] += [double]$u.input_tokens; $a[1] += [double]$u.output_tokens; $a[2] += [double]$u.cache_read_input_tokens; $a[3] += $cw5; $a[4] += $cw1; $a[5] += $web
    }
    @{ Days = $days; First = $first; Last = $last }
}

# Scan one Claude project folder (runs in a background runspace). $Known maps ledger key -> "length|mtime" so unchanged files are skipped.
function Get-ProjectCostScan([string]$Dir, [hashtable]$Known) {
    $enc = Split-Path -Leaf $Dir
    $files = @(Get-ChildItem -LiteralPath $Dir -Filter *.jsonl -File -ErrorAction SilentlyContinue)
    foreach ($sd in @(Get-ChildItem -LiteralPath $Dir -Directory -ErrorAction SilentlyContinue)) {
        $files += @(Get-ChildItem -LiteralPath (Join-Path $sd.FullName 'subagents') -Filter *.jsonl -File -ErrorAction SilentlyContinue)
    }
    $present = @(); $recs = @{}
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($Dir.Length).TrimStart('\')
        $key = "$enc\$rel"
        $sig = '{0}|{1}' -f $f.Length, $f.LastWriteTimeUtc.Ticks
        $present += $key
        if ($Known.ContainsKey($key) -and $Known[$key] -eq $sig) { continue }
        $sid = if ($rel.Contains('\')) { $rel.Split('\')[0] } else { [IO.Path]::GetFileNameWithoutExtension($rel) }
        try { $u = Read-TranscriptUsage $f.FullName } catch { continue }
        $recs[$key] = @{ dir = $enc; session = $sid; sig = $sig; first = $u.First; last = $u.Last; days = $u.Days }
    }
    @{ Enc = $enc; Present = $present; Records = $recs }
}

function Read-CostLedger {
    $l = @{ files = @{} }
    $f = Join-Path $ConfigDir 'costs.json'
    if (Test-Path -LiteralPath $f) {
        try { foreach ($p in (Get-Content -LiteralPath $f -Raw | ConvertFrom-Json).files.PSObject.Properties) { $l.files[$p.Name] = $p.Value } } catch { Write-Warning "Could not read costs.json: $_" }
    }
    $l
}
function Save-CostLedger($Ledger) {
    if ($DryRun) { return }
    try {
        New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
        $f = Join-Path $ConfigDir 'costs.json'
        ([pscustomobject]@{ version = 1; files = $Ledger.files } | ConvertTo-Json -Depth 8 -Compress) | Set-Content -LiteralPath "$f.tmp" -Encoding UTF8
        Move-Item -LiteralPath "$f.tmp" -Destination $f -Force
    } catch { Write-Warning "Could not save costs.json: $_" }
}
# Fold one project's scan into the ledger; files Claude has since deleted are kept (marked gone) so history survives its cleanup.
function Merge-CostScan($Ledger, $Scan) {
    foreach ($k in $Scan.Records.Keys) { $Ledger.files[$k] = (ConvertTo-Json -InputObject $Scan.Records[$k] -Depth 8 -Compress) | ConvertFrom-Json }
    $prefix = $Scan.Enc + '\'
    foreach ($k in @($Ledger.files.Keys)) { if ($k.StartsWith($prefix) -and $Scan.Present -notcontains $k) { $Ledger.files[$k] | Add-Member -NotePropertyName gone -NotePropertyValue $true -Force } }
}
# Re-key a project's ledger entries after a rename (its Claude history folder is renamed too).
function Move-CostLedgerDir([string]$OldEnc, [string]$NewEnc) {
    $l = Read-CostLedger; $n = 0
    foreach ($k in @($l.files.Keys)) {
        if ($k.StartsWith($OldEnc + '\')) { $r = $l.files[$k]; $l.files.Remove($k); $r.dir = $NewEnc; $l.files[$NewEnc + '\' + $k.Substring($OldEnc.Length + 1)] = $r; $n++ }
    }
    if ($n) { Save-CostLedger $l; if ($script:CostLedger) { $script:CostLedger = $l } }
}

function Get-ProjectCostSummary($Ledger, [string]$Enc, $Prices) {
    $tot = 0.0; $c7 = 0.0; $c30 = 0.0; $by = @{}; $unk = @{}; $sess = @{}; $first = ''; $last = ''
    $today = (Get-Date).Date
    foreach ($e in $Ledger.files.GetEnumerator()) {
        $r = $e.Value; if ($r.dir -ne $Enc) { continue }
        $sess[[string]$r.session] = $true
        if ($r.first -and (-not $first -or [string]$r.first -lt $first)) { $first = [string]$r.first }
        if ($r.last -and [string]$r.last -gt $last) { $last = [string]$r.last }
        foreach ($d in $r.days.PSObject.Properties) {
            $age = 99999; try { $age = ($today - [datetime]::ParseExact($d.Name, 'yyyy-MM-dd', $null)).TotalDays } catch { }
            foreach ($m in $d.Value.PSObject.Properties) {
                $fast = $m.Name.EndsWith('#fast'); $model = $m.Name -replace '#fast$', ''
                $rates = Get-ModelRates $Prices $model
                if (-not $rates) { $unk[$model] = $true; continue }
                $usd = Get-UsageCost $rates $Prices @($m.Value) $fast
                $tot += $usd; if ($age -lt 7) { $c7 += $usd }; if ($age -lt 30) { $c30 += $usd }
                $by[$model] = [double]$by[$model] + $usd
            }
        }
    }
    $tip = ''
    if ($sess.Count) {
        $fmt = { param($x) '$' + ([double]$x).ToString('N2') }
        $lines = @("Estimated API-equivalent cost: $(& $fmt $tot) (all time)")
        $fd = ''; $ld = ''; if ($first.Length -ge 10) { $fd = $first.Substring(0, 10) }; if ($last.Length -ge 10) { $ld = $last.Substring(0, 10) }
        $lines += "Sessions: $($sess.Count) (subagents included)   First: $fd   Last: $ld"
        $lines += "Last 7 days: $(& $fmt $c7)    Last 30 days: $(& $fmt $c30)"
        $top = @($by.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "$($_.Key) $(& $fmt $_.Value)" })
        if ($top.Count) { $lines += 'By model: ' + ($top -join '; ') }
        if ($unk.Count) { $lines += "Not priced (add them to model-prices.json): $(@($unk.Keys) -join ', ')" }
        $lines += "From Claude Code's local session files, kept in the Wrangler's own ledger so it survives Claude's cleanup of old sessions. List prices; a subscription plan is not billed per token."
        $tip = $lines -join "`n"
    }
    [pscustomobject]@{ Sessions = $sess.Count; Total = $tot; Incomplete = ($unk.Count -gt 0); Tip = $tip }
}

function Set-RowCost($Row) {
    $Row.CostUsd = $null; $Row.CostText = ''; $Row.CostTip = ''
    if (-not $script:CostOn) { return }
    $enc = ([string]$Row.Path) -replace '[^A-Za-z0-9]', '-'
    $s = Get-ProjectCostSummary $script:CostLedger $enc $script:Prices
    if (-not $s.Sessions) { return }
    $Row.CostUsd = $s.Total; $Row.CostTip = $s.Tip
    $Row.CostText = $(if ($s.Incomplete) { '~' } else { '' }) + '$' + $s.Total.ToString('N2')
}

# Normalize a git remote (https, ssh://, git://, scp-style) to a browsable https://<host>/<path> URL
# (GitHub, GitLab, Bitbucket, Azure DevOps, self-hosted...). $null for local-path / unparseable remotes.
function ConvertTo-RemoteWebUrl([string]$Remote) {
    $r = $Remote.Trim()
    # Azure DevOps ssh (git@ssh.dev.azure.com:v3/org/project/repo) maps to dev.azure.com/org/project/_git/repo.
    if ($r -match '^(?:ssh://)?(?:[^@/\s]+@)?ssh\.dev\.azure\.com[:/]v3/([^/]+)/([^/]+)/([^/\s]+?)(?:\.git)?/?$') { return "https://dev.azure.com/$($Matches[1])/$($Matches[2])/_git/$($Matches[3])" }
    if ($r -match '^https?://(?:[^@/]+@)?([^/\s]+)/(.+?)(?:\.git)?/?$') { $h = $Matches[1]; $p = $Matches[2] }
    elseif ($r -match '^(?:ssh|git)://(?:[^@/]+@)?([^/:\s]+)(?::\d+)?/(.+?)(?:\.git)?/?$') { $h = $Matches[1]; $p = $Matches[2] }
    elseif ($r -match '^(?:[^@/\s]+@)?([^/:\s]+):(?!//)(.+?)(?:\.git)?/?$' -and $r -notmatch '^[A-Za-z]:[\\/]') { $h = $Matches[1]; $p = $Matches[2] }
    else { return $null }
    return "https://$h/$($p.TrimStart('/'))"
}

function Get-GitInfo([string]$Dir) {
    if (-not (Test-Path -LiteralPath (Join-Path $Dir '.git'))) { return $null }
    $branch = ''; $dirty = $null; $url = $null
    try {
        # One call for branch + dirty state (porcelain v2: "# branch.head <name>" header, then one line per change).
        $st = @(& git -C $Dir status --porcelain=v2 --branch 2>$null)
        if ($LASTEXITCODE -eq 0) {
            $bl = $st | Where-Object { $_ -like '# branch.head *' } | Select-Object -First 1
            if ($bl) { $b = ([string]$bl).Substring(14).Trim(); if ($b -ne '(detached)') { $branch = $b } }
            $dirty = [bool]($st | Where-Object { $_ -and -not ([string]$_).StartsWith('#') } | Select-Object -First 1)
        }
        # One call for every remote URL. Prefer "origin"; otherwise the first remote with a browsable URL.
        $remotes = @()
        foreach ($l in @(& git -C $Dir config --get-regexp '^remote\..+\.url$' 2>$null)) {
            if ("$l" -match '^remote\.(.+)\.url\s+(.+)$') { $remotes += [pscustomobject]@{ Name = $Matches[1]; Url = $Matches[2].Trim() } }
        }
        $ordered = @($remotes | Where-Object { $_.Name -eq 'origin' }) + @($remotes | Where-Object { $_.Name -ne 'origin' })
        foreach ($r in $ordered) {
            $u = ConvertTo-RemoteWebUrl ([string]$r.Url)
            if ($u) { $url = $u; break }
        }
    } catch { }
    [pscustomobject]@{ Branch = $branch; Dirty = $dirty; RemoteUrl = $url }
}

# Last-active time and git info for many projects at once. Each project costs one or two git processes (or a
# file walk), so they run on a small runspace pool instead of one after another. Returns @{ <path> = @{ La; Gi } }.
function Get-ProjectFacts($Dirs, [bool]$Scan, [bool]$Git) {
    $facts = @{}
    if (-not $Scan -and -not $Git) { return $facts }
    $fns = 'ConvertTo-RemoteWebUrl', 'Get-GitInfo', 'Get-LastActive'
    $defs = ($fns | ForEach-Object { "function $_ {`n" + (Get-Item "function:$_").ScriptBlock.ToString() + "`n}" }) -join "`n"
    $job = [scriptblock]::Create('param($dir, $scan, $git, $noise, $maxFiles, $maxDepth)' + "`n" + '$NoiseDirs = $noise; $MaxScanFiles = $maxFiles; $MaxScanDepth = $maxDepth' + "`n" + $defs + "`n" + @'
$r = @{ La = $null; Gi = $null }
if ($scan) { try { $r.La = Get-LastActive $dir } catch { } }
if ($git)  { try { $r.Gi = Get-GitInfo $dir } catch { } }
$r
'@)
    $size = [Math]::Max(2, [Math]::Min(8, [Environment]::ProcessorCount))
    $pool = [runspacefactory]::CreateRunspacePool(1, $size)
    $pool.Open()
    $jobs = @()
    try {
        foreach ($d in $Dirs) {
            $ps = [powershell]::Create(); $ps.RunspacePool = $pool
            [void]$ps.AddScript($job.ToString()).AddArgument($d.FullName).AddArgument($Scan).AddArgument($Git).AddArgument($NoiseDirs).AddArgument($MaxScanFiles).AddArgument($MaxScanDepth)
            $jobs += [pscustomobject]@{ Path = $d.FullName; PS = $ps; Handle = $ps.BeginInvoke() }
        }
        foreach ($j in $jobs) {
            # Keep the startup splash responsive while the scan runs (no-op without a splash).
            while ($script:Splash -and -not $j.Handle.IsCompleted) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 30 }
            try { $out = @($j.PS.EndInvoke($j.Handle)); if ($out.Count) { $facts[$j.Path] = $out[-1] } } catch { }
            $j.PS.Dispose()
        }
    } finally { $pool.Close(); $pool.Dispose() }
    $facts
}

# Stable per-project tab color: hash of the name -> hue.
function Get-TabColor([string]$Name) {
    $h = 0
    foreach ($c in $Name.ToCharArray()) { $h = ($h * 31 + [int]$c) % 360 }
    $s = 0.55; $l = 0.42
    $c = (1 - [Math]::Abs(2 * $l - 1)) * $s
    $x = $c * (1 - [Math]::Abs((($h / 60) % 2) - 1))
    $m = $l - $c / 2
    switch ([int][Math]::Floor($h / 60)) {
        0 { $r = $c; $g = $x; $b = 0 } 1 { $r = $x; $g = $c; $b = 0 } 2 { $r = 0; $g = $c; $b = $x }
        3 { $r = 0; $g = $x; $b = $c } 4 { $r = $x; $g = 0; $b = $c } default { $r = $c; $g = 0; $b = $x }
    }
    '#{0:X2}{1:X2}{2:X2}' -f [int](($r + $m) * 255), [int](($g + $m) * 255), [int](($b + $m) * 255)
}

# ---------------------------------------------------------------- find / focus open tabs (UI Automation)
# Tab titles are short, unique and predictable (cc:<project>, sh:<scope>; the older claude-code-/shell- prefixes still match), so we can find
# them in ANY Windows Terminal window, select the tab, and raise its window. No tab indexes.
function Get-TerminalTabs {
    try {
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction Stop
        $AE = [System.Windows.Automation.AutomationElement]
        $winCond = New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, 'CASCADIA_HOSTING_WINDOW_CLASS')
        $tabCond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)
        foreach ($w in $AE::RootElement.FindAll('Children', $winCond)) {
            foreach ($t in $w.FindAll('Descendants', $tabCond)) {
                [pscustomobject]@{ Title = $t.Current.Name; Window = $w; Tab = $t }
            }
        }
    } catch { Write-Verbose "UI Automation unavailable: $_" }
}

# Project names that currently have a cc:<name> or sh:<name> tab open (legacy claude-code-/shell- prefixes too).
function Get-RunningNames {
    @(Get-TerminalTabs | ForEach-Object { if ($_.Title -match '^(?:cc:|sh:|claude-code-|shell-)(.+)$') { $Matches[1] } } | Select-Object -Unique)
}

# Select the project's harness tab (else its shell tab) and raise the window. Returns $true if found.
function Initialize-WinApi {
    if ('WoWin' -as [type]) { return }
    Add-Type @'
using System; using System.Runtime.InteropServices;
public static class WoWin {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int ht, uint flags);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
}
'@
}

# ---------------------------------------------------------------- window arrangement (tile on launch, saved layouts)
# One entry per Windows Terminal window: its handle and the project its cc:/sh: tabs name.
function Get-TerminalWindows {
    $byHandle = [ordered]@{}
    foreach ($t in @(Get-TerminalTabs)) {
        $h = [int64]$t.Window.Current.NativeWindowHandle
        if (-not $byHandle.Contains($h)) { $byHandle[$h] = [pscustomobject]@{ Handle = $h; Name = $null; Sh = $null } }
        if ($t.Title -match '^(?:cc:|claude-code-)(.+)$' -and -not $byHandle[$h].Name) { $byHandle[$h].Name = $Matches[1] }
        elseif ($t.Title -match '^(?:sh:|shell-)(.+)$' -and -not $byHandle[$h].Sh) { $byHandle[$h].Sh = $Matches[1] }
    }
    foreach ($w in $byHandle.Values) { if (-not $w.Name) { $w.Name = $w.Sh } }
    @($byHandle.Values)
}

# Identifies the monitor setup so a saved layout is only reused when the screens are the same.
function Get-ScreenSignature {
    Add-Type -AssemblyName System.Windows.Forms
    (@([System.Windows.Forms.Screen]::AllScreens | Sort-Object DeviceName | ForEach-Object { "$($_.Bounds.X),$($_.Bounds.Y),$($_.Bounds.Width)x$($_.Bounds.Height)" }) -join '|')
}

function Get-SavedLayout {
    $f = Join-Path $ConfigDir 'layouts.json'
    if (-not (Test-Path -LiteralPath $f)) { return @{} }
    try {
        $all = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
        $set = $all.PSObject.Properties[(Get-ScreenSignature)]
        $out = @{}
        if ($set) { foreach ($p in $set.Value.PSObject.Properties) { $out[$p.Name] = $p.Value } }
        return $out
    } catch { Write-Warning "Could not read layouts.json: $_"; return @{} }
}

# Record where each open project's window is (for the current monitor setup). Returns how many were saved.
function Save-WindowLayout {
    Initialize-WinApi
    $f = Join-Path $ConfigDir 'layouts.json'
    $all = [ordered]@{}
    if (Test-Path -LiteralPath $f) {
        try { foreach ($p in (Get-Content -LiteralPath $f -Raw | ConvertFrom-Json).PSObject.Properties) { $all[$p.Name] = $p.Value } } catch { }
    }
    $sig = Get-ScreenSignature
    $cur = [ordered]@{}
    if ($all.Contains($sig)) { foreach ($p in $all[$sig].PSObject.Properties) { $cur[$p.Name] = $p.Value } }
    $n = 0
    foreach ($w in @(Get-TerminalWindows)) {
        if (-not $w.Name) { continue }
        $h = [IntPtr]$w.Handle
        if ([WoWin]::IsIconic($h)) { continue }
        $r = New-Object WoWin+RECT
        if (-not [WoWin]::GetWindowRect($h, [ref]$r)) { continue }
        $cur[$w.Name] = [pscustomobject]@{ x = $r.Left; y = $r.Top; w = $r.Right - $r.Left; h = $r.Bottom - $r.Top; max = [bool][WoWin]::IsZoomed($h) }
        $n++
    }
    $all[$sig] = [pscustomobject]$cur
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
    ([pscustomobject]$all | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $f -Encoding UTF8
    return $n
}

function Set-WindowRect([int64]$Handle, [int]$X, [int]$Y, [int]$W, [int]$H, [bool]$Maximize = $false, [bool]$Raise = $false) {
    Initialize-WinApi
    $p = [IntPtr]$Handle
    [void][WoWin]::ShowWindow($p, 9)                                   # restore if minimized / maximized
    $flags = 0x0014   # SWP_NOZORDER | SWP_NOACTIVATE
    if ($Raise) { $flags = 0x0010 }   # keep z-order logic: place on top (used by cascade so later windows sit above earlier ones)
    [void][WoWin]::SetWindowPos($p, [IntPtr]::Zero, $X, $Y, $W, $H, $flags)
    if ($Maximize) { [void][WoWin]::ShowWindow($p, 3) }
}

# After launching, wait for the new windows (those not in $Before) to show up, then give each its saved spot,
# and tile the rest in a grid on the primary screen's work area.
function Invoke-WindowArrangement([int64[]]$Before, [string[]]$Names) {
    $useSaved = [bool]$cfg.restoreLayouts; $useTile = [bool]$cfg.arrangeOnLaunch; $style = [string]$cfg.arrangeStyle; if (-not $style) { $style = 'cascade' }
    if (-not $useSaved -and -not $useTile) { return }
    $saved = @{}; if ($useSaved) { $saved = Get-SavedLayout }
    if (-not $useTile -and -not ($Names | Where-Object { $saved.ContainsKey($_) })) { return }
    if ($useTile -and $Names.Count -lt 2 -and -not ($Names | Where-Object { $saved.ContainsKey($_) })) { return }
    $deadline = (Get-Date).AddSeconds(15); $found = @()
    do {
        Start-Sleep -Milliseconds 400
        $found = @(Get-TerminalWindows | Where-Object { $Before -notcontains $_.Handle -and $Names -contains $_.Name })
    } while ($found.Count -lt $Names.Count -and (Get-Date) -lt $deadline)
    if (-not $found.Count) { return }
    $st = 'none'; if ($useTile) { $st = $style }
    [void](Set-WindowArrangement $found $Names $saved $st)
}

# Place windows at their saved spot where one exists; arrange the others (2 or more) on the primary screen.
# $Style: cascade | grid | columns | rows | resize (default size, same position) | none (only restore saved spots).
# Cascade and resize use the default window size (windowWidth x windowHeight), clamped to the work area.
# Returns the number of windows moved.
function Set-WindowArrangement($Windows, [string[]]$Names, $Saved, [string]$Style) {
    Add-Type -AssemblyName System.Windows.Forms
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    if ($cfg.keepDesktopIconsClear) {
        # Start at desktop-icon row 2, column 2 so the first column and row of desktop shortcuts stay visible.
        Initialize-WinApi
        $ix = [WoWin]::GetSystemMetrics(38); $iy = [WoWin]::GetSystemMetrics(39)   # SM_CXICONSPACING / SM_CYICONSPACING
        if ($ix -gt 0 -and $iy -gt 0 -and $ix -lt $wa.Width / 3 -and $iy -lt $wa.Height / 3) {
            $wa = New-Object System.Drawing.Rectangle(($wa.X + $ix), ($wa.Y + $iy), ($wa.Width - $ix), ($wa.Height - $iy))
        }
    }
    $dw = [Math]::Min([int]$cfg.windowWidth, $wa.Width); $dh = [Math]::Min([int]$cfg.windowHeight, $wa.Height)
    if ($dw -lt 300) { $dw = [Math]::Min(1100, $wa.Width) }; if ($dh -lt 200) { $dh = [Math]::Min(750, $wa.Height) }
    if ($Style -eq 'resize') {
        # Back to the default size; keep each window's top-left (nudged so it stays on its screen).
        Initialize-WinApi
        $moved = 0
        foreach ($w in $Windows) {
            $r = New-Object WoWin+RECT
            if (-not [WoWin]::GetWindowRect([IntPtr]$w.Handle, [ref]$r)) { continue }
            $scr = [System.Windows.Forms.Screen]::FromPoint((New-Object System.Drawing.Point(($r.Left + 40), ($r.Top + 40)))).WorkingArea
            $ww = [Math]::Min($dw, $scr.Width); $hh = [Math]::Min($dh, $scr.Height)
            $x = [Math]::Max($scr.X, [Math]::Min($r.Left, $scr.Right - $ww)); $y = [Math]::Max($scr.Y, [Math]::Min($r.Top, $scr.Bottom - $hh))
            Set-WindowRect $w.Handle $x $y $ww $hh
            $moved++
        }
        return $moved
    }
    $byName = @{}; foreach ($w in $Windows) { $byName[$w.Name] = $w }
    $rest = @(); $moved = 0
    foreach ($n in $Names) {
        if (-not $byName.ContainsKey($n)) { continue }
        if ($Saved.ContainsKey($n)) { $s = $Saved[$n]; Set-WindowRect $byName[$n].Handle $s.x $s.y $s.w $s.h ([bool]$s.max); $moved++ }
        else { $rest += $byName[$n] }
    }
    # The Wrangler's own window (KeepSize) is not part of the overlap; it is parked beside the cascade below.
    $self = @($rest | Where-Object { $_.KeepSize }); $rest = @($rest | Where-Object { -not $_.KeepSize })
    if ($Style -eq 'none' -or ($rest.Count + $self.Count) -lt 2) { return $moved }
    if ($Style -eq 'cascade') {
        # Overlapping windows, each offset down-right so every title bar stays visible; later windows sit on top.
        $step = 48
        $w = $dw; $h = $dh
        $slots = [Math]::Max(1, [Math]::Min([int][Math]::Floor(($wa.Width - $w) / $step), [int][Math]::Floor(($wa.Height - $h) / $step)) + 1)
        $maxRight = $wa.X
        for ($i = 0; $i -lt $rest.Count; $i++) {
            $k = $i % $slots
            Set-WindowRect $rest[$i].Handle ($wa.X + $k * $step) ($wa.Y + $k * $step) $w $h $false $true
            $maxRight = [Math]::Max($maxRight, $wa.X + $k * $step + $w)
            $moved++
        }
        # Wrangler: top aligned with the first window, just right of the last one so it never hides behind them.
        # If the screen has no room for that, it sits against the right edge of the work area instead.
        foreach ($sw in $self) {
            $rr = New-Object WoWin+RECT
            if (-not [WoWin]::GetWindowRect([IntPtr][int64]$sw.Handle, [ref]$rr)) { continue }
            $pw = $rr.Right - $rr.Left; $ph = $rr.Bottom - $rr.Top
            $x = $maxRight + 8
            if ($x + $pw -gt $wa.Right) { $x = [Math]::Max($wa.X, $wa.Right - $pw) }
            $y = $wa.Y; if ($y + $ph -gt $wa.Bottom) { $y = [Math]::Max($wa.Y, $wa.Bottom - $ph) }
            Set-WindowRect $sw.Handle $x $y $pw $ph $false $true
            $moved++
        }
        return $moved
    }
    switch ($Style) {
        'columns' { $cols = $rest.Count; $rows = 1 }
        'rows'    { $cols = 1; $rows = $rest.Count }
        default   { $cols = [int][Math]::Ceiling([Math]::Sqrt($rest.Count)); $rows = [int][Math]::Ceiling($rest.Count / $cols) }
    }
    $cw = [int][Math]::Floor($wa.Width / $cols); $ch = [int][Math]::Floor($wa.Height / $rows)
    for ($i = 0; $i -lt $rest.Count; $i++) {
        Set-WindowRect $rest[$i].Handle ($wa.X + ($i % $cols) * $cw) ($wa.Y + [Math]::Floor($i / $cols) * $ch) $cw $ch
        $moved++
    }
    return $moved
}

# On demand: arrange every open project window (saved spots first, unless -IgnoreSaved; the rest per $Style).
function Invoke-ArrangeOpen([string]$Style = 'cascade', [bool]$IgnoreSaved = $false) {
    $wins = @(Get-TerminalWindows | Where-Object { $_.Name } | Sort-Object Name)
    if (-not $wins.Count) { return 0 }
    $saved = @{}; if ($cfg.restoreLayouts -and -not $IgnoreSaved) { $saved = Get-SavedLayout }
    return (Set-WindowArrangement $wins @($wins | ForEach-Object { $_.Name }) $saved $Style)
}

# Hotkey action: discover the open workspace windows, restore minimized ones, cascade them (ignoring saved
# positions, like Arrange > Cascade), and bring them to the front with the last one active. Returns the window count.
function Invoke-CascadeFront([int64]$SelfHandle = 0) {
    $wins = @(Get-TerminalWindows | Where-Object { $_.Name } | Sort-Object Name)
    Initialize-WinApi
    if ($SelfHandle) {   # the Wrangler joins the cascade as the last (topmost) window, keeping its own size
        $wins += [pscustomobject]@{ Handle = $SelfHandle; Name = '~Workspace Wrangler'; Sh = $null; KeepSize = $true }
    }
    if (-not $wins.Count) { return 0 }
    foreach ($w in $wins) { if ([WoWin]::IsIconic([IntPtr][int64]$w.Handle)) { [void][WoWin]::ShowWindow([IntPtr][int64]$w.Handle, 9) } }
    [void](Set-WindowArrangement $wins @($wins | ForEach-Object { $_.Name }) @{} 'cascade')
    # A tap of Alt lets SetForegroundWindow succeed when launched from a shortcut hotkey rather than from a focused window.
    [WoWin]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [WoWin]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
    [void][WoWin]::SetForegroundWindow([IntPtr][int64]$wins[-1].Handle)
    return @($wins | Where-Object { -not $_.KeepSize }).Count
}

# Global hotkey (only while the picker is open): "Ctrl+Alt+W" -> modifiers + virtual-key, or $null if it can't be parsed.
function ConvertTo-HotkeySpec([string]$Text) {
    if (-not $Text -or -not $Text.Trim()) { return $null }
    Add-Type -AssemblyName System.Windows.Forms
    $mods = 0; $vk = 0
    foreach ($t in ($Text -split '\+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        switch -Regex ($t) {
            '^(ctrl|control)$' { $mods = $mods -bor 2; continue }
            '^alt$'            { $mods = $mods -bor 1; continue }
            '^shift$'          { $mods = $mods -bor 4; continue }
            '^(win|windows)$'  { $mods = $mods -bor 8; continue }
            default {
                $name = $t; if ($name -match '^\d$') { $name = "D$name" }
                try { $vk = [int][System.Enum]::Parse([System.Windows.Forms.Keys], $name, $true) } catch { return $null }
            }
        }
    }
    if (-not $vk -or -not $mods) { return $null }   # a bare key would steal normal typing system-wide
    @{ Mods = [uint32]$mods; Vk = [uint32]$vk }
}

function Initialize-HotkeyType {
    if ('WoHotkey' -as [type]) { return }
    Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class WoHotkey : IMessageFilter {
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
    public event EventHandler Pressed;
    const int Id = 0x5743;
    public bool Register(uint mods, uint vk) { Application.AddMessageFilter(this); return RegisterHotKey(IntPtr.Zero, Id, mods | 0x4000, vk); }
    public void Unregister() { UnregisterHotKey(IntPtr.Zero, Id); Application.RemoveMessageFilter(this); }
    public bool PreFilterMessage(ref Message m) {
        if (m.Msg == 0x0312 && m.WParam.ToInt32() == Id) { EventHandler h = Pressed; if (h != null) h(this, EventArgs.Empty); return true; }
        return false;
    }
}
"@
}

function Switch-ToProject([string]$Name, [string]$Tab = 'any') {
    Initialize-WinApi
    $tabs = @(Get-TerminalTabs)
    $hit = $null
    if ($Tab -ne 'shell') { $hit = $tabs | Where-Object { $_.Title -ieq "cc:$Name" -or $_.Title -ieq "claude-code-$Name" } | Select-Object -First 1 }
    if (-not $hit -and $Tab -ne 'claude') { $hit = $tabs | Where-Object { $_.Title -ieq "sh:$Name" -or $_.Title -ieq "shell-$Name" } | Select-Object -First 1 }
    if (-not $hit) { return $false }
    try { $hit.Tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select() } catch { }
    $h = [IntPtr]$hit.Window.Current.NativeWindowHandle
    if ([WoWin]::IsIconic($h)) { [void][WoWin]::ShowWindow($h, 9) }
    # A tap of Alt lets SetForegroundWindow succeed when we aren't the foreground process (e.g. -Focus from a script).
    [WoWin]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [WoWin]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
    [void][WoWin]::SetForegroundWindow($h)
    return $true
}

# ---------------------------------------------------------------- GitOps actions (picker Git menu)
# These are the only things that change a project, and only when the picker user explicitly asks
# (a confirmation for Initialize, the create dialog for New remote). -DryRun reports instead of running.
function Test-GitHasCommits([string]$Dir) {
    try { & git -C $Dir rev-parse --verify --quiet HEAD 2>$null | Out-Null; return ($LASTEXITCODE -eq 0) } catch { return $false }
}

# GitHub accounts the gh user can create repositories under: their own login, then their organizations.
function Get-GitHubLogin {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { return '' }
    try { $me = [string](& gh api user --jq .login 2>$null); if ($LASTEXITCODE -eq 0) { return $me.Trim() } } catch { }
    ''
}
function Get-GitHubOwners {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { return @() }
    $owners = @()
    try {
        $me = [string](& gh api user --jq .login 2>$null)
        if ($LASTEXITCODE -eq 0 -and $me.Trim()) { $owners += $me.Trim() }
        $orgs = @(& gh api user/orgs --paginate --jq '.[].login' 2>$null)
        if ($LASTEXITCODE -eq 0) { $owners += @($orgs | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) }
    } catch { }
    @($owners | Select-Object -Unique)
}

# GitHub repository names allow letters, digits, '.', '-' and '_'; anything else in a folder name becomes '-'.
function ConvertTo-RepoName([string]$Name) { (($Name -replace '[^A-Za-z0-9._-]', '-') -replace '-{2,}', '-').Trim('-') }

# Hosting providers for "create remote repository". github -> gh, gitlab -> glab, azure -> az repos;
# 'url' just attaches an existing remote URL (works with any host, e.g. Bitbucket).
$GitProviders = @{
    github = @{ Label = 'GitHub';       Cli = 'gh';   Install = "Install the GitHub CLI from https://cli.github.com, then run 'gh auth login'."; OwnerLabel = 'Owner (organization):';        OwnerHint = 'blank = your own account' }
    gitlab = @{ Label = 'GitLab';       Cli = 'glab'; Install = "Install the GitLab CLI from https://gitlab.com/gitlab-org/cli, then run 'glab auth login'.";   OwnerLabel = 'Group / namespace:';           OwnerHint = 'e.g. my-group/sub-group; blank = your own namespace' }
    azure  = @{ Label = 'Azure DevOps'; Cli = 'az';   Install = "Install the Azure CLI (https://aka.ms/installazurecli), then run 'az extension add --name azure-devops' and 'az login'."; OwnerLabel = 'Organization/Project:'; OwnerHint = 'e.g. my-org/my-project' }
}

# Configured targets (config `gitOpsTargets`): a string is a GitHub organization; an object is { provider, owner, host }.
function Get-GitTargets {
    $out = @()
    foreach ($t in @($cfg.gitOpsTargets)) {
        if ($null -eq $t -or "$t" -eq '') { continue }
        if ($t -is [string]) { $out += [pscustomobject]@{ Provider = 'github'; Owner = $t; Host = '' }; continue }
        $pv = ([string]$t.provider).ToLowerInvariant(); if (-not $pv) { $pv = 'github' }
        if (-not $GitProviders.ContainsKey($pv)) { continue }
        $out += [pscustomobject]@{ Provider = $pv; Owner = [string]$t.owner; Host = [string]$t.host }
    }
    $out
}

# After a CLI created the repository: make sure 'origin' points at it, and optionally push. Returns $null or an error line.
function Set-OriginAndPush([string]$Dir, [string]$Url, [bool]$Push) {
    if (-not [string](& git -C $Dir remote get-url origin 2>$null)) {
        $o = (& git -C $Dir remote add origin $Url 2>&1 | ForEach-Object { "$_" } | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { return "The repository was created, but adding it as origin failed: $o" }
    }
    if ($Push) {
        $o = (& git -C $Dir push -u origin HEAD 2>&1 | ForEach-Object { "$_" } | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { return "The repository was created and added as origin, but the push failed: $(($o -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1))" }
    }
    $null
}

# Non-UI core. $Op: 'init' | 'remote'. $Opts (remote): Provider (github|gitlab|azure|url), Owner ('' = your own account),
# Name, Visibility, Push, Host (gitlab), Url (url). Returns { Ok, Message }.
# ---------------------------------------------------------------- app log and diagnostics (text for issue reports)
function Write-AppLog([string]$Message) {
    try {
        New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
        $f = Join-Path $ConfigDir 'app.log'
        if ((Test-Path -LiteralPath $f) -and (Get-Item -LiteralPath $f).Length -gt 512KB) { $keep = @(Get-Content -LiteralPath $f -Tail 300); Set-Content -LiteralPath $f -Value $keep -Encoding UTF8 }
        Add-Content -LiteralPath $f -Value ("{0}  v{1}  {2}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $AppVersion, (($Message -replace "\r?\n", ' | ').Trim())) -Encoding UTF8
    } catch { }
}
# Plain text to paste into an issue: versions plus the recent log, with the user name and home folder masked. No settings values, no secrets.
function Get-DiagnosticsText {
    $mask = { param($t) $t = [string]$t; $t = $t.Replace([string]$env:USERPROFILE, '%USERPROFILE%'); if ($env:USERNAME) { $t = $t.Replace([string]$env:USERNAME, '<user>') }; $t }
    $tool = { param($c, $a) try { [string](& $c @a 2>&1 | Select-Object -First 1) } catch { 'not found' } }
    $lines = @(
        "Workspace Wrangler v$AppVersion",
        "OS: $([Environment]::OSVersion.VersionString)   PowerShell: $($PSVersionTable.PSVersion)",
        "git: $(& $tool 'git' @('--version'))   gh: $(& $tool 'gh' @('--version'))   wt: $(if (Get-Command wt.exe -ErrorAction SilentlyContinue) { 'found' } else { 'not found' })",
        "Project folders configured: $(@($Roots).Count)   showCost: $($cfg.showCost)",
        '',
        'Recent log:'
    )
    $f = Join-Path $ConfigDir 'app.log'
    if (Test-Path -LiteralPath $f) { $lines += @(Get-Content -LiteralPath $f -Tail 60) } else { $lines += '(log is empty)' }
    & $mask ($lines -join "`r`n")
}

function Invoke-GitOp([string]$Op, [string]$Dir, $Opts) {
    $r = [pscustomobject]@{ Ok = $false; Message = '' }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { $r.Message = 'git was not found on PATH.'; return $r }
    $isGit = Test-Path -LiteralPath (Join-Path $Dir '.git')
    switch ($Op) {
        'init' {
            if ($isGit) { $r.Message = "$Dir is already a git repository."; return $r }
            if ($DryRun) { $r.Message = "Dry run: would run 'git init' in $Dir."; return $r }
            $out = (& git -C $Dir init 2>&1 | ForEach-Object { "$_" } | Out-String).Trim()
            if ($LASTEXITCODE -ne 0) { $r.Message = "git init failed: $out"; return $r }
            $r.Ok = $true; $r.Message = "Initialized a local git repository in $Dir."
        }
        'remote' {
            $prov = ([string]$Opts.Provider).ToLowerInvariant(); if (-not $prov) { $prov = 'github' }
            if ($prov -ne 'url') {
                if (-not $GitProviders.ContainsKey($prov)) { $r.Message = "Unknown provider: $prov"; return $r }
                $P = $GitProviders[$prov]
                if (-not (Get-Command $P.Cli -ErrorAction SilentlyContinue)) { $r.Message = "$($P.Label) CLI ($($P.Cli)) was not found. $($P.Install)"; return $r }
            }
            if ($isGit -and [string](& git -C $Dir remote get-url origin 2>$null)) { $r.Message = "This project already has a remote named 'origin'."; return $r }
            $vis = ([string]$Opts.Visibility).ToLowerInvariant()
            if (@('private','internal','public') -notcontains $vis) { $vis = 'private' }
            $name = [string]$Opts.Name; $owner = [string]$Opts.Owner
            $full = $name; if ($owner) { $full = "$owner/$name" }
            if ($prov -eq 'github' -and $vis -eq 'internal' -and (-not $owner -or ($Opts.PersonalLogin -and $owner -ieq [string]$Opts.PersonalLogin))) {
                $r.Message = "GitHub 'internal' repositories exist only inside an organization, not on a personal account. Choose 'private' or 'public'."; return $r
            }
            $push = [bool]$Opts.Push
            # What would run, per provider (also the dry-run text).
            $cmdText = ''
            switch ($prov) {
                'github' { $ghArgs = @('repo', 'create', $full, "--$vis", '--source', $Dir, '--remote', 'origin'); if ($push) { $ghArgs += '--push' }; $cmdText = "gh $($ghArgs -join ' ')" }
                'gitlab' { $cmdText = "glab repo create $full --$vis" + $(if ($push) { ", git push -u origin HEAD" } else { '' }) }
                'azure'  {
                    if ($owner -notmatch '^[^/\s]+/[^/\s]+$') { $r.Message = 'Azure DevOps needs Organization/Project as the owner (for example my-org/my-project).'; return $r }
                    $org, $proj = $owner -split '/', 2
                    $cmdText = "az repos create --name $name --organization https://dev.azure.com/$org --project $proj" + $(if ($push) { ", git push -u origin HEAD" } else { '' })
                }
                'url'    { $cmdText = "git remote add origin $($Opts.Url)" + $(if ($push) { ", git push -u origin HEAD" } else { '' }) }
            }
            if ($DryRun) {
                $pre = ''; if (-not $isGit) { $pre = "'git init' in $Dir, then " }
                $r.Message = "Dry run: would run ${pre}$cmdText"; return $r
            }
            if (-not $isGit) {
                $init = Invoke-GitOp 'init' $Dir $null
                if (-not $init.Ok) { return $init }
            }
            switch ($prov) {
                'github' {
                    $out = (& gh @ghArgs 2>&1 | ForEach-Object { "$_" } | Out-String).Trim()
                    if ($LASTEXITCODE -ne 0) {
                        $first = (($out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 4) -join ' ')
                        $r.Message = "Could not create $full on GitHub: $first`n`nCommand: $cmdText"; return $r
                    }
                    $r.Ok = $true; $r.Message = "Created $full on GitHub ($vis) and added it as origin."
                    if ($push) { $r.Message += ' Pushed the current branch.' }
                }
                'gitlab' {
                    $hostName = [string]$Opts.Host; if (-not $hostName) { $hostName = 'gitlab.com' }
                    $old = $env:GITLAB_HOST; if ($hostName -ne 'gitlab.com') { $env:GITLAB_HOST = $hostName }
                    Push-Location -LiteralPath $Dir
                    try { $out = (& glab repo create $full "--$vis" 2>&1 | ForEach-Object { "$_" } | Out-String).Trim(); $code = $LASTEXITCODE }
                    finally { Pop-Location; $env:GITLAB_HOST = $old }
                    if ($code -ne 0) {
                        $first = (($out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 4) -join ' ')
                        $r.Message = "Could not create $full on GitLab: $first`n`nCommand: $cmdText"; return $r
                    }
                    $err = Set-OriginAndPush $Dir "https://$hostName/$full.git" $push
                    if ($err) { $r.Message = $err; return $r }
                    $r.Ok = $true; $r.Message = "Created $full on GitLab ($vis) and added it as origin."
                    if ($push) { $r.Message += ' Pushed the current branch.' }
                }
                'azure' {
                    $res = & az repos create --name $name --organization "https://dev.azure.com/$org" --project $proj --output json 2>&1
                    $code = $LASTEXITCODE
                    $txt = (@($res | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) | Out-String).Trim()
                    $url = $null; try { $url = [string]($txt | ConvertFrom-Json).remoteUrl } catch { }
                    if ($code -ne 0 -or -not $url) {
                        $first = (@($res | ForEach-Object { "$_" }) -join "`n" -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
                        $r.Message = "Could not create $name in Azure DevOps ($owner): $first"; return $r
                    }
                    $err = Set-OriginAndPush $Dir $url $push
                    if ($err) { $r.Message = $err; return $r }
                    $r.Ok = $true; $r.Message = "Created $name in Azure DevOps ($owner) and added it as origin."
                    if ($push) { $r.Message += ' Pushed the current branch.' }
                }
                'url' {
                    $u = [string]$Opts.Url
                    if (-not $u.Trim()) { $r.Message = 'No remote URL given.'; return $r }
                    $err = Set-OriginAndPush $Dir $u.Trim() $push
                    if ($err) { $r.Message = $err; return $r }
                    $r.Ok = $true; $r.Message = "Added $($u.Trim()) as origin."
                    if ($push) { $r.Message += ' Pushed the current branch.' }
                }
            }
        }
        default { $r.Message = "Unknown git action: $Op" }
    }
    $r
}

# Dialog for New remote on GitHub. Returns $null (cancelled) or { Owner, Name, Visibility, Push }.
function Show-NewRemoteDialog($OwnerForm, [string]$ProjectName, [bool]$IsGit, [bool]$HasCommits, [string[]]$Owners, [string]$DefaultOwner, [string]$DefaultVisibility, [string]$Provider = 'github', [string]$PersonalLogin = '') {
    $PL = $GitProviders[$Provider].Label; $OwnerLabel = $GitProviders[$Provider].OwnerLabel; $OwnerHint = $GitProviders[$Provider].OwnerHint
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "New $PL repository for $ProjectName"; $dlg.ClientSize = New-Object System.Drawing.Size(480, 250)
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.StartPosition = 'CenterParent'
    $mk = {
        param($text, $y)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text; $l.AutoSize = $true; $l.Location = New-Object System.Drawing.Point(12, ($y + 4)); $l
    }
    $cboOwner = New-Object System.Windows.Forms.ComboBox
    $cboOwner.Location = New-Object System.Drawing.Point(140, 12); $cboOwner.Width = 320; $cboOwner.DropDownStyle = 'DropDown'
    foreach ($o in $Owners) { [void]$cboOwner.Items.Add($o) }
    $cboOwner.Text = $DefaultOwner
    $txtName = New-Object System.Windows.Forms.TextBox
    $txtName.Location = New-Object System.Drawing.Point(140, 44); $txtName.Width = 320; $txtName.Text = (ConvertTo-RepoName $ProjectName)
    $cboVis = New-Object System.Windows.Forms.ComboBox
    $cboVis.Location = New-Object System.Drawing.Point(140, 76); $cboVis.Width = 120; $cboVis.DropDownStyle = 'DropDownList'
    foreach ($v in 'private','internal','public') { [void]$cboVis.Items.Add($v) }
    $cboVis.SelectedItem = $DefaultVisibility; if ($cboVis.SelectedIndex -lt 0) { $cboVis.SelectedIndex = 0 }
    $chkPush = New-Object System.Windows.Forms.CheckBox
    $chkPush.Location = New-Object System.Drawing.Point(140, 106); $chkPush.AutoSize = $true
    if ($HasCommits) { $chkPush.Text = 'Push the current branch'; $chkPush.Checked = $true }
    else { $chkPush.Text = 'Push the current branch (no commits yet)'; $chkPush.Enabled = $false }
    $summary = New-Object System.Windows.Forms.Label
    $summary.Location = New-Object System.Drawing.Point(12, 140); $summary.Size = New-Object System.Drawing.Size(456, 60)
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Create'; $ok.Location = New-Object System.Drawing.Point(274, 210); $ok.Size = New-Object System.Drawing.Size(90, 28)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'; $cancel.Location = New-Object System.Drawing.Point(374, 210); $cancel.Size = New-Object System.Drawing.Size(90, 28)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    $dlg.Controls.AddRange(@((& $mk $OwnerLabel 12), $cboOwner, (& $mk 'Repository name:' 44), $txtName, (& $mk 'Visibility:' 76), $cboVis, $chkPush, $summary, $ok, $cancel))
    $tip = New-Object System.Windows.Forms.ToolTip
    $tip.SetToolTip($cboOwner, "Where to create the repository (pick one or type it); $OwnerHint. Organizations you list under gitOpsTargets in config.json appear here.")
    $tip.SetToolTip($txtName, 'Name of the new repository (letters, digits, ".", "-" and "_"). Defaults to the folder name.')
    $tip.SetToolTip($cboVis, 'Who can see the repository: private (only you / your org), internal (your enterprise) or public.')
    $tip.SetToolTip($chkPush, 'Also push the current branch to the new repository right after creating it. Needs at least one commit.')
    $tip.SetToolTip($ok, "Create the repository on $PL and add it to this project as 'origin'. Runs git init first if the folder is not a repository yet.")
    $tip.SetToolTip($cancel, 'Close this dialog without creating anything.')
    if ($Provider -eq 'azure') { $cboVis.Enabled = $false; $tip.SetToolTip($cboVis, 'Azure DevOps repositories take their visibility from the project.') }

    $update = {
        $owner = $cboOwner.Text.Trim(); $full = $txtName.Text.Trim()
        if ($owner) { $full = "$owner/$full" } else { $full = "$full (your account)" }
        $visTxt = " as $($cboVis.SelectedItem)"; if ($Provider -eq 'azure') { $visTxt = '' }
        $s = "This will create $full on $PL$visTxt and add it to this project as 'origin'."
        if (-not $IsGit) { $s = "This will run 'git init' in the project, then create $full on $PL$visTxt and add it as 'origin'." }
        if ($chkPush.Checked) { $s += ' The current branch is pushed.' }
        $summary.Text = $s
    }.GetNewClosure()
    $cboOwner.Add_TextChanged($update); $txtName.Add_TextChanged($update); $cboVis.Add_SelectedIndexChanged($update); $chkPush.Add_CheckedChanged($update)
    & $update
    $ok.Add_Click({
        if ($txtName.Text.Trim() -notmatch '^[A-Za-z0-9._-]+$') {
            [void][System.Windows.Forms.MessageBox]::Show($dlg, 'Repository names can use only letters, digits, ".", "-" and "_".', "New $PL repository", 'OK', 'Warning')
            return
        }
        $ow = $cboOwner.Text.Trim()
        $okOwner = switch ($Provider) { 'github' { (-not $ow) -or ($ow -match '^[A-Za-z0-9-]+$') } 'gitlab' { (-not $ow) -or ($ow -match '^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$') } default { $ow -match '^[^/\s]+/[^/\s]+$' } }
        if (-not $okOwner) {
            [void][System.Windows.Forms.MessageBox]::Show($dlg, "That is not a valid $($OwnerLabel.TrimEnd(':')) ($OwnerHint).", "New $PL repository", 'OK', 'Warning')
            return
        }
        if ($Provider -eq 'github' -and [string]$cboVis.SelectedItem -eq 'internal' -and (-not $ow -or ($PersonalLogin -and $ow -ieq $PersonalLogin))) {
            [void][System.Windows.Forms.MessageBox]::Show($dlg, "GitHub 'internal' repositories exist only inside an organization. For your personal account choose 'private' or 'public'.", "New $PL repository", 'OK', 'Warning')
            return
        }
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK; $dlg.Close()
    }.GetNewClosure())

    $res = $dlg.ShowDialog($OwnerForm)
    $out = $null
    if ($res -eq [System.Windows.Forms.DialogResult]::OK) {
        $out = [pscustomobject]@{ Provider = $Provider; Owner = $cboOwner.Text.Trim(); Name = $txtName.Text.Trim(); Visibility = [string]$cboVis.SelectedItem; Push = ($chkPush.Enabled -and $chkPush.Checked) }
    }
    $dlg.Dispose()
    $out
}

# Small dialog: attach an existing remote by URL. Returns $null or { Provider='url'; Url; Push }.
function Show-AddRemoteDialog($OwnerForm, [string]$ProjectName, [bool]$HasCommits) {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Add existing remote for $ProjectName"; $dlg.ClientSize = New-Object System.Drawing.Size(480, 150)
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.StartPosition = 'CenterParent'
    $l = New-Object System.Windows.Forms.Label; $l.Text = 'Remote URL:'; $l.AutoSize = $true; $l.Location = New-Object System.Drawing.Point(12, 16)
    $txt = New-Object System.Windows.Forms.TextBox; $txt.Location = New-Object System.Drawing.Point(100, 12); $txt.Width = 360
    $chk = New-Object System.Windows.Forms.CheckBox; $chk.Location = New-Object System.Drawing.Point(100, 44); $chk.AutoSize = $true
    if ($HasCommits) { $chk.Text = 'Push the current branch'; $chk.Checked = $true } else { $chk.Text = 'Push the current branch (no commits yet)'; $chk.Enabled = $false }
    $note = New-Object System.Windows.Forms.Label; $note.Location = New-Object System.Drawing.Point(12, 74); $note.Size = New-Object System.Drawing.Size(456, 32)
    $note.Text = "Create the empty repository on your host first (GitHub, GitLab, Bitbucket, Azure DevOps, ...), then paste its URL. It is added as 'origin'."
    $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'Add'; $ok.Location = New-Object System.Drawing.Point(274, 112); $ok.Size = New-Object System.Drawing.Size(90, 28)
    $cancel = New-Object System.Windows.Forms.Button; $cancel.Text = 'Cancel'; $cancel.Location = New-Object System.Drawing.Point(374, 112); $cancel.Size = New-Object System.Drawing.Size(90, 28)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    $dlg.Controls.AddRange(@($l, $txt, $chk, $note, $ok, $cancel))
    $tip = New-Object System.Windows.Forms.ToolTip
    $tip.SetToolTip($txt, 'The URL of a repository you already created, e.g. https://host/owner/repo.git or git@host:owner/repo.git.')
    $tip.SetToolTip($chk, 'Also push the current branch to that remote right after adding it. Needs at least one commit.')
    $tip.SetToolTip($ok, "Add this URL to the project as 'origin'. Nothing is created on the host.")
    $tip.SetToolTip($cancel, 'Close this dialog without changing anything.')
    $ok.Add_Click({
        if ($txt.Text.Trim() -notmatch '^(https?://|ssh://|git://|[^@\s]+@[^:\s]+:)\S+$') {
            [void][System.Windows.Forms.MessageBox]::Show($dlg, 'Enter a git remote URL such as https://host/owner/repo.git or git@host:owner/repo.git.', 'Add existing remote', 'OK', 'Warning'); return
        }
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK; $dlg.Close()
    }.GetNewClosure())
    $res = $dlg.ShowDialog($OwnerForm); $out = $null
    if ($res -eq [System.Windows.Forms.DialogResult]::OK) { $out = [pscustomobject]@{ Provider = 'url'; Url = $txt.Text.Trim(); Push = ($chk.Enabled -and $chk.Checked) } }
    $dlg.Dispose(); $out
}

# Picker side of a Git menu action: confirm, run, then refresh the row's git info in place.
# $Row is the picker's row object (shared with the list), so updating it updates the picker.
function Invoke-PickerGitOp([string]$Op, $Row, $OwnerForm, [string]$PresetOwner = '') {
    $isGit = Test-Path -LiteralPath (Join-Path $Row.Path '.git')
    switch ($Op) {
        'init' {
            $ans = [System.Windows.Forms.MessageBox]::Show($OwnerForm, "Run 'git init' in this folder?`n`n$($Row.Path)", 'Initialize local repository', 'YesNo', 'Question')
            if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return 'Cancelled.' }
            $res = Invoke-GitOp 'init' $Row.Path $null
        }
        'remote' {
            # $PresetOwner is "provider|owner" from the submenu ('@me' = your own account; empty owner = ask in the dialog).
            $prov, $pre = ([string]$PresetOwner + '|') -split '\|', 2; $pre = $pre.TrimEnd('|')
            if (-not $prov) { $prov = 'github' }
            $P = $GitProviders[$prov]
            if (-not (Get-Command $P.Cli -ErrorAction SilentlyContinue)) { return "$($P.Label) CLI ($($P.Cli)) was not found. $($P.Install)" }
            $targets = @(Get-GitTargets | Where-Object { $_.Provider -eq $prov })
            $owners = @($targets | ForEach-Object { $_.Owner } | Where-Object { $_ })
            if ($prov -eq 'github') {
                $OwnerForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
                try { $owners = @($owners + @(Get-GitHubOwners) | Select-Object -Unique) } finally { $OwnerForm.Cursor = [System.Windows.Forms.Cursors]::Default }
            }
            $default = ''
            if ($pre -eq '@me') { $default = '' }
            elseif ($pre) { $default = $pre }
            elseif ($prov -eq 'github') { $default = [string]$cfg.gitOpsOrg; if (-not $default -and $owners.Count) { $default = $owners[0] } }
            elseif ($owners.Count) { $default = $owners[0] }
            $login = ''; if ($prov -eq 'github') { $login = Get-GitHubLogin }
            $opts = Show-NewRemoteDialog $OwnerForm $Row.Name $isGit ($isGit -and (Test-GitHasCommits $Row.Path)) $owners $default ([string]$cfg.gitOpsVisibility) $prov $login
            if (-not $opts) { return 'Cancelled.' }
            $hostName = ($targets | Where-Object { $_.Owner -eq $opts.Owner } | Select-Object -First 1).Host
            $opts | Add-Member -NotePropertyName Host -NotePropertyValue ([string]$hostName)
            $opts | Add-Member -NotePropertyName PersonalLogin -NotePropertyValue ([string]$login)
            $res = Invoke-GitOp 'remote' $Row.Path $opts
        }
        'addurl' {
            $opts = Show-AddRemoteDialog $OwnerForm $Row.Name ($isGit -and (Test-GitHasCommits $Row.Path))
            if (-not $opts) { return 'Cancelled.' }
            $res = Invoke-GitOp 'remote' $Row.Path $opts
        }
        default { return "Unknown git action: $Op" }
    }
    if ($res.Ok) {
        $gi = Get-GitInfo $Row.Path
        $Row.IsGit = Test-Path -LiteralPath (Join-Path $Row.Path '.git')
        if ($gi) { $Row.Branch = $gi.Branch; $Row.Dirty = $gi.Dirty; $Row.RemoteUrl = $gi.RemoteUrl }
    }
    if (-not $res.Ok) { Write-AppLog "git $Op failed in $($Row.Path): $($res.Message)" }
    $res.Message
}

# ---------------------------------------------------------------- updates (GitHub releases)
# Network use is limited to this check: one GET of the public releases list, sent with a generic User-Agent.
function ConvertTo-ReleaseVersion([string]$Tag) {
    if ($Tag -match '^v?(\d+)\.(\d+)\.(\d+)') { return [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])" }
    return $null
}

# Starts the check without blocking (returns a Task), or $null when disabled or checked recently (unless $Force).
function Start-UpdateCheck([bool]$Force) {
    if (-not $Force) {
        if (-not [bool]$cfg.checkForUpdates) { return $null }
        if ($state.lastUpdateCheck) {
            try { if (((Get-Date) - [datetime]$state.lastUpdateCheck).TotalHours -lt [double]$cfg.updateCheckHours) { return $null } } catch { }
        }
    }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Add-Type -AssemblyName System.Net.Http
        $http = New-Object System.Net.Http.HttpClient
        $http.Timeout = [TimeSpan]::FromSeconds(10)
        $http.DefaultRequestHeaders.UserAgent.ParseAdd('workspace-app-update-check')
        $http.DefaultRequestHeaders.Accept.ParseAdd('application/vnd.github+json')
        return $http.GetStringAsync("https://api.github.com/repos/$($cfg.updateRepo)/releases?per_page=10")
    } catch { return $null }
}

# Turns a finished check into an info object (or $null: up to date / version skipped; or @{Failed=$true}), and remembers the result.
function Complete-UpdateCheck($Task, [bool]$Force) {
    try {
        $best = $null
        $releases = $Task.Result | ConvertFrom-Json   # PS 5.1 emits a JSON array as ONE object; foreach below enumerates it
        foreach ($r in $releases) {
            if ($r.draft) { continue }
            $v = ConvertTo-ReleaseVersion ([string]$r.tag_name)
            if ($v -and (-not $best -or $v -gt $best.v)) { $best = @{ v = $v; r = $r } }
        }
        $state.lastUpdateCheck = (Get-Date).ToString('o')
        if ($best) { $state.update = [pscustomobject]@{ tag = [string]$best.r.tag_name; url = [string]$best.r.html_url; zip = [string]$best.r.zipball_url } }
        else { $state.update = $null }
        if (-not $DryRun) { Save-State }
    } catch {
        try { $state.lastUpdateCheck = (Get-Date).ToString('o'); if (-not $DryRun) { Save-State } } catch { }   # back off until the next interval
        return [pscustomobject]@{ Failed = $true }
    }
    return (Get-UpdateInfo $Force)
}

# The remembered latest release, if newer than this one (and not skipped unless $IgnoreSkip).
function Get-UpdateInfo([bool]$IgnoreSkip = $false) {
    $u = $state.update
    if (-not $u) { return $null }
    $v = ConvertTo-ReleaseVersion ([string]$u.tag)
    if (-not $v -or $v -le [version]$AppVersion) { return $null }
    if (-not $IgnoreSkip -and $state.skipVersion -eq [string]$u.tag) { return $null }
    [pscustomobject]@{ Tag = [string]$u.tag; Version = $v.ToString(); Url = [string]$u.url; Zip = [string]$u.zip }
}

# Applies the update in place: git fast-forward for a clone, otherwise download + copy over the install folder.
# Settings live in ~\.config\workspace_app, so they are untouched. Returns @{ Ok; Message }.
function Install-Update($Info, [string]$Dir = $PSScriptRoot, [string]$Cfg = $ConfigDir, [string]$Ver = $AppVersion) {
    try {
        if (Test-Path -LiteralPath (Join-Path $Dir '.git')) {
            # Never prompt: this runs without a visible console, so a credential prompt would hang forever.
            $env:GIT_TERMINAL_PROMPT = '0'; $env:GCM_INTERACTIVE = 'never'
            if (@(& git -C $Dir status --porcelain 2>$null).Count) { return [pscustomobject]@{ Ok = $false; Message = 'This folder is a git clone with uncommitted changes. Commit or stash them, then update again (or run: git fetch --tags; git merge --ff-only ' + $Info.Tag + ').' } }
            $out = (& git -C $Dir -c credential.interactive=never fetch --tags origin 2>&1 | Out-String)
            if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ Ok = $false; Message = "git fetch failed: $out" } }
            $out = (& git -C $Dir merge --ff-only $Info.Tag 2>&1 | Out-String)
            if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ Ok = $false; Message = "Could not fast-forward to $($Info.Tag): $out" } }
            return [pscustomobject]@{ Ok = $true; Message = "Updated to $($Info.Tag) with git." }
        }
        if ([string]$Info.Zip -notmatch '^https://(api\.github\.com|codeload\.github\.com|github\.com)/') {
            return [pscustomobject]@{ Ok = $false; Message = 'The release download address is not a GitHub https URL; nothing was changed.' }
        }
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $tmp = Join-Path $env:TEMP ("wrangler-update-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        try {
            $zip = Join-Path $tmp 'release.zip'
            Invoke-WebRequest -Uri $Info.Zip -OutFile $zip -UseBasicParsing -TimeoutSec 60 -Headers @{ 'User-Agent' = 'workspace-app-update' }
            Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $tmp 'x') -Force
            $root = Get-ChildItem -LiteralPath (Join-Path $tmp 'x') -Directory | Select-Object -First 1
            if (-not $root -or -not (Test-Path -LiteralPath (Join-Path $root.FullName 'Start-App.ps1'))) {
                return [pscustomobject]@{ Ok = $false; Message = 'The downloaded release does not look like Workspace Wrangler; nothing was changed.' }
            }
            # Back up whatever is about to be replaced, then copy the new files over the install folder.
            $bk = Join-Path $Cfg "backup\v$Ver"
            $rels = @()
            foreach ($f in Get-ChildItem -LiteralPath $root.FullName -Recurse -File) {
                $rel = $f.FullName.Substring($root.FullName.Length).TrimStart('\'); $rels += $rel
                $cur = Join-Path $Dir $rel
                if (Test-Path -LiteralPath $cur) {
                    $dst = Join-Path $bk $rel; New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
                    Copy-Item -LiteralPath $cur -Destination $dst -Force
                }
            }
            try {
                Copy-Item -Path (Join-Path $root.FullName '*') -Destination $Dir -Recurse -Force -ErrorAction Stop
            } catch {
                $err = $_
                foreach ($rel in $rels) {   # roll back what we backed up
                    $b = Join-Path $bk $rel
                    if (Test-Path -LiteralPath $b) { try { Copy-Item -LiteralPath $b -Destination (Join-Path $Dir $rel) -Force } catch { } }
                }
                return [pscustomobject]@{ Ok = $false; Message = "Update failed while copying files ($err). The previous files were restored." }
            }
        } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        return [pscustomobject]@{ Ok = $true; Message = "Updated to $($Info.Tag). The previous files are backed up in $bk." }
    } catch { return [pscustomobject]@{ Ok = $false; Message = "Update failed: $_" } }
}

# Runs Install-Update on a background runspace so the picker stays responsive; poll .Handle.IsCompleted, then EndInvoke.
function Start-InstallUpdate($Info) {
    $ps = [powershell]::Create()
    [void]$ps.AddScript("function Install-Update {`n" + ${function:Install-Update}.ToString() + "`n}`nInstall-Update `$args[0] `$args[1] `$args[2] `$args[3]")
    [void]$ps.AddArgument($Info).AddArgument($PSScriptRoot).AddArgument($ConfigDir).AddArgument($AppVersion)
    @{ PS = $ps; Handle = $ps.BeginInvoke() }
}

# Opens each project folder in the user's IDE (config `ide`, default VS Code's `code`), one new window per project
# (`ideArgs`, default -n). Returns a status line. Launching an IDE never modifies the project.
function Invoke-OpenIde([string[]]$Paths) {
    $ide = [string]$cfg.ide; if (-not $ide) { $ide = 'code' }
    $exe = $null
    $c = Get-Command $ide -ErrorAction SilentlyContinue | Where-Object { $_.CommandType -eq 'Application' } | Select-Object -First 1
    if ($c) { $exe = $c.Source }
    elseif ($ide -eq 'code') {
        $exe = @("$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd", "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    }
    if (-not $exe) { return "Could not find '$ide' on PATH. Set `"ide`" in config.json (Settings > Edit config.json)." }
    $n = 0; $dry = @()
    foreach ($p in $Paths) {
        $a = ("$([string]$cfg.ideArgs) `"$p`"").Trim()
        if ($DryRun) { $dry += "ide: $exe $a"; $n++; continue }
        try {
            if ($exe -match '\.(cmd|bat)$') { Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `"`"$exe`" $a`"" -WindowStyle Hidden }
            else { Start-Process -FilePath $exe -ArgumentList $a }
            $n++
        } catch { return "Could not start $ide : $_" }
    }
    if ($DryRun) { return ($dry -join "`n") }
    "Opened $n project(s) in $ide."
}

# ---------------------------------------------------------------- branding images, splash, About
# Reads an image from assets\ into memory (so the file is never locked). Returns $null if it is missing or unreadable.
function Get-ArtImage([string]$Name) {
    try {
        Add-Type -AssemblyName System.Drawing
        $f = Join-Path $PSScriptRoot "assets\$Name"
        if (-not (Test-Path -LiteralPath $f)) { return $null }
        $ms = New-Object IO.MemoryStream(, [IO.File]::ReadAllBytes($f))
        $img = [System.Drawing.Image]::FromStream($ms)
        $bmp = New-Object System.Drawing.Bitmap($img); $img.Dispose(); $ms.Dispose()
        return $bmp
    } catch { return $null }
}

# Startup splash: shown while the projects are scanned, closed just before the picker appears.
function Show-Splash {
    try {
        $art = Get-ArtImage 'splash.jpg'
        if (-not $art) { return }
        Add-Type -AssemblyName System.Windows.Forms
        $f = New-Object System.Windows.Forms.Form
        $f.FormBorderStyle = 'None'; $f.StartPosition = 'CenterScreen'; $f.TopMost = $true; $f.ShowInTaskbar = $false
        $f.BackColor = [System.Drawing.Color]::FromArgb(14, 22, 40)
        $f.ClientSize = New-Object System.Drawing.Size(($art.Width), ($art.Height + 28))
        $pic = New-Object System.Windows.Forms.PictureBox
        $pic.Image = $art; $pic.SizeMode = 'Zoom'; $pic.Location = New-Object System.Drawing.Point(0, 0); $pic.Size = New-Object System.Drawing.Size($art.Width, $art.Height)
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = "Rounding up your projects..."; $lbl.ForeColor = [System.Drawing.Color]::FromArgb(240, 200, 90); $lbl.TextAlign = 'MiddleCenter'
        $lbl.Location = New-Object System.Drawing.Point(0, $art.Height); $lbl.Size = New-Object System.Drawing.Size($art.Width, 28)
        $f.Controls.AddRange(@($pic, $lbl))
        $f.Show(); $f.Refresh(); [System.Windows.Forms.Application]::DoEvents()
        $script:Splash = $f
    } catch { }
}
function Close-Splash {
    if ($script:Splash) {
        try { $img = $script:Splash.Controls[0].Image; $script:Splash.Close(); $script:Splash.Dispose(); if ($img) { $img.Dispose() } } catch { }
        $script:Splash = $null
    }
}

# About box: the full-width art (click it for the full-size image), version and links.
function Show-AboutDialog($OwnerForm) {
    Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing
    $art = Get-ArtImage 'splash.jpg'
    $w = 640; $h = 0; if ($art) { $h = $art.Height }
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'About Workspace Wrangler'; $dlg.ClientSize = New-Object System.Drawing.Size(($w + 24), ($h + 130))
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.StartPosition = 'CenterParent'
    $tip = New-Object System.Windows.Forms.ToolTip
    $y = 12
    if ($art) {
        $pic = New-Object System.Windows.Forms.PictureBox
        $pic.Image = $art; $pic.SizeMode = 'Zoom'; $pic.Cursor = [System.Windows.Forms.Cursors]::Hand
        $pic.Location = New-Object System.Drawing.Point(12, $y); $pic.Size = New-Object System.Drawing.Size($w, $h)
        $full = Join-Path $PSScriptRoot 'assets\concept.jpg'
        $pic.Add_Click({ try { Start-Process -FilePath $full } catch { } }.GetNewClosure())
        $tip.SetToolTip($pic, 'Click to open the full-size image in your default viewer.')
        $dlg.Controls.Add($pic); $y += $h + 8
    }
    $ver = New-Object System.Windows.Forms.Label
    $ver.Text = "Workspace Wrangler v$AppVersion`nTame your sea of projects and terminals, and restart your whole workday in one click."
    $ver.Location = New-Object System.Drawing.Point(12, $y); $ver.Size = New-Object System.Drawing.Size($w, 36)
    $links = New-Object System.Windows.Forms.LinkLabel
    $repo = "https://github.com/$($cfg.updateRepo)"
    $links.Text = 'Repository  |  Open issues  |  Changelog'
    $links.Location = New-Object System.Drawing.Point(12, ($y + 40)); $links.AutoSize = $true
    [void]$links.Links.Add(0, 10, $repo); [void]$links.Links.Add(15, 11, "$repo/issues"); [void]$links.Links.Add(31, 9, 'changelog')
    $links.Add_LinkClicked({
        param($s, $e)
        try { if ([string]$e.Link.LinkData -eq 'changelog') { [void](Open-Changelog) } else { Start-Process ([string]$e.Link.LinkData) } } catch { }
    })
    $close = New-Object System.Windows.Forms.Button
    $close.Text = 'Close'; $close.Location = New-Object System.Drawing.Point(($w - 78), ($y + 40)); $close.Size = New-Object System.Drawing.Size(90, 28)
    $close.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $dlg.CancelButton = $close; $dlg.AcceptButton = $close
    $dlg.Controls.AddRange(@($ver, $links, $close))
    [void]$dlg.ShowDialog($OwnerForm)
    $dlg.Dispose(); if ($art) { $art.Dispose() }
}

# ---------------------------------------------------------------- Claude Code data health (retention + telemetry)
# Cost totals and any later usage review depend on Claude Code keeping its session files. It deletes transcripts older than
# `cleanupPeriodDays` (default 30) at startup. This reads the settings (names and on/off only, never endpoint values) and can, after a
# confirmation, set that one key.
function Get-ClaudeDataHealth {
    $h = @{ File = (Join-Path $env:USERPROFILE '.claude\settings.json'); Retention = $null; Telemetry = $false; Exporters = @(); PromptLogging = $false; Files = 0; Bytes = 0L; Oldest = $null }
    $envNames = @{}
    if (Test-Path -LiteralPath $h.File) {
        try {
            $j = Get-Content -LiteralPath $h.File -Raw | ConvertFrom-Json
            if ($j.PSObject.Properties['cleanupPeriodDays']) { $h.Retention = [int]$j.cleanupPeriodDays }
            if ($j.env) { foreach ($p in $j.env.PSObject.Properties) { $envNames[$p.Name] = [string]$p.Value } }
        } catch { }
    }
    foreach ($n in 'CLAUDE_CODE_ENABLE_TELEMETRY', 'OTEL_METRICS_EXPORTER', 'OTEL_LOGS_EXPORTER', 'OTEL_TRACES_EXPORTER', 'OTEL_EXPORTER_OTLP_ENDPOINT', 'OTEL_LOG_USER_PROMPTS') {
        if (-not $envNames.ContainsKey($n)) { $v = [Environment]::GetEnvironmentVariable($n); if ($v) { $envNames[$n] = $v } }
    }
    $h.Telemetry = ($envNames['CLAUDE_CODE_ENABLE_TELEMETRY'] -eq '1')
    $h.PromptLogging = ($envNames['OTEL_LOG_USER_PROMPTS'] -eq '1')
    $h.Exporters = @($envNames.Keys | Where-Object { $_ -like 'OTEL_*' -and $_ -ne 'OTEL_LOG_USER_PROMPTS' } | Sort-Object)
    $proj = Join-Path $env:USERPROFILE '.claude\projects'
    if (Test-Path -LiteralPath $proj) {
        foreach ($f in Get-ChildItem -LiteralPath $proj -Recurse -Filter *.jsonl -File -ErrorAction SilentlyContinue) {
            $h.Files++; $h.Bytes += $f.Length
            if (-not $h.Oldest -or $f.LastWriteTime -lt $h.Oldest) { $h.Oldest = $f.LastWriteTime }
        }
    }
    $h
}

function Get-ClaudeDataHealthText($h) {
    $ret = $(if ($null -eq $h.Retention) { '30 days (Claude Code default; not set in settings.json)' } else { "$($h.Retention) days (set in settings.json)" })
    $old = $(if ($h.Oldest) { "oldest from $($h.Oldest.ToString('yyyy-MM-dd')) ($([int]((Get-Date) - $h.Oldest).TotalDays) days ago)" } else { 'none found' })
    $tele = $(if ($h.Telemetry) { 'on' } else { 'off' })
    $ex = $(if ($h.Exporters.Count) { $h.Exporters -join ', ' } else { '(none)' })
    $pl = $(if ($h.PromptLogging) { 'ON: prompt text is sent to the telemetry endpoint' } else { 'off' })
    $rec = $(if ($null -eq $h.Retention -or $h.Retention -lt 365) { "Recommendation: raise it, e.g. to 3650 days, so cost history and any later review of how you use Claude Code keep their data (the button below makes that one change after asking)." } else { 'Retention is long enough for cost history and later review.' })
    @(
        'CLAUDE CODE SESSION HISTORY',
        "  Kept for: $ret",
        "  On disk now: $($h.Files) transcript files, $([math]::Round($h.Bytes / 1MB, 1)) MB; $old",
        '',
        'Claude Code deletes transcripts older than this each time it starts. The Wrangler keeps its own cost totals, so those survive, but anything that reviews what you actually did (prompts, tools, subagents) needs the files themselves.',
        $rec,
        '',
        'TELEMETRY (OpenTelemetry)',
        "  Enabled: $tele     Exporter settings present: $ex",
        "  Prompt text logging: $pl",
        '  This app never changes telemetry. See https://code.claude.com/docs/en/monitoring-usage',
        '',
        'Note: transcripts are plain text and can contain secrets that tools printed (for example from .env files).'
    ) -join "`r`n"
}

# Sets cleanupPeriodDays in ~\.claude\settings.json: backup first, edit only that key as text (everything else stays byte for byte), verify, else restore.
function Set-ClaudeRetention([int]$Days) {
    $f = Join-Path $env:USERPROFILE '.claude\settings.json'
    try {
        $dir = Split-Path -Parent $f; if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        if (-not (Test-Path -LiteralPath $f)) { Set-Content -LiteralPath $f -Value "{`r`n  `"cleanupPeriodDays`": $Days`r`n}" -Encoding UTF8; return [pscustomobject]@{ Ok = $true; Message = "Created $f with cleanupPeriodDays = $Days." } }
        $txt = [IO.File]::ReadAllText($f); $bak = "$f.bak"; Copy-Item -LiteralPath $f -Destination $bak -Force
        if ($txt -match '"cleanupPeriodDays"\s*:\s*\d+') { $new = [regex]::Replace($txt, '("cleanupPeriodDays"\s*:\s*)\d+', ('${1}' + $Days), 1) }
        else {
            $m = [regex]::Match($txt, '\{'); if (-not $m.Success) { return [pscustomobject]@{ Ok = $false; Message = 'settings.json does not look like a JSON object; nothing changed.' } }
            $rest = $txt.Substring($m.Index + 1); $comma = $(if ($rest -match '^\s*"') { ',' } else { '' })
            $new = $txt.Substring(0, $m.Index + 1) + "`r`n  `"cleanupPeriodDays`": $Days$comma" + $rest
        }
        [IO.File]::WriteAllText($f, $new, (New-Object System.Text.UTF8Encoding($false)))
        $ok = $false; try { $ok = ([int]((Get-Content -LiteralPath $f -Raw | ConvertFrom-Json).cleanupPeriodDays) -eq $Days) } catch { }
        if (-not $ok) { Copy-Item -LiteralPath $bak -Destination $f -Force; return [pscustomobject]@{ Ok = $false; Message = 'The edited file did not validate; the original was restored.' } }
        [pscustomobject]@{ Ok = $true; Message = "Set cleanupPeriodDays = $Days (backup: $bak)." }
    } catch { [pscustomobject]@{ Ok = $false; Message = "Could not change settings.json: $_" } }
}

function Show-DataHealthDialog($OwnerForm) {
    Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Claude Code data health'; $dlg.ClientSize = New-Object System.Drawing.Size(640, 430)
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.StartPosition = 'CenterParent'
    $box = New-Object System.Windows.Forms.TextBox
    $box.Multiline = $true; $box.ReadOnly = $true; $box.ScrollBars = 'Vertical'; $box.Location = New-Object System.Drawing.Point(12, 12); $box.Size = New-Object System.Drawing.Size(616, 360); $box.BackColor = [System.Drawing.SystemColors]::Window
    $bSet = New-Object System.Windows.Forms.Button; $bSet.Text = 'Set retention to 3650 days...'; $bSet.Location = New-Object System.Drawing.Point(12, 384); $bSet.Size = New-Object System.Drawing.Size(190, 28)
    $bCopy = New-Object System.Windows.Forms.Button; $bCopy.Text = 'Copy snippet'; $bCopy.Location = New-Object System.Drawing.Point(210, 384); $bCopy.Size = New-Object System.Drawing.Size(100, 28)
    $bOpen = New-Object System.Windows.Forms.Button; $bOpen.Text = 'Open settings.json'; $bOpen.Location = New-Object System.Drawing.Point(318, 384); $bOpen.Size = New-Object System.Drawing.Size(130, 28)
    $bClose = New-Object System.Windows.Forms.Button; $bClose.Text = 'Close'; $bClose.Location = New-Object System.Drawing.Point(538, 384); $bClose.Size = New-Object System.Drawing.Size(90, 28)
    $bClose.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $dlg.CancelButton = $bClose
    $dlg.Controls.AddRange(@($box, $bSet, $bCopy, $bOpen, $bClose))
    $tip = New-Object System.Windows.Forms.ToolTip
    $tip.SetToolTip($bSet, 'Adds "cleanupPeriodDays": 3650 to ~\.claude\settings.json after asking, keeping a settings.json.bak backup. Nothing else is changed.')
    $tip.SetToolTip($bCopy, 'Copy the one-line setting to paste into settings.json yourself.')
    $refresh = {
        $h = Get-ClaudeDataHealth; $box.Text = Get-ClaudeDataHealthText $h
        $bSet.Enabled = ($null -eq $h.Retention -or $h.Retention -lt 365)
    }.GetNewClosure()
    & $refresh
    $bCopy.Add_Click({ try { [System.Windows.Forms.Clipboard]::SetText('"cleanupPeriodDays": 3650') } catch { } }.GetNewClosure())
    $bOpen.Add_Click({ $f = Join-Path $env:USERPROFILE '.claude\settings.json'; try { if (Test-Path -LiteralPath $f) { Start-Process -FilePath $f } else { Start-Process explorer.exe -ArgumentList (Split-Path -Parent $f) } } catch { } }.GetNewClosure())
    $bSet.Add_Click({
        $f = Join-Path $env:USERPROFILE '.claude\settings.json'
        $q = "Change one setting in Claude Code's settings?`n`nFile: $f`nChange: set cleanupPeriodDays to 3650 (keep session history for about 10 years instead of deleting it after the current period).`n`nA backup is saved as settings.json.bak first and nothing else in the file is touched."
        if ([System.Windows.Forms.MessageBox]::Show($dlg, $q, 'Set Claude Code retention', 'YesNo', 'Question') -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        $r = Set-ClaudeRetention 3650
        [void][System.Windows.Forms.MessageBox]::Show($dlg, $r.Message, 'Claude Code data health')
        & $refresh
    }.GetNewClosure())
    [void]$dlg.ShowDialog($OwnerForm)
    $dlg.Dispose()
}

# Opens CHANGELOG.md from the install folder (always matches the installed version, works offline); falls back to GitHub.
function Open-Changelog {
    $f = Join-Path $PSScriptRoot 'CHANGELOG.md'
    try {
        if (Test-Path -LiteralPath $f) {
            try { Start-Process -FilePath $f -ErrorAction Stop } catch { Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$f`"" }   # no .md association
        } else { Start-Process "https://github.com/$($cfg.updateRepo)/blob/main/CHANGELOG.md" }
    } catch { return $false }
    return $true
}

# Start a fresh picker (same way the desktop shortcut does) so the new code takes over.
function Restart-App {
    Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
}

# ---------------------------------------------------------------- wt command building
# --- wt quoting rules (fragile!) ---
# * The whole wt command line is ONE string, passed verbatim by Start-Process;
#   wt does its own parsing. Never pass an array of args.
# * ';' is a wt command separator even inside quotes. Real separators between
#   new-tab clauses are ' ; '. A ';' INSIDE a tab's command must be '\;'.
# * Paths: escaped double quotes for wt/-d, single quotes inside -Command.
function ConvertTo-PsLiteral([string]$s) { "'" + ($s -replace "'", "''") + "'" }

function New-TabClause([string]$Title, [string]$Dir, [string]$Command, [string]$Color) {
    $inner = "Set-Location -LiteralPath $(ConvertTo-PsLiteral $Dir)"
    if ($Command) { $inner += "\; $Command" }
    $col = ''
    if ($Color) { $col = " --tabColor `"$Color`"" }
    "new-tab --title `"$Title`"$col --suppressApplicationTitle -d `"$Dir`" powershell.exe -NoExit -Command `"$inner`""
}

# ---------------------------------------------------------------- picker
# Persistent picker: launches go through $OnLaunch, tab switching through $OnSwitch, and the
# list of open projects comes from $GetRunning (all scriptblocks defined in the main script,
# because WinForms handlers are closures that can't see script-scope state or functions).
function Show-FormsPicker($Rows, [string]$InitialFilter, [string[]]$Preselect,
                          [scriptblock]$OnLaunch, [scriptblock]$OnSwitch, [scriptblock]$GetRunning, [int]$RefreshSeconds = 0, [scriptblock]$OnSaveLayout, [scriptblock]$OnArrange, [scriptblock]$OnGitOp, [hashtable]$Update, [scriptblock]$OnIde, [scriptblock]$OnCascade, [hashtable]$Actions, [scriptblock]$OnFactsStart, [scriptblock]$OnFactsDone) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $ctx = @{
        Rebuilding = $false
        Checked = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        Running = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        Clock   = [System.Diagnostics.Stopwatch]::StartNew()
        Remote  = @{}
        Busy    = $false
        ConfigDir = $ConfigDir
        ConfigFile = Join-Path $ConfigDir 'config.json'
        ConfigExample = Join-Path $PSScriptRoot 'config.example.json'
        PresetFile = Join-Path $ConfigDir 'presets.json'
        PresetExample = Join-Path $PSScriptRoot 'presets.example.json'
    }
    foreach ($r in $Rows) { if ($r.RemoteUrl) { $ctx.Remote[$r.Path] = $r.RemoteUrl } }
    foreach ($p in $Preselect)    { [void]$ctx.Checked.Add($p) }

    $form = New-Object System.Windows.Forms.Form
    $iconFile = Join-Path $PSScriptRoot 'assets\app.ico'
    $form.Text = "Workspace Wrangler v$($Update.Current)"; if (Test-Path -LiteralPath $iconFile) { try { $form.Icon = New-Object System.Drawing.Icon($iconFile) } catch { } }; $form.ClientSize = New-Object System.Drawing.Size(1150, 628)
    $form.StartPosition = 'CenterScreen'; $form.KeyPreview = $true

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'Filter:'; $lbl.Location = New-Object System.Drawing.Point(12, 16); $lbl.AutoSize = $true
    $btnNew = New-Object System.Windows.Forms.Button
    $btnNew.Text = '+ New project'; $btnNew.Location = New-Object System.Drawing.Point(440, 10); $btnNew.Size = New-Object System.Drawing.Size(90, 26)
    $filterBox = New-Object System.Windows.Forms.TextBox
    $filterBox.Location = New-Object System.Drawing.Point(60, 12); $filterBox.Width = 240; $filterBox.Text = $InitialFilter
    $stateBox = New-Object System.Windows.Forms.ComboBox
    $stateBox.DropDownStyle = 'DropDownList'; $stateBox.Location = New-Object System.Drawing.Point(308, 12); $stateBox.Width = 124
    [void]$stateBox.Items.AddRange(@('All projects', 'Dirty (uncommitted)', 'Clean', 'Open in terminal', 'Not open', 'Not a git repo')); $stateBox.SelectedIndex = 0
    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = 'Tick or Ctrl/Shift-click projects, then Launch or Switch.'
    $hint.Location = New-Object System.Drawing.Point(546, 16); $hint.AutoSize = $true

    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = 'Details'; $lv.CheckBoxes = $true; $lv.FullRowSelect = $true; $lv.GridLines = $true; $lv.HideSelection = $false
    $lv.Location = New-Object System.Drawing.Point(12, 44); $lv.Size = New-Object System.Drawing.Size(1126, 500)
    $lv.Anchor = 'Top,Bottom,Left,Right'
    # Path comes before the git-only columns (Branch, State, Remote) because not every project is a repo.
    # The Remote link column index is stored in $ctx.RemoteCol (set with $colHelp below); keep it, $colHelp and the
    # SubItems.Add order in the list fill in sync if you reorder.
    foreach ($col in @(@('Project', 200), @('Open', 45), @('Last active', 85), @('When', 115), @('Path', 230), @('Branch', 110), @('State', 55), @('Remote', 160))) {
        [void]$lv.Columns.Add($col[0], $col[1])
    }
    # Optional Cost column (index 8, after Remote so every other column index is unchanged).
    $ctx.CostOn = [bool]($Actions -and $Actions.CostOn)
    if ($ctx.CostOn) { [void]$lv.Columns.Add('Cost', 80); $lv.Columns[8].TextAlign = 'Right' }

    # ListView column headers have no built-in tooltips, so hit-test the mouse against the header strip.
    $colHelp = @(
        "Project: folder name under the root.`nGreen row = already open in a terminal.",
        "Open: $([char]0x25CF) means a cc:<project> or sh:<project> tab is open in some Windows Terminal window.`nSelect the row and click Switch to bring it forward.",
        "Last active: how long ago the project's latest git commit was`n(or its newest file change if it isn't a git repo).",
        "When: exact date and time of that last activity.",
        "Path: full folder path of the project.",
        "Branch: the current git branch (blank if not a git repo).",
        "State: 'dirty' = uncommitted changes (modified, staged or untracked files); 'clean' = nothing to commit;`nblank = not a git repo. Does not show unpushed commits.",
        "Remote: the project's git remote (origin preferred) on any host - owner/repo for GitHub, host/path otherwise. Click it to open the repository in your browser.`nBlank if the project has no remote."
    )
    $ctx.RemoteCol = 7
    if ($ctx.CostOn) { $colHelp += "Cost: estimated API-equivalent cost of this project's Claude Code sessions so far (from Claude Code's local session files).`nHover a value for the breakdown. '~' = some models are not in the price table yet." }
    $tip = New-Object System.Windows.Forms.ToolTip
    $ctx.TipCol = -1
    $lv.Add_MouseMove({
        param($s, $e)
        $headerH = 24
        if ($lv.TopItem) { $headerH = $lv.TopItem.Bounds.Top }
        $col = -1
        if ($e.Y -lt $headerH) {
            $x = 0
            for ($i = 0; $i -lt $lv.Columns.Count; $i++) {
                $x += $lv.Columns[$i].Width
                if ($e.X -lt $x) { $col = $i; break }
            }
        }
        if ($col -ne $ctx.TipCol) {
            $ctx.TipCol = $col
            if ($col -ge 0) { $tip.Show($colHelp[$col], $lv, $e.X + 12, $headerH + 6, 12000) } else { $tip.Hide($lv) }
        }
        # Hand cursor over a clickable Remote link cell.
        $hit = $lv.HitTest($e.X, $e.Y)
        $overLink = $false
        if ($hit.Item -and $hit.SubItem -and $hit.Item.SubItems.IndexOf($hit.SubItem) -eq $ctx.RemoteCol -and $ctx.Remote.ContainsKey([string]$hit.Item.Tag)) { $overLink = $true }
        if ($overLink) { $lv.Cursor = [System.Windows.Forms.Cursors]::Hand } else { $lv.Cursor = [System.Windows.Forms.Cursors]::Default }
        # Cost cell: breakdown tooltip.
        if ($ctx.CostOn -and $hit.Item -and $hit.SubItem -and $hit.Item.SubItems.IndexOf($hit.SubItem) -eq 8) {
            $cp = [string]$hit.Item.Tag
            if ($ctx.TipCell -ne $cp) {
                $r0 = $Rows | Where-Object { $_.Path -eq $cp } | Select-Object -First 1
                if ($r0 -and $r0.CostTip) { $ctx.TipCell = $cp; $tip.Show([string]$r0.CostTip, $lv, ($e.X + 14), ($e.Y + 22), 20000) }
            }
        } elseif ($ctx.TipCell) { $ctx.TipCell = $null; $tip.Hide($lv) }
    }.GetNewClosure())
    # Clicking a Remote cell opens that repository.
    $lv.Add_MouseClick({
        param($s, $e)
        $hit = $lv.HitTest($e.X, $e.Y)
        if ($hit.Item -and $hit.SubItem -and $hit.Item.SubItems.IndexOf($hit.SubItem) -eq $ctx.RemoteCol) {
            $url = $ctx.Remote[[string]$hit.Item.Tag]
            if ($url) { try { Start-Process $url } catch { $status.Text = "Could not open $url" } }
        }
    }.GetNewClosure())
    $lv.Add_MouseLeave({ $ctx.TipCol = -1; $tip.Hide($lv) }.GetNewClosure())

    $status = New-Object System.Windows.Forms.Label
    $status.Text = ''; $status.AutoSize = $true; $status.Location = New-Object System.Drawing.Point(12, 552); $status.Anchor = 'Bottom,Left'

    # Help area: links back to the GitHub repo and its issue pages.
    $repoUrl = 'https://github.com/dstaulcu/workspace-wrangler'
    $help = New-Object System.Windows.Forms.LinkLabel
    $help.Text = 'Help:  Repository  |  Open issues  |  Report a bug or request a feature  |  About'
    $help.AutoSize = $true; $help.Location = New-Object System.Drawing.Point(670, 552); $help.Anchor = 'Bottom,Right'
    foreach ($l in @(@('Repository', $repoUrl), @('Open issues', "$repoUrl/issues"), @('Report a bug or request a feature', "$repoUrl/issues/new/choose"), @('About', 'about'))) {
        [void]$help.Links.Add($help.Text.IndexOf($l[0]), $l[0].Length, $l[1])
    }
    $help.Add_LinkClicked({
        param($s, $e)
        if ([string]$e.Link.LinkData -eq 'about') { if ($Actions -and $Actions.About) { & $Actions.About $form }; return }
        try { Start-Process ([string]$e.Link.LinkData) } catch { $status.Text = "Could not open $($e.Link.LinkData)" }
    }.GetNewClosure())

    # Update notice: replaces the hint line when a newer release exists. Hooks are scriptblocks from the main script.
    $updLink = New-Object System.Windows.Forms.LinkLabel
    $updLink.AutoSize = $true; $updLink.Location = New-Object System.Drawing.Point(414, 16); $updLink.Visible = $false
    $ctx.UpdInfo = $null; $ctx.UpdTask = $null; $ctx.UpdForced = $false
    $showUpdate = {
        param($info)
        $ctx.UpdInfo = $info
        if ($info) {
            $updLink.Links.Clear()
            $updLink.Text = "Update available: v$($info.Version)  |  What's new  |  Update now  |  Skip this version"
            foreach ($l in @(@("What's new", 'notes'), @('Update now', 'update'), @('Skip this version', 'skip'))) { [void]$updLink.Links.Add($updLink.Text.IndexOf($l[0]), $l[0].Length, $l[1]) }
            $updLink.Visible = $true; $hint.Visible = $false
        } else { $updLink.Visible = $false; $hint.Visible = $true }
    }.GetNewClosure()
    $updTimer = New-Object System.Windows.Forms.Timer
    $updTimer.Interval = 700
    $updTimer.Add_Tick({
        if ($ctx.UpdTask -and $ctx.UpdTask.IsCompleted) {
            $updTimer.Stop()
            $info = & $Update.Done $ctx.UpdTask $ctx.UpdForced
            $ctx.UpdTask = $null
            $failed = [bool]($info -and $info.PSObject.Properties['Failed'])
            if ($failed) { $info = & $Update.Cached }
            & $showUpdate $info
            if ($ctx.UpdForced) {
                if ($failed) { $status.Text = 'Could not check for updates (offline or rate-limited). Try again later.' }
                elseif ($info) { $status.Text = "Update available: v$($info.Version)." } else { $status.Text = "You're up to date (v$($Update.Current))." }
            }
            $ctx.UpdForced = $false
        }
    }.GetNewClosure())
    $ctx.InstTask = $null
    $instTimer = New-Object System.Windows.Forms.Timer
    $instTimer.Interval = 500
    $instTimer.Add_Tick({
        if ($ctx.InstTask -and $ctx.InstTask.Handle.IsCompleted) {
            $instTimer.Stop()
            $t = $ctx.InstTask; $ctx.InstTask = $null
            try { $res = @($t.PS.EndInvoke($t.Handle) | Where-Object { $_ -and $_.PSObject.Properties['Ok'] } | Select-Object -Last 1)[0] } catch { $res = $null }
            try { $t.PS.Dispose() } catch { }
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
            if ($res -and $res.Ok) {
                $ans = [System.Windows.Forms.MessageBox]::Show($form, "$($res.Message)`n`nOpen the changelog to see what's new? The picker will restart either way.", 'Update', 'YesNo', 'Information')
                if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) { [void](& $Update.Changelog) }
                & $Update.Restart; $form.Close()
            } else {
                $status.Text = 'Update failed.'
                $m = if ($res) { [string]$res.Message } else { 'The update did not finish.' }
                [void][System.Windows.Forms.MessageBox]::Show($form, $m, 'Update failed', 'OK', 'Warning')
            }
        }
    }.GetNewClosure())
    $updLink.Add_LinkClicked({
        param($s, $e)
        $info = $ctx.UpdInfo; if (-not $info) { return }
        switch ([string]$e.Link.LinkData) {
            'notes'  { try { Start-Process $info.Url } catch { $status.Text = "Could not open $($info.Url)" } }
            'skip'   { & $Update.Skip $info.Tag; & $showUpdate $null; $status.Text = "Skipping v$($info.Version). 'Check for updates now' in Settings brings it back." }
            'update' {
                $q = "Update Workspace Wrangler to v$($info.Version)?`n`nYour settings are kept. The picker will restart. Open terminal windows are not affected."
                if ([System.Windows.Forms.MessageBox]::Show($form, $q, 'Update', 'YesNo', 'Question') -ne 'Yes') { return }
                if ($ctx.InstTask) { return }
                $form.Cursor = [System.Windows.Forms.Cursors]::AppStarting; $status.Text = 'Updating...'
                $ctx.InstTask = & $Update.Install $info
                $instTimer.Start()
            }
        }
    }.GetNewClosure())

    function New-Btn($text, $x, $isDefault) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $text; $b.Size = New-Object System.Drawing.Size(90, 28)
        $b.Location = New-Object System.Drawing.Point($x, 580); $b.Anchor = 'Bottom,Right'
        $b
    }
    $btnSettings = New-Btn 'Settings' 368
    $btnIde     = New-Btn 'IDE' 464
    $btnGit     = New-Btn 'Git' 560
    $btnArrange = New-Btn 'Arrange' 656
    $btnRefresh = New-Btn 'Refresh' 752
    $btnSwitch  = New-Btn 'Switch' 848
    $btnGo      = New-Btn 'Launch' 944
    $btnClose   = New-Btn 'Close' 1040
    $btnClose.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.AcceptButton = $btnGo; $form.CancelButton = $btnClose
    $form.Controls.AddRange(@($lbl, $filterBox, $stateBox, $btnNew, $hint, $updLink, $lv, $status, $help, $btnSettings, $btnIde, $btnGit, $btnArrange, $btnRefresh, $btnSwitch, $btnGo, $btnClose))

    $ctrlTip = New-Object System.Windows.Forms.ToolTip
    $ctrlTip.InitialDelay = 400; $ctrlTip.AutoPopDelay = 12000
    $ctrlTip.SetToolTip($btnNew, 'Create a new project folder in your projects folder: optionally run git init, add a README and open it in your IDE. The list reloads with it pre-checked.')
    $ctrlTip.SetToolTip($filterBox, 'Type to narrow the list by project name, path or branch. Selected projects stay selected while you filter.')
    $ctrlTip.SetToolTip($stateBox, 'Show only projects in a given state: dirty (uncommitted changes), clean, open in a terminal, not open, or not a git repo. Combines with the text filter. Click a column header to sort.')
    $ctrlTip.SetToolTip($btnSettings, 'Edit config.json (global defaults) or presets.json (per-project overrides) in your default editor (changes apply the next time the picker starts), or save the positions of your open project windows so Launch restores them.')
    $ctrlTip.SetToolTip($btnIde, 'Open the selected projects in your IDE, one new window per project. Visual Studio Code by default; set "ide" (and "ideArgs") in config.json to use another.')
    $ctrlTip.SetToolTip($btnGit, 'Git actions for the selected project: open its repository in your browser, initialize a local git repository, or create a new GitHub repository (in an organization you pick) and add it as origin. Also on the right-click menu of a row.')
    $ctrlTip.SetToolTip($btnArrange, 'Arrange the windows of all open projects now. Choose cascade, grid, side by side or stacked, or reset windows to the default size. Windows with a saved spot (Settings > Save window layout) go there; hold Shift while choosing to ignore saved spots.')
    $ctrlTip.SetToolTip($btnRefresh, 'Re-check which projects have tabs open in Windows Terminal and re-read each project''s git branch, clean/dirty state, remote and last-activity time.')
    $ctrlTip.SetToolTip($btnSwitch, 'Bring the selected project''s open tab and its terminal window to the foreground (the first one if several are selected). Works for projects marked open.')
    $ctrlTip.SetToolTip($btnGo, 'Open the selected projects, each in its own new Windows Terminal window with a Claude Code tab and a shell tab. Projects already open are brought to the front instead; hold Shift while clicking to open a new copy anyway.')
    $ctrlTip.SetToolTip($btnClose, 'Close the picker without launching anything.')
    $ctrlTip.SetToolTip($help, 'Open this project on GitHub, its open issues, or the new-issue page.')
    $ctrlTip.SetToolTip($updLink, "What's new: read the release notes.  Update now: install the new version in place (settings are kept) and restart the picker.  Skip this version: hide this notice until a newer release appears.")

    $green = [System.Drawing.Color]::FromArgb(222, 245, 226)

    # One selection, shown two ways: a row is selected exactly when its box is ticked ($ctx.Checked is the single source of truth, so
    # it also survives filtering and sorting). Ticking highlights the row; Ctrl/Shift-clicking rows ticks them. Every action uses this set.
    $setSelection = {
        param($paths)
        $want = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($p in @($paths)) { if ($p) { [void]$want.Add([string]$p) } }
        $ctx.Checked.Clear(); foreach ($p in $want) { [void]$ctx.Checked.Add($p) }
        $ctx.Syncing = $true
        try { foreach ($i in $lv.Items) { $on = $want.Contains([string]$i.Tag); $i.Checked = $on; $i.Selected = $on } } finally { $ctx.Syncing = $false }
    }.GetNewClosure()
    $showSel = {
        $vis = 0; foreach ($i in $lv.Items) { if ($i.Checked) { $vis++ } }
        $hid = $ctx.Checked.Count - $vis
        $t = '{0} selected' -f $ctx.Checked.Count; if ($hid -gt 0) { $t += " ($hid hidden by the filter)" }
        $status.Text = $t + '.'
    }.GetNewClosure()

    # Rebuild the list (newest activity first); keeps the selection.
    $fill = {
        $ctx.Rebuilding = $true
        $sel = @($lv.SelectedItems | ForEach-Object { [string]$_.Tag })
        $lv.BeginUpdate(); $lv.Items.Clear()
        $f = $filterBox.Text.Trim()
        $sf = $stateBox.SelectedIndex
        $list = @($Rows)
        if ($ctx.SortCol -ge 0) {
            $key = switch ($ctx.SortCol) {
                0 { { $_.Name } }
                1 { { [bool]$ctx.Running.Contains($_.Name) } }
                2 { { $_.LastActiveDt } }
                3 { { $_.LastActiveDt } }
                4 { { $_.Path } }
                5 { { [string]$_.Branch } }
                6 { { if ($_.Dirty -eq $true) { 0 } elseif ($_.Dirty -eq $false) { 1 } else { 2 } } }
                7 { { [string]$_.RemoteUrl } }
                default { { if ($null -eq $_.CostUsd) { -1 } else { [double]$_.CostUsd } } }
            }
            $list = @($list | Sort-Object -Property $key -Descending:([bool]$ctx.SortDesc))
        }
        foreach ($r in $list) {
            if ($f -and $r.Name.IndexOf($f, [StringComparison]::OrdinalIgnoreCase) -lt 0 -and $r.Path.IndexOf($f, [StringComparison]::OrdinalIgnoreCase) -lt 0 -and ([string]$r.Branch).IndexOf($f, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            $isOpen = $ctx.Running.Contains($r.Name)
            $keep = switch ($sf) { 1 { $r.Dirty -eq $true } 2 { $r.Dirty -eq $false } 3 { $isOpen } 4 { -not $isOpen } 5 { -not $r.IsGit } default { $true } }
            if (-not $keep) { continue }
            $it = New-Object System.Windows.Forms.ListViewItem($r.Name)
            $open = ''
            if ($isOpen) { $open = [string][char]0x25CF }
            $st = ''
            if ($r.Dirty -eq $true) { $st = 'dirty' } elseif ($r.Dirty -eq $false) { $st = 'clean' }
            [void]$it.SubItems.Add($open); [void]$it.SubItems.Add($r.Relative); [void]$it.SubItems.Add($r.LastActive)
            $gh = ''
            if ($r.RemoteUrl) { $gh = ($r.RemoteUrl -replace '^https://', '') -replace '^github\.com/', '' }
            [void]$it.SubItems.Add($r.Path); [void]$it.SubItems.Add([string]$r.Branch); [void]$it.SubItems.Add($st); [void]$it.SubItems.Add($gh)
            if ($ctx.CostOn) { [void]$it.SubItems.Add([string]$r.CostText) }
            $it.Tag = $r.Path
            # Per-cell styling so the Remote cell can look like a link; the green "open" tint is applied to every cell.
            $it.UseItemStyleForSubItems = $false
            $bg = [System.Drawing.SystemColors]::Window
            if ($isOpen) { $bg = $green }
            foreach ($sub in $it.SubItems) { $sub.BackColor = $bg }
            if ($gh) {
                $it.SubItems[$ctx.RemoteCol].ForeColor = [System.Drawing.Color]::FromArgb(0, 102, 204)
                $it.SubItems[$ctx.RemoteCol].Font =New-Object System.Drawing.Font($lv.Font, [System.Drawing.FontStyle]::Underline)
            }
            $it.Checked = $ctx.Checked.Contains($r.Path)
            [void]$lv.Items.Add($it)
            if ($ctx.Checked.Contains([string]$r.Path)) { $it.Selected = $true }
        }
        $lv.EndUpdate()
        $ctx.Rebuilding = $false
    }.GetNewClosure()

    # Ask Windows Terminal (via UI Automation) which projects have tabs open.
    $refresh = {
        $status.Text = 'Looking for open terminal tabs...'; $form.Update()
        $ctx.Running.Clear()
        foreach ($n in @(& $GetRunning)) { if ($n) { [void]$ctx.Running.Add([string]$n) } }
        $ctx.Clock.Restart()
        & $fill
        $status.Text = '{0} open project(s) found.' -f $ctx.Running.Count
    }.GetNewClosure()

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 4000
    $timer.Add_Tick({ $timer.Stop(); & $refresh }.GetNewClosure())

    # Background refresh: re-check open tabs every $RefreshSeconds seconds (0 = off). The list is only rebuilt
    # when the set of open projects actually changed, so highlight, checks and scroll position aren't disturbed.
    $bgTimer = New-Object System.Windows.Forms.Timer
    if ($RefreshSeconds -gt 0) {
        $bgTimer.Interval = [Math]::Max(5, $RefreshSeconds) * 1000
        $bgTimer.Add_Tick({
            if ($ctx.Busy -or -not $form.Visible) { return }
            $ctx.Busy = $true
            try {
                $now = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
                foreach ($n in @(& $GetRunning)) { if ($n) { [void]$now.Add([string]$n) } }
                if (-not $now.SetEquals($ctx.Running)) {
                    $top = $null; if ($lv.TopItem) { $top = [string]$lv.TopItem.Tag }
                    $ctx.Running.Clear(); foreach ($n in $now) { [void]$ctx.Running.Add($n) }
                    & $fill
                    if ($top) { foreach ($i in $lv.Items) { if ([string]$i.Tag -eq $top) { $lv.TopItem = $i; break } } }
                    $status.Text = 'Open projects updated: {0} open.' -f $ctx.Running.Count
                }
                $ctx.Clock.Restart()
            } catch { } finally { $ctx.Busy = $false }
        }.GetNewClosure())
        $bgTimer.Start()
    }

    $lv.Add_ItemChecked({
        param($s, $e)
        if ($ctx.Rebuilding -or $ctx.Syncing) { return }
        if ($e.Item.Checked) { [void]$ctx.Checked.Add([string]$e.Item.Tag) } else { [void]$ctx.Checked.Remove([string]$e.Item.Tag) }
        $ctx.Syncing = $true; try { $e.Item.Selected = $e.Item.Checked } finally { $ctx.Syncing = $false }   # ticking highlights the row
        & $showSel
    }.GetNewClosure())
    $lv.Add_ItemSelectionChanged({
        param($s, $e)
        if ($ctx.Rebuilding -or $ctx.Syncing) { return }
        if ($e.IsSelected) { [void]$ctx.Checked.Add([string]$e.Item.Tag) } else { [void]$ctx.Checked.Remove([string]$e.Item.Tag) }
        $ctx.Syncing = $true; try { $e.Item.Checked = $e.IsSelected } finally { $ctx.Syncing = $false }   # highlighting ticks the row
        & $showSel
    }.GetNewClosure())
    # Right-click acts on the selection: on an unselected row it first selects just that row; on empty space it clears the selection.
    $lv.Add_MouseDown({
        param($s, $e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Right) { return }
        $hit = $lv.HitTest($e.X, $e.Y)
        if ($hit.Item) { if (-not $ctx.Checked.Contains([string]$hit.Item.Tag)) { & $setSelection @([string]$hit.Item.Tag); & $showSel } }
        else { & $setSelection @(); & $showSel }
    }.GetNewClosure())
    # Ctrl+A selects every project shown (anything already selected but hidden by the filter stays selected).
    $lv.Add_KeyDown({
        param($s, $e)
        if ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::A) {
            & $setSelection (@($ctx.Checked) + @($lv.Items | ForEach-Object { [string]$_.Tag })); & $showSel; $e.SuppressKeyPress = $true
        }
    }.GetNewClosure())
    $filterBox.Add_TextChanged({ & $fill }.GetNewClosure())
    $stateBox.Add_SelectedIndexChanged({ & $fill; $status.Text = '{0} of {1} project(s) shown.' -f $lv.Items.Count, @($Rows).Count }.GetNewClosure())
    # Click a column header to sort by it; click again to reverse. Dates, Open and State start with the most useful end first.
    $ctx.SortCol = -1; $ctx.SortDesc = $false
    $colNames = @($lv.Columns | ForEach-Object { $_.Text })
    $lv.Add_ColumnClick({
        param($s, $e)
        $c = [int]$e.Column
        if ($ctx.SortCol -eq $c) { $ctx.SortDesc = -not $ctx.SortDesc } else { $ctx.SortCol = $c; $ctx.SortDesc = ($c -in 1, 2, 3, 8) }
        for ($i = 0; $i -lt $lv.Columns.Count; $i++) {
            $mark = ''; if ($i -eq $c) { $mark = $(if ($ctx.SortDesc) { ' ' + [char]0x25BC } else { ' ' + [char]0x25B2 }) }
            $lv.Columns[$i].Text = $colNames[$i] + $mark
        }
        & $fill
    }.GetNewClosure())
    # Refresh: re-check open tabs right away, then re-read git state (branch, dirty, remote) and last-active time in the
    # background so the window stays responsive. A timer polls the background job and applies the result.
    $factsTimer = New-Object System.Windows.Forms.Timer
    $factsTimer.Interval = 300
    $factsTimer.Add_Tick({
        $t = $ctx.FactsTask
        if (-not $t) { $factsTimer.Stop(); return }
        if (-not $t.Handle.IsCompleted) { return }
        $factsTimer.Stop(); $ctx.FactsTask = $null; $btnRefresh.Enabled = $true
        $err = ''
        $res = $null
        try { $res = & $OnFactsDone $t } catch { $err = $_.Exception.Message }
        if ($err) { $status.Text = "Could not refresh: $err"; & $fill; return }   # rows may already have changed: redraw
        # Keep newest-activity-first order (sorted in place so every closure still sees the same list).
        $sorted = @($Rows | Sort-Object LastActiveDt -Descending)
        if ($Rows -is [System.Collections.IList] -and -not $Rows.IsFixedSize) { $Rows.Clear(); $Rows.AddRange($sorted) } else { for ($i = 0; $i -lt $sorted.Count; $i++) { $Rows[$i] = $sorted[$i] } }
        foreach ($r in $Rows) { if ($r.RemoteUrl) { $ctx.Remote[$r.Path] = $r.RemoteUrl } else { [void]$ctx.Remote.Remove($r.Path) } }
        # Forget checked paths and remote links of projects that no longer exist (deleted while the picker was open).
        $live = @{}; foreach ($r in $Rows) { $live[[string]$r.Path] = $true }
        foreach ($p in @($ctx.Checked)) { if (-not $live.ContainsKey([string]$p)) { [void]$ctx.Checked.Remove($p) } }
        foreach ($k in @($ctx.Remote.Keys)) { if (-not $live.ContainsKey([string]$k)) { [void]$ctx.Remote.Remove($k) } }
        & $fill
        $extra = ''; if ($res -and ($res.Added -or $res.Removed)) { $extra = " ($($res.Added) new, $($res.Removed) gone)" } elseif ($res -and $res.Skipped) { $extra = ' (folders not rescanned: the list was narrowed by a command-line switch)' }
        $costNote = ''; if ($ctx.CostOn) { $sum = 0.0; $n = 0; foreach ($r in $Rows) { if ($null -ne $r.CostUsd) { $sum += [double]$r.CostUsd; $n++ } }; $costNote = ' Cost so far: $' + $sum.ToString('N2') + " across $n project(s)." }
        $status.Text = ('{0} open project(s); {1} project(s) refreshed{2}.' -f $ctx.Running.Count, @($Rows).Count, $extra) + $costNote
    }.GetNewClosure())
    $btnRefresh.Add_Click({
        & $refresh
        if ($ctx.FactsTask) { return }
        $task = $null
        try { if ($OnFactsStart) { $task = & $OnFactsStart } } catch { $status.Text = "Could not refresh: $($_.Exception.Message)"; return }
        if ($task) {
            $ctx.FactsTask = $task; $btnRefresh.Enabled = $false
            $status.Text = 'Refreshing projects...'; $factsTimer.Start()
        } else {
            $status.Text = '{0} open project(s) found. Git info is off (gitInfo in config.json), so only open tabs were refreshed.' -f $ctx.Running.Count
        }
    }.GetNewClosure())
    # Arrange: pick a style from a menu. Shift while choosing = ignore saved spots.
    $arrMenu = New-Object System.Windows.Forms.ContextMenuStrip
    foreach ($opt in @(@('Cascade (overlapping, title bars visible)', 'cascade'), @('Tile in a grid', 'grid'), @('Side by side (columns)', 'columns'), @('Stacked (rows)', 'rows'), @('-', ''), @('Reset window size (keep positions)', 'resize'), @('Restore saved layout only', 'none'))) {
        if ($opt[0] -eq '-') { [void]$arrMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)); continue }
        $mi = $arrMenu.Items.Add($opt[0]); $style = $opt[1]
        if ($style -eq 'cascade') { $ctx.CascadeItem = $mi }
        $mi.ToolTipText = @{
            cascade = 'Overlap the open project windows, each offset so every title bar stays visible.'
            grid    = 'Tile the open project windows in a grid that fills the screen.'
            columns = 'Put the open project windows side by side.'
            rows    = 'Stack the open project windows top to bottom.'
            resize  = 'Give every open project window the default size (windowWidth x windowHeight); positions stay.'
            none    = 'Only move windows that have a saved spot (Settings > Save window layout).'
        }[$style]
        $mi.Add_Click({
            try {
                $shift = [bool]([System.Windows.Forms.Control]::ModifierKeys -band [System.Windows.Forms.Keys]::Shift)
                $n = & $OnArrange $style $shift
                if ($n -gt 0) { $status.Text = "Arranged $n window(s)." } else { $status.Text = 'Nothing to arrange (no open project windows, or only one and no saved spot).' }
            } catch { $status.Text = "Could not arrange windows: $_" }
        }.GetNewClosure())
    }
    $btnArrange.Add_Click({ $arrMenu.Show($btnArrange, (New-Object System.Drawing.Point(0, $btnArrange.Height))) }.GetNewClosure())
    # Git: GitOps actions for the highlighted project (the Git button, and the Git submenu of the right-click menu). Items are enabled
    # only where they apply; anything that changes the project asks first (see Invoke-PickerGitOp).
    $gitMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $ctx.GitTargets = @(Get-GitTargets)
    $ctx.GitRow = {
        $path = ''
        if ($lv.SelectedItems.Count -gt 0) { $path = [string]$lv.SelectedItems[0].Tag } elseif ($ctx.Checked.Count -gt 0) { $path = [string]@($ctx.Checked)[0] }
        if (-not $path) { return $null }
        $Rows | Where-Object { $_.Path -eq $path } | Select-Object -First 1
    }.GetNewClosure()
    $runGit = {
        param($op, $owner)
        $row = & $ctx.GitRow
        if (-not $row) { $status.Text = 'Select a project first.'; return }
        $msg = ''
        try { $msg = [string](& $OnGitOp $op $row $form $owner) } catch { $msg = "Git action failed: $_" }
        $status.Text = $msg
        # The status line alone is easy to miss (and the window refreshes it when it is re-activated after a dialog), so show the outcome.
        if ($msg -and $msg -ne 'Cancelled.') {
            $good = ($msg -match '^(Created|Initialized|Added|Dry run)')
            $ic = $(if ($good) { 'Information' } else { 'Warning' })
            $tail = ''; if (-not $good) { $tail = "`n`nThis is in the log; Settings > Copy diagnostics puts it on the clipboard for an issue report." }
            [void][System.Windows.Forms.MessageBox]::Show($form, ($msg + $tail), 'Git', 'OK', $ic)
        }
        $ctx.Clock.Restart()
        if ($row.RemoteUrl) { $ctx.Remote[$row.Path] = $row.RemoteUrl }
        & $fill
    }.GetNewClosure()
    $ctx.RunGit = $runGit
    # Menu items created while a menu opens cannot rely on closure capture (nested closures see none of this function's
    # variables), so each item carries { Fn = scriptblock; A = args } in its Tag and shares this one handler.
    $menuClick = { param($sender, $e) $tg = $sender.Tag; if ($tg -and $tg.Fn) { $a = @($tg.A); & $tg.Fn @a } }   # @a splats; @($tg.A) would pass ONE array argument
    $actGitOpen = {
        $r = & $ctx.GitRow
        if ($r -and $r.RemoteUrl) { try { Start-Process ([string]$r.RemoteUrl) } catch { $status.Text = "Could not open $($r.RemoteUrl)" } }
    }.GetNewClosure()
    # Builds the Git items into any menu (the Git button's menu and the right-click Git submenu) each time it opens,
    # so enabled states always match the highlighted project.
    $fillGit = {
        param($items)
        $items.Clear()
        $row = & $ctx.GitRow
        $isGit = $row -and (Test-Path -LiteralPath (Join-Path $row.Path '.git'))
        $mOpen = $items.Add('Open repository in browser')
        $mInit = $items.Add('Initialize local repository (git init)...')
        $mRemote = New-Object System.Windows.Forms.ToolStripMenuItem 'Create remote repository'
        [void]$items.Add($mRemote)
        $mUrl = $items.Add('Add existing remote URL...')
        if (-not $row) {
            foreach ($mi in @($mOpen, $mInit, $mRemote, $mUrl)) { $mi.Enabled = $false; $mi.ToolTipText = 'Select a project first.' }
            return
        }
        $mOpen.Enabled = [bool]$row.RemoteUrl
        $mOpen.ToolTipText = $(if ($row.RemoteUrl) { [string]$row.RemoteUrl } else { 'This project has no remote yet.' })
        $mOpen.Tag = @{ Fn = $actGitOpen; A = @() }; $mOpen.Add_Click($menuClick)
        $mInit.Enabled = -not $isGit
        $mInit.ToolTipText = $(if ($isGit) { 'Already a git repository.' } else { "Run git init in $($row.Path)." })
        $mInit.Tag = @{ Fn = $runGit; A = @('init', '') }; $mInit.Add_Click($menuClick)
        $mRemote.Enabled = -not $row.RemoteUrl
        $mRemote.ToolTipText = $(if ($row.RemoteUrl) { 'This project already has a remote.' } else { 'Create a repository on GitHub (gh), GitLab (glab) or Azure DevOps (az) and add it as origin. Runs git init first if needed.' })
        $mUrl.Enabled = -not $row.RemoteUrl
        $mUrl.ToolTipText = $(if ($row.RemoteUrl) { 'This project already has a remote.' } else { 'Attach a repository you already created on any host, by URL.' })
        $mUrl.Tag = @{ Fn = $runGit; A = @('addurl', '') }; $mUrl.Add_Click($menuClick)
        # Submenu per provider; configured targets (gitOpsTargets) are listed first, then "Other...".
        foreach ($pv in 'github','gitlab','azure') {
            $label = @{ github = 'GitHub'; gitlab = 'GitLab'; azure = 'Azure DevOps' }[$pv]
            $sub = New-Object System.Windows.Forms.ToolStripMenuItem $label
            $sub.ToolTipText = "Create a new repository on $label and add it as origin."
            foreach ($t in @($ctx.GitTargets | Where-Object { $_.Provider -eq $pv })) {
                $it = $sub.DropDownItems.Add([string]$t.Owner)
                $it.ToolTipText = "Create the repository under $($t.Owner) on $label (you confirm the name and visibility next)."
                $it.Tag = @{ Fn = $runGit; A = @('remote', "$pv|$($t.Owner)") }; $it.Add_Click($menuClick)
            }
            if ($pv -eq 'github') {
                $me = $sub.DropDownItems.Add('My own account'); $me.ToolTipText = 'Create the repository under your own GitHub account.'; $me.Tag = @{ Fn = $runGit; A = @('remote', 'github|@me') }; $me.Add_Click($menuClick)
            }
            if ($sub.DropDownItems.Count) { [void]$sub.DropDownItems.Add('-') }
            $other = $sub.DropDownItems.Add('Other...'); $other.ToolTipText = "Type the owner yourself in the create dialog ($label)."; $other.Tag = @{ Fn = $runGit; A = @('remote', "$pv|") }; $other.Add_Click($menuClick)
            [void]$mRemote.DropDownItems.Add($sub)
        }
    }.GetNewClosure()
    $gitMenu.Add_Opening({ & $fillGit $gitMenu.Items }.GetNewClosure())
    $btnGit.Add_Click({ $gitMenu.Show($btnGit, (New-Object System.Drawing.Point(0, $btnGit.Height))) }.GetNewClosure())

    # Right-click menu on a project row: Launch / Switch / IDE / Git submenus. Launch, Switch and IDE act on the
    # highlighted project(s); Git acts on the first highlighted one.
    $rowMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $ctx.ClaudeVariants = @($cfg.claudeVariants | Where-Object { $_ -and $_.name -and $_.args })
    $ctx.IdeName = [string]$cfg.ide; if (-not $ctx.IdeName) { $ctx.IdeName = 'code' }
    $selRows = {
        @($Rows | Where-Object { $ctx.Checked.Contains([string]$_.Path) })
    }.GetNewClosure()
    $doLaunch = {
        param($mode, $fresh, $force, $session, $extra)
        $paths = @(& $selRows | ForEach-Object { $_.Path })
        if (-not $paths.Count) { return }
        try { & $OnLaunch $paths ([bool]$fresh) ([bool]$force) ([string]$mode) ([string]$session) ([string]$extra) } catch { $status.Text = "Launch failed: $_"; return }
        $status.Text = 'Launched {0} project(s). Rechecking open tabs shortly...' -f $paths.Count
        $timer.Stop(); $timer.Start()
    }.GetNewClosure()
    $doSwitch = {
        param($tab)
        $r = @(& $selRows)[0]; if (-not $r) { return }
        if (& $OnSwitch $r.Name ([string]$tab)) {
            $status.Text = "Switched to $($r.Name)."
        } else { $status.Text = "No open $tab tab found for $($r.Name)." }
    }.GetNewClosure()
    $reloadAfter = {
        param($res)
        if ($res.Ok) {
            [void][System.Windows.Forms.MessageBox]::Show($form, "$($res.Message)`n`nThe picker will restart to reload the list.", 'Done', 'OK', 'Information')
            & $Update.Restart; $form.Close()
        } elseif ($res.Message -and $res.Message -ne 'Cancelled.') {
            $status.Text = [string]$res.Message
            [void][System.Windows.Forms.MessageBox]::Show($form, [string]$res.Message, 'Could not complete that', 'OK', 'Warning')
        } else { $status.Text = 'Cancelled.' }
    }.GetNewClosure()
    $actNewProject = { & $reloadAfter (& $Actions.NewProject $form) }.GetNewClosure()
    $actRename = {
        $r = @(& $selRows)[0]; if (-not $r) { return }
        & $reloadAfter (& $Actions.RenameProject $r $form)
    }.GetNewClosure()
    $actLaunchOpts = {
        $r = @(& $selRows)[0]; if (-not $r) { return }
        $res = & $Actions.LaunchOptions $r $form
        $status.Text = [string]$res.Message
    }.GetNewClosure()
    $actIde = {
        $paths = @(& $selRows | ForEach-Object { $_.Path })
        try { $status.Text = [string](& $OnIde $paths) } catch { $status.Text = "Could not open the IDE: $_" }
    }.GetNewClosure()
    $actExplorer = {
        foreach ($r in @(& $selRows)) { try { Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$($r.Path)`"" } catch { $status.Text = "Could not open Explorer: $_" } }
    }.GetNewClosure()
    $actCopy = {
        try { [System.Windows.Forms.Clipboard]::SetText((@(& $selRows | ForEach-Object { $_.Path }) -join "`r`n")); $status.Text = 'Copied the path.' } catch { $status.Text = "Could not copy: $_" }
    }.GetNewClosure()
    $gitDropOpen = { param($sender, $e) & $fillGit $sender.DropDownItems }.GetNewClosure()
    $rowMenu.Add_Opening({
        param($s, $e)
        $s.Items.Clear()
        $sel = @(& $selRows)
        if (-not $sel.Count) {   # right-click on empty space: just the New project item
            $np = $s.Items.Add('New project...'); $np.ToolTipText = 'Create a new project folder in your projects folder (optionally git init, README, open in IDE).'
            $np.Tag = @{ Fn = $actNewProject; A = @() }; $np.Add_Click($menuClick)
            return
        }
        $title = $(if ($sel.Count -eq 1) { $sel[0].Name } else { "$($sel.Count) selected projects" })
        $hdr = $s.Items.Add($title); $hdr.Enabled = $false
        [void]$s.Items.Add('-')
        # Launch >
        $mL = New-Object System.Windows.Forms.ToolStripMenuItem 'Launch'; [void]$s.Items.Add($mL)
        $launchOpts = @(
            @('Claude + shell (default)', 'both', $false, $false, 'Open the project the usual way: a Claude tab and a shell tab in a new window. An already-open project is brought to the front instead.'),
            @('Claude only', 'claude', $false, $true, 'Open just a Claude Code tab in a new window (no shell tab, no extra tabs).'),
            @('Shell only', 'shell', $false, $true, 'Open just a shell tab in a new window (with the git status summary in a git repository).'),
            @('-'),
            @('New window even if already open', 'both', $false, $true, 'Open another copy of the project even if it already has tabs open.')
        )
        foreach ($o in $launchOpts) {
            if ($o[0] -eq '-') { [void]$mL.DropDownItems.Add('-'); continue }
            $it = $mL.DropDownItems.Add($o[0]); $it.ToolTipText = $o[4]
            $it.Tag = @{ Fn = $doLaunch; A = @($o[1], $o[2], $o[3], 'auto', '') }; $it.Add_Click($menuClick)
        }
        # Launch > Claude session >  (how the Claude tab starts); your own variants come from config.json "claudeVariants".
        $mC = New-Object System.Windows.Forms.ToolStripMenuItem 'Claude session'
        $mC.ToolTipText = 'Choose how Claude starts in a new Claude + shell window.'
        [void]$mL.DropDownItems.Insert(3, $mC)
        $sessOpts = @(
            @('Continue the last conversation  (--continue)', 'continue', '', 'Reopen the most recent conversation for this folder.'),
            @('Pick a conversation to resume  (--resume)', 'resume', '', 'Start Claude with its conversation picker so you can choose which earlier session to resume.'),
            @('Start a fresh conversation', 'fresh', '', 'Start plain "claude" with no earlier conversation.')
        )
        foreach ($v in $ctx.ClaudeVariants) { $sessOpts += ,@([string]$v.name, 'auto', [string]$v.args, "Claude + shell with extra arguments: claude $($v.args)  (from claudeVariants in config.json)") }
        $i = 0
        foreach ($o in $sessOpts) {
            if ($i -eq 3) { [void]$mC.DropDownItems.Add('-') }
            $i++
            $it = $mC.DropDownItems.Add($o[0]); $it.ToolTipText = $o[3]
            $it.Tag = @{ Fn = $doLaunch; A = @('both', $false, $true, $o[1], $o[2]) }; $it.Add_Click($menuClick)
        }
        # Switch >
        $mS = New-Object System.Windows.Forms.ToolStripMenuItem 'Switch'; [void]$s.Items.Add($mS)
        $isOpen = $ctx.Running.Contains($sel[0].Name)
        foreach ($o in @(@('Claude tab', 'claude', 'Select the project''s Claude tab (cc:) and bring its window to the front.'), @('Shell tab', 'shell', 'Select the project''s shell tab (sh:) and bring its window to the front.'), @('Whichever is open', 'any', 'Bring the project''s window to the front (Claude tab first).'))) {
            $it = $mS.DropDownItems.Add($o[0]); $it.ToolTipText = $o[2]
            $it.Enabled = $isOpen
            if (-not $isOpen) { $it.ToolTipText = 'This project has no open tab. Use Launch.' }
            $it.Tag = @{ Fn = $doSwitch; A = @($o[1]) }; $it.Add_Click($menuClick)
        }
        # IDE >
        $mI = New-Object System.Windows.Forms.ToolStripMenuItem 'IDE'; [void]$s.Items.Add($mI)
        $it = $mI.DropDownItems.Add("Open in $($ctx.IdeName)"); $it.ToolTipText = 'Open the selected project(s) in your IDE, one new window each (config "ide").'
        $it.Tag = @{ Fn = $actIde; A = @() }; $it.Add_Click($menuClick)
        $it = $mI.DropDownItems.Add('Open folder in File Explorer'); $it.ToolTipText = 'Show the project folder in Windows File Explorer.'
        $it.Tag = @{ Fn = $actExplorer; A = @() }; $it.Add_Click($menuClick)
        $it = $mI.DropDownItems.Add('Copy path'); $it.ToolTipText = 'Copy the project folder path to the clipboard.'
        $it.Tag = @{ Fn = $actCopy; A = @() }; $it.Add_Click($menuClick)
        # Git >
        $mG = New-Object System.Windows.Forms.ToolStripMenuItem 'Git'; [void]$s.Items.Add($mG)
        [void]$mG.DropDownItems.Add('...')   # placeholder so the arrow shows; filled when the submenu opens
        $mG.Add_DropDownOpening($gitDropOpen)
        [void]$s.Items.Add('-')
        $lo = $s.Items.Add('Launch options...'); $lo.ToolTipText = 'Customize how this project launches: Claude arguments, shell tab and startup command, URLs to open, tab color. Saved to presets.json.'
        $lo.Enabled = ($sel.Count -eq 1); if ($sel.Count -ne 1) { $lo.ToolTipText = 'Select a single project to edit its launch options.' }
        $lo.Tag = @{ Fn = $actLaunchOpts; A = @() }; $lo.Add_Click($menuClick)
        $rn = $s.Items.Add('Rename project...'); $rn.ToolTipText = 'Rename the project folder and carry its Claude history, preset and window position along. Close its terminal tabs first.'
        $rn.Enabled = ($sel.Count -eq 1); if ($sel.Count -ne 1) { $rn.ToolTipText = 'Select a single project to rename it.' }
        $rn.Tag = @{ Fn = $actRename; A = @() }; $rn.Add_Click($menuClick)
    }.GetNewClosure())
    $lv.ContextMenuStrip = $rowMenu
    # Settings: open the JSON files in the default editor (created from the example files if missing).
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $miCfg = $menu.Items.Add('Edit config.json (global defaults)')
    $miPre = $menu.Items.Add('Edit presets.json (per-project overrides)')
    $miLay = $menu.Items.Add('Save window layout (remember where open projects are)')
    $miUpd = $menu.Items.Add('Check for updates now')
    $miRoot = $menu.Items.Add('Projects folders...')
    $miLog = $menu.Items.Add('Changelog (what changed in each version)')
    $miCost = $menu.Items.Add('Show project cost'); $miCost.CheckOnClick = $false
    $miHealth = $menu.Items.Add('Claude Code data health...')
    $miDiag = $menu.Items.Add('Copy diagnostics (for an issue report)')
    $miLogOpen = $menu.Items.Add('Open the log')
    $miAbout = $menu.Items.Add('About Workspace Wrangler...')
    $miAbout.ToolTipText = 'Version, links and the full concept art.'
    $miCfg.ToolTipText = 'Open config.json (global defaults) in your editor. Changes apply the next time the picker starts.'
    $miPre.ToolTipText = 'Open presets.json (per-project extra tabs, apps, Claude arguments, tab color) in your editor.'
    $miLay.ToolTipText = 'Remember where each open project window is; later launches put them back (per monitor setup).'
    $miUpd.ToolTipText = 'Look for a newer GitHub release now, even if you skipped it.'
    $miLog.ToolTipText = 'Open CHANGELOG.md: what changed in each version.'
    $miCfg.Add_Click({
        try {
            New-Item -ItemType Directory -Force -Path $ctx.ConfigDir | Out-Null
            if (-not (Test-Path -LiteralPath $ctx.ConfigFile) -and (Test-Path -LiteralPath $ctx.ConfigExample)) { Copy-Item -LiteralPath $ctx.ConfigExample -Destination $ctx.ConfigFile }
            Start-Process -FilePath $ctx.ConfigFile; $status.Text = 'Opened config.json. Restart the picker to apply changes.' } catch { $status.Text = "Could not open config.json: $_" }
    }.GetNewClosure())
    $miPre.Add_Click({
        try {
            New-Item -ItemType Directory -Force -Path $ctx.ConfigDir | Out-Null
            if (-not (Test-Path -LiteralPath $ctx.PresetFile) -and (Test-Path -LiteralPath $ctx.PresetExample)) { Copy-Item -LiteralPath $ctx.PresetExample -Destination $ctx.PresetFile }
            Start-Process -FilePath $ctx.PresetFile; $status.Text = 'Opened presets.json. Restart the picker to apply changes.'
        } catch { $status.Text = "Could not open presets.json: $_" }
    }.GetNewClosure())
    $btnNew.Add_Click({ & $actNewProject }.GetNewClosure())
    $miRoot.ToolTipText = 'Choose which folders hold your projects (each subfolder is a project; you can use several). Saved as "roots" in config.json; the picker restarts.'
    $miRoot.Add_Click({
        $p = & $Actions.ChooseRoot
        if ($p) { & $Update.Restart; $form.Close() }
    }.GetNewClosure())
    $miCost.Checked = $ctx.CostOn
    $miCost.ToolTipText = "Add a Cost column: each project's estimated Claude Code cost, from Claude Code's local session files (read-only; the picker restarts)."
    $miCost.Add_Click({ if ($Actions -and $Actions.SetCost) { & $Actions.SetCost (-not $ctx.CostOn); & $Update.Restart; $form.Close() } }.GetNewClosure())
    $miHealth.ToolTipText = 'Check whether Claude Code keeps its session history long enough for cost and usage review, and what telemetry is on.'
    $miHealth.Add_Click({ if ($Actions -and $Actions.Health) { & $Actions.Health $form } }.GetNewClosure())
    $miDiag.ToolTipText = 'Copy versions and the recent log (user name and home folder masked) to the clipboard, ready to paste into a GitHub issue.'
    $miDiag.Add_Click({ try { & $Actions.Diagnostics; $status.Text = 'Diagnostics copied to the clipboard.' } catch { $status.Text = "Could not copy diagnostics: $_" } }.GetNewClosure())
    $miLogOpen.Add_Click({ try { & $Actions.OpenLog } catch { $status.Text = "Could not open the log: $_" } }.GetNewClosure())
    $miAbout.Add_Click({ if ($Actions -and $Actions.About) { & $Actions.About $form } }.GetNewClosure())
    $miLog.Add_Click({ if (-not (& $Update.Changelog)) { $status.Text = 'Could not open the changelog.' } }.GetNewClosure())
    $miUpd.Add_Click({
        $t = & $Update.Start $true
        if ($t) { $ctx.UpdTask = $t; $ctx.UpdForced = $true; $status.Text = 'Checking for updates...'; $updTimer.Start() } else { $status.Text = 'Could not start the update check.' }
    }.GetNewClosure())
    $miLay.Add_Click({
        try {
            $n = & $OnSaveLayout
            $status.Text = "Saved window positions for $n open project(s). They are restored the next time you launch them."
        } catch { $status.Text = "Could not save layout: $_" }
    }.GetNewClosure())
    $btnSettings.Add_Click({ $menu.Show($btnSettings, (New-Object System.Drawing.Point(0, $btnSettings.Height))) }.GetNewClosure())
    $btnSwitch.Add_Click({
        $path = ''
        if ($lv.SelectedItems.Count -gt 0) { $path = [string]$lv.SelectedItems[0].Tag } elseif ($ctx.Checked.Count -gt 0) { $path = [string]@($ctx.Checked)[0] }
        if (-not $path) { $status.Text = 'Select a project first, then Switch.'; return }
        $name = ($Rows | Where-Object { $_.Path -eq $path } | Select-Object -First 1).Name
        if (& $OnSwitch $name) {
            $status.Text = "Switched to $name."
        } else {
            $status.Text = "No open tab found for $name (use Launch to open it)."
        }
    }.GetNewClosure())
    $btnIde.Add_Click({
        $paths = @($ctx.Checked)
        if ($paths.Count -eq 0) { $status.Text = 'Select a project first, then IDE.'; return }
        try { $status.Text = [string](& $OnIde $paths) } catch { $status.Text = "Could not open the IDE: $_" }
    }.GetNewClosure())
    $btnGo.Add_Click({
        if ($ctx.Checked.Count -eq 0) { $status.Text = 'Select at least one project to launch.'; return }
        $paths = @($ctx.Checked)
        $force = [bool]([System.Windows.Forms.Control]::ModifierKeys -band [System.Windows.Forms.Keys]::Shift)   # Shift+Launch = open a new copy even if already open
        & $OnLaunch $paths $false $force
        $ctx.Checked.Clear()
        & $fill
        $status.Text = 'Launched {0} project(s). Rechecking open tabs shortly...' -f $paths.Count
        $timer.Stop(); $timer.Start()
    }.GetNewClosure())
    # Coming back to the picker (e.g. after switching away) re-checks which tabs are open.
    $form.Add_Activated({ if ($ctx.Clock.ElapsedMilliseconds -gt 3000) { & $refresh } }.GetNewClosure())

    & $fill
    $form.Add_Shown({
        $form.TopMost = $true; $form.Activate(); $form.TopMost = $false
        $filterBox.Focus(); & $refresh
        # Project cost: ask once (opt-in); when on, a background refresh fills the column (also re-reads git state).
        if ($Actions -and $Actions.CostAsk) {
            $q = "Show what each project has cost?`n`nWorkspace Wrangler can estimate each project's Claude Code cost from the session files Claude Code keeps on this computer (under ~\.claude\projects). It only reads them, keeps just token counts and model names in its own settings folder, and sends nothing anywhere.`n`nYou can change this any time under Settings > Show project cost."
            $ans = [System.Windows.Forms.MessageBox]::Show($form, $q, 'Show project cost?', 'YesNo', 'Question')
            & $Actions.SetCost ($ans -eq [System.Windows.Forms.DialogResult]::Yes)
            if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) { & $Update.Restart; $form.Close(); return }
        }
        if ($ctx.CostOn) { $btnRefresh.PerformClick() }
        # Update check on startup (non-blocking; throttled by updateCheckHours, cached result shown meanwhile).
        $t = & $Update.Start $false
        if ($t) { $ctx.UpdTask = $t; $updTimer.Start() } else { & $showUpdate (& $Update.Cached) }
    }.GetNewClosure())
    # Global hotkey (config `hotkey`, default Ctrl+Alt+W): cascade every open workspace to the front. Works while this picker is open.
    $hk = $null
    $spec = ConvertTo-HotkeySpec ([string]$cfg.hotkey)
    if ($spec) {
        try {
            Initialize-HotkeyType
            $hk = New-Object WoHotkey
            if ($hk.Register($spec.Mods, $spec.Vk)) {
                # Pressing it cascades every open workspace, then brings the Wrangler itself up on top of them.
                $hk.add_Pressed({
                    # Restore the Wrangler if minimized, then cascade it together with the workspace windows (it ends up on top).
                    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal }
                    try { $n = & $OnCascade $form.Handle.ToInt64(); $status.Text = "Cascaded $n workspace window(s) and the Wrangler." } catch { $status.Text = "Cascade failed: $_" }
                }.GetNewClosure())
                # Make the hotkey discoverable in the app itself.
                $hotText = [string]$cfg.hotkey
                $hint.Text = "Tick or Ctrl/Shift-click projects, then Launch or Switch.  Hotkey: $hotText cascades all workspaces."
                if ($ctx.CascadeItem) { $ctx.CascadeItem.ShortcutKeyDisplayString = $hotText }
                $ctrlTip.SetToolTip($btnArrange, ($ctrlTip.GetToolTip($btnArrange) + " Hotkey $hotText cascades all open workspaces from anywhere and brings this window up on top (works while the picker is open)."))
            } else { $hk = $null; $ctx.HotkeyNote = "Hotkey $($cfg.hotkey) is already used by another program." }
        } catch { $hk = $null; $ctx.HotkeyNote = "Could not register hotkey $($cfg.hotkey): $_" }
    } elseif ([string]$cfg.hotkey) { $ctx.HotkeyNote = "Hotkey '$($cfg.hotkey)' is not valid (use e.g. Ctrl+Alt+W)." }
    if ($ctx.HotkeyNote) { $status.Text = $ctx.HotkeyNote }
    Close-Splash
    [void]$form.ShowDialog()
    if ($hk) { try { $hk.Unregister() } catch { } }
    $timer.Dispose(); $bgTimer.Dispose(); $updTimer.Dispose()
    $null
}

# ---------------------------------------------------------------- launch (build + start wt)
function Invoke-Launch($Selected, [bool]$FreshRun, [bool]$Remember, [bool]$ForceNew = $false, [string]$Mode = 'both', [string]$Session = 'auto', [string]$ExtraArgs = '') {
    $groups = @(); $groupNames = @()
    $extraApps = @(); $consumed = @(); $urls = @()
    # Projects that already have a tab open are brought to the foreground instead of being launched a second time.
    $open = @(); if (-not $ForceNew) { $open = @(Get-RunningNames) }
    $toFocus = @()
    foreach ($p in $Selected) {
        if (-not (Test-Path -LiteralPath $p.Path)) { Write-Warning "Directory not found: $($p.Path)"; continue }
        if ($open -contains $p.Name) { $toFocus += $p.Name; continue }
        $preset = Get-Preset $p.Name

        # Per-project overrides from presets.json fall back to the global settings.
        $pShell = $wantShell; if ($preset -and $null -ne $preset.shell) { $pShell = [bool]$preset.shell -and (-not $NoShell) }
        $pDiff  = $wantDiff;  if ($preset -and $null -ne $preset.diff)  { $pDiff  = [bool]$preset.diff  -and (-not $NoDiff) }
        $cArgs  = [string]$cfg.claudeArgs; if ($preset -and $null -ne $preset.claudeArgs) { $cArgs = [string]$preset.claudeArgs }
        $color  = $null
        if ($wantColor) { $color = Get-TabColor $p.Name; if ($preset -and $preset.tabColor) { $color = [string]$preset.tabColor } }

        # claude --continue only when prior session history exists (and not fresh).
        # $Session: auto (continue if there is history, unless -Fresh) | continue | resume (claude's session picker) | fresh.
        $parts = @('claude')
        switch ($Session) {
            'continue' { $parts += '--continue' }
            'resume'   { $parts += '--resume' }
            'fresh'    { }
            default    { if ((Test-ClaudeHistory $p.Path) -and -not $FreshRun) { $parts += '--continue' } }
        }
        if ($cArgs.Trim()) { $parts += ($cArgs.Trim() -replace ';', '\;') }   # args must not contain double quotes
        $xa = ($ExtraArgs -replace '"', '').Trim()                              # variant args from config.json (claudeVariants)
        if ($xa) { $parts += ($xa -replace ';', '\;') }
        # A message left for Claude (e.g. after Rename project) is sent once as the session's first message. It goes through a
        # file so quotes and spaces cannot upset the wt command line.
        if ($Mode -ne 'shell' -and $Session -ne 'resume' -and $state.pending.ContainsKey($p.Path) -and ([string]$state.pending[$p.Path]).Trim()) {
            $pf = Join-Path $ConfigDir "pending\$($p.Name).txt"
            if (-not $DryRun) { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $pf) | Out-Null; Set-Content -LiteralPath $pf -Value ([string]$state.pending[$p.Path]) -NoNewline -Encoding UTF8 }
            $parts += "(Get-Content -Raw -LiteralPath $(ConvertTo-PsLiteral $pf))"
            $consumed += $p.Path
        }
        # Tab titles: Claude tab = "cc:<project>", every other tab = "sh:<scope>" (kept short; detection depends on them).
        $pc = @()
        # $Mode: both (default) | claude (only the Claude tab) | shell (only a shell tab).
        if ($Mode -ne 'shell') { $pc += New-TabClause "cc:$($p.Name)" $p.Path ($parts -join ' ') $color }

        if (($pShell -and $Mode -eq 'both') -or $Mode -eq 'shell') {
            $shellCmd = $null
            $startup = ''; if ($preset -and $preset.startupCommand) { $startup = ([string]$preset.startupCommand -replace '"', '').Trim() }   # preset "startupCommand": runs in the shell tab instead of the git summary
            if ($startup) { $shellCmd = ($startup -replace ';', '\;') }
            elseif ($pDiff -and (Test-Path -LiteralPath (Join-Path $p.Path '.git'))) { $shellCmd = 'git status -sb\; git diff --stat' }
            $pc += New-TabClause "sh:$($p.Name)" $p.Path $shellCmd $color
        }
        if ($preset -and $Mode -eq 'both') {
            foreach ($t in @($preset.extraTabs)) {
                if (-not $t) { continue }
                if (-not (Test-Path -LiteralPath $t.path)) { Write-Warning "Directory not found: $($t.path)"; continue }
                $pc += New-TabClause "sh:$($t.title)" $t.path $null $color
            }
            foreach ($l in @($preset.launch)) { if ($l) { $extraApps += $l } }
            foreach ($u in @($preset.urls)) { if ($u) { $urls += [string]$u } }   # preset "urls": opened in the default browser, once per launch
        }
        $groups += ,$pc; $groupNames += $p.Name
    }
    if ($groups.Count -eq 0 -and -not $toFocus.Count) { return }

    # Default: every project gets its OWN new terminal window (one wt call each). With -Window <id>, all tabs go to that window.
    $newWindow = (-not $Window) -or ($Window -eq 'new')
    $calls = @()
    if (-not $groups.Count) { }
    elseif ($newWindow) {
        foreach ($g in $groups) { $calls += "-w new " + (($g + 'focus-tab -t 0') -join ' ; ') }
    } else {
        $calls += "-w $Window " + ((@($groups | ForEach-Object { $_ })) -join ' ; ')
    }

    if ($Remember -and -not $DryRun) { $state.last = @($Selected | ForEach-Object { $_.Path }); Save-State }
    if ($consumed.Count -and -not $DryRun) { foreach ($c in $consumed) { $state.pending.Remove($c) }; Save-State }   # sent once
    if ($DryRun) {
        foreach ($n in $toFocus) { Write-Output "FOCUS (already open): $n" }
        foreach ($c in $calls) { Write-Output $c }
        foreach ($a in $extraApps) { Write-Output "LAUNCH: $($a.exe) $(@($a.args) -join ' ')" }
        foreach ($u in @($urls | Select-Object -Unique)) { Write-Output "URL: $u" }
        return
    }
    $before = @(); if ($newWindow -and $calls.Count) { $before = @(Get-TerminalWindows | ForEach-Object { $_.Handle }) }
    foreach ($c in $calls) { Start-Process -FilePath 'wt.exe' -ArgumentList $c; if ($calls.Count -gt 1) { Start-Sleep -Milliseconds 400 } }
    if ($newWindow -and $calls.Count) { try { Invoke-WindowArrangement $before $groupNames } catch { Write-Warning "Window arrangement failed: $_" } }
    # Raise already-open projects last (after any new windows have appeared) so they end up in front.
    if ($toFocus.Count -and $calls.Count) { Start-Sleep -Milliseconds 1200 }
    foreach ($n in $toFocus) { [void](Switch-ToProject $n) }
    foreach ($a in $extraApps) {
        if (-not (Test-Path -LiteralPath $a.exe)) { Write-Warning "Executable not found: $($a.exe)"; continue }
        if ($a.args) { Start-Process -FilePath $a.exe -ArgumentList @($a.args) } else { Start-Process -FilePath $a.exe }
    }
    # Only http(s) addresses are opened (never other protocol handlers or local files).
    foreach ($u in @($urls | Select-Object -Unique)) {
        if ($u -match '^https?://\S+$') { try { Start-Process $u } catch { Write-Warning "Could not open $u : $_" } }
        else { Write-Warning "Ignoring URL (only http/https addresses are opened): $u" }
    }
}

# ---------------------------------------------------------------- -CheckUpdate (no UI)
if ($CheckUpdate) {
    $t = Start-UpdateCheck $true
    $info = $null; $ok = $false
    if ($t -and $t.Wait(12000)) { $ok = -not $t.IsFaulted; if ($ok) { $info = Complete-UpdateCheck $t $true; if ($info -and $info.PSObject.Properties['Failed']) { $ok = $false; $info = $null } } }
    [pscustomobject]@{
        current = $AppVersion; checked = $ok
        latest = $(if ($ok -and $state.update) { [string]$state.update.tag } else { $null })
        updateAvailable = [bool]$info; url = $(if ($info) { $info.Url } else { $null })
    } | ConvertTo-Json
    return
}

# ---------------------------------------------------------------- -Cascade (no UI)
if ($Cascade) {
    $n = Invoke-CascadeFront
    if (-not $n) { Write-Warning 'No open workspace windows found.'; exit 1 }
    Write-Output "Cascaded $n workspace window(s)."
    return
}

# ---------------------------------------------------------------- -Focus (no UI)
if ($Focus) {
    if (Switch-ToProject $Focus) { return }
    Write-Warning "No open tab found for: $Focus"; exit 1
}

# ---------------------------------------------------------------- project management: new / rename
# With the Git menu, these are the only places the Wrangler changes your files, and only after you confirm.
function Test-ProjectName([string]$Name, [string]$ParentDir, [string]$Current = '') {
    $n = $Name.Trim()
    if (-not $n) { return 'Enter a name.' }
    if ($n -match '[\/:*?"<>|]') { return 'A folder name cannot contain  \ / : * ? " < > |' }
    if ($n -match '[. ]$') { return 'A folder name cannot end with a dot or a space.' }
    if ($n.StartsWith('.')) { return 'Names starting with a dot are hidden from the project list.' }
    if ($n -match '^(CON|PRN|AUX|NUL|COM\d|LPT\d)(\..*)?$') { return "'$n' is a reserved Windows name." }
    if ($n -ine $Current -and (Test-Path -LiteralPath (Join-Path $ParentDir $n))) { return 'A folder with that name already exists here.' }
    $null
}

# Dialog: name for a new project (+ git init / README / open in IDE). Returns $null or { Name, GitInit, Readme, OpenIde }.
function Show-NewProjectDialog($OwnerForm, [string[]]$Parents) {
    $ParentDir = [string]@($Parents)[0]
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'New project'; $dlg.ClientSize = New-Object System.Drawing.Size(470, 262)
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.StartPosition = 'CenterParent'
    $l1 = New-Object System.Windows.Forms.Label; $l1.Text = 'Project name:'; $l1.AutoSize = $true; $l1.Location = New-Object System.Drawing.Point(12, 16)
    $txt = New-Object System.Windows.Forms.TextBox; $txt.Location = New-Object System.Drawing.Point(110, 12); $txt.Width = 350
    # Gray placeholder text inside the box (Windows cue banner); harmless if the type can't be loaded.
    try {
        if (-not ('WoCue' -as [type])) { Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class WoCue { [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, string l); }' }
        $txt.Add_HandleCreated({ param($s, $e) [void][WoCue]::SendMessage($s.Handle, 0x1501, [IntPtr]1, 'noun-verb, e.g. page-distill') }.GetNewClosure())
    } catch { }
    $naming = New-Object System.Windows.Forms.Label; $naming.Location = New-Object System.Drawing.Point(110, 38); $naming.Size = New-Object System.Drawing.Size(350, 32)
    $naming.ForeColor = [System.Drawing.SystemColors]::GrayText
    $naming.Text = "Tip: a noun-verb name reads well, e.g. page-distill or log-triage."
    $where = New-Object System.Windows.Forms.Label; $where.Location = New-Object System.Drawing.Point(12, 76); $where.Size = New-Object System.Drawing.Size(448, 32)
    $chkGit = New-Object System.Windows.Forms.CheckBox; $chkGit.Text = 'Initialize a git repository (git init)'; $chkGit.Checked = $true; $chkGit.AutoSize = $true; $chkGit.Location = New-Object System.Drawing.Point(110, 114)
    $chkRead = New-Object System.Windows.Forms.CheckBox; $chkRead.Text = 'Create a README.md'; $chkRead.Checked = $true; $chkRead.AutoSize = $true; $chkRead.Location = New-Object System.Drawing.Point(110, 140)
    $chkIde = New-Object System.Windows.Forms.CheckBox; $chkIde.Text = 'Open it in my IDE afterwards'; $chkIde.Checked = $false; $chkIde.AutoSize = $true; $chkIde.Location = New-Object System.Drawing.Point(110, 166)
    $err = New-Object System.Windows.Forms.Label; $err.ForeColor = [System.Drawing.Color]::Firebrick; $err.Location = New-Object System.Drawing.Point(12, 192); $err.Size = New-Object System.Drawing.Size(448, 20)
    $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'Create'; $ok.Location = New-Object System.Drawing.Point(274, 222); $ok.Size = New-Object System.Drawing.Size(90, 28)
    $cancel = New-Object System.Windows.Forms.Button; $cancel.Text = 'Cancel'; $cancel.Location = New-Object System.Drawing.Point(374, 222); $cancel.Size = New-Object System.Drawing.Size(90, 28)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    $dlg.Controls.AddRange(@($l1, $txt, $naming, $where, $chkGit, $chkRead, $chkIde, $err, $ok, $cancel))
    $tip = New-Object System.Windows.Forms.ToolTip
    $tip.SetToolTip($txt, 'The new folder name (letters, digits, "-" and "_" are safest). A noun-verb name such as page-distill is suggested, not required.')
    $tip.SetToolTip($chkGit, 'Run git init in the new folder so it is a repository from the start.')
    $tip.SetToolTip($chkRead, 'Create a README.md containing the project name as a heading.')
    $tip.SetToolTip($chkIde, 'Open the new folder in your IDE (config "ide") right after creating it.')
    $tip.SetToolTip($ok, 'Create the folder in your projects folder and add it to the list.')
    $tip.SetToolTip($cancel, 'Close without creating anything.')
    # With several project folders, let the user pick which one the new project goes in (the dialog grows to make room).
    $cur = @{ Parent = $ParentDir }
    if (@($Parents).Count -gt 1) {
        $dlg.ClientSize = New-Object System.Drawing.Size(470, 292)
        foreach ($c in @($where, $chkGit, $chkRead, $chkIde, $err, $ok, $cancel)) { $c.Top += 30 }
        $inLbl = New-Object System.Windows.Forms.Label; $inLbl.Text = 'Create in:'; $inLbl.AutoSize = $true; $inLbl.Location = New-Object System.Drawing.Point(12, 80)
        $parentBox = New-Object System.Windows.Forms.ComboBox; $parentBox.DropDownStyle = 'DropDownList'; $parentBox.Location = New-Object System.Drawing.Point(110, 76); $parentBox.Width = 350
        foreach ($pp in @($Parents)) { [void]$parentBox.Items.Add([string]$pp) }
        $parentBox.SelectedIndex = 0
        $dlg.Controls.AddRange(@($inLbl, $parentBox))
        $tip.SetToolTip($parentBox, 'Which of your project folders the new project is created in.')
    }
    $upd = { $e = Test-ProjectName $txt.Text $cur.Parent; $err.Text = $(if ($txt.Text.Trim()) { [string]$e } else { '' }); $where.Text = "Will be created at: $(Join-Path $cur.Parent $txt.Text.Trim())"; $ok.Enabled = ($txt.Text.Trim() -and -not $e) }.GetNewClosure()
    $txt.Add_TextChanged($upd)
    if ($parentBox) { $parentBox.Add_SelectedIndexChanged({ $cur.Parent = [string]$parentBox.SelectedItem; & $upd }.GetNewClosure()) }
    & $upd
    $res = $dlg.ShowDialog($OwnerForm); $out = $null
    if ($res -eq [System.Windows.Forms.DialogResult]::OK) { $out = [pscustomobject]@{ Name = $txt.Text.Trim(); Parent = $cur.Parent; GitInit = $chkGit.Checked; Readme = $chkRead.Checked; OpenIde = $chkIde.Checked } }
    $dlg.Dispose(); $out
}

# Dialog: new name for an existing project, plus an optional message for Claude's next session in it.
# Returns $null or { Name, Note } (Note is empty when unticked).
function Show-RenameDialog($OwnerForm, $Row) {
    $parent = Split-Path -Parent $Row.Path
    $old = $Row.Name
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Rename $old"; $dlg.ClientSize = New-Object System.Drawing.Size(470, 366)
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.StartPosition = 'CenterParent'
    $l1 = New-Object System.Windows.Forms.Label; $l1.Text = 'New name:'; $l1.AutoSize = $true; $l1.Location = New-Object System.Drawing.Point(12, 16)
    $txt = New-Object System.Windows.Forms.TextBox; $txt.Location = New-Object System.Drawing.Point(90, 12); $txt.Width = 370; $txt.Text = $old
    $naming = New-Object System.Windows.Forms.Label; $naming.Location = New-Object System.Drawing.Point(90, 38); $naming.Size = New-Object System.Drawing.Size(370, 18)
    $naming.ForeColor = [System.Drawing.SystemColors]::GrayText
    $naming.Text = "Tip: a noun-verb name reads well, e.g. page-distill or log-triage."
    $err = New-Object System.Windows.Forms.Label; $err.ForeColor = [System.Drawing.Color]::Firebrick; $err.Location = New-Object System.Drawing.Point(12, 58); $err.Size = New-Object System.Drawing.Size(448, 20)
    $info = New-Object System.Windows.Forms.Label; $info.Location = New-Object System.Drawing.Point(12, 84); $info.Size = New-Object System.Drawing.Size(448, 112)
    $info.Text = "The folder is renamed in place ($parent).`n`nAlso updated so nothing is lost: its Claude conversation history (so --continue keeps working), its entry in presets.json, its saved window position and the remembered selection.`n`nClose its terminal tabs and IDE window first."
    $chk = New-Object System.Windows.Forms.CheckBox; $chk.Text = 'Tell Claude about the rename the next time I launch this project'; $chk.Checked = $true; $chk.AutoSize = $true; $chk.Location = New-Object System.Drawing.Point(12, 202)
    $note = New-Object System.Windows.Forms.TextBox; $note.Multiline = $true; $note.ScrollBars = 'Vertical'; $note.Location = New-Object System.Drawing.Point(12, 228); $note.Size = New-Object System.Drawing.Size(448, 82)
    $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'Rename'; $ok.Location = New-Object System.Drawing.Point(274, 326); $ok.Size = New-Object System.Drawing.Size(90, 28)
    $cancel = New-Object System.Windows.Forms.Button; $cancel.Text = 'Cancel'; $cancel.Location = New-Object System.Drawing.Point(374, 326); $cancel.Size = New-Object System.Drawing.Size(90, 28)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    $dlg.Controls.AddRange(@($l1, $txt, $naming, $err, $info, $chk, $note, $ok, $cancel))
    $tip = New-Object System.Windows.Forms.ToolTip
    $tip.SetToolTip($txt, 'The new folder name. A noun-verb name such as page-distill is suggested, not required.')
    $tip.SetToolTip($chk, 'Claude cannot know the folder was renamed. When ticked, this message is sent as the first message of the next Claude session you launch for the project (once), so it can fix references to the old name or path.')
    $tip.SetToolTip($note, 'Edit the message if you like. It is sent to Claude as your first message on the next launch of this project.')
    $tip.SetToolTip($ok, 'Rename the folder and carry its Claude history, preset and window position along.')
    $tip.SetToolTip($cancel, 'Close without changing anything.')
    $st = @{ Edited = $false; Setting = $false }
    $mk = { param($n) "I just renamed this project's folder from '$old' to '$n'. Please update any artifacts that refer to the old name or path (docs, configs, scripts, memory) as appropriate." }.GetNewClosure()
    $upd = {
        $changed = ($txt.Text.Trim() -cne $old); $e = $null
        if ($changed) { $e = Test-ProjectName $txt.Text $parent $old }
        $err.Text = [string]$e; $ok.Enabled = ($changed -and -not $e)
        if (-not $st.Edited) { $st.Setting = $true; $note.Text = & $mk $txt.Text.Trim(); $st.Setting = $false }   # follows the name until you edit it yourself
    }.GetNewClosure()
    $txt.Add_TextChanged($upd)
    $note.Add_TextChanged({ if (-not $st.Setting) { $st.Edited = $true } }.GetNewClosure())
    $chk.Add_CheckedChanged({ $note.Enabled = $chk.Checked }.GetNewClosure())
    & $upd
    $dlg.Add_Shown({ $txt.Focus(); $txt.SelectAll() }.GetNewClosure())
    $res = $dlg.ShowDialog($OwnerForm); $out = $null
    if ($res -eq [System.Windows.Forms.DialogResult]::OK) {
        $n = ''; if ($chk.Checked) { $n = (($note.Text -replace '[\r\n]+', ' ') -replace '"', "'").Trim() }
        $out = [pscustomobject]@{ Name = $txt.Text.Trim(); Note = $n }
    }
    $dlg.Dispose(); $out
}

# Creates the folder (+ optional git init / README) under the projects root and remembers it as the selection. { Ok, Message, Path }.
function Invoke-NewProject($Opts) {
    $r = [pscustomobject]@{ Ok = $false; Message = ''; Path = '' }
    $parent = [string]$Opts.Parent; if (-not $parent) { $parent = [string]@($Roots)[0] }
    $err = Test-ProjectName $Opts.Name $parent
    if ($err) { $r.Message = $err; return $r }
    $path = Join-Path $parent $Opts.Name; $r.Path = $path
    if ($DryRun) { $r.Message = "Dry run: would create $path" + $(if ($Opts.GitInit) { ', run git init' } else { '' }) + $(if ($Opts.Readme) { ' and add README.md' } else { '' }) + '.'; return $r }
    try { New-Item -ItemType Directory -Path $path -ErrorAction Stop | Out-Null } catch { $r.Message = "Could not create the folder: $_"; return $r }
    $notes = @("Created $path")
    if ($Opts.GitInit) { $g = Invoke-GitOp 'init' $path $null; if ($g.Ok) { $notes += 'initialized git' } else { $notes += "git init failed ($($g.Message))" } }
    if ($Opts.Readme) { try { Set-Content -LiteralPath (Join-Path $path 'README.md') -Value "# $($Opts.Name)`r`n" -Encoding UTF8; $notes += 'added README.md' } catch { $notes += "README failed: $_" } }
    $state.last = @($path); Save-State           # pre-checked in the list after the picker restarts
    if ($Opts.OpenIde) { $notes += (Invoke-OpenIde @($path)) }
    $r.Ok = $true; $r.Message = ($notes -join '; ') + '.'
    $r
}

# Renames a project folder and moves what refers to it by name or path. { Ok, Message }.
function Invoke-RenameProject($Row, [string]$NewName, [string]$Note = '') {
    $r = [pscustomobject]@{ Ok = $false; Message = '' }
    $old = [string]$Row.Path; $parent = Split-Path -Parent $old; $new = Join-Path $parent $NewName
    $err = Test-ProjectName $NewName $parent $Row.Name
    if ($err) { $r.Message = $err; return $r }
    if (@(Get-RunningNames) -contains $Row.Name) { $r.Message = "$($Row.Name) has terminal tabs open. Close them first (Windows cannot rename a folder that is in use), then rename."; return $r }
    if ($DryRun) { $r.Message = "Dry run: would rename $old to $new and move its Claude history, preset, saved window position and selection."; return $r }
    try { Rename-Item -LiteralPath $old -NewName $NewName -ErrorAction Stop }
    catch { $r.Message = "Could not rename the folder. Is a terminal, IDE or other program using it? $_"; return $r }
    $notes = @("Renamed $($Row.Name) to $NewName")
    $enc = { param($p) $p -replace '[^A-Za-z0-9]', '-' }
    $oldH = Join-Path $env:USERPROFILE ".claude\projects\$(& $enc $old)"; $newH = Join-Path $env:USERPROFILE ".claude\projects\$(& $enc $new)"
    if ((Test-Path -LiteralPath $oldH) -and -not (Test-Path -LiteralPath $newH)) {
        try { Move-Item -LiteralPath $oldH -Destination $newH -ErrorAction Stop; $notes += 'moved its Claude history'; try { Move-CostLedgerDir (& $enc $old) (& $enc $new) } catch { } } catch { $notes += "could not move its Claude history ($_)" }
    }
    $pf = Join-Path $ConfigDir 'presets.json'
    if (Test-Path -LiteralPath $pf) {
        try {
            $arr = @(); foreach ($x in (Get-Content -LiteralPath $pf -Raw | ConvertFrom-Json)) { $arr += $x }; $hit = $false
            foreach ($e in $arr) { if ([string]$e.name -ieq $Row.Name) { $e.name = $NewName; $hit = $true } }
            if ($hit) { ConvertTo-Json -InputObject $arr -Depth 8 | Set-Content -LiteralPath $pf -Encoding UTF8; $notes += 'updated presets.json' }
        } catch { $notes += "could not update presets.json ($_)" }
    }
    $lf = Join-Path $ConfigDir 'layouts.json'
    if (Test-Path -LiteralPath $lf) {
        try {
            $all = Get-Content -LiteralPath $lf -Raw | ConvertFrom-Json; $hit = $false
            foreach ($sig in $all.PSObject.Properties) {
                $pp = $sig.Value.PSObject.Properties[$Row.Name]
                if ($pp) { $val = $pp.Value; $sig.Value.PSObject.Properties.Remove($Row.Name); $sig.Value | Add-Member -NotePropertyName $NewName -NotePropertyValue $val; $hit = $true }
            }
            if ($hit) { $all | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $lf -Encoding UTF8; $notes += 'moved its saved window position' }
        } catch { $notes += "could not update layouts.json ($_)" }
    }
    $state.last = @($state.last | ForEach-Object { if ($_ -ieq $old) { $new } else { $_ } })
    if ($state.pending.ContainsKey($old)) { $state.pending.Remove($old) }
    if ($Note.Trim()) { $state.pending[$new] = $Note.Trim(); $notes += 'Claude will be told about the rename on its next launch' }
    Save-State
    $r.Ok = $true; $r.Message = ($notes -join '; ') + '.'
    $r
}

# Picker side: dialog, confirmation, action. Returns { Ok; Message } (Ok = the list needs a reload).
function Invoke-PickerNewProject($OwnerForm) {
    $opts = Show-NewProjectDialog $OwnerForm @($Roots | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
    if (-not $opts) { return [pscustomobject]@{ Ok = $false; Message = 'Cancelled.' } }
    Invoke-NewProject $opts
}
function Invoke-PickerRenameProject($Row, $OwnerForm) {
    $dlgRes = Show-RenameDialog $OwnerForm $Row
    if (-not $dlgRes) { return [pscustomobject]@{ Ok = $false; Message = 'Cancelled.' } }
    $new = $dlgRes.Name
    $q = "Rename this project?`n`n$($Row.Path)`n  to`n$(Join-Path (Split-Path -Parent $Row.Path) $new)`n`nIts Claude history, preset, saved window position and selection move with it."
    if ([System.Windows.Forms.MessageBox]::Show($OwnerForm, $q, 'Rename project', 'YesNo', 'Question') -ne [System.Windows.Forms.DialogResult]::Yes) { return [pscustomobject]@{ Ok = $false; Message = 'Cancelled.' } }
    Invoke-RenameProject $Row $new $dlgRes.Note
}

# ---------------------------------------------------------------- per-project launch options (presets.json)
# Writes one project's entry in presets.json (creating it if needed), keeping keys it does not manage (extraTabs, launch, ...).
# $Set maps key -> value; $null, an empty string or an empty array removes the key. An entry left with only its name is dropped.
function Save-ProjectPreset([string]$Name, [hashtable]$Set) {
    $arr = @()
    if (Test-Path -LiteralPath $presetFile) { foreach ($x in (Get-Content -LiteralPath $presetFile -Raw | ConvertFrom-Json)) { if ($x) { $arr += $x } } }
    $entry = $arr | Where-Object { [string]$_.name -ieq $Name } | Select-Object -First 1
    if (-not $entry) { $entry = [pscustomobject]@{ name = $Name }; $arr += $entry }
    foreach ($k in $Set.Keys) {
        $v = $Set[$k]
        $empty = ($null -eq $v) -or (($v -is [string]) -and -not $v.Trim()) -or (($v -is [array]) -and $v.Count -eq 0)
        if ($empty) { if ($entry.PSObject.Properties[$k]) { $entry.PSObject.Properties.Remove($k) } }
        elseif ($entry.PSObject.Properties[$k]) { $entry.$k = $v }
        else { $entry | Add-Member -NotePropertyName $k -NotePropertyValue $v }
    }
    $arr = @($arr | Where-Object { @($_.PSObject.Properties).Count -gt 1 -or [string]$_.name -ine $Name })
    if (-not $DryRun) {
        New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
        ConvertTo-Json -InputObject @($arr) -Depth 8 | Set-Content -LiteralPath $presetFile -Encoding UTF8
    }
    $script:presets = @($arr)    # the next launch in this session sees it too
}

# Dialog: the per-project launch options. Returns $null or { ClaudeArgs, Shell, Diff, Startup, Urls, Color } (Shell/Diff: $null = default).
function Show-LaunchOptionsDialog($OwnerForm, $Row) {
    $cur = Get-Preset $Row.Name
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Launch options for $($Row.Name)"; $dlg.ClientSize = New-Object System.Drawing.Size(540, 420)
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.StartPosition = 'CenterParent'
    $mkLabel = { param($t, $y) $l = New-Object System.Windows.Forms.Label; $l.Text = $t; $l.AutoSize = $true; $l.Location = New-Object System.Drawing.Point(12, ($y + 4)); $l }
    $txtArgs = New-Object System.Windows.Forms.TextBox; $txtArgs.Location = New-Object System.Drawing.Point(160, 12); $txtArgs.Width = 370; $txtArgs.Text = [string]$cur.claudeArgs
    $cboShell = New-Object System.Windows.Forms.ComboBox; $cboShell.DropDownStyle = 'DropDownList'; $cboShell.Location = New-Object System.Drawing.Point(160, 44); $cboShell.Width = 210
    $cboDiff = New-Object System.Windows.Forms.ComboBox; $cboDiff.DropDownStyle = 'DropDownList'; $cboDiff.Location = New-Object System.Drawing.Point(160, 76); $cboDiff.Width = 210
    foreach ($c in @($cboShell, $cboDiff)) { foreach ($i in 'Default (from config.json)', 'On', 'Off') { [void]$c.Items.Add($i) } }
    $cboShell.SelectedIndex = $(if ($null -eq $cur.shell) { 0 } elseif ([bool]$cur.shell) { 1 } else { 2 })
    $cboDiff.SelectedIndex = $(if ($null -eq $cur.diff) { 0 } elseif ([bool]$cur.diff) { 1 } else { 2 })
    $txtStart = New-Object System.Windows.Forms.TextBox; $txtStart.Location = New-Object System.Drawing.Point(160, 108); $txtStart.Width = 370; $txtStart.Text = [string]$cur.startupCommand
    $txtUrls = New-Object System.Windows.Forms.TextBox; $txtUrls.Multiline = $true; $txtUrls.ScrollBars = 'Vertical'; $txtUrls.WordWrap = $false
    $txtUrls.Location = New-Object System.Drawing.Point(160, 140); $txtUrls.Size = New-Object System.Drawing.Size(370, 96); $txtUrls.Text = (@($cur.urls | Where-Object { $_ }) -join "`r`n")
    $swatch = New-Object System.Windows.Forms.Panel; $swatch.Location = New-Object System.Drawing.Point(160, 248); $swatch.Size = New-Object System.Drawing.Size(40, 24); $swatch.BorderStyle = 'FixedSingle'
    $st = @{ Color = [string]$cur.tabColor }
    $paint = { try { if ($st.Color) { $swatch.BackColor = [System.Drawing.ColorTranslator]::FromHtml($st.Color) } else { $swatch.BackColor = [System.Drawing.SystemColors.Control] } } catch { $swatch.BackColor = [System.Drawing.SystemColors.Control] } }.GetNewClosure()
    $btnColor = New-Object System.Windows.Forms.Button; $btnColor.Text = 'Choose...'; $btnColor.Location = New-Object System.Drawing.Point(208, 246); $btnColor.Size = New-Object System.Drawing.Size(90, 28)
    $btnClear = New-Object System.Windows.Forms.Button; $btnClear.Text = 'Automatic'; $btnClear.Location = New-Object System.Drawing.Point(304, 246); $btnClear.Size = New-Object System.Drawing.Size(90, 28)
    $adv = New-Object System.Windows.Forms.Label; $adv.Location = New-Object System.Drawing.Point(12, 292); $adv.Size = New-Object System.Drawing.Size(516, 52)
    $adv.Text = "Extra tabs in other folders and extra applications for this project are edited in presets.json (other settings in this project's entry are kept as they are)."
    $btnFile = New-Object System.Windows.Forms.Button; $btnFile.Text = 'Open presets.json'; $btnFile.Location = New-Object System.Drawing.Point(12, 346); $btnFile.Size = New-Object System.Drawing.Size(130, 28)
    $err = New-Object System.Windows.Forms.Label; $err.ForeColor = [System.Drawing.Color]::Firebrick; $err.Location = New-Object System.Drawing.Point(12, 350); $err.Size = New-Object System.Drawing.Size(516, 20); $err.Visible = $false
    $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'Save'; $ok.Location = New-Object System.Drawing.Point(344, 382); $ok.Size = New-Object System.Drawing.Size(90, 28)
    $cancel = New-Object System.Windows.Forms.Button; $cancel.Text = 'Cancel'; $cancel.Location = New-Object System.Drawing.Point(440, 382); $cancel.Size = New-Object System.Drawing.Size(90, 28)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.AcceptButton = $null; $dlg.CancelButton = $cancel
    $dlg.Controls.AddRange(@((& $mkLabel 'Claude arguments:' 12), $txtArgs, (& $mkLabel 'Shell tab:' 44), $cboShell, (& $mkLabel 'Git status summary:' 76), $cboDiff, (& $mkLabel 'Shell startup command:' 108), $txtStart,
        (& $mkLabel 'Open these URLs:' 140), $txtUrls, (& $mkLabel 'Tab color:' 248), $swatch, $btnColor, $btnClear, $adv, $btnFile, $err, $ok, $cancel))
    $tip = New-Object System.Windows.Forms.ToolTip
    $tip.SetToolTip($txtArgs, 'Extra arguments for claude in this project only, e.g. --model opus or --permission-mode plan (no double quotes). Replaces claudeArgs from config.json.')
    $tip.SetToolTip($cboShell, 'Whether this project gets a shell tab next to its Claude tab.')
    $tip.SetToolTip($cboDiff, 'Whether the shell tab starts by showing git status and a diff summary (ignored when a startup command is set).')
    $tip.SetToolTip($txtStart, 'Runs in the shell tab when the project launches, e.g. npm run dev or docker compose up (no double quotes). Replaces the git summary.')
    $tip.SetToolTip($txtUrls, 'One address per line (http or https). Opened in your default browser each time the project is launched, for example a dev server, tracker or dashboard.')
    $tip.SetToolTip($btnColor, 'Pick a fixed tab color for this project.')
    $tip.SetToolTip($btnClear, 'Go back to the automatic color (derived from the project name).')
    $tip.SetToolTip($btnFile, 'Open presets.json in your editor for extra tabs and extra applications.')
    $tip.SetToolTip($ok, 'Save these options to presets.json. They apply the next time the project is launched.')
    $tip.SetToolTip($cancel, 'Close without changing anything.')
    & $paint
    $btnColor.Add_Click({
        $cd = New-Object System.Windows.Forms.ColorDialog; $cd.FullOpen = $true
        try { if ($st.Color) { $cd.Color = [System.Drawing.ColorTranslator]::FromHtml($st.Color) } } catch { }
        if ($cd.ShowDialog($dlg) -eq [System.Windows.Forms.DialogResult]::OK) { $st.Color = ('#{0:X2}{1:X2}{2:X2}' -f $cd.Color.R, $cd.Color.G, $cd.Color.B); & $paint }
    }.GetNewClosure())
    $btnClear.Add_Click({ $st.Color = ''; & $paint }.GetNewClosure())
    $btnFile.Add_Click({
        try {
            New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
            if (-not (Test-Path -LiteralPath $presetFile)) { Set-Content -LiteralPath $presetFile -Value '[]' -Encoding UTF8 }
            Start-Process -FilePath $presetFile
        } catch { [void][System.Windows.Forms.MessageBox]::Show($dlg, "Could not open presets.json: $_", 'Launch options', 'OK', 'Warning') }
    }.GetNewClosure())
    $ok.Add_Click({
        $problem = $null
        if ($txtArgs.Text.Contains('"')) { $problem = 'Claude arguments cannot contain double quotes.' }
        elseif ($txtStart.Text.Contains('"')) { $problem = 'The startup command cannot contain double quotes (use single quotes).' }
        else { foreach ($u in @($txtUrls.Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ })) { if ($u -notmatch '^https?://\S+$') { $problem = "Not an http(s) address: $u"; break } } }
        if ($problem) { [void][System.Windows.Forms.MessageBox]::Show($dlg, $problem, 'Launch options', 'OK', 'Warning'); return }
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK; $dlg.Close()
    }.GetNewClosure())
    $res = $dlg.ShowDialog($OwnerForm); $out = $null
    if ($res -eq [System.Windows.Forms.DialogResult]::OK) {
        $tri = { param($c) switch ($c.SelectedIndex) { 1 { $true } 2 { $false } default { $null } } }
        $out = [pscustomobject]@{
            ClaudeArgs = $txtArgs.Text.Trim(); Shell = (& $tri $cboShell); Diff = (& $tri $cboDiff); Startup = $txtStart.Text.Trim()
            Urls = @($txtUrls.Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ }); Color = $st.Color
        }
    }
    $dlg.Dispose(); $out
}

function Invoke-PickerLaunchOptions($Row, $OwnerForm) {
    $o = Show-LaunchOptionsDialog $OwnerForm $Row
    if (-not $o) { return [pscustomobject]@{ Ok = $false; Message = 'Cancelled.' } }
    try {
        Save-ProjectPreset $Row.Name @{ claudeArgs = $o.ClaudeArgs; shell = $o.Shell; diff = $o.Diff; startupCommand = $o.Startup; urls = @($o.Urls); tabColor = $o.Color }
        $Row.HasPreset = [bool](Get-Preset $Row.Name)
        [pscustomobject]@{ Ok = $true; Message = "Saved launch options for $($Row.Name). They apply the next time it is launched." }
    } catch { [pscustomobject]@{ Ok = $false; Message = "Could not save launch options: $_" } }
}

# ---------------------------------------------------------------- first run: where are the projects?
# Project folders your tools already know about: Claude Code's list (~\.claude.json "projects", real paths) and the folders
# VS Code (and its forks) have opened. Read-only, local files only; nothing is sent anywhere.
function Get-ToolProjectPaths {
    $found = @()
    try {
        Add-Type -AssemblyName System.Web.Extensions
        $js = New-Object System.Web.Script.Serialization.JavaScriptSerializer; $js.MaxJsonLength = [int]::MaxValue
    } catch { return @() }
    $cj = Join-Path $env:USERPROFILE '.claude.json'
    if (Test-Path -LiteralPath $cj) {
        try {
            $d = $js.DeserializeObject((Get-Content -LiteralPath $cj -Raw))
            if ($d.ContainsKey('projects')) { foreach ($k in $d['projects'].Keys) { $found += [pscustomobject]@{ Path = ([string]$k -replace '/', '\'); Source = 'Claude Code' } } }
        } catch { }
    }
    foreach ($app in 'Code', 'Code - Insiders', 'VSCodium', 'Cursor', 'Windsurf') {
        $f = Join-Path $env:APPDATA "$app\User\globalStorage\storage.json"
        if (-not (Test-Path -LiteralPath $f)) { continue }
        try {
            $d = $js.DeserializeObject((Get-Content -LiteralPath $f -Raw))
            $uris = @()
            if ($d.ContainsKey('profileAssociations') -and $d['profileAssociations'].ContainsKey('workspaces')) { $uris += @($d['profileAssociations']['workspaces'].Keys) }
            if ($d.ContainsKey('backupWorkspaces') -and $d['backupWorkspaces'].ContainsKey('folders')) { foreach ($e in $d['backupWorkspaces']['folders']) { if ($e.ContainsKey('folderUri')) { $uris += [string]$e['folderUri'] } } }
            if ($d.ContainsKey('windowsState')) {
                $ws = $d['windowsState']
                if ($ws.ContainsKey('lastActiveWindow') -and $ws['lastActiveWindow'].ContainsKey('folder')) { $uris += [string]$ws['lastActiveWindow']['folder'] }
                if ($ws.ContainsKey('openedWindows')) { foreach ($w in $ws['openedWindows']) { if ($w.ContainsKey('folder')) { $uris += [string]$w['folder'] } } }
            }
            foreach ($u in $uris) {
                if ([string]$u -match '^file:///(.+)$') { $found += [pscustomobject]@{ Path = ([uri]::UnescapeDataString($Matches[1]) -replace '/', '\'); Source = $(if ($app -eq 'Code') { 'VS Code' } else { $app }) } }
            }
        } catch { }
    }
    $found
}

# Folders that look like a place people keep projects: parents of projects your tools opened, plus common names,
# ranked by how many projects/repositories they hold.
function Find-ProjectRootCandidates {
    $h = $env:USERPROFILE
    $byPath = @{}
    function Add-Cand($path) { if (-not $byPath.ContainsKey($path)) { $byPath[$path] = [pscustomobject]@{ Path = $path; Folders = 0; Repos = 0; Opened = 0; Sources = @() } }; $byPath[$path] }
    # 1. Parents of the projects Claude Code / VS Code know about.
    $seen = @{}
    foreach ($t in @(Get-ToolProjectPaths)) {
        $p = ([string]$t.Path).TrimEnd('\')
        if ($p.Length -le 3 -or $p -ieq $h -or $h -like "$p\*") { continue }                 # drive root, home folder, or a parent of home
        if (-not (Test-Path -LiteralPath $p -PathType Container)) { continue }
        $parent = Split-Path -Parent $p
        if (-not $parent -or $parent.Length -le 3 -or $parent -ieq $h -or $h -like "$parent\*") { continue }
        if ($parent -like "$h\AppData*" -or $parent -like "$h\.*") { continue }                             # tool internals, not projects
        $c = Add-Cand $parent
        if (-not $seen.ContainsKey($p.ToLowerInvariant())) { $seen[$p.ToLowerInvariant()] = $true; $c.Opened++ }
        if ($c.Sources -notcontains $t.Source) { $c.Sources += $t.Source }
    }
    # 2. Folders with common names.
    $names = 'code', 'repos', 'source\repos', 'src', 'dev', 'projects', 'git', 'workspace', 'Documents\GitHub', 'Documents\Projects', 'Documents\Code', 'GitHub'
    $paths = @(); foreach ($n in $names) { $paths += (Join-Path $h $n) }
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        if ($d.DriveType -eq 'Fixed' -and $d.IsReady) { foreach ($n in 'code', 'repos', 'src', 'dev', 'projects', 'git') { $paths += (Join-Path $d.Name $n) } }
    }
    foreach ($p in ($paths | Select-Object -Unique)) { if (Test-Path -LiteralPath $p -PathType Container) { [void](Add-Cand $p) } }
    # 3. Count what is inside each candidate; drop the empty ones.
    $out = @()
    foreach ($c in $byPath.Values) {
        $subs = @(Get-ChildItem -LiteralPath $c.Path -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '.*' })
        if (-not $subs.Count) { continue }
        if ($c.Opened -eq 1 -and $subs.Count -lt 3) { continue }                                          # a lone one-off, not a projects folder
        $c.Folders = $subs.Count
        $c.Repos = @($subs | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.git') }).Count
        $out += $c
    }
    @($out | Sort-Object @{ Expression = 'Opened'; Descending = $true }, @{ Expression = 'Repos'; Descending = $true }, @{ Expression = 'Folders'; Descending = $true } | Select-Object -First 8)
}

# Writes one key into the user's config.json (creating it from the example file if needed). No-op under -DryRun.
function Set-ConfigValue([string]$Key, $Value) {
    if ($DryRun) { return }
    try {
        New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
        $f = Join-Path $ConfigDir 'config.json'
        $ex = Join-Path $PSScriptRoot 'config.example.json'
        if (-not (Test-Path -LiteralPath $f) -and (Test-Path -LiteralPath $ex)) { Copy-Item -LiteralPath $ex -Destination $f }
        $o = $null
        if (Test-Path -LiteralPath $f) { $o = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json }
        if (-not $o) { $o = [pscustomobject]@{} }
        if ($o.PSObject.Properties[$Key]) { $o.$Key = $Value } else { $o | Add-Member -NotePropertyName $Key -NotePropertyValue $Value }
        ($o | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $f -Encoding UTF8
    } catch { Write-Warning "Could not save $Key to config.json: $_" }
}

# Writes the chosen project folders to config.json: "roots" (the list) and "root" (the first, so older versions still work).
function Set-ProjectRoots([string[]]$Paths) {
    $Paths = @($Paths | Where-Object { $_ })
    if (-not $Paths.Count) { return }
    Set-ConfigValue 'root' $Paths[0]
    Set-ConfigValue 'roots' $Paths
}

# "Where are your projects?" dialog. Returns the checked folders (an array; empty on Cancel). Several folders can be used at once.
# Nothing is scanned unless the user asks: $Scan is a scriptblock returning candidate folders, run only when "Look for likely folders"
# is clicked. $Current are the folders already in use (listed and checked first).
function Show-RootDialog([scriptblock]$Scan, [string]$Message, [string[]]$Current = @()) {
    Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Workspace Wrangler: where are your projects?'; $dlg.ClientSize = New-Object System.Drawing.Size(560, 392)
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.StartPosition = 'CenterScreen'
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Location = New-Object System.Drawing.Point(12, 10); $lbl.Size = New-Object System.Drawing.Size(470, 64)
    $logo = Get-ArtImage 'app.png'
    if ($logo) { $pm = New-Object System.Windows.Forms.PictureBox; $pm.Image = $logo; $pm.SizeMode = 'Zoom'; $pm.Location = New-Object System.Drawing.Point(490, 8); $pm.Size = New-Object System.Drawing.Size(58, 58); $dlg.Controls.Add($pm) }
    $lbl.Text = "$Message`n`nWorkspace Wrangler lists the subfolders of each folder you check as your projects. Check one or more folders."
    $how = New-Object System.Windows.Forms.Label
    $how.Location = New-Object System.Drawing.Point(12, 80); $how.Size = New-Object System.Drawing.Size(536, 112)
    $how.ForeColor = [System.Drawing.SystemColors]::GrayText
    $how.Text = "Browse to folders yourself, or let Workspace Wrangler suggest some. Suggesting is optional and only happens if you click the button. It reads, on this computer only:`n  - the project list in Claude Code's settings file (~\.claude.json)`n  - the recent-folders list kept by VS Code (also Insiders, VSCodium, Cursor, Windsurf)`n  - whether folders named code, repos, src, dev, projects or git exist`nIt only looks at folder names; nothing is changed, saved or sent anywhere."
    $lst = New-Object System.Windows.Forms.CheckedListBox
    $lst.CheckOnClick = $true; $lst.HorizontalScrollbar = $true
    $lst.Location = New-Object System.Drawing.Point(12, 200); $lst.Size = New-Object System.Drawing.Size(536, 110)
    $status = New-Object System.Windows.Forms.Label
    $status.Location = New-Object System.Drawing.Point(12, 316); $status.Size = New-Object System.Drawing.Size(536, 18)
    $paths = New-Object System.Collections.ArrayList
    $look = New-Object System.Windows.Forms.Button; $look.Text = 'Look for likely folders'; $look.Location = New-Object System.Drawing.Point(12, 350); $look.Size = New-Object System.Drawing.Size(150, 28)
    $browse = New-Object System.Windows.Forms.Button; $browse.Text = 'Browse...'; $browse.Location = New-Object System.Drawing.Point(172, 350); $browse.Size = New-Object System.Drawing.Size(100, 28)
    $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'Use checked folders'; $ok.Location = New-Object System.Drawing.Point(298, 350); $ok.Size = New-Object System.Drawing.Size(150, 28)
    $cancel = New-Object System.Windows.Forms.Button; $cancel.Text = 'Cancel'; $cancel.Location = New-Object System.Drawing.Point(458, 350); $cancel.Size = New-Object System.Drawing.Size(90, 28)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $ok.Enabled = $false
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    $dlg.Controls.AddRange(@($lbl, $how, $lst, $status, $look, $browse, $ok, $cancel))
    $tip = New-Object System.Windows.Forms.ToolTip
    $tip.SetToolTip($look, 'Optional. Suggest folders based on the project lists of Claude Code and VS Code and on common folder names. Reads folder names only, on this computer.')
    $tip.SetToolTip($lst, 'Check every folder whose subfolders are your projects. Folders already in use are listed first; uncheck one to stop using it.')
    $tip.SetToolTip($browse, 'Add any folder. Each of its subfolders becomes a project in the list.')
    $tip.SetToolTip($ok, 'Remember the checked folders (saved as "roots" in config.json) and open the picker.')
    $tip.SetToolTip($cancel, 'Close without choosing. You will be asked again next time.')
    # Add an entry (skipping duplicates); returns its index.
    $addItem = {
        param($path, $text, $checked)
        $idx = -1
        for ($k = 0; $k -lt $paths.Count; $k++) { if ([string]$paths[$k] -ieq $path) { $idx = $k; break } }
        if ($idx -lt 0) { [void]$paths.Add($path); $idx = $lst.Items.Add($text) }
        if ($checked) { $lst.SetItemChecked($idx, $true) }
        $idx
    }.GetNewClosure()
    foreach ($c in @($Current)) { if ($c) { [void](& $addItem $c $c $true) } }
    $refreshOk = { $ok.Enabled = ($lst.CheckedItems.Count -gt 0) }.GetNewClosure()
    $lst.Add_ItemCheck({ param($s, $e) $n = $lst.CheckedItems.Count; if ($e.NewValue -eq 'Checked') { $n++ } else { $n-- }; $ok.Enabled = ($n -gt 0) }.GetNewClosure())
    & $refreshOk
    $look.Add_Click({
        $look.Enabled = $false; $status.Text = 'Looking...'; $dlg.Update()
        $cands = @(); try { $cands = @(& $Scan) } catch { }
        $first = $true
        foreach ($c in $cands) {
            $desc = "$($c.Folders) folders"; if ($c.Repos) { $desc = "$($c.Repos) git repositories, $($c.Folders) folders" }
            if ($c.Opened) { $desc = "$($c.Opened) opened in $(@($c.Sources) -join ' / '); $desc" }
            [void](& $addItem $c.Path "$($c.Path)   ($desc)" ($first -and -not @($Current).Count)); $first = $false
        }
        if ($cands.Count) { $status.Text = 'Check the folders to use, or use Browse. (Each suggestion says where it came from.)' }
        else { $status.Text = 'No likely folders found. Use Browse to pick yours.' }
    }.GetNewClosure())
    $browse.Add_Click({
        $fb = New-Object System.Windows.Forms.FolderBrowserDialog
        $fb.Description = 'Choose a folder that contains your project folders'
        if ($fb.ShowDialog($dlg) -eq [System.Windows.Forms.DialogResult]::OK) { [void](& $addItem $fb.SelectedPath $fb.SelectedPath $true) }
    }.GetNewClosure())
    $res = $dlg.ShowDialog()
    $out = @()
    if ($res -eq [System.Windows.Forms.DialogResult]::OK) { foreach ($idx in $lst.CheckedIndices) { $out += [string]$paths[$idx] } }
    $dlg.Dispose()
    if ($logo) { $logo.Dispose() }
    $out
}

# ---------------------------------------------------------------- discover
# First run (or moved/empty project folders): ask where the projects are instead of failing silently. Picker only; the command-line switches never prompt.
if (-not $PSBoundParameters.ContainsKey('Root') -and $Picker -eq 'Forms' -and -not ($List -or $All -or $Cascade -or $Focus -or $CheckUpdate -or $Project.Count)) {
    $why = ''
    if ($firstRun) { $why = 'Welcome! Before the first launch, tell Workspace Wrangler where your projects live.' }
    $okRoots = @($Roots | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
    $hasFolders = ($ExtraProjects | Where-Object { Test-Path -LiteralPath $_ -PathType Container }).Count -gt 0
    foreach ($r in $okRoots) { if (@(Get-ChildItem -LiteralPath $r -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '.*' }).Count) { $hasFolders = $true; break } }
    if (-not $Roots.Count) { $why = 'No projects folder is set yet.' }
    elseif (-not $okRoots.Count) { $why = "The projects folder$(if ($Roots.Count -gt 1) { 's' }) $(($Roots | ForEach-Object { '"' + $_ + '"' }) -join ', ') do$(if ($Roots.Count -eq 1) { 'es' }) not exist on this computer." }
    elseif (-not $hasFolders) { $why = 'The projects folders have no folders in them.' }
    if ($why) {
        $picks = @(Show-RootDialog { @(Find-ProjectRootCandidates) } $why $okRoots)
        if (-not $picks.Count) { exit 0 }
        $Roots = $picks; Set-ProjectRoots $picks
    }
}
$Roots = @($Roots | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
if (-not $Roots.Count -and -not @($ExtraProjects | Where-Object { Test-Path -LiteralPath $_ -PathType Container }).Count) { Write-Warning "No projects folder found. Set `"root`" or `"roots`" in config.json (or pass -Root <folder>)."; exit 1 }

if ($Picker -eq 'Forms' -and -not $List -and -not $All -and $Project.Count -eq 0 -and -not $DryRun) { Show-Splash }
# Every subfolder of every project folder, plus the individual "projects" folders, de-duplicated by path. When two projects share a
# folder name, later ones are labelled "name (parentfolder)" so tab titles, presets and saved layouts (all keyed by name) stay unique.
function Get-ProjectDirs {
    $found = @()
    $seenPaths = @{}; $seenNames = @{}
    $candidates = @()
    foreach ($r in $Roots) { foreach ($d in @(Get-ChildItem -LiteralPath $r -Directory -Force -ErrorAction SilentlyContinue)) { $candidates += $d.FullName } }
    foreach ($p in $ExtraProjects) { if (Test-Path -LiteralPath $p -PathType Container) { $candidates += (Resolve-Path -LiteralPath $p).ProviderPath } }
    foreach ($c in $candidates) {
        $full = $c.TrimEnd('\')
        $leaf = Split-Path -Leaf $full
        if (-not $leaf -or $leaf -like '.*' -or $Ignore -contains $leaf) { continue }
        $key = $full.ToLowerInvariant()
        if ($seenPaths.ContainsKey($key)) { continue }
        $seenPaths[$key] = $true
        $name = $leaf
        if ($seenNames.ContainsKey($name.ToLowerInvariant())) {
            $name = "$leaf ($(Split-Path -Leaf (Split-Path -Parent $full)))"
            $n = 2; while ($seenNames.ContainsKey($name.ToLowerInvariant())) { $name = "$leaf ($(Split-Path -Leaf (Split-Path -Parent $full)) $n)"; $n++ }
        }
        $seenNames[$name.ToLowerInvariant()] = $true
        $found += [pscustomobject]@{ Name = $name; FullName = $full }
    }
    $found
}
$dirs = @(Get-ProjectDirs)

function New-Row($d, [bool]$Scan, [bool]$Git, $Facts) {
    $la = $null; $gi = $null
    if ($Facts -and $Facts.ContainsKey($d.FullName)) { $la = $Facts[$d.FullName].La; $gi = $Facts[$d.FullName].Gi }   # computed in parallel
    else {
        if ($Scan) { $la = Get-LastActive $d.FullName }
        if ($Git) { $gi = Get-GitInfo $d.FullName }
    }
    $hasGit = Test-Path -LiteralPath (Join-Path $d.FullName '.git')
    $row = [pscustomobject]@{
        Name = $d.Name; Path = $d.FullName
        LastActiveDt = $la
        Relative   = $(if ($la) { Format-Relative $la } else { '' })
        LastActive = $(if ($la) { $la.ToString('yyyy-MM-dd HH:mm') } else { '' })
        IsGit = $hasGit
        RemoteUrl = $(if ($gi) { $gi.RemoteUrl } else { $null })
        Branch = $(if ($gi) { $gi.Branch } else { $null })
        Dirty  = $(if ($gi) { $gi.Dirty } else { $null })
        HasHistory = (Test-ClaudeHistory $d.FullName)
        HasPreset = [bool](Get-Preset $d.Name)
        CostUsd = $null; CostText = ''; CostTip = ''
    }
    Set-RowCost $row
    $row
}

# Fast path: -Project names given -> no scan, no git info needed.
if ($Project.Count -gt 0 -and -not $List) {
    $selected = @()
    foreach ($want in $Project) {
        $m = $dirs | Where-Object { $_.Name -ieq $want -or $_.FullName -ieq $want } | Select-Object -First 1
        if (-not $m -and (Test-Path -LiteralPath $want -PathType Container)) { $m = Get-Item -LiteralPath $want }
        if ($m) { $selected += (New-Row $m $false $false) } else { Write-Warning "Project not found: $want" }
    }
    if ($selected.Count -eq 0) { exit 1 }
    Invoke-Launch $selected ([bool]$Fresh) $false
    return
}

# Project cost is opt-in (config showCost). The ledger and prices are loaded once here; rows read from them.
$script:CostOn = ($cfg.showCost -eq $true)
$script:CostLedger = $null; $script:Prices = $null
if ($script:CostOn) { $script:CostLedger = Read-CostLedger; $script:Prices = Get-ModelPrices }
$needGit = [bool]$cfg.gitInfo -and ($List -or ($Picker -eq 'Forms' -and -not $All))
# -List has no window to refresh in the background, so scan session files for cost right here (picker starts use the ledger, then refresh in the background).
if ($script:CostOn -and $List) {
    $known = @{}; foreach ($e in $script:CostLedger.files.GetEnumerator()) { $known[$e.Key] = [string]$e.Value.sig }
    foreach ($d in $dirs) {
        $cd = Join-Path (Join-Path $env:USERPROFILE '.claude\projects') ($d.FullName -replace '[^A-Za-z0-9]', '-')
        if (Test-Path -LiteralPath $cd) { try { Merge-CostScan $script:CostLedger (Get-ProjectCostScan $cd $known) } catch { } }
    }
    Save-CostLedger $script:CostLedger
}
$facts = Get-ProjectFacts $dirs $true $needGit
$rows = @($dirs | ForEach-Object { New-Row $_ $true $needGit $facts } | Sort-Object LastActiveDt -Descending)
if ($Filter) { $rows = @($rows | Where-Object { $_.Name -like "*$Filter*" -or $_.Path -like "*$Filter*" }) }
if ($Project.Count -gt 0) { $rows = @($rows | Where-Object { $Project -contains $_.Name -or $Project -contains $_.Path }) }
if ($Top -gt 0 -and -not $All) { $rows = @($rows | Select-Object -First $Top) }
$rescanAllowed = -not $Filter -and $Top -le 0 -and $Project.Count -eq 0   # Refresh may add/remove folders only when the list was not narrowed by switches
$rows = [System.Collections.ArrayList]@($rows)   # a growing list: Refresh adds new project folders and drops vanished ones

if ($List) {
    $running = @(Get-RunningNames)
    $out = @($rows | ForEach-Object {
        $n = $_.Name
        [pscustomobject]@{
            name = $_.Name; path = $_.Path
            lastActive = $(if ($_.LastActiveDt) { $_.LastActiveDt.ToString('o') } else { $null })
            isGit = $_.IsGit; branch = $_.Branch; dirty = $_.Dirty; remoteUrl = $_.RemoteUrl
            running = [bool]($running | Where-Object { $_ -ieq $n })
            hasClaudeHistory = $_.HasHistory; hasPreset = $_.HasPreset; costUsd = $_.CostUsd   # costUsd is null unless showCost is on
        } })
    ConvertTo-Json -InputObject $out -Depth 3
    return
}

if ($All) {
    $n = 15; if ($Top -gt 0) { $n = $Top }
    Invoke-Launch @($rows | Select-Object -First $n) ([bool]$Fresh) $false
} elseif ($Picker -eq 'Grid') {
    $picked = @($rows | Select-Object Name, Relative, LastActive, Branch, Path |
        Out-GridView -Title 'Workspace Wrangler: select projects (Ctrl/Shift for multiple)' -PassThru)
    $sel = @($rows | Where-Object { $picked.Path -contains $_.Path })
    if ($sel.Count -gt 0) { Invoke-Launch $sel ([bool]$Fresh) $true }
} else {
    # Callbacks stay as scriptblocks defined HERE so they keep script scope when invoked from WinForms closures.
    $onLaunch = {
        param($paths, $fresh, $force, $mode, $session, $extra)
        $sel = @($rows | Where-Object { $paths -contains $_.Path })
        if (-not $mode) { $mode = 'both' }
        if (-not $session) { $session = 'auto' }
        Invoke-Launch $sel ([bool]$fresh -or [bool]$Fresh) $true ([bool]$force) ([string]$mode) ([string]$session) ([string]$extra)
        if (-not $DryRun) { Save-State }
    }
    $onSwitch  = { param($name, $tab) if (-not $tab) { $tab = 'any' }; Switch-ToProject $name ([string]$tab) }
    $getRunning = { Get-RunningNames }
    $onSaveLayout = { Save-WindowLayout }
    $onArrange = { param($style, $ignoreSaved) Invoke-ArrangeOpen ([string]$style) ([bool]$ignoreSaved) }
    $onGitOp = { param($op, $row, $form, $preset) try { Invoke-PickerGitOp ([string]$op) $row $form ([string]$preset) } catch { Write-AppLog "git $op crashed: $_ $($_.ScriptStackTrace)"; throw } }
    $onCascade = { param($self) Invoke-CascadeFront ([int64]$self) }
    $actions = @{ Diagnostics = { [System.Windows.Forms.Clipboard]::SetText((Get-DiagnosticsText)) }; OpenLog = { $lf = Join-Path $ConfigDir 'app.log'; if (-not (Test-Path -LiteralPath $lf)) { Set-Content -LiteralPath $lf -Value '' }; Start-Process -FilePath $lf }; CostOn = $script:CostOn; CostAsk = ($null -eq $cfg.showCost -and -not $DryRun); SetCost = { param($v) Set-ConfigValue 'showCost' ([bool]$v) }; Health = { param($owner) Show-DataHealthDialog $owner }; About = { param($owner) Show-AboutDialog $owner }; LaunchOptions = { param($row, $owner) Invoke-PickerLaunchOptions $row $owner }; NewProject = { param($owner) Invoke-PickerNewProject $owner }; RenameProject = { param($row, $owner) Invoke-PickerRenameProject $row $owner }; ChooseRoot = { $p = @(Show-RootDialog { @(Find-ProjectRootCandidates) } 'Choose the folders that hold your projects.' @($Roots)); if ($p.Count) { Set-ProjectRoots $p }; [bool]$p.Count } }
    $onIde = { param($paths) Invoke-OpenIde ([string[]]$paths) }
    # Refresh support: rescan the project folders (new/removed projects), then start Get-ProjectFacts for every project in a background
    # runspace and apply the finished result to the rows in place.
    $onFactsStart = {
        $script:RefreshDirs = @(Get-ProjectDirs)
        $fns = 'ConvertTo-RemoteWebUrl', 'Get-GitInfo', 'Get-LastActive', 'Get-ProjectFacts', 'Read-TranscriptUsage', 'Get-ProjectCostScan'
        $defs = ($fns | ForEach-Object { "function $_ {`n" + (Get-Item "function:$_").ScriptBlock.ToString() + "`n}" }) -join "`n"
        $known = @{}; if ($script:CostOn) { foreach ($e in $script:CostLedger.files.GetEnumerator()) { $known[$e.Key] = [string]$e.Value.sig } }
        $body = 'param($paths, $noise, $maxFiles, $maxDepth, $git, $costOn, $known, $home2)' + "`n" + '$NoiseDirs = $noise; $MaxScanFiles = $maxFiles; $MaxScanDepth = $maxDepth' + "`n" + $defs + "`n" +
            '$d = @($paths | ForEach-Object { [pscustomobject]@{ FullName = $_ } }); $facts = Get-ProjectFacts $d $true $git' + "`n" +
            '$cost = @{}; if ($costOn) { foreach ($p in $paths) { $enc = $p -replace ''[^A-Za-z0-9]'', ''-''; $dir = Join-Path $home2 (''.claude\projects\'' + $enc); if (Test-Path -LiteralPath $dir) { try { $cost[$enc] = Get-ProjectCostScan $dir $known } catch { } } } }' + "`n" +
            '@{ Facts = $facts; Cost = $cost }'
        $ps = [powershell]::Create()
        [void]$ps.AddScript($body).AddArgument([string[]]@($script:RefreshDirs | ForEach-Object { $_.FullName })).AddArgument($NoiseDirs).AddArgument($MaxScanFiles).AddArgument($MaxScanDepth).AddArgument([bool]$needGit).AddArgument([bool]$script:CostOn).AddArgument($known).AddArgument([string]$env:USERPROFILE)
        @{ PS = $ps; Handle = $ps.BeginInvoke() }
    }
    $onFactsDone = {
        param($task)
        try { $out = @($task.PS.EndInvoke($task.Handle)) } finally { $task.PS.Dispose() }
        if (-not $out.Count -or $out[-1] -isnot [hashtable]) { throw 'the background check returned nothing' }
        $res0 = $out[-1]; $f = $res0.Facts
        if ($script:CostOn -and $res0.Cost.Count) {
            foreach ($scan in $res0.Cost.Values) { Merge-CostScan $script:CostLedger $scan }
            Save-CostLedger $script:CostLedger
        }
        $added = 0; $removed = 0
        if ($rescanAllowed) {
            $cur = @($script:RefreshDirs)
            $curKeys = @{}; foreach ($d in $cur) { $curKeys[$d.FullName.ToLowerInvariant()] = $true }
            for ($i = $rows.Count - 1; $i -ge 0; $i--) { if (-not $curKeys.ContainsKey(([string]$rows[$i].Path).TrimEnd('\').ToLowerInvariant())) { $rows.RemoveAt($i); $removed++ } }
            $have = @{}; foreach ($r in $rows) { $have[([string]$r.Path).TrimEnd('\').ToLowerInvariant()] = $true }
            $names = @{}; foreach ($r in $rows) { $names[([string]$r.Name).ToLowerInvariant()] = $true }
            foreach ($d in $cur) {
                if ($have.ContainsKey($d.FullName.ToLowerInvariant())) { continue }
                # Keep names unique against the rows already listed (their names were fixed when the picker started).
                $leaf = Split-Path -Leaf $d.FullName; $nm = $leaf
                if ($names.ContainsKey($nm.ToLowerInvariant())) {
                    $par = Split-Path -Leaf (Split-Path -Parent $d.FullName); $nm = "$leaf ($par)"
                    $k = 2; while ($names.ContainsKey($nm.ToLowerInvariant())) { $nm = "$leaf ($par $k)"; $k++ }
                }
                $names[$nm.ToLowerInvariant()] = $true
                [void]$rows.Add((New-Row ([pscustomobject]@{ Name = $nm; FullName = $d.FullName }) $true $needGit $f)); $added++
            }
        }
        foreach ($r in $rows) {
            if (-not $f.ContainsKey($r.Path)) { continue }
            $la = $f[$r.Path].La; $gi = $f[$r.Path].Gi
            if ($la) { $r.LastActiveDt = $la; $r.Relative = Format-Relative $la; $r.LastActive = $la.ToString('yyyy-MM-dd HH:mm') }
            if ($gi) { $r.RemoteUrl = $gi.RemoteUrl; $r.Branch = $gi.Branch; $r.Dirty = $gi.Dirty }   # keep old values if a check failed
            $r.IsGit = Test-Path -LiteralPath (Join-Path $r.Path '.git')
            if (-not $r.IsGit) { $r.Branch = $null; $r.Dirty = $null; $r.RemoteUrl = $null }
            $r.HasHistory = Test-ClaudeHistory $r.Path
            $r.HasPreset = [bool](Get-Preset $r.Name)
        }
        foreach ($r in $rows) { Set-RowCost $r }
        @{ Added = $added; Removed = $removed; Skipped = (-not $rescanAllowed) }
    }
    $update = @{
        Current = $AppVersion
        Start   = { param($force) Start-UpdateCheck ([bool]$force) }
        Done    = { param($task, $force) Complete-UpdateCheck $task ([bool]$force) }
        Cached  = { Get-UpdateInfo }
        Install = { param($info) Start-InstallUpdate $info }
        Skip    = { param($tag) $state.skipVersion = [string]$tag; if (-not $DryRun) { Save-State } }
        Restart = { Restart-App }
        Changelog = { Open-Changelog }
    }
    [void](Show-FormsPicker $rows $Filter @($state.last) $onLaunch $onSwitch $getRunning ([int]$cfg.refreshSeconds) $onSaveLayout $onArrange $onGitOp $update $onIde $onCascade $actions $onFactsStart $onFactsDone)
    if (-not $DryRun) { Save-State }
}
