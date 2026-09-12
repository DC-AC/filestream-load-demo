<#
.SYNOPSIS
    End-to-end FILESTREAM POC run: start monitoring, ingest, stop monitoring,
    report.

.DESCRIPTION
    This is the entry point you actually run.

    Suggested sequence for a defensible POC:

      1. .\Invoke-PocRun.ps1 -Scenario Filestream -TargetGB 200
             Clean throughput number. No Procmon.
      2. .\Invoke-PocRun.ps1 -Scenario Filestream -TargetGB 20 -Procmon
             Short instrumented run for per-operation anatomy.
      3. .\Invoke-PocRun.ps1 -Scenario Blob -TargetGB 20 -SizeProfile Small
         .\Invoke-PocRun.ps1 -Scenario Filestream -TargetGB 20 -SizeProfile Small
             The A/B that answers the actual question, at the size where it is
             genuinely in doubt.
      4. .\Invoke-PocRun.ps1 -Scenario FilestreamRead -TargetGB 20
             Read path. Ingest performance alone is a half-answer.

    Or run the whole matrix: -Matrix

.EXAMPLE
    .\Invoke-PocRun.ps1 -Scenario Filestream -TargetGB 200 -Threads 8

.EXAMPLE
    .\Invoke-PocRun.ps1 -Matrix -TargetGB 20
#>
[CmdletBinding()]
param(
    [ValidateSet('Filestream', 'Blob', 'FileTable', 'FilestreamRead', 'BlobRead', 'FileTableRead')]
    [string] $Scenario = 'Filestream',

    [double] $TargetGB,
    [int]    $Threads,
    [int]    $ChunkSizeKB,
    [ValidateSet('Tiny', 'Small', 'Medium', 'Large', 'Huge', 'Mixed')]
    [string] $SizeProfile,

    [string] $ConfigPath,
    [string] $SourcePath,
    # Names the configuration under test, e.g. 'Premium v1 4k'. Carried into
    # RunName so section 8 of the analysis can tell the runs apart.
    [string] $Label,
    [switch] $Preallocate,
    # Force FileTable writes to stable storage, matching what a FILESTREAM
    # commit does implicitly. Off by default: see Invoke-FilestreamIngest.ps1.
    [switch] $FileTableFlush,

    # Monitoring
    [switch] $Procmon,
    [int]    $ProcmonDelaySec = 30,
    [int]    $ProcmonWindowSec,
    <#  Convert the Procmon backing file to CSV as part of this run.

        Off by default. The conversion is single-threaded and writes a CSV that
        can exceed the trace itself, and it would start the moment a very large
        load finishes -- the worst possible time, on the machine that has just
        been hammered for an hour. A previous 200 GB run lost its analysis
        phase to a bugcheck at exactly this point.

        The .pml is kept either way. Convert and analyse it afterwards, when
        the machine is quiet, with:
            .\Invoke-PocAnalysis.ps1 -ConvertProcmon
    #>
    [switch] $ConvertProcmon,
    [string] $ProcmonConfig,
    [switch] $NoXEvents,
    [switch] $NoPerfmon,
    [switch] $NoSampler,

    # Run the full comparison matrix instead of a single scenario
    [switch] $Matrix,
    # Proceed even though the container already holds data. Only pass this when
    # a warm container is deliberately the thing being measured.
    [switch] $AllowUsedContainer,
    [switch] $SkipAnalysis
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 does not reliably populate $PSScriptRoot while it binds
# parameter defaults, so the script directory is resolved here in the body --
# where it is always available -- and parameter defaults are applied after.
# Everything below uses $ScriptDir; nothing uses $PSScriptRoot.
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptDir 'FsPocConfig.psd1' }
Import-Module (Join-Path $ScriptDir 'FsPoc.Common.psm1') -Force

if ($PSVersionTable.PSVersion.Major -ge 6) {
    throw "Run under Windows PowerShell 5.1: powershell.exe -ExecutionPolicy Bypass -File $PSCommandPath"
}

$cfg = Get-FsPocConfig -Path $ConfigPath -Override @{
    TargetGB = $TargetGB; Threads = $Threads; ChunkSizeKB = $ChunkSizeKB; SizeProfile = $SizeProfile
}
$sqlDir = Join-Path (Split-Path -Parent $ScriptDir) 'sql'

# ---------------------------------------------------------------------------
# Preflight. Failing here with a clear message beats failing 40 minutes into a
# run, or -- worse -- producing numbers from a half-configured instance.
# ---------------------------------------------------------------------------
try {
    <#  The database EXISTING is not the same as it being the right database.

        A plain "CREATE DATABASE FsPocDemo" satisfies DB_ID() and nothing else:
        no FILESTREAM filegroup, no FileStore/BlobStore, no procs. Checking only
        DB_ID() let that through, and the run then failed 141 times on a missing
        stored procedure before anyone found out. These three extra columns turn
        that into a one-second failure that names the fix.

        Everything here is readable from master, so nothing needs the database to
        exist: sys.master_files carries the FILESTREAM file (type 2) for every
        database, and three-part OBJECT_ID() returns NULL rather than erroring
        when the database is absent.
    #>
    $pre = Invoke-FsPocSql -Instance $cfg.SqlInstance -Database 'master' -Query @"
SELECT
    FsLevel     = CONVERT(int, SERVERPROPERTY('FilestreamEffectiveLevel')),
    DemoDb      = CASE WHEN DB_ID(N'$($cfg.DemoDb)')    IS NULL THEN 0 ELSE 1 END,
    MonitorDb   = CASE WHEN DB_ID(N'$($cfg.MonitorDb)') IS NULL THEN 0 ELSE 1 END,
    FsContainer = (SELECT COUNT(*) FROM sys.master_files
                   WHERE database_id = DB_ID(N'$($cfg.DemoDb)') AND type = 2),
    FsProc      = CASE WHEN OBJECT_ID(N'$($cfg.DemoDb).dbo.usp_BeginFileStreamInsert', 'P') IS NULL THEN 0 ELSE 1 END,
    BlobProc    = CASE WHEN OBJECT_ID(N'$($cfg.DemoDb).dbo.usp_BeginBlobInsert', 'P')       IS NULL THEN 0 ELSE 1 END,
    FileTable   = CASE WHEN OBJECT_ID(N'$($cfg.DemoDb).dbo.FileStoreFT')                    IS NULL THEN 0 ELSE 1 END,
    FtProc      = CASE WHEN OBJECT_ID(N'$($cfg.DemoDb).dbo.usp_GetFileTableRoot', 'P')      IS NULL THEN 0 ELSE 1 END,
    -- Directory pressure roughly halves per-file throughput once a container
    -- is full, so a run into a used container is not comparable with one into
    -- an empty container. Cheap to check, expensive to discover afterwards.
    ExistingRows = ISNULL((SELECT SUM(c.row_count) FROM sys.dm_db_partition_stats c
                           JOIN sys.objects o ON o.object_id = c.object_id
                           WHERE c.index_id IN (0,1)
                             AND o.name IN ('FileStore','BlobStore','FileStoreFT')), 0)
"@
}
catch {
    throw "Cannot reach SQL Server instance '$($cfg.SqlInstance)': $($_.Exception.Message)`nCheck SqlInstance in $ConfigPath."
}

$missing = @()
# Only demanded for the scenarios that use them: a Filestream-only run should
# not be blocked by a missing FileTable, and vice versa.
$needsFileTable = ($Scenario -like 'FileTable*') -or $Matrix
if ($pre.Rows[0].FsLevel   -lt 2) { $missing += "FILESTREAM effective level is $($pre.Rows[0].FsLevel); the streaming API needs 2 or higher" }
if ($pre.Rows[0].DemoDb    -eq 0) { $missing += "database '$($cfg.DemoDb)' does not exist" }
if ($pre.Rows[0].MonitorDb -eq 0) { $missing += "database '$($cfg.MonitorDb)' does not exist" }

# Only worth reporting when the database is actually there -- otherwise these
# just restate "it does not exist" three more times.
if ($pre.Rows[0].DemoDb -eq 1) {
    if ($pre.Rows[0].FsContainer -eq 0) {
        $missing += "'$($cfg.DemoDb)' has no FILESTREAM filegroup -- it was created as a plain database, not by sql\02-create-database.sql"
    }
    if ($pre.Rows[0].FsProc -eq 0)   { $missing += "'$($cfg.DemoDb)' is missing dbo.usp_BeginFileStreamInsert" }
    if ($pre.Rows[0].BlobProc -eq 0) { $missing += "'$($cfg.DemoDb)' is missing dbo.usp_BeginBlobInsert" }
    if ($needsFileTable) {
        if ($pre.Rows[0].FileTable -eq 0) { $missing += "'$($cfg.DemoDb)' is missing the FileTable dbo.FileStoreFT" }
        if ($pre.Rows[0].FtProc -eq 0)    { $missing += "'$($cfg.DemoDb)' is missing dbo.usp_GetFileTableRoot" }
    }
}

if ($missing.Count -gt 0) {
    Write-Host ''
    Write-FsPocLog 'Preflight failed:' 'ERROR'
    $missing | ForEach-Object { Write-Host "    * $_" -ForegroundColor Red }
    Write-Host ''
    throw "Run setup first (elevated):`n" +
          "    powershell.exe -ExecutionPolicy Bypass -File $ScriptDir\Setup-FilestreamPoc.ps1 -RestartSqlService -ApplyNtfsTuning"
}
Write-FsPocLog "Preflight OK: FILESTREAM level $($pre.Rows[0].FsLevel), $($cfg.DemoDb) and $($cfg.MonitorDb) present." 'OK'

<#  A used container is a different benchmark from an empty one.

    Measured at roughly 2x the per-file cost once the container is populated,
    so a run into a container holding a previous run's data cannot be compared
    against one into a fresh container. That is the difference between
    measuring a disk change and measuring directory pressure.
#>
$existing = [long]$pre.Rows[0].ExistingRows
if ($existing -gt 0) {
    Write-Host ''
    Write-FsPocLog ("The container already holds {0:N0} row(s) from previous run(s)." -f $existing) 'WARN'
    Write-FsPocLog 'Directory pressure costs roughly 2x per-file throughput, so this run will NOT be' 'WARN'
    Write-FsPocLog 'comparable with runs that started from an empty container.' 'WARN'
    Write-FsPocLog 'To start clean:  .\Reset-FilestreamPoc.ps1 -Execute   (keeps the run history)' 'INFO'
    Write-Host ''
    if (-not $AllowUsedContainer) {
        throw 'Aborting: the container is not empty. Reset it, or pass -AllowUsedContainer if a warm container is what you intend to measure.'
    }
    Write-FsPocLog 'Continuing into a used container (-AllowUsedContainer).' 'WARN'
}

# ---------------------------------------------------------------------------
function Invoke-OneRun {
    param(
        [string] $Scn,
        [string] $Prof,
        [double] $GB
    )

    $runId      = [guid]::NewGuid()
    $stamp      = Get-Date -Format 'yyyyMMdd_HHmmss'
    $resultsDir = Join-Path $cfg.ResultsPath "run_${stamp}_${Scn}_${Prof}"
    $null = New-Item -ItemType Directory -Path $resultsDir -Force

    Write-Host ''
    Write-Host '################################################################' -ForegroundColor Magenta
    Write-Host " RUN: $Scn / $Prof / $GB GB" -ForegroundColor Magenta
    Write-Host '################################################################' -ForegroundColor Magenta

    # ---- Start monitoring -------------------------------------------------
    $captureArgs = @{
        RunId = $runId; ResultsDir = $resultsDir; ConfigPath = $ConfigPath
        NoXEvents = $NoXEvents; NoPerfmon = $NoPerfmon
    }
    if ($Procmon) {
        $captureArgs.Procmon = $true
        $captureArgs.ProcmonDelaySec = $ProcmonDelaySec
        if ($ProcmonWindowSec) { $captureArgs.ProcmonWindowSec = $ProcmonWindowSec }
        if ($ProcmonConfig)    { $captureArgs.ProcmonConfig = $ProcmonConfig }
    }
    & (Join-Path $ScriptDir 'Start-PocCapture.ps1') @captureArgs | Out-Null

    # ---- DMV activity sampler --------------------------------------------
    # A dedicated runspace rather than a SQL Agent job: it starts and stops
    # exactly with the run, and it never touches the workload connections.
    $samplerRs = $null; $samplerPs = $null; $samplerHandle = $null
    $samplerCtl = [hashtable]::Synchronized(@{ Stop = $false })
    if (-not $NoSampler) {
        $samplerRs = [runspacefactory]::CreateRunspace()
        $samplerRs.Open()
        $samplerPs = [powershell]::Create()
        $samplerPs.Runspace = $samplerRs
        $null = $samplerPs.AddScript({
            param($cs, $runId, $interval, $ctl)
            $conn = New-Object System.Data.SqlClient.SqlConnection $cs
            $conn.Open()
            $cmd = $conn.CreateCommand()
            $cmd.CommandType = [System.Data.CommandType]::StoredProcedure
            $cmd.CommandText = 'dbo.usp_SampleActivity'
            $null = $cmd.Parameters.AddWithValue('@RunId', $runId)
            try {
                while (-not $ctl['Stop']) {
                    try { $null = $cmd.ExecuteNonQuery() } catch { }
                    Start-Sleep -Seconds $interval
                }
            }
            finally { $conn.Dispose() }
        }).AddArgument((Get-FsPocConnectionString -Instance $cfg.SqlInstance -Database $cfg.MonitorDb)).
           AddArgument($runId).
           AddArgument($cfg.SamplerIntervalSec).
           AddArgument($samplerCtl)
        $samplerHandle = $samplerPs.BeginInvoke()
        Write-FsPocLog "DMV activity sampler running every $($cfg.SamplerIntervalSec)s." 'OK'
    }

    # ---- Ingest -----------------------------------------------------------
    $result = $null
    try {
        $ingestArgs = @{
            Scenario = $Scn; TargetGB = $GB; SizeProfile = $Prof
            Threads = $cfg.Threads; ChunkSizeKB = $cfg.ChunkSizeKB
            RunId = $runId; ConfigPath = $ConfigPath
        }
        if ($SourcePath)     { $ingestArgs.SourcePath = $SourcePath }
        if ($Label)          { $ingestArgs.Label = $Label }
        if ($Preallocate)    { $ingestArgs.Preallocate = $true }
        if ($FileTableFlush) { $ingestArgs.FileTableFlush = $true }
        $result = & (Join-Path $ScriptDir 'Invoke-FilestreamIngest.ps1') @ingestArgs
    }
    finally {
        # ---- Stop sampler -------------------------------------------------
        if ($samplerPs) {
            $samplerCtl['Stop'] = $true
            try { $null = $samplerPs.EndInvoke($samplerHandle) } catch { }
            $samplerPs.Dispose(); $samplerRs.Close(); $samplerRs.Dispose()
        }
        # ---- Stop monitoring ----------------------------------------------
        try {
            $stopArgs = @{ ResultsDir = $resultsDir }
            if ($Procmon -and -not $ConvertProcmon) { $stopArgs.SkipProcmonConvert = $true }
            & (Join-Path $ScriptDir 'Stop-PocCapture.ps1') @stopArgs
        }
        catch { Write-FsPocLog "Stop-PocCapture failed: $($_.Exception.Message)" 'WARN' }
    }

    # ---- Copy the run's own results next to the capture -------------------
    if ($result -and $result.ResultsDir -and (Test-Path -LiteralPath $result.ResultsDir) -and
        $result.ResultsDir -ne $resultsDir) {
        Get-ChildItem -LiteralPath $result.ResultsDir -File | ForEach-Object {
            Move-Item -LiteralPath $_.FullName -Destination $resultsDir -Force
        }
        Remove-Item -LiteralPath $result.ResultsDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # ---- Procmon analysis -------------------------------------------------
    $pmCsv = Join-Path $resultsDir 'procmon.csv'
    $pmPml = Join-Path $resultsDir 'procmon.pml'
    if ($Procmon -and -not $ConvertProcmon -and (Test-Path -LiteralPath $pmPml)) {
        Write-FsPocLog ("Procmon trace kept unconverted: {0} ({1})" -f $pmPml, (Format-FsPocBytes (Get-Item $pmPml).Length)) 'OK'
        Write-FsPocLog 'Convert and analyse it when the machine is quiet:  .\Invoke-PocAnalysis.ps1 -ConvertProcmon' 'INFO'
    }
    if ($Procmon -and (Test-Path -LiteralPath $pmCsv)) {
        Write-Host ''
        try { & (Join-Path $ScriptDir 'Measure-ProcmonLog.ps1') -CsvPath $pmCsv -ConfigPath $ConfigPath }
        catch { Write-FsPocLog "Procmon analysis failed: $($_.Exception.Message)" 'WARN' }
    }

    [pscustomobject]@{
        RunId = $runId; Scenario = $Scn; Profile = $Prof; ResultsDir = $resultsDir; Result = $result
    }
}

# ---------------------------------------------------------------------------
$runs = @()
if ($Matrix) {
    # Straddle the FILESTREAM crossover deliberately: Small is where in-table
    # LOB usually wins, Large is where FILESTREAM usually wins, and Medium is
    # the one nobody can predict without measuring.
    # Three write paths at each of three sizes, then the read side. Blob and
    # Filestream are transactional; FileTable is not, so it is expected to win
    # on raw throughput -- the question the matrix answers is by how much, and
    # therefore what transactional consistency is costing at each size.
    $matrixPlan = @(
        @{ Scn = 'Blob';           Prof = 'Small'  }
        @{ Scn = 'Filestream';     Prof = 'Small'  }
        @{ Scn = 'FileTable';      Prof = 'Small'  }
        @{ Scn = 'Blob';           Prof = 'Medium' }
        @{ Scn = 'Filestream';     Prof = 'Medium' }
        @{ Scn = 'FileTable';      Prof = 'Medium' }
        @{ Scn = 'Blob';           Prof = 'Large'  }
        @{ Scn = 'Filestream';     Prof = 'Large'  }
        @{ Scn = 'FileTable';      Prof = 'Large'  }
        @{ Scn = 'BlobRead';       Prof = 'Medium' }
        @{ Scn = 'FilestreamRead'; Prof = 'Medium' }
        @{ Scn = 'FileTableRead';  Prof = 'Medium' }
    )
    Write-FsPocLog "Matrix mode: $($matrixPlan.Count) runs at $($cfg.TargetGB) GB each." 'STEP'
    foreach ($m in $matrixPlan) {
        $runs += Invoke-OneRun -Scn $m.Scn -Prof $m.Prof -GB $cfg.TargetGB
        # Let FILESTREAM garbage collection and checkpoint activity settle so
        # the next run does not start with the previous run's cleanup in flight.
        Write-FsPocLog 'Settling for 60s between matrix runs...' 'INFO'
        Start-Sleep -Seconds 60
    }
}
else {
    $runs += Invoke-OneRun -Scn $Scenario -Prof $cfg.SizeProfile -GB $cfg.TargetGB
}

# ---------------------------------------------------------------------------
<#  sqlcmd rejects -W together with -y/-Y ("mutually exclusive") and exits 1
    before running a single batch, so an earlier -y 0 -Y 40 -W here meant the
    analysis phase never ran at all -- it failed on the usage error, and with
    $ErrorActionPreference = 'Stop' that took the whole run down after the
    ingest had already finished.

    -W is the half to keep. It trims trailing padding, and it does NOT truncate
    variable-length columns the way the 256-char default does, so the wide
    columns -y 0 was there to protect (06-xevent-shred's ErrorMsg nvarchar(2000)
    and IoPath nvarchar(400)) still come through whole.
#>
$AnalysisFormatArgs = @('-W', '-s', '|')

if (-not $SkipAnalysis) {
    Write-Host ''
    Write-Host '================================================================' -ForegroundColor Cyan
    Write-Host ' ANALYSIS' -ForegroundColor Cyan
    Write-Host '================================================================' -ForegroundColor Cyan
    foreach ($r in $runs) {
        $out = Join-Path $r.ResultsDir 'analysis.txt'
        Invoke-FsPocSql -Instance $cfg.SqlInstance `
            -InputFile (Join-Path $sqlDir '05-analysis.sql') `
            -SqlcmdVariables @{ RunId = $r.RunId; TopWaits = 25 } `
            -ExtraArgs $AnalysisFormatArgs |
            Tee-Object -FilePath $out
        Write-FsPocLog "Analysis saved to $out" 'OK'
    }

    # XEvent shred: only meaningful once the session has stopped and flushed.
    $lastRun = $runs[-1]
    $xelDir = Join-Path $lastRun.ResultsDir 'xevents'
    if (Test-Path -LiteralPath $xelDir) {
        $xeOut = Join-Path $lastRun.ResultsDir 'xevents-analysis.txt'
        try {
            Invoke-FsPocSql -Instance $cfg.SqlInstance `
                -InputFile (Join-Path $sqlDir '06-xevent-shred.sql') `
                -SqlcmdVariables @{ XePath = $xelDir; SessionName = 'FsPoc_Waits' } `
                -ExtraArgs $AnalysisFormatArgs |
                Tee-Object -FilePath $xeOut
            Write-FsPocLog "XEvent analysis saved to $xeOut" 'OK'
        }
        catch { Write-FsPocLog "XEvent shred failed: $($_.Exception.Message)" 'WARN' }
    }
}

Write-Host ''
Write-FsPocLog 'All runs complete.' 'OK'
$runs | ForEach-Object {
    if ($_.Result) {
        Write-Host ('  {0,-16} {1,-8} {2,10} in {3,7:N0}s = {4,7:N1} MB/s   {5}' -f `
            $_.Scenario, $_.Profile, (Format-FsPocBytes $_.Result.Bytes), $_.Result.Seconds,
            $_.Result.ThroughputMBs, $_.ResultsDir) -ForegroundColor Green
    }
}
$runs
