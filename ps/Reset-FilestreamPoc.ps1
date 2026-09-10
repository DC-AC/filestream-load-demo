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
    [string[]] $AlsoRemove = @(),
    # DROP DATABASE on a FILESTREAM database deletes the whole container
    # synchronously, so it can legitimately take minutes. It can also block
    # forever behind a session or a handle. A finite timeout distinguishes the
    # two; the default Invoke-FsPocSql timeout of 0 means "wait forever", which
    # tells you nothing.
    [int] $TimeoutSeconds = 900
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptDir 'FsPocConfig.psd1' }
Import-Module (Join-Path $ScriptDir 'FsPoc.Common.psm1') -Force

$cfg = Get-FsPocConfig -Path $ConfigPath

function Show-Blockers {
    param([string] $Instance)
    Write-Host ''
    Write-FsPocLog 'Active requests and blockers:' 'STEP'
    try {
        $r = Invoke-FsPocSql -Instance $Instance -Database 'master' -CommandTimeout 30 -Query @'
SELECT
    r.session_id, r.command, r.status, r.wait_type,
    WaitSec  = r.wait_time / 1000,
    Blocker  = r.blocking_session_id,
    DbName   = DB_NAME(r.database_id),
    PctDone  = r.percent_complete
FROM sys.dm_exec_requests r
WHERE r.session_id > 50
'@
        if ($r.Rows.Count -eq 0) { Write-Host '      (no user requests active)' -ForegroundColor Gray }
        foreach ($row in $r.Rows) {
            Write-Host ("      spid {0,-5} {1,-16} {2,-12} wait={3,-28} {4,5}s  blocked-by={5}  {6}" -f `
                $row.session_id, $row.command, $row.status, $row.wait_type, $row.WaitSec, $row.Blocker, $row.DbName) -ForegroundColor Gray
        }
    }
    catch { Write-FsPocLog "Could not read active requests: $($_.Exception.Message)" 'WARN' }
}

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

    if (-not $Execute) { Write-FsPocLog "WOULD DROP database $db" 'WARN'; continue }

    # Report what the drop has to delete. A container holding hundreds of
    # thousands of small NTFS files takes real time to remove, and knowing the
    # count up front is the difference between "slow" and "stuck".
    $fsDirs = @($info.Rows | Where-Object FileType -eq 'FILESTREAM' | ForEach-Object { $_.PhysicalPath })
    foreach ($fsDir in $fsDirs) {
        try {
            $inv = Get-ChildItem -LiteralPath $fsDir -Recurse -File -ErrorAction SilentlyContinue |
                   Measure-Object Length -Sum
            if ($inv.Count -gt 0) {
                Write-FsPocLog ("Container holds {0:N0} file(s), {1}. The drop must delete all of them." -f `
                    $inv.Count, (Format-FsPocBytes $inv.Sum)) 'INFO'
            }
        }
        catch { }
    }

    # Two statements, run separately, so the log says which one is slow.
    Write-FsPocLog "Setting $db to SINGLE_USER ..." 'STEP'
    try {
        Invoke-FsPocSql -Instance $cfg.SqlInstance -Database 'master' -NonQuery -CommandTimeout $TimeoutSeconds `
            -Query "ALTER DATABASE [$db] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;" | Out-Null
        Write-FsPocLog "$db is SINGLE_USER" 'OK'
    }
    catch {
        Write-FsPocLog "SET SINGLE_USER did not complete: $($_.Exception.Message)" 'ERROR'
        Show-Blockers -Instance $cfg.SqlInstance
        throw
    }

    Write-FsPocLog "Dropping $db (deleting the container can take minutes) ..." 'STEP'
    try {
        Invoke-FsPocSql -Instance $cfg.SqlInstance -Database 'master' -NonQuery -CommandTimeout $TimeoutSeconds `
            -Query "DROP DATABASE [$db];" | Out-Null
        Write-FsPocLog "Dropped $db" 'OK'
    }
    catch {
        Write-FsPocLog "DROP DATABASE did not complete within $TimeoutSeconds s: $($_.Exception.Message)" 'ERROR'
        Show-Blockers -Instance $cfg.SqlInstance
        Write-Host ''
        Write-Host '  If nothing is blocking, the drop is simply deleting a very large' -ForegroundColor Yellow
        Write-Host '  container. Re-run with a longer -TimeoutSeconds, or take the database' -ForegroundColor Yellow
        Write-Host '  offline and remove the container from the filesystem instead:' -ForegroundColor Yellow
        Write-Host ("      ALTER DATABASE [$db] SET OFFLINE WITH ROLLBACK IMMEDIATE;") -ForegroundColor Gray
        Write-Host ("      DROP DATABASE [$db];") -ForegroundColor Gray
        throw
    }
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
