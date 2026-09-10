<#
.SYNOPSIS
    Prepares the SQL Server VM for the FILESTREAM POC: Windows-level FILESTREAM,
    volume tuning checks, directories, and the database/monitoring objects.

.DESCRIPTION
    Run this ONCE per VM (elevated). It is idempotent -- re-running it re-checks
    everything and only changes what is wrong.

    -AccessLevel controls the Windows-level switch:
        1 = T-SQL access only
        2 = T-SQL + local Win32 streaming   <-- required by the ingest engine
        3 = 2 + remote Win32 streaming over SMB

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Setup-FilestreamPoc.ps1

.EXAMPLE
    .\Setup-FilestreamPoc.ps1 -AccessLevel 3 -RestartSqlService
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 3)] [int] $AccessLevel = 2,
    [string] $ShareName,
    [string] $ConfigPath,
    [switch] $RestartSqlService,
    [switch] $SkipDatabase,
    [switch] $SkipSmokeTest,
    [switch] $ApplyNtfsTuning,
    [switch] $IgnoreVolumeRoles
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

if (-not (Test-FsPocElevated)) { throw 'Run this elevated. FILESTREAM enablement and fsutil both require admin.' }

$cfg = Get-FsPocConfig -Path $ConfigPath
$instanceShort = if ($cfg.SqlInstance -match '\\') { $cfg.SqlInstance.Split('\')[-1] } else { 'MSSQLSERVER' }
if (-not $ShareName) { $ShareName = $instanceShort }

Write-Host ''
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host ' FILESTREAM POC -- VM SETUP' -ForegroundColor Cyan
Write-Host '================================================================' -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 1. Windows-level FILESTREAM
# ---------------------------------------------------------------------------
Write-FsPocLog 'Step 1: Windows-level FILESTREAM' 'STEP'

$ns = Get-CimInstance -Namespace 'root\Microsoft\SqlServer' -ClassName '__NAMESPACE' -ErrorAction SilentlyContinue |
      Where-Object Name -like 'ComputerManagement*' |
      Sort-Object { [int]($_.Name -replace '\D', '') } -Descending

if (-not $ns) { throw 'No root\Microsoft\SqlServer\ComputerManagement* WMI namespace found. Is SQL Server installed on this machine?' }

$fsSettings = $null; $usedNs = $null
foreach ($n in $ns) {
    $candidate = "root\Microsoft\SqlServer\$($n.Name)"
    $s = Get-CimInstance -Namespace $candidate -ClassName FilestreamSettings -ErrorAction SilentlyContinue |
         Where-Object InstanceName -eq $instanceShort
    if ($s) { $fsSettings = $s; $usedNs = $candidate; break }
}
if (-not $fsSettings) { throw "FilestreamSettings not found for instance '$instanceShort' in any ComputerManagement namespace." }

Write-FsPocLog "WMI namespace : $usedNs"
Write-FsPocLog "Current level : $($fsSettings.AccessLevel)   Share: '$($fsSettings.ShareName)'"

$needRestart = $false
if ($fsSettings.AccessLevel -lt $AccessLevel -or $fsSettings.ShareName -ne $ShareName) {
    Write-FsPocLog "Setting Windows FILESTREAM access level to $AccessLevel (share '$ShareName')..." 'STEP'
    $r = Invoke-CimMethod -InputObject $fsSettings -MethodName EnableFilestream `
            -Arguments @{ AccessLevel = [uint32]$AccessLevel; ShareName = $ShareName }
    if ($r.ReturnValue -ne 0) { throw "EnableFilestream failed with ReturnValue $($r.ReturnValue)" }
    Write-FsPocLog 'Windows FILESTREAM setting updated. A SQL Server service restart is required.' 'OK'
    $needRestart = $true
}
else { Write-FsPocLog 'Windows FILESTREAM already at or above the requested level.' 'OK' }

if ($needRestart) {
    if ($RestartSqlService) {
        $svcName = if ($instanceShort -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { "MSSQL`$$instanceShort" }
        Write-FsPocLog "Restarting service $svcName ..." 'STEP'
        Restart-Service -Name $svcName -Force
        (Get-Service $svcName).WaitForStatus('Running', '00:03:00')
        Write-FsPocLog 'SQL Server restarted.' 'OK'
    }
    else {
        Write-FsPocLog 'Re-run with -RestartSqlService, or restart SQL Server manually, then run this script again.' 'WARN'
        return
    }
}

# ---------------------------------------------------------------------------
# 2. Directories
# ---------------------------------------------------------------------------
Write-FsPocLog 'Step 2: directories' 'STEP'
foreach ($p in @($cfg.DataPath, $cfg.LogPath, $cfg.XePath, $cfg.ResultsPath, $cfg.FsPath)) {
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    if (-not (Test-Path -LiteralPath $p)) {
        $null = New-Item -ItemType Directory -Path $p -Force
        Write-FsPocLog "Created $p" 'OK'
    }
    else { Write-FsPocLog "Exists  $p" }
}
Write-FsPocLog "NOTE: '$($cfg.FsPath)' is the PARENT. SQL Server creates '$($cfg.FsPath)\$($cfg.DemoDb)_FS1' itself -- that leaf must NOT exist." 'WARN'

# ---------------------------------------------------------------------------
# 3. Volume checks -- the settings that actually move FILESTREAM numbers
# ---------------------------------------------------------------------------
Write-FsPocLog 'Step 3: volume and NTFS checks' 'STEP'

$volumesOfInterest = @($cfg.DataPath, $cfg.LogPath, $cfg.FsPath, $cfg.FsPath2) |
    Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
    ForEach-Object { (Split-Path -Qualifier $_) } | Select-Object -Unique

$volInfo = Get-CimInstance Win32_Volume -ErrorAction SilentlyContinue |
           Where-Object { $_.DriveLetter -and $volumesOfInterest -contains $_.DriveLetter }

Write-Host ''
Write-Host ('  {0,-6} {1,-14} {2,12} {3,12} {4,10}' -f 'Drive', 'Label', 'AllocUnit', 'FreeGB', 'FS') -ForegroundColor White
foreach ($v in $volInfo) {
    Write-Host ('  {0,-6} {1,-14} {2,12:N0} {3,12:N1} {4,10}' -f `
        $v.DriveLetter, $v.Label, $v.BlockSize, ($v.FreeSpace / 1GB), $v.FileSystem)
}
Write-Host ''

<#  Cross-check the configured volume roles against SQL SERVER'S OWN defaults.

    This exists because the defaults once put the FILESTREAM container on the
    volume holding the instance's default log directory, and the transaction
    log on the volume intended for FILESTREAM. Setup created the directories,
    both databases built cleanly, nothing complained -- and every number the
    POC produced would have described the wrong device.

    The instance's configured default data and log paths are the authoritative
    statement of which volume is for what. Volume labels are free text that may
    be stale, blank, or simply wrong, so they are printed for context but are
    not used to make this decision.
#>
$mismatch = $false
$defaults = $null
try {
    $defaults = Invoke-FsPocSql -Instance $cfg.SqlInstance -Database 'master' -Query @'
SELECT
    DefaultData = CONVERT(nvarchar(260), SERVERPROPERTY('InstanceDefaultDataPath')),
    DefaultLog  = CONVERT(nvarchar(260), SERVERPROPERTY('InstanceDefaultLogPath'))
'@
}
catch {
    Write-FsPocLog "Could not read the instance's default paths: $($_.Exception.Message)" 'WARN'
    Write-FsPocLog 'Skipping the volume role check -- verify DataPath, LogPath and FsPath by hand.' 'WARN'
}

if ($defaults -and $defaults.Rows.Count -gt 0) {
    $defData = [string]$defaults.Rows[0].DefaultData
    $defLog  = [string]$defaults.Rows[0].DefaultLog

    if ([string]::IsNullOrWhiteSpace($defData) -or [string]::IsNullOrWhiteSpace($defLog)) {
        Write-FsPocLog 'The instance reports no default data/log path; skipping the volume role check.' 'WARN'
    }
    else {
        $defDataDrive = Split-Path -Qualifier $defData
        $defLogDrive  = Split-Path -Qualifier $defLog
        $fsDrive2     = Split-Path -Qualifier $cfg.FsPath
        $logDrive2    = Split-Path -Qualifier $cfg.LogPath
        $dataDrive2   = Split-Path -Qualifier $cfg.DataPath

        Write-Host ''
        Write-FsPocLog "Instance default data path : $defData"
        Write-FsPocLog "Instance default log path  : $defLog"
        Write-Host ''

        # The failure that actually happened: container on the log volume.
        if ($fsDrive2 -eq $defLogDrive) {
            $mismatch = $true
            Write-FsPocLog "FsPath is on $fsDrive2, which is the instance's default LOG volume ($defLog)." 'ERROR'
        }
        elseif ($fsDrive2 -eq $defDataDrive) {
            Write-FsPocLog "FsPath is on $fsDrive2, the instance's default DATA volume. The container will contend with the MDF." 'WARN'
        }

        if ($logDrive2 -ne $defLogDrive) {
            Write-FsPocLog "LogPath is on $logDrive2 but the instance's default log volume is $defLogDrive." 'WARN'
        }
        if ($dataDrive2 -ne $defDataDrive) {
            Write-FsPocLog "DataPath is on $dataDrive2 but the instance's default data volume is $defDataDrive." 'WARN'
        }
        if ((Split-Path -Qualifier $cfg.XePath) -eq $fsDrive2) {
            Write-FsPocLog "XePath is on the FILESTREAM volume. Trace writes will compete with the workload being traced." 'WARN'
        }
    }
}

# Two heavy roles sharing one spindle is the other way to measure the wrong thing.
$fsDriveLetter  = Split-Path -Qualifier $cfg.FsPath
$logDriveLetter = Split-Path -Qualifier $cfg.LogPath
if ($fsDriveLetter -eq $logDriveLetter) {
    $mismatch = $true
    Write-FsPocLog "The FILESTREAM container and the transaction log are both on $fsDriveLetter. They will compete for the same IOPS budget and the result will describe the disk, not FILESTREAM." 'ERROR'
}

if ($mismatch) {
    Write-Host ''
    Write-Host '  Volume assignment looks wrong. Fix the paths in ps\FsPocConfig.psd1' -ForegroundColor Red
    Write-Host '  and re-run, or pass -IgnoreVolumeRoles if this layout is deliberate.' -ForegroundColor Red
    Write-Host ''
    if (-not $IgnoreVolumeRoles) {
        throw 'Aborting: configured volume roles disagree with the instance default paths. Nothing has been created.'
    }
    Write-FsPocLog 'Continuing anyway (-IgnoreVolumeRoles).' 'WARN'
}
else { Write-FsPocLog 'Volume roles are consistent with the instance default paths.' 'OK' }

foreach ($v in $volInfo) {
    if ($v.FileSystem -ne 'NTFS') {
        Write-FsPocLog "$($v.DriveLetter) is $($v.FileSystem). FILESTREAM containers require NTFS (ReFS is not supported)." 'ERROR'
    }
    if ($v.DriveLetter -eq (Split-Path -Qualifier $cfg.FsPath)) {
        $needGB = [double]$cfg.TargetGB * 1.15
        if (($v.FreeSpace / 1GB) -lt $needGB) {
            Write-FsPocLog ("$($v.DriveLetter) has {0:N0} GB free; the {1} GB target needs ~{2:N0} GB with headroom for FILESTREAM garbage collection lag." -f ($v.FreeSpace / 1GB), $cfg.TargetGB, $needGB) 'ERROR'
        }
    }
}

# 8.3 name generation is the big one. Every file created in a directory that
# still generates short names costs an extra NTFS index insert, and the cost
# grows super-linearly as the directory fills -- which is exactly what a
# FILESTREAM container does over a few hundred thousand files.
$fsDrive = Split-Path -Qualifier $cfg.FsPath
$short = (& fsutil.exe 8dot3name query $fsDrive) 2>&1 | Out-String
if ($short -match 'disabled') { Write-FsPocLog "8.3 name generation is DISABLED on $fsDrive." 'OK' }
else {
    Write-FsPocLog "8.3 name generation appears ENABLED on $fsDrive. This measurably slows large FILESTREAM containers." 'WARN'
    if ($ApplyNtfsTuning) {
        & fsutil.exe 8dot3name set $fsDrive 1 | Out-Null
        Write-FsPocLog "Disabled 8.3 name generation on $fsDrive (affects newly created files only)." 'OK'
    }
    else { Write-FsPocLog "Re-run with -ApplyNtfsTuning, or: fsutil 8dot3name set $fsDrive 1" 'INFO' }
}

$lastAccess = (& fsutil.exe behavior query disablelastaccess) 2>&1 | Out-String
Write-FsPocLog ("fsutil disablelastaccess -> " + $lastAccess.Trim())
if ($lastAccess -notmatch '=\s*[13]') {
    Write-FsPocLog 'Last-access timestamps are being updated. That is an extra metadata write per file touched.' 'WARN'
    if ($ApplyNtfsTuning) {
        & fsutil.exe behavior set disablelastaccess 1 | Out-Null
        Write-FsPocLog 'Disabled last-access updates (reboot to take full effect).' 'OK'
    }
}

Write-Host ''
Write-FsPocLog 'Manual checks this script cannot make for you:' 'WARN'
Write-Host @"
    * Antivirus / Defender: exclude the FILESTREAM container path AND the
      sqlservr.exe process. A real-time scanner sees every FILESTREAM file as a
      brand-new file on disk, because it is one. This is the single most common
      cause of a bad FILESTREAM POC result.
        Add-MpPreference -ExclusionPath '$($cfg.FsPath)'

    * Azure host caching on the data disk holding the container: set it to
      None for a write-heavy POC. ReadOnly caching helps re-read workloads but
      inflates write numbers in a way that will not survive production.

    * Disk striping: a single Azure premium disk caps at a fixed IOPS and
      MB/s. If you are trying to measure FILESTREAM and not the disk SKU, use
      a Storage Spaces stripe or a second container (FsPath2) on another disk.

    * Instant File Initialization: grant "Perform volume maintenance tasks" to
      the SQL Server service account. It does not affect FILESTREAM containers,
      but it stops MDF growth from contaminating the run.

    * The SQL Server service account needs Full Control on '$($cfg.FsPath)'.
"@ -ForegroundColor DarkYellow

# ---------------------------------------------------------------------------
# 4. Database objects
# ---------------------------------------------------------------------------
if ($SkipDatabase) { Write-FsPocLog 'Skipping database creation (-SkipDatabase).' 'INFO'; return }

Write-FsPocLog 'Step 4: instance configuration and databases' 'STEP'
$sqlDir = Join-Path (Split-Path -Parent $ScriptDir) 'sql'
$vars = @{
    DbName          = $cfg.DemoDb
    MonitorDb       = $cfg.MonitorDb
    DataPath        = $cfg.DataPath
    LogPath         = $cfg.LogPath
    FsPath          = $cfg.FsPath
    FsPath2         = $cfg.FsPath2
    MonitorDataPath = $cfg.DataPath
    MonitorLogPath  = $cfg.LogPath
    XePath          = $cfg.XePath
    TargetGB        = $cfg.TargetGB
    DirectoryName   = $cfg.DemoDb
    SessionName     = 'FsPoc_Waits'
    MinWaitMs       = 10
}

foreach ($script in '01-instance-config.sql', '02-create-database.sql', '03-monitor-db.sql', '04-xevents.sql') {
    Invoke-FsPocSql -Instance $cfg.SqlInstance -InputFile (Join-Path $sqlDir $script) -SqlcmdVariables $vars
}

# ---------------------------------------------------------------------------
# 5. End-to-end smoke test of the actual streaming path
# ---------------------------------------------------------------------------
if ($SkipSmokeTest) {
    Write-FsPocLog 'Step 5: smoke test SKIPPED (-SkipSmokeTest).' 'WARN'
    Write-FsPocLog 'The streaming path is unverified. Run Test-FilestreamPath.ps1 when ready.' 'WARN'
    return
}

Write-FsPocLog 'Step 5: SqlFileStream smoke test' 'STEP'
try {
    $r = & (Join-Path $ScriptDir 'Invoke-FilestreamIngest.ps1') `
            -Scenario Filestream -TargetGB 0.05 -Threads 2 -SizeProfile Medium `
            -ConfigPath $ConfigPath -NoMonitorDb
    if ($r.Errors -gt 0 -or $r.Files -eq 0) {
        Write-FsPocLog "Smoke test FAILED: $($r.Files) file(s) written, $($r.Errors) error(s)." 'ERROR'
        Write-Host ''
        Write-Host '  Setup is NOT complete. The streaming path does not work yet.' -ForegroundColor Red
        Write-Host '  Run the single-file diagnostic for a step-by-step trace:' -ForegroundColor Yellow
        Write-Host "      powershell.exe -ExecutionPolicy Bypass -File $ScriptDir\Test-FilestreamPath.ps1" -ForegroundColor Yellow
        throw "SqlFileStream smoke test failed ($($r.Errors) errors, $($r.Files) files written)."
    }
    Write-FsPocLog ("Smoke test OK: {0} in {1:N0} files at {2:N1} MB/s" -f (Format-FsPocBytes $r.Bytes), $r.Files, $r.ThroughputMBs) 'OK'
}
catch {
    Write-FsPocLog "Smoke test FAILED: $($_.Exception.Message)" 'ERROR'
    Write-Host @"
    Common causes, in order of likelihood:
      1. FILESTREAM effective level < 2  -> the Win32 open is refused.
      2. Running under PowerShell 7      -> SqlFileStream does not exist there.
      3. SQL authentication in use       -> the Win32 open needs a Windows token.
      4. Running from a remote machine   -> needs Windows access level 3, and
                                            the client must reach the SMB share.
"@ -ForegroundColor Red
    throw
}

Write-Host ''
Write-FsPocLog 'Setup complete. Next: .\Invoke-PocRun.ps1' 'OK'
