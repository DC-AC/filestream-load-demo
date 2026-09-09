/*  01-instance-config.sql
    Instance-level FILESTREAM enablement + POC-friendly settings.

    PREREQUISITE: the Windows-level FILESTREAM switch must be on FIRST.
    Do that via ps/Setup-FilestreamPoc.ps1 (WMI) or SQL Server Configuration
    Manager -> SQL Server Services -> <instance> -> Properties -> FILESTREAM.
    Enabling it at the Windows level requires a SQL Server service restart.

    Run:  sqlcmd -S . -E -b -i sql\01-instance-config.sql
*/
SET NOCOUNT ON;

-- 0 = disabled, 1 = T-SQL access only, 2 = T-SQL + local Win32 streaming,
-- (remote Win32 streaming is the Windows-level setting, not this one).
-- Level 2 is required for SqlFileStream, which is what the ingest engine uses.
EXEC sp_configure 'filestream access level', 2;
RECONFIGURE WITH OVERRIDE;
GO

-- Report what the instance actually has, both layers.
SELECT
    SqlLevel        = CONVERT(int, SERVERPROPERTY('FilestreamEffectiveLevel')),
    ConfiguredLevel = CONVERT(int, SERVERPROPERTY('FilestreamConfiguredLevel')),
    ShareName       = CONVERT(sysname, SERVERPROPERTY('FilestreamShareName')),
    Edition         = CONVERT(nvarchar(128), SERVERPROPERTY('Edition')),
    ProductVersion  = CONVERT(nvarchar(64), SERVERPROPERTY('ProductVersion'));
GO

IF CONVERT(int, SERVERPROPERTY('FilestreamEffectiveLevel')) < 2
BEGIN
    RAISERROR('FILESTREAM effective level < 2. Enable FILESTREAM at the Windows level (Configuration Manager or Setup-FilestreamPoc.ps1) and RESTART the SQL Server service, then re-run this script.', 16, 1);
END
GO

/* ---------------------------------------------------------------------------
   POC-relevant instance settings. These are deliberate choices for a
   throughput benchmark, not blanket production recommendations.
--------------------------------------------------------------------------- */
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
GO

/*  max server memory is deliberately NOT changed here -- it is too
    environment-specific to set blind, and getting it wrong invalidates the
    whole POC in a way that is hard to spot.

    Why it matters more than usual for FILESTREAM: FILESTREAM I/O is served by
    the Windows system file cache, which lives OUTSIDE the SQL Server buffer
    pool. The default "give SQL Server everything" setting starves the very
    cache your FILESTREAM reads depend on, and no SQL-side counter shows it.
    Leave real headroom for the OS and the file cache.

    Report the current value so it is recorded alongside the run: */
SELECT
    ConfigName   = name,
    ConfiguredMB = value,
    RunningMB    = value_in_use
FROM sys.configurations
WHERE name IN ('max server memory (MB)', 'min server memory (MB)');
GO

SELECT
    PhysicalMemoryMB   = total_physical_memory_kb / 1024,
    AvailableMemoryMB  = available_physical_memory_kb / 1024,
    SystemCacheMB      = system_cache_kb / 1024,   -- the FILESTREAM-relevant one
    SystemMemoryState  = system_memory_state_desc
FROM sys.dm_os_sys_memory;
GO

-- Instant File Initialization check (affects data-file growth, not FILESTREAM
-- containers, but a 200 GB run will grow the MDF and the log).
SELECT
    ServiceAccount            = servicename,
    InstantFileInitEnabled    = instant_file_initialization_enabled
FROM sys.dm_server_services
WHERE servicename LIKE 'SQL Server (%';
GO
