/*  02-create-database.sql
    Creates the FILESTREAM POC database, the FILESTREAM table, and a
    non-FILESTREAM LOB table used as the A/B comparison baseline.

    Run with sqlcmd, supplying the scripting variables listed below:
      sqlcmd -S . -E -b -i sql\02-create-database.sql ^
             -v DbName="FsPocDemo" DataPath="F:\SQLData" LogPath="H:\SQLLog" ^
                FsPath="G:\FilestreamData" FsPath2="" DirectoryName="FsPocDemo" TargetGB=200

    IMPORTANT about FILESTREAM container paths:
      The LAST folder in the container path must NOT already exist -- SQL Server
      creates it. The PARENT must exist. If a previous run left it behind,
      99-cleanup.sql removes it (or delete the folder by hand).
*/

/*  SQLCMD SCRIPTING VARIABLES REQUIRED BY THIS SCRIPT
      DbName           default: FsPocDemo
      DataPath         default: F:\SQLData
      LogPath          default: H:\SQLLog
      FsPath           default: G:\FilestreamData
      FsPath2          default: (blank = single container)
      DirectoryName    default: FsPocDemo
      TargetGB         default: 200
    These are intentionally NOT declared with :setvar. A :setvar inside a script
    runs AFTER sqlcmd applies -v, so it silently overrides anything passed on
    the command line -- which would make every -v in this kit a no-op.

    The PowerShell scripts always supply them. To run this file by hand, either
    pass -v for each one, or run sql\00-set-variables.cmd first (sqlcmd falls
    back to environment variables for undefined scripting variables).
*/

SET NOCOUNT ON;
GO

IF DB_ID(N'$(DbName)') IS NOT NULL
BEGIN
    RAISERROR('Database $(DbName) already exists. Run sql\99-cleanup.sql first if you want a clean rebuild.', 16, 1);
    SET NOEXEC ON;
END
GO

/* ---------------------------------------------------------------------------
   Sizing: presize everything so file growth is not what you end up measuring.

   MDF: FILESTREAM data does NOT live in the MDF, but the row metadata does.
        A few hundred bytes/row * a few hundred thousand rows is small; 4 GB is
        generous headroom.
   LDF: this is the one that bites. Under SIMPLE recovery, FILESTREAM file
        content is not written to the log, but each streamed insert is still a
        transaction. Under FULL recovery the log grows with the metadata and
        the log backup chain carries the FILESTREAM data. We use SIMPLE for the
        throughput baseline -- switch to FULL for the "realistic" run and watch
        WRITELOG separately.
--------------------------------------------------------------------------- */
CREATE DATABASE [$(DbName)]
ON PRIMARY
(
    NAME     = N'$(DbName)_data',
    FILENAME = N'$(DataPath)\$(DbName)_data.mdf',
    SIZE     = 4096MB,
    FILEGROWTH = 1024MB
),
FILEGROUP FsPocFileStream CONTAINS FILESTREAM
(
    NAME     = N'$(DbName)_fs1',
    FILENAME = N'$(FsPath)\$(DbName)_FS1'
)
LOG ON
(
    NAME     = N'$(DbName)_log',
    FILENAME = N'$(LogPath)\$(DbName)_log.ldf',
    SIZE     = 16384MB,
    FILEGROWTH = 2048MB
)
WITH FILESTREAM
(
    NON_TRANSACTED_ACCESS = FULL,
    DIRECTORY_NAME = N'$(DirectoryName)'
);
GO

ALTER DATABASE [$(DbName)] SET RECOVERY SIMPLE;
ALTER DATABASE [$(DbName)] SET AUTO_CLOSE OFF;
ALTER DATABASE [$(DbName)] SET AUTO_SHRINK OFF;
ALTER DATABASE [$(DbName)] SET AUTO_CREATE_STATISTICS ON;
ALTER DATABASE [$(DbName)] SET AUTO_UPDATE_STATISTICS ON;
-- Accelerated Database Recovery interacts with FILESTREAM GC; leave OFF for a
-- clean first measurement, then flip it on as a second data point.
ALTER DATABASE [$(DbName)] SET ACCELERATED_DATABASE_RECOVERY = OFF;
GO

/* Optional second FILESTREAM container on a different disk.
   A FILESTREAM filegroup accepts multiple containers and fills them
   proportionally -- this is how you spread FILESTREAM across data disks to get
   past a single Azure disk's IOPS/throughput cap. */
DECLARE @fs2 sysname = N'$(FsPath2)';
IF LEN(LTRIM(@fs2)) > 0
BEGIN
    DECLARE @sql nvarchar(max) = N'
        ALTER DATABASE [$(DbName)]
        ADD FILE (NAME = N''$(DbName)_fs2'', FILENAME = N''' + @fs2 + N'\$(DbName)_FS2'')
        TO FILEGROUP FsPocFileStream;';
    EXEC sys.sp_executesql @sql;
    PRINT 'Added second FILESTREAM container: ' + @fs2;
END
ELSE
    PRINT 'Single FILESTREAM container. Set -v FsPath2="I:\FilestreamData2" to add a second.';
GO

USE [$(DbName)];
GO

/* ---------------------------------------------------------------------------
   The FILESTREAM table.

   ROWGUIDCOL + UNIQUE is mandatory for a FILESTREAM column. The ingest engine
   generates the GUID client-side so it can round-trip PathName() and the
   transaction context in a single batch.
--------------------------------------------------------------------------- */
CREATE TABLE dbo.FileStore
(
    FileId       bigint IDENTITY(1,1)  NOT NULL,
    RowGuid      uniqueidentifier ROWGUIDCOL NOT NULL CONSTRAINT DF_FileStore_RowGuid DEFAULT NEWID(),
    RunId        uniqueidentifier      NOT NULL,
    Bucket       varchar(20)           NOT NULL,
    FileName     nvarchar(400)         NOT NULL,
    SizeBytes    bigint                NOT NULL,
    IngestedAt   datetime2(3)          NOT NULL CONSTRAINT DF_FileStore_IngestedAt DEFAULT SYSUTCDATETIME(),
    ContentHash  binary(8)             NULL,     -- cheap checksum for read-back verification
    FileData     varbinary(max) FILESTREAM NULL,
    CONSTRAINT PK_FileStore PRIMARY KEY CLUSTERED (FileId),
    CONSTRAINT UQ_FileStore_RowGuid UNIQUE NONCLUSTERED (RowGuid)
) FILESTREAM_ON FsPocFileStream;
GO

CREATE NONCLUSTERED INDEX IX_FileStore_RunId_Bucket
    ON dbo.FileStore (RunId, Bucket) INCLUDE (SizeBytes);
GO

/* ---------------------------------------------------------------------------
   The A/B baseline: identical shape, plain varbinary(max) LOB in the data
   filegroup. This is the comparison that actually answers "should we use
   FILESTREAM?" -- the crossover is generally around 1 MB, but it depends on
   your storage, your access pattern, and your read/write mix, which is the
   whole point of running the POC on YOUR VM.
--------------------------------------------------------------------------- */
CREATE TABLE dbo.BlobStore
(
    FileId       bigint IDENTITY(1,1)  NOT NULL,
    RunId        uniqueidentifier      NOT NULL,
    Bucket       varchar(20)           NOT NULL,
    FileName     nvarchar(400)         NOT NULL,
    SizeBytes    bigint                NOT NULL,
    IngestedAt   datetime2(3)          NOT NULL CONSTRAINT DF_BlobStore_IngestedAt DEFAULT SYSUTCDATETIME(),
    ContentHash  binary(8)             NULL,
    FileData     varbinary(max)        NULL,
    CONSTRAINT PK_BlobStore PRIMARY KEY CLUSTERED (FileId)
);
GO

CREATE NONCLUSTERED INDEX IX_BlobStore_RunId_Bucket
    ON dbo.BlobStore (RunId, Bucket) INCLUDE (SizeBytes);
GO

/* Ingest engine calls this: one round trip returns both the Win32 path and the
   transaction context that SqlFileStream needs. */
CREATE OR ALTER PROCEDURE dbo.usp_BeginFileStreamInsert
    @RowGuid   uniqueidentifier,
    @RunId     uniqueidentifier,
    @Bucket    varchar(20),
    @FileName  nvarchar(400),
    @SizeBytes bigint
AS
BEGIN
    SET NOCOUNT ON;
    INSERT dbo.FileStore (RowGuid, RunId, Bucket, FileName, SizeBytes, FileData)
    VALUES (@RowGuid, @RunId, @Bucket, @FileName, @SizeBytes, 0x);

    SELECT
        PathName          = FileData.PathName(),
        TransactionContext = GET_FILESTREAM_TRANSACTION_CONTEXT()
    FROM dbo.FileStore
    WHERE RowGuid = @RowGuid;
END
GO

/* Read-back path for the retrieval benchmark. */
CREATE OR ALTER PROCEDURE dbo.usp_BeginFileStreamRead
    @FileId bigint
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        PathName           = FileData.PathName(),
        TransactionContext = GET_FILESTREAM_TRANSACTION_CONTEXT(),
        SizeBytes          = SizeBytes,
        FileName           = FileName
    FROM dbo.FileStore
    WHERE FileId = @FileId;
END
GO

PRINT '';
PRINT '=== $(DbName) created ===';
GO

SELECT
    FileType   = CASE WHEN df.type = 2 THEN 'FILESTREAM' WHEN df.type = 1 THEN 'LOG' ELSE 'ROWS' END,
    LogicalName= df.name,
    FileGroup  = fg.name,
    PhysicalPath = df.physical_name,
    SizeMB     = CASE WHEN df.type = 2 THEN NULL ELSE df.size / 128 END
FROM sys.database_files df
LEFT JOIN sys.filegroups fg ON fg.data_space_id = df.data_space_id
ORDER BY df.type, df.file_id;
GO

PRINT 'Target ingest volume for this POC: $(TargetGB) GB';
PRINT 'Next: sql\03-monitor-db.sql, then ps\Invoke-PocRun.ps1';
GO
SET NOEXEC OFF;
GO

/* ---------------------------------------------------------------------------
   Chunked-append path for the non-FILESTREAM baseline.

   Deliberately NOT a single INSERT with one big varbinary(max) parameter:
   that would compare a chunked streaming write against a single monolithic
   parameter push and the comparison would be meaningless. .WRITE with a NULL
   offset appends, so the client can feed the same chunk size down both paths.
--------------------------------------------------------------------------- */
USE [$(DbName)];
GO

CREATE OR ALTER PROCEDURE dbo.usp_BeginBlobInsert
    @RunId       uniqueidentifier,
    @Bucket      varchar(20),
    @FileName    nvarchar(400),
    @SizeBytes   bigint,
    @ContentHash binary(8) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT dbo.BlobStore (RunId, Bucket, FileName, SizeBytes, ContentHash, FileData)
    VALUES (@RunId, @Bucket, @FileName, @SizeBytes, @ContentHash, 0x);
    SELECT FileId = CONVERT(bigint, SCOPE_IDENTITY());
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_AppendBlob
    @FileId bigint,
    @Chunk  varbinary(max)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.BlobStore
       SET FileData.WRITE(@Chunk, NULL, NULL)
     WHERE FileId = @FileId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_SetFileStreamHash
    @RowGuid     uniqueidentifier,
    @ContentHash binary(8)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.FileStore SET ContentHash = @ContentHash WHERE RowGuid = @RowGuid;
END
GO

/* Bounds for the read benchmark: workers pick random FileIds in this range. */
CREATE OR ALTER PROCEDURE dbo.usp_GetRunFileRange
    @RunId uniqueidentifier = NULL,
    @Table varchar(20) = 'FileStore'
AS
BEGIN
    SET NOCOUNT ON;
    IF @Table = 'BlobStore'
        SELECT MinFileId = MIN(FileId), MaxFileId = MAX(FileId), Files = COUNT_BIG(*)
        FROM dbo.BlobStore WHERE (@RunId IS NULL OR RunId = @RunId);
    ELSE
        SELECT MinFileId = MIN(FileId), MaxFileId = MAX(FileId), Files = COUNT_BIG(*)
        FROM dbo.FileStore WHERE (@RunId IS NULL OR RunId = @RunId);
END
GO
