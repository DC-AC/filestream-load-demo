/*  03-monitor-db.sql
    Creates FsPocMonitor: a separate database holding run metadata, wait-stat
    and file-stat snapshots, a continuous activity sampler, and the per-file
    client-side timings imported from the ingest engine.

    Kept separate from FsPocDemo on purpose -- you will drop and rebuild the
    demo DB between runs and you want the measurements to survive that.

      sqlcmd -S . -E -b -i sql\03-monitor-db.sql
*/

/*  SQLCMD SCRIPTING VARIABLES REQUIRED BY THIS SCRIPT
      MonitorDb        default: FsPocMonitor
      MonitorDataPath  default: F:\SQLData
      MonitorLogPath   default: H:\SQLLog
    These are intentionally NOT declared with :setvar. A :setvar inside a script
    runs AFTER sqlcmd applies -v, so it silently overrides anything passed on
    the command line -- which would make every -v in this kit a no-op.

    The PowerShell scripts always supply them. To run this file by hand, either
    pass -v for each one, or run sql\00-set-variables.cmd first (sqlcmd falls
    back to environment variables for undefined scripting variables).
*/


SET NOCOUNT ON;
GO

IF DB_ID(N'$(MonitorDb)') IS NULL
BEGIN
    DECLARE @sql nvarchar(max) = N'
    CREATE DATABASE [$(MonitorDb)]
    ON PRIMARY (NAME = N''$(MonitorDb)_data'', FILENAME = N''$(MonitorDataPath)\$(MonitorDb)_data.mdf'', SIZE = 512MB, FILEGROWTH = 256MB)
    LOG ON      (NAME = N''$(MonitorDb)_log'',  FILENAME = N''$(MonitorLogPath)\$(MonitorDb)_log.ldf'',  SIZE = 256MB, FILEGROWTH = 128MB);';
    EXEC sys.sp_executesql @sql;
    EXEC(N'ALTER DATABASE [$(MonitorDb)] SET RECOVERY SIMPLE;');
    PRINT 'Created $(MonitorDb)';
END
ELSE
    PRINT '$(MonitorDb) already exists -- objects will be created/altered in place.';
GO

USE [$(MonitorDb)];
GO

/* =========================================================================
   Run metadata
   ========================================================================= */
IF OBJECT_ID('dbo.PocRun') IS NULL
CREATE TABLE dbo.PocRun
(
    RunId         uniqueidentifier NOT NULL CONSTRAINT PK_PocRun PRIMARY KEY,
    RunName       nvarchar(200)    NOT NULL,
    Scenario      nvarchar(100)    NOT NULL,   -- Filestream | Blob | FilestreamRead | ...
    TargetDb      sysname          NOT NULL,
    StartedAtUtc  datetime2(3)     NOT NULL,
    EndedAtUtc    datetime2(3)     NULL,
    Threads       int              NULL,
    ChunkSizeKB   int              NULL,
    SizeProfile   nvarchar(50)     NULL,
    TargetBytes   bigint           NULL,
    ActualBytes   bigint           NULL,
    FileCount     bigint           NULL,
    ProcmonActive bit              NOT NULL CONSTRAINT DF_PocRun_Procmon DEFAULT 0,
    Notes         nvarchar(max)    NULL,
    ParamsJson    nvarchar(max)    NULL
);
GO

/* =========================================================================
   Snapshot tables. Phase is free-form but the analysis views expect the
   pairing 'start' -> 'end' (procmon windows add 'pm-start'/'pm-end').
   ========================================================================= */
IF OBJECT_ID('dbo.WaitSnapshot') IS NULL
CREATE TABLE dbo.WaitSnapshot
(
    SnapshotId          bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_WaitSnapshot PRIMARY KEY,
    RunId               uniqueidentifier NOT NULL,
    Phase               varchar(20)      NOT NULL,
    CapturedAtUtc       datetime2(3)     NOT NULL,
    wait_type           nvarchar(60)     NOT NULL,
    waiting_tasks_count bigint           NOT NULL,
    wait_time_ms        bigint           NOT NULL,
    max_wait_time_ms    bigint           NOT NULL,
    signal_wait_time_ms bigint           NOT NULL,
    INDEX IX_WaitSnapshot_Run NONCLUSTERED (RunId, Phase, wait_type)
);
GO

IF OBJECT_ID('dbo.FileStatsSnapshot') IS NULL
CREATE TABLE dbo.FileStatsSnapshot
(
    SnapshotId       bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_FileStatsSnapshot PRIMARY KEY,
    RunId            uniqueidentifier NOT NULL,
    Phase            varchar(20)      NOT NULL,
    CapturedAtUtc    datetime2(3)     NOT NULL,
    DatabaseName     sysname          NOT NULL,
    FileId           int              NOT NULL,
    FileType         varchar(20)      NOT NULL,
    LogicalName      sysname          NULL,
    PhysicalName     nvarchar(520)    NULL,
    num_of_reads     bigint           NOT NULL,
    num_of_bytes_read bigint          NOT NULL,
    io_stall_read_ms bigint           NOT NULL,
    num_of_writes    bigint           NOT NULL,
    num_of_bytes_written bigint       NOT NULL,
    io_stall_write_ms bigint          NOT NULL,
    size_on_disk_bytes bigint         NOT NULL,
    INDEX IX_FileStatsSnapshot_Run NONCLUSTERED (RunId, Phase, DatabaseName, FileId)
);
GO

IF OBJECT_ID('dbo.PerfCounterSnapshot') IS NULL
CREATE TABLE dbo.PerfCounterSnapshot
(
    SnapshotId    bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_PerfCounterSnapshot PRIMARY KEY,
    RunId         uniqueidentifier NOT NULL,
    Phase         varchar(20)      NOT NULL,
    CapturedAtUtc datetime2(3)     NOT NULL,
    object_name   nvarchar(128)    NOT NULL,
    counter_name  nvarchar(128)    NOT NULL,
    instance_name nvarchar(128)    NULL,
    cntr_value    bigint           NOT NULL,
    cntr_type     int              NOT NULL,
    INDEX IX_PerfCounterSnapshot_Run NONCLUSTERED (RunId, Phase)
);
GO

/* Continuous sampler output -- what was actually waiting, moment to moment.
   Aggregate wait stats tell you the totals; this tells you the shape. */
IF OBJECT_ID('dbo.ActivitySample') IS NULL
CREATE TABLE dbo.ActivitySample
(
    SampleId       bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ActivitySample PRIMARY KEY,
    RunId          uniqueidentifier NOT NULL,
    SampledAtUtc   datetime2(3)     NOT NULL,
    session_id     int              NULL,
    request_id     int              NULL,
    wait_type      nvarchar(60)     NULL,
    wait_duration_ms bigint         NULL,
    blocking_session_id int         NULL,
    resource_description nvarchar(500) NULL,
    command        nvarchar(64)     NULL,
    status         nvarchar(60)     NULL,
    INDEX IX_ActivitySample_Run NONCLUSTERED (RunId, SampledAtUtc)
);
GO

/* FILESTREAM non-transacted / Win32 handle activity (populated when the
   file-share access path is exercised, e.g. FileTable or NTA reads). */
IF OBJECT_ID('dbo.FileStreamHandleSample') IS NULL
CREATE TABLE dbo.FileStreamHandleSample
(
    SampleId      bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_FsHandleSample PRIMARY KEY,
    RunId         uniqueidentifier NOT NULL,
    SampledAtUtc  datetime2(3)     NOT NULL,
    HandleCount   int              NOT NULL,
    RequestCount  int              NOT NULL
);
GO

/* Per-file client-side timings, bulk-loaded from the ingest engine's CSVs.
   This is the ground truth for latency percentiles -- DMVs cannot give you
   per-operation latency for the Win32 streaming path, because those writes
   never go through SQL Server's I/O stack at all. */
IF OBJECT_ID('dbo.IngestTiming') IS NULL
CREATE TABLE dbo.IngestTiming
(
    TimingId      bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_IngestTiming PRIMARY KEY,
    RunId         uniqueidentifier NOT NULL,
    WorkerId      int              NOT NULL,
    Seq           bigint           NOT NULL,
    Bucket        varchar(20)      NOT NULL,
    FileName      nvarchar(400)    NOT NULL,
    SizeBytes     bigint           NOT NULL,
    StartedAtUtc  datetime2(3)     NOT NULL,
    OpenMs        float            NOT NULL,   -- BEGIN TRAN + insert + PathName round trip
    WriteMs       float            NOT NULL,   -- SqlFileStream / varbinary payload transfer
    CommitMs      float            NOT NULL,   -- COMMIT
    TotalMs       float            NOT NULL,
    INDEX IX_IngestTiming_Run NONCLUSTERED (RunId, Bucket) INCLUDE (SizeBytes, TotalMs)
);
GO

/* =========================================================================
   Procedures
   ========================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_StartRun
    @RunId       uniqueidentifier,
    @RunName     nvarchar(200),
    @Scenario    nvarchar(100),
    @TargetDb    sysname,
    @Threads     int           = NULL,
    @ChunkSizeKB int           = NULL,
    @SizeProfile nvarchar(50)  = NULL,
    @TargetBytes bigint        = NULL,
    @ProcmonActive bit         = 0,
    @ParamsJson  nvarchar(max) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT dbo.PocRun (RunId, RunName, Scenario, TargetDb, StartedAtUtc, Threads,
                       ChunkSizeKB, SizeProfile, TargetBytes, ProcmonActive, ParamsJson)
    VALUES (@RunId, @RunName, @Scenario, @TargetDb, SYSUTCDATETIME(), @Threads,
            @ChunkSizeKB, @SizeProfile, @TargetBytes, @ProcmonActive, @ParamsJson);
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_EndRun
    @RunId       uniqueidentifier,
    @ActualBytes bigint = NULL,
    @FileCount   bigint = NULL,
    @Notes       nvarchar(max) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.PocRun
       SET EndedAtUtc  = SYSUTCDATETIME(),
           ActualBytes = COALESCE(@ActualBytes, ActualBytes),
           FileCount   = COALESCE(@FileCount, FileCount),
           Notes       = COALESCE(@Notes, Notes)
     WHERE RunId = @RunId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_CaptureSnapshot
    @RunId    uniqueidentifier,
    @Phase    varchar(20),
    @TargetDb sysname = N'FsPocDemo'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now datetime2(3) = SYSUTCDATETIME();

    /* --- Wait stats. Capture everything; filter at analysis time so you can
           change your mind about what counts as benign without re-running. --- */
    INSERT dbo.WaitSnapshot (RunId, Phase, CapturedAtUtc, wait_type, waiting_tasks_count,
                             wait_time_ms, max_wait_time_ms, signal_wait_time_ms)
    SELECT @RunId, @Phase, @now, wait_type, waiting_tasks_count,
           wait_time_ms, max_wait_time_ms, signal_wait_time_ms
    FROM sys.dm_os_wait_stats;

    /* --- Virtual file stats for the target DB AND tempdb.
           Note: FILESTREAM containers report as file type 2 here, but SQL
           Server only sees the I/O it performs itself. Win32 streaming writes
           issued by the client bypass this entirely -- which is exactly why
           Procmon is in this kit. --- */
    DECLARE @dbid int = DB_ID(@TargetDb);
    INSERT dbo.FileStatsSnapshot (RunId, Phase, CapturedAtUtc, DatabaseName, FileId, FileType,
                                  LogicalName, PhysicalName, num_of_reads, num_of_bytes_read,
                                  io_stall_read_ms, num_of_writes, num_of_bytes_written,
                                  io_stall_write_ms, size_on_disk_bytes)
    SELECT @RunId, @Phase, @now, DB_NAME(vfs.database_id), vfs.file_id,
           CASE mf.type WHEN 0 THEN 'ROWS' WHEN 1 THEN 'LOG' WHEN 2 THEN 'FILESTREAM' ELSE 'OTHER' END,
           mf.name, mf.physical_name,
           vfs.num_of_reads, vfs.num_of_bytes_read, vfs.io_stall_read_ms,
           vfs.num_of_writes, vfs.num_of_bytes_written, vfs.io_stall_write_ms,
           vfs.size_on_disk_bytes
    FROM sys.dm_io_virtual_file_stats(NULL, NULL) vfs
    JOIN sys.master_files mf
      ON mf.database_id = vfs.database_id AND mf.file_id = vfs.file_id
    WHERE vfs.database_id IN (@dbid, 2);

    /* --- A focused slice of perf counters. --- */
    INSERT dbo.PerfCounterSnapshot (RunId, Phase, CapturedAtUtc, object_name, counter_name,
                                    instance_name, cntr_value, cntr_type)
    SELECT @RunId, @Phase, @now, RTRIM(object_name), RTRIM(counter_name),
           RTRIM(instance_name), cntr_value, cntr_type
    FROM sys.dm_os_performance_counters
    WHERE (RTRIM(counter_name) IN (
              'Log Bytes Flushed/sec','Log Flushes/sec','Log Flush Wait Time','Log Flush Waits/sec',
              'Transactions/sec','Write Transactions/sec','Checkpoint pages/sec','Background writer pages/sec',
              'Page life expectancy','Lazy writes/sec','Buffer cache hit ratio','Free Memory (KB)',
              'Target Server Memory (KB)','Total Server Memory (KB)','Batch Requests/sec',
              'Full Scans/sec','Latch Waits/sec','Total Latch Wait Time (ms)')
          )
       OR RTRIM(object_name) LIKE '%FileTable%';
END
GO

/* Single sampler tick. Called on a loop by the PowerShell sampler runspace so
   the sampling cost lives in a client thread, not in a SQL Agent job. */
CREATE OR ALTER PROCEDURE dbo.usp_SampleActivity
    @RunId uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now datetime2(3) = SYSUTCDATETIME();

    INSERT dbo.ActivitySample (RunId, SampledAtUtc, session_id, request_id, wait_type,
                               wait_duration_ms, blocking_session_id, resource_description,
                               command, status)
    SELECT @RunId, @now, r.session_id, r.request_id,
           COALESCE(wt.wait_type, r.wait_type),
           COALESCE(wt.wait_duration_ms, r.wait_time),
           COALESCE(wt.blocking_session_id, r.blocking_session_id),
           LEFT(wt.resource_description, 500), r.command, r.status
    FROM sys.dm_exec_requests r
    LEFT JOIN sys.dm_os_waiting_tasks wt ON wt.session_id = r.session_id
    WHERE r.session_id <> @@SPID
      AND r.session_id > 50;

    INSERT dbo.FileStreamHandleSample (RunId, SampledAtUtc, HandleCount, RequestCount)
    SELECT @RunId, @now,
           (SELECT COUNT(*) FROM sys.dm_filestream_non_transacted_handles),
           (SELECT COUNT(*) FROM sys.dm_filestream_file_io_requests);
END
GO

/* =========================================================================
   Analysis views -- deltas between the 'start' and 'end' snapshots.
   ========================================================================= */
CREATE OR ALTER VIEW dbo.vw_WaitDelta
AS
SELECT
    r.RunId,
    r.RunName,
    r.Scenario,
    s.wait_type,
    WaitCount     = e.waiting_tasks_count - s.waiting_tasks_count,
    WaitTimeMs    = e.wait_time_ms        - s.wait_time_ms,
    SignalTimeMs  = e.signal_wait_time_ms - s.signal_wait_time_ms,
    ResourceTimeMs= (e.wait_time_ms - s.wait_time_ms) - (e.signal_wait_time_ms - s.signal_wait_time_ms),
    MaxWaitMs     = e.max_wait_time_ms,
    AvgWaitMs     = CASE WHEN e.waiting_tasks_count - s.waiting_tasks_count > 0
                         THEN (e.wait_time_ms - s.wait_time_ms) * 1.0
                              / (e.waiting_tasks_count - s.waiting_tasks_count) END,
    ElapsedSec    = DATEDIFF(second, s.CapturedAtUtc, e.CapturedAtUtc)
FROM dbo.PocRun r
JOIN dbo.WaitSnapshot s ON s.RunId = r.RunId AND s.Phase = 'start'
JOIN dbo.WaitSnapshot e ON e.RunId = r.RunId AND e.Phase = 'end' AND e.wait_type = s.wait_type
WHERE e.wait_time_ms - s.wait_time_ms > 0;
GO

CREATE OR ALTER VIEW dbo.vw_FileStatsDelta
AS
SELECT
    r.RunId,
    r.RunName,
    r.Scenario,
    s.DatabaseName,
    s.FileType,
    s.LogicalName,
    s.PhysicalName,
    Reads         = e.num_of_reads  - s.num_of_reads,
    ReadMB        = (e.num_of_bytes_read - s.num_of_bytes_read) / 1048576.0,
    ReadStallMs   = e.io_stall_read_ms - s.io_stall_read_ms,
    AvgReadMs     = CASE WHEN e.num_of_reads - s.num_of_reads > 0
                         THEN (e.io_stall_read_ms - s.io_stall_read_ms) * 1.0
                              / (e.num_of_reads - s.num_of_reads) END,
    Writes        = e.num_of_writes - s.num_of_writes,
    WriteMB       = (e.num_of_bytes_written - s.num_of_bytes_written) / 1048576.0,
    WriteStallMs  = e.io_stall_write_ms - s.io_stall_write_ms,
    AvgWriteMs    = CASE WHEN e.num_of_writes - s.num_of_writes > 0
                         THEN (e.io_stall_write_ms - s.io_stall_write_ms) * 1.0
                              / (e.num_of_writes - s.num_of_writes) END,
    GrowthMB      = (e.size_on_disk_bytes - s.size_on_disk_bytes) / 1048576.0,
    ElapsedSec    = DATEDIFF(second, s.CapturedAtUtc, e.CapturedAtUtc)
FROM dbo.PocRun r
JOIN dbo.FileStatsSnapshot s ON s.RunId = r.RunId AND s.Phase = 'start'
JOIN dbo.FileStatsSnapshot e ON e.RunId = r.RunId AND e.Phase = 'end'
                            AND e.DatabaseName = s.DatabaseName AND e.FileId = s.FileId;
GO

/* Waits that are almost always noise in a throughput test. Kept as a table so
   you can add to it without editing views. */
IF OBJECT_ID('dbo.BenignWait') IS NULL
BEGIN
    CREATE TABLE dbo.BenignWait (wait_type nvarchar(60) NOT NULL CONSTRAINT PK_BenignWait PRIMARY KEY);
    INSERT dbo.BenignWait (wait_type) VALUES
        ('BROKER_EVENTHANDLER'),('BROKER_RECEIVE_WAITFOR'),('BROKER_TASK_STOP'),
        ('BROKER_TO_FLUSH'),('BROKER_TRANSMITTER'),('CHECKPOINT_QUEUE'),
        ('CHKPT'),('CLR_AUTO_EVENT'),('CLR_MANUAL_EVENT'),('CLR_SEMAPHORE'),
        ('DBMIRROR_DBM_EVENT'),('DBMIRROR_EVENTS_QUEUE'),('DBMIRROR_WORKER_QUEUE'),
        ('DBMIRRORING_CMD'),('DIRTY_PAGE_POLL'),('DISPATCHER_QUEUE_SEMAPHORE'),
        ('EXECSYNC'),('FSAGENT'),('FT_IFTS_SCHEDULER_IDLE_WAIT'),('FT_IFTSHC_MUTEX'),
        ('HADR_CLUSAPI_CALL'),('HADR_FILESTREAM_IOMGR_IOCOMPLETION'),('HADR_LOGCAPTURE_WAIT'),
        ('HADR_NOTIFICATION_DEQUEUE'),('HADR_TIMER_TASK'),('HADR_WORK_QUEUE'),
        ('KSOURCE_WAKEUP'),('LAZYWRITER_SLEEP'),('LOGMGR_QUEUE'),('MEMORY_ALLOCATION_EXT'),
        ('ONDEMAND_TASK_QUEUE'),('PARALLEL_REDO_DRAIN_WORKER'),('PARALLEL_REDO_LOG_CACHE'),
        ('PARALLEL_REDO_TRAN_LIST'),('PARALLEL_REDO_WORKER_SYNC'),('PARALLEL_REDO_WORKER_WAIT_WORK'),
        ('PREEMPTIVE_XE_GETTARGETSTATE'),('PWAIT_ALL_COMPONENTS_INITIALIZED'),
        ('PWAIT_DIRECTLOGCONSUMER_GETNEXT'),('QDS_PERSIST_TASK_MAIN_LOOP_SLEEP'),
        ('QDS_ASYNC_QUEUE'),('QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP'),
        ('QDS_SHUTDOWN_QUEUE'),('REDO_THREAD_PENDING_WORK'),('REQUEST_FOR_DEADLOCK_SEARCH'),
        ('RESOURCE_QUEUE'),('SERVER_IDLE_CHECK'),('SLEEP_BPOOL_FLUSH'),('SLEEP_DBSTARTUP'),
        ('SLEEP_DCOMSTARTUP'),('SLEEP_MASTERDBREADY'),('SLEEP_MASTERMDREADY'),
        ('SLEEP_MASTERUPGRADED'),('SLEEP_MSDBSTARTUP'),('SLEEP_SYSTEMTASK'),('SLEEP_TASK'),
        ('SLEEP_TEMPDBSTARTUP'),('SNI_HTTP_ACCEPT'),('SP_SERVER_DIAGNOSTICS_SLEEP'),
        ('SQLTRACE_BUFFER_FLUSH'),('SQLTRACE_INCREMENTAL_FLUSH_SLEEP'),
        ('SQLTRACE_WAIT_ENTRIES'),('WAIT_FOR_RESULTS'),('WAITFOR'),('WAITFOR_TASKSHUTDOWN'),
        ('WAIT_XTP_RECOVERY'),('WAIT_XTP_HOST_WAIT'),('WAIT_XTP_OFFLINE_CKPT_NEW_LOG'),
        ('WAIT_XTP_CKPT_CLOSE'),('XE_DISPATCHER_JOIN'),('XE_DISPATCHER_WAIT'),
        ('XE_TIMER_EVENT'),('XE_LIVE_TARGET_TVF'),('XE_FILE_TARGET_TVF'),
        ('SOS_WORK_DISPATCHER'),('VDI_CLIENT_OTHER'),('POPULATE_LOCK_ORDINALS'),
        -- Background housekeeping that sleeps in 300s blocks. It surfaced at
        -- 7.5% of total wait time in a 25-minute run purely because it sleeps,
        -- crowding out waits that mean something.
        ('PWAIT_EXTENSIBILITY_CLEANUP_TASK'),('PWAIT_PREEMPTIVE_APP_USAGE_TIMER'),
        ('SLEEP_RETRY_VIRTUALALLOC'),('PARALLEL_REDO_FLOW_CONTROL'),
        -- Extended Events reports some wait types WITHOUT the PWAIT_ prefix the
        -- DMV uses, so both spellings have to be listed for a filter to work
        -- against either source.
        ('EXTENSIBILITY_CLEANUP_TASK'),('FT_SCHEDULER_IDLE_WAIT'),
        ('PREEMPTIVE_XE_SESSIONCOMMIT'),('PREEMPTIVE_XE_TARGETINIT'),
        ('XE_SESSION_FLUSH'),('SLEEP_TASK_SCHEDULER');
    -- NOTE: FSAGENT is in this list because it is chronically idle-noisy, BUT
    -- if you see it climbing during a heavy FILESTREAM run it is meaningful.
    -- 05-analysis.sql reports it separately for exactly that reason.
END
GO

PRINT 'FsPocMonitor ready.';
GO
