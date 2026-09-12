<#
.SYNOPSIS
    Generates and ingests a large synthetic workload into a FILESTREAM database,
    with per-file client-side timings.

.DESCRIPTION
    Four scenarios, all driving the same size profile and chunk size so the
    numbers are comparable:

      Filestream     Win32 streaming writes via System.Data.SqlTypes.SqlFileStream
      Blob           Chunked varbinary(max) .WRITE appends through T-SQL
      FilestreamRead Win32 streaming reads back out of the container
      BlobRead       Chunked varbinary(max) reads via SqlDataReader

    Files are synthesised in memory from a pre-generated incompressible pool, so
    a 200 GB run needs 200 GB of destination capacity, not 400 GB. Nothing is
    staged to a source directory. Use -SourcePath to ingest real files instead.

.NOTES
    MUST run under Windows PowerShell 5.1 on the SQL Server VM itself.
    See the module header in FsPoc.Common.psm1 for why.

.EXAMPLE
    .\Invoke-FilestreamIngest.ps1 -Scenario Filestream -TargetGB 200 -Threads 8

.EXAMPLE
    .\Invoke-FilestreamIngest.ps1 -Scenario Blob -TargetGB 20 -SizeProfile Small
#>
[CmdletBinding()]
param(
    [ValidateSet('Filestream', 'Blob', 'FileTable', 'AzureBlob',
                 'FilestreamRead', 'BlobRead', 'FileTableRead', 'AzureBlobRead')]
    [string] $Scenario = 'Filestream',

    [double] $TargetGB,
    [int]    $Threads,
    [int]    $ChunkSizeKB,
    [ValidateSet('Tiny', 'Small', 'Medium', 'Large', 'Huge', 'Mixed')]
    [string] $SizeProfile,

    [guid]   $RunId = [guid]::NewGuid(),
    [string] $RunName,
    <#  A name for the configuration under test, e.g. 'Premium v1 4k'.

        Section 8 of the analysis compares runs, and it can only be read if
        each row says what was being varied. Scenario and profile are already
        recorded; the disk SKU, allocation unit, caching mode and VM size are
        not, and nothing on the machine records them either.
    #>
    [string] $Label,
    [string] $ConfigPath,

    # Ingest real files from a directory tree instead of synthesising them.
    [string] $SourcePath,

    # Read scenarios: which ingest run to read back. Defaults to the newest.
    [guid]   $SourceRunId,

    # Preallocate the FILESTREAM file to its final size on open. Real tuning
    # knob: it trades an up-front NTFS allocation for fewer extend operations.
    [switch] $Preallocate,

    <#  FileTable writes are non-transacted Win32 I/O over the SMB share, so
        unlike a FILESTREAM commit nothing forces them to disk. Left off, this
        measures FileTable as applications actually use it; switched on, it
        forces each file to stable storage so the comparison against a
        FILESTREAM commit is like for like. The two answer different questions
        and the analysis reports which was used.
    #>
    [switch] $FileTableFlush,

    <#  Record that this run was traced with Process Monitor.

        Passed in rather than set by the capture scripts: Start-PocCapture runs
        BEFORE usp_StartRun creates the PocRun row, so its
        "UPDATE ... SET ProcmonActive = 1" matched zero rows and the flag was
        silently 0 on every run ever recorded -- including a 200 GB run that
        was genuinely traced. The flag exists so a traced run is not compared
        against a clean one as though the overhead were not there.
    #>
    [switch] $ProcmonActive,

    # Skip writing run metadata / snapshots to FsPocMonitor (raw throughput only).
    [switch] $NoMonitorDb,

    [switch] $WhatIfPlan
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

if ($PSVersionTable.PSVersion.Major -ge 6) {
    throw "This script requires Windows PowerShell 5.1. SqlFileStream does not exist in .NET Core/.NET 5+. Launch with: powershell.exe -File $PSCommandPath"
}

$cfg = Get-FsPocConfig -Path $ConfigPath -Override @{
    TargetGB    = $TargetGB
    Threads     = $Threads
    ChunkSizeKB = $ChunkSizeKB
    SizeProfile = $SizeProfile
}

$isRead      = $Scenario -like '*Read'
$chunkBytes  = $cfg.ChunkSizeKB * 1KB
$poolBytes   = $cfg.RandomPoolMB * 1MB
$connString  = Get-FsPocConnectionString -Instance $cfg.SqlInstance -Database $cfg.DemoDb
$resultsDir  = Join-Path $cfg.ResultsPath ("run_{0:yyyyMMdd_HHmmss}_{1}" -f (Get-Date), $Scenario)
if (-not $RunName) { $RunName = "$Scenario / $($cfg.SizeProfile) / $($cfg.Threads)t / $($cfg.ChunkSizeKB)KB" }
if ($Label) { $RunName = "$Label | $RunName" }

if ($chunkBytes -gt $poolBytes) {
    throw "ChunkSizeKB ($($cfg.ChunkSizeKB) KB) exceeds RandomPoolMB ($($cfg.RandomPoolMB) MB). Raise RandomPoolMB."
}

Write-Host ''
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host " FILESTREAM POC INGEST" -ForegroundColor Cyan
Write-Host '================================================================' -ForegroundColor Cyan
Write-FsPocLog "RunId      : $RunId"
Write-FsPocLog "Scenario   : $Scenario"
Write-FsPocLog "Instance   : $($cfg.SqlInstance) / $($cfg.DemoDb)"
Write-FsPocLog "Threads    : $($cfg.Threads)   Chunk: $($cfg.ChunkSizeKB) KB   Profile: $($cfg.SizeProfile)"
Write-FsPocLog "Results    : $resultsDir"

# ---------------------------------------------------------------------------
# Work plan
# ---------------------------------------------------------------------------
$plan = @(Get-FsPocWorkPlan -TargetGB $cfg.TargetGB -Profile $cfg.SizeProfile -Threads $cfg.Threads)
Write-FsPocWorkPlan -Plan $plan
if ($WhatIfPlan) { Write-FsPocLog 'WhatIfPlan set -- stopping before any work.' 'OK'; return }

# Real-file mode: enumerate once, hand each worker a stripe.
$sourceFiles = @()
if ($SourcePath) {
    if ($isRead) { throw '-SourcePath is not valid for read scenarios.' }
    Write-FsPocLog "Enumerating source files under $SourcePath ..." 'STEP'
    $sourceFiles = @(Get-ChildItem -LiteralPath $SourcePath -File -Recurse -ErrorAction Stop)
    if ($sourceFiles.Count -eq 0) { throw "No files found under $SourcePath" }
    $srcBytes = ($sourceFiles | Measure-Object Length -Sum).Sum
    Write-FsPocLog ("Found {0:N0} files, {1}" -f $sourceFiles.Count, (Format-FsPocBytes $srcBytes)) 'OK'
}

# --- Azure Blob: resolve the endpoint and credential -----------------------
$blobBaseUrl = ''
$blobSas     = ''
$blobAuth    = 'ManagedIdentity'
$blobMiId    = ''
$blobUrls    = @()

if ($Scenario -like 'AzureBlob*') {
    foreach ($k in 'BlobAccount', 'BlobContainer', 'BlobEndpoint') {
        if ([string]::IsNullOrWhiteSpace([string]$cfg.$k)) { throw "$k is not set in $ConfigPath." }
    }
    $blobBaseUrl = "https://$($cfg.BlobAccount).$($cfg.BlobEndpoint)/$($cfg.BlobContainer)"
    $blobAuth    = if ($cfg.PSObject.Properties['BlobAuth']) { [string]$cfg.BlobAuth } else { 'ManagedIdentity' }
    $blobMiId    = if ($cfg.PSObject.Properties['BlobManagedIdentityClientId']) { [string]$cfg.BlobManagedIdentityClientId } else { '' }

    # Azure Storage refuses anything below TLS 1.2, and .NET Framework's default
    # protocol list predates it -- without this every request fails with a
    # connection error that never mentions TLS.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $probeHeaders = @{ 'x-ms-version' = '2021-08-06' }
    $probeQuery   = 'restype=container&comp=list&maxresults=1'

    if ($blobAuth -eq 'ManagedIdentity') {
        $tokUri = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com%2F'
        if ($blobMiId) { $tokUri += "&client_id=$blobMiId" }
        try {
            $tok = Invoke-RestMethod -Uri $tokUri -Headers @{ Metadata = 'true' } -TimeoutSec 30
        }
        catch {
            throw "Could not get a managed identity token from IMDS: $($_.Exception.Message)`nIs a managed identity assigned to this VM? Set BlobAuth = 'Sas' in $ConfigPath to use a SAS token instead."
        }
        $probeHeaders['Authorization'] = "Bearer $($tok.access_token)"
        Write-FsPocLog "Managed identity token acquired (expires $([DateTimeOffset]::FromUnixTimeSeconds([long]$tok.expires_on).UtcDateTime.ToString('u')))." 'OK'
    }
    else {
        $blobSas = [string]$env:FSPOC_BLOB_SAS
        if ([string]::IsNullOrWhiteSpace($blobSas)) { $blobSas = [string]$cfg.BlobSasToken }
        $blobSas = $blobSas.TrimStart('?')
        if ([string]::IsNullOrWhiteSpace($blobSas)) {
            throw "BlobAuth is 'Sas' but no token was found. Set FSPOC_BLOB_SAS or BlobSasToken in $ConfigPath."
        }
        $probeQuery += "&$blobSas"
    }

    Write-FsPocLog "Blob container: $blobBaseUrl  (auth: $blobAuth)" 'OK'

    <#  Fail on the container, not on the 161,000th file.

        A missing container, an expired SAS, a firewall rule, or -- the common
        one with managed identity -- a control-plane role like Owner that
        carries no blob DATA permission, all produce the same symptom deep in a
        run: every upload failing identically, 40 minutes late. One list request
        settles it in a second.
    #>
    try {
        $null = Invoke-WebRequest -Uri "$blobBaseUrl`?$probeQuery" -Method GET -Headers $probeHeaders `
                    -UseBasicParsing -TimeoutSec 30
        Write-FsPocLog 'Container reachable and readable.' 'OK'
    }
    catch {
        $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
        $hint = switch ($code) {
            403 { "403 Forbidden. With managed identity this almost always means the identity has no DATA-plane role. Owner and Contributor do not grant blob access -- assign 'Storage Blob Data Contributor' on the account or container." }
            404 { "404 Not Found. Container '$($cfg.BlobContainer)' does not exist on account '$($cfg.BlobAccount)'." }
            default { $_.Exception.Message }
        }
        throw "Cannot reach $blobBaseUrl : $hint"
    }
}

if ($Scenario -eq 'AzureBlobRead') {
    $srcRun = if ($PSBoundParameters.ContainsKey('SourceRunId')) { $SourceRunId } else { $null }
    $bu = Invoke-FsPocSql -Instance $cfg.SqlInstance -Database $cfg.DemoDb `
            -Query 'EXEC dbo.usp_GetBlobUrlSample @RunId, @Top' -Parameters @{ RunId = $srcRun; Top = 500000 }
    $blobUrls = @($bu.Rows | ForEach-Object {
        [pscustomobject]@{ Url = [string]$_.BlobUrl; SizeBytes = [long]$_.SizeBytes; Bucket = [string]$_.Bucket } })
    if ($blobUrls.Count -eq 0) { throw 'dbo.BlobUrlStore holds no rows. Run an AzureBlob ingest first.' }
    Write-FsPocLog ("Blob read source: {0:N0} catalogued blob(s)" -f $blobUrls.Count) 'OK'
}

# --- FileTable: resolve the share root, or the file list for a read run ----
$fileTableRoot  = ''
$fileTablePaths = @()

if ($Scenario -eq 'FileTable') {
    $ft = Invoke-FsPocSql -Instance $cfg.SqlInstance -Database $cfg.DemoDb -Query 'EXEC dbo.usp_GetFileTableRoot'
    if ($ft.Rows.Count -eq 0 -or $ft.Rows[0].RootPath -is [DBNull]) {
        throw "FileTableRootPath() returned NULL. The database needs NON_TRANSACTED_ACCESS = FULL and a DIRECTORY_NAME, and the instance needs FILESTREAM level 2 or higher. Re-run sql\02-create-database.sql."
    }
    $fileTableRoot = [string]$ft.Rows[0].RootPath
    Write-FsPocLog "FileTable share root: $fileTableRoot" 'OK'
    if (-not (Test-Path -LiteralPath $fileTableRoot)) {
        throw "The FileTable share root is not reachable from this client: $fileTableRoot"
    }
}
elseif ($Scenario -eq 'FileTableRead') {
    $ftp = Invoke-FsPocSql -Instance $cfg.SqlInstance -Database $cfg.DemoDb `
             -Query 'EXEC dbo.usp_GetFileTableSample @Top' -Parameters @{ Top = 500000 }
    $fileTablePaths = @($ftp.Rows | ForEach-Object {
        [pscustomobject]@{ FullPath = [string]$_.FullPath; SizeBytes = [long]$_.SizeBytes } })
    if ($fileTablePaths.Count -eq 0) { throw 'The FileTable holds no files. Run a FileTable ingest first.' }
    Write-FsPocLog ("FileTable read source: {0:N0} file(s)" -f $fileTablePaths.Count) 'OK'
}

# Read scenarios over FileStore/BlobStore need the FileId range to sample from.
$readRange = $null
if ($isRead -and $Scenario -ne 'FileTableRead') {
    $tbl = if ($Scenario -eq 'BlobRead') { 'BlobStore' } else { 'FileStore' }
    $srcRun = if ($PSBoundParameters.ContainsKey('SourceRunId')) { $SourceRunId } else { $null }
    $rr = Invoke-FsPocSql -Instance $cfg.SqlInstance -Database $cfg.DemoDb `
            -Query "EXEC dbo.usp_GetRunFileRange @RunId, @Table" `
            -Parameters @{ RunId = $srcRun; Table = $tbl }
    if ($rr.Rows.Count -eq 0 -or $rr.Rows[0].Files -eq 0) { throw "No rows in dbo.$tbl to read back. Run an ingest first." }
    $readRange = [pscustomobject]@{
        MinFileId = [long]$rr.Rows[0].MinFileId
        MaxFileId = [long]$rr.Rows[0].MaxFileId
        Files     = [long]$rr.Rows[0].Files
    }
    Write-FsPocLog ("Read source: {0:N0} rows, FileId {1}..{2}" -f $readRange.Files, $readRange.MinFileId, $readRange.MaxFileId) 'OK'
}

$null = New-Item -ItemType Directory -Path $resultsDir -Force

# ---------------------------------------------------------------------------
# Source data pool (writes only)
# ---------------------------------------------------------------------------
$pool = $null
if (-not $isRead -and -not $SourcePath) {
    $pool = New-FsPocRandomPool -SizeMB $cfg.RandomPoolMB
}

# ---------------------------------------------------------------------------
# Register the run
# ---------------------------------------------------------------------------
$targetBytes = [long]($cfg.TargetGB * 1GB)
if (-not $NoMonitorDb) {
    $paramsJson = ($cfg | ConvertTo-Json -Compress -Depth 3)
    Invoke-FsPocSql -Instance $cfg.SqlInstance -Database $cfg.MonitorDb -NonQuery `
        -Query @'
EXEC dbo.usp_StartRun @RunId, @RunName, @Scenario, @TargetDb, @Threads,
                      @ChunkSizeKB, @SizeProfile, @TargetBytes, @ProcmonActive, @ParamsJson
'@ -Parameters @{
            RunId = $RunId; RunName = $RunName; Scenario = $Scenario; TargetDb = $cfg.DemoDb
            Threads = $cfg.Threads; ChunkSizeKB = $cfg.ChunkSizeKB; SizeProfile = $cfg.SizeProfile
            TargetBytes = $targetBytes
            ProcmonActive = [int][bool]$ProcmonActive
            ParamsJson = $paramsJson
        } | Out-Null
    Write-FsPocLog 'Run registered in FsPocMonitor.' 'OK'
}

# ===========================================================================
# WORKER
# ===========================================================================
$worker = {
    param(
        [int]      $WorkerId,
        [string]   $ConnectionString,
        [guid]     $RunId,
        [string]   $Scenario,
        [object[]] $Plan,
        [int]      $ChunkBytes,
        [byte[]]   $Pool,
        [string]   $TimingCsv,
        [hashtable]$Progress,
        [hashtable]$Control,
        [int]      $Seed,
        [bool]     $Preallocate,
        [object[]] $SourceFiles,
        [object]   $ReadRange,
        [long]     $ReadOpCount,
        [string]   $FileTableRoot,
        [bool]     $FileTableFlush,
        [object[]] $FileTablePaths,
        [string]   $BlobBaseUrl,
        [string]   $BlobSas,
        [object[]] $BlobUrls,
        [string]   $BlobAuth,
        [string]   $BlobMiClientId
    )

    $ErrorActionPreference = 'Stop'
    $rand   = New-Object System.Random $Seed
    $sw     = New-Object System.Diagnostics.Stopwatch
    $swAll  = New-Object System.Diagnostics.Stopwatch
    $key    = "w$WorkerId"
    $Progress[$key] = @{
        Bytes = [long]0; Files = [long]0; Errors = [long]0; Done = $false
        # Errors are split by kind because they need different responses.
        # Structural means the environment is wrong -- a missing proc, a denied
        # path, a full disk -- and every remaining file will fail the same way,
        # so the run should stop. Transient means the connection died under load
        # (a commit that outran its timeout is the usual cause here); the right
        # response is to reconnect and keep going, because this POC exists to
        # push the disk until exactly that happens.
        Structural = [long]0; Transient = [long]0; Reconnects = [long]0
        LastError = ''
        # Structured failures. Exceptions are caught per file so they never
        # reach the runspace's error stream -- without this the caller sees a
        # count and nothing else, which is useless for diagnosis.
        ErrorList = New-Object System.Collections.ArrayList
    }
    $me     = $Progress[$key]

    $csv = New-Object System.IO.StreamWriter($TimingCsv, $false, [System.Text.Encoding]::UTF8)
    $csv.AutoFlush = $false
    $csv.WriteLine('WorkerId,Seq,Bucket,FileName,SizeBytes,StartedAtUtc,OpenMs,WriteMs,CommitMs,TotalMs')

    $conn = New-Object System.Data.SqlClient.SqlConnection $ConnectionString
    $conn.Open()

    # Reusable buffer for the T-SQL chunked paths (FILESTREAM writes straight
    # from the shared pool with an offset and needs no copy).
    $chunkBuf = New-Object byte[] $ChunkBytes
    $seq = [long]0
    # FileTable directories are rows too: creating one is a write. Track which
    # this worker has already made so it is done once, not once per file.
    $createdDirs = New-Object 'System.Collections.Generic.HashSet[string]'

    <#  One HttpClient per worker, for the AzureBlob scenarios.

        Two settings that are not optional on Windows PowerShell 5.1:

        TLS 1.2 -- .NET Framework's default protocol list predates it, and Azure
        Storage refuses anything older, so without this every request fails with
        a connection error that says nothing about TLS.

        DefaultConnectionLimit -- defaults to 2 per endpoint. Eight workers would
        silently queue behind two connections and the run would report the
        concurrency it was given rather than the concurrency it had.
    #>
    $http = $null
    if ($Scenario -like 'AzureBlob*') {
        Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        [Net.ServicePointManager]::DefaultConnectionLimit = 256
        [Net.ServicePointManager]::Expect100Continue = $false
        $http = New-Object System.Net.Http.HttpClient
        $http.Timeout = [TimeSpan]::FromMinutes(15)
        $null = $http.DefaultRequestHeaders.TryAddWithoutValidation('x-ms-version', '2021-08-06')
    }
    # Managed identity tokens last hours, but a long run can outlive one. Each
    # worker holds its own and refreshes inline; IMDS is link-local so the call
    # is cheap. Refreshed BEFORE expiry, never in response to a 401, so no file
    # pays for the rotation with a failed upload.
    $blobToken    = ''
    $blobTokenExp = [DateTime]::MinValue
    # Query-string fragments: empty under managed identity, the SAS otherwise.
    $sasFirst = if ($BlobAuth -eq 'Sas' -and $BlobSas) { "?$BlobSas" } else { '' }
    $sasMore  = if ($BlobAuth -eq 'Sas' -and $BlobSas) { "&$BlobSas" } else { '' }

    try {
        # -------------------------------------------------------------------
        # Build this worker's list of work items
        # -------------------------------------------------------------------
        $items = New-Object System.Collections.Generic.List[object]

        if ($Scenario -eq 'AzureBlobRead') {
            for ($i = $WorkerId; $i -lt $BlobUrls.Count; $i += $Control['Threads']) {
                $b = $BlobUrls[$i]
                $items.Add([pscustomobject]@{ Bucket = $b.Bucket; FileId = [long]0; SizeBytes = [long]$b.SizeBytes; Path = [string]$b.Url })
            }
        }
        elseif ($Scenario -eq 'FileTableRead') {
            # Stripe the real path list across workers.
            for ($i = $WorkerId; $i -lt $FileTablePaths.Count; $i += $Control['Threads']) {
                $f = $FileTablePaths[$i]
                $items.Add([pscustomobject]@{ Bucket = 'read'; FileId = [long]0; SizeBytes = [long]$f.SizeBytes; Path = [string]$f.FullPath })
            }
        }
        elseif ($Scenario -like '*Read') {
            $span = [long]($ReadRange.MaxFileId - $ReadRange.MinFileId + 1)
            for ($i = 0; $i -lt $ReadOpCount; $i++) {
                $fid = $ReadRange.MinFileId + [long]($rand.NextDouble() * $span)
                $items.Add([pscustomobject]@{ Bucket = 'read'; FileId = $fid; SizeBytes = [long]0; Path = $null })
            }
        }
        elseif ($SourceFiles -and $SourceFiles.Count -gt 0) {
            for ($i = $WorkerId; $i -lt $SourceFiles.Count; $i += $Control['Threads']) {
                $f = $SourceFiles[$i]
                $items.Add([pscustomobject]@{ Bucket = 'source'; FileId = [long]0; SizeBytes = [long]$f.Length; Path = $f.FullName })
            }
        }
        else {
            foreach ($b in $Plan) {
                $budget = [long]$b.BytesPerWorker
                $span   = [long]($b.MaxBytes - $b.MinBytes)
                while ($budget -gt 0) {
                    $size = [long]$b.MinBytes + [long]($rand.NextDouble() * $span)
                    if ($size -gt $budget) { $size = $budget }
                    if ($size -lt 1KB) { break }
                    $items.Add([pscustomobject]@{ Bucket = $b.Bucket; FileId = [long]0; SizeBytes = $size; Path = $null })
                    $budget -= $size
                }
            }
        }

        # -------------------------------------------------------------------
        # Execute
        # -------------------------------------------------------------------
        foreach ($item in $items) {
            if ($Control['Stop']) { break }
            $seq++
            $startUtc = [DateTime]::UtcNow
            $swAll.Restart()
            $openMs = 0.0; $writeMs = 0.0; $commitMs = 0.0
            $tx = $null
            $skip = $false
            $stage = 'start'
            $diagPath = ''      # PathName() returned by SQL Server
            $diagCtx  = -1      # length of the FILESTREAM transaction context

            try {
                switch -Wildcard ($Scenario) {

                    # ---------------- FILESTREAM WRITE ----------------------
                    'Filestream' {
                        $size    = $item.SizeBytes
                        $rowGuid = [guid]::NewGuid()
                        $name    = "$($item.Bucket)/w$WorkerId/$($rowGuid.ToString('N')).bin"

                        $sw.Restart()
                        $stage = 'begin-transaction'
                        $tx  = $conn.BeginTransaction()
                        $stage = 'usp_BeginFileStreamInsert'
                        $cmd = $conn.CreateCommand()
                        $cmd.Transaction   = $tx
                        $cmd.CommandType   = [System.Data.CommandType]::StoredProcedure
                        $cmd.CommandText   = 'dbo.usp_BeginFileStreamInsert'
                        $cmd.CommandTimeout = 0
                        $null = $cmd.Parameters.AddWithValue('@RowGuid',   $rowGuid)
                        $null = $cmd.Parameters.AddWithValue('@RunId',     $RunId)
                        $null = $cmd.Parameters.AddWithValue('@Bucket',    $item.Bucket)
                        $null = $cmd.Parameters.AddWithValue('@FileName',  $name)
                        $null = $cmd.Parameters.AddWithValue('@SizeBytes', $size)

                        $rdr = $cmd.ExecuteReader()
                        if (-not $rdr.Read()) { $rdr.Close(); throw 'usp_BeginFileStreamInsert returned no row' }

                        # Read both values defensively and report precisely
                        # which one was missing. A NULL PathName means the
                        # FILESTREAM value was NULL rather than 0x; a NULL
                        # transaction context means the transaction is not
                        # FILESTREAM-enabled. Casting a DBNull straight to
                        # [byte[]] would throw a conversion error that names
                        # neither cause.
                        $stage = 'read PathName / transaction context'
                        if ($rdr.IsDBNull(0)) { $rdr.Close(); throw 'PathName() returned NULL -- the FILESTREAM column is NULL, not 0x' }
                        $fsPath = $rdr.GetString(0)
                        $diagPath = $fsPath
                        if ($rdr.IsDBNull(1)) { $rdr.Close(); throw 'GET_FILESTREAM_TRANSACTION_CONTEXT() returned NULL -- no FILESTREAM-enabled transaction on this connection' }
                        $fsCtx  = [byte[]]$rdr.GetValue(1)
                        $diagCtx = $fsCtx.Length
                        $rdr.Close()
                        $sw.Stop(); $openMs = $sw.Elapsed.TotalMilliseconds

                        $sw.Restart()
                        $stage = 'SqlFileStream open'
                        $alloc = if ($Preallocate) { [long]$size } else { [long]0 }
                        $sfs = New-Object System.Data.SqlTypes.SqlFileStream(
                                    $fsPath, $fsCtx,
                                    [System.IO.FileAccess]::Write,
                                    [System.IO.FileOptions]::SequentialScan,
                                    $alloc)
                        try {
                            $stage = 'SqlFileStream write'
                            $remaining = $size
                            while ($remaining -gt 0) {
                                $n   = [int][Math]::Min([long]$ChunkBytes, $remaining)
                                # Random offset into the shared pool: no copy, and
                                # the resulting file is incompressible.
                                $off = $rand.Next(0, $Pool.Length - $n)
                                $sfs.Write($Pool, $off, $n)
                                $remaining -= $n
                            }
                            $sfs.Flush()
                        }
                        finally { $sfs.Close(); $sfs.Dispose() }
                        $sw.Stop(); $writeMs = $sw.Elapsed.TotalMilliseconds

                        $stage = 'commit'
                        $sw.Restart(); $tx.Commit(); $sw.Stop()
                        $commitMs = $sw.Elapsed.TotalMilliseconds
                        $tx.Dispose(); $tx = $null
                        $me['Bytes'] += $size
                    }

                    # ---------------- BLOB WRITE (baseline) -----------------
                    'Blob' {
                        $size = $item.SizeBytes
                        $name = "$($item.Bucket)/w$WorkerId/$([guid]::NewGuid().ToString('N')).bin"

                        $sw.Restart()
                        $tx  = $conn.BeginTransaction()
                        $cmd = $conn.CreateCommand()
                        $cmd.Transaction = $tx
                        $cmd.CommandType = [System.Data.CommandType]::StoredProcedure
                        $cmd.CommandText = 'dbo.usp_BeginBlobInsert'
                        $cmd.CommandTimeout = 0
                        $null = $cmd.Parameters.AddWithValue('@RunId',     $RunId)
                        $null = $cmd.Parameters.AddWithValue('@Bucket',    $item.Bucket)
                        $null = $cmd.Parameters.AddWithValue('@FileName',  $name)
                        $null = $cmd.Parameters.AddWithValue('@SizeBytes', $size)
                        $null = $cmd.Parameters.AddWithValue('@ContentHash', [DBNull]::Value)
                        $fileId = [long]$cmd.ExecuteScalar()
                        $sw.Stop(); $openMs = $sw.Elapsed.TotalMilliseconds

                        $sw.Restart()
                        $app = $conn.CreateCommand()
                        $app.Transaction = $tx
                        $app.CommandType = [System.Data.CommandType]::StoredProcedure
                        $app.CommandText = 'dbo.usp_AppendBlob'
                        $app.CommandTimeout = 0
                        $null = $app.Parameters.AddWithValue('@FileId', $fileId)
                        $pChunk = $app.Parameters.Add('@Chunk', [System.Data.SqlDbType]::VarBinary, -1)

                        $remaining = $size
                        while ($remaining -gt 0) {
                            $n   = [int][Math]::Min([long]$ChunkBytes, $remaining)
                            $off = $rand.Next(0, $Pool.Length - $n)
                            if ($n -eq $ChunkBytes) {
                                [Array]::Copy($Pool, $off, $chunkBuf, 0, $n)
                                $pChunk.Value = $chunkBuf
                            }
                            else {
                                $tail = New-Object byte[] $n
                                [Array]::Copy($Pool, $off, $tail, 0, $n)
                                $pChunk.Value = $tail
                            }
                            $pChunk.Size = $n
                            $null = $app.ExecuteNonQuery()
                            $remaining -= $n
                        }
                        $sw.Stop(); $writeMs = $sw.Elapsed.TotalMilliseconds

                        $sw.Restart(); $tx.Commit(); $sw.Stop()
                        $commitMs = $sw.Elapsed.TotalMilliseconds
                        $tx.Dispose(); $tx = $null
                        $me['Bytes'] += $size
                    }

                    # ---------------- AZURE BLOB WRITE ----------------------
                    # Upload the bytes to Azure, then record a row in SQL Server
                    # pointing at them. Upload FIRST: a failure then leaves an
                    # orphan blob rather than a row referencing a blob that does
                    # not exist. The two cannot share a transaction.
                    'AzureBlob' {
                        $size = $item.SizeBytes
                        $name = "$($item.Bucket)/w$WorkerId/$([guid]::NewGuid().ToString('N')).bin"
                        $blobUrl = "$BlobBaseUrl/$name"
                        $etag = $null

                        if ($BlobAuth -eq 'ManagedIdentity' -and $blobTokenExp -lt [DateTime]::UtcNow.AddMinutes(5)) {
                            $stage = 'IMDS token'
                            $tokUri = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com%2F'
                            if ($BlobMiClientId) { $tokUri += "&client_id=$BlobMiClientId" }
                            $tr = Invoke-RestMethod -Uri $tokUri -Headers @{ Metadata = 'true' } -TimeoutSec 30
                            $blobToken    = [string]$tr.access_token
                            $blobTokenExp = [DateTimeOffset]::FromUnixTimeSeconds([long]$tr.expires_on).UtcDateTime
                            $http.DefaultRequestHeaders.Authorization =
                                New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $blobToken)
                        }

                        $sw.Restart()
                        try {
                            if ($size -le [long]$ChunkBytes) {
                                # Single-shot Put Blob: what any client does below
                                # the chunk size, and one round trip instead of two.
                                $stage = 'blob PUT (single)'
                                $off = $rand.Next(0, $Pool.Length - [int]$size)
                                $body = New-Object System.Net.Http.ByteArrayContent($Pool, $off, [int]$size)
                                $null = $body.Headers.TryAddWithoutValidation('x-ms-blob-type', 'BlockBlob')
                                $resp = $http.PutAsync("$blobUrl$sasFirst", $body).GetAwaiter().GetResult()
                                try {
                                    if (-not $resp.IsSuccessStatusCode) { throw "PUT $([int]$resp.StatusCode) $($resp.ReasonPhrase)" }
                                    if ($resp.Headers.ETag) { $etag = $resp.Headers.ETag.Tag }
                                }
                                finally { $resp.Dispose(); $body.Dispose() }
                            }
                            else {
                                # Put Block xN then Put Block List. Block ids must be
                                # base64 and the SAME length across a blob, hence D6.
                                $stage = 'blob PUT (blocks)'
                                $ids = New-Object System.Collections.Generic.List[string]
                                $remaining = $size
                                $bi = 0
                                while ($remaining -gt 0) {
                                    $n   = [int][Math]::Min([long]$ChunkBytes, $remaining)
                                    $off = $rand.Next(0, $Pool.Length - $n)
                                    $id  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($bi.ToString('D6')))
                                    $ids.Add($id)
                                    $u = "$blobUrl`?comp=block&blockid=$([Uri]::EscapeDataString($id))$sasMore"
                                    $body = New-Object System.Net.Http.ByteArrayContent($Pool, $off, $n)
                                    $resp = $http.PutAsync($u, $body).GetAwaiter().GetResult()
                                    try {
                                        if (-not $resp.IsSuccessStatusCode) { throw "Put Block $bi -> $([int]$resp.StatusCode) $($resp.ReasonPhrase)" }
                                    }
                                    finally { $resp.Dispose(); $body.Dispose() }
                                    $remaining -= $n; $bi++
                                }

                                $stage = 'blob commit block list'
                                $sb = New-Object System.Text.StringBuilder
                                $null = $sb.Append('<?xml version="1.0" encoding="utf-8"?><BlockList>')
                                foreach ($id in $ids) { $null = $sb.Append('<Latest>').Append($id).Append('</Latest>') }
                                $null = $sb.Append('</BlockList>')
                                $body = New-Object System.Net.Http.StringContent($sb.ToString(), [Text.Encoding]::UTF8, 'application/xml')
                                $resp = $http.PutAsync("$blobUrl`?comp=blocklist$sasMore", $body).GetAwaiter().GetResult()
                                try {
                                    if (-not $resp.IsSuccessStatusCode) { throw "Put Block List -> $([int]$resp.StatusCode) $($resp.ReasonPhrase)" }
                                    if ($resp.Headers.ETag) { $etag = $resp.Headers.ETag.Tag }
                                }
                                finally { $resp.Dispose(); $body.Dispose() }
                            }
                        }
                        finally { $sw.Stop(); $writeMs = $sw.Elapsed.TotalMilliseconds }

                        # The catalog write. Timed as commit, because it is the
                        # durable metadata write this path pays in place of the
                        # other three paths' transaction commit.
                        $sw.Restart()
                        $stage = 'SQL catalog insert'
                        $cmd = $conn.CreateCommand()
                        $cmd.CommandType = [System.Data.CommandType]::StoredProcedure
                        $cmd.CommandText = 'dbo.usp_InsertBlobUrl'
                        $cmd.CommandTimeout = 0
                        $null = $cmd.Parameters.AddWithValue('@RunId',     $RunId)
                        $null = $cmd.Parameters.AddWithValue('@Bucket',    $item.Bucket)
                        $null = $cmd.Parameters.AddWithValue('@FileName',  $name)
                        $null = $cmd.Parameters.AddWithValue('@SizeBytes', $size)
                        $null = $cmd.Parameters.AddWithValue('@BlobUrl',   $blobUrl)
                        $null = $cmd.Parameters.AddWithValue('@ETag',      $(if ($etag) { $etag } else { [DBNull]::Value }))
                        $null = $cmd.ExecuteNonQuery()
                        $sw.Stop(); $commitMs = $sw.Elapsed.TotalMilliseconds

                        $me['Bytes'] += $size
                    }

                    # ---------------- AZURE BLOB READ -----------------------
                    # Catalog lookup already happened in bulk; this is the fetch.
                    'AzureBlobRead' {
                        if ($BlobAuth -eq 'ManagedIdentity' -and $blobTokenExp -lt [DateTime]::UtcNow.AddMinutes(5)) {
                            $stage = 'IMDS token'
                            $tokUri = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com%2F'
                            if ($BlobMiClientId) { $tokUri += "&client_id=$BlobMiClientId" }
                            $tr = Invoke-RestMethod -Uri $tokUri -Headers @{ Metadata = 'true' } -TimeoutSec 30
                            $blobToken    = [string]$tr.access_token
                            $blobTokenExp = [DateTimeOffset]::FromUnixTimeSeconds([long]$tr.expires_on).UtcDateTime
                            $http.DefaultRequestHeaders.Authorization =
                                New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $blobToken)
                        }
                        $sw.Restart()
                        $stage = 'blob GET'
                        $read = [long]0
                        $resp = $http.GetAsync("$($item.Path)$sasFirst",
                                    [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                        try {
                            if (-not $resp.IsSuccessStatusCode) { throw "GET $([int]$resp.StatusCode) $($resp.ReasonPhrase)" }
                            $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                            try { while (($n = $stream.Read($chunkBuf, 0, $chunkBuf.Length)) -gt 0) { $read += $n } }
                            finally { $stream.Dispose() }
                        }
                        finally { $resp.Dispose() }
                        $sw.Stop(); $writeMs = $sw.Elapsed.TotalMilliseconds

                        if ($item.SizeBytes -gt 0 -and $read -ne $item.SizeBytes) {
                            $me['Errors']++
                            $me['LastError'] = "Short read on $($item.Path): $read of $($item.SizeBytes)"
                        }
                        $item.SizeBytes = $read
                        $me['Bytes'] += $read
                    }

                    # ---------------- FILETABLE WRITE -----------------------
                    # Ordinary Win32 file I/O over the SMB share. No SQL
                    # connection is touched: SQL Server surfaces the file as a
                    # row on its own. That is the entire point of the
                    # comparison, so there is deliberately no transaction and
                    # no commit phase here.
                    'FileTable' {
                        $size = $item.SizeBytes
                        $dir  = Join-Path (Join-Path $FileTableRoot "w$WorkerId") $item.Bucket
                        if (-not $createdDirs.Contains($dir)) {
                            $stage = 'FileTable create directory'
                            $null = [System.IO.Directory]::CreateDirectory($dir)
                            $null = $createdDirs.Add($dir)
                        }
                        $path = Join-Path $dir ([guid]::NewGuid().ToString('N') + '.bin')

                        $sw.Restart()
                        $stage = 'FileTable create file'
                        $fs = [System.IO.File]::Create($path, $ChunkBytes, [System.IO.FileOptions]::SequentialScan)
                        $sw.Stop(); $openMs = $sw.Elapsed.TotalMilliseconds

                        $sw.Restart()
                        try {
                            $stage = 'FileTable write'
                            $remaining = $size
                            while ($remaining -gt 0) {
                                $n   = [int][Math]::Min([long]$ChunkBytes, $remaining)
                                $off = $rand.Next(0, $Pool.Length - $n)
                                $fs.Write($Pool, $off, $n)
                                $remaining -= $n
                            }
                            # Flush(true) forces the file to stable storage,
                            # which is what a FILESTREAM commit does implicitly.
                            if ($FileTableFlush) { $fs.Flush($true) }
                        }
                        finally { $fs.Close(); $fs.Dispose() }
                        $sw.Stop(); $writeMs = $sw.Elapsed.TotalMilliseconds

                        # commitMs stays 0: there is no transaction to commit.
                        $me['Bytes'] += $size
                    }

                    # ---------------- FILETABLE READ ------------------------
                    'FileTableRead' {
                        $sw.Restart()
                        $stage = 'FileTable open for read'
                        $fs = [System.IO.File]::Open($item.Path, [System.IO.FileMode]::Open,
                                                     [System.IO.FileAccess]::Read,
                                                     [System.IO.FileShare]::Read)
                        $sw.Stop(); $openMs = $sw.Elapsed.TotalMilliseconds

                        $sw.Restart()
                        $read = [long]0
                        try {
                            $stage = 'FileTable read'
                            while (($n = $fs.Read($chunkBuf, 0, $chunkBuf.Length)) -gt 0) { $read += $n }
                        }
                        finally { $fs.Close(); $fs.Dispose() }
                        $sw.Stop(); $writeMs = $sw.Elapsed.TotalMilliseconds

                        if ($item.SizeBytes -gt 0 -and $read -ne $item.SizeBytes) {
                            $me['Errors']++
                            $me['LastError'] = "Short read on $($item.Path): $read of $($item.SizeBytes)"
                        }
                        $item.SizeBytes = $read
                        $me['Bytes'] += $read
                    }

                    # ---------------- FILESTREAM READ -----------------------
                    'FilestreamRead' {
                        $sw.Restart()
                        $tx  = $conn.BeginTransaction()
                        $cmd = $conn.CreateCommand()
                        $cmd.Transaction = $tx
                        $cmd.CommandType = [System.Data.CommandType]::StoredProcedure
                        $cmd.CommandText = 'dbo.usp_BeginFileStreamRead'
                        $cmd.CommandTimeout = 0
                        $null = $cmd.Parameters.AddWithValue('@FileId', $item.FileId)
                        $rdr = $cmd.ExecuteReader()
                        $found = $rdr.Read()
                        if (-not $found) {
                            # Sampled FileId landed in an identity gap. Not an
                            # error -- just skip without recording a timing row.
                            $rdr.Close(); $tx.Rollback(); $tx.Dispose(); $tx = $null
                            $skip = $true; break
                        }
                        $fsPath = $rdr.GetString(0)
                        $fsCtx  = [byte[]]$rdr.GetValue(1)
                        $size   = [long]$rdr.GetValue(2)
                        $rdr.Close()
                        $sw.Stop(); $openMs = $sw.Elapsed.TotalMilliseconds

                        $sw.Restart()
                        $read = [long]0
                        $sfs = New-Object System.Data.SqlTypes.SqlFileStream(
                                    $fsPath, $fsCtx,
                                    [System.IO.FileAccess]::Read,
                                    [System.IO.FileOptions]::SequentialScan,
                                    [long]0)
                        try {
                            while (($n = $sfs.Read($chunkBuf, 0, $chunkBuf.Length)) -gt 0) { $read += $n }
                        }
                        finally { $sfs.Close(); $sfs.Dispose() }
                        $sw.Stop(); $writeMs = $sw.Elapsed.TotalMilliseconds

                        $sw.Restart(); $tx.Commit(); $sw.Stop()
                        $commitMs = $sw.Elapsed.TotalMilliseconds
                        $tx.Dispose(); $tx = $null

                        if ($read -ne $size) { $me['Errors']++; $me['LastError'] = "Short read on FileId $($item.FileId): $read of $size" }
                        $item.SizeBytes = $read
                        $me['Bytes'] += $read
                    }

                    # ---------------- BLOB READ (baseline) ------------------
                    'BlobRead' {
                        $sw.Restart()
                        $cmd = $conn.CreateCommand()
                        $cmd.CommandText = 'SELECT SizeBytes, FileData FROM dbo.BlobStore WHERE FileId = @FileId'
                        $cmd.CommandTimeout = 0
                        $null = $cmd.Parameters.AddWithValue('@FileId', $item.FileId)
                        $rdr = $cmd.ExecuteReader([System.Data.CommandBehavior]::SequentialAccess)
                        $found = $rdr.Read()
                        if (-not $found) { $rdr.Close(); $skip = $true; break }
                        $size = [long]$rdr.GetValue(0)
                        $sw.Stop(); $openMs = $sw.Elapsed.TotalMilliseconds

                        $sw.Restart()
                        $read = [long]0
                        while (($n = $rdr.GetBytes(1, $read, $chunkBuf, 0, $chunkBuf.Length)) -gt 0) { $read += $n }
                        $rdr.Close()
                        $sw.Stop(); $writeMs = $sw.Elapsed.TotalMilliseconds

                        if ($read -ne $size) { $me['Errors']++; $me['LastError'] = "Short read on FileId $($item.FileId): $read of $size" }
                        $item.SizeBytes = $read
                        $me['Bytes'] += $read
                    }
                }

                if ($skip) { continue }

                $swAll.Stop()
                $me['Files']++
                $csv.WriteLine(('{0},{1},{2},{3},{4},{5:yyyy-MM-dd HH:mm:ss.fff},{6:F3},{7:F3},{8:F3},{9:F3}' -f `
                    $WorkerId, $seq, $item.Bucket,
                    $(if ($item.Path) { [IO.Path]::GetFileName($item.Path) } else { "$($item.Bucket)_$seq" }),
                    $item.SizeBytes, $startUtc, $openMs, $writeMs, $commitMs, $swAll.Elapsed.TotalMilliseconds))
                if ($seq % 200 -eq 0) { $csv.Flush() }
            }
            catch {
                $me['Errors']++
                $ex = $_.Exception
                $inner = ''
                $probe = $ex.InnerException
                while ($probe) { $inner += "$($probe.GetType().Name): $($probe.Message); "; $probe = $probe.InnerException }

                $me['LastError'] = "[$stage] $($ex.GetType().Name): $($ex.Message)"
                $null = $me['ErrorList'].Add([pscustomobject]@{
                    WorkerId   = $WorkerId
                    Seq        = $seq
                    Stage      = $stage
                    Bucket     = $item.Bucket
                    SizeBytes  = $item.SizeBytes
                    Exception  = $ex.GetType().FullName
                    Message    = $ex.Message
                    Inner      = $inner
                    PathName   = $diagPath
                    ContextLen = $diagCtx
                })

                if ($tx) { try { $tx.Rollback() } catch { }; try { $tx.Dispose() } catch { }; $tx = $null }

                <#  Classify, then recover.

                    A commit that outruns its timeout leaves the connection
                    broken, and SqlTransaction.Commit() has no settable timeout
                    -- ADO.NET commits on an internal default. Every later file
                    on this worker then fails instantly at begin-transaction
                    with "the connection is closed", so ONE slow commit used to
                    manufacture 25 more errors, trip the threshold below, and
                    set Control.Stop -- which is global. A single slow commit
                    stopped all eight workers and ended a 200 GB run at 145 GB,
                    reported as success with 26 errors.

                    On a saturated disk a slow commit is the expected outcome,
                    not a structural fault, so it must not end the run.
                #>
                $chain = "$($ex.Message) $inner"
                $isTransient =
                    ($chain -match 'PUT 50[0-9]') -or ($chain -match 'GET 50[0-9]') -or
                    ($chain -match 'Put Block.*-> 50[0-9]') -or
                    ($chain -match 'ServerBusy') -or ($chain -match 'OperationTimedOut') -or
                    ($chain -match 'task was canceled') -or
                    ($conn.State -ne [System.Data.ConnectionState]::Open) -or
                    ($chain -match 'Execution Timeout Expired') -or
                    ($chain -match 'connection is closed') -or
                    ($chain -match 'transport-level error') -or
                    ($chain -match 'wait operation timed out')

                if ($isTransient) {
                    $me['Transient']++
                    if ($conn.State -ne [System.Data.ConnectionState]::Open) {
                        try { $conn.Close() } catch { }
                        try {
                            $conn.Open()
                            $me['Reconnects']++
                        }
                        catch {
                            # Cannot get back to the instance at all: that IS structural.
                            $me['Structural']++
                        }
                    }
                }
                else { $me['Structural']++ }

                # Structural failures repeat on every remaining file, so stop the
                # run rather than burn an hour producing garbage. The transient
                # cap is a backstop against a pathological reconnect loop.
                if ($me['Structural'] -gt 25 -or $me['Transient'] -gt 500) {
                    $Control['Stop'] = $true; $Control['FatalWorker'] = $WorkerId; break
                }
            }
        }
    }
    finally {
        $me['Done'] = $true
        try { $csv.Flush(); $csv.Close(); $csv.Dispose() } catch { }
        try { $conn.Close(); $conn.Dispose() } catch { }
        if ($http) { try { $http.Dispose() } catch { } }
    }
}

# ===========================================================================
# LAUNCH
# ===========================================================================
$progress = [hashtable]::Synchronized(@{})
$control  = [hashtable]::Synchronized(@{ Stop = $false; Threads = $cfg.Threads; FatalWorker = -1 })

$iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$iss.ApartmentState = 'MTA'
$rsPool = [runspacefactory]::CreateRunspacePool(1, $cfg.Threads, $iss, $Host)
$rsPool.Open()

# Read scenarios: how many read ops per worker to roughly cover TargetGB.
$readOpsPerWorker = 0
if ($isRead) {
    $readOpsPerWorker = [long][Math]::Ceiling($readRange.Files / [double]$cfg.Threads)
}

$jobs = @()
foreach ($w in 0..($cfg.Threads - 1)) {
    $ps = [powershell]::Create()
    $ps.RunspacePool = $rsPool
    $null = $ps.AddScript($worker).
        AddArgument($w).
        AddArgument($connString).
        AddArgument($RunId).
        AddArgument($Scenario).
        AddArgument($plan).
        AddArgument([int]$chunkBytes).
        AddArgument($pool).
        AddArgument((Join-Path $resultsDir "timings_w$w.csv")).
        AddArgument($progress).
        AddArgument($control).
        AddArgument((Get-Random -Minimum 1 -Maximum 2147483647)).
        AddArgument([bool]$Preallocate).
        AddArgument($sourceFiles).
        AddArgument($readRange).
        AddArgument([long]$readOpsPerWorker).
        AddArgument([string]$fileTableRoot).
        AddArgument([bool]$FileTableFlush).
        AddArgument($fileTablePaths).
        AddArgument([string]$blobBaseUrl).
        AddArgument([string]$blobSas).
        AddArgument($blobUrls).
        AddArgument([string]$blobAuth).
        AddArgument([string]$blobMiId)
    $jobs += [pscustomobject]@{ Id = $w; Shell = $ps; Handle = $ps.BeginInvoke() }
}

Write-FsPocLog "Launched $($cfg.Threads) workers." 'STEP'

# Snapshot the "before" state
if (-not $NoMonitorDb) {
    Invoke-FsPocSql -Instance $cfg.SqlInstance -Database $cfg.MonitorDb -NonQuery `
        -Query 'EXEC dbo.usp_CaptureSnapshot @RunId, @Phase, @TargetDb' `
        -Parameters @{ RunId = $RunId; Phase = 'start'; TargetDb = $cfg.DemoDb } | Out-Null
}

# ---------------------------------------------------------------------------
# Progress loop
# ---------------------------------------------------------------------------
$runSw    = [Diagnostics.Stopwatch]::StartNew()
$lastBytes = [long]0
$lastTime  = 0.0
$startedAt = Get-Date

try {
    while ($true) {
        Start-Sleep -Seconds 3
        try   { $snapshot = @($progress.Values | ForEach-Object { $_.Clone() }) }
        catch { continue }   # a worker registered its key mid-enumeration
        if ($snapshot.Count -eq 0) { continue }

        $bytes  = ($snapshot | ForEach-Object { $_['Bytes'] } | Measure-Object -Sum).Sum
        $files  = ($snapshot | ForEach-Object { $_['Files'] } | Measure-Object -Sum).Sum
        $errors = ($snapshot | ForEach-Object { $_['Errors'] } | Measure-Object -Sum).Sum
        $done   = @($snapshot | Where-Object { $_['Done'] }).Count

        $now      = $runSw.Elapsed.TotalSeconds
        $instMBs  = if ($now -gt $lastTime) { (($bytes - $lastBytes) / 1MB) / ($now - $lastTime) } else { 0 }
        $avgMBs   = if ($now -gt 0) { ($bytes / 1MB) / $now } else { 0 }
        $pct      = if ($targetBytes -gt 0) { [Math]::Min(100, 100.0 * $bytes / $targetBytes) } else { 0 }
        $etaSec   = if ($avgMBs -gt 0) { (($targetBytes - $bytes) / 1MB) / $avgMBs } else { 0 }
        $lastBytes = $bytes; $lastTime = $now

        $status = ('{0,6:N2}% | {1,10} | {2,8:N0} files | now {3,7:N1} MB/s | avg {4,7:N1} MB/s | ETA {5} | errors {6} | workers {7}/{8}' -f `
            $pct, (Format-FsPocBytes $bytes), $files, $instMBs, $avgMBs,
            ([TimeSpan]::FromSeconds([Math]::Max(0, $etaSec)).ToString('hh\:mm\:ss')),
            $errors, ($cfg.Threads - $done), $cfg.Threads)
        # Padded: the line is rewritten with \r, so a shorter status would
        # otherwise leave the tail of a longer one behind and corrupt the
        # numbers on screen.
        Write-Host ("`r  " + $status.PadRight(150)) -NoNewline -ForegroundColor Green

        if ($control['FatalWorker'] -ge 0) {
            Write-Host ''
            $bad = $progress["w$($control['FatalWorker'])"]
            Write-FsPocLog "Worker $($control['FatalWorker']) exceeded the error threshold. Last error: $($bad['LastError'])" 'ERROR'
        }
        if ($done -eq $cfg.Threads) { break }
    }
}
finally {
    Write-Host ''
    $control['Stop'] = $true
    foreach ($j in $jobs) {
        try { $null = $j.Shell.EndInvoke($j.Handle) } catch { Write-FsPocLog "Worker $($j.Id): $($_.Exception.Message)" 'WARN' }
        foreach ($e in $j.Shell.Streams.Error) { Write-FsPocLog "Worker $($j.Id) error: $e" 'WARN' }
        $j.Shell.Dispose()
    }
    $rsPool.Close(); $rsPool.Dispose()
}
$runSw.Stop()

# Snapshot the "after" state
if (-not $NoMonitorDb) {
    Invoke-FsPocSql -Instance $cfg.SqlInstance -Database $cfg.MonitorDb -NonQuery `
        -Query 'EXEC dbo.usp_CaptureSnapshot @RunId, @Phase, @TargetDb' `
        -Parameters @{ RunId = $RunId; Phase = 'end'; TargetDb = $cfg.DemoDb } | Out-Null
}

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
$final  = @($progress.Values)
$bytes  = ($final | ForEach-Object { $_['Bytes'] } | Measure-Object -Sum).Sum
$files  = ($final | ForEach-Object { $_['Files'] } | Measure-Object -Sum).Sum
$errors = ($final | ForEach-Object { $_['Errors'] } | Measure-Object -Sum).Sum
$sec    = $runSw.Elapsed.TotalSeconds

Write-Host ''
Write-Host '----------------------------------------------------------------' -ForegroundColor Cyan
Write-FsPocLog ("Elapsed     : {0}" -f $runSw.Elapsed.ToString('hh\:mm\:ss')) 'OK'
Write-FsPocLog ("Transferred : {0} in {1:N0} files" -f (Format-FsPocBytes $bytes), $files) 'OK'
Write-FsPocLog ("Throughput  : {0:N1} MB/s  ({1:N1} files/s)" -f (($bytes / 1MB) / $sec), ($files / $sec)) 'OK'
if ($errors -gt 0) {
    Write-FsPocLog "Errors      : $errors" 'ERROR'

    # A run that lost connections and recovered is NOT the same as a clean run,
    # and the throughput number is not comparable to one. Say so here rather
    # than leaving it to be discovered in errors.csv.
    $structural = ($final | ForEach-Object { [long]$_['Structural'] } | Measure-Object -Sum).Sum
    $transient  = ($final | ForEach-Object { [long]$_['Transient']  } | Measure-Object -Sum).Sum
    $reconnects = ($final | ForEach-Object { [long]$_['Reconnects'] } | Measure-Object -Sum).Sum
    Write-FsPocLog ("              {0} structural, {1} transient, {2} reconnect(s)" -f $structural, $transient, $reconnects) 'INFO'
    if ($reconnects -gt 0) {
        # Say how much was actually lost rather than asserting the run is
        # "short": one in-flight file per reconnect, which against 160k files is
        # usually a rounding error. Overstating this trains people to ignore it.
        Write-FsPocLog ("{0} reconnect(s): the file in flight at each was not written ({0} of {1:N0}). Everything else completed normally." -f $reconnects, $files) 'WARN'
        Write-FsPocLog 'Commit timeouts under load are the expected symptom of a saturated container disk -- check section 5 of the analysis before treating them as a fault.' 'INFO'
    }

    $allErrors = @($final | ForEach-Object { $_['ErrorList'] } | ForEach-Object { $_ })
    if ($allErrors.Count -gt 0) {
        $errCsv = Join-Path $resultsDir 'errors.csv'
        $allErrors | Export-Csv -LiteralPath $errCsv -NoTypeInformation -Encoding UTF8

        Write-Host ''
        Write-Host '--- Failures, grouped ------------------------------------------' -ForegroundColor Red
        $allErrors | Group-Object Stage, Exception, Message |
            Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object {
                $e = $_.Group[0]
                Write-Host ''
                Write-Host ("  x{0}  at stage: {1}" -f $_.Count, $e.Stage) -ForegroundColor Red
                Write-Host ("        {0}" -f $e.Exception) -ForegroundColor Yellow
                Write-Host ("        {0}" -f $e.Message) -ForegroundColor Yellow
                if ($e.Inner)    { Write-Host ("        inner: {0}" -f $e.Inner) -ForegroundColor DarkYellow }
                if ($e.PathName) { Write-Host ("        PathName()  : {0}" -f $e.PathName) -ForegroundColor DarkGray }
                if ($e.ContextLen -ge 0) { Write-Host ("        context len : {0} bytes" -f $e.ContextLen) -ForegroundColor DarkGray }
            }
        Write-Host ''
        Write-FsPocLog "Full detail for all $($allErrors.Count) failures: $errCsv" 'INFO'
        Write-FsPocLog "For a single-file step-by-step diagnosis, run: .\Test-FilestreamPath.ps1" 'INFO'
    }
}

if (-not $NoMonitorDb) {
    Invoke-FsPocSql -Instance $cfg.SqlInstance -Database $cfg.MonitorDb -NonQuery `
        -Query 'EXEC dbo.usp_EndRun @RunId, @ActualBytes, @FileCount, @Notes' `
        -Parameters @{ RunId = $RunId; ActualBytes = $bytes; FileCount = $files
                       Notes = "errors=$errors; results=$resultsDir" } | Out-Null

    & (Join-Path $ScriptDir 'Import-PocTimings.ps1') -RunId $RunId -ResultsDir $resultsDir -ConfigPath $ConfigPath
}

[pscustomobject]@{
    RunId        = $RunId
    Scenario     = $Scenario
    Bytes        = $bytes
    Files        = $files
    Seconds      = $sec
    ThroughputMBs = ($bytes / 1MB) / $sec
    Errors       = $errors
    ResultsDir   = $resultsDir
}
