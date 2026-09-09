/*  99-cleanup.sql
    Tears the demo database down between runs.

      sqlcmd -S . -E -b -i sql\99-cleanup.sql -v DbName="FsPocDemo" FsPath="G:\FilestreamData"

    Two things people get wrong here:

    1) Deleting rows does NOT free disk. FILESTREAM files become "tombstoned"
       and are removed by a background garbage collector that only advances
       past CHECKPOINTs (and, in FULL recovery, past a log backup). If you
       measure a second run right after a DELETE, the GC is still churning in
       the background and it WILL pollute your numbers.

    2) DROP DATABASE removes the container, but if anything still holds a
       handle to the directory (Explorer, an AV scanner, a stale Win32 handle)
       the folder is left behind and the next CREATE DATABASE fails, because
       the leaf container folder must not exist.
*/

/*  SQLCMD SCRIPTING VARIABLES REQUIRED BY THIS SCRIPT
      DbName           default: FsPocDemo
      Mode             default: drop  -- or "purge"
    These are intentionally NOT declared with :setvar. A :setvar inside a script
    runs AFTER sqlcmd applies -v, so it silently overrides anything passed on
    the command line -- which would make every -v in this kit a no-op.

    The PowerShell scripts always supply them. To run this file by hand, either
    pass -v for each one, or run sql\00-set-variables.cmd first (sqlcmd falls
    back to environment variables for undefined scripting variables).
*/


SET NOCOUNT ON;
GO

IF N'$(Mode)' = N'purge'
BEGIN
    PRINT 'Purge mode: emptying tables and forcing FILESTREAM garbage collection.';
END
ELSE
    PRINT 'Drop mode: dropping $(DbName).';
GO

IF N'$(Mode)' = N'purge' AND DB_ID(N'$(DbName)') IS NOT NULL
BEGIN
    DECLARE @sql nvarchar(max) = N'
    USE [$(DbName)];
    DELETE FROM dbo.FileStore;
    DELETE FROM dbo.BlobStore;
    CHECKPOINT;';
    EXEC sys.sp_executesql @sql;

    -- Force GC. Run it repeatedly until num_marked_for_deletion stops falling;
    -- on a few hundred GB this takes a while and is itself worth measuring.
    DECLARE @i int = 0;
    WHILE @i < 10
    BEGIN
        EXEC sp_filestream_force_garbage_collection @dbname = N'$(DbName)';
        CHECKPOINT;
        SET @i += 1;
    END
    PRINT 'GC passes complete. Verify the container directory has actually shrunk on disk.';
END
GO

IF N'$(Mode)' <> N'purge' AND DB_ID(N'$(DbName)') IS NOT NULL
BEGIN
    ALTER DATABASE [$(DbName)] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [$(DbName)];
    PRINT 'Dropped $(DbName).';
    PRINT 'If CREATE DATABASE later fails with "cannot be created because it already exists",';
    PRINT 'the leaf container folder survived the drop -- delete it manually.';
END
GO
