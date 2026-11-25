<#
.SYNOPSIS
    Scans a code root for projects (newest activity first), lets you pick some, and opens
    a Windows Terminal window per project, each with a Claude Code tab and a PowerShell tab.
    Projects that are already open are brought to the front instead of being opened twice.

.DESCRIPTION
    Interactive (default): WinForms picker with filter, pre-checked last
    selection, branch/dirty columns. Use -Picker Grid for plain Out-GridView.

    Agent / scripted use (no UI):
      -List                      print all projects as JSON and exit (launches nothing)
      -Project a,b               launch exactly those projects (by folder name or full path)
      -All [-Top N]              launch the N most recent (default 15)
      add -DryRun to print the wt command line instead of launching

    Settings live in ~\.config\workspace_wrangler\: config.json (defaults; switches/parameters override it),
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
    [string]$Root,
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
$AppVersion = '0.6.1'   # bump on every release; the update check compares it with the latest GitHub release tag
$cfg = @{
    root = 'C:\code'; top = 0; ignore = @()
    noiseDirs = @('.git','node_modules','.venv','venv','__pycache__','dist','build','.next','bin','obj','.idea','.vscode')
    maxScanFiles = 5000; maxScanDepth = 6; picker = 'Forms'
    shell = $true; diff = $true; tabColors = $true; gitInfo = $true; claudeArgs = ''; keepOpen = $true; refreshSeconds = 60; arrangeOnLaunch = $true; arrangeStyle = 'cascade'; keepDesktopIconsClear = $true; windowWidth = 1100; windowHeight = 750; restoreLayouts = $true
    checkForUpdates = $true; updateCheckHours = 24; updateRepo = 'dstaulcu/workspace-wrangler'
    gitOpsOrg = ''; gitOpsTargets = @(); gitOpsVisibility = 'private'
    ide = 'code'; ideArgs = '-n'; git = 'git'; hotkey = 'Ctrl+Alt+W'
}
# Settings live outside the repo so they survive updates; files from older versions are moved over once.
$ConfigDir = Join-Path $env:USERPROFILE '.config\workspace_wrangler'
# The app used to be called Workspace Picker / Orchestrator: carry its settings folder over (read it in place during -DryRun).
$legacyDir = Join-Path $env:USERPROFILE '.config\workspace_picker'
if ((Test-Path -LiteralPath $legacyDir) -and -not (Test-Path -LiteralPath $ConfigDir)) {
    if ($DryRun) { $ConfigDir = $legacyDir }
    else { try { Move-Item -LiteralPath $legacyDir -Destination $ConfigDir } catch { Write-Warning "Could not migrate $legacyDir : $_"; $ConfigDir = $legacyDir } }
}
foreach ($f in 'presets.json','state.json') {
    $old = Join-Path $PSScriptRoot $f; $new = Join-Path $ConfigDir $f
    if ((Test-Path -LiteralPath $old) -and -not (Test-Path -LiteralPath $new) -and -not $DryRun) {
        try { New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null; Move-Item -LiteralPath $old -Destination $new } catch { Write-Warning "Could not migrate ${f}: $_" }
    }
}
$cfgFile = Join-Path $ConfigDir 'config.json'
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
if (-not $PSBoundParameters.ContainsKey('Root'))   { $Root = $cfg.root }
if (-not $PSBoundParameters.ContainsKey('Top'))    { $Top = [int]$cfg.top }
if (-not $PSBoundParameters.ContainsKey('Ignore')) { $Ignore = @($cfg.ignore) }
if (-not $PSBoundParameters.ContainsKey('Picker')) { $Picker = $cfg.picker }
$NoiseDirs = @($cfg.noiseDirs); $MaxScanFiles = [int]$cfg.maxScanFiles; $MaxScanDepth = [int]$cfg.maxScanDepth
$wantShell = (-not $NoShell) -and [bool]$cfg.shell
$wantDiff  = (-not $NoDiff)  -and [bool]$cfg.diff
$wantColor = (-not $NoColor) -and [bool]$cfg.tabColors
$Project = @($Project | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$stateFile = Join-Path $ConfigDir 'state.json'
$state = @{ last = @() }
if (Test-Path -LiteralPath $stateFile) {
    try {
        $s = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
        $state.last = @($s.last | Where-Object { $_ })
        if ($s.lastUpdateCheck) { $state.lastUpdateCheck = [string]$s.lastUpdateCheck }
        if ($s.skipVersion) { $state.skipVersion = [string]$s.skipVersion }
        if ($s.update) { $state.update = $s.update }
    } catch { Write-Warning "Could not parse state.json: $_" }
}
function Save-State {
    try { New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null; ([pscustomobject]@{ last = @($state.last); lastUpdateCheck = $state.lastUpdateCheck; skipVersion = $state.skipVersion; update = $state.update } | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $stateFile -Encoding UTF8 }
    catch { Write-Warning "Could not save state.json: $_" }
}

$presets = @()
$presetFile = Join-Path $ConfigDir 'presets.json'
if (Test-Path -LiteralPath $presetFile) {
    try { $presets = @(Get-Content -LiteralPath $presetFile -Raw | ConvertFrom-Json) }
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
        $branch = [string](& git -C $Dir branch --show-current 2>$null)
        $dirty = [bool](& git -C $Dir status --porcelain 2>$null | Select-Object -First 1)
        # Prefer "origin"; otherwise the first remote with a browsable URL.
        $remotes = @(& git -C $Dir remote 2>$null)
        $ordered = @($remotes | Where-Object { $_ -eq 'origin' }) + @($remotes | Where-Object { $_ -ne 'origin' })
        foreach ($rn in $ordered) {
            $u = ConvertTo-RemoteWebUrl ([string](& git -C $Dir remote get-url $rn 2>$null))
            if ($u) { $url = $u; break }
        }
    } catch { }
    [pscustomobject]@{ Branch = $branch; Dirty = $dirty; RemoteUrl = $url }
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
    if ($Style -eq 'none' -or $rest.Count -lt 2) { return $moved }
    if ($Style -eq 'cascade') {
        # Overlapping windows, each offset down-right so every title bar stays visible; later windows sit on top.
        $step = 48
        $w = $dw; $h = $dh
        $slots = [Math]::Max(1, [Math]::Min([int][Math]::Floor(($wa.Width - $w) / $step), [int][Math]::Floor(($wa.Height - $h) / $step)) + 1)
        for ($i = 0; $i -lt $rest.Count; $i++) {
            $k = $i % $slots
            Set-WindowRect $rest[$i].Handle ($wa.X + $k * $step) ($wa.Y + $k * $step) $w $h $false $true
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
function Invoke-CascadeFront {
    $wins = @(Get-TerminalWindows | Where-Object { $_.Name } | Sort-Object Name)
    if (-not $wins.Count) { return 0 }
    Initialize-WinApi
    foreach ($w in $wins) { if ([WoWin]::IsIconic([IntPtr][int64]$w.Handle)) { [void][WoWin]::ShowWindow([IntPtr][int64]$w.Handle, 9) } }
    [void](Set-WindowArrangement $wins @($wins | ForEach-Object { $_.Name }) @{} 'cascade')
    # A tap of Alt lets SetForegroundWindow succeed when launched from a shortcut hotkey rather than from a focused window.
    [WoWin]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [WoWin]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
    [void][WoWin]::SetForegroundWindow([IntPtr][int64]$wins[-1].Handle)
    return $wins.Count
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

function Switch-ToProject([string]$Name) {
    Initialize-WinApi
    $tabs = @(Get-TerminalTabs)
    $hit = $tabs | Where-Object { $_.Title -ieq "cc:$Name" -or $_.Title -ieq "claude-code-$Name" } | Select-Object -First 1
    if (-not $hit) { $hit = $tabs | Where-Object { $_.Title -ieq "sh:$Name" -or $_.Title -ieq "shell-$Name" } | Select-Object -First 1 }
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
        $o = (& git -C $Dir remote add origin $Url 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { return "The repository was created, but adding it as origin failed: $o" }
    }
    if ($Push) {
        $o = (& git -C $Dir push -u origin HEAD 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { return "The repository was created and added as origin, but the push failed: $(($o -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1))" }
    }
    $null
}

# Non-UI core. $Op: 'init' | 'remote'. $Opts (remote): Provider (github|gitlab|azure|url), Owner ('' = your own account),
# Name, Visibility, Push, Host (gitlab), Url (url). Returns { Ok, Message }.
function Invoke-GitOp([string]$Op, [string]$Dir, $Opts) {
    $r = [pscustomobject]@{ Ok = $false; Message = '' }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { $r.Message = 'git was not found on PATH.'; return $r }
    $isGit = Test-Path -LiteralPath (Join-Path $Dir '.git')
    switch ($Op) {
        'init' {
            if ($isGit) { $r.Message = "$Dir is already a git repository."; return $r }
            if ($DryRun) { $r.Message = "Dry run: would run 'git init' in $Dir."; return $r }
            $out = (& git -C $Dir init 2>&1 | Out-String).Trim()
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
                    $out = (& gh @ghArgs 2>&1 | Out-String).Trim()
                    if ($LASTEXITCODE -ne 0) {
                        $first = ($out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
                        $r.Message = "Could not create $full on GitHub: $first"; return $r
                    }
                    $r.Ok = $true; $r.Message = "Created $full on GitHub ($vis) and added it as origin."
                    if ($push) { $r.Message += ' Pushed the current branch.' }
                }
                'gitlab' {
                    $hostName = [string]$Opts.Host; if (-not $hostName) { $hostName = 'gitlab.com' }
                    $old = $env:GITLAB_HOST; if ($hostName -ne 'gitlab.com') { $env:GITLAB_HOST = $hostName }
                    Push-Location -LiteralPath $Dir
                    try { $out = (& glab repo create $full "--$vis" 2>&1 | Out-String).Trim(); $code = $LASTEXITCODE }
                    finally { Pop-Location; $env:GITLAB_HOST = $old }
                    if ($code -ne 0) {
                        $first = ($out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
                        $r.Message = "Could not create $full on GitLab: $first"; return $r
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
function Show-NewRemoteDialog($OwnerForm, [string]$ProjectName, [bool]$IsGit, [bool]$HasCommits, [string[]]$Owners, [string]$DefaultOwner, [string]$DefaultVisibility, [string]$Provider = 'github') {
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
            $opts = Show-NewRemoteDialog $OwnerForm $Row.Name $isGit ($isGit -and (Test-GitHasCommits $Row.Path)) $owners $default ([string]$cfg.gitOpsVisibility) $prov
            if (-not $opts) { return 'Cancelled.' }
            $hostName = ($targets | Where-Object { $_.Owner -eq $opts.Owner } | Select-Object -First 1).Host
            $opts | Add-Member -NotePropertyName Host -NotePropertyValue ([string]$hostName)
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
        $http.DefaultRequestHeaders.UserAgent.ParseAdd('WorkspaceWrangler-update-check')
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
# Settings live in ~\.config\workspace_wrangler, so they are untouched. Returns @{ Ok; Message }.
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
            Invoke-WebRequest -Uri $Info.Zip -OutFile $zip -UseBasicParsing -TimeoutSec 60 -Headers @{ 'User-Agent' = 'WorkspaceWrangler-update' }
            Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $tmp 'x') -Force
            $root = Get-ChildItem -LiteralPath (Join-Path $tmp 'x') -Directory | Select-Object -First 1
            if (-not $root -or -not (Test-Path -LiteralPath (Join-Path $root.FullName 'Start-WorkspaceWrangler.ps1'))) {
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
function Restart-Wrangler {
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
function Show-FormsPicker($Rows, [string]$InitialFilter, [string[]]$Preselect, [bool]$InitialFresh,
                          [bool]$KeepOpen, [scriptblock]$OnLaunch, [scriptblock]$OnSwitch, [scriptblock]$GetRunning, [int]$RefreshSeconds = 0, [scriptblock]$OnSaveLayout, [scriptblock]$OnArrange, [scriptblock]$OnGitOp, [hashtable]$Update, [scriptblock]$OnIde, [scriptblock]$OnCascade) {
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
    $iconFile = Join-Path $PSScriptRoot 'assets\wrangler.ico'
    $form.Text = "Workspace Wrangler v$($Update.Current)"; if (Test-Path -LiteralPath $iconFile) { try { $form.Icon = New-Object System.Drawing.Icon($iconFile) } catch { } }; $form.ClientSize = New-Object System.Drawing.Size(1150, 628)
    $form.StartPosition = 'CenterScreen'; $form.KeyPreview = $true

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'Filter:'; $lbl.Location = New-Object System.Drawing.Point(12, 16); $lbl.AutoSize = $true
    $filterBox = New-Object System.Windows.Forms.TextBox
    $filterBox.Location = New-Object System.Drawing.Point(60, 12); $filterBox.Width = 320; $filterBox.Text = $InitialFilter
    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = 'Check projects and Launch, or highlight an open (green) project and Switch to bring it forward.'
    $hint.Location = New-Object System.Drawing.Point(400, 16); $hint.AutoSize = $true

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

    # ListView column headers have no built-in tooltips, so hit-test the mouse against the header strip.
    $colHelp = @(
        "Project: folder name under the root.`nGreen row = already open in a terminal.",
        "Open: $([char]0x25CF) means a cc:<project> or sh:<project> tab is open in some Windows Terminal window.`nHighlight the row and click Switch to bring it forward.",
        "Last active: how long ago the project's latest git commit was`n(or its newest file change if it isn't a git repo).",
        "When: exact date and time of that last activity.",
        "Path: full folder path of the project.",
        "Branch: the current git branch (blank if not a git repo).",
        "State: 'dirty' = uncommitted changes (modified, staged or untracked files); 'clean' = nothing to commit;`nblank = not a git repo. Does not show unpushed commits.",
        "Remote: the project's git remote (origin preferred) on any host - owner/repo for GitHub, host/path otherwise. Click it to open the repository in your browser.`nBlank if the project has no remote."
    )
    $ctx.RemoteCol = 7
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
    $help.Text = 'Help:  Repository  |  Open issues  |  Report a bug or request a feature'
    $help.AutoSize = $true; $help.Location = New-Object System.Drawing.Point(670, 552); $help.Anchor = 'Bottom,Right'
    foreach ($l in @(@('Repository', $repoUrl), @('Open issues', "$repoUrl/issues"), @('Report a bug or request a feature', "$repoUrl/issues/new/choose"))) {
        [void]$help.Links.Add($help.Text.IndexOf($l[0]), $l[0].Length, $l[1])
    }
    $help.Add_LinkClicked({
        param($s, $e)
        try { Start-Process ([string]$e.Link.LinkData) } catch { $status.Text = "Could not open $($e.Link.LinkData)" }
    }.GetNewClosure())

    # Update notice: replaces the hint line when a newer release exists. Hooks are scriptblocks from the main script.
    $updLink = New-Object System.Windows.Forms.LinkLabel
    $updLink.AutoSize = $true; $updLink.Location = New-Object System.Drawing.Point(400, 16); $updLink.Visible = $false
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

    $chkFresh = New-Object System.Windows.Forms.CheckBox
    $chkFresh.Text = 'Fresh sessions (no --continue)'; $chkFresh.Checked = $InitialFresh; $chkFresh.AutoSize = $true
    $chkFresh.Location = New-Object System.Drawing.Point(12, 584); $chkFresh.Anchor = 'Bottom,Left'
    $chkKeep = New-Object System.Windows.Forms.CheckBox
    $chkKeep.Text = 'Keep open after launch'; $chkKeep.Checked = $KeepOpen; $chkKeep.AutoSize = $true
    $chkKeep.Location = New-Object System.Drawing.Point(220, 584); $chkKeep.Anchor = 'Bottom,Left'

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
    $form.Controls.AddRange(@($lbl, $filterBox, $hint, $updLink, $lv, $status, $help, $chkFresh, $chkKeep, $btnSettings, $btnIde, $btnGit, $btnArrange, $btnRefresh, $btnSwitch, $btnGo, $btnClose))

    $ctrlTip = New-Object System.Windows.Forms.ToolTip
    $ctrlTip.InitialDelay = 400; $ctrlTip.AutoPopDelay = 12000
    $ctrlTip.SetToolTip($filterBox, 'Type to narrow the list by project name or path. Checked projects stay checked while you filter.')
    $ctrlTip.SetToolTip($chkFresh, 'Start plain "claude" instead of "claude --continue", even for projects with earlier sessions.')
    $ctrlTip.SetToolTip($chkKeep, 'Leave this picker open after launching so you can launch more or Switch to open workspaces. Untick to close after Launch.')
    $ctrlTip.SetToolTip($btnSettings, 'Edit config.json (global defaults) or presets.json (per-project overrides) in your default editor (changes apply the next time the picker starts), or save the positions of your open project windows so Launch restores them.')
    $ctrlTip.SetToolTip($btnIde, 'Open the checked and the highlighted projects in your IDE, one new window per project. Visual Studio Code by default; set "ide" (and "ideArgs") in config.json to use another.')
    $ctrlTip.SetToolTip($btnGit, 'Git actions for the highlighted project: open its repository in your browser, initialize a local git repository, or create a new GitHub repository (in an organization you pick) and add it as origin. Also on the right-click menu of a row.')
    $ctrlTip.SetToolTip($btnArrange, 'Arrange the windows of all open projects now. Choose cascade, grid, side by side or stacked, or reset windows to the default size. Windows with a saved spot (Settings > Save window layout) go there; hold Shift while choosing to ignore saved spots.')
    $ctrlTip.SetToolTip($btnRefresh, 'Re-check which projects have tabs open in Windows Terminal (also happens when you return to this window).')
    $ctrlTip.SetToolTip($btnSwitch, 'Bring the highlighted project''s open tab and its terminal window to the foreground. Works for projects marked open.')
    $ctrlTip.SetToolTip($btnGo, 'Open the checked projects (or the highlighted one), each in its own new Windows Terminal window with a Claude Code tab and a shell tab. Projects already open are brought to the front instead; hold Shift while clicking to open a new copy anyway.')
    $ctrlTip.SetToolTip($btnClose, 'Close the picker without launching anything.')

    $green = [System.Drawing.Color]::FromArgb(222, 245, 226)

    # Rebuild the list (newest activity first); keeps checked + highlighted rows.
    $fill = {
        $ctx.Rebuilding = $true
        $sel = @($lv.SelectedItems | ForEach-Object { [string]$_.Tag })
        $lv.BeginUpdate(); $lv.Items.Clear()
        $f = $filterBox.Text.Trim()
        foreach ($r in $Rows) {
            if ($f -and $r.Name.IndexOf($f, [StringComparison]::OrdinalIgnoreCase) -lt 0 -and $r.Path.IndexOf($f, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            $it = New-Object System.Windows.Forms.ListViewItem($r.Name)
            $open = ''
            $isOpen = $ctx.Running.Contains($r.Name)
            if ($isOpen) { $open = [string][char]0x25CF }
            $st = ''
            if ($r.Dirty -eq $true) { $st = 'dirty' } elseif ($r.Dirty -eq $false) { $st = 'clean' }
            [void]$it.SubItems.Add($open); [void]$it.SubItems.Add($r.Relative); [void]$it.SubItems.Add($r.LastActive)
            $gh = ''
            if ($r.RemoteUrl) { $gh = ($r.RemoteUrl -replace '^https://', '') -replace '^github\.com/', '' }
            [void]$it.SubItems.Add($r.Path); [void]$it.SubItems.Add([string]$r.Branch); [void]$it.SubItems.Add($st); [void]$it.SubItems.Add($gh)
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
            if ($sel -contains $r.Path) { $it.Selected = $true }
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
        if ($ctx.Rebuilding) { return }
        if ($e.Item.Checked) { [void]$ctx.Checked.Add([string]$e.Item.Tag) } else { [void]$ctx.Checked.Remove([string]$e.Item.Tag) }
    }.GetNewClosure())
    $filterBox.Add_TextChanged({ & $fill }.GetNewClosure())
    $btnRefresh.Add_Click({ & $refresh }.GetNewClosure())
    # Arrange: pick a style from a menu. Shift while choosing = ignore saved spots.
    $arrMenu = New-Object System.Windows.Forms.ContextMenuStrip
    foreach ($opt in @(@('Cascade (overlapping, title bars visible)', 'cascade'), @('Tile in a grid', 'grid'), @('Side by side (columns)', 'columns'), @('Stacked (rows)', 'rows'), @('-', ''), @('Reset window size (keep positions)', 'resize'), @('Restore saved layout only', 'none'))) {
        if ($opt[0] -eq '-') { [void]$arrMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)); continue }
        $mi = $arrMenu.Items.Add($opt[0]); $style = $opt[1]
        if ($style -eq 'cascade') { $ctx.CascadeItem = $mi }
        $mi.Add_Click({
            try {
                $shift = [bool]([System.Windows.Forms.Control]::ModifierKeys -band [System.Windows.Forms.Keys]::Shift)
                $n = & $OnArrange $style $shift
                if ($n -gt 0) { $status.Text = "Arranged $n window(s)." } else { $status.Text = 'Nothing to arrange (no open project windows, or only one and no saved spot).' }
            } catch { $status.Text = "Could not arrange windows: $_" }
        }.GetNewClosure())
    }
    $btnArrange.Add_Click({ $arrMenu.Show($btnArrange, (New-Object System.Drawing.Point(0, $btnArrange.Height))) }.GetNewClosure())
    # Git: GitOps actions for the highlighted project (also the list's right-click menu). Items are enabled
    # only where they apply; anything that changes the project asks first (see Invoke-PickerGitOp).
    $gitMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $miGitOpen = $gitMenu.Items.Add('Open repository in browser')
    $miGitInit = $gitMenu.Items.Add('Initialize local repository (git init)...')
    $miGitRemote = New-Object System.Windows.Forms.ToolStripMenuItem 'Create remote repository'
    [void]$gitMenu.Items.Add($miGitRemote)
    $ctx.GitTargets = @(Get-GitTargets)
    $miGitUrl = $gitMenu.Items.Add('Add existing remote URL...')
    $ctx.GitRow = {
        if ($lv.SelectedItems.Count -eq 0) { return $null }
        $path = [string]$lv.SelectedItems[0].Tag
        $Rows | Where-Object { $_.Path -eq $path } | Select-Object -First 1
    }.GetNewClosure()
    $gitMenu.Add_Opening({
        param($s, $e)
        $row = & $ctx.GitRow
        if (-not $row) {
            foreach ($mi in @($miGitOpen, $miGitInit, $miGitRemote)) { $mi.Enabled = $false; $mi.ToolTipText = 'Highlight a project first.' }
            return
        }
        $isGit = Test-Path -LiteralPath (Join-Path $row.Path '.git')
        $miGitOpen.Enabled = [bool]$row.RemoteUrl
        $miGitOpen.ToolTipText = $(if ($row.RemoteUrl) { [string]$row.RemoteUrl } else { 'This project has no remote yet.' })
        $miGitInit.Enabled = -not $isGit
        $miGitInit.ToolTipText = $(if ($isGit) { 'Already a git repository.' } else { "Run git init in $($row.Path)." })
        $miGitRemote.Enabled = -not $row.RemoteUrl
        # Submenu per provider; configured targets (gitOpsTargets) are listed first, then "Other...".
        $miGitUrl.Enabled = -not $row.RemoteUrl
        $miGitUrl.ToolTipText = $(if ($row.RemoteUrl) { 'This project already has a remote.' } else { 'Attach a repository you already created on any host, by URL.' })
        $miGitRemote.DropDownItems.Clear()
        foreach ($pv in 'github','gitlab','azure') {
            $label = @{ github = 'GitHub'; gitlab = 'GitLab'; azure = 'Azure DevOps' }[$pv]
            $sub = New-Object System.Windows.Forms.ToolStripMenuItem $label
            foreach ($t in @($ctx.GitTargets | Where-Object { $_.Provider -eq $pv })) {
                $it = $sub.DropDownItems.Add([string]$t.Owner)
                $key = "$pv|$($t.Owner)"
                $it.Add_Click({ & $ctx.RunGit 'remote' $key }.GetNewClosure())
            }
            if ($pv -eq 'github') {
                $me = $sub.DropDownItems.Add('My own account'); $me.Add_Click({ & $ctx.RunGit 'remote' 'github|@me' }.GetNewClosure())
            }
            if ($sub.DropDownItems.Count) { [void]$sub.DropDownItems.Add('-') }
            $key2 = "$pv|"
            $other = $sub.DropDownItems.Add('Other...'); $other.Add_Click({ & $ctx.RunGit 'remote' $key2 }.GetNewClosure())
            [void]$miGitRemote.DropDownItems.Add($sub)
        }
        $miGitRemote.ToolTipText = $(if ($row.RemoteUrl) { 'This project already has a remote.' } else { 'Create a repository on GitHub (gh), GitLab (glab) or Azure DevOps (az) and add it as origin. Runs git init first if needed.' })
    }.GetNewClosure())
    $miGitOpen.Add_Click({
        $row = & $ctx.GitRow
        if ($row -and $row.RemoteUrl) { try { Start-Process ([string]$row.RemoteUrl) } catch { $status.Text = "Could not open $($row.RemoteUrl)" } }
    }.GetNewClosure())
    $runGit = {
        param($op, $owner)
        $row = & $ctx.GitRow
        if (-not $row) { $status.Text = 'Highlight a project first.'; return }
        try { $status.Text = [string](& $OnGitOp $op $row $form $owner) } catch { $status.Text = "Git action failed: $_" }
        if ($row.RemoteUrl) { $ctx.Remote[$row.Path] = $row.RemoteUrl }
        & $fill
    }.GetNewClosure()
    $ctx.RunGit = $runGit
    $miGitInit.Add_Click({ & $runGit 'init' }.GetNewClosure())
    $miGitUrl.Add_Click({ & $runGit 'addurl' '' }.GetNewClosure())
    $btnGit.Add_Click({ $gitMenu.Show($btnGit, (New-Object System.Drawing.Point(0, $btnGit.Height))) }.GetNewClosure())
    $lv.ContextMenuStrip = $gitMenu
    # Settings: open the JSON files in the default editor (created from the example files if missing).
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $miCfg = $menu.Items.Add('Edit config.json (global defaults)')
    $miPre = $menu.Items.Add('Edit presets.json (per-project overrides)')
    $miLay = $menu.Items.Add('Save window layout (remember where open projects are)')
    $miUpd = $menu.Items.Add('Check for updates now')
    $miLog = $menu.Items.Add('Changelog (what changed in each version)')
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
        if ($lv.SelectedItems.Count -eq 0) { $status.Text = 'Highlight a project first, then Switch.'; return }
        $path = [string]$lv.SelectedItems[0].Tag
        $name = ($Rows | Where-Object { $_.Path -eq $path } | Select-Object -First 1).Name
        if (& $OnSwitch $name) {
            $status.Text = "Switched to $name."
            if (-not $chkKeep.Checked) { $form.Close() }
        } else {
            $status.Text = "No open tab found for $name (use Launch to open it)."
        }
    }.GetNewClosure())
    $btnIde.Add_Click({
        # Everything checked AND everything highlighted (a highlighted row doesn't need its checkbox ticked).
        $paths = @(@($ctx.Checked) + @($lv.SelectedItems | ForEach-Object { [string]$_.Tag }) | Where-Object { $_ } | Select-Object -Unique)
        if ($paths.Count -eq 0) { $status.Text = 'Check or highlight a project first, then IDE.'; return }
        try { $status.Text = [string](& $OnIde $paths) } catch { $status.Text = "Could not open the IDE: $_" }
    }.GetNewClosure())
    $btnGo.Add_Click({
        if ($ctx.Checked.Count -eq 0) { foreach ($i in $lv.SelectedItems) { [void]$ctx.Checked.Add([string]$i.Tag) } }
        if ($ctx.Checked.Count -eq 0) { $status.Text = 'Check at least one project to launch.'; return }
        $paths = @($ctx.Checked)
        $force = [bool]([System.Windows.Forms.Control]::ModifierKeys -band [System.Windows.Forms.Keys]::Shift)   # Shift+Launch = open a new copy even if already open
        & $OnLaunch $paths $chkFresh.Checked $force
        if ($chkKeep.Checked) {
            $ctx.Checked.Clear()
            & $fill
            $status.Text = 'Launched {0} project(s). Rechecking open tabs shortly...' -f $paths.Count
            $timer.Stop(); $timer.Start()
        } else {
            $form.Close()
        }
    }.GetNewClosure())
    # Coming back to the picker (e.g. after switching away) re-checks which tabs are open.
    $form.Add_Activated({ if ($ctx.Clock.ElapsedMilliseconds -gt 3000) { & $refresh } }.GetNewClosure())

    & $fill
    $form.Add_Shown({
        $form.TopMost = $true; $form.Activate(); $form.TopMost = $false
        $filterBox.Focus(); & $refresh
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
                    try { $n = & $OnCascade; $status.Text = "Cascaded $n workspace window(s)." } catch { $status.Text = "Cascade failed: $_" }
                    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal }
                    $form.TopMost = $true; $form.Activate(); $form.TopMost = $false
                }.GetNewClosure())
                # Make the hotkey discoverable in the app itself.
                $hotText = [string]$cfg.hotkey
                $hint.Text = "Launch checked projects, or highlight an open (green) one and Switch.  Hotkey: $hotText cascades all workspaces."
                if ($ctx.CascadeItem) { $ctx.CascadeItem.ShortcutKeyDisplayString = $hotText }
                $ctrlTip.SetToolTip($btnArrange, ($ctrlTip.GetToolTip($btnArrange) + " Hotkey $hotText cascades all open workspaces from anywhere and brings this window up on top (works while the picker is open)."))
            } else { $hk = $null; $ctx.HotkeyNote = "Hotkey $($cfg.hotkey) is already used by another program." }
        } catch { $hk = $null; $ctx.HotkeyNote = "Could not register hotkey $($cfg.hotkey): $_" }
    } elseif ([string]$cfg.hotkey) { $ctx.HotkeyNote = "Hotkey '$($cfg.hotkey)' is not valid (use e.g. Ctrl+Alt+W)." }
    if ($ctx.HotkeyNote) { $status.Text = $ctx.HotkeyNote }
    [void]$form.ShowDialog()
    if ($hk) { try { $hk.Unregister() } catch { } }
    $timer.Dispose(); $bgTimer.Dispose(); $updTimer.Dispose()
    $null
}

# ---------------------------------------------------------------- launch (build + start wt)
function Invoke-Launch($Selected, [bool]$FreshRun, [bool]$Remember, [bool]$ForceNew = $false) {
    $groups = @(); $groupNames = @()
    $extraApps = @()
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
        $parts = @('claude')
        if ((Test-ClaudeHistory $p.Path) -and -not $FreshRun) { $parts += '--continue' }
        if ($cArgs.Trim()) { $parts += ($cArgs.Trim() -replace ';', '\;') }   # args must not contain double quotes
        # Tab titles: Claude tab = "cc:<project>", every other tab = "sh:<scope>" (kept short; detection depends on them).
        $pc = @()
        $pc += New-TabClause "cc:$($p.Name)" $p.Path ($parts -join ' ') $color

        if ($pShell) {
            $shellCmd = $null
            if ($pDiff -and (Test-Path -LiteralPath (Join-Path $p.Path '.git'))) { $shellCmd = 'git status -sb\; git diff --stat' }
            $pc += New-TabClause "sh:$($p.Name)" $p.Path $shellCmd $color
        }
        if ($preset) {
            foreach ($t in @($preset.extraTabs)) {
                if (-not $t) { continue }
                if (-not (Test-Path -LiteralPath $t.path)) { Write-Warning "Directory not found: $($t.path)"; continue }
                $pc += New-TabClause "sh:$($t.title)" $t.path $null $color
            }
            foreach ($l in @($preset.launch)) { if ($l) { $extraApps += $l } }
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
    if ($DryRun) {
        foreach ($n in $toFocus) { Write-Output "FOCUS (already open): $n" }
        foreach ($c in $calls) { Write-Output $c }
        foreach ($a in $extraApps) { Write-Output "LAUNCH: $($a.exe) $(@($a.args) -join ' ')" }
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
}

# ---------------------------------------------------------------- -CheckUpdate (agent-friendly, no UI)
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

# ---------------------------------------------------------------- -Cascade (hotkey / agent, no UI)
if ($Cascade) {
    $n = Invoke-CascadeFront
    if (-not $n) { Write-Warning 'No open workspace windows found.'; exit 1 }
    Write-Output "Cascaded $n workspace window(s)."
    return
}

# ---------------------------------------------------------------- -Focus (agent-friendly, no UI)
if ($Focus) {
    if (Switch-ToProject $Focus) { return }
    Write-Warning "No open tab found for: $Focus"; exit 1
}

# ---------------------------------------------------------------- discover
if (-not (Test-Path -LiteralPath $Root)) { Write-Warning "Root not found: $Root"; exit 1 }

$dirs = @(Get-ChildItem -LiteralPath $Root -Directory -Force |
    Where-Object { $Ignore -notcontains $_.Name -and $_.Name -notlike '.*' })

function New-Row($d, [bool]$Scan, [bool]$Git) {
    $la = $null
    if ($Scan) { $la = Get-LastActive $d.FullName }
    $gi = $null
    if ($Git) { $gi = Get-GitInfo $d.FullName }
    $hasGit = Test-Path -LiteralPath (Join-Path $d.FullName '.git')
    [pscustomobject]@{
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
    }
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

$needGit = [bool]$cfg.gitInfo -and ($List -or ($Picker -eq 'Forms' -and -not $All))
$rows = @($dirs | ForEach-Object { New-Row $_ $true $needGit } | Sort-Object LastActiveDt -Descending)
if ($Filter) { $rows = @($rows | Where-Object { $_.Name -like "*$Filter*" -or $_.Path -like "*$Filter*" }) }
if ($Project.Count -gt 0) { $rows = @($rows | Where-Object { $Project -contains $_.Name -or $Project -contains $_.Path }) }
if ($Top -gt 0 -and -not $All) { $rows = @($rows | Select-Object -First $Top) }

if ($List) {
    $running = @(Get-RunningNames)
    $out = @($rows | ForEach-Object {
        $n = $_.Name
        [pscustomobject]@{
            name = $_.Name; path = $_.Path
            lastActive = $(if ($_.LastActiveDt) { $_.LastActiveDt.ToString('o') } else { $null })
            isGit = $_.IsGit; branch = $_.Branch; dirty = $_.Dirty; remoteUrl = $_.RemoteUrl
            running = [bool]($running | Where-Object { $_ -ieq $n })
            hasClaudeHistory = $_.HasHistory; hasPreset = $_.HasPreset
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
        param($paths, $fresh, $force)
        $sel = @($rows | Where-Object { $paths -contains $_.Path })
        Invoke-Launch $sel ([bool]$fresh -or [bool]$Fresh) $true ([bool]$force)
        if (-not $DryRun) { Save-State }
    }
    $onSwitch  = { param($name) Switch-ToProject $name }
    $getRunning = { Get-RunningNames }
    $onSaveLayout = { Save-WindowLayout }
    $onArrange = { param($style, $ignoreSaved) Invoke-ArrangeOpen ([string]$style) ([bool]$ignoreSaved) }
    $onGitOp = { param($op, $row, $form, $preset) Invoke-PickerGitOp ([string]$op) $row $form ([string]$preset) }
    $onCascade = { Invoke-CascadeFront }
    $onIde = { param($paths) Invoke-OpenIde ([string[]]$paths) }
    $update = @{
        Current = $AppVersion
        Start   = { param($force) Start-UpdateCheck ([bool]$force) }
        Done    = { param($task, $force) Complete-UpdateCheck $task ([bool]$force) }
        Cached  = { Get-UpdateInfo }
        Install = { param($info) Start-InstallUpdate $info }
        Skip    = { param($tag) $state.skipVersion = [string]$tag; if (-not $DryRun) { Save-State } }
        Restart = { Restart-Wrangler }
        Changelog = { Open-Changelog }
    }
    [void](Show-FormsPicker $rows $Filter @($state.last) ([bool]$Fresh) ([bool]$cfg.keepOpen) $onLaunch $onSwitch $getRunning ([int]$cfg.refreshSeconds) $onSaveLayout $onArrange $onGitOp $update $onIde $onCascade)
    if (-not $DryRun) { Save-State }
}
