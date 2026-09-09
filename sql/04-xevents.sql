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

    THE SESSION IS BUILT DYNAMICALLY.

    A hardcoded CREATE EVENT SESSION fails in its entirety if any single event
    or action is unavailable on the running build, and event availability
    varies by version and edition. This script therefore checks each candidate
    against sys.dm_xe_objects and assembles a session from what is actually
    present, reporting anything it skipped. Adding a speculative event to the
    candidate list below is free: if it does not exist, it is left out.

    SCOPE: instance-wide, filtered only by duration and is_system = 0. It is
    not scoped to one database on purpose -- the predicate sources available on
    sqlos.wait_info vary across versions and a database filter that silently
    matches nothing is worse than no filter. On a dedicated POC VM there is
    nothing else running to dilute it; on a shared instance, correlate by
    session_id when you shred.

    NOT captured here: log flush events. They fire per flush, which during a
    heavy ingest is thousands per second, and they would swamp the session into
    event loss. Log flush cost is already covered from two directions -- the
    WRITELOG / LOGBUFFER waits in this session, and the Log Flush Wait Time and
    Log Bytes Flushed/sec counters in Start-PocCapture.ps1.

    Start/stop is handled by ps\Start-PocCapture.ps1 / Stop-PocCapture.ps1.
*/

/*  SQLCMD SCRIPTING VARIABLES REQUIRED BY THIS SCRIPT
      XePath           default: H:\XEvents
      SessionName      default: FsPoc_Waits
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

DECLARE @SessionName sysname       = N'$(SessionName)';
DECLARE @XePath      nvarchar(260) = N'$(XePath)';
DECLARE @MinWaitMs   int           = $(MinWaitMs);
DECLARE @nl          nchar(2)      = CHAR(13) + CHAR(10);

/* ---------------------------------------------------------------------------
   Drop any previous session first.
--------------------------------------------------------------------------- */
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = @SessionName)
BEGIN
    IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = @SessionName)
        EXEC(N'ALTER EVENT SESSION [' + @SessionName + N'] ON SERVER STATE = STOP;');
    EXEC(N'DROP EVENT SESSION [' + @SessionName + N'] ON SERVER;');
    PRINT 'Dropped existing session ' + @SessionName;
END

/* ---------------------------------------------------------------------------
   Which actions are available?

   capabilities bit 0 marks an object as private/unsupported. NULL capabilities
   simply means "no special capabilities" and is the common case for ordinary
   events, so it must be treated as usable -- filtering on capabilities_desc
   IS NOT NULL would wrongly exclude perfectly good objects.
--------------------------------------------------------------------------- */
DECLARE @actions nvarchar(max);

SELECT @actions = STUFF((
    SELECT N', sqlserver.' + a.ActionName
    FROM (VALUES ('session_id'), ('database_id'), ('sql_text')) AS a(ActionName)
    WHERE EXISTS (
        SELECT 1
        FROM sys.dm_xe_objects o
        JOIN sys.dm_xe_packages p ON p.guid = o.package_guid
        WHERE o.name = a.ActionName
          AND o.object_type = 'action'
          AND p.name = 'sqlserver'
          AND (o.capabilities IS NULL OR (o.capabilities & 1) = 0))
    ORDER BY a.ActionName
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, '');

DECLARE @actionClause nvarchar(max) =
    CASE WHEN @actions IS NULL THEN N'' ELSE N'ACTION (' + @actions + N') ' END;

/* ---------------------------------------------------------------------------
   Candidate events. Anything unavailable is silently skipped and reported.
--------------------------------------------------------------------------- */
DECLARE @candidate TABLE (
    Ord      int           NOT NULL,
    Pkg      sysname       NOT NULL,
    Evt      sysname       NOT NULL,
    Spec     nvarchar(max) NOT NULL,
    -- Event-LOCAL data fields the Spec's predicate references, comma separated.
    -- Predicate sources such as sqlserver.is_system are global and are not
    -- listed here; only fields that must exist on this particular event are.
    -- A predicate naming a field the event does not have fails the whole
    -- CREATE, exactly as an unavailable event name does.
    PredFields nvarchar(200) NOT NULL,
    Purpose  nvarchar(200) NOT NULL
);

DECLARE @waitPred nvarchar(200) =
    N'WHERE ([opcode] = 1 AND [duration] >= ' + CONVERT(nvarchar(20), @MinWaitMs) +
    N' AND [sqlserver].[is_system] = 0)';

INSERT @candidate (Ord, Pkg, Evt, Spec, PredFields, Purpose) VALUES
    -- Cooperative waits: WRITELOG, PAGEIOLATCH, LOGBUFFER, FS_* latches.
    (1, 'sqlos', 'wait_info',
        @actionClause + @waitPred,
        'opcode,duration',
        'Cooperative waits (WRITELOG, PAGEIOLATCH, FS_* latches)'),

    -- Preemptive / external waits: where FILESTREAM Win32 time actually lives.
    -- PREEMPTIVE_OS_WRITEFILE, _CREATEFILE, _FILEOPS, _FLUSHFILEBUFFERS,
    -- _CLOSEHANDLE, _DELETEFILE (garbage collection).
    (2, 'sqlos', 'wait_info_external',
        @actionClause + @waitPred,
        'opcode,duration',
        'Win32/preemptive waits -- the FILESTREAM-critical ones'),

    -- SQL Server's own file I/O completions (MDF/LDF, not the Win32 stream).
    (3, 'sqlserver', 'file_write_completed',
        N'WHERE ([duration] >= ' + CONVERT(nvarchar(20), @MinWaitMs) + N')',
        'duration',
        'MDF/LDF write completions'),
    (4, 'sqlserver', 'file_read_completed',
        N'WHERE ([duration] >= ' + CONVERT(nvarchar(20), @MinWaitMs) + N')',
        'duration',
        'MDF/LDF read completions'),

    -- Transaction boundaries, to correlate a slow write to a specific commit.
    (5, 'sqlserver', 'sql_transaction',
        @actionClause + N'WHERE ([sqlserver].[is_system] = 0)',
        '',
        'Transaction boundaries for Procmon correlation'),

    -- File-in-use, path and GC problems surface here.
    (6, 'sqlserver', 'error_reported',
        @actionClause + N'WHERE ([severity] >= 11)',
        'severity',
        'Errors severity 11+');

/* ---------------------------------------------------------------------------
   Assemble.
--------------------------------------------------------------------------- */
DECLARE @available TABLE (Ord int, Pkg sysname, Evt sysname, Spec nvarchar(max), Purpose nvarchar(200));

INSERT @available
SELECT c.Ord, c.Pkg, c.Evt, c.Spec, c.Purpose
FROM @candidate c
WHERE EXISTS (               -- the event itself exists
    SELECT 1
    FROM sys.dm_xe_objects o
    JOIN sys.dm_xe_packages p ON p.guid = o.package_guid
    WHERE o.name = c.Evt
      AND o.object_type = 'event'
      AND p.name = c.Pkg
      AND (o.capabilities IS NULL OR (o.capabilities & 1) = 0))
  AND NOT EXISTS (           -- ...and every field its predicate names exists
    SELECT 1
    FROM STRING_SPLIT(c.PredFields, ',') f
    WHERE LTRIM(RTRIM(f.value)) <> ''
      AND NOT EXISTS (
        SELECT 1
        FROM sys.dm_xe_object_columns oc
        JOIN sys.dm_xe_objects o2 ON o2.name = oc.object_name AND o2.package_guid = oc.object_package_guid
        JOIN sys.dm_xe_packages p2 ON p2.guid = o2.package_guid
        WHERE oc.object_name = c.Evt
          AND p2.name = c.Pkg
          AND o2.object_type = 'event'
          AND oc.column_type = 'data'
          AND oc.name = LTRIM(RTRIM(f.value))));

PRINT '';
PRINT 'Events INCLUDED:';
SELECT IncludedEvent = a.Pkg + '.' + a.Evt, Purpose = a.Purpose
FROM @available a ORDER BY a.Ord;

IF EXISTS (SELECT 1 FROM @candidate c WHERE NOT EXISTS (SELECT 1 FROM @available a WHERE a.Ord = c.Ord))
BEGIN
    PRINT '';
    PRINT 'Events SKIPPED (event or a predicate field is unavailable on this build --';
    PRINT 'this is not an error; the session is created from what remains):';
    SELECT SkippedEvent = c.Pkg + '.' + c.Evt, Purpose = c.Purpose
    FROM @candidate c
    WHERE NOT EXISTS (SELECT 1 FROM @available a WHERE a.Ord = c.Ord)
    ORDER BY c.Ord;
END

IF NOT EXISTS (SELECT 1 FROM @available)
BEGIN
    RAISERROR('No candidate Extended Events are available on this build. The session cannot be created.', 16, 1);
    RETURN;
END

DECLARE @eventClause nvarchar(max) = STUFF((
    SELECT N',' + @nl + N'ADD EVENT ' + a.Pkg + N'.' + a.Evt + N'(' + a.Spec + N')'
    FROM @available a
    ORDER BY a.Ord
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 1, '');

DECLARE @sql nvarchar(max) =
    N'CREATE EVENT SESSION [' + @SessionName + N'] ON SERVER' + @nl +
    @eventClause + @nl +
    N'ADD TARGET package0.event_file' + @nl +
    N'(' + @nl +
    N'    SET filename = N''' + @XePath + N'\' + @SessionName + N'.xel'',' + @nl +
    N'        max_file_size = 512,' + @nl +   -- MB per rollover file
    N'        max_rollover_files = 20' + @nl + -- ~10 GB ceiling; size the disk
    N')' + @nl +
    N'WITH' + @nl +
    N'(' + @nl +
    N'    MAX_MEMORY = 64MB,' + @nl +
    N'    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,' + @nl +
    N'    MAX_DISPATCH_LATENCY = 5 SECONDS,' + @nl +
    -- MAX_EVENT_SIZE is deliberately not set. It exists to permit single events
    -- LARGER than MAX_MEMORY, so any explicit value must exceed MAX_MEMORY;
    -- passing 0 raises msg 25703. Omitting it takes the default, which is 0.
    N'    MEMORY_PARTITION_MODE = PER_CPU,' + @nl +
    N'    TRACK_CAUSALITY = ON,' + @nl +
    N'    STARTUP_STATE = OFF' + @nl +
    N');';

PRINT '';
PRINT '--- Session definition -------------------------------------------';
PRINT @sql;

EXEC sys.sp_executesql @sql;

PRINT '';
PRINT 'Created event session ' + @SessionName + '. Target: ' + @XePath + '\' + @SessionName + '.xel';
PRINT 'Ensure that folder exists and the SQL Server service account can write to it.';
PRINT 'Start with: ALTER EVENT SESSION [' + @SessionName + '] ON SERVER STATE = START;';
GO

-- Confirm it landed.
SELECT
    SessionName = s.name,
    EventCount  = (SELECT COUNT(*) FROM sys.server_event_session_events e WHERE e.event_session_id = s.event_session_id),
    TargetCount = (SELECT COUNT(*) FROM sys.server_event_session_targets t WHERE t.event_session_id = s.event_session_id)
FROM sys.server_event_sessions s
WHERE s.name = N'$(SessionName)';
GO
