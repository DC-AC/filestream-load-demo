<#
.SYNOPSIS
    Analyses a Process Monitor CSV export against the FILESTREAM container.

.DESCRIPTION
    Answers the questions that DMVs structurally cannot answer for FILESTREAM:

      * What sequence of NTFS operations does sqlservr.exe actually perform per
        FILESTREAM file? (CreateFile / SetEndOfFile / WriteFile xN / FlushBuffers
        / CloseFile -- and how many of each)
      * What write size is actually reaching the file system, versus the chunk
        size the client asked for?
      * Where is the wall-clock time going: the data writes, or the metadata
        operations around them?
      * Is anything other than SQL Server touching the container? (Antivirus is
        the classic finding here, and it is invisible from inside SQL Server.)
      * Are there non-SUCCESS results being retried?

    REQUIRED: the CSV must include a Duration column. Procmon does not export it
    by default -- in the Procmon UI, Options > Select Columns > tick "Duration"
    BEFORE saving the CSV, or save a .pmc with it enabled and pass that to
    Start-PocCapture.ps1 -ProcmonConfig. Without it this script still reports
    operation counts and sizes, but no latency.

.EXAMPLE
    .\Measure-ProcmonLog.ps1 -CsvPath C:\FsPocResults\run_.._Filestream\procmon.csv
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $CsvPath,
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'FsPocConfig.psd1'),
    [string] $ContainerPath,
    [string] $ProcessFilter = 'sqlservr.exe',
    [int]    $SampleFileCount = 3,
    [switch] $IncludeAllProcesses
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'FsPoc.Common.psm1') -Force
Add-Type -AssemblyName Microsoft.VisualBasic

$cfg = Get-FsPocConfig -Path $ConfigPath
if (-not $ContainerPath) { $ContainerPath = $cfg.FsPath }
if (-not (Test-Path -LiteralPath $CsvPath)) { throw "Procmon CSV not found: $CsvPath" }

Write-FsPocLog ("Parsing {0} ({1})" -f $CsvPath, (Format-FsPocBytes (Get-Item -LiteralPath $CsvPath).Length)) 'STEP'
Write-FsPocLog "Container filter: $ContainerPath"

$parser = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($CsvPath)
$parser.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
$parser.SetDelimiters(',')
$parser.HasFieldsEnclosedInQuotes = $true

# Column indexes are resolved from the header, because which columns Procmon
# exports depends on what was ticked in the UI.
$header = $parser.ReadFields()
$idx = @{}
for ($i = 0; $i -lt $header.Length; $i++) { $idx[$header[$i].Trim()] = $i }
foreach ($req in 'Process Name', 'Operation', 'Path', 'Result') {
    if (-not $idx.ContainsKey($req)) { throw "Procmon CSV is missing the '$req' column. Re-export with the default columns plus Duration." }
}
$hasDuration = $idx.ContainsKey('Duration')
$hasDetail   = $idx.ContainsKey('Detail')
$hasTime     = $idx.ContainsKey('Time of Day')
if (-not $hasDuration) {
    Write-FsPocLog 'No Duration column -- latency analysis will be skipped. See the help for how to enable it.' 'WARN'
}

$byOp        = @{}   # Operation -> stats
$byProcess   = @{}   # Process   -> event count (contamination check)
$byResult    = @{}   # Result    -> count
$writeSizes  = @{}   # bytes     -> count
$perSecond   = @{}   # second    -> count
$fileOps     = @{}   # path      -> ordered op list (only for the sample files)
$sampleFiles = New-Object System.Collections.Generic.List[string]
$rowCount = 0; $matched = 0

$reLen = [regex]'Length:\s*([\d,]+)'
$sw = [Diagnostics.Stopwatch]::StartNew()

try {
    while (-not $parser.EndOfData) {
        try { $f = $parser.ReadFields() } catch { continue }
        $rowCount++
        if ($rowCount % 500000 -eq 0) {
            Write-Host ("`r  parsed {0:N0} rows, {1:N0} matched..." -f $rowCount, $matched) -NoNewline -ForegroundColor DarkGray
        }

        $proc = $f[$idx['Process Name']]
        $path = $f[$idx['Path']]

        # Contamination check runs across ALL processes touching the container:
        # this is how an antivirus or backup agent gets caught.
        if ($path -and $path.StartsWith($ContainerPath, [StringComparison]::OrdinalIgnoreCase)) {
            if (-not $byProcess.ContainsKey($proc)) { $byProcess[$proc] = 0 }
            $byProcess[$proc]++
        }
        else { continue }

        if (-not $IncludeAllProcesses -and $proc -ne $ProcessFilter) { continue }
        $matched++

        $op  = $f[$idx['Operation']]
        $res = $f[$idx['Result']]
        $dur = if ($hasDuration) { [double]($f[$idx['Duration']] -replace '[^\d\.]', '') } else { 0.0 }

        if (-not $byOp.ContainsKey($op)) {
            $byOp[$op] = [pscustomobject]@{ Operation = $op; Count = [long]0; TotalSec = 0.0; MaxSec = 0.0; Bytes = [long]0 }
        }
        $o = $byOp[$op]
        $o.Count++
        $o.TotalSec += $dur
        if ($dur -gt $o.MaxSec) { $o.MaxSec = $dur }

        if (-not $byResult.ContainsKey($res)) { $byResult[$res] = 0 }
        $byResult[$res]++

        if ($hasDetail -and ($op -eq 'WriteFile' -or $op -eq 'ReadFile')) {
            $m = $reLen.Match($f[$idx['Detail']])
            if ($m.Success) {
                $len = [long]($m.Groups[1].Value -replace ',', '')
                $o.Bytes += $len
                if (-not $writeSizes.ContainsKey($len)) { $writeSizes[$len] = 0 }
                $writeSizes[$len]++
            }
        }

        if ($hasTime) {
            $sec = $f[$idx['Time of Day']]
            if ($sec.Length -ge 8) {
                $k = $sec.Substring(0, 8)
                if (-not $perSecond.ContainsKey($k)) { $perSecond[$k] = 0 }
                $perSecond[$k]++
            }
        }

        # Capture the full operation sequence for a handful of individual files.
        if ($sampleFiles.Count -lt $SampleFileCount -and $op -eq 'CreateFile' -and $path -match '\\[0-9a-f-]{8,}' ) {
            if (-not $fileOps.ContainsKey($path)) {
                $sampleFiles.Add($path)
                $fileOps[$path] = New-Object System.Collections.Generic.List[object]
            }
        }
        if ($fileOps.ContainsKey($path)) {
            $fileOps[$path].Add([pscustomobject]@{
                Op = $op; Result = $res; Sec = $dur
                Detail = if ($hasDetail) { $f[$idx['Detail']] } else { '' }
            })
        }
    }
}
finally { $parser.Close(); $parser.Dispose() }
$sw.Stop()
Write-Host ''
Write-FsPocLog ("Parsed {0:N0} rows in {1:N0}s; {2:N0} matched the container + process filter." -f $rowCount, $sw.Elapsed.TotalSeconds, $matched) 'OK'

if ($matched -eq 0) {
    Write-FsPocLog "Nothing matched. Check that -ContainerPath ('$ContainerPath') is the real container root and that Procmon's own filter was not already excluding it." 'ERROR'
    return
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- Operations against the FILESTREAM container -------------------' -ForegroundColor Cyan
$ops = $byOp.Values | Sort-Object -Property TotalSec -Descending
$ops | Format-Table -AutoSize @(
    @{ N = 'Operation';  E = { $_.Operation } }
    @{ N = 'Count';      E = { '{0:N0}' -f $_.Count } }
    @{ N = 'TotalSec';   E = { '{0:N3}' -f $_.TotalSec } }
    @{ N = 'AvgMs';      E = { '{0:N4}' -f ($_.TotalSec * 1000 / [Math]::Max($_.Count, 1)) } }
    @{ N = 'MaxMs';      E = { '{0:N3}' -f ($_.MaxSec * 1000) } }
    @{ N = 'MB';         E = { '{0:N1}' -f ($_.Bytes / 1MB) } }
    @{ N = 'PctTime';    E = { '{0:N1}' -f (100 * $_.TotalSec / [Math]::Max(($ops | Measure-Object TotalSec -Sum).Sum, 0.0001)) } }
)

# Per-file cost, the headline number for FILESTREAM: how many NTFS operations
# does one logical "save a file" actually cost?
$creates = if ($byOp.ContainsKey('CreateFile')) { $byOp['CreateFile'].Count } else { 0 }
if ($creates -gt 0) {
    $totalOps = ($ops | Measure-Object Count -Sum).Sum
    Write-Host ''
    Write-FsPocLog ("{0:N0} CreateFile calls -> {1:N1} NTFS operations per file opened." -f $creates, ($totalOps / $creates)) 'OK'
    $meta = @('CreateFile','CloseFile','SetEndOfFileInformationFile','SetAllocationInformationFile',
              'QueryBasicInformationFile','QueryStandardInformationFile','FlushBuffersFile','SetBasicInformationFile')
    $metaSec = ($ops | Where-Object { $meta -contains $_.Operation } | Measure-Object TotalSec -Sum).Sum
    $dataSec = ($ops | Where-Object { $_.Operation -in 'WriteFile','ReadFile' } | Measure-Object TotalSec -Sum).Sum
    if (($metaSec + $dataSec) -gt 0) {
        Write-FsPocLog ("Metadata ops: {0:N1}% of traced time; data transfer: {1:N1}%." -f `
            (100 * $metaSec / ($metaSec + $dataSec)), (100 * $dataSec / ($metaSec + $dataSec))) 'OK'
        if ($metaSec -gt $dataSec) {
            Write-FsPocLog 'Metadata dominates. That is the signature of a small-file workload -- the case where FILESTREAM typically loses to in-table LOB storage.' 'WARN'
        }
    }
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- Actual I/O sizes reaching NTFS --------------------------------' -ForegroundColor Cyan
Write-FsPocLog "Compare these against the configured chunk size ($($cfg.ChunkSizeKB) KB). A mismatch means something between you and the disk is re-blocking the I/O." 'INFO'
$writeSizes.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 15 |
    Format-Table -AutoSize @(
        @{ N = 'IoSize'; E = { Format-FsPocBytes $_.Key } }
        @{ N = 'Count';  E = { '{0:N0}' -f $_.Value } }
        @{ N = 'TotalMB'; E = { '{0:N1}' -f ($_.Key * $_.Value / 1MB) } }
    )

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- Every process touching the container --------------------------' -ForegroundColor Cyan
Write-FsPocLog 'Anything here other than sqlservr.exe (and your ingest client) is overhead you did not intend to measure.' 'INFO'
$byProcess.GetEnumerator() | Sort-Object -Property Value -Descending |
    Format-Table -AutoSize @(
        @{ N = 'Process'; E = { $_.Key } }
        @{ N = 'Events';  E = { '{0:N0}' -f $_.Value } }
    )
$intruders = @($byProcess.Keys | Where-Object { $_ -notin @($ProcessFilter, 'System', 'powershell.exe', 'pwsh.exe', 'Procmon64.exe', 'Procmon.exe') })
if ($intruders.Count -gt 0) {
    Write-FsPocLog ("Unexpected processes in the container: {0}" -f ($intruders -join ', ')) 'WARN'
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- Results (non-SUCCESS means retries or failures) ---------------' -ForegroundColor Cyan
$byResult.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 12 |
    Format-Table -AutoSize @{ N = 'Result'; E = { $_.Key } }, @{ N = 'Count'; E = { '{0:N0}' -f $_.Value } }

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- Operation sequence for sample individual files -----------------' -ForegroundColor Cyan
Write-FsPocLog 'This is the per-file anatomy of a FILESTREAM write.' 'INFO'
foreach ($p in $sampleFiles) {
    Write-Host ''
    Write-Host "  $p" -ForegroundColor White
    $seq = $fileOps[$p]
    $seq | Group-Object Op | Sort-Object Count -Descending |
        ForEach-Object { Write-Host ('    {0,-34} x{1}' -f $_.Name, $_.Count) -ForegroundColor Gray }
    Write-Host ('    -- first 20 in order --') -ForegroundColor DarkGray
    $seq | Select-Object -First 20 | ForEach-Object {
        Write-Host ('    {0,-34} {1,-12} {2}' -f $_.Op, $_.Result, ($_.Detail -replace '\s+', ' ').Substring(0, [Math]::Min(70, ($_.Detail -replace '\s+', ' ').Length))) -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------------------------
$outDir = Split-Path -Parent $CsvPath
$summaryPath = Join-Path $outDir 'procmon-summary.csv'
$ops | Select-Object Operation, Count, TotalSec,
        @{ N = 'AvgMs'; E = { $_.TotalSec * 1000 / [Math]::Max($_.Count, 1) } },
        @{ N = 'MaxMs'; E = { $_.MaxSec * 1000 } }, Bytes |
    Export-Csv -LiteralPath $summaryPath -NoTypeInformation -Encoding UTF8

$timelinePath = Join-Path $outDir 'procmon-timeline.csv'
$perSecond.GetEnumerator() | Sort-Object Name |
    Select-Object @{ N = 'Second'; E = { $_.Key } }, @{ N = 'Operations'; E = { $_.Value } } |
    Export-Csv -LiteralPath $timelinePath -NoTypeInformation -Encoding UTF8

Write-Host ''
Write-FsPocLog "Wrote $summaryPath" 'OK'
Write-FsPocLog "Wrote $timelinePath" 'OK'
