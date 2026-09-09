/*  04-xevents.sql
    Extended Events session for the FILESTREAM POC.

    Why this exists alongside the wait-stat snapshots: aggregate DMV deltas tell
    you WHICH waits dominated; this tells you WHEN and for HOW LONG each one
    happened, which is what you need to line the SQL side up against the
    Procmon timeline.

    The critical events for FILESTREAM are the *external* ones. Win32 file
    operations that SQL Server performs on your behalf (create, write, flush,
    close on the container) run preemptively -- the worker leaves the scheduler
    and the time lands in PREEMPTIVE_OS_* waits, captured by
    sqlos.wait_info_external. Aggregate wait stats routinely hide these because
    people filter PREEMPTIVE_* out as noise. Do not filter them out here.

      sqlcmd -S . -E -b -i sql\04-xevents.sql

    Start/stop is handled by ps\Start-PocCapture.ps1 / Stop-PocCapture.ps1.
*/

/*  SQLCMD SCRIPTING VARIABLES REQUIRED BY THIS SCRIPT
      XePath           default: H:\XEvents
      SessionName      default: FsPoc_Waits
      TargetDb         default: FsPocDemo
      MinWaitMs        default: 10
    These are intentionally NOT declared with :setvar. A :setvar inside a script
    runs AFTER sqlcmd applies -v, so it silently overrides anything passed on
    the command line -- which would make every -v in this kit a no-op.

    The PowerShell scripts always supply them. To run this file by hand, either
    pass -v for each one, or run sql\00-set-variables.cmd first (sqlcmd falls
    back to environment variables for undefined scripting variables).
*/


SET NOCOUNT ON;
GO

IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'$(SessionName)')
BEGIN
    IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'$(SessionName)')
        ALTER EVENT SESSION [$(SessionName)] ON SERVER STATE = STOP;
    DROP EVENT SESSION [$(SessionName)] ON SERVER;
    PRINT 'Dropped existing session $(SessionName)';
END
GO

CREATE EVENT SESSION [$(SessionName)] ON SERVER

/* ---- Cooperative waits: WRITELOG, PAGEIOLATCH, LOGBUFFER, FS_* latches ---- */
ADD EVENT sqlos.wait_info
(
    ACTION (sqlserver.session_id, sqlserver.database_id, sqlserver.sql_text)
    WHERE  ([opcode] = 1                              -- End of wait only
        AND [duration] >= $(MinWaitMs)
        AND [sqlserver].[is_system] = 0)
),

/* ---- Preemptive / external waits: this is where FILESTREAM Win32 time lives.
        PREEMPTIVE_OS_WRITEFILE, PREEMPTIVE_OS_CREATEFILE, PREEMPTIVE_OS_FILEOPS,
        PREEMPTIVE_OS_FLUSHFILEBUFFERS, PREEMPTIVE_OS_CLOSEHANDLE,
        PREEMPTIVE_OS_DELETEFILE (garbage collection). ---- */
ADD EVENT sqlos.wait_info_external
(
    ACTION (sqlserver.session_id, sqlserver.database_id, sqlserver.sql_text)
    WHERE  ([opcode] = 1
        AND [duration] >= $(MinWaitMs)
        AND [sqlserver].[is_system] = 0)
),

/* ---- SQL Server's own file I/O completions (MDF/LDF, not the Win32 stream) ---- */
ADD EVENT sqlserver.file_write_completed
(
    WHERE ([duration] >= $(MinWaitMs))
),
ADD EVENT sqlserver.file_read_completed
(
    WHERE ([duration] >= $(MinWaitMs))
),

/* ---- Log flush latency: the usual real bottleneck for many-small-transaction
        ingest, FILESTREAM or not. ---- */
ADD EVENT sqlserver.databases_log_flush
(
    ACTION (sqlserver.database_id)
    WHERE ([duration] >= 1000)                        -- microseconds here => 1 ms
),

/* ---- Transaction boundaries, so you can correlate a slow write to a
        specific commit in the Procmon timeline. ---- */
ADD EVENT sqlserver.sql_transaction
(
    ACTION (sqlserver.session_id, sqlserver.database_id)
    WHERE ([sqlserver].[is_system] = 0)
),

/* ---- Errors: file-in-use, path, and GC problems surface here. ---- */
ADD EVENT sqlserver.error_reported
(
    ACTION (sqlserver.session_id, sqlserver.database_id, sqlserver.sql_text)
    WHERE ([severity] >= 11)
)

ADD TARGET package0.event_file
(
    SET filename         = N'$(XePath)\$(SessionName).xel',
        max_file_size    = 512,      -- MB per rollover file
        max_rollover_files = 20      -- ~10 GB ceiling; size the disk accordingly
)

WITH
(
    MAX_MEMORY               = 64MB,
    EVENT_RETENTION_MODE     = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY     = 5 SECONDS,
    MAX_EVENT_SIZE           = 0,
    MEMORY_PARTITION_MODE    = PER_CPU,
    TRACK_CAUSALITY          = ON,
    STARTUP_STATE            = OFF
);
GO

PRINT 'Created event session $(SessionName). Target: $(XePath)\$(SessionName).xel';
PRINT 'Ensure $(XePath) exists and the SQL Server service account can write to it.';
PRINT 'Start with: ALTER EVENT SESSION [$(SessionName)] ON SERVER STATE = START;';
GO
