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
    [int] $TimeoutSeconds = 900,
    <#  Also drop the monitoring database.

        Off by default, and deliberately so. FsPocMonitor exists precisely to
        OUTLIVE the demo database -- 03-monitor-db.sql says so in its header --
        because it accumulates the run history that section 8 of the analysis
        compares across configurations. Dropping it discards every previous
        run's wait snapshots and per-file timings, which is exactly the data a
        disk or VM change is being measured against.

        Reset was dropping it by default, which contradicted its whole purpose.
    #>
    [switch] $IncludeMonitorDb
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

if ($IncludeMonitorDb) {
    Write-FsPocLog "-IncludeMonitorDb: $($cfg.MonitorDb) WILL be dropped, discarding all previous run history." 'WARN'
}
else {
    # Say what is being kept, so it is not a silent assumption either way.
    try {
        $hist = Invoke-FsPocSql -Instance $cfg.SqlInstance -Database $cfg.MonitorDb -CommandTimeout 30 `
                  -Query 'SELECT Runs = COUNT(*), Timings = (SELECT COUNT_BIG(*) FROM dbo.IngestTiming) FROM dbo.PocRun'
        Write-FsPocLog ("Keeping $($cfg.MonitorDb): {0} run(s), {1:N0} timing rows. Use -IncludeMonitorDb to drop it too." -f `
            $hist.Rows[0].Runs, $hist.Rows[0].Timings) 'OK'
    }
    catch { Write-FsPocLog "Keeping $($cfg.MonitorDb) (could not read its contents: $($_.Exception.Message))" 'INFO' }
}

# ---------------------------------------------------------------------------
# Where do the files actually live right now?
# ---------------------------------------------------------------------------
$dbs = @($cfg.DemoDb)
if ($IncludeMonitorDb) { $dbs += $cfg.MonitorDb }
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

    # This database's own files, read before the drop removes the metadata.
    $fileRows = Invoke-FsPocSql -Instance $cfg.SqlInstance -Database 'master' -CommandTimeout 60 -Query @"
SELECT PhysicalPath = mf.physical_name, IsContainer = CASE WHEN mf.type = 2 THEN 1 ELSE 0 END
FROM sys.master_files mf WHERE mf.database_id = DB_ID(N'$db')
"@
    $dbFiles = @($fileRows.Rows | Where-Object { [int]$_.IsContainer -eq 0 } | ForEach-Object { [string]$_.PhysicalPath })
    foreach ($c in @($fileRows.Rows | Where-Object { [int]$_.IsContainer -eq 1 })) {
        $dirsToRemove.Add([string]$c.PhysicalPath)
    }

    <#  Report what the drop has to delete, so a long delete reads as slow
        rather than stuck.

        Asked of SQL Server, not of the file system. The previous version walked
        the container with Get-ChildItem -Recurse, which on a container holding
        a few hundred thousand files across a deep GUID directory tree takes
        minutes on its own -- before deleting anything, purely to print one
        line. The row counts and byte totals are already indexed in the
        database and answer the same question instantly.
    #>
    try {
        $inv = Invoke-FsPocSql -Instance $cfg.SqlInstance -Database $db -CommandTimeout 60 -Query @'
SELECT
    Files = ISNULL((SELECT COUNT_BIG(*) FROM dbo.FileStore), 0)
          + ISNULL((SELECT COUNT_BIG(*) FROM dbo.FileStoreFT WHERE is_directory = 0), 0),
    Bytes = ISNULL((SELECT SUM(SizeBytes) FROM dbo.FileStore), 0)
          + ISNULL((SELECT SUM(CONVERT(bigint, DATALENGTH(file_stream))) FROM dbo.FileStoreFT WHERE is_directory = 0), 0)
'@
        $files = [long]$inv.Rows[0].Files
        if ($files -gt 0) {
            Write-FsPocLog ("Container holds {0:N0} file(s), {1}. DROP DATABASE must delete every one of them, so allow minutes." -f `
                $files, (Format-FsPocBytes ([double]$inv.Rows[0].Bytes))) 'INFO'
        }
    }
    catch {
        # A database with no FileStore/FileStoreFT, or one already unusable.
        Write-FsPocLog 'Could not size the container from the database; proceeding.' 'INFO'
    }

    <#  Teardown order: OFFLINE, then DROP, then delete the files ourselves.

        DROP DATABASE on an ONLINE FILESTREAM database deletes the whole
        container synchronously inside the statement. On 323,689 files that ran
        past 900 seconds with nothing blocking it -- it was simply doing 323,689
        NTFS deletes one statement deep, with no progress and no way to
        interrupt it safely.

        Taking the database offline first makes the DROP a metadata operation.
        The container is then removed from the file system directly, where
        `rd /s /q` is markedly faster than either SQL Server or
        Remove-Item -Recurse, and where progress is visible.

        The file deletion is written to run whether or not the DROP already
        removed them, so it is correct either way rather than depending on that
        behaviour.
    #>
    $state = Invoke-FsPocSql -Instance $cfg.SqlInstance -Database 'master' -CommandTimeout 60 `
               -Query "SELECT StateDesc = state_desc FROM sys.databases WHERE name = N'$db'"
    $currentState = if ($state.Rows.Count -gt 0) { [string]$state.Rows[0].StateDesc } else { 'GONE' }
    Write-FsPocLog "$db is currently $currentState" 'INFO'

    if ($currentState -ne 'GONE') {
        if ($currentState -ne 'OFFLINE') {
            Write-FsPocLog "Taking $db offline ..." 'STEP'
            try {
                Invoke-FsPocSql -Instance $cfg.SqlInstance -Database 'master' -NonQuery -CommandTimeout $TimeoutSeconds `
                    -Query "ALTER DATABASE [$db] SET OFFLINE WITH ROLLBACK IMMEDIATE;" | Out-Null
                Write-FsPocLog "$db is offline" 'OK'
            }
            catch {
                Write-FsPocLog "SET OFFLINE did not complete: $($_.Exception.Message)" 'ERROR'
                Show-Blockers -Instance $cfg.SqlInstance
                throw
            }
        }

        Write-FsPocLog "Dropping $db (metadata only -- it is offline) ..." 'STEP'
        Invoke-FsPocSql -Instance $cfg.SqlInstance -Database 'master' -NonQuery -CommandTimeout $TimeoutSeconds `
            -Query "DROP DATABASE [$db];" | Out-Null
        Write-FsPocLog "Dropped $db" 'OK'
    }
    else { Write-FsPocLog "$db no longer exists; cleaning up its files." 'INFO' }

    # The MDF/LDF are left behind when an offline database is dropped, so remove
    # them too. Missing files are not an error -- the drop may have taken them.
    # $dbFiles is captured BEFORE the drop, since sys.master_files no longer
    # lists them afterwards.
    foreach ($path in $dbFiles) {
        if (Test-Path -LiteralPath $path) {
            try { Remove-Item -LiteralPath $path -Force; Write-FsPocLog "Removed $path" 'OK' }
            catch { Write-FsPocLog "Could not remove $path : $($_.Exception.Message)" 'WARN' }
        }
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
        # rd /s /q rather than Remove-Item -Recurse: on a container of a few
        # hundred thousand files the difference is minutes, because Remove-Item
        # materialises a PowerShell object per file before deleting any of them.
        Write-FsPocLog "Removing $dir (this is the slow part -- a few hundred thousand deletes) ..." 'STEP'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        & cmd.exe /c "rd /s /q `"$dir`"" 2>&1 | Out-Null
        $sw.Stop()

        if (Test-Path -LiteralPath $dir) {
            Write-FsPocLog "rd left $dir behind after $([int]$sw.Elapsed.TotalSeconds)s; retrying with Remove-Item ..." 'WARN'
            try { Remove-Item -LiteralPath $dir -Recurse -Force; Write-FsPocLog "Removed $dir" 'OK' }
            catch {
                Write-FsPocLog "Could not remove $dir : $($_.Exception.Message)" 'ERROR'
                Write-FsPocLog 'Something still holds a handle -- close Explorer windows, stop AV scans, and retry.' 'WARN'
            }
        }
        else { Write-FsPocLog ("Removed $dir in {0:N0}s" -f $sw.Elapsed.TotalSeconds) 'OK' }
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
