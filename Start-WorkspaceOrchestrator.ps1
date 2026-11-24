<#
.SYNOPSIS
    Scans a code root for projects (newest activity first), lets you pick some, and opens
    ONE Windows Terminal window with, per project, a Claude Code tab and a PowerShell tab.

.DESCRIPTION
    Interactive (default): WinForms picker with filter, pinning (star), pre-checked last
    selection, branch/dirty columns. Use -Picker Grid for plain Out-GridView.

    Agent / scripted use (no UI):
      -List                      print all projects as JSON and exit (launches nothing)
      -Project a,b               launch exactly those projects (by folder name or full path)
      -All [-Top N]              launch the N most recent (default 15)
      add -DryRun to print the wt command line instead of launching

    Defaults come from config.json (next to this script); switches/parameters override it.
    Per-project overrides live in presets.json. Pins and last selection live in state.json.

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
.PARAMETER Window     Value for wt's -w (e.g. 0 = most recent existing window). Default: wt's own behavior.
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
    root = 'C:\code'; top = 0; ignore = @('workspace_orchestrator')
    noiseDirs = @('.git','node_modules','.venv','venv','__pycache__','dist','build','.next','bin','obj','.idea','.vscode')
    maxScanFiles = 5000; maxScanDepth = 6; picker = 'Forms'
    shell = $true; diff = $true; tabColors = $true; gitInfo = $true; claudeArgs = ''; keepOpen = $true
}
$cfgFile = Join-Path $PSScriptRoot 'config.json'
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

$stateFile = Join-Path $PSScriptRoot 'state.json'
$state = @{ pinned = @(); last = @() }
if (Test-Path -LiteralPath $stateFile) {
    try {
        $s = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
        $state.pinned = @($s.pinned | Where-Object { $_ }); $state.last = @($s.last | Where-Object { $_ })
    } catch { Write-Warning "Could not parse state.json: $_" }
}
function Save-State {
    try { ([pscustomobject]@{ pinned = @($state.pinned); last = @($state.last) } | ConvertTo-Json) | Set-Content -LiteralPath $stateFile -Encoding UTF8 }
    catch { Write-Warning "Could not save state.json: $_" }
}

$presets = @()
$presetFile = Join-Path $PSScriptRoot 'presets.json'
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

function Get-GitInfo([string]$Dir) {
    if (-not (Test-Path -LiteralPath (Join-Path $Dir '.git'))) { return $null }
    $branch = ''; $dirty = $null
    try {
        $branch = [string](& git -C $Dir branch --show-current 2>$null)
        $dirty = [bool](& git -C $Dir status --porcelain 2>$null | Select-Object -First 1)
    } catch { }
    [pscustomobject]@{ Branch = $branch; Dirty = $dirty }
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
# Tab titles are unique and predictable (claude-code-<project>, shell-<scope>), so we can find
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

# Project names that currently have a claude-code-<name> or shell-<name> tab open.
function Get-RunningNames {
    @(Get-TerminalTabs | ForEach-Object { if ($_.Title -match '^(claude-code|shell)-(.+)$') { $Matches[2] } } | Select-Object -Unique)
}

# Select the project's harness tab (else its shell tab) and raise the window. Returns $true if found.
function Switch-ToProject([string]$Name) {
    if (-not ('WoWin' -as [type])) {
        Add-Type @'
using System; using System.Runtime.InteropServices;
public static class WoWin {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
}
'@
    }
    $tabs = @(Get-TerminalTabs)
    $hit = $tabs | Where-Object { $_.Title -ieq "claude-code-$Name" } | Select-Object -First 1
    if (-not $hit) { $hit = $tabs | Where-Object { $_.Title -ieq "shell-$Name" } | Select-Object -First 1 }
    if (-not $hit) { return $false }
    try { $hit.Tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select() } catch { }
    $h = [IntPtr]$hit.Window.Current.NativeWindowHandle
    if ([WoWin]::IsIconic($h)) { [void][WoWin]::ShowWindow($h, 9) }
    # A tap of Alt lets SetForegroundWindow succeed when we aren't the foreground process (e.g. -Focus from a script).
    [WoWin]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [WoWin]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
    [void][WoWin]::SetForegroundWindow($h)
    return $true
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
                          [bool]$KeepOpen, [scriptblock]$OnLaunch, [scriptblock]$OnSwitch, [scriptblock]$GetRunning) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $ctx = @{
        Rebuilding = $false
        Pinned  = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        Checked = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        Running = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        Clock   = [System.Diagnostics.Stopwatch]::StartNew()
    }
    foreach ($p in $state.pinned) { [void]$ctx.Pinned.Add($p) }
    foreach ($p in $Preselect)    { [void]$ctx.Checked.Add($p) }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Workspace Picker'; $form.ClientSize = New-Object System.Drawing.Size(1040, 628)
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
    $lv.Location = New-Object System.Drawing.Point(12, 44); $lv.Size = New-Object System.Drawing.Size(1016, 500)
    $lv.Anchor = 'Top,Bottom,Left,Right'
    foreach ($col in @(@('Project', 230), @('Open', 50), @('Last active', 90), @('When', 130), @('Branch', 130), @('State', 60), @('Path', 320))) {
        [void]$lv.Columns.Add($col[0], $col[1])
    }

    # ListView column headers have no built-in tooltips, so hit-test the mouse against the header strip.
    $colHelp = @(
        "Project: folder name under the root.`n$([char]0x2605) = pinned (kept at the top). Green row = already open in a terminal.",
        "Open: $([char]0x25CF) means a claude-code-<project> or shell-<project> tab is open in some Windows Terminal window.`nHighlight the row and click Switch to bring it forward.",
        "Last active: how long ago the project's latest git commit was`n(or its newest file change if it isn't a git repo).",
        "When: exact date and time of that last activity.",
        "Branch: the current git branch (blank if not a git repo).",
        "State: 'dirty' = uncommitted changes (modified, staged or untracked files); 'clean' = nothing to commit;`nblank = not a git repo. Does not show unpushed commits.",
        "Path: full folder path of the project."
    )
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
    }.GetNewClosure())
    $lv.Add_MouseLeave({ $ctx.TipCol = -1; $tip.Hide($lv) }.GetNewClosure())

    $status = New-Object System.Windows.Forms.Label
    $status.Text = ''; $status.AutoSize = $true; $status.Location = New-Object System.Drawing.Point(12, 552); $status.Anchor = 'Bottom,Left'

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
    $btnRefresh = New-Btn 'Refresh' 480
    $btnPin     = New-Btn 'Pin / Unpin' 590
    $btnSwitch  = New-Btn 'Switch' 700
    $btnGo      = New-Btn 'Launch' 810
    $btnClose   = New-Btn 'Close' 920
    $btnClose.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.AcceptButton = $btnGo; $form.CancelButton = $btnClose
    $form.Controls.AddRange(@($lbl, $filterBox, $hint, $lv, $status, $chkFresh, $chkKeep, $btnRefresh, $btnPin, $btnSwitch, $btnGo, $btnClose))

    $ctrlTip = New-Object System.Windows.Forms.ToolTip
    $ctrlTip.InitialDelay = 400; $ctrlTip.AutoPopDelay = 12000
    $ctrlTip.SetToolTip($filterBox, 'Type to narrow the list by project name or path. Checked projects stay checked while you filter.')
    $ctrlTip.SetToolTip($chkFresh, 'Start plain "claude" instead of "claude --continue", even for projects with earlier sessions.')
    $ctrlTip.SetToolTip($chkKeep, 'Leave this picker open after launching so you can launch more or Switch to open workspaces. Untick to close after Launch.')
    $ctrlTip.SetToolTip($btnRefresh, 'Re-check which projects have tabs open in Windows Terminal (also happens when you return to this window).')
    $ctrlTip.SetToolTip($btnPin, 'Pin or unpin the highlighted projects. Pinned projects (star) stay at the top of the list and are remembered.')
    $ctrlTip.SetToolTip($btnSwitch, 'Bring the highlighted project''s open tab and its terminal window to the foreground. Works for projects marked open.')
    $ctrlTip.SetToolTip($btnGo, 'Open the checked projects (or the highlighted one) in one new Windows Terminal window: a Claude Code tab and a shell tab each.')
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
            [void]$it.SubItems.Add([string]$r.Branch); [void]$it.SubItems.Add($st); [void]$it.SubItems.Add($r.Path)
            $it.Tag = $r.Path
            if ($isOpen) { $it.BackColor = $green }
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

    $lv.Add_ItemChecked({
        param($s, $e)
        if ($ctx.Rebuilding) { return }
        if ($e.Item.Checked) { [void]$ctx.Checked.Add([string]$e.Item.Tag) } else { [void]$ctx.Checked.Remove([string]$e.Item.Tag) }
    }.GetNewClosure())
    $filterBox.Add_TextChanged({ & $fill }.GetNewClosure())
    $btnRefresh.Add_Click({ & $refresh }.GetNewClosure())
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
        & $OnLaunch $paths $chkFresh.Checked @($ctx.Pinned)
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
    $timer.Dispose()
    [pscustomobject]@{ Pinned = @($ctx.Pinned) }
}

# ---------------------------------------------------------------- launch (build + start wt)
function Invoke-Launch($Selected, [bool]$FreshRun, [bool]$Remember) {
    $clauses = @()
    $extraApps = @()
    foreach ($p in $Selected) {
        if (-not (Test-Path -LiteralPath $p.Path)) { Write-Warning "Directory not found: $($p.Path)"; continue }
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
        # Tab titles: harness tab = "<harness>-<project>", every other tab = "shell-<scope>".
        $clauses += New-TabClause "claude-code-$($p.Name)" $p.Path ($parts -join ' ') $color

        if ($pShell) {
            $shellCmd = $null
            if ($pDiff -and (Test-Path -LiteralPath (Join-Path $p.Path '.git'))) { $shellCmd = 'git status -sb\; git diff --stat' }
            $clauses += New-TabClause "shell-$($p.Name)" $p.Path $shellCmd $color
        }
        if ($preset) {
            foreach ($t in @($preset.extraTabs)) {
                if (-not $t) { continue }
                if (-not (Test-Path -LiteralPath $t.path)) { Write-Warning "Directory not found: $($t.path)"; continue }
                $clauses += New-TabClause "shell-$($t.title)" $t.path $null $color
            }
            foreach ($l in @($preset.launch)) { if ($l) { $extraApps += $l } }
        }
    }
    if ($clauses.Count -eq 0) { return }

    $prefix = ''
    $newWindow = (-not $Window) -or ($Window -eq 'new')
    if ($Window) { $prefix = "-w $Window " }
    if ($newWindow) { $clauses += 'focus-tab -t 0' }   # skipped when attaching to an existing window
    $wtArgs = $prefix + ($clauses -join ' ; ')

    if ($Remember -and -not $DryRun) { $state.last = @($Selected | ForEach-Object { $_.Path }); Save-State }
    if ($DryRun) {
        Write-Output $wtArgs
        foreach ($a in $extraApps) { Write-Output "LAUNCH: $($a.exe) $(@($a.args) -join ' ')" }
        return
    }
    Start-Process -FilePath 'wt.exe' -ArgumentList $wtArgs
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
            pinned = $_.Pinned; isGit = $_.IsGit; branch = $_.Branch; dirty = $_.Dirty
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
        param($paths, $fresh, $pins)
        $state.pinned = @($pins)
        $sel = @(Sort-Projects @($rows | Where-Object { $paths -contains $_.Path }))
        Invoke-Launch $sel ([bool]$fresh -or [bool]$Fresh) $true
        if (-not $DryRun) { Save-State }
    }
    $onSwitch  = { param($name) Switch-ToProject $name }
    $getRunning = { Get-RunningNames }
    $res = Show-FormsPicker $rows $Filter @($state.last) ([bool]$Fresh) ([bool]$cfg.keepOpen) $onLaunch $onSwitch $getRunning
    $state.pinned = @($res.Pinned)
    if (-not $DryRun) { Save-State }
}
