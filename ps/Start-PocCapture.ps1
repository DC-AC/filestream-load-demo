<#
.SYNOPSIS
    Starts the monitoring stack for a POC run: Extended Events, a Perfmon
    counter set, and (optionally) a windowed Process Monitor trace.

.DESCRIPTION
    Writes a capture-state JSON into the results directory so Stop-PocCapture.ps1
    can tear everything down even from a different shell.

    On Procmon and why it is WINDOWED:

    Process Monitor is a kernel filter driver that records every file, registry
    and process operation on the machine. During a FILESTREAM ingest at a few
    hundred MB/s that is on the order of tens of thousands of events per second,
    and the backing file grows by gigabytes per minute. Left running for a full
    200 GB run it will (a) fill the disk, and (b) add enough overhead that the
    throughput number you collect is no longer the number you were trying to
    measure.

    So: run the full ingest clean to get throughput, and run Procmon for a short
    representative window to get the per-operation shape -- what NTFS calls
    sqlservr.exe actually makes per FILESTREAM file, in what order, at what
    size, and where the time goes. Those are two different questions and they
    want two different traces.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [guid]   $RunId,
    [Parameter(Mandatory)] [string] $ResultsDir,
    [string] $ConfigPath,

    [switch] $NoXEvents,
    [switch] $NoPerfmon,
    [switch] $Procmon,
    [int]    $ProcmonDelaySec = 30,
    [int]    $ProcmonWindowSec,
    [string] $ProcmonConfig       # optional .pmc saved from the Procmon UI
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
if (-not $ProcmonWindowSec) { $ProcmonWindowSec = $cfg.ProcmonWindowSec }
$null = New-Item -ItemType Directory -Path $ResultsDir -Force

$state = [ordered]@{
    RunId        = $RunId.ToString()
    ResultsDir   = $ResultsDir
    ConfigPath   = $ConfigPath
    StartedAt    = (Get-Date).ToString('o')
    XEventSession = $null
    PerfmonName   = $null
    PerfmonFile   = $null
    ProcmonPml    = $null
    ProcmonJob    = $null
    ProcmonWindowSec = $ProcmonWindowSec
}

# ---------------------------------------------------------------------------
# Extended Events
# ---------------------------------------------------------------------------
if (-not $NoXEvents) {
    $session = 'FsPoc_Waits'
    Write-FsPocLog "Starting Extended Events session $session" 'STEP'
    Invoke-FsPocSql -Instance $cfg.SqlInstance -Database 'master' -NonQuery -Query @"
IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'$session')
    ALTER EVENT SESSION [$session] ON SERVER STATE = STOP;
ALTER EVENT SESSION [$session] ON SERVER STATE = START;
"@ | Out-Null
    $state.XEventSession = $session
    Write-FsPocLog "XE target: $($cfg.XePath)\$session*.xel" 'OK'
}

# ---------------------------------------------------------------------------
# Perfmon
# ---------------------------------------------------------------------------
if (-not $NoPerfmon) {
    $name = "FsPoc_$($RunId.ToString('N').Substring(0,8))"
    $out  = Join-Path $ResultsDir 'perfmon.csv'

    # Counter object prefix differs for named instances.
    $sqlObj = if ($cfg.SqlInstance -match '\\') { "MSSQL`$$($cfg.SqlInstance.Split('\')[-1])" } else { 'SQLServer' }

    $counters = @(
        # Storage. Avg. Disk sec/Write is the number that decides whether your
        # FILESTREAM result is about FILESTREAM or about the Azure disk SKU.
        '\LogicalDisk(*)\Disk Bytes/sec'
        '\LogicalDisk(*)\Disk Read Bytes/sec'
        '\LogicalDisk(*)\Disk Write Bytes/sec'
        '\LogicalDisk(*)\Disk Reads/sec'
        '\LogicalDisk(*)\Disk Writes/sec'
        '\LogicalDisk(*)\Avg. Disk sec/Read'
        '\LogicalDisk(*)\Avg. Disk sec/Write'
        '\LogicalDisk(*)\Avg. Disk Bytes/Write'
        '\LogicalDisk(*)\Current Disk Queue Length'
        '\LogicalDisk(*)\% Idle Time'
        '\LogicalDisk(*)\Split IO/Sec'
        # CPU
        '\Processor Information(_Total)\% Processor Time'
        '\Processor Information(_Total)\% Privileged Time'
        '\System\Processor Queue Length'
        '\System\Context Switches/sec'
        '\System\File Data Operations/sec'
        # Windows system file cache -- FILESTREAM I/O flows through this, NOT
        # through the SQL Server buffer pool. Watching it is how you catch
        # "max server memory is starving the file cache".
        '\Memory\Available MBytes'
        '\Memory\Cache Bytes'
        '\Memory\System Cache Resident Bytes'
        '\Memory\Standby Cache Normal Priority Bytes'
        '\Memory\Pages/sec'
        # Processes
        '\Process(sqlservr)\% Processor Time'
        '\Process(sqlservr)\IO Data Bytes/sec'
        '\Process(sqlservr)\IO Write Bytes/sec'
        '\Process(sqlservr)\IO Read Bytes/sec'
        '\Process(sqlservr)\Working Set'
        '\Process(sqlservr)\Private Bytes'
        '\Process(sqlservr)\Handle Count'
        '\Process(powershell)\% Processor Time'
        '\Process(powershell)\IO Data Bytes/sec'
        # SQL Server
        "\$sqlObj`:Databases($($cfg.DemoDb))\Log Bytes Flushed/sec"
        "\$sqlObj`:Databases($($cfg.DemoDb))\Log Flushes/sec"
        "\$sqlObj`:Databases($($cfg.DemoDb))\Log Flush Wait Time"
        "\$sqlObj`:Databases($($cfg.DemoDb))\Log Flush Waits/sec"
        "\$sqlObj`:Databases($($cfg.DemoDb))\Transactions/sec"
        "\$sqlObj`:Databases($($cfg.DemoDb))\Percent Log Used"
        "\$sqlObj`:Buffer Manager\Page life expectancy"
        "\$sqlObj`:Buffer Manager\Checkpoint pages/sec"
        "\$sqlObj`:Buffer Manager\Lazy writes/sec"
        "\$sqlObj`:General Statistics\User Connections"
        "\$sqlObj`:Wait Statistics(Average wait time (ms))\Log write waits"
        "\$sqlObj`:Wait Statistics(Average wait time (ms))\Page IO latch waits"
        "\$sqlObj`:Transactions\Transactions"
        # Network -- relevant if you ever run the client off-box (access level 3)
        '\Network Interface(*)\Bytes Total/sec'
    )

    Write-FsPocLog "Creating Perfmon collector $name (interval $($cfg.PerfmonIntervalSec)s)" 'STEP'
    & logman.exe stop   $name 2>&1 | Out-Null
    & logman.exe delete $name 2>&1 | Out-Null

    $cfgFile = Join-Path $ResultsDir 'perfmon-counters.txt'
    Set-Content -LiteralPath $cfgFile -Value $counters -Encoding ASCII

    $si = '{0:00}:{1:00}:{2:00}' -f 0, 0, $cfg.PerfmonIntervalSec
    & logman.exe create counter $name -f csv -si $si -o $out -cf $cfgFile -ow 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-FsPocLog "logman create failed (exit $LASTEXITCODE). Some counters may not exist on this build; check $cfgFile." 'WARN'
    }
    else {
        & logman.exe start $name 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $state.PerfmonName = $name
            $state.PerfmonFile = $out
            Write-FsPocLog "Perfmon collecting to $out" 'OK'
        }
        else { Write-FsPocLog "logman start failed (exit $LASTEXITCODE)." 'WARN' }
    }
}

# ---------------------------------------------------------------------------
# Procmon (windowed, started after a delay so it samples steady state)
# ---------------------------------------------------------------------------
if ($Procmon) {
    if (-not (Test-Path -LiteralPath $cfg.ProcmonExe)) {
        Write-FsPocLog "Procmon not found at $($cfg.ProcmonExe). Skipping. Download from Sysinternals and unblock the exe." 'WARN'
    }
    else {
        $pml = Join-Path $ResultsDir 'procmon.pml'
        $state.ProcmonPml = $pml

        # A missing .pmc is worth catching here. Procmon runs inside a background
        # job with /Quiet /Minimized, so a bad /LoadConfig argument surfaces
        # nowhere -- the job exits and the trace is empty or unfiltered, which is
        # only discovered when Measure-ProcmonLog finds nothing to report.
        if ($ProcmonConfig -and -not (Test-Path -LiteralPath $ProcmonConfig)) {
            Write-FsPocLog "ProcmonConfig not found: $ProcmonConfig" 'WARN'
            Write-FsPocLog 'Capturing WITHOUT it -- no column/filter setup, so the CSV may lack the Duration column that Measure-ProcmonLog.ps1 needs. See procmon/README.md.' 'WARN'
            $ProcmonConfig = $null
        }

        # A background job so the ingest keeps running: wait out the ramp-up,
        # capture for the window, then terminate cleanly.
        $job = Start-Job -Name "FsPocProcmon_$($RunId.ToString('N').Substring(0,8))" -ScriptBlock {
            param($exe, $pml, $delay, $window, $pmc)
            Start-Sleep -Seconds $delay
            $args = @('/AcceptEula', '/Quiet', '/Minimized', '/BackingFile', $pml)
            if ($pmc) { $args += @('/LoadConfig', $pmc) }
            $args += @('/Runtime', $window)
            Start-Process -FilePath $exe -ArgumentList $args -Wait
            # Belt and braces: /Runtime should have stopped it already.
            Start-Process -FilePath $exe -ArgumentList @('/AcceptEula', '/Terminate') -Wait -ErrorAction SilentlyContinue
        } -ArgumentList $cfg.ProcmonExe, $pml, $ProcmonDelaySec, $ProcmonWindowSec, $ProcmonConfig

        $state.ProcmonJob = $job.Name
        Write-FsPocLog "Procmon scheduled: starts in ${ProcmonDelaySec}s, captures for ${ProcmonWindowSec}s -> $pml" 'OK'
        Write-FsPocLog 'Expect several GB of PML. Make sure ResultsPath is NOT on the FILESTREAM disk.' 'WARN'
    }
}

# ProcmonActive is NOT set here. This script runs before Invoke-FilestreamIngest
# calls usp_StartRun, so the PocRun row does not exist yet and an UPDATE against
# it matches zero rows -- which is exactly what used to happen, leaving every
# traced run recorded as untraced. The ingest engine takes -ProcmonActive and
# records it when it registers the run.

$statePath = Join-Path $ResultsDir 'capture-state.json'
$state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $statePath -Encoding UTF8
Write-FsPocLog "Capture state -> $statePath" 'OK'
[pscustomobject]$state
