/*  06-xevent-shred.sql
    Shreds the FsPoc_Waits event_file target into a temp table and reports.
    Run AFTER stopping the session (or accept a partially-flushed tail).

      sqlcmd -S . -E -b -i sql\06-xevent-shred.sql -v XePath="H:\XEvents"
*/

/*  SQLCMD SCRIPTING VARIABLES REQUIRED BY THIS SCRIPT
      XePath           default: H:\XEvents
      SessionName      default: FsPoc_Waits
    These are intentionally NOT declared with :setvar. A :setvar inside a script
    runs AFTER sqlcmd applies -v, so it silently overrides anything passed on
    the command line -- which would make every -v in this kit a no-op.

    The PowerShell scripts always supply them. To run this file by hand, either
    pass -v for each one, or run sql\00-set-variables.cmd first (sqlcmd falls
    back to environment variables for undefined scripting variables).
*/


SET NOCOUNT ON;
USE FsPocMonitor;
GO

-- The DROP is in its own batch on purpose. SELECT ... INTO a temp table that
-- already exists at compile time fails with "There is already an object named
-- '#xe'", which is what happens on the second run inside one sqlcmd session.
IF OBJECT_ID('tempdb..#xe') IS NOT NULL DROP TABLE #xe;
GO

SELECT CONVERT(xml, event_data) AS ed, file_name, file_offset
INTO #xe
FROM sys.fn_xe_file_target_read_file(N'$(XePath)\$(SessionName)*.xel', NULL, NULL, NULL);

PRINT 'Events read: ' + CONVERT(varchar(20), (SELECT COUNT(*) FROM #xe));
GO

IF OBJECT_ID('tempdb..#ev') IS NOT NULL DROP TABLE #ev;
GO

SELECT
    EventName  = ed.value('(/event/@name)[1]', 'nvarchar(100)'),
    EventTime  = ed.value('(/event/@timestamp)[1]', 'datetime2(3)'),
    WaitType   = ed.value('(/event/data[@name="wait_type"]/text)[1]', 'nvarchar(60)'),
    -- wait_info duration is milliseconds; file_* and log_flush are microseconds.
    RawDuration= ed.value('(/event/data[@name="duration"]/value)[1]', 'bigint'),
    SignalDur  = ed.value('(/event/data[@name="signal_duration"]/value)[1]', 'bigint'),
    SessionId  = ed.value('(/event/action[@name="session_id"]/value)[1]', 'int'),
    DatabaseId = ed.value('(/event/action[@name="database_id"]/value)[1]', 'int'),
    FileId     = ed.value('(/event/data[@name="file_id"]/value)[1]', 'int'),
    IoOffset   = ed.value('(/event/data[@name="offset"]/value)[1]', 'bigint'),
    IoPath     = ed.value('(/event/data[@name="path"]/value)[1]', 'nvarchar(400)'),
    WriteSize  = ed.value('(/event/data[@name="write_size"]/value)[1]', 'bigint'),
    ErrorNum   = ed.value('(/event/data[@name="error_number"]/value)[1]', 'int'),
    ErrorMsg   = ed.value('(/event/data[@name="message"]/value)[1]', 'nvarchar(2000)')
INTO #ev
FROM #xe;

CREATE CLUSTERED INDEX CX_ev ON #ev (EventTime);
GO

PRINT '';
PRINT '--- Wait events by type -------------------------------------------';
SELECT
    EventName,
    WaitType,
    Events     = COUNT(*),
    TotalMs    = SUM(RawDuration),
    AvgMs      = CONVERT(decimal(18,2), AVG(RawDuration * 1.0)),
    P95Ms      = CONVERT(decimal(18,2), MAX(p95)),
    MaxMs      = MAX(RawDuration),
    FirstSeen  = MIN(EventTime),
    LastSeen   = MAX(EventTime)
FROM (
    SELECT *, p95 = PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY RawDuration)
                     OVER (PARTITION BY EventName, WaitType)
    FROM #ev
    WHERE EventName IN ('wait_info','wait_info_external')
) x
GROUP BY EventName, WaitType
ORDER BY SUM(RawDuration) DESC;

PRINT '';
PRINT '--- Slowest 30 individual waits (correlate these to Procmon) -------';
SELECT TOP 30
    EventTime, EventName, WaitType, DurationMs = RawDuration, SessionId, DatabaseId
FROM #ev
WHERE EventName IN ('wait_info','wait_info_external')
ORDER BY RawDuration DESC;

PRINT '';
PRINT '--- SQL Server file I/O completions (microseconds) -----------------';
SELECT
    EventName,
    DatabaseName = DB_NAME(DatabaseId),
    FileId,
    Events   = COUNT(*),
    AvgUs    = CONVERT(decimal(18,1), AVG(RawDuration * 1.0)),
    MaxUs    = MAX(RawDuration),
    TotalMB  = CONVERT(decimal(18,1), SUM(ISNULL(WriteSize, 0)) / 1048576.0)
FROM #ev
WHERE EventName IN ('file_write_completed','file_read_completed','databases_log_flush')
GROUP BY EventName, DatabaseId, FileId
ORDER BY EventName, Events DESC;

PRINT '';
PRINT '--- Errors --------------------------------------------------------';
SELECT TOP 50 EventTime, ErrorNum, ErrorMsg, SessionId
FROM #ev WHERE EventName = 'error_reported'
ORDER BY EventTime;

PRINT '';
PRINT '--- Per-second wait pressure (for charting against Procmon) --------';
SELECT
    Second   = DATEADD(second, DATEDIFF(second, 0, EventTime), 0),
    WaitType,
    Events   = COUNT(*),
    TotalMs  = SUM(RawDuration)
FROM #ev
WHERE EventName IN ('wait_info','wait_info_external')
GROUP BY DATEADD(second, DATEDIFF(second, 0, EventTime), 0), WaitType
ORDER BY Second, TotalMs DESC;
GO
