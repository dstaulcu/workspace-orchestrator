<#
.SYNOPSIS
    Scans a code root for projects (newest activity first), lets you pick some, and opens
    a Windows Terminal window per project, each with a Claude Code tab and a PowerShell tab.
    Projects that are already open are brought to the front instead of being opened twice.

.DESCRIPTION
    Interactive (default): WinForms picker with filter, pinning (star), pre-checked last
    selection, branch/dirty columns. Use -Picker Grid for plain Out-GridView.

    Agent / scripted use (no UI):
      -List                      print all projects as JSON and exit (launches nothing)
      -Project a,b               launch exactly those projects (by folder name or full path)
      -All [-Top N]              launch the N most recent (default 15)
      add -DryRun to print the wt command line instead of launching

    Settings live in ~\.config\workspace_picker\: config.json (defaults; switches/parameters override it),
    presets.json (per-project overrides) and state.json (pins and last selection).

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
    [switch]$DryRun
)

# ---------------------------------------------------------------- config / state
$cfg = @{
    root = 'C:\code'; top = 0; ignore = @()
    noiseDirs = @('.git','node_modules','.venv','venv','__pycache__','dist','build','.next','bin','obj','.idea','.vscode')
    maxScanFiles = 5000; maxScanDepth = 6; picker = 'Forms'
    shell = $true; diff = $true; tabColors = $true; gitInfo = $true; claudeArgs = ''; keepOpen = $true; refreshSeconds = 60; arrangeOnLaunch = $true; arrangeStyle = 'cascade'; keepDesktopIconsClear = $true; windowWidth = 1100; windowHeight = 750; restoreLayouts = $true
    gitOpsOrg = ''; gitOpsVisibility = 'private'
}
# Settings live outside the repo so they survive updates; files from older versions are moved over once.
$ConfigDir = Join-Path $env:USERPROFILE '.config\workspace_picker'
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
$state = @{ pinned = @(); last = @() }
if (Test-Path -LiteralPath $stateFile) {
    try {
        $s = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
        $state.pinned = @($s.pinned | Where-Object { $_ }); $state.last = @($s.last | Where-Object { $_ })
    } catch { Write-Warning "Could not parse state.json: $_" }
}
function Save-State {
    try { New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null; ([pscustomobject]@{ pinned = @($state.pinned); last = @($state.last) } | ConvertTo-Json) | Set-Content -LiteralPath $stateFile -Encoding UTF8 }
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

# Pinned projects first, then newest-first (input is already newest-first).
function Sort-Projects($Rows) {
    $pin = @($Rows | Where-Object { $state.pinned -contains $_.Path })
    $rest = @($Rows | Where-Object { $state.pinned -notcontains $_.Path })
    @($pin) + @($rest)
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

# Non-UI core. $Op: 'init' | 'remote'. $Opts (remote): Owner ('' = your own account), Name, Visibility, Push.
# Returns { Ok, Message }.
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
            if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { $r.Message = "GitHub CLI (gh) was not found. Install it from https://cli.github.com, then run 'gh auth login'."; return $r }
            if ($isGit -and [string](& git -C $Dir remote get-url origin 2>$null)) { $r.Message = "This project already has a remote named 'origin'."; return $r }
            $vis = ([string]$Opts.Visibility).ToLowerInvariant()
            if (@('private','internal','public') -notcontains $vis) { $vis = 'private' }
            $full = [string]$Opts.Name
            if ([string]$Opts.Owner) { $full = "$($Opts.Owner)/$($Opts.Name)" }
            $ghArgs = @('repo', 'create', $full, "--$vis", '--source', $Dir, '--remote', 'origin')
            if ($Opts.Push) { $ghArgs += '--push' }
            if ($DryRun) {
                $pre = ''; if (-not $isGit) { $pre = "'git init' in $Dir, then " }
                $r.Message = "Dry run: would run ${pre}gh $($ghArgs -join ' ')"; return $r
            }
            if (-not $isGit) {
                $init = Invoke-GitOp 'init' $Dir $null
                if (-not $init.Ok) { return $init }
            }
            $out = (& gh @ghArgs 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -ne 0) {
                $first = ($out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
                $r.Message = "Could not create $full on GitHub: $first"; return $r
            }
            $r.Ok = $true; $r.Message = "Created $full on GitHub ($vis) and added it as origin."
            if ($Opts.Push) { $r.Message += ' Pushed the current branch.' }
        }
        default { $r.Message = "Unknown git action: $Op" }
    }
    $r
}

# Dialog for New remote on GitHub. Returns $null (cancelled) or { Owner, Name, Visibility, Push }.
function Show-NewRemoteDialog($OwnerForm, [string]$ProjectName, [bool]$IsGit, [bool]$HasCommits, [string[]]$Owners, [string]$DefaultOwner, [string]$DefaultVisibility) {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "New GitHub repository for $ProjectName"; $dlg.ClientSize = New-Object System.Drawing.Size(480, 250)
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
    $dlg.Controls.AddRange(@((& $mk 'Owner (organization):' 12), $cboOwner, (& $mk 'Repository name:' 44), $txtName, (& $mk 'Visibility:' 76), $cboVis, $chkPush, $summary, $ok, $cancel))
    $tip = New-Object System.Windows.Forms.ToolTip
    $tip.SetToolTip($cboOwner, 'The GitHub organization to create the repository in (pick one or type it). Leave blank for your own account. Default comes from gitOpsOrg in config.json.')

    $update = {
        $owner = $cboOwner.Text.Trim(); $full = $txtName.Text.Trim()
        if ($owner) { $full = "$owner/$full" } else { $full = "$full (your account)" }
        $s = "This will create $full on GitHub as $($cboVis.SelectedItem) and add it to this project as 'origin'."
        if (-not $IsGit) { $s = "This will run 'git init' in the project, then create $full on GitHub as $($cboVis.SelectedItem) and add it as 'origin'." }
        if ($chkPush.Checked) { $s += ' The current branch is pushed.' }
        $summary.Text = $s
    }.GetNewClosure()
    $cboOwner.Add_TextChanged($update); $txtName.Add_TextChanged($update); $cboVis.Add_SelectedIndexChanged($update); $chkPush.Add_CheckedChanged($update)
    & $update
    $ok.Add_Click({
        if ($txtName.Text.Trim() -notmatch '^[A-Za-z0-9._-]+$') {
            [void][System.Windows.Forms.MessageBox]::Show($dlg, 'Repository names can use only letters, digits, ".", "-" and "_".', 'New GitHub repository', 'OK', 'Warning')
            return
        }
        if ($cboOwner.Text.Trim() -and $cboOwner.Text.Trim() -notmatch '^[A-Za-z0-9-]+$') {
            [void][System.Windows.Forms.MessageBox]::Show($dlg, 'An owner name can use only letters, digits and "-".', 'New GitHub repository', 'OK', 'Warning')
            return
        }
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK; $dlg.Close()
    }.GetNewClosure())

    $res = $dlg.ShowDialog($OwnerForm)
    $out = $null
    if ($res -eq [System.Windows.Forms.DialogResult]::OK) {
        $out = [pscustomobject]@{ Owner = $cboOwner.Text.Trim(); Name = $txtName.Text.Trim(); Visibility = [string]$cboVis.SelectedItem; Push = ($chkPush.Enabled -and $chkPush.Checked) }
    }
    $dlg.Dispose()
    $out
}

# Picker side of a Git menu action: confirm, run, then refresh the row's git info in place.
# $Row is the picker's row object (shared with the list), so updating it updates the picker.
function Invoke-PickerGitOp([string]$Op, $Row, $OwnerForm) {
    $isGit = Test-Path -LiteralPath (Join-Path $Row.Path '.git')
    switch ($Op) {
        'init' {
            $ans = [System.Windows.Forms.MessageBox]::Show($OwnerForm, "Run 'git init' in this folder?`n`n$($Row.Path)", 'Initialize local repository', 'YesNo', 'Question')
            if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return 'Cancelled.' }
            $res = Invoke-GitOp 'init' $Row.Path $null
        }
        'remote' {
            if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { return "GitHub CLI (gh) was not found. Install it from https://cli.github.com, then run 'gh auth login'." }
            $OwnerForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            try { $owners = @(Get-GitHubOwners) } finally { $OwnerForm.Cursor = [System.Windows.Forms.Cursors]::Default }
            $default = [string]$cfg.gitOpsOrg
            if (-not $default -and $owners.Count) { $default = $owners[0] }
            $opts = Show-NewRemoteDialog $OwnerForm $Row.Name $isGit ($isGit -and (Test-GitHasCommits $Row.Path)) $owners $default ([string]$cfg.gitOpsVisibility)
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
                          [bool]$KeepOpen, [scriptblock]$OnLaunch, [scriptblock]$OnSwitch, [scriptblock]$GetRunning, [int]$RefreshSeconds = 0, [scriptblock]$OnSaveLayout, [scriptblock]$OnArrange, [scriptblock]$OnGitOp) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $ctx = @{
        Rebuilding = $false
        Pinned  = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
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
    foreach ($p in $state.pinned) { [void]$ctx.Pinned.Add($p) }
    foreach ($p in $Preselect)    { [void]$ctx.Checked.Add($p) }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Workspace Picker'; $form.ClientSize = New-Object System.Drawing.Size(1260, 628)
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
    $lv.Location = New-Object System.Drawing.Point(12, 44); $lv.Size = New-Object System.Drawing.Size(1236, 500)
    $lv.Anchor = 'Top,Bottom,Left,Right'
    # Path comes before the git-only columns (Branch, State, Remote) because not every project is a repo.
    # The Remote link column index is stored in $ctx.RemoteCol (set with $colHelp below); keep it, $colHelp and the
    # SubItems.Add order in the list fill in sync if you reorder.
    foreach ($col in @(@('Project', 200), @('Open', 45), @('Last active', 85), @('When', 115), @('Path', 230), @('Branch', 110), @('State', 55), @('Remote', 160))) {
        [void]$lv.Columns.Add($col[0], $col[1])
    }

    # ListView column headers have no built-in tooltips, so hit-test the mouse against the header strip.
    $colHelp = @(
        "Project: folder name under the root.`n$([char]0x2605) = pinned (kept at the top). Green row = already open in a terminal.",
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
    $repoUrl = 'https://github.com/dstaulcu/workspace-orchestrator'
    $help = New-Object System.Windows.Forms.LinkLabel
    $help.Text = 'Help:  Repository  |  Open issues  |  Report a bug or request a feature'
    $help.AutoSize = $true; $help.Location = New-Object System.Drawing.Point(780, 552); $help.Anchor = 'Bottom,Right'
    foreach ($l in @(@('Repository', $repoUrl), @('Open issues', "$repoUrl/issues"), @('Report a bug or request a feature', "$repoUrl/issues/new/choose"))) {
        [void]$help.Links.Add($help.Text.IndexOf($l[0]), $l[0].Length, $l[1])
    }
    $help.Add_LinkClicked({
        param($s, $e)
        try { Start-Process ([string]$e.Link.LinkData) } catch { $status.Text = "Could not open $($e.Link.LinkData)" }
    }.GetNewClosure())

    $chkFresh = New-Object System.Windows.Forms.CheckBox
    $chkFresh.Text = 'Fresh sessions (no --continue)'; $chkFresh.Checked = $InitialFresh; $chkFresh.AutoSize = $true
    $chkFresh.Location = New-Object System.Drawing.Point(12, 584); $chkFresh.Anchor = 'Bottom,Left'
    $chkKeep = New-Object System.Windows.Forms.CheckBox
    $chkKeep.Text = 'Keep open after launch'; $chkKeep.Checked = $KeepOpen; $chkKeep.AutoSize = $true
    $chkKeep.Location = New-Object System.Drawing.Point(220, 584); $chkKeep.Anchor = 'Bottom,Left'

    function New-Btn($text, $x, $isDefault) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $text; $b.Size = New-Object System.Drawing.Size(100, 28)
        $b.Location = New-Object System.Drawing.Point($x, 580); $b.Anchor = 'Bottom,Right'
        $b
    }
    $btnSettings = New-Btn 'Settings' 372
    $btnGit     = New-Btn 'Git' 480
    $btnArrange = New-Btn 'Arrange' 590
    $btnRefresh = New-Btn 'Refresh' 700
    $btnPin     = New-Btn 'Pin / Unpin' 810
    $btnSwitch  = New-Btn 'Switch' 920
    $btnGo      = New-Btn 'Launch' 1030
    $btnClose   = New-Btn 'Close' 1140
    $btnClose.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.AcceptButton = $btnGo; $form.CancelButton = $btnClose
    $form.Controls.AddRange(@($lbl, $filterBox, $hint, $lv, $status, $help, $chkFresh, $chkKeep, $btnSettings, $btnGit, $btnArrange, $btnRefresh, $btnPin, $btnSwitch, $btnGo, $btnClose))

    $ctrlTip = New-Object System.Windows.Forms.ToolTip
    $ctrlTip.InitialDelay = 400; $ctrlTip.AutoPopDelay = 12000
    $ctrlTip.SetToolTip($filterBox, 'Type to narrow the list by project name or path. Checked projects stay checked while you filter.')
    $ctrlTip.SetToolTip($chkFresh, 'Start plain "claude" instead of "claude --continue", even for projects with earlier sessions.')
    $ctrlTip.SetToolTip($chkKeep, 'Leave this picker open after launching so you can launch more or Switch to open workspaces. Untick to close after Launch.')
    $ctrlTip.SetToolTip($btnSettings, 'Edit config.json (global defaults) or presets.json (per-project overrides) in your default editor (changes apply the next time the picker starts), or save the positions of your open project windows so Launch restores them.')
    $ctrlTip.SetToolTip($btnGit, 'Git actions for the highlighted project: open its repository in your browser, initialize a local git repository, or create a new GitHub repository (in an organization you pick) and add it as origin. Also on the right-click menu of a row.')
    $ctrlTip.SetToolTip($btnArrange, 'Arrange the windows of all open projects now. Choose cascade, grid, side by side or stacked, or reset windows to the default size. Windows with a saved spot (Settings > Save window layout) go there; hold Shift while choosing to ignore saved spots.')
    $ctrlTip.SetToolTip($btnRefresh, 'Re-check which projects have tabs open in Windows Terminal (also happens when you return to this window).')
    $ctrlTip.SetToolTip($btnPin, 'Pin or unpin the highlighted projects. Pinned projects (star) stay at the top of the list and are remembered.')
    $ctrlTip.SetToolTip($btnSwitch, 'Bring the highlighted project''s open tab and its terminal window to the foreground. Works for projects marked open.')
    $ctrlTip.SetToolTip($btnGo, 'Open the checked projects (or the highlighted one), each in its own new Windows Terminal window with a Claude Code tab and a shell tab. Projects already open are brought to the front instead; hold Shift while clicking to open a new copy anyway.')
    $ctrlTip.SetToolTip($btnClose, 'Close the picker without launching anything.')

    $green = [System.Drawing.Color]::FromArgb(222, 245, 226)

    # Rebuild the list: pinned first, then recency; keeps checked + highlighted rows.
    $fill = {
        $ctx.Rebuilding = $true
        $sel = @($lv.SelectedItems | ForEach-Object { [string]$_.Tag })
        $lv.BeginUpdate(); $lv.Items.Clear()
        $f = $filterBox.Text.Trim()
        $ordered = @($Rows | Where-Object { $ctx.Pinned.Contains($_.Path) }) + @($Rows | Where-Object { -not $ctx.Pinned.Contains($_.Path) })
        foreach ($r in $ordered) {
            if ($f -and $r.Name.IndexOf($f, [StringComparison]::OrdinalIgnoreCase) -lt 0 -and $r.Path.IndexOf($f, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            $star = ''
            if ($ctx.Pinned.Contains($r.Path)) { $star = [string][char]0x2605 + ' ' }
            $it = New-Object System.Windows.Forms.ListViewItem(($star + $r.Name))
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
    $miGitRemote = $gitMenu.Items.Add('Create remote repository on GitHub...')
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
        $miGitRemote.ToolTipText = $(if ($row.RemoteUrl) { 'This project already has a remote.' } elseif ($isGit) { 'Create a GitHub repository (pick the organization) and add it as origin. Needs the GitHub CLI (gh).' } else { 'Runs git init first, then creates a GitHub repository and adds it as origin. Needs the GitHub CLI (gh).' })
    }.GetNewClosure())
    $miGitOpen.Add_Click({
        $row = & $ctx.GitRow
        if ($row -and $row.RemoteUrl) { try { Start-Process ([string]$row.RemoteUrl) } catch { $status.Text = "Could not open $($row.RemoteUrl)" } }
    }.GetNewClosure())
    $runGit = {
        param($op)
        $row = & $ctx.GitRow
        if (-not $row) { $status.Text = 'Highlight a project first.'; return }
        try { $status.Text = [string](& $OnGitOp $op $row $form) } catch { $status.Text = "Git action failed: $_" }
        if ($row.RemoteUrl) { $ctx.Remote[$row.Path] = $row.RemoteUrl }
        & $fill
    }.GetNewClosure()
    $miGitInit.Add_Click({ & $runGit 'init' }.GetNewClosure())
    $miGitRemote.Add_Click({ & $runGit 'remote' }.GetNewClosure())
    $btnGit.Add_Click({ $gitMenu.Show($btnGit, (New-Object System.Drawing.Point(0, $btnGit.Height))) }.GetNewClosure())
    $lv.ContextMenuStrip = $gitMenu
    # Settings: open the JSON files in the default editor (created from the example files if missing).
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $miCfg = $menu.Items.Add('Edit config.json (global defaults)')
    $miPre = $menu.Items.Add('Edit presets.json (per-project overrides)')
    $miLay = $menu.Items.Add('Save window layout (remember where open projects are)')
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
    $miLay.Add_Click({
        try {
            $n = & $OnSaveLayout
            $status.Text = "Saved window positions for $n open project(s). They are restored the next time you launch them."
        } catch { $status.Text = "Could not save layout: $_" }
    }.GetNewClosure())
    $btnSettings.Add_Click({ $menu.Show($btnSettings, (New-Object System.Drawing.Point(0, $btnSettings.Height))) }.GetNewClosure())
    $btnPin.Add_Click({
        $paths = @($lv.SelectedItems | ForEach-Object { [string]$_.Tag })
        foreach ($p in $paths) { if ($ctx.Pinned.Contains($p)) { [void]$ctx.Pinned.Remove($p) } else { [void]$ctx.Pinned.Add($p) } }
        & $fill
    }.GetNewClosure())
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
    $btnGo.Add_Click({
        if ($ctx.Checked.Count -eq 0) { foreach ($i in $lv.SelectedItems) { [void]$ctx.Checked.Add([string]$i.Tag) } }
        if ($ctx.Checked.Count -eq 0) { $status.Text = 'Check at least one project to launch.'; return }
        $paths = @($ctx.Checked)
        $force = [bool]([System.Windows.Forms.Control]::ModifierKeys -band [System.Windows.Forms.Keys]::Shift)   # Shift+Launch = open a new copy even if already open
        & $OnLaunch $paths $chkFresh.Checked @($ctx.Pinned) $force
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
    }.GetNewClosure())
    [void]$form.ShowDialog()
    $timer.Dispose(); $bgTimer.Dispose()
    [pscustomobject]@{ Pinned = @($ctx.Pinned) }
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
        Pinned = ($state.pinned -contains $d.FullName)
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
$rows = @(Sort-Projects $rows)
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
            pinned = $_.Pinned; isGit = $_.IsGit; branch = $_.Branch; dirty = $_.Dirty; remoteUrl = $_.RemoteUrl
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
        Out-GridView -Title 'Workspace Picker: select projects (Ctrl/Shift for multiple)' -PassThru)
    $sel = @($rows | Where-Object { $picked.Path -contains $_.Path })
    if ($sel.Count -gt 0) { Invoke-Launch $sel ([bool]$Fresh) $true }
} else {
    # Callbacks stay as scriptblocks defined HERE so they keep script scope when invoked from WinForms closures.
    $onLaunch = {
        param($paths, $fresh, $pins, $force)
        $state.pinned = @($pins)
        $sel = @(Sort-Projects @($rows | Where-Object { $paths -contains $_.Path }))
        Invoke-Launch $sel ([bool]$fresh -or [bool]$Fresh) $true ([bool]$force)
        if (-not $DryRun) { Save-State }
    }
    $onSwitch  = { param($name) Switch-ToProject $name }
    $getRunning = { Get-RunningNames }
    $onSaveLayout = { Save-WindowLayout }
    $onArrange = { param($style, $ignoreSaved) Invoke-ArrangeOpen ([string]$style) ([bool]$ignoreSaved) }
    $onGitOp = { param($op, $row, $owner) Invoke-PickerGitOp ([string]$op) $row $owner }
    $res = Show-FormsPicker $rows $Filter @($state.last) ([bool]$Fresh) ([bool]$cfg.keepOpen) $onLaunch $onSwitch $getRunning ([int]$cfg.refreshSeconds) $onSaveLayout $onArrange $onGitOp
    $state.pinned = @($res.Pinned)
    if (-not $DryRun) { Save-State }
}
