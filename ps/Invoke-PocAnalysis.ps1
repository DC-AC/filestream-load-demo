<#
.SYNOPSIS
    Runs the analysis for a completed run, without re-running the load.

.DESCRIPTION
    Ingest and analysis are separate concerns, and a 200 GB load is far too
    expensive to repeat because the reporting stage failed. Everything the
    analysis needs is already durable once the load finishes:

      * wait-stat, file-stat and perf-counter snapshots are committed to
        FsPocMonitor before the ingest returns;
      * per-file timings are written to per-worker CSVs in the run folder as
        the run proceeds;
      * the Procmon backing file and the .xel files are on disk.

    So this re-runs the reporting against whatever survived, skipping anything
    that is missing rather than failing.

    -List first: it shows every run and exactly which artefacts exist for it.

.EXAMPLE
    .\Invoke-PocAnalysis.ps1 -List

.EXAMPLE
    .\Invoke-PocAnalysis.ps1                       # newest run, everything cheap
    .\Invoke-PocAnalysis.ps1 -ConvertProcmon       # also do the expensive PML->CSV
#>
[CmdletBinding()]
param(
    [guid]   $RunId,
    [string] $ResultsDir,
    [string] $ConfigPath,
    [switch] $List,
    [switch] $SkipTimings,
    [switch] $SkipSql,
    [switch] $SkipProcmon,
    [switch] $SkipXEvents,
    # PML -> CSV is single-threaded and writes a file that can be larger than
    # the trace itself. Opt in deliberately.
    [switch] $ConvertProcmon
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptDir 'FsPocConfig.psd1' }
Import-Module (Join-Path $ScriptDir 'FsPoc.Common.psm1') -Force

$cfg    = Get-FsPocConfig -Path $ConfigPath
$sqlDir = Join-Path (Split-Path -Parent $ScriptDir) 'sql'

# ---------------------------------------------------------------------------
# Inventory
# ---------------------------------------------------------------------------
$runs = Invoke-FsPocSql -Instance $cfg.SqlInstance -Database $cfg.MonitorDb -Query @'
SELECT
    r.RunId, r.RunName, r.Scenario, r.SizeProfile, r.Threads, r.ChunkSizeKB,
    r.StartedAtUtc, r.EndedAtUtc,
    GB          = CONVERT(decimal(18,2), r.ActualBytes / 1073741824.0),
    Files       = r.FileCount,
    WaitSnaps   = (SELECT COUNT(DISTINCT Phase) FROM dbo.WaitSnapshot      w WHERE w.RunId = r.RunId),
    FileSnaps   = (SELECT COUNT(DISTINCT Phase) FROM dbo.FileStatsSnapshot f WHERE f.RunId = r.RunId),
    Timings     = (SELECT COUNT_BIG(*)          FROM dbo.IngestTiming      t WHERE t.RunId = r.RunId),
    Samples     = (SELECT COUNT_BIG(*)          FROM dbo.ActivitySample    a WHERE a.RunId = r.RunId),
    r.Notes
FROM dbo.PocRun r
ORDER BY r.StartedAtUtc DESC
'@

if ($runs.Rows.Count -eq 0) { throw "No runs recorded in $($cfg.MonitorDb).dbo.PocRun." }

function Get-RunFolder {
    param($NotesText)
    if ($NotesText -and $NotesText -match 'results=(.+?)(?:;|$)') { return $Matches[1].Trim() }
    return $null
}

if ($List) {
    Write-Host ''
    Write-Host ' Runs and the artefacts that survive for each' -ForegroundColor Cyan
    Write-Host ' ------------------------------------------------------------------' -ForegroundColor DarkGray
    foreach ($r in $runs.Rows) {
        $done = if ($r.EndedAtUtc -is [DBNull]) { 'INCOMPLETE' } else { 'completed ' }
        Write-Host ''
        Write-Host ("  {0}  {1}" -f $r.RunId, $r.RunName) -ForegroundColor White
        Write-Host ("     {0}  started {1}  {2} GB in {3} files" -f $done, $r.StartedAtUtc, $r.GB, $r.Files) -ForegroundColor Gray
        Write-Host ("     wait snapshots: {0}/2   file snapshots: {1}/2   timings: {2:N0}   samples: {3:N0}" -f `
            $r.WaitSnaps, $r.FileSnaps, $r.Timings, $r.Samples) -ForegroundColor Gray
        $folder = Get-RunFolder $r.Notes
        if ($folder) {
            $exists = Test-Path -LiteralPath $folder
            Write-Host ("     folder: {0} {1}" -f $folder, $(if ($exists) { '' } else { '(MISSING)' })) -ForegroundColor Gray
            if ($exists) {
                $csvs = @(Get-ChildItem -LiteralPath $folder -Filter 'timings_w*.csv' -File -EA SilentlyContinue)
                $pml  = Join-Path $folder 'procmon.pml'
                $pcsv = Join-Path $folder 'procmon.csv'
                $xel  = Join-Path $folder 'xevents'
                Write-Host ("     timing CSVs: {0}   procmon.pml: {1}   procmon.csv: {2}   xel: {3}" -f `
                    $csvs.Count,
                    $(if (Test-Path $pml)  { Format-FsPocBytes (Get-Item $pml).Length }  else { 'no' }),
                    $(if (Test-Path $pcsv) { Format-FsPocBytes (Get-Item $pcsv).Length } else { 'no' }),
                    $(if (Test-Path $xel)  { 'yes' } else { 'no' })) -ForegroundColor Gray
            }
        }
    }
    Write-Host ''
    Write-FsPocLog 'A run with 2/2 wait snapshots has everything the SQL analysis needs.' 'INFO'
    return
}

# ---------------------------------------------------------------------------
# Pick the run
# ---------------------------------------------------------------------------
if (-not $PSBoundParameters.ContainsKey('RunId')) {
    $chosen = $runs.Rows | Where-Object { $_.EndedAtUtc -isnot [DBNull] } | Select-Object -First 1
    if (-not $chosen) { $chosen = $runs.Rows[0] }
    $RunId = [guid]$chosen.RunId
}
else { $chosen = $runs.Rows | Where-Object { [guid]$_.RunId -eq $RunId } | Select-Object -First 1 }
if (-not $chosen) { throw "RunId $RunId not found." }

if (-not $ResultsDir) { $ResultsDir = Get-RunFolder $chosen.Notes }

Write-Host ''
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host ' FILESTREAM POC ANALYSIS' -ForegroundColor Cyan
Write-Host '================================================================' -ForegroundColor Cyan
Write-FsPocLog "RunId   : $RunId"
Write-FsPocLog "Run     : $($chosen.RunName)"
Write-FsPocLog "Loaded  : $($chosen.GB) GB in $($chosen.Files) files"
Write-FsPocLog "Folder  : $(if ($ResultsDir) { $ResultsDir } else { '(unknown)' })"

if ([int]$chosen.WaitSnaps -lt 2) {
    Write-FsPocLog "Only $($chosen.WaitSnaps)/2 wait snapshots exist. The wait analysis needs both 'start' and 'end' and will be empty." 'WARN'
}

# ---------------------------------------------------------------------------
# 1. Timings
# ---------------------------------------------------------------------------
if (-not $SkipTimings -and $ResultsDir -and (Test-Path -LiteralPath $ResultsDir)) {
    if ([long]$chosen.Timings -gt 0) {
        Write-FsPocLog ("Timings already imported ({0:N0} rows). Skipping." -f $chosen.Timings) 'OK'
    }
    else {
        $csvs = @(Get-ChildItem -LiteralPath $ResultsDir -Filter 'timings_w*.csv' -File -EA SilentlyContinue)
        if ($csvs.Count -gt 0) {
            Write-FsPocLog "Importing per-file timings from $($csvs.Count) worker CSV(s)..." 'STEP'
            & (Join-Path $ScriptDir 'Import-PocTimings.ps1') -RunId $RunId -ResultsDir $ResultsDir -ConfigPath $ConfigPath
        }
        else { Write-FsPocLog 'No timing CSVs found.' 'WARN' }
    }
}

# ---------------------------------------------------------------------------
# 2. SQL analysis
# ---------------------------------------------------------------------------
if (-not $SkipSql) {
    Write-Host ''
    Write-FsPocLog 'Running the SQL analysis...' 'STEP'
    $out = if ($ResultsDir -and (Test-Path -LiteralPath $ResultsDir)) { Join-Path $ResultsDir 'analysis.txt' }
           else { Join-Path $cfg.ResultsPath ("analysis_{0}.txt" -f $RunId.ToString('N')) }
    Invoke-FsPocSql -Instance $cfg.SqlInstance `
        -InputFile (Join-Path $sqlDir '05-analysis.sql') `
        -SqlcmdVariables @{ RunId = $RunId; TopWaits = 25 } `
        -ExtraArgs @('-y', '0', '-Y', '40', '-W', '-s', '|') |
        Tee-Object -FilePath $out
    Write-FsPocLog "Saved to $out" 'OK'
}

# ---------------------------------------------------------------------------
# 3. Procmon
# ---------------------------------------------------------------------------
if (-not $SkipProcmon -and $ResultsDir -and (Test-Path -LiteralPath $ResultsDir)) {
    $pml  = Join-Path $ResultsDir 'procmon.pml'
    $pcsv = Join-Path $ResultsDir 'procmon.csv'

    if (-not (Test-Path -LiteralPath $pcsv) -and (Test-Path -LiteralPath $pml)) {
        $pmlSize = (Get-Item -LiteralPath $pml).Length
        if ($ConvertProcmon) {
            Write-FsPocLog ("Converting {0} of PML to CSV. Single-threaded; expect this to take a while." -f (Format-FsPocBytes $pmlSize)) 'STEP'
            & $cfg.ProcmonExe /AcceptEula /Quiet /Minimized /OpenLog $pml /SaveApplyFilter /SaveAs $pcsv
        }
        else {
            Write-FsPocLog ("procmon.pml is present ({0}) but not converted." -f (Format-FsPocBytes $pmlSize)) 'WARN'
            Write-FsPocLog 'Re-run with -ConvertProcmon to convert and analyse it. It writes a large CSV.' 'INFO'
        }
    }

    if (Test-Path -LiteralPath $pcsv) {
        Write-Host ''
        Write-FsPocLog 'Analysing the Procmon trace...' 'STEP'
        & (Join-Path $ScriptDir 'Measure-ProcmonLog.ps1') -CsvPath $pcsv -ConfigPath $ConfigPath
    }
}

# ---------------------------------------------------------------------------
# 4. Extended Events
# ---------------------------------------------------------------------------
if (-not $SkipXEvents -and $ResultsDir) {
    $xelDir = Join-Path $ResultsDir 'xevents'
    $xelSrc = if (Test-Path -LiteralPath $xelDir) { $xelDir } else { $cfg.XePath }
    $xels = @(Get-ChildItem -LiteralPath $xelSrc -Filter 'FsPoc_Waits*.xel' -File -EA SilentlyContinue)
    if ($xels.Count -gt 0) {
        Write-Host ''
        Write-FsPocLog "Shredding $($xels.Count) .xel file(s) from $xelSrc ..." 'STEP'
        $xeOut = Join-Path (Split-Path -Parent $xelSrc) 'xevents-analysis.txt'
        try {
            Invoke-FsPocSql -Instance $cfg.SqlInstance `
                -InputFile (Join-Path $sqlDir '06-xevent-shred.sql') `
                -SqlcmdVariables @{ XePath = $xelSrc; SessionName = 'FsPoc_Waits' } `
                -ExtraArgs @('-y', '0', '-Y', '40', '-W', '-s', '|') |
                Tee-Object -FilePath $xeOut
            Write-FsPocLog "Saved to $xeOut" 'OK'
        }
        catch { Write-FsPocLog "XEvent shred failed: $($_.Exception.Message)" 'WARN' }
    }
    else { Write-FsPocLog 'No .xel files found.' 'INFO' }
}

Write-Host ''
Write-FsPocLog 'Analysis complete.' 'OK'
