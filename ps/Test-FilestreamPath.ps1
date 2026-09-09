<#
.SYNOPSIS
    Step-by-step diagnosis of the SqlFileStream write path. Writes exactly one
    small file and reports precisely where it fails and why.

.DESCRIPTION
    The ingest engine catches per-file exceptions so a long run is not derailed
    by a handful of failures. That is the right behaviour for a 200 GB run and
    the wrong behaviour when nothing works at all. This script does the
    opposite: one file, no catching, maximum detail at every step.

    Run it whenever the smoke test reports errors.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\ps\Test-FilestreamPath.ps1
#>
[CmdletBinding()]
param(
    [string] $ConfigPath,
    [int]    $SizeKB = 1024,
    [switch] $KeepRow
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptDir 'FsPocConfig.psd1' }
Import-Module (Join-Path $ScriptDir 'FsPoc.Common.psm1') -Force

$cfg = Get-FsPocConfig -Path $ConfigPath
$step = 0
function Step { param([string] $Name) $script:step++; Write-Host ''; Write-Host ("[$script:step] $Name") -ForegroundColor Cyan }
function Detail { param([string] $Text, [string] $Colour = 'Gray') Write-Host "      $Text" -ForegroundColor $Colour }
function Report-NonFatal {
    # Informational steps report and continue. Only the streaming test itself
    # is allowed to be fatal: a diagnostic that aborts before reaching the
    # thing being diagnosed is worthless.
    param([string] $What, [System.Exception] $Ex)
    Write-Host "      could not determine $What" -ForegroundColor Yellow
    Write-Host ("      {0}: {1}" -f $Ex.GetType().Name, $Ex.Message) -ForegroundColor DarkYellow
    Write-Host '      (continuing -- this step is informational)' -ForegroundColor DarkGray
}

function Explain {
    param([System.Exception] $Ex)
    Write-Host ''
    Write-Host '  FAILED HERE' -ForegroundColor Red
    Detail $Ex.GetType().FullName 'Yellow'
    Detail $Ex.Message 'Yellow'
    $inner = $Ex.InnerException
    while ($inner) { Detail ("inner -> {0}: {1}" -f $inner.GetType().Name, $inner.Message) 'DarkYellow'; $inner = $inner.InnerException }
    if ($Ex -is [System.Data.SqlClient.SqlException]) {
        foreach ($e in $Ex.Errors) { Detail ("SQL {0} (state {1}, line {2}): {3}" -f $e.Number, $e.State, $e.LineNumber, $e.Message) 'DarkYellow' }
    }
}

Write-Host ''
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host ' FILESTREAM PATH DIAGNOSTIC' -ForegroundColor Cyan
Write-Host '================================================================' -ForegroundColor Cyan

# ---------------------------------------------------------------------------
Step 'Client environment'
Detail ("PowerShell     : {0} ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
Detail ("64-bit process : {0}" -f [Environment]::Is64BitProcess)
Detail ("Running as     : {0}" -f [Security.Principal.WindowsIdentity]::GetCurrent().Name)
Detail ("Elevated       : {0}" -f (Test-FsPocElevated))
Detail ("Machine        : {0}" -f $env:COMPUTERNAME)
if ($PSVersionTable.PSVersion.Major -ge 6) {
    Write-Host '  SqlFileStream does not exist in .NET Core/.NET 5+. Re-run with powershell.exe.' -ForegroundColor Red
    return
}
try { $null = [System.Data.SqlTypes.SqlFileStream]; Detail 'SqlFileStream type resolves: yes' 'Green' }
catch { Write-Host '  SqlFileStream type could not be resolved.' -ForegroundColor Red; Explain $_.Exception; return }

# ---------------------------------------------------------------------------
Step 'Instance FILESTREAM configuration'
$fsLevel = -1
$srv = $null; $r = $null; $d = $null
try {
$srv = Invoke-FsPocSql -Instance $cfg.SqlInstance -Database 'master' -Query @'
SELECT
    Version    = CONVERT(nvarchar(64), SERVERPROPERTY('ProductVersion')),
    Level      = CONVERT(int, SERVERPROPERTY('FilestreamEffectiveLevel')),
    Configured = CONVERT(int, SERVERPROPERTY('FilestreamConfiguredLevel')),
    ShareName  = CONVERT(nvarchar(128), SERVERPROPERTY('FilestreamShareName')),
    MachineName= CONVERT(nvarchar(128), SERVERPROPERTY('MachineName'))
'@
$r = $srv.Rows[0]
Detail ("SQL version    : {0}" -f $r.Version)
Detail ("Effective level: {0}   Configured: {1}" -f $r.Level, $r.Configured)
Detail ("Share name     : {0}" -f $r.ShareName)
$fsLevel = [int]$r.Level
if ($fsLevel -lt 2) {
    Write-Host '  Effective level is below 2. The Win32 streaming open will be refused.' -ForegroundColor Red
    Write-Host '  Enable it at the Windows level and RESTART the SQL Server service.' -ForegroundColor Red
}
}
catch { Report-NonFatal 'instance FILESTREAM configuration' $_.Exception }

# ---------------------------------------------------------------------------
Step "Database configuration ($($cfg.DemoDb))"
try {
# The FILESTREAM per-database settings live in sys.database_filestream_options.
# sys.databases exposes neither non_transacted_access_desc nor directory_name.
$db = Invoke-FsPocSql -Instance $cfg.SqlInstance -Database $cfg.DemoDb -Query @'
SELECT
    NonTransactedAccess = ISNULL(fo.non_transacted_access_desc, N'(not set)'),
    DirectoryName       = ISNULL(fo.directory_name, N'(not set)'),
    ContainerPath       = ISNULL((SELECT TOP 1 physical_name FROM sys.database_files WHERE type = 2), N'(no FILESTREAM file)'),
    FsFileCount         = (SELECT COUNT(*) FROM sys.database_files WHERE type = 2),
    ProcExists          = CASE WHEN OBJECT_ID('dbo.usp_BeginFileStreamInsert') IS NULL THEN 0 ELSE 1 END,
    TableExists         = CASE WHEN OBJECT_ID('dbo.FileStore') IS NULL THEN 0 ELSE 1 END
FROM (SELECT 1 AS one) AS anchor
LEFT JOIN sys.database_filestream_options fo ON fo.database_id = DB_ID()
'@
$d = $db.Rows[0]
Detail ("Container       : {0}" -f $d.ContainerPath)
Detail ("FILESTREAM files: {0}" -f $d.FsFileCount)
Detail ("Directory name  : {0}" -f $d.DirectoryName)
Detail ("Non-transacted  : {0}" -f $d.NonTransactedAccess)
Detail ("dbo.FileStore   : {0}" -f $(if ([int]$d.TableExists) { 'present' } else { 'MISSING' })) $(if ([int]$d.TableExists) { 'Gray' } else { 'Red' })
Detail ("usp_BeginFileStreamInsert : {0}" -f $(if ([int]$d.ProcExists) { 'present' } else { 'MISSING' })) $(if ([int]$d.ProcExists) { 'Gray' } else { 'Red' })
if (-not [int]$d.ProcExists -or -not [int]$d.TableExists) {
    Write-Host '  Re-run sql\02-create-database.sql.' -ForegroundColor Red
}
if (Test-Path -LiteralPath $d.ContainerPath) { Detail 'Container directory is visible to this client: yes' 'Green' }
else { Detail 'Container directory is NOT visible from this client path.' 'Yellow' }
}
catch { Report-NonFatal 'database FILESTREAM configuration' $_.Exception }

# ---------------------------------------------------------------------------
Step 'Open connection and begin transaction'
$cs = Get-FsPocConnectionString -Instance $cfg.SqlInstance -Database $cfg.DemoDb
Detail ("Connection string: {0}" -f $cs)
$conn = New-Object System.Data.SqlClient.SqlConnection $cs
$tx = $null
$rowGuid = [guid]::NewGuid()
try {
    $conn.Open()
    Detail ("Connected. Server protocol version: {0}" -f $conn.ServerVersion) 'Green'
    $tx = $conn.BeginTransaction()
    Detail 'BeginTransaction: ok' 'Green'

    # -----------------------------------------------------------------------
    Step 'Insert placeholder row and fetch PathName + transaction context'
    $cmd = $conn.CreateCommand()
    $cmd.Transaction = $tx
    $cmd.CommandType = [System.Data.CommandType]::StoredProcedure
    $cmd.CommandText = 'dbo.usp_BeginFileStreamInsert'
    $null = $cmd.Parameters.AddWithValue('@RowGuid',   $rowGuid)
    $null = $cmd.Parameters.AddWithValue('@RunId',     [guid]::Empty)
    $null = $cmd.Parameters.AddWithValue('@Bucket',    'diag')
    $null = $cmd.Parameters.AddWithValue('@FileName',  "diag/$($rowGuid.ToString('N')).bin")
    $null = $cmd.Parameters.AddWithValue('@SizeBytes', [long]($SizeKB * 1KB))

    $rdr = $cmd.ExecuteReader()
    if (-not $rdr.Read()) { $rdr.Close(); throw 'The procedure returned no row.' }

    $pathIsNull = $rdr.IsDBNull(0)
    $ctxIsNull  = $rdr.IsDBNull(1)
    $fsPath = if ($pathIsNull) { $null } else { $rdr.GetString(0) }
    $fsCtx  = if ($ctxIsNull)  { $null } else { [byte[]]$rdr.GetValue(1) }
    $rdr.Close()

    Detail ("PathName()                        : {0}" -f $(if ($pathIsNull) { 'NULL' } else { $fsPath })) $(if ($pathIsNull) { 'Red' } else { 'Green' })
    Detail ("GET_FILESTREAM_TRANSACTION_CONTEXT: {0}" -f $(if ($ctxIsNull) { 'NULL' } else { "$($fsCtx.Length) bytes" })) $(if ($ctxIsNull) { 'Red' } else { 'Green' })

    if ($pathIsNull) {
        Write-Host '  PathName() is NULL: the FILESTREAM column was inserted as NULL rather than 0x.' -ForegroundColor Red
        Write-Host '  A NULL FILESTREAM value has no file on disk and cannot be streamed to.' -ForegroundColor Red
        return
    }
    if ($ctxIsNull) {
        Write-Host '  The transaction context is NULL. SqlFileStream cannot open without it.' -ForegroundColor Red
        Write-Host '  This means the connection has no FILESTREAM-enabled transaction open --' -ForegroundColor Red
        Write-Host '  usually the command was not enlisted in the SqlTransaction.' -ForegroundColor Red
        return
    }

    $unc = Split-Path -Parent $fsPath
    if ($null -ne $r) {
        Detail ("Server share root  : \\{0}\{1}" -f $r.MachineName, $r.ShareName)
    }
    Detail ("Path parent visible: {0}" -f (Test-Path -LiteralPath $unc)) 'DarkGray'

    # -----------------------------------------------------------------------
    Step "Open SqlFileStream for write and stream $SizeKB KB"
    $bytes = New-Object byte[] ($SizeKB * 1KB)
    (New-Object Random).NextBytes($bytes)

    $sfs = New-Object System.Data.SqlTypes.SqlFileStream(
                $fsPath, $fsCtx,
                [System.IO.FileAccess]::Write,
                [System.Data.SqlTypes.SqlFileStreamOptions]::SequentialScan,
                [long]0)
    try {
        Detail ("Handle opened. Name: {0}" -f $sfs.Name) 'Green'
        $sfs.Write($bytes, 0, $bytes.Length)
        $sfs.Flush()
        Detail ("Wrote {0} bytes" -f $bytes.Length) 'Green'
    }
    finally { $sfs.Close(); $sfs.Dispose() }

    # -----------------------------------------------------------------------
    Step 'Commit'
    $tx.Commit(); $tx.Dispose(); $tx = $null
    Detail 'Committed' 'Green'

    # -----------------------------------------------------------------------
    Step 'Verify the row and read it back'
    $v = Invoke-FsPocSql -Instance $cfg.SqlInstance -Database $cfg.DemoDb `
            -Query 'SELECT FileId, SizeBytes, StoredBytes = DATALENGTH(FileData) FROM dbo.FileStore WHERE RowGuid = @g' `
            -Parameters @{ g = $rowGuid }
    if ($v.Rows.Count -eq 0) { Write-Host '  Row not found after commit.' -ForegroundColor Red; return }
    $row = $v.Rows[0]
    Detail ("FileId {0}: declared {1} bytes, stored {2} bytes" -f $row.FileId, $row.SizeBytes, $row.StoredBytes) `
        $(if ([long]$row.StoredBytes -eq $bytes.Length) { 'Green' } else { 'Red' })

    if (-not $KeepRow) {
        $null = Invoke-FsPocSql -Instance $cfg.SqlInstance -Database $cfg.DemoDb -NonQuery `
                -Query 'DELETE FROM dbo.FileStore WHERE RowGuid = @g' -Parameters @{ g = $rowGuid }
        Detail 'Diagnostic row deleted (its container file is now tombstoned until GC runs).' 'DarkGray'
    }

    Write-Host ''
    Write-Host '  RESULT: the SqlFileStream write path works end to end.' -ForegroundColor Green
    Write-Host ''
}
catch {
    Explain $_.Exception
    Write-Host ''
    Write-Host '  Most likely causes, in order:' -ForegroundColor Yellow
    Write-Host '    1. FILESTREAM effective level < 2 (the Win32 open is refused).' -ForegroundColor Gray
    Write-Host '    2. The SQL Server service account lacks Full Control on the container.' -ForegroundColor Gray
    Write-Host '    3. The calling Windows account cannot reach the FILESTREAM share.' -ForegroundColor Gray
    Write-Host '    4. Antivirus is holding or blocking files in the container.' -ForegroundColor Gray
    Write-Host '    5. The client is not on the SQL Server machine and the Windows' -ForegroundColor Gray
    Write-Host '       access level is 2 rather than 3 (remote streaming disabled).' -ForegroundColor Gray
    throw
}
finally {
    if ($tx) { try { $tx.Rollback() } catch { } ; try { $tx.Dispose() } catch { } }
    $conn.Dispose()
}
