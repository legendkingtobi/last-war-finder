#requires -Version 5.1
<#
  Read-only UI Automation diagnostic for the Last War PC client.

  Walks System.Windows.Automation under top-level windows whose process is
  LastWar.exe and whose title is exactly "Last War-Survival Game".
  It does not type, click, change focus, toggle Narrator, read process memory,
  inject code into the game, use the network, or read ValuePattern values.

  Windows PowerShell 5.1 only (powershell.exe). PowerShell 7 cannot load
  UIAutomationClient. The script starts its own STA worker and stops that
  worker on timeout. It never stops LastWar.exe.

  How to run, with the game already running and the known chat open:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Inspect-LastWarChatUia.ps1 -OutFile .\lastwar-uia-report.json

  Send lastwar-uia-report.json back. A nonempty Name is not recipient
  verification. This script does not print message text.
#>
param(
    [string]$OutFile = '',
    [int]$MaxNodes = 250,
    [int]$MaxDepth = 6,
    [int]$TimeoutSec = 15,
    [switch]$Worker
)

$ErrorActionPreference = 'Stop'
$ExpectedTitle = 'Last War-Survival Game'
$ExpectedProcess = 'LastWar'
$ExpectedExe = 'LastWar.exe'

function Limit-Int([int]$Value, [int]$Min, [int]$Max) {
    if ($Value -lt $Min) { return $Min }
    if ($Value -gt $Max) { return $Max }
    return $Value
}

$MaxNodes = Limit-Int $MaxNodes 1 400
$MaxDepth = Limit-Int $MaxDepth 1 8
$TimeoutSec = Limit-Int $TimeoutSec 5 30

function New-Report([string]$Status, [bool]$TimedOut, [string]$Detail) {
    return [ordered]@{
        tool                = 'Inspect-LastWarChatUia'
        readOnly            = $true
        actionsTaken        = @()
        generatedUtc        = [DateTime]::UtcNow.ToString('o')
        status              = $Status
        detail              = $Detail
        recipientVerified   = $false
        disclaimer          = 'A nonempty Name is not recipient verification. ValuePattern values and message text were not read. Control presence does not identify the open chat.'
        limits              = [ordered]@{ maxNodes = $MaxNodes; maxDepth = $MaxDepth; timeoutSec = $TimeoutSec }
        timedOut            = $TimedOut
        truncated           = $false
        expectedProcess     = $ExpectedExe
        expectedTitle       = $ExpectedTitle
        processes           = @()
        windows             = @()
    }
}

function Convert-Report($Report) {
    try {
        Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
        $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $ser.MaxJsonLength = 8000000
        $ser.RecursionLimit = 20
        return $ser.Serialize($Report)
    }
    catch {
        return ($Report | ConvertTo-Json -Depth 8)
    }
}

function Format-JsonText([string]$Json) {
    $sb = New-Object System.Text.StringBuilder
    $indent = 0
    $inString = $false
    $escape = $false
    foreach ($ch in $Json.ToCharArray()) {
        if ($inString) {
            [void]$sb.Append($ch)
            if ($escape) { $escape = $false }
            elseif ($ch -eq '\') { $escape = $true }
            elseif ($ch -eq '"') { $inString = $false }
            continue
        }
        switch ($ch) {
            '{' { [void]$sb.Append("`r`n" + ('  ' * $indent) + $ch); $indent++; [void]$sb.Append("`r`n" + ('  ' * $indent)) }
            '}' { if ($indent -gt 0) { $indent-- }; [void]$sb.Append("`r`n" + ('  ' * $indent) + $ch) }
            '[' { [void]$sb.Append($ch); $indent++; [void]$sb.Append("`r`n" + ('  ' * $indent)) }
            ']' { if ($indent -gt 0) { $indent-- }; [void]$sb.Append("`r`n" + ('  ' * $indent) + $ch) }
            ',' { [void]$sb.Append($ch); [void]$sb.Append("`r`n" + ('  ' * $indent)) }
            ':' { [void]$sb.Append(': ') }
            default { [void]$sb.Append($ch) }
        }
    }
    return $sb.ToString().Trim()
}

function Write-Report($Report, [int]$ExitCode) {
    $json = Format-JsonText (Convert-Report $Report)
    if ($Worker) {
        [Console]::Out.Write($json)
        exit $ExitCode
    }
    if ($OutFile) {
        $parent = Split-Path -Parent $OutFile
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            throw "Output directory does not exist."
        }
        [System.IO.File]::WriteAllText($OutFile, $json, (New-Object System.Text.UTF8Encoding $false))
    }
    else {
        Write-Output $json
    }
    exit $ExitCode
}

function Get-SafeToken([string]$Value, [int]$MaxLen) {
    $len = 0
    if ($null -ne $Value) { $len = $Value.Length }
    $text = $null
    $redacted = $false
    if ($len -gt 0) {
        if ($len -le $MaxLen -and $Value -match '^[A-Za-z_][A-Za-z0-9_.:\-]*$') { $text = $Value }
        else { $redacted = $true }
    }
    return [ordered]@{ text = $text; length = $len; redacted = $redacted }
}

function Get-SafeLabel([string]$Name, [string]$ControlType) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    $chrome = @('ControlType.Button', 'ControlType.SplitButton', 'ControlType.MenuItem', 'ControlType.TabItem', 'ControlType.Window', 'ControlType.TitleBar')
    if ($chrome -notcontains $ControlType) { return $null }
    $trimmed = $Name.Trim()
    $allow = @(
        'Last War-Survival Game',
        'Send', 'Senden', 'OK', 'Cancel', 'Abbrechen', 'Close', 'Schliessen',
        'Back', 'Zurueck', 'Chat', 'Emoji', 'Search', 'Suchen', 'Plus'
    )
    foreach ($item in $allow) {
        if ([string]::Equals($trimmed, $item, [StringComparison]::OrdinalIgnoreCase)) { return $item }
    }
    return $null
}

if (-not $Worker) {
    if ($env:OS -ne 'Windows_NT') {
        $report = New-Report 'NOT_WINDOWS' $false 'Run this script on Windows PowerShell 5.1 on the PC where Last War is open.'
        Write-Report $report 5
    }
    if ($OutFile -and $OutFile -notmatch '(?i)\.json$') {
        throw 'OutFile must end with .json'
    }
    $hostExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $hostExe)) {
        $report = New-Report 'POWERSHELL_HOST_MISSING' $false 'Windows PowerShell 5.1 was not found.'
        Write-Report $report 5
    }
    $arg = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}" -Worker -MaxNodes {1} -MaxDepth {2} -TimeoutSec {3}' -f $PSCommandPath, $MaxNodes, $MaxDepth, $TimeoutSec
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $hostExe
    $psi.Arguments = $arg
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $timeoutMs = ($TimeoutSec + 8) * 1000
    $finished = $proc.WaitForExit($timeoutMs)
    if (-not $finished) {
        try { $proc.Kill() } catch { }
        try { [void]$proc.WaitForExit(3000) } catch { }
        $report = New-Report 'WALK_TIMEOUT' $true 'The UI Automation worker exceeded its time limit and was stopped. LastWar.exe was not stopped. No tree was accepted.'
        Write-Report $report 4
    }
    $stdout = ''
    $stderr = ''
    try { $stdout = $outTask.Result } catch { $stdout = '' }
    try { $stderr = $errTask.Result } catch { $stderr = '' }
    if ([string]::IsNullOrWhiteSpace($stdout)) {
        $tail = ''
        if ($stderr) { $tail = $stderr.Substring(0, [Math]::Min(240, $stderr.Length)) }
        $report = New-Report 'WORKER_NO_OUTPUT' $false $tail
        Write-Report $report 1
    }
    if ($OutFile) {
        $parent = Split-Path -Parent $OutFile
        if ($parent -and -not (Test-Path -LiteralPath $parent)) { throw 'Output directory does not exist.' }
        [System.IO.File]::WriteAllText($OutFile, $stdout, (New-Object System.Text.UTF8Encoding $false))
    }
    else {
        [Console]::Out.Write($stdout)
    }
    if ($stdout -match '"status"\s*:\s*"([A-Z0-9_]+)"') {
        Write-Host ('status=' + $Matches[1] + ' recipientVerified=false')
    }
    exit $proc.ExitCode
}

# Worker: STA, read-only walk. No second process is started from here.
$started = [Diagnostics.Stopwatch]::StartNew()
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)

try {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
}
catch {
    $report = New-Report 'UIA_ASSEMBLY_UNAVAILABLE' $false 'UIAutomationClient could not be loaded. Use powershell.exe, not pwsh.'
    Write-Report $report 5
}

if (-not ('LwfTopWindows' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class LwfTopWindows {
    delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hWnd, StringBuilder sb, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    public static List<string> List(uint pid) {
        var rows = new List<string>();
        EnumWindows(delegate (IntPtr h, IntPtr l) {
            uint op;
            GetWindowThreadProcessId(h, out op);
            if (op == pid) {
                var title = new StringBuilder(512);
                var cls = new StringBuilder(256);
                GetWindowText(h, title, title.Capacity);
                GetClassName(h, cls, cls.Capacity);
                rows.Add(h.ToInt64().ToString() + "\t" + (IsWindowVisible(h) ? "1" : "0") + "\t" + cls.ToString() + "\t" + title.ToString());
            }
            return true;
        }, IntPtr.Zero);
        return rows;
    }
}
'@
}

function Get-PatternFlags($Element) {
    $flags = [ordered]@{ value = $false; invoke = $false; text = $false; names = (New-Object System.Collections.Generic.List[string]); other = 0; error = $null }
    try {
        $valueId = [System.Windows.Automation.ValuePattern]::Pattern.Id
        $invokeId = [System.Windows.Automation.InvokePattern]::Pattern.Id
        $textId = [System.Windows.Automation.TextPattern]::Pattern.Id
        foreach ($pat in $Element.GetSupportedPatterns()) {
            $short = $null
            $pn = $pat.ProgrammaticName
            if ($pn -match '^([A-Za-z]{1,40})Pattern') { $short = $Matches[1] }
            if ($pat.Id -eq $valueId) { $flags.value = $true }
            elseif ($pat.Id -eq $invokeId) { $flags.invoke = $true }
            elseif ($pat.Id -eq $textId) { $flags.text = $true }
            if ($short) {
                if (-not $flags.names.Contains($short)) { [void]$flags.names.Add($short) }
            }
            else { $flags.other++ }
        }
    }
    catch {
        $flags.error = $_.Exception.GetType().Name
    }
    return $flags
}

function Get-NodeRecord($Element, [int]$Depth, [int]$Index, [int]$ParentIndex) {
    $rec = [ordered]@{
        index = $Index
        parentIndex = $ParentIndex
        depth = $Depth
        controlType = $null
        automationId = $null
        automationIdLength = 0
        automationIdRedacted = $false
        className = $null
        classNameLength = 0
        classNameRedacted = $false
        frameworkId = $null
        frameworkIdLength = 0
        frameworkIdRedacted = $false
        processId = $null
        nativeWindowHandle = $null
        nameLength = 0
        nameLabel = $null
        nameRedacted = $false
        isEnabled = $null
        isOffscreen = $null
        isKeyboardFocusable = $null
        isPassword = $null
        width = $null
        height = $null
        supportsValue = $false
        supportsInvoke = $false
        supportsText = $false
        patterns = @()
        otherPatternCount = 0
        readError = $null
    }
    try {
        $cur = $Element.Current
        $ct = $null
        if ($cur.ControlType) { $ct = $cur.ControlType.ProgrammaticName }
        $rec.controlType = $ct
        $id = Get-SafeToken $cur.AutomationId 64
        $rec.automationId = $id.text
        $rec.automationIdLength = $id.length
        $rec.automationIdRedacted = $id.redacted
        $cls = Get-SafeToken $cur.ClassName 80
        $rec.className = $cls.text
        $rec.classNameLength = $cls.length
        $rec.classNameRedacted = $cls.redacted
        $fw = Get-SafeToken $cur.FrameworkId 32
        $rec.frameworkId = $fw.text
        $rec.frameworkIdLength = $fw.length
        $rec.frameworkIdRedacted = $fw.redacted
        $rec.processId = [int]$cur.ProcessId
        $rec.nativeWindowHandle = ('0x{0:X}' -f [int64]$cur.NativeWindowHandle)
        $name = $cur.Name
        $nameLen = 0
        if ($null -ne $name) { $nameLen = $name.Length }
        $rec.nameLength = $nameLen
        $label = Get-SafeLabel $name $ct
        if ($label) { $rec.nameLabel = $label }
        elseif ($nameLen -gt 0) { $rec.nameRedacted = $true }
        $rec.isEnabled = [bool]$cur.IsEnabled
        $rec.isOffscreen = [bool]$cur.IsOffscreen
        $rec.isKeyboardFocusable = [bool]$cur.IsKeyboardFocusable
        $rec.isPassword = [bool]$cur.IsPassword
        $b = $cur.BoundingRectangle
        if (-not [double]::IsNaN($b.Width) -and $b.Width -ge 0 -and $b.Width -le 10000) { $rec.width = [int]$b.Width }
        if (-not [double]::IsNaN($b.Height) -and $b.Height -ge 0 -and $b.Height -le 10000) { $rec.height = [int]$b.Height }
    }
    catch {
        $rec.readError = $_.Exception.GetType().Name
    }
    $flags = Get-PatternFlags $Element
    $rec.supportsValue = [bool]$flags.value
    $rec.supportsInvoke = [bool]$flags.invoke
    $rec.supportsText = [bool]$flags.text
    $rec.patterns = @($flags.names)
    $rec.otherPatternCount = [int]$flags.other
    if ($flags.error -and -not $rec.readError) { $rec.readError = $flags.error }
    return $rec
}

$report = New-Report 'WALK_STARTED' $false $null
try {
$report.apartmentState = [Threading.Thread]::CurrentThread.ApartmentState.ToString()
$report.powershellVersion = $PSVersionTable.PSVersion.ToString()

$procs = @(Get-Process -Name $ExpectedProcess -ErrorAction SilentlyContinue)
if ($procs.Count -eq 0) {
    $report.status = 'CLIENT_NOT_RUNNING'
    $report.detail = 'No process named LastWar is running.'
    Write-Report $report 0
}

foreach ($p in $procs) {
    $exeOk = $false
    $exeReadError = $null
    try {
        $file = $p.MainModule.FileName
        $exeOk = ([IO.Path]::GetFileName($file) -eq $ExpectedExe)
    }
    catch {
        $exeReadError = $_.Exception.GetType().Name
    }
    $report.processes += [ordered]@{
        processId = [int]$p.Id
        processName = $ExpectedProcess
        exeNameMatched = $exeOk
        exePathVerified = $exeOk
        exeReadError = $exeReadError
    }
}

$controlWalker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
$rawWalker = [System.Windows.Automation.TreeWalker]::RawViewWalker
$anyExact = $false
$sawEdit = $false
$sawInvokeButton = $false
$sawTextLike = $false
$anyTruncated = $false
$anyTimeout = $false
$successfulWalks = 0
$rootOnlyWalks = 0
$controlChildWalks = 0
$rawChildWalks = 0
$fromHandleFailed = 0

foreach ($p in $procs) {
    if ([DateTime]::UtcNow -gt $deadline) { $anyTimeout = $true; break }
    $rows = @()
    try { $rows = @([LwfTopWindows]::List([uint32]$p.Id)) } catch {
        $report.windows += [ordered]@{ processId = [int]$p.Id; enumError = $_.Exception.GetType().Name }
        continue
    }
    foreach ($row in $rows) {
        if ([DateTime]::UtcNow -gt $deadline) { $anyTimeout = $true; break }
        $parts = $row -split "`t", 4
        if ($parts.Count -lt 4) { continue }
        $hwnd = [int64]$parts[0]
        $visible = ($parts[1] -eq '1')
        $classInfo = Get-SafeToken $parts[2] 80
        $title = $parts[3]
        $titleLen = 0
        if ($null -ne $title) { $titleLen = $title.Length }
        $exact = ($title -ceq $ExpectedTitle)
        $win = [ordered]@{
            processId = [int]$p.Id
            hwnd = ('0x{0:X}' -f $hwnd)
            visible = $visible
            className = $classInfo.text
            classNameLength = $classInfo.length
            classNameRedacted = $classInfo.redacted
            titleExact = $exact
            titleLength = $titleLen
            walked = $false
        }
        if (-not $exact) {
            $report.windows += $win
            continue
        }
        $anyExact = $true
        $win.walked = $true
        $root = $null
        try { $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$hwnd) } catch { }
        if (-not $root) {
            $fromHandleFailed++
            $win.uiaError = 'FromHandleFailed'
            $report.windows += $win
            continue
        }
        $nodes = New-Object System.Collections.Generic.List[object]
        $hist = @{}
        $queue = New-Object System.Collections.Queue
        $queue.Enqueue(@{ El = $root; Depth = 0; Parent = -1 })
        $truncated = $false
        $editCount = 0
        $editValue = 0
        $editFocus = 0
        $invokeButtons = 0
        $textLike = 0
        $maxDepthSeen = 0
        while ($queue.Count -gt 0) {
            if ([DateTime]::UtcNow -gt $deadline) { $anyTimeout = $true; $truncated = $true; break }
            if ($nodes.Count -ge $MaxNodes) { $truncated = $true; break }
            $item = $queue.Dequeue()
            $depth = [int]$item.Depth
            if ($depth -gt $MaxDepth) { $truncated = $true; continue }
            if ($depth -gt $maxDepthSeen) { $maxDepthSeen = $depth }
            $index = $nodes.Count
            $rec = Get-NodeRecord $item.El $depth $index ([int]$item.Parent)
            [void]$nodes.Add($rec)
            if ($rec.controlType) {
                if (-not $hist.ContainsKey($rec.controlType)) { $hist[$rec.controlType] = 0 }
                $hist[$rec.controlType]++
            }
            if ($rec.controlType -eq 'ControlType.Edit') {
                $editCount++
                $sawEdit = $true
                if ($rec.supportsValue) { $editValue++ }
                if ($rec.isKeyboardFocusable) { $editFocus++ }
            }
            if (($rec.controlType -eq 'ControlType.Button' -or $rec.controlType -eq 'ControlType.SplitButton') -and $rec.supportsInvoke) {
                $invokeButtons++
                $sawInvokeButton = $true
            }
            $textTypes = @('ControlType.Text', 'ControlType.Header', 'ControlType.Document')
            if (($textTypes -contains $rec.controlType) -and $rec.nameLength -gt 0 -and $rec.depth -gt 0) {
                $textLike++
                $sawTextLike = $true
            }
            if ($depth -ge $MaxDepth) {
                try { if ($controlWalker.GetFirstChild($item.El)) { $truncated = $true } } catch { }
                continue
            }
            try {
                $child = $controlWalker.GetFirstChild($item.El)
                $guard = 0
                while ($child -and $guard -lt $MaxNodes) {
                    $guard++
                    if ($nodes.Count + $queue.Count -ge $MaxNodes) { $truncated = $true; break }
                    $queue.Enqueue(@{ El = $child; Depth = ($depth + 1); Parent = $index })
                    $child = $controlWalker.GetNextSibling($child)
                }
            }
            catch {
                $rec.readError = $_.Exception.GetType().Name
            }
        }
        $rawCount = 0
        $rawHist = @{}
        $rawCapped = $false
        try {
            $rawChild = $rawWalker.GetFirstChild($root)
            $rawGuard = 0
            while ($rawChild -and $rawGuard -lt 41) {
                $rawGuard++
                if ($rawCount -ge 40) { $rawCapped = $true; break }
                if ([DateTime]::UtcNow -gt $deadline) { $anyTimeout = $true; break }
                $rawCount++
                try {
                    $rct = $rawChild.Current.ControlType.ProgrammaticName
                    if (-not $rawHist.ContainsKey($rct)) { $rawHist[$rct] = 0 }
                    $rawHist[$rct]++
                } catch { }
                $rawChild = $rawWalker.GetNextSibling($rawChild)
            }
        } catch { }
        $successfulWalks++
        if ($nodes.Count -gt 1) { $controlChildWalks++ }
        if ($rawCount -gt 0) { $rawChildWalks++ }
        if ($nodes.Count -le 1 -and $rawCount -eq 0) { $rootOnlyWalks++ }
        if ($truncated) { $anyTruncated = $true }
        $rootHw = $null
        if ($nodes.Count -gt 0) { $rootHw = $nodes[0].nativeWindowHandle }
        $win.nodeCount = $nodes.Count
        $win.maxDepthSeen = $maxDepthSeen
        $win.truncated = $truncated
        $win.hwndMatchesRoot = ($rootHw -eq $win.hwnd)
        $win.controlTypeCounts = $hist
        $win.editCount = $editCount
        $win.editWithValuePattern = $editValue
        $win.editKeyboardFocusable = $editFocus
        $win.invokeButtonCount = $invokeButtons
        $win.textLikeNonemptyNameCount = $textLike
        $win.rawViewImmediateChildCount = $rawCount
        $win.rawViewImmediateCapped = $rawCapped
        $win.rawViewImmediateControlTypes = $rawHist
        $win.nodes = @($nodes)
        $report.windows += $win
    }
}

$report.truncated = $anyTruncated
$report.timedOut = $anyTimeout
$report.elapsedMs = [int]$started.ElapsedMilliseconds
if ($anyTimeout -and -not $anyExact) { $report.status = 'WALK_TIMEOUT' }
elseif (-not $anyExact) { $report.status = 'PROCESS_RUNNING_NO_EXACT_WINDOW' }
elseif ($anyTimeout) { $report.status = 'WALK_TIMEOUT' }
elseif ($successfulWalks -eq 0 -and $fromHandleFailed -gt 0) { $report.status = 'UIA_FROMHANDLE_FAILED' }
elseif ($anyTruncated -and -not ($sawEdit -and $sawInvokeButton -and $sawTextLike)) { $report.status = 'WALK_TRUNCATED' }
elseif ($rootOnlyWalks -gt 0 -and $controlChildWalks -eq 0 -and $rawChildWalks -eq 0) { $report.status = 'ONLY_UNITY_ROOT' }
elseif ($controlChildWalks -eq 0 -and $rawChildWalks -gt 0) { $report.status = 'CONTROL_VIEW_ROOT_ONLY_RAW_HAS_CHILDREN' }
elseif ($sawEdit -and $sawInvokeButton -and $sawTextLike) { $report.status = 'STRUCTURE_PRESENT_RECIPIENT_NOT_VERIFIED' }
elseif (-not $sawEdit) { $report.status = 'TREE_PRESENT_NO_EDIT' }
elseif (-not $sawInvokeButton) { $report.status = 'EDIT_PRESENT_NO_INVOKE_BUTTON' }
else { $report.status = 'EDIT_PRESENT_NO_TITLE_ELEMENT' }
$report.detail = 'recipientVerified is false. textLikeNonemptyNameCount ignores the game window title and does not reveal that text.'
Write-Report $report 0
}
catch {
    $report.status = 'WORKER_ERROR'
    $report.detail = $_.Exception.GetType().Name
    Write-Report $report 1
}
