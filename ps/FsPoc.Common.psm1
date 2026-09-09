<#
    FsPoc.Common.psm1
    Shared helpers for the FILESTREAM POC kit.

    Windows PowerShell 5.1 ONLY. This is not a style preference:
    System.Data.SqlTypes.SqlFileStream -- the managed wrapper over the Win32
    FILESTREAM streaming API -- exists in .NET Framework and was never ported
    to .NET Core / .NET 5+. Microsoft.Data.SqlClient does not include it. If you
    run the ingest engine under PowerShell 7 you will get a type-not-found
    error, and the only workaround is the T-SQL path, which is the thing you are
    trying to measure against.
#>

Set-StrictMode -Version Latest

Add-Type -AssemblyName System.Data -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
function Get-FsPocConfig {
    [CmdletBinding()]
    param(
        [string] $Path = (Join-Path $PSScriptRoot 'FsPocConfig.psd1'),
        [hashtable] $Override = @{}
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config not found: $Path"
    }
    $cfg = Import-PowerShellDataFile -LiteralPath $Path
    foreach ($k in $Override.Keys) {
        if ($null -ne $Override[$k] -and $Override[$k] -ne '') { $cfg[$k] = $Override[$k] }
    }
    [pscustomobject]$cfg
}

function Get-FsPocConnectionString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Instance,
        [Parameter(Mandatory)] [string] $Database,
        [int] $ConnectTimeout = 15,
        [int] $CommandTimeout = 0
    )
    # Integrated Security is not optional for the SqlFileStream path: the Win32
    # handle is opened by the CLIENT against the FILESTREAM share, and that
    # open is authenticated with the caller's Windows token. SQL auth gets you
    # a valid PathName() and then an access-denied on CreateFile.
    "Data Source=$Instance;Initial Catalog=$Database;Integrated Security=SSPI;" +
    "Connect Timeout=$ConnectTimeout;Application Name=FsPoc;Pooling=true;Max Pool Size=200"
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Write-FsPocLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'STEP', 'OK')] [string] $Level = 'INFO'
    )
    $ts = (Get-Date).ToString('HH:mm:ss')
    $color = switch ($Level) {
        'STEP'  { 'Cyan' }
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        default { 'Gray' }
    }
    Write-Host ("[{0}] {1,-5} {2}" -f $ts, $Level, $Message) -ForegroundColor $color
}

function Test-FsPocElevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Format-FsPocBytes {
    param([Parameter(Mandatory)][double] $Bytes)
    $u = 'B', 'KB', 'MB', 'GB', 'TB', 'PB'; $i = 0
    while ($Bytes -ge 1024 -and $i -lt $u.Count - 1) { $Bytes /= 1024; $i++ }
    '{0:N2} {1}' -f $Bytes, $u[$i]
}

# ---------------------------------------------------------------------------
# SQL helpers (System.Data.SqlClient, no SqlServer module dependency)
# ---------------------------------------------------------------------------
function Invoke-FsPocSql {
    [CmdletBinding(DefaultParameterSetName = 'Query')]
    param(
        [Parameter(Mandatory)] [string] $Instance,
        [string] $Database = 'master',
        [Parameter(Mandatory, ParameterSetName = 'Query')] [string] $Query,
        [Parameter(Mandatory, ParameterSetName = 'File')]  [string] $InputFile,
        [hashtable] $Parameters = @{},
        [hashtable] $SqlcmdVariables = @{},
        [int] $CommandTimeout = 0,
        [switch] $NonQuery
    )

    if ($PSCmdlet.ParameterSetName -eq 'File') {
        # sqlcmd.exe handles :setvar / GO batching, which System.Data cannot.
        if (-not (Test-Path -LiteralPath $InputFile)) { throw "SQL file not found: $InputFile" }
        $args = @('-S', $Instance, '-E', '-b', '-I', '-i', $InputFile)
        foreach ($k in $SqlcmdVariables.Keys) { $args += @('-v', "$k=$($SqlcmdVariables[$k])") }
        Write-FsPocLog "sqlcmd -i $(Split-Path -Leaf $InputFile)" 'INFO'
        & sqlcmd.exe @args
        if ($LASTEXITCODE -ne 0) { throw "sqlcmd failed (exit $LASTEXITCODE) on $InputFile" }
        return
    }

    $cs = Get-FsPocConnectionString -Instance $Instance -Database $Database
    $conn = New-Object System.Data.SqlClient.SqlConnection $cs
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Query
        $cmd.CommandTimeout = $CommandTimeout
        foreach ($k in $Parameters.Keys) {
            $v = $Parameters[$k]
            $null = $cmd.Parameters.AddWithValue("@$k", $(if ($null -eq $v) { [DBNull]::Value } else { $v }))
        }
        if ($NonQuery) { return $cmd.ExecuteNonQuery() }

        $da = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
        $dt = New-Object System.Data.DataTable
        $null = $da.Fill($dt)
        , $dt
    }
    finally { $conn.Dispose() }
}

# ---------------------------------------------------------------------------
# Workload shaping
# ---------------------------------------------------------------------------
<#
    Size buckets. The ranges are chosen around the decision boundary that
    actually matters: Microsoft's long-standing guidance is that FILESTREAM
    tends to win above ~1 MB and lose below ~256 KB, with the middle being
    entirely dependent on your storage. A POC that only ingests one size proves
    nothing transferable, so the Mixed profile straddles the boundary and the
    analysis reports each bucket separately.

    ByteShare = fraction of TOTAL BYTES, not of file count. Small buckets
    therefore produce very large file counts, which is deliberate: NTFS
    directory pressure and per-file transaction overhead are the two costs that
    a naive "write 200 GB in 200 files" test completely misses.
#>
function Get-FsPocSizeProfile {
    [CmdletBinding()]
    param(
        [ValidateSet('Tiny', 'Small', 'Medium', 'Large', 'Huge', 'Mixed')]
        [string] $Profile = 'Mixed'
    )

    $all = @(
        [pscustomobject]@{ Bucket = 'Tiny';   MinBytes = 4KB;    MaxBytes = 64KB;   ByteShare = 0.02 }
        [pscustomobject]@{ Bucket = 'Small';  MinBytes = 64KB;   MaxBytes = 1MB;    ByteShare = 0.08 }
        [pscustomobject]@{ Bucket = 'Medium'; MinBytes = 1MB;    MaxBytes = 16MB;   ByteShare = 0.30 }
        [pscustomobject]@{ Bucket = 'Large';  MinBytes = 16MB;   MaxBytes = 256MB;  ByteShare = 0.45 }
        # Capped just under the 2 GB varbinary(max) ceiling so the SAME profile
        # can run down both paths. That ceiling is itself a POC finding worth
        # recording: FILESTREAM has no 2 GB per-value limit, in-table LOB does.
        [pscustomobject]@{ Bucket = 'Huge';   MinBytes = 256MB;  MaxBytes = 2000MB; ByteShare = 0.15 }
    )

    if ($Profile -eq 'Mixed') { return $all }

    $one = $all | Where-Object Bucket -eq $Profile
    $one.ByteShare = 1.0
    , $one
}

function Get-FsPocWorkPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [double] $TargetGB,
        [string] $Profile = 'Mixed',
        [int] $Threads = 8
    )

    $targetBytes = [long]($TargetGB * 1GB)
    $plan = foreach ($b in Get-FsPocSizeProfile -Profile $Profile) {
        $bucketBytes = [long]($targetBytes * $b.ByteShare)
        $avg = ($b.MinBytes + $b.MaxBytes) / 2
        [pscustomobject]@{
            Bucket           = $b.Bucket
            MinBytes         = [long]$b.MinBytes
            MaxBytes         = [long]$b.MaxBytes
            TargetBytes      = $bucketBytes
            EstimatedFiles   = [long][Math]::Ceiling($bucketBytes / $avg)
            BytesPerWorker   = [long]([Math]::Ceiling($bucketBytes / $Threads))
        }
    }
    , @($plan)
}

function Write-FsPocWorkPlan {
    param([Parameter(Mandatory)] $Plan)
    Write-Host ''
    Write-Host ('  {0,-8} {1,10} {2,10} {3,12} {4,14}' -f 'Bucket', 'Min', 'Max', 'Target', 'Est. files') -ForegroundColor White
    Write-Host ('  ' + ('-' * 58)) -ForegroundColor DarkGray
    foreach ($p in $Plan) {
        Write-Host ('  {0,-8} {1,10} {2,10} {3,12} {4,14:N0}' -f `
            $p.Bucket,
            (Format-FsPocBytes $p.MinBytes),
            (Format-FsPocBytes $p.MaxBytes),
            (Format-FsPocBytes $p.TargetBytes),
            $p.EstimatedFiles)
    }
    $totalFiles = ($Plan | Measure-Object EstimatedFiles -Sum).Sum
    $totalBytes = ($Plan | Measure-Object TargetBytes -Sum).Sum
    Write-Host ('  ' + ('-' * 58)) -ForegroundColor DarkGray
    Write-Host ('  {0,-8} {1,10} {2,10} {3,12} {4,14:N0}' -f `
        'TOTAL', '', '', (Format-FsPocBytes $totalBytes), $totalFiles) -ForegroundColor White
    Write-Host ''
    if ($totalFiles -gt 500000) {
        Write-FsPocLog "Plan creates $('{0:N0}' -f $totalFiles) files. NTFS handles this, but make sure 8.3 name generation is DISABLED on the container volume or directory enumeration will degrade badly." 'WARN'
    }
}

<#
    Incompressible source data without paying for 200 GB of CSPRNG.

    Filling 200 GB from RNGCryptoServiceProvider is CPU-bound and would become
    the bottleneck you are measuring. Instead we generate one pool of genuinely
    random bytes once, then write random-offset slices of it. The result is
    incompressible at any window smaller than the pool, which is what matters:
    it defeats NTFS compression, Azure host-level dedup, and any storage-side
    compression that would otherwise inflate your apparent throughput.
#>
function New-FsPocRandomPool {
    [CmdletBinding()]
    param([int] $SizeMB = 256)

    Write-FsPocLog "Generating $SizeMB MB incompressible source pool..." 'INFO'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $pool = New-Object byte[] ($SizeMB * 1MB)
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        # Fill in slices; some RNG providers dislike very large single buffers.
        $slice = 16MB
        for ($off = 0; $off -lt $pool.Length; $off += $slice) {
            $len = [Math]::Min($slice, $pool.Length - $off)
            $buf = New-Object byte[] $len
            $rng.GetBytes($buf)
            [Array]::Copy($buf, 0, $pool, $off, $len)
        }
    }
    finally { $rng.Dispose() }
    $sw.Stop()
    Write-FsPocLog ("Source pool ready in {0:N1}s" -f $sw.Elapsed.TotalSeconds) 'OK'
    , $pool
}

Export-ModuleMember -Function *-FsPoc*, Invoke-FsPocSql, Test-FsPocElevated, Format-FsPocBytes
