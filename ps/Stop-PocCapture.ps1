<#
.SYNOPSIS
    Tears down the monitoring stack started by Start-PocCapture.ps1 and converts
    the Procmon backing file to CSV.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ResultsDir,
    [switch] $KeepXEventsRunning,
    [switch] $SkipProcmonConvert
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'FsPoc.Common.psm1') -Force

$statePath = Join-Path $ResultsDir 'capture-state.json'
if (-not (Test-Path -LiteralPath $statePath)) { throw "No capture-state.json in $ResultsDir" }
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
$cfg   = Get-FsPocConfig -Path $state.ConfigPath

# ---------------------------------------------------------------------------
# Procmon
# ---------------------------------------------------------------------------
if ($state.ProcmonJob) {
    $job = Get-Job -Name $state.ProcmonJob -ErrorAction SilentlyContinue
    if ($job) {
        if ($job.State -eq 'Running') {
            Write-FsPocLog 'Procmon window still open; terminating early.' 'WARN'
            & $cfg.ProcmonExe /AcceptEula /Terminate 2>&1 | Out-Null
            $null = Wait-Job $job -Timeout 120
        }
        Receive-Job $job -ErrorAction SilentlyContinue | Out-Null
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    }
    # Anything still holding the driver open
    Get-Process -Name 'Procmon*' -ErrorAction SilentlyContinue | ForEach-Object {
        & $cfg.ProcmonExe /AcceptEula /Terminate 2>&1 | Out-Null
    }
}

if ($state.ProcmonPml -and (Test-Path -LiteralPath $state.ProcmonPml)) {
    $pmlSize = (Get-Item -LiteralPath $state.ProcmonPml).Length
    Write-FsPocLog ("Procmon backing file: {0}" -f (Format-FsPocBytes $pmlSize)) 'OK'

    if (-not $SkipProcmonConvert) {
        $csv = [IO.Path]::ChangeExtension($state.ProcmonPml, '.csv')
        Write-FsPocLog 'Converting PML to CSV (this is single-threaded and slow on large traces)...' 'STEP'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        & $cfg.ProcmonExe /AcceptEula /Quiet /Minimized /OpenLog $state.ProcmonPml /SaveApplyFilter /SaveAs $csv
        $sw.Stop()
        if (Test-Path -LiteralPath $csv) {
            Write-FsPocLog ("CSV ready in {0:N0}s: {1}" -f $sw.Elapsed.TotalSeconds, $csv) 'OK'
        }
        else { Write-FsPocLog 'PML->CSV conversion produced no file. Convert manually from the Procmon UI.' 'WARN' }
    }
}

# ---------------------------------------------------------------------------
# Perfmon
# ---------------------------------------------------------------------------
if ($state.PerfmonName) {
    Write-FsPocLog "Stopping Perfmon collector $($state.PerfmonName)" 'STEP'
    & logman.exe stop   $state.PerfmonName 2>&1 | Out-Null
    & logman.exe delete $state.PerfmonName 2>&1 | Out-Null

    # logman appends a sequence suffix; find whatever it actually wrote.
    $dir  = Split-Path -Parent $state.PerfmonFile
    $base = [IO.Path]::GetFileNameWithoutExtension($state.PerfmonFile)
    $produced = @(Get-ChildItem -LiteralPath $dir -Filter "$base*.csv" -File -ErrorAction SilentlyContinue)
    foreach ($f in $produced) { Write-FsPocLog ("Perfmon data: {0} ({1})" -f $f.FullName, (Format-FsPocBytes $f.Length)) 'OK' }
    if ($produced.Count -eq 0) { Write-FsPocLog 'No Perfmon CSV produced.' 'WARN' }
}

# ---------------------------------------------------------------------------
# Extended Events
# ---------------------------------------------------------------------------
if ($state.XEventSession -and -not $KeepXEventsRunning) {
    Write-FsPocLog "Stopping XE session $($state.XEventSession)" 'STEP'
    Invoke-FsPocSql -Instance $cfg.SqlInstance -Database 'master' -NonQuery -Query @"
IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'$($state.XEventSession)')
    ALTER EVENT SESSION [$($state.XEventSession)] ON SERVER STATE = STOP;
"@ | Out-Null

    # Copy the .xel files into the run folder so the run is self-contained --
    # the next run's session will roll them over otherwise.
    $xelDest = Join-Path $ResultsDir 'xevents'
    $null = New-Item -ItemType Directory -Path $xelDest -Force
    $xels = @(Get-ChildItem -LiteralPath $cfg.XePath -Filter "$($state.XEventSession)*.xel" -File -ErrorAction SilentlyContinue)
    foreach ($x in $xels) { Copy-Item -LiteralPath $x.FullName -Destination $xelDest -Force }
    if ($xels.Count -gt 0) {
        Write-FsPocLog ("Copied {0} .xel file(s) to {1}" -f $xels.Count, $xelDest) 'OK'
        foreach ($x in $xels) { Remove-Item -LiteralPath $x.FullName -Force -ErrorAction SilentlyContinue }
    }
}

$state | Add-Member -NotePropertyName StoppedAt -NotePropertyValue (Get-Date).ToString('o') -Force
$state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $statePath -Encoding UTF8
Write-FsPocLog 'Capture stopped.' 'OK'
