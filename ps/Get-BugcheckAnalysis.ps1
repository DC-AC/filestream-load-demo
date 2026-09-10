<#
.SYNOPSIS
    Runs !analyze -v against the most recent crash dump and reports the
    faulting driver.

.DESCRIPTION
    Get-CrashEvidence.ps1 establishes THAT a bugcheck happened and what the
    code was. This establishes WHICH driver did it, which is the only thing
    that turns a bugcheck into an actionable finding.

    Needs the Debugging Tools for Windows. If they are not present:

        winget install --id Microsoft.WinDbg

    or install the "Debugging Tools for Windows" feature from the Windows SDK.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\ps\Get-BugcheckAnalysis.ps1
#>
[CmdletBinding()]
param(
    [string] $DumpPath,
    [string] $SymbolPath = 'srv*C:\symbols*https://msdl.microsoft.com/download/symbols',
    [string] $OutputFile,
    [switch] $InstallDebugger,
    # Path to an already-downloaded winsdksetup.exe. Installs ONLY the
    # debuggers -- no other SDK component. winget is not present on Windows
    # Server by default, so this is the practical route there.
    [string] $SdkSetupPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
Import-Module (Join-Path $ScriptDir 'FsPoc.Common.psm1') -Force

# ---------------------------------------------------------------------------
# Find a dump. Prefer the newest minidump: it analyses in seconds where a
# multi-gigabyte kernel dump takes minutes, and !analyze -v reports the same
# faulting module from either.
# ---------------------------------------------------------------------------
if (-not $DumpPath) {
    $candidates = @()
    if (Test-Path 'C:\Windows\Minidump') {
        $candidates += @(Get-ChildItem 'C:\Windows\Minidump' -Filter *.dmp -ErrorAction SilentlyContinue)
    }
    if ($candidates.Count -eq 0 -and (Test-Path 'C:\Windows\MEMORY.DMP')) {
        $candidates += Get-Item 'C:\Windows\MEMORY.DMP'
    }
    if ($candidates.Count -eq 0) { throw 'No crash dump found under C:\Windows\Minidump or C:\Windows\MEMORY.DMP.' }
    $DumpPath = ($candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}
if (-not (Test-Path -LiteralPath $DumpPath)) { throw "Dump not found: $DumpPath" }

$dump = Get-Item -LiteralPath $DumpPath
Write-FsPocLog ("Analysing {0} ({1}, written {2})" -f $dump.FullName, (Format-FsPocBytes $dump.Length), $dump.LastWriteTime) 'STEP'

# ---------------------------------------------------------------------------
# Find a debugger
# ---------------------------------------------------------------------------
function Find-Debugger {
    # Fixed SDK locations first -- much the most common.
    foreach ($p in @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64\cdb.exe"
        "$env:ProgramFiles\Windows Kits\10\Debuggers\x64\cdb.exe"
        "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64\kd.exe"
        "$env:ProgramFiles\Windows Kits\10\Debuggers\x64\kd.exe"
    )) { if (Test-Path -LiteralPath $p) { return $p } }

    # Anything already on PATH.
    $cmd = Get-Command cdb.exe, kd.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }

    # The modern WinDbg ships as an MSIX. WindowsApps is ACL-restricted even
    # for administrators, so this may legitimately find nothing.
    foreach ($root in @("$env:ProgramFiles\WindowsApps", "$env:LOCALAPPDATA\Microsoft\WindowsApps")) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $hit = Get-ChildItem -LiteralPath $root -Filter 'cdb.exe' -Recurse -Depth 4 -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }

    # Any other Windows Kits layout.
    foreach ($root in @("${env:ProgramFiles(x86)}\Windows Kits", "$env:ProgramFiles\Windows Kits")) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $hit = Get-ChildItem -LiteralPath $root -Filter 'cdb.exe' -Recurse -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

$debugger = Find-Debugger

if (-not $debugger -and $SdkSetupPath) {
    if (-not (Test-Path -LiteralPath $SdkSetupPath)) { throw "winsdksetup.exe not found at $SdkSetupPath" }
    Write-FsPocLog 'Installing ONLY the Debugging Tools from the Windows SDK...' 'STEP'
    Write-FsPocLog 'No other SDK component is installed. This takes a couple of minutes.' 'INFO'
    & $SdkSetupPath /features OptionId.WindowsDesktopDebuggers /quiet /norestart | Out-Null
    Write-FsPocLog 'Re-scanning for a command-line debugger...' 'INFO'
    $debugger = Find-Debugger
}
elseif (-not $debugger -and $InstallDebugger) {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        Write-FsPocLog 'winget is not present. It does not ship with Windows Server -- use -SdkSetupPath instead.' 'WARN'
    }
    else {
        Write-FsPocLog 'Installing the Debugging Tools via winget...' 'STEP'
        & winget.exe install --id Microsoft.WinDbg --accept-source-agreements --accept-package-agreements --silent
        $debugger = Find-Debugger
        if (-not $debugger) {
            Write-FsPocLog 'winget completed but no cdb.exe/kd.exe appeared. Use -SdkSetupPath instead.' 'WARN'
        }
    }
}

if (-not $debugger) {
    Write-FsPocLog 'No command-line debugger (cdb.exe / kd.exe) found.' 'ERROR'
    Write-Host ''
    Write-Host '  Options, easiest first:' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  1. Install ONLY the debuggers from the Windows SDK. winget does not ship' -ForegroundColor White
    Write-Host '     with Windows Server, so this is the practical route there. One' -ForegroundColor White
    Write-Host '     download, one command, no other SDK component installed:' -ForegroundColor White
    Write-Host '         a) Download winsdksetup.exe from' -ForegroundColor Gray
    Write-Host '            https://developer.microsoft.com/windows/downloads/windows-sdk' -ForegroundColor Gray
    Write-Host '         b) .\Get-BugcheckAnalysis.ps1 -SdkSetupPath C:\Temp\winsdksetup.exe' -ForegroundColor Gray
    Write-Host '            (or run it directly:' -ForegroundColor Gray
    Write-Host '             winsdksetup.exe /features OptionId.WindowsDesktopDebuggers /quiet /norestart)' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  2. On a client OS with winget: re-run with -InstallDebugger.' -ForegroundColor White
    Write-Host ''
    Write-Host '  3. Copy the minidump to any machine that already has WinDbg, open it,' -ForegroundColor White
    Write-Host '     and run !analyze -v. It is under 1 MB and contains no user data' -ForegroundColor White
    Write-Host '     beyond kernel state:' -ForegroundColor White
    Write-Host ("         {0}" -f $dump.FullName) -ForegroundColor Gray
    Write-Host ''
    Write-Host '  You do NOT need this to make progress. Only two minifilters are' -ForegroundColor Yellow
    Write-Host '  attached to the FILESTREAM volume, so excluding the container from' -ForegroundColor Yellow
    Write-Host '  Defender and retrying discriminates between them by itself:' -ForegroundColor Yellow
    Write-Host '    - crash stops  -> it was the Defender/RsFx interaction' -ForegroundColor Gray
    Write-Host '    - crash repeats -> RsFx alone; apply the latest CU and open a case' -ForegroundColor Gray
    return
}
Write-FsPocLog "Debugger: $debugger" 'OK'

# ---------------------------------------------------------------------------
$log = if ($OutputFile) { $OutputFile } else { Join-Path $env:TEMP ("bugcheck_{0}.txt" -f $dump.BaseName) }
$env:_NT_SYMBOL_PATH = $SymbolPath
Write-FsPocLog "Symbols: $SymbolPath" 'INFO'
Write-FsPocLog 'Running !analyze -v (first run downloads symbols and can take several minutes)...' 'STEP'

& $debugger -z $dump.FullName -c '!analyze -v; lm kv; q' -logo $log 2>&1 | Out-Null

if (-not (Test-Path -LiteralPath $log)) { Write-FsPocLog 'The debugger produced no log.' 'ERROR'; return }
$text = Get-Content -LiteralPath $log -Raw

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== Verdict ===' -ForegroundColor Cyan
$fields = 'BUGCHECK_CODE', 'BUGCHECK_P1', 'MODULE_NAME', 'IMAGE_NAME', 'FAILURE_BUCKET_ID',
          'PROCESS_NAME', 'FAILURE_ID_HASH_STRING', 'STACK_COMMAND', 'DEFAULT_BUCKET_ID'
foreach ($f in $fields) {
    # ${f} not $f -- "$f:" parses as a scope-qualified variable reference.
    $m = [regex]::Match($text, "(?m)^${f}:\s*(.+)$")
    if ($m.Success) { Write-Host ("  {0,-24} {1}" -f $f, $m.Groups[1].Value.Trim()) -ForegroundColor White }
}

<#  MODULE_NAME is an attribution, not a diagnosis.

    !analyze blames the driver that owns the IRP, which for a completion-path
    fault is often several frames below the code that actually faulted. The
    stack is the evidence, so it is what gets classified here. Getting this
    wrong is not harmless: an earlier version of this script read MODULE_NAME
    alone and told the user that disk.sys might be a third-party filter driver
    they should exclude. disk.sys is an inbox Microsoft driver.
#>
$culprit = [regex]::Match($text, "(?m)^MODULE_NAME:\s*(\S+)")
$mod = if ($culprit.Success) { $culprit.Groups[1].Value } else { '(unknown)' }

$inbox = @('nt', 'ntoskrnl', 'Ntfs', 'disk', 'storport', 'CLASSPNP', 'partmgr',
           'volmgr', 'volsnap', 'fileinfo', 'FltMgr', 'storahci', 'stornvme')

Write-Host ''
Write-Host '=== What the stack says ===' -ForegroundColor Cyan

if ($text -match 'Ntfs!.*IoPerf' -or $text -match 'FsLibIoPerf') {
    Write-Host '  The fault is in NTFS I/O performance telemetry, on an I/O completion path.' -ForegroundColor Yellow
    Write-Host '  NtfsIoPerf* / FsLibIoPerf* run when NTFS records a high-latency I/O; the' -ForegroundColor Gray
    Write-Host '  reference count went bad while posting file-object info for that record.' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  This is a Windows NTFS defect, not FILESTREAM, not antivirus, and not' -ForegroundColor Yellow
    Write-Host '  the workload. A user-mode program cannot corrupt a kernel object' -ForegroundColor Yellow
    Write-Host '  reference count; it can only issue I/O that reaches the defective path.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  What to do:' -ForegroundColor White
    Write-Host '    1. Apply the latest cumulative update for this Windows build.' -ForegroundColor Gray
    Write-Host '    2. Open a Microsoft support case with this dump. The signature is' -ForegroundColor Gray
    Write-Host '       specific enough to be actionable.' -ForegroundColor Gray
    Write-Host '    3. To reduce how often the path is reached, reduce high-latency I/O:' -ForegroundColor Gray
    Write-Host '       a faster disk tier, or fewer durability flushes by batching more' -ForegroundColor Gray
    Write-Host '       files per transaction. Neither fixes the defect.' -ForegroundColor Gray
}
elseif ($text -match 'RsFx') {
    Write-Host "  The FILESTREAM filter driver (RsFx) is on the stack. This is a SQL Server" -ForegroundColor Yellow
    Write-Host '  driver defect. Apply the latest SQL Server cumulative update, and open a' -ForegroundColor Yellow
    Write-Host '  Microsoft support case with this dump if it persists.' -ForegroundColor Yellow
}
elseif ($text -match 'WdFilter') {
    Write-Host "  Windows Defender's minifilter (WdFilter) is on the stack. Exclude the" -ForegroundColor Yellow
    Write-Host '  FILESTREAM container and sqlservr.exe and retry.' -ForegroundColor Yellow
}
elseif ($inbox -contains $mod) {
    Write-Host ("  Faulting module: {0} -- an inbox Microsoft driver, NOT third party." -f $mod) -ForegroundColor Yellow
    Write-Host '  There is nothing to uninstall or exclude. Apply the latest cumulative' -ForegroundColor Gray
    Write-Host '  update and open a support case with this dump.' -ForegroundColor Gray
}
else {
    Write-Host ("  Faulting module: {0}" -f $mod) -ForegroundColor Yellow
    Write-Host '  Not recognised as an inbox driver. If it is a third-party filter driver' -ForegroundColor Gray
    Write-Host '  (antivirus, backup, monitoring), exclude the FILESTREAM volume from it or' -ForegroundColor Gray
    Write-Host '  uninstall it for the duration of the POC.' -ForegroundColor Gray
}

Write-Host ''
Write-Host ("  (MODULE_NAME reported {0}; the classification above is based on the full stack.)" -f $mod) -ForegroundColor DarkGray

# The stack usually names the interacting drivers even when MODULE_NAME does not.
$stack = [regex]::Match($text, '(?ms)^STACK_TEXT:\s*\r?\n(.*?)\r?\n\s*\r?\n')
if ($stack.Success) {
    Write-Host ''
    Write-Host '=== Stack ===' -ForegroundColor Cyan
    ($stack.Groups[1].Value -split "`r?`n" | Select-Object -First 25) | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
}

Write-Host ''
Write-FsPocLog "Full debugger output: $log" 'OK'
Write-FsPocLog 'Send MODULE_NAME, FAILURE_BUCKET_ID and the stack if you want help reading it.' 'INFO'
