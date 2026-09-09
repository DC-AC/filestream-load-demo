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
    [ValidateSet('Filestream', 'Blob', 'FilestreamRead', 'BlobRead')]
    [string] $Scenario = 'Filestream',

    [double] $TargetGB,
    [int]    $Threads,
    [int]    $ChunkSizeKB,
    [ValidateSet('Tiny', 'Small', 'Medium', 'Large', 'Huge', 'Mixed')]
    [string] $SizeProfile,

    [string] $ConfigPath = (Join-Path $PSScriptRoot 'FsPocConfig.psd1'),
    [string] $SourcePath,
    [switch] $Preallocate,

    # Monitoring
    [switch] $Procmon,
    [int]    $ProcmonDelaySec = 30,
    [int]    $ProcmonWindowSec,
    [string] $ProcmonConfig,
    [switch] $NoXEvents,
    [switch] $NoPerfmon,
    [switch] $NoSampler,

    # Run the full comparison matrix instead of a single scenario
    [switch] $Matrix,
    [switch] $SkipAnalysis
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'FsPoc.Common.psm1') -Force

if ($PSVersionTable.PSVersion.Major -ge 6) {
    throw "Run under Windows PowerShell 5.1: powershell.exe -ExecutionPolicy Bypass -File $PSCommandPath"
}

$cfg = Get-FsPocConfig -Path $ConfigPath -Override @{
    TargetGB = $TargetGB; Threads = $Threads; ChunkSizeKB = $ChunkSizeKB; SizeProfile = $SizeProfile
}
$sqlDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'sql'

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
    & (Join-Path $PSScriptRoot 'Start-PocCapture.ps1') @captureArgs | Out-Null

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
        if ($SourcePath)  { $ingestArgs.SourcePath = $SourcePath }
        if ($Preallocate) { $ingestArgs.Preallocate = $true }
        $result = & (Join-Path $PSScriptRoot 'Invoke-FilestreamIngest.ps1') @ingestArgs
    }
    finally {
        # ---- Stop sampler -------------------------------------------------
        if ($samplerPs) {
            $samplerCtl['Stop'] = $true
            try { $null = $samplerPs.EndInvoke($samplerHandle) } catch { }
            $samplerPs.Dispose(); $samplerRs.Close(); $samplerRs.Dispose()
        }
        # ---- Stop monitoring ----------------------------------------------
        try { & (Join-Path $PSScriptRoot 'Stop-PocCapture.ps1') -ResultsDir $resultsDir }
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
    if ($Procmon -and (Test-Path -LiteralPath $pmCsv)) {
        Write-Host ''
        try { & (Join-Path $PSScriptRoot 'Measure-ProcmonLog.ps1') -CsvPath $pmCsv -ConfigPath $ConfigPath }
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
    $matrixPlan = @(
        @{ Scn = 'Blob';           Prof = 'Small'  }
        @{ Scn = 'Filestream';     Prof = 'Small'  }
        @{ Scn = 'Blob';           Prof = 'Medium' }
        @{ Scn = 'Filestream';     Prof = 'Medium' }
        @{ Scn = 'Blob';           Prof = 'Large'  }
        @{ Scn = 'Filestream';     Prof = 'Large'  }
        @{ Scn = 'BlobRead';       Prof = 'Medium' }
        @{ Scn = 'FilestreamRead'; Prof = 'Medium' }
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
if (-not $SkipAnalysis) {
    Write-Host ''
    Write-Host '================================================================' -ForegroundColor Cyan
    Write-Host ' ANALYSIS' -ForegroundColor Cyan
    Write-Host '================================================================' -ForegroundColor Cyan
    foreach ($r in $runs) {
        $out = Join-Path $r.ResultsDir 'analysis.txt'
        & sqlcmd.exe -S $cfg.SqlInstance -E -b -I -i (Join-Path $sqlDir '05-analysis.sql') `
                     -v RunId="$($r.RunId)" TopWaits=25 -y 0 -Y 40 -W -s '|' |
            Tee-Object -FilePath $out
        Write-FsPocLog "Analysis saved to $out" 'OK'
    }

    # XEvent shred: only meaningful once the session has stopped and flushed.
    $lastRun = $runs[-1]
    $xelDir = Join-Path $lastRun.ResultsDir 'xevents'
    if (Test-Path -LiteralPath $xelDir) {
        $xeOut = Join-Path $lastRun.ResultsDir 'xevents-analysis.txt'
        try {
            & sqlcmd.exe -S $cfg.SqlInstance -E -b -I -i (Join-Path $sqlDir '06-xevent-shred.sql') `
                         -v XePath="$xelDir" SessionName="FsPoc_Waits" -y 0 -Y 40 -W -s '|' | Tee-Object -FilePath $xeOut
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
