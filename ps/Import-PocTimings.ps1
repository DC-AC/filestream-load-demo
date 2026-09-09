<#
.SYNOPSIS
    Bulk-loads the per-worker timing CSVs produced by Invoke-FilestreamIngest.ps1
    into FsPocMonitor.dbo.IngestTiming.

.DESCRIPTION
    Workers each write their own CSV rather than contending on a shared sink --
    at a few hundred thousand files, a lock-protected shared writer becomes a
    measurable part of the thing being measured. This script stitches them back
    together via SqlBulkCopy after the run.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [guid]   $RunId,
    [Parameter(Mandatory)] [string] $ResultsDir,
    [string] $ConfigPath,
    [int]    $BatchSize  = 10000
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

$cfg = Get-FsPocConfig -Path $ConfigPath
$csvFiles = @(Get-ChildItem -LiteralPath $ResultsDir -Filter 'timings_w*.csv' -File)
if ($csvFiles.Count -eq 0) { Write-FsPocLog "No timing CSVs in $ResultsDir" 'WARN'; return }

$dt = New-Object System.Data.DataTable
foreach ($c in @(
    @{ N = 'RunId';        T = [guid] },
    @{ N = 'WorkerId';     T = [int] },
    @{ N = 'Seq';          T = [long] },
    @{ N = 'Bucket';       T = [string] },
    @{ N = 'FileName';     T = [string] },
    @{ N = 'SizeBytes';    T = [long] },
    @{ N = 'StartedAtUtc'; T = [datetime] },
    @{ N = 'OpenMs';       T = [double] },
    @{ N = 'WriteMs';      T = [double] },
    @{ N = 'CommitMs';     T = [double] },
    @{ N = 'TotalMs';      T = [double] })) {
    $null = $dt.Columns.Add($c.N, $c.T)
}

$cs = Get-FsPocConnectionString -Instance $cfg.SqlInstance -Database $cfg.MonitorDb
$conn = New-Object System.Data.SqlClient.SqlConnection $cs
$conn.Open()
$bulk = New-Object System.Data.SqlClient.SqlBulkCopy($conn)
$bulk.DestinationTableName = 'dbo.IngestTiming'
$bulk.BatchSize = $BatchSize
$bulk.BulkCopyTimeout = 0
foreach ($col in $dt.Columns) { $null = $bulk.ColumnMappings.Add($col.ColumnName, $col.ColumnName) }

$total = 0
try {
    foreach ($f in $csvFiles) {
        $reader = New-Object System.IO.StreamReader($f.FullName)
        try {
            $null = $reader.ReadLine()   # header
            while ($null -ne ($line = $reader.ReadLine())) {
                # FileName is synthesised without commas, so a plain split is safe.
                $p = $line.Split(',')
                if ($p.Length -lt 10) { continue }
                $row = $dt.NewRow()
                $row['RunId']        = $RunId
                $row['WorkerId']     = [int]$p[0]
                $row['Seq']          = [long]$p[1]
                $row['Bucket']       = $p[2]
                $row['FileName']     = $p[3]
                $row['SizeBytes']    = [long]$p[4]
                $row['StartedAtUtc'] = [datetime]::ParseExact($p[5], 'yyyy-MM-dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture)
                $row['OpenMs']       = [double]$p[6]
                $row['WriteMs']      = [double]$p[7]
                $row['CommitMs']     = [double]$p[8]
                $row['TotalMs']      = [double]$p[9]
                $dt.Rows.Add($row)

                if ($dt.Rows.Count -ge $BatchSize) {
                    $bulk.WriteToServer($dt); $total += $dt.Rows.Count; $dt.Clear()
                }
            }
        }
        finally { $reader.Dispose() }
    }
    if ($dt.Rows.Count -gt 0) { $bulk.WriteToServer($dt); $total += $dt.Rows.Count; $dt.Clear() }
}
finally { $bulk.Close(); $conn.Dispose() }

Write-FsPocLog ("Imported {0:N0} timing rows from {1} worker files." -f $total, $csvFiles.Count) 'OK'
