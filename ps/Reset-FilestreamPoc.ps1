<#
.SYNOPSIS
    Tears the POC down completely so Setup-FilestreamPoc.ps1 can rebuild it
    from scratch. Dry run by default.

.DESCRIPTION
    Use this after changing any path in FsPocConfig.psd1. Moving a database
    file is not enough: the FILESTREAM container's leaf folder must NOT exist
    when CREATE DATABASE runs, and a container left behind by a previous build
    is the usual reason the next CREATE fails.

    It discovers the real file locations from sys.master_files rather than
    assuming the current config still describes them -- which is precisely the
    case when the config is what you just corrected.

    Nothing is deleted unless -Execute is passed.

.EXAMPLE
    .\Reset-FilestreamPoc.ps1              # show what would be removed
    .\Reset-FilestreamPoc.ps1 -Execute     # actually remove it
#>
[CmdletBinding()]
param(
    [string] $ConfigPath,
    [switch] $Execute,
    [string[]] $AlsoRemove = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptDir 'FsPocConfig.psd1' }
Import-Module (Join-Path $ScriptDir 'FsPoc.Common.psm1') -Force

$cfg = Get-FsPocConfig -Path $ConfigPath

Write-Host ''
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host ' FILESTREAM POC RESET' -ForegroundColor Cyan
Write-Host '================================================================' -ForegroundColor Cyan
if (-not $Execute) { Write-FsPocLog 'DRY RUN. Re-run with -Execute to actually remove anything.' 'WARN' }

# ---------------------------------------------------------------------------
# Where do the files actually live right now?
# ---------------------------------------------------------------------------
$dbs = @($cfg.DemoDb, $cfg.MonitorDb)
$dirsToRemove = New-Object System.Collections.Generic.List[string]

foreach ($db in $dbs) {
    $info = Invoke-FsPocSql -Instance $cfg.SqlInstance -Database 'master' -Query @"
SELECT
    Present      = CASE WHEN DB_ID(N'$db') IS NULL THEN 0 ELSE 1 END,
    LogicalName  = mf.name,
    PhysicalPath = mf.physical_name,
    FileType     = CASE mf.type WHEN 0 THEN 'ROWS' WHEN 1 THEN 'LOG' WHEN 2 THEN 'FILESTREAM' ELSE 'OTHER' END
FROM sys.master_files mf
WHERE mf.database_id = DB_ID(N'$db')
"@
    Write-Host ''
    if ($info.Rows.Count -eq 0) { Write-FsPocLog "$db : not present" 'INFO'; continue }

    Write-FsPocLog "$db :" 'STEP'
    foreach ($row in $info.Rows) {
        Write-Host ("      {0,-12} {1}" -f $row.FileType, $row.PhysicalPath) -ForegroundColor Gray
        # A FILESTREAM "file" is a directory, and it is the one that must be
        # gone before the next CREATE DATABASE.
        if ($row.FileType -eq 'FILESTREAM') { $dirsToRemove.Add([string]$row.PhysicalPath) }
    }
}

# ---------------------------------------------------------------------------
# Drop
# ---------------------------------------------------------------------------
foreach ($db in $dbs) {
    $exists = Invoke-FsPocSql -Instance $cfg.SqlInstance -Database 'master' `
                -Query "SELECT Present = CASE WHEN DB_ID(N'$db') IS NULL THEN 0 ELSE 1 END"
    if ([int]$exists.Rows[0].Present -eq 0) { continue }

    if ($Execute) {
        Write-FsPocLog "Dropping $db ..." 'STEP'
        Invoke-FsPocSql -Instance $cfg.SqlInstance -Database 'master' -NonQuery -Query @"
ALTER DATABASE [$db] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DROP DATABASE [$db];
"@ | Out-Null
        Write-FsPocLog "Dropped $db" 'OK'
    }
    else { Write-FsPocLog "WOULD DROP database $db" 'WARN' }
}

# ---------------------------------------------------------------------------
# Extended Events session
# ---------------------------------------------------------------------------
$session = 'FsPoc_Waits'
$xe = Invoke-FsPocSql -Instance $cfg.SqlInstance -Database 'master' `
        -Query "SELECT Present = CASE WHEN EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'$session') THEN 1 ELSE 0 END"
if ([int]$xe.Rows[0].Present -eq 1) {
    if ($Execute) {
        Invoke-FsPocSql -Instance $cfg.SqlInstance -Database 'master' -NonQuery -Query @"
IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'$session')
    ALTER EVENT SESSION [$session] ON SERVER STATE = STOP;
DROP EVENT SESSION [$session] ON SERVER;
"@ | Out-Null
        Write-FsPocLog "Dropped event session $session" 'OK'
    }
    else { Write-FsPocLog "WOULD DROP event session $session" 'WARN' }
}

# ---------------------------------------------------------------------------
# Directories
# ---------------------------------------------------------------------------
foreach ($extra in $AlsoRemove) { $dirsToRemove.Add($extra) }

# The configured container leaf, in case the database was already gone.
foreach ($fsRoot in @($cfg.FsPath, $cfg.FsPath2)) {
    if ([string]::IsNullOrWhiteSpace($fsRoot)) { continue }
    foreach ($suffix in '_FS1', '_FS2') {
        $leaf = Join-Path $fsRoot ("{0}{1}" -f $cfg.DemoDb, $suffix)
        if (Test-Path -LiteralPath $leaf) { $dirsToRemove.Add($leaf) }
    }
}

$unique = @($dirsToRemove | Sort-Object -Unique | Where-Object { Test-Path -LiteralPath $_ -ErrorAction SilentlyContinue })
Write-Host ''
if ($unique.Count -eq 0) { Write-FsPocLog 'No container directories left to remove.' 'OK' }
foreach ($dir in $unique) {
    if ($Execute) {
        try {
            Remove-Item -LiteralPath $dir -Recurse -Force
            Write-FsPocLog "Removed $dir" 'OK'
        }
        catch {
            Write-FsPocLog "Could not remove $dir : $($_.Exception.Message)" 'ERROR'
            Write-FsPocLog 'Something still holds a handle -- close Explorer windows, stop AV scans, and retry.' 'WARN'
        }
    }
    else { Write-FsPocLog "WOULD REMOVE directory $dir" 'WARN' }
}

Write-Host ''
if ($Execute) {
    Write-FsPocLog 'Reset complete. Re-run Setup-FilestreamPoc.ps1.' 'OK'
}
else {
    Write-FsPocLog 'Dry run finished. Re-run with -Execute to apply.' 'INFO'
}
