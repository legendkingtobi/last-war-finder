#requires -Version 5.1
<#
  Read-only UI Automation diagnostic for the Last War PC client.

  Walks System.Windows.Automation under top-level windows whose process is
  LastWar.exe and whose title is exactly "Last War-Survival Game".
  It does not type, click, change focus, toggle Narrator, read process memory,
  inject code into the game, use the network, or read ValuePattern values.

  Window metadata (handle, visibility, class, title length, title match) is
  stored before any UI Automation call. Titles other than the exact expected
  title are not written out.

  Windows PowerShell 5.1 only (powershell.exe). The script starts its own STA
  worker and, on timeout, stops that worker only. It never stops LastWar.exe.

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Inspect-LastWarChatUia.ps1 -OutFile .\lastwar-uia-report.json
#>
param(
    [string]$OutFile = '',
    [int]$MaxNodes = 250,
    [int]$MaxDepth = 6,
    [int]$TimeoutSec = 15,
    [switch]$Worker,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$ExpectedTitle = 'Last War-Survival Game'
$ExpectedProcess = 'LastWar'
$ExpectedExe = 'LastWar.exe'
$ScriptVersion = 2

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
        tool                     = 'Inspect-LastWarChatUia'
        scriptVersion            = $ScriptVersion
        readOnly                 = $true
        actionsTaken             = @()
        generatedUtc             = [DateTime]::UtcNow.ToString('o')
        status                   = $Status
        detail                   = $Detail
        stage                    = 'init'
        recipientVerified        = $false
        disclaimer               = 'A nonempty Name is not recipient verification. ValuePattern values and message text were not read. Control presence does not identify the open chat.'
        limits                   = [ordered]@{ maxNodes = $MaxNodes; maxDepth = $MaxDepth; timeoutSec = $TimeoutSec }
        timedOut                 = $TimedOut
        truncated                = $false
        enumCompleted            = $false
        expectedProcess          = $ExpectedExe
        expectedTitle            = $ExpectedTitle
        processCount             = 0
        windowCount              = 0
        exactTitleCount          = 0
        exceptionType            = $null
        exceptionMessage         = $null
        exceptionMessageRedacted = $false
        scriptLine               = $null
        stack                    = @()
        processes                = @()
        windows                  = @()
    }
}

function Convert-ToObjectArray($Value) {
    # Windows PowerShell 5.1 can throw ArgumentException from @($genericList).
    # Index the collection instead, and keep a one-element result from unrolling.
    if ($null -eq $Value) { return ,@() }
    if ($Value -is [string]) {
        $one = New-Object object[] 1
        $one[0] = $Value
        return ,$one
    }
    $count = 0
    try { $count = [int]$Value.Count } catch { return ,@() }
    if ($count -lt 0) { $count = 0 }
    if ($count -gt 10000) { $count = 10000 }
    $arr = New-Object object[] $count
    for ($i = 0; $i -lt $count; $i++) { $arr[$i] = $Value[$i] }
    return ,$arr
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
    $quote = [char]34
    foreach ($ch in $Json.ToCharArray()) {
        if ($inString) {
            [void]$sb.Append($ch)
            if ($escape) { $escape = $false }
            elseif ($ch -eq '\') { $escape = $true }
            elseif ($ch -eq $quote) { $inString = $false }
            continue
        }
        if ($ch -eq $quote) {
            $inString = $true
            [void]$sb.Append($ch)
            continue
        }
        if ($ch -eq '{' -or $ch -eq '[') {
            [void]$sb.Append($ch)
            $indent++
            [void]$sb.Append("`r`n" + ('  ' * $indent))
            continue
        }
        if ($ch -eq '}' -or $ch -eq ']') {
            if ($indent -gt 0) { $indent-- }
            [void]$sb.Append("`r`n" + ('  ' * $indent) + $ch)
            continue
        }
        if ($ch -eq ',') {
            [void]$sb.Append($ch)
            [void]$sb.Append("`r`n" + ('  ' * $indent))
            continue
        }
        if ($ch -eq ':') {
            [void]$sb.Append(': ')
            continue
        }
        if ($ch -eq ' ' -or $ch -eq "`r" -or $ch -eq "`n" -or $ch -eq "`t") { continue }
        [void]$sb.Append($ch)
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
            throw 'Output directory does not exist.'
        }
        [System.IO.File]::WriteAllText($OutFile, $json, (New-Object System.Text.UTF8Encoding $false))
    }
    else {
        [Console]::Out.Write($json)
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

function Test-SafeExceptionWord([string]$Word) {
    $allowed = @(
        'a', 'added', 'already', 'an', 'and', 'argument', 'array', 'be', 'cannot', 'capacity',
        'collection', 'destination', 'does', 'enough', 'expected', 'fall', 'fixed', 'has',
        'index', 'instance', 'into', 'item', 'key', 'less', 'long', 'must', 'name', 'negative',
        'non', 'not', 'null', 'object', 'of', 'out', 'parameter', 'range', 'reference', 'same',
        'set', 'size', 'specified', 'than', 'the', 'to', 'valid', 'value', 'values', 'was',
        'were', 'with', 'within'
    )
    foreach ($item in $allowed) {
        if ([string]::Equals($Word, $item, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-SafeExceptionMessage([string]$Message) {
    $result = [ordered]@{ text = $null; redacted = $false; length = 0 }
    if ([string]::IsNullOrEmpty($Message)) { return $result }
    $result.length = $Message.Length
    $flat = ([regex]::Replace($Message, '[\r\n\t]+', ' ')).Trim()
    $flat = [regex]::Replace($flat, '"[^"]*"', '')
    $flat = [regex]::Replace($flat, "'[^']*'", '')
    $flat = ([regex]::Replace($flat, ' +', ' ')).Trim()
    if ($flat.Length -eq 0 -or $flat.Length -gt 160) { $result.redacted = $true; return $result }
    if ($flat -notmatch '^[A-Za-z0-9_ .:()=,+\-]+$') { $result.redacted = $true; return $result }
    $words = $flat.Split(@(' '), [System.StringSplitOptions]::RemoveEmptyEntries)
    foreach ($word in $words) {
        $clean = $word.Trim('.', ',', ':', '(', ')', '=', '+', '-')
        if ($clean.Length -eq 0) { continue }
        if (-not (Test-SafeExceptionWord $clean)) { $result.redacted = $true; return $result }
    }
    $result.text = $flat
    return $result
}

function Get-SafeStack([string]$Stack) {
    $frames = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrEmpty($Stack)) { return ,$frames }
    foreach ($line in ([regex]::Split($Stack, '\r?\n'))) {
        $name = $null
        $number = $null
        if ($line -match 'at\s+(.+?),\s+.*:\s+line\s+(\d+)') {
            $name = $Matches[1].Trim()
            $number = $Matches[2]
        }
        elseif ($line -match ':\s+line\s+(\d+)') {
            $name = 'script'
            $number = $Matches[1]
        }
        if ($number -and $name -match '^[A-Za-z0-9_<>\-]+$') {
            [void]$frames.Add(('{0}:{1}' -f $name, $number))
        }
        if ($frames.Count -ge 8) { break }
    }
    return ,$frames
}

function Set-ErrorFields($Report, $ErrorRecord, [string]$Stage) {
    $Report.stage = $Stage
    $Report.status = 'WORKER_ERROR'
    $typeName = 'Exception'
    $message = $null
    $line = $null
    $stackText = $null
    if ($ErrorRecord) {
        if ($ErrorRecord.Exception) {
            $typeName = $ErrorRecord.Exception.GetType().Name
            $message = $ErrorRecord.Exception.Message
        }
        try { $line = $ErrorRecord.InvocationInfo.ScriptLineNumber } catch { $line = $null }
        try { $stackText = $ErrorRecord.ScriptStackTrace } catch { $stackText = $null }
    }
    $safe = Get-SafeExceptionMessage $message
    $Report.exceptionType = $typeName
    $Report.exceptionMessage = $safe.text
    $Report.exceptionMessageRedacted = [bool]$safe.redacted
    $Report.scriptLine = $line
    $Report.stack = Convert-ToObjectArray (Get-SafeStack $stackText)
    $shown = $typeName
    if ($safe.text) { $shown = $shown + ': ' + $safe.text }
    elseif ($safe.redacted) { $shown = $shown + ': message redacted' }
    $Report.detail = ('stage={0}; {1}; line={2}' -f $Stage, $shown, $line)
}

function Hide-InternalFields($WindowItems) {
    $wins = Convert-ToObjectArray $WindowItems
    foreach ($win in $wins) {
        try { [void]$win.Remove('hwndValue') } catch { }
    }
}

function Update-Counts($Report, $ProcessItems, $WindowItems) {
    $procs = Convert-ToObjectArray $ProcessItems
    $wins = Convert-ToObjectArray $WindowItems
    $Report.processes = $procs
    $Report.windows = $wins
    $Report.processCount = $procs.Count
    $Report.windowCount = $wins.Count
    $exact = 0
    foreach ($win in $wins) {
        if ($win.titleExact) { $exact++ }
    }
    $Report.exactTitleCount = $exact
}

function Invoke-SelfTest {
    $report = New-Report 'SELF_TEST' $false $null
    $empty = New-Object 'System.Collections.Generic.List[string]'
    $one = New-Object 'System.Collections.Generic.List[string]'
    [void]$one.Add('row-one')
    $emptyCopy = Convert-ToObjectArray $empty
    $oneCopy = Convert-ToObjectArray $one
    $legacy = 'ok'
    try { $null = @($empty) } catch { $legacy = $_.Exception.GetType().Name }
    $sample = '{"generatedUtc":"2026-11-07T11:30:52.1350443Z","status":"OK"}'
    $pretty = Format-JsonText $sample
    if ($pretty -notmatch '11:30:52\.1350443Z') { throw 'Format-JsonText changed a timestamp inside a string.' }
    $safe = Get-SafeExceptionMessage 'Specified argument was out of the range of valid values. Parameter name: index'
    $hidden = 'player said "SHOULD_NOT_APPEAR_TITLE" hello'
    $redacted = Get-SafeExceptionMessage $hidden
    if ($redacted.text) { throw 'Exception sanitizer kept a non-framework message.' }
    $stack = Get-SafeStack "at Get-NodeRecord, C:\Users\example\Inspect-LastWarChatUia.ps1: line 12`r`nat <ScriptBlock>, C:\Users\example\secret\Inspect-LastWarChatUia.ps1: line 40"
    $copiedStack = Convert-ToObjectArray $stack
    $joined = $copiedStack -join ','
    if ($joined -match 'Users|secret|:\\') { throw 'Stack sanitizer kept a path.' }
    if ($joined -notmatch 'Get-NodeRecord:12') { throw ('Stack sanitizer dropped the script line. joined=' + $joined) }
    $report.stage = 'self-test'
    $report.status = 'SELF_TEST_OK'
    $report.detail = ('empty={0}; one={1}; legacyWrap={2}; safeMessage={3}; redacted={4}' -f $emptyCopy.Count, $oneCopy.Count, $legacy, [bool]$safe.text, [bool]$redacted.redacted)
    $report.exceptionMessage = $safe.text
    $report.stack = Convert-ToObjectArray $stack
    if ($emptyCopy.Count -ne 0 -or $oneCopy.Count -ne 1) { throw 'List copy failed.' }
    Write-Report $report 0
}

if ($SelfTest) { Invoke-SelfTest }

if (-not $Worker) {
    if ($env:OS -ne 'Windows_NT') {
        $report = New-Report 'NOT_WINDOWS' $false 'Run this script on Windows PowerShell 5.1 on the PC where Last War is open.'
        Write-Report $report 5
    }
    if ($OutFile -and $OutFile -notmatch '(?i)\.json$') { throw 'OutFile must end with .json' }
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
        $report.stage = 'parent-timeout'
        Write-Report $report 4
    }
    $stdout = ''
    $stderr = ''
    try { $stdout = $outTask.Result } catch { $stdout = '' }
    try { $stderr = $errTask.Result } catch { $stderr = '' }
    if ([string]::IsNullOrWhiteSpace($stdout)) {
        $tail = ''
        if ($stderr) {
            $flat = ([regex]::Replace($stderr, '[\r\n\t]+', ' ')).Trim()
            $safeTail = Get-SafeExceptionMessage $flat
            if ($safeTail.text) { $tail = $safeTail.text } else { $tail = 'worker stderr redacted' }
        }
        $report = New-Report 'WORKER_NO_OUTPUT' $false $tail
        Write-Report $report 1
    }
    if ($OutFile) {
        $parent = Split-Path -Parent $OutFile
        if ($parent -and -not (Test-Path -LiteralPath $parent)) { throw 'Output directory does not exist.' }
        [System.IO.File]::WriteAllText($OutFile, $stdout, (New-Object System.Text.UTF8Encoding $false))
    }
    else { [Console]::Out.Write($stdout) }
    if ($stdout -match '"status"\s*:\s*"([A-Z0-9_]+)"') { Write-Host ('status=' + $Matches[1] + ' recipientVerified=false') }
    exit $proc.ExitCode
}

$script:Stage = 'worker-start'
$started = [Diagnostics.Stopwatch]::StartNew()
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
$report = New-Report 'WALK_STARTED' $false $null
$processItems = New-Object System.Collections.Generic.List[object]
$windowItems = New-Object System.Collections.Generic.List[object]

function Sync-Report {
    Update-Counts $report $processItems $windowItems
    $report.stage = $script:Stage
    $report.elapsedMs = [int]$started.ElapsedMilliseconds
}

try {
    $script:Stage = 'uia-assembly'
    Sync-Report
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $report.apartmentState = [Threading.Thread]::CurrentThread.ApartmentState.ToString()
    $report.powershellVersion = $PSVersionTable.PSVersion.ToString()

    if (-not ('LwfTopWindows' -as [type])) {
        $script:Stage = 'window-enum-type'
        Sync-Report
        Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class LwfTopWindows {
    delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    static EnumProc keepAlive;
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hWnd, StringBuilder sb, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    static bool SafeToken(string value) {
        if (string.IsNullOrEmpty(value) || value.Length > 80) return false;
        for (int i = 0; i < value.Length; i++) {
            char c = value[i];
            bool ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '.' || c == ':' || c == '-';
            if (i == 0 && (c >= '0' && c <= '9')) return false;
            if (!ok) return false;
        }
        return true;
    }
    public static string[] Describe(uint pid, string expectedTitle) {
        var rows = new List<string>();
        int skipped = 0;
        keepAlive = delegate (IntPtr h, IntPtr l) {
            try {
                uint op;
                GetWindowThreadProcessId(h, out op);
                if (op != pid) return true;
                var title = new StringBuilder(512);
                var cls = new StringBuilder(256);
                int titleN = GetWindowText(h, title, title.Capacity);
                int classN = GetClassName(h, cls, cls.Capacity);
                if (titleN < 0) titleN = 0;
                if (classN < 0) classN = 0;
                string titleText = title.ToString();
                string classText = cls.ToString();
                bool exact = expectedTitle != null && string.Equals(titleText, expectedTitle, StringComparison.Ordinal);
                bool capped = titleN >= title.Capacity - 1;
                string classToken = SafeToken(classText) ? classText : "";
                rows.Add(h.ToInt64().ToString() + "\t" + (IsWindowVisible(h) ? "1" : "0") + "\t" + (exact ? "1" : "0") + "\t" + titleN.ToString() + "\t" + (capped ? "1" : "0") + "\t" + classText.Length.ToString() + "\t" + classToken);
            }
            catch { skipped++; }
            return true;
        };
        EnumWindows(keepAlive, IntPtr.Zero);
        rows.Add("META\t" + skipped.ToString());
        return rows.ToArray();
    }
}
'@
    }

    $script:Stage = 'process-list'
    Sync-Report
    $found = Get-Process -Name $ExpectedProcess -ErrorAction SilentlyContinue
    if ($null -eq $found) {
        $report.status = 'CLIENT_NOT_RUNNING'
        $report.detail = 'No process named LastWar is running.'
        $script:Stage = 'complete'
        Sync-Report
        Write-Report $report 0
    }
    if ($found -is [System.Diagnostics.Process]) { [void]$processItems.Add($found) }
    else {
        $procArray = Convert-ToObjectArray $found
        foreach ($item in $procArray) { if ($item -is [System.Diagnostics.Process]) { [void]$processItems.Add($item) } }
    }
    $procSnapshot = Convert-ToObjectArray $processItems
    foreach ($p in $procSnapshot) {
        $exeOk = $false
        $exeReadError = $null
        try {
            $file = $p.MainModule.FileName
            $exeOk = ([IO.Path]::GetFileName($file) -eq $ExpectedExe)
        }
        catch { $exeReadError = $_.Exception.GetType().Name }
        $index = $processItems.IndexOf($p)
        $processItems[$index] = [ordered]@{
            processId = [int]$p.Id
            processName = $ExpectedProcess
            exeNameMatched = $exeOk
            exePathVerified = $exeOk
            exeReadError = $exeReadError
        }
    }
    Sync-Report
    if ($processItems.Count -eq 0) {
        $report.status = 'CLIENT_NOT_RUNNING'
        $report.detail = 'No process named LastWar is running.'
        $script:Stage = 'complete'
        Sync-Report
        Write-Report $report 0
    }

    $script:Stage = 'window-enum'
    Sync-Report
    $enumSkipped = 0
    $procForWindows = Convert-ToObjectArray $processItems
    foreach ($p in $procForWindows) {
        if ([DateTime]::UtcNow -gt $deadline) { $report.timedOut = $true; break }
        $described = [LwfTopWindows]::Describe([uint32]$p.processId, $ExpectedTitle)
        $rows = Convert-ToObjectArray $described
        foreach ($row in $rows) {
            if ($row -isnot [string]) { continue }
            if ($row.StartsWith('META' + "`t")) {
                $meta = $row.Split("`t")
                if ($meta.Length -ge 2) { $enumSkipped += [int]$meta[1] }
                continue
            }
            $parts = $row.Split("`t")
            if ($parts.Length -lt 7) { continue }
            $hwnd = [int64]$parts[0]
            $classToken = $parts[6]
            $classInfo = Get-SafeToken $classToken 80
            [void]$windowItems.Add([ordered]@{
                processId = [int]$p.processId
                hwnd = ('0x{0:X}' -f $hwnd)
                hwndValue = $hwnd
                visible = ($parts[1] -eq '1')
                className = $classInfo.text
                classNameLength = [int]$parts[5]
                classNameRedacted = ($classInfo.redacted -or ($classInfo.length -eq 0 -and [int]$parts[5] -gt 0))
                titleExact = ($parts[2] -eq '1')
                titleLength = [int]$parts[3]
                titleLengthCapped = ($parts[4] -eq '1')
                walked = $false
            })
        }
    }
    $report.enumCompleted = -not $report.timedOut
    $report.enumSkipped = $enumSkipped
    Sync-Report

    if ($report.timedOut) {
        $report.status = 'WALK_TIMEOUT'
        $report.detail = 'Timed out while enumerating top-level windows. Listed windows are metadata only.'
        $script:Stage = 'complete'
        Hide-InternalFields $windowItems
        Sync-Report
        Write-Report $report 0
    }

    $script:Stage = 'uia-walker'
    Sync-Report
    $controlWalker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $rawWalker = [System.Windows.Automation.TreeWalker]::RawViewWalker
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
    $walkErrors = 0

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
                if ($short -and -not $flags.names.Contains($short)) { [void]$flags.names.Add($short) }
                elseif (-not $short) { $flags.other++ }
            }
        }
        catch { $flags.error = $_.Exception.GetType().Name }
        return $flags
    }

    function Get-NodeRecord($Element, [int]$Depth, [int]$Index, [int]$ParentIndex) {
        $rec = [ordered]@{
            index = $Index; parentIndex = $ParentIndex; depth = $Depth; controlType = $null
            automationId = $null; automationIdLength = 0; automationIdRedacted = $false
            className = $null; classNameLength = 0; classNameRedacted = $false
            frameworkId = $null; frameworkIdLength = 0; frameworkIdRedacted = $false
            processId = $null; nativeWindowHandle = $null; nameLength = 0; nameLabel = $null; nameRedacted = $false
            isEnabled = $null; isOffscreen = $null; isKeyboardFocusable = $null; isPassword = $null
            width = $null; height = $null; supportsValue = $false; supportsInvoke = $false; supportsText = $false
            patterns = @(); otherPatternCount = 0; readError = $null
        }
        try {
            $cur = $Element.Current
            $ct = $null
            if ($cur.ControlType) { $ct = $cur.ControlType.ProgrammaticName }
            $rec.controlType = $ct
            $id = Get-SafeToken ([string]$cur.AutomationId) 64
            $rec.automationId = $id.text; $rec.automationIdLength = $id.length; $rec.automationIdRedacted = $id.redacted
            $cls = Get-SafeToken ([string]$cur.ClassName) 80
            $rec.className = $cls.text; $rec.classNameLength = $cls.length; $rec.classNameRedacted = $cls.redacted
            $fw = Get-SafeToken ([string]$cur.FrameworkId) 32
            $rec.frameworkId = $fw.text; $rec.frameworkIdLength = $fw.length; $rec.frameworkIdRedacted = $fw.redacted
            $rec.processId = [int]$cur.ProcessId
            $rec.nativeWindowHandle = ('0x{0:X}' -f [int64]$cur.NativeWindowHandle)
            $name = [string]$cur.Name
            $nameLen = 0
            if ($null -ne $name) { $nameLen = $name.Length }
            $rec.nameLength = $nameLen
            $label = Get-SafeLabel $name $ct
            if ($label) { $rec.nameLabel = $label } elseif ($nameLen -gt 0) { $rec.nameRedacted = $true }
            $rec.isEnabled = [bool]$cur.IsEnabled
            $rec.isOffscreen = [bool]$cur.IsOffscreen
            $rec.isKeyboardFocusable = [bool]$cur.IsKeyboardFocusable
            $rec.isPassword = [bool]$cur.IsPassword
            $b = $cur.BoundingRectangle
            if (-not [double]::IsNaN($b.Width) -and $b.Width -ge 0 -and $b.Width -le 10000) { $rec.width = [int]$b.Width }
            if (-not [double]::IsNaN($b.Height) -and $b.Height -ge 0 -and $b.Height -le 10000) { $rec.height = [int]$b.Height }
        }
        catch { $rec.readError = $_.Exception.GetType().Name }
        $flags = Get-PatternFlags $Element
        $rec.supportsValue = [bool]$flags.value
        $rec.supportsInvoke = [bool]$flags.invoke
        $rec.supportsText = [bool]$flags.text
        $rec.patterns = Convert-ToObjectArray $flags.names
        $rec.otherPatternCount = [int]$flags.other
        if ($flags.error -and -not $rec.readError) { $rec.readError = $flags.error }
        return $rec
    }

    for ($w = 0; $w -lt $windowItems.Count; $w++) {
        $win = $windowItems[$w]
        if (-not $win.titleExact) { continue }
        if ([DateTime]::UtcNow -gt $deadline) { $anyTimeout = $true; break }
        $script:Stage = 'uia-window'
        Sync-Report
        try {
            $root = $null
            try { $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]([int64]$win.hwndValue)) } catch { $root = $null }
            if (-not $root) {
                $fromHandleFailed++
                $win.uiaError = 'FromHandleFailed'
                $win.walked = $false
                continue
            }
            $nodes = New-Object System.Collections.Generic.List[object]
            $hist = @{}
            $pending = New-Object System.Collections.Generic.List[object]
            [void]$pending.Add(@{ El = $root; Depth = 0; Parent = -1 })
            $cursor = 0
            $truncated = $false
            $editCount = 0
            $editValue = 0
            $editFocus = 0
            $invokeButtons = 0
            $textLike = 0
            $maxDepthSeen = 0
            while ($cursor -lt $pending.Count) {
                if ([DateTime]::UtcNow -gt $deadline) { $anyTimeout = $true; $truncated = $true; break }
                if ($nodes.Count -ge $MaxNodes) { $truncated = $true; break }
                $item = $pending[$cursor]
                $cursor++
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
                        if ($nodes.Count + $pending.Count -ge ($MaxNodes + 20)) { $truncated = $true; break }
                        [void]$pending.Add(@{ El = $child; Depth = ($depth + 1); Parent = $index })
                        $child = $controlWalker.GetNextSibling($child)
                    }
                }
                catch { $rec.readError = $_.Exception.GetType().Name }
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
            $win.walked = $true
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
            $win.nodes = Convert-ToObjectArray $nodes
        }
        catch {
            $walkErrors++
            $safe = Get-SafeExceptionMessage $_.Exception.Message
            $win.walked = $false
            $win.walkError = $_.Exception.GetType().Name
            $win.walkLine = $_.InvocationInfo.ScriptLineNumber
            $win.walkMessage = $safe.text
            $win.walkMessageRedacted = [bool]$safe.redacted
            $win.walkStack = Convert-ToObjectArray (Get-SafeStack $_.ScriptStackTrace)
        }
        finally {
            $win.Remove('hwndValue')
        }
    }

    $report.truncated = $anyTruncated
    $report.timedOut = $anyTimeout
    $report.walkErrors = $walkErrors
    $exactCount = 0
    $finalWindows = Convert-ToObjectArray $windowItems
    foreach ($win in $finalWindows) { if ($win.titleExact) { $exactCount++ } }
    if ($anyTimeout -and $exactCount -eq 0) { $report.status = 'WALK_TIMEOUT' }
    elseif ($exactCount -eq 0) { $report.status = 'PROCESS_RUNNING_NO_EXACT_WINDOW' }
    elseif ($anyTimeout) { $report.status = 'WALK_TIMEOUT' }
    elseif ($walkErrors -gt 0 -and $successfulWalks -eq 0) { $report.status = 'WALK_ERROR' }
    elseif ($successfulWalks -eq 0 -and $fromHandleFailed -gt 0) { $report.status = 'UIA_FROMHANDLE_FAILED' }
    elseif ($anyTruncated -and -not ($sawEdit -and $sawInvokeButton -and $sawTextLike)) { $report.status = 'WALK_TRUNCATED' }
    elseif ($rootOnlyWalks -gt 0 -and $controlChildWalks -eq 0 -and $rawChildWalks -eq 0) { $report.status = 'ONLY_UNITY_ROOT' }
    elseif ($controlChildWalks -eq 0 -and $rawChildWalks -gt 0) { $report.status = 'CONTROL_VIEW_ROOT_ONLY_RAW_HAS_CHILDREN' }
    elseif ($sawEdit -and $sawInvokeButton -and $sawTextLike) { $report.status = 'STRUCTURE_PRESENT_RECIPIENT_NOT_VERIFIED' }
    elseif (-not $sawEdit) { $report.status = 'TREE_PRESENT_NO_EDIT' }
    elseif (-not $sawInvokeButton) { $report.status = 'EDIT_PRESENT_NO_INVOKE_BUTTON' }
    else { $report.status = 'EDIT_PRESENT_NO_TITLE_ELEMENT' }
    $report.detail = 'recipientVerified is false. titleExact is a boolean. textLikeNonemptyNameCount does not reveal text.'
    $script:Stage = 'complete'
    Hide-InternalFields $windowItems
    Sync-Report
    Write-Report $report 0
}
catch {
    Hide-InternalFields $windowItems
    Sync-Report
    Set-ErrorFields $report $_ $script:Stage
    try { Write-Report $report 1 }
    catch {
        $fallback = '{"tool":"Inspect-LastWarChatUia","scriptVersion":2,"status":"WORKER_ERROR","stage":"serialize","recipientVerified":false,"exceptionType":"SerializeFailed"}'
        [Console]::Out.Write($fallback)
        exit 1
    }
}
