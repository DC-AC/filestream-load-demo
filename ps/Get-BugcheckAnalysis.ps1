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
    [string] $OutputFile
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
$debugger = $null
$searchPaths = @(
    "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64\cdb.exe"
    "$env:ProgramFiles\Windows Kits\10\Debuggers\x64\cdb.exe"
    "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64\kd.exe"
    "$env:ProgramFiles\Windows Kits\10\Debuggers\x64\kd.exe"
)
foreach ($p in $searchPaths) { if (Test-Path -LiteralPath $p) { $debugger = $p; break } }
if (-not $debugger) {
    $cmd = Get-Command cdb.exe, kd.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { $debugger = $cmd.Source }
}
if (-not $debugger) {
    Write-FsPocLog 'No command-line debugger (cdb.exe / kd.exe) found.' 'ERROR'
    Write-Host ''
    Write-Host '  Install the Debugging Tools for Windows:' -ForegroundColor Yellow
    Write-Host '      winget install --id Microsoft.WinDbg' -ForegroundColor White
    Write-Host ''
    Write-Host '  Or open the dump in WinDbg by hand and run:' -ForegroundColor Yellow
    Write-Host '      !analyze -v' -ForegroundColor White
    Write-Host ''
    Write-Host ("  Dump to open: {0}" -f $dump.FullName) -ForegroundColor White
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

$culprit = [regex]::Match($text, "(?m)^MODULE_NAME:\s*(\S+)")
if ($culprit.Success) {
    $mod = $culprit.Groups[1].Value
    Write-Host ''
    switch -Wildcard ($mod) {
        'RsFx*'    { Write-Host "  The FILESTREAM filter driver ($mod) is implicated. This is a SQL Server" -ForegroundColor Yellow
                     Write-Host '  driver defect. Apply the latest SQL Server 2019 cumulative update, and' -ForegroundColor Yellow
                     Write-Host '  open a Microsoft support case with this dump if it persists.' -ForegroundColor Yellow }
        'WdFilter*'{ Write-Host "  Windows Defender's minifilter ($mod) is implicated. Add the FILESTREAM" -ForegroundColor Yellow
                     Write-Host '  container and sqlservr.exe to the exclusion list and retry.' -ForegroundColor Yellow }
        default    { Write-Host "  Faulting module: $mod" -ForegroundColor Yellow
                     Write-Host '  If that is a third-party filter driver, exclude the FILESTREAM volume' -ForegroundColor Yellow
                     Write-Host '  from it or uninstall it for the duration of the POC.' -ForegroundColor Yellow }
    }
}

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
