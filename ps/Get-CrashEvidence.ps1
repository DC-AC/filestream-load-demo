<#
.SYNOPSIS
    Collects evidence about an unexpected VM restart and reports whether it was
    a kernel bugcheck or a platform-level reset.

.DESCRIPTION
    Nothing in this kit restarts a machine -- there is no Restart-Computer,
    Stop-Computer or shutdown call anywhere in it. The only service action is
    restarting the SQL Server service. So an unexpected VM restart during a run
    is one of:

      * a kernel bugcheck (BSOD), most plausibly in a file system filter
        driver, because FILESTREAM streaming I/O goes through RsFx.sys and
        every antivirus / backup / monitoring minifilter is stacked alongside
        it on the same volume; or
      * an Azure platform event -- host maintenance, a host fault, or a forced
        reset -- which looks similar in the log but records no bugcheck code.

    Kernel-Power event 41 distinguishes them: a non-zero BugcheckCode means a
    real bugcheck, zero means the machine went down without one.

    Run elevated, after the VM comes back up.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\ps\Get-CrashEvidence.ps1
#>
[CmdletBinding()]
param(
    [int]    $DaysBack = 3,
    [string] $ConfigPath,
    [string] $OutputFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptDir 'FsPocConfig.psd1' }
Import-Module (Join-Path $ScriptDir 'FsPoc.Common.psm1') -Force
$cfg = Get-FsPocConfig -Path $ConfigPath

if ($OutputFile) { Start-Transcript -Path $OutputFile -Force | Out-Null }
$since = (Get-Date).AddDays(-$DaysBack)

function Section { param($T) Write-Host ''; Write-Host "=== $T ===" -ForegroundColor Cyan }

Write-Host ''
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host ' UNEXPECTED RESTART -- EVIDENCE COLLECTION' -ForegroundColor Cyan
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host ("  Machine: {0}   Looking back {1} day(s)" -f $env:COMPUTERNAME, $DaysBack) -ForegroundColor Gray

# ---------------------------------------------------------------------------
Section 'Boot history'
try {
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Host ("  Last boot : {0}" -f $os.LastBootUpTime)
    Write-Host ("  Uptime    : {0}" -f ((Get-Date) - $os.LastBootUpTime).ToString('d\d\ hh\:mm\:ss'))
}
catch { Write-Host "  (could not read Win32_OperatingSystem: $($_.Exception.Message))" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
Section 'Bugcheck vs platform reset (Kernel-Power 41)'
$k41 = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41; StartTime = $since } -ErrorAction SilentlyContinue)
if ($k41.Count -eq 0) { Write-Host '  No Kernel-Power 41 events. The VM was not hard-reset in this window.' -ForegroundColor Green }
foreach ($e in $k41) {
    $x = [xml]$e.ToXml()
    $d = @{}
    foreach ($p in $x.Event.EventData.Data) { $d[$p.Name] = $p.'#text' }
    $code = 0
    if ($d.ContainsKey('BugcheckCode')) { $code = [int64]$d['BugcheckCode'] }
    Write-Host ''
    Write-Host ("  {0}" -f $e.TimeCreated) -ForegroundColor White
    if ($code -ne 0) {
        Write-Host ("     KERNEL BUGCHECK. Code 0x{0:X} ({1})" -f $code, $code) -ForegroundColor Red
        foreach ($n in 'BugcheckParameter1', 'BugcheckParameter2', 'BugcheckParameter3', 'BugcheckParameter4') {
            if ($d.ContainsKey($n)) { Write-Host ("       {0} = {1}" -f $n, $d[$n]) -ForegroundColor DarkYellow }
        }
    }
    else {
        Write-Host '     No bugcheck code recorded -- the machine went down without a BSOD.' -ForegroundColor Yellow
        Write-Host '     On Azure that points at a host event or a forced reset, not at this workload.' -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
Section 'Bugcheck detail (WER 1001) and unexpected shutdowns (6008)'
foreach ($id in 1001, 6008, 1074, 109) {
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = $id; StartTime = $since } -ErrorAction SilentlyContinue)
    foreach ($e in $ev | Select-Object -First 5) {
        Write-Host ''
        Write-Host ("  [{0}] {1}  ({2})" -f $id, $e.TimeCreated, $e.ProviderName) -ForegroundColor White
        Write-Host ("     {0}" -f (($e.Message -split "`r?`n" | Where-Object { $_.Trim() }) -join ' ' )) -ForegroundColor Gray
    }
}

# ---------------------------------------------------------------------------
Section 'Crash dumps'
$dumps = @()
if (Test-Path 'C:\Windows\MEMORY.DMP') { $dumps += Get-Item 'C:\Windows\MEMORY.DMP' }
if (Test-Path 'C:\Windows\Minidump')   { $dumps += @(Get-ChildItem 'C:\Windows\Minidump' -Filter *.dmp -ErrorAction SilentlyContinue) }
if ($dumps.Count -eq 0) {
    Write-Host '  No dump files found.' -ForegroundColor Yellow
    Write-Host '  Absence of a dump alongside a Kernel-Power 41 with no bugcheck code' -ForegroundColor Gray
    Write-Host '  is consistent with a platform reset rather than a BSOD.' -ForegroundColor Gray
}
foreach ($d in $dumps | Sort-Object LastWriteTime -Descending | Select-Object -First 10) {
    Write-Host ("  {0}   {1,12}   {2}" -f $d.LastWriteTime, (Format-FsPocBytes $d.Length), $d.FullName)
}

# ---------------------------------------------------------------------------
Section 'File system filter drivers (the FILESTREAM-critical list)'
Write-Host '  RsFx is the FILESTREAM filter driver. Anything else attached to the' -ForegroundColor Gray
Write-Host '  container volume is stacked alongside it during streaming I/O.' -ForegroundColor Gray
Write-Host ''
try { & fltmc.exe filters 2>&1 | ForEach-Object { Write-Host "  $_" } }
catch { Write-Host "  (fltmc failed: $($_.Exception.Message))" -ForegroundColor Yellow }

$fsVol = Split-Path -Qualifier $cfg.FsPath
Write-Host ''
Write-Host ("  Instances attached to the FILESTREAM volume ($fsVol):") -ForegroundColor Gray
try { & fltmc.exe instances -v $fsVol 2>&1 | ForEach-Object { Write-Host "  $_" } }
catch { Write-Host "  (fltmc instances failed)" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
Section 'Antivirus'
try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    Write-Host ("  Defender real-time protection : {0}" -f $mp.RealTimeProtectionEnabled)
    Write-Host ("  Antimalware engine            : {0}" -f $mp.AMEngineVersion)
    $pref = Get-MpPreference -ErrorAction Stop
    $ex = @($pref.ExclusionPath)
    if ($ex.Count -eq 0 -or -not $ex) { Write-Host '  Exclusion paths: NONE' -ForegroundColor Yellow }
    else { foreach ($e in $ex) { Write-Host "  Exclusion: $e" } }
    if (-not ($ex -contains $cfg.FsPath)) {
        Write-Host ''
        Write-Host ("  The FILESTREAM container ({0}) is NOT excluded." -f $cfg.FsPath) -ForegroundColor Yellow
        Write-Host '  Real-time scanning sees every FILESTREAM file as a brand-new file,' -ForegroundColor Yellow
        Write-Host '  because it is one, and its minifilter sits alongside RsFx on that' -ForegroundColor Yellow
        Write-Host '  volume. Exclude it before the next attempt:' -ForegroundColor Yellow
        Write-Host ("      Add-MpPreference -ExclusionPath '{0}'" -f $cfg.FsPath) -ForegroundColor White
        Write-Host "      Add-MpPreference -ExclusionProcess 'sqlservr.exe'" -ForegroundColor White
    }
}
catch { Write-Host "  (Defender cmdlets unavailable: $($_.Exception.Message))" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
Section 'SQL Server around the restart'
try {
    $log = Invoke-FsPocSql -Instance $cfg.SqlInstance -Database 'master' -Query @'
EXEC sys.xp_readerrorlog 0, 1, NULL, NULL, NULL, NULL, N'desc'
'@
    $log.Rows | Select-Object -First 25 | ForEach-Object {
        Write-Host ("  {0}  {1}" -f $_.LogDate, ($_.Text -replace '\s+', ' '))
    }
}
catch { Write-Host "  (could not read the SQL error log: $($_.Exception.Message))" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
Section 'Verdict'
$bugchecks = @($k41 | Where-Object {
    $x = [xml]$_.ToXml()
    $c = ($x.Event.EventData.Data | Where-Object Name -eq 'BugcheckCode').'#text'
    $c -and [int64]$c -ne 0
})
if ($bugchecks.Count -gt 0) {
    Write-Host '  KERNEL BUGCHECK confirmed.' -ForegroundColor Red
    Write-Host '  Send the bugcheck code above plus the fltmc filter list. If a third-party' -ForegroundColor Gray
    Write-Host '  minifilter (AV, backup, monitoring) is attached to the FILESTREAM volume,' -ForegroundColor Gray
    Write-Host '  exclude the container from it before retrying -- that stack is the most' -ForegroundColor Gray
    Write-Host '  common source of bugchecks during FILESTREAM streaming I/O.' -ForegroundColor Gray
}
elseif ($k41.Count -gt 0) {
    Write-Host '  Restart recorded with NO bugcheck code.' -ForegroundColor Yellow
    Write-Host '  That is a platform-level reset, not a crash caused by this workload.' -ForegroundColor Gray
    Write-Host '  Check the Azure portal for host maintenance or Resource Health events' -ForegroundColor Gray
    Write-Host '  covering these timestamps.' -ForegroundColor Gray
}
else {
    Write-Host '  No unexpected-restart events found in the window.' -ForegroundColor Green
    Write-Host '  Try -DaysBack 7, or confirm the restart times from the Azure portal.' -ForegroundColor Gray
}

if ($OutputFile) { Stop-Transcript | Out-Null; Write-Host ''; Write-Host "Saved to $OutputFile" -ForegroundColor Green }
