/*  05-analysis.sql
    Post-run analysis. Every section is independent -- run the whole file for a
    full report, or highlight one section.

      sqlcmd -S . -E -b -i sql\05-analysis.sql -v RunId="<guid>" -y 0 -Y 40
      (omit RunId to report on the most recent completed run)
*/

/*  SQLCMD SCRIPTING VARIABLES REQUIRED BY THIS SCRIPT
      RunId            default: (blank = most recent run)
      TopWaits         default: 25
    These are intentionally NOT declared with :setvar. A :setvar inside a script
    runs AFTER sqlcmd applies -v, so it silently overrides anything passed on
    the command line -- which would make every -v in this kit a no-op.

    The PowerShell scripts always supply them. To run this file by hand, either
    pass -v for each one, or run sql\00-set-variables.cmd first (sqlcmd falls
    back to environment variables for undefined scripting variables).
*/


USE FsPocMonitor;
SET NOCOUNT ON;
GO

-- '', 'NONE' and 'LATEST' all mean "report on the most recent run". NONE is
-- the sentinel used when the value is supplied through the environment, where
-- an empty string cannot survive.
DECLARE @RunIdText nvarchar(50) = N'$(RunId)';
DECLARE @RunId uniqueidentifier =
    CASE WHEN @RunIdText IN (N'', N'NONE', N'LATEST') THEN NULL
         ELSE TRY_CONVERT(uniqueidentifier, @RunIdText) END;

IF @RunId IS NULL
    SELECT TOP (1) @RunId = RunId FROM dbo.PocRun ORDER BY StartedAtUtc DESC;

IF @RunId IS NULL
BEGIN
    RAISERROR('No runs found in FsPocMonitor.dbo.PocRun.', 16, 1);
    RETURN;
END

DECLARE @sql nvarchar(max);
PRINT '';
PRINT '================================================================';
PRINT ' FILESTREAM POC ANALYSIS -- RunId ' + CONVERT(char(36), @RunId);
PRINT '================================================================';

/* ============================ 1. RUN SUMMARY ============================ */
PRINT '';
PRINT '--- 1. Run summary -------------------------------------------------';
SELECT
    RunName, Scenario, TargetDb, SizeProfile,
    Threads, ChunkSizeKB, ProcmonActive,
    StartedAtUtc, EndedAtUtc,
    ElapsedSec  = DATEDIFF(second, StartedAtUtc, EndedAtUtc),
    FileCount,
    TotalGB     = ActualBytes / 1073741824.0,
    ThroughputMBs = CASE WHEN DATEDIFF(second, StartedAtUtc, EndedAtUtc) > 0
                         THEN (ActualBytes / 1048576.0) / DATEDIFF(second, StartedAtUtc, EndedAtUtc) END,
    FilesPerSec   = CASE WHEN DATEDIFF(second, StartedAtUtc, EndedAtUtc) > 0
                         THEN FileCount * 1.0 / DATEDIFF(second, StartedAtUtc, EndedAtUtc) END
FROM dbo.PocRun
WHERE RunId = @RunId;

/* ====================== 2. TOP WAITS (NON-BENIGN) ======================= */
PRINT '';
PRINT '--- 2. Top waits during the run (benign filtered) -------------------';
SELECT TOP ($(TopWaits))
    d.wait_type,
    WaitCount      = d.WaitCount,
    WaitTimeSec    = CONVERT(decimal(18,1), d.WaitTimeMs / 1000.0),
    ResourceSec    = CONVERT(decimal(18,1), d.ResourceTimeMs / 1000.0),
    SignalSec      = CONVERT(decimal(18,1), d.SignalTimeMs / 1000.0),
    AvgWaitMs      = CONVERT(decimal(18,2), d.AvgWaitMs),
    PctOfWaitTime  = CONVERT(decimal(5,2),
                       100.0 * d.WaitTimeMs / NULLIF(SUM(d.WaitTimeMs) OVER (), 0)),
    Category       = CASE
        WHEN d.wait_type LIKE 'FILESTREAM%' OR d.wait_type LIKE 'FS[_]%'
          OR d.wait_type LIKE 'FSA%' OR d.wait_type LIKE 'FSTR%'
             THEN '** FILESTREAM **'
        WHEN d.wait_type LIKE 'PREEMPTIVE_OS_%'
             THEN '** WIN32 (external) **'
        WHEN d.wait_type IN ('WRITELOG','LOGBUFFER','LOGMGR_FLUSH','LOGMGR_RESERVE_APPEND')
             THEN 'Log'
        WHEN d.wait_type LIKE 'PAGEIOLATCH%' OR d.wait_type LIKE 'IO_%'
             OR d.wait_type = 'ASYNC_IO_COMPLETION' THEN 'Data I/O'
        WHEN d.wait_type LIKE 'LCK[_]%' THEN 'Locking'
        WHEN d.wait_type LIKE 'PAGELATCH%' OR d.wait_type LIKE 'LATCH[_]%' THEN 'Latch'
        WHEN d.wait_type LIKE 'CXPACKET%' OR d.wait_type LIKE 'CXCONSUMER%' THEN 'Parallelism'
        WHEN d.wait_type IN ('SOS_SCHEDULER_YIELD','THREADPOOL') THEN 'CPU/Scheduler'
        WHEN d.wait_type LIKE 'RESOURCE_SEMAPHORE%' OR d.wait_type LIKE 'MEMORY%' THEN 'Memory'
        WHEN d.wait_type LIKE 'ASYNC_NETWORK%' OR d.wait_type LIKE 'NETWORK%' THEN 'Network/Client'
        ELSE 'Other' END
FROM dbo.vw_WaitDelta d
WHERE d.RunId = @RunId
  AND NOT EXISTS (SELECT 1 FROM dbo.BenignWait b WHERE b.wait_type = d.wait_type)
ORDER BY d.WaitTimeMs DESC;

/* ============ 3. FILESTREAM + WIN32 WAITS, UNFILTERED ================== */
PRINT '';
PRINT '--- 3. FILESTREAM / Win32 waits (shown even if small or "benign") ---';
PRINT '    FSAGENT climbing here is real signal, not idle noise.';
SELECT
    d.wait_type,
    WaitCount   = d.WaitCount,
    WaitTimeSec = CONVERT(decimal(18,1), d.WaitTimeMs / 1000.0),
    AvgWaitMs   = CONVERT(decimal(18,2), d.AvgWaitMs),
    MaxWaitMs   = d.MaxWaitMs,
    -- Ops per file is what makes these actionable: a count of 4x the file
    -- count means four of that Win32 call per file written.
    OpsPerFile = CONVERT(decimal(18,2), d.WaitCount * 1.0 /
                   NULLIF((SELECT FileCount FROM dbo.PocRun WHERE RunId = @RunId), 0)),
    Meaning = CASE d.wait_type
        WHEN 'FILESTREAM_WORKITEM_QUEUE' THEN 'FILESTREAM internal work queue -- the agent serialising file operations'
        WHEN 'FILESTREAM_CACHE'         THEN 'FILESTREAM metadata cache'
        WHEN 'PREEMPTIVE_OS_RSFXDEVICEOPS' THEN 'Calls into the RsFx FILESTREAM filter driver'
        WHEN 'PREEMPTIVE_OS_FINDFILE'   THEN 'Directory lookup in the container -- grows with directory size'
        WHEN 'PREEMPTIVE_OS_GETFILESIZE' THEN 'Win32 GetFileSize on a container file'
        WHEN 'PREEMPTIVE_OS_DEVICEOPS'  THEN 'Volume/device level Win32 calls'
        WHEN 'FSAGENT'                  THEN 'FILESTREAM agent throttle -- contention on the FS agent'
        WHEN 'FS_FC_RWLOCK'             THEN 'FILESTREAM garbage collector / file control lock'
        WHEN 'FS_GARBAGE_COLLECTION_SHUTDOWN' THEN 'Waiting on GC to drain'
        WHEN 'FS_HEADER_RWLOCK'         THEN 'FILESTREAM header lock -- container metadata contention'
        WHEN 'FS_LOGTRUNC_RWLOCK'       THEN 'FILESTREAM log truncation lock'
        WHEN 'FSA_FORCE_OWN_XACT'       THEN 'FILESTREAM transaction ownership handoff (Win32 open)'
        WHEN 'FSTR_CONFIG_MUTEX'        THEN 'FILESTREAM config change serialization'
        WHEN 'FSTR_CONFIG_RWLOCK'       THEN 'FILESTREAM config read lock'
        WHEN 'PREEMPTIVE_OS_WRITEFILE'  THEN 'Win32 WriteFile on the container -- raw NTFS write cost'
        WHEN 'PREEMPTIVE_OS_CREATEFILE' THEN 'Win32 CreateFile -- new container file; NTFS metadata cost'
        WHEN 'PREEMPTIVE_OS_FILEOPS'    THEN 'Misc Win32 file ops on the container'
        WHEN 'PREEMPTIVE_OS_FLUSHFILEBUFFERS' THEN 'FlushFileBuffers -- durability flush to disk'
        WHEN 'PREEMPTIVE_OS_CLOSEHANDLE'THEN 'Win32 CloseHandle -- often hides flush cost'
        WHEN 'PREEMPTIVE_OS_DELETEFILE' THEN 'Container file delete -- FILESTREAM garbage collection'
        WHEN 'PREEMPTIVE_OS_GETFILEATTRIBUTES' THEN 'Directory/attribute probes -- worse with 8.3 names on'
        ELSE '' END
FROM dbo.vw_WaitDelta d
WHERE d.RunId = @RunId
  AND (d.wait_type LIKE 'FILESTREAM%' OR d.wait_type LIKE 'FS[_]%'
       OR d.wait_type LIKE 'FSA%' OR d.wait_type LIKE 'FSTR%'
       OR d.wait_type LIKE 'PREEMPTIVE_OS_%')
ORDER BY d.WaitTimeMs DESC;

/* ======================= 4. FILE-LEVEL I/O DELTA ======================== */
PRINT '';
PRINT '--- 4. Per-file I/O (sys.dm_io_virtual_file_stats delta) ------------';
PRINT '    Win32 streaming writes do NOT appear here -- see the Procmon CSV.';
SELECT
    DatabaseName, FileType, LogicalName,
    Reads, ReadMB      = CONVERT(decimal(18,1), ReadMB),
    AvgReadMs          = CONVERT(decimal(18,2), AvgReadMs),
    Writes, WriteMB    = CONVERT(decimal(18,1), WriteMB),
    AvgWriteMs         = CONVERT(decimal(18,2), AvgWriteMs),
    WriteMBps          = CONVERT(decimal(18,1), WriteMB / NULLIF(ElapsedSec, 0)),
    GrowthMB           = CONVERT(decimal(18,1), GrowthMB),
    PhysicalName
FROM dbo.vw_FileStatsDelta
WHERE RunId = @RunId
ORDER BY (WriteMB + ReadMB) DESC;

/* =================== 5. CLIENT-SIDE LATENCY PERCENTILES ================= */
PRINT '';
PRINT '--- 5. Per-file latency by size bucket (client-measured) ------------';
WITH t AS (
    SELECT Bucket, SizeBytes, OpenMs, WriteMs, CommitMs, TotalMs
    FROM dbo.IngestTiming WHERE RunId = @RunId
)
SELECT DISTINCT
    Bucket,
    Files       = COUNT(*)      OVER (PARTITION BY Bucket),
    TotalGB     = CONVERT(decimal(18,2), SUM(SizeBytes) OVER (PARTITION BY Bucket) / 1073741824.0),
    AvgSizeMB   = CONVERT(decimal(18,2), AVG(SizeBytes * 1.0) OVER (PARTITION BY Bucket) / 1048576.0),
    AvgOpenMs   = CONVERT(decimal(18,2), AVG(OpenMs)   OVER (PARTITION BY Bucket)),
    AvgWriteMs  = CONVERT(decimal(18,2), AVG(WriteMs)  OVER (PARTITION BY Bucket)),
    AvgCommitMs = CONVERT(decimal(18,2), AVG(CommitMs) OVER (PARTITION BY Bucket)),
    P50Ms       = CONVERT(decimal(18,2), PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY TotalMs) OVER (PARTITION BY Bucket)),
    P95Ms       = CONVERT(decimal(18,2), PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY TotalMs) OVER (PARTITION BY Bucket)),
    P99Ms       = CONVERT(decimal(18,2), PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY TotalMs) OVER (PARTITION BY Bucket)),
    MaxMs       = CONVERT(decimal(18,2), MAX(TotalMs) OVER (PARTITION BY Bucket)),
    -- Effective per-file throughput, the number that actually matters
    AvgMBps     = CONVERT(decimal(18,1),
                    (SUM(SizeBytes) OVER (PARTITION BY Bucket) / 1048576.0)
                    / NULLIF(SUM(TotalMs) OVER (PARTITION BY Bucket) / 1000.0, 0))
FROM t
ORDER BY Bucket;

/* =============== 6. WAIT TIMELINE FROM THE ACTIVITY SAMPLER ============= */
PRINT '';
PRINT '--- 6. Wait shape over time (10s buckets, top waits per bucket) -----';
WITH s AS (
    SELECT
        Bucket10s = DATEADD(second, (DATEDIFF(second, MIN(SampledAtUtc) OVER (), SampledAtUtc) / 10) * 10,
                            MIN(SampledAtUtc) OVER ()),
        wait_type = ISNULL(wait_type, '<running>')
    FROM dbo.ActivitySample
    WHERE RunId = @RunId
)
SELECT
    Bucket10s,
    wait_type,
    Samples = COUNT(*),
    PctOfBucket = CONVERT(decimal(5,1), 100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY Bucket10s))
FROM s
GROUP BY Bucket10s, wait_type
HAVING COUNT(*) > 1
ORDER BY Bucket10s, Samples DESC;

/* =================== 7. CONTAINER SHAPE ON DISK ========================= */
PRINT '';
PRINT '--- 7. FILESTREAM container: rows, bytes, and directory fan-out -----';
SET @sql = N'
USE [' + (SELECT TargetDb FROM dbo.PocRun WHERE RunId = @RunId) + N'];
SELECT
    Bucket,
    Files     = COUNT(*),
    TotalGB   = CONVERT(decimal(18,2), SUM(SizeBytes) / 1073741824.0),
    MinMB     = CONVERT(decimal(18,3), MIN(SizeBytes) / 1048576.0),
    AvgMB     = CONVERT(decimal(18,3), AVG(SizeBytes * 1.0) / 1048576.0),
    MaxMB     = CONVERT(decimal(18,3), MAX(SizeBytes) / 1048576.0)
FROM dbo.FileStore
WHERE RunId = ''' + CONVERT(char(36), @RunId) + N'''
GROUP BY Bucket WITH ROLLUP
ORDER BY Bucket;';
EXEC sys.sp_executesql @sql;

/* ==================== 7b. FILETABLE CONTENTS ============================ */
PRINT '';
PRINT '--- 7b. FileTable contents (non-transacted share path) --------------';
PRINT '    FileTable has a fixed schema with nowhere to record RunId, so this';
PRINT '    is the whole table rather than one run. Per-bucket and per-run';
PRINT '    detail for FileTable comes from the client timings in section 5.';
SET @sql = N'
USE [' + (SELECT TargetDb FROM dbo.PocRun WHERE RunId = @RunId) + N'];
IF OBJECT_ID(''dbo.FileStoreFT'') IS NULL
    SELECT FileTable = ''dbo.FileStoreFT does not exist -- run sql\02-create-database.sql'';
ELSE
    EXEC dbo.usp_GetFileTableSummary;';
EXEC sys.sp_executesql @sql;

/* ==================== 7c. AZURE BLOB CATALOG =========================== */
PRINT '';
PRINT '--- 7c. Azure Blob catalog (SQL Server as catalog, blob as store) ---';
PRINT '    The bytes are not in this database. These rows point at them, and';
PRINT '    a database backup captures the pointers, not the objects.';
SET @sql = N'
USE [' + (SELECT TargetDb FROM dbo.PocRun WHERE RunId = @RunId) + N'];
IF OBJECT_ID(''dbo.BlobUrlStore'') IS NULL
    SELECT BlobCatalog = ''dbo.BlobUrlStore does not exist -- run sql\02-create-database.sql'';
ELSE
    EXEC dbo.usp_GetBlobUrlSummary @RunId = ''' + CONVERT(char(36), @RunId) + N''';';
EXEC sys.sp_executesql @sql;

/* ================= 8. A/B: WRITE PATHS COMPARED ======================== */
PRINT '';
PRINT '--- 8. Comparison across runs and write paths -----------------------';
PRINT '    Filestream and Blob are transactional; FileTable is not, so it has';
PRINT '    no commit to pay for. Read the gap as the cost of that guarantee,';
PRINT '    not as a like-for-like win, unless the run used -FileTableFlush.';
PRINT '';
PRINT '    AzureBlob is bound by the network and the storage account, not by';
PRINT '    the container disk, and its bytes are outside the database backup.';
PRINT '    Compare it on cost and architecture, not on this column alone.';
SELECT
    r.Scenario,
    r.SizeProfile,
    r.Threads,
    r.ChunkSizeKB,
    Files         = r.FileCount,
    TotalGB       = CONVERT(decimal(18,2), r.ActualBytes / 1073741824.0),
    ElapsedSec    = DATEDIFF(second, r.StartedAtUtc, r.EndedAtUtc),
    ThroughputMBs = CONVERT(decimal(18,1),
                      (r.ActualBytes / 1048576.0)
                      / NULLIF(DATEDIFF(second, r.StartedAtUtc, r.EndedAtUtc), 0)),
    P95Ms         = (SELECT CONVERT(decimal(18,2), MAX(p)) FROM (
                        SELECT DISTINCT p = PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY t.TotalMs) OVER ()
                        FROM dbo.IngestTiming t WHERE t.RunId = r.RunId) x),
    TopWait       = (SELECT TOP 1 d.wait_type FROM dbo.vw_WaitDelta d
                     WHERE d.RunId = r.RunId
                       AND NOT EXISTS (SELECT 1 FROM dbo.BenignWait b WHERE b.wait_type = d.wait_type)
                     ORDER BY d.WaitTimeMs DESC),
    RunName       = r.RunName,
    r.RunId
FROM dbo.PocRun r
WHERE r.EndedAtUtc IS NOT NULL
ORDER BY r.SizeProfile, r.Scenario, r.StartedAtUtc DESC;
GO
