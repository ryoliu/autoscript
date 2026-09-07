/*
  Generate_All_UserDB_Restore.sql
  Pure T-SQL: generate RESTORE scripts for the latest full backup of each user database at the DR site.
  This generator does not execute RESTORE DATABASE, enable xp_cmdshell, or load backup history into msdb.

  Intended platform: Windows SQL Server 2016 CU1+ / 2017 / 2019 / 2022 / 2025.
  Run the entire file in SSMS connected to the DR target instance; do not run isolated sections.
  RESTORE metadata and xp_dirtree permissions are required; this script is intended for DBA use.
  The SQL Server service account needs backup read access and Data/Log write access for restoration.
  xp_dirtree is undocumented. If access is restricted, consult the administrator; do not bypass restrictions.

  Handles subdirectories, multiple backup dates, native striped backups, and appended backup set positions.
  Selects the latest full backup by header BackupFinishDate, including COPY_ONLY full backups.
  If the latest backup is incomplete or invalid, that database is blocked; no fallback to an older backup.
  Reported file/directory read errors stop generation to avoid selecting an older backup by mistake.
  Same-named databases from different source servers/database families are blocked; narrow the scan scope.
  Only ordinary D/L files are handled. FILESTREAM and In-Memory containers require separate MOVE rules.
  Scans .bak files only; adjust the extension filter if needed. Do not include directory links/junctions.
  Covers databases found in readable backups; this does not prove every source database has a backup.
  Headers alone may not reveal incomplete file copies. Wait until backup transfers finish before running.

  Safety: existing database names produce warnings during generation; generated SQL blocks them at execution.
  Never adds WITH REPLACE. Paths owned by the same existing database do not block script generation.
  Preserves original physical filenames; checks cross-database target collisions and sys.master_files paths.
  Does not create directories, check free disk space, transfer certificates, or restore logins/jobs.
  Prepare TDE/backup encryption keys or certificates first. The source version must not exceed the target.
  @RunVerifyOnly=1 additionally reads the full backup for verification, costing time and I/O; it does not restore.
  VERIFYONLY is not a substitute for a test restore and DBCC CHECKDB.

  Result sets: 1 database status; 2 MOVE mapping; 3 warnings and errors.
  Restore commands are printed to the SSMS Messages tab between BEGIN/END GENERATED RESTORE SCRIPT markers.
  Copy only that marked section and review in a new window before execution.
  Each PRINT outputs one line of at most 4000 Unicode characters to avoid truncating a complete script.

  Written against Microsoft Learn metadata schemas; not runtime-tested on the user's SQL Server.
  References:
  https://learn.microsoft.com/en-us/sql/t-sql/statements/restore-statements-headeronly-transact-sql
  https://learn.microsoft.com/en-us/sql/t-sql/statements/restore-statements-labelonly-transact-sql
  https://learn.microsoft.com/en-us/sql/t-sql/statements/restore-statements-filelistonly-transact-sql
*/
USE [master];
SET NOCOUNT ON;

/*==================== Configure these three paths first ====================*/
DECLARE @BackupRoot nvarchar(4000) = N'T:\SQLServerBackup\data';
DECLARE @DataPath   nvarchar(4000) = N'H:\MSSQL\DATA\';
DECLARE @LogPath    nvarchar(4000) = N'L:\MSSQL\LOG\';

DECLARE @RunVerifyOnly bit = 0; -- 0=metadata only; 1=also run VERIFYONLY
DECLARE @MaxDepth int = 16;     -- Subdirectory depth limit to guard against directory cycles

/*==================== 0. Preflight checks ====================*/
DECLARE @Major int = TRY_CONVERT(int, SERVERPROPERTY('ProductMajorVersion'));
DECLARE @Build int = TRY_CONVERT(int, PARSENAME(CONVERT(varchar(32), SERVERPROPERTY('ProductVersion')), 2));
IF @Major IS NULL OR @Major NOT BETWEEN 13 AND 17 OR (@Major = 13 AND @Build < 2149)
    THROW 50001, N'This script targets SQL Server 2016 CU1+ through SQL Server 2025.', 1;
IF @@TRANCOUNT <> 0
    THROW 50002, N'Do not run this generator inside a user transaction.', 1;
IF NULLIF(LTRIM(RTRIM(@BackupRoot)), N'') IS NULL
   OR NULLIF(LTRIM(RTRIM(@DataPath)), N'') IS NULL
   OR NULLIF(LTRIM(RTRIM(@LogPath)), N'') IS NULL
    THROW 50003, N'Backup, Data, and Log paths must not be empty.', 1;
IF RIGHT(@BackupRoot, 1) <> N'\' SET @BackupRoot += N'\';
IF RIGHT(@DataPath, 1) <> N'\' SET @DataPath += N'\';
IF RIGHT(@LogPath, 1) <> N'\' SET @LogPath += N'\';
IF LEN(@BackupRoot) > 240 OR LEN(@DataPath) > 240 OR LEN(@LogPath) > 240
    THROW 50004, N'Shorten the root paths. This script conservatively limits them to 240 characters.', 1;

DROP TABLE IF EXISTS #RDir;
DROP TABLE IF EXISTS #RQueue;
DROP TABLE IF EXISTS #RFiles;
DROP TABLE IF EXISTS #RIssues;
DROP TABLE IF EXISTS #RLabel;
DROP TABLE IF EXISTS #RHeader;
DROP TABLE IF EXISTS #RBackups;
DROP TABLE IF EXISTS #RSets;
DROP TABLE IF EXISTS #RLatest;
DROP TABLE IF EXISTS #RFileList;
DROP TABLE IF EXISTS #RMap;
DROP TABLE IF EXISTS #RScripts;
DROP TABLE IF EXISTS #RLines;

CREATE TABLE #RDir (EntryName nvarchar(512), Depth int, IsFile bit);
CREATE TABLE #RQueue
(
    ID int IDENTITY PRIMARY KEY, Folder nvarchar(4000), LevelNo int, Done bit DEFAULT (0)
);
CREATE TABLE #RFiles (ID int IDENTITY PRIMARY KEY, FilePath nvarchar(4000));
CREATE TABLE #RIssues
(
    Stage nvarchar(30), Item nvarchar(4000), Detail nvarchar(4000)
);
INSERT #RQueue(Folder, LevelNo) VALUES (@BackupRoot, 0);

/*==================== 1. Recursive directory scan ====================*/
DECLARE @QueueID int, @Folder nvarchar(4000), @Level int;
WHILE EXISTS (SELECT 1 FROM #RQueue WHERE Done = 0)
BEGIN
    SELECT TOP (1) @QueueID = ID, @Folder = Folder, @Level = LevelNo
    FROM #RQueue WHERE Done = 0 ORDER BY ID;
    UPDATE #RQueue SET Done = 1 WHERE ID = @QueueID;
    TRUNCATE TABLE #RDir;
    BEGIN TRY
        INSERT #RDir EXEC master.sys.xp_dirtree @Folder, 1, 1;
        IF NOT EXISTS (SELECT 1 FROM #RDir)
            INSERT #RIssues VALUES (N'Warning', @Folder, N'No visible directory entries: the folder may be empty or inaccessible.');
        IF EXISTS (SELECT 1 FROM #RDir WHERE LEN(@Folder + EntryName) > 259)
            THROW 50005, N'A scanned path exceeds the supported length. Shorten the path.', 1;
        INSERT #RFiles(FilePath)
        SELECT @Folder + D.EntryName FROM #RDir AS D
        WHERE D.IsFile = 1 AND LOWER(RIGHT(D.EntryName, 4)) = N'.bak'
          AND NOT EXISTS (SELECT 1 FROM #RFiles AS F WHERE F.FilePath = @Folder + D.EntryName);
        IF @Level >= @MaxDepth AND EXISTS (SELECT 1 FROM #RDir WHERE IsFile = 0)
            THROW 50006, N'Directory depth limit exceeded. Check for directory links or narrow the scan scope.', 1;
        INSERT #RQueue(Folder, LevelNo)
        SELECT @Folder + D.EntryName + N'\', @Level + 1 FROM #RDir AS D
        WHERE D.IsFile = 0 AND D.EntryName NOT IN (N'.', N'..')
          AND NOT EXISTS (SELECT 1 FROM #RQueue AS Q WHERE Q.Folder = @Folder + D.EntryName + N'\');
    END TRY
    BEGIN CATCH
        INSERT #RIssues VALUES (N'ScanError', @Folder, ERROR_MESSAGE());
    END CATCH;
END;
IF EXISTS (SELECT 1 FROM #RIssues WHERE Stage = N'ScanError')
BEGIN
    SELECT * FROM #RIssues;
    THROW 50007, N'Directory scan errors occurred. No restore scripts were generated.', 1;
END;
IF NOT EXISTS (SELECT 1 FROM #RFiles)
BEGIN
    SELECT * FROM #RIssues;
    THROW 50008, N'No .bak files found. Check the path and service account permissions on the DR SQL Server.', 1;
END;

/*==================== 2. Backup metadata staging tables ====================*/
CREATE TABLE #RLabel
(
    MediaName nvarchar(128), MediaSetId uniqueidentifier,
    FamilyCount int, FamilySequenceNumber int, MediaFamilyId uniqueidentifier,
    MediaSequenceNumber int, MediaLabelPresent tinyint, MediaDescription nvarchar(255),
    SoftwareName nvarchar(128), SoftwareVendorId int, MediaDate datetime,
    Mirror_Count int, IsCompressed bit
);
CREATE TABLE #RHeader
(
    BackupName nvarchar(128), BackupDescription nvarchar(255), BackupType smallint,
    ExpirationDate datetime, Compressed bit, Position smallint, DeviceType tinyint,
    UserName nvarchar(128), ServerName nvarchar(128), DatabaseName nvarchar(128),
    DatabaseVersion int, DatabaseCreationDate datetime, BackupSize numeric(20,0),
    FirstLSN numeric(25,0), LastLSN numeric(25,0), CheckpointLSN numeric(25,0),
    DatabaseBackupLSN numeric(25,0), BackupStartDate datetime, BackupFinishDate datetime,
    SortOrder smallint, CodePage smallint, UnicodeLocaleId int, UnicodeComparisonStyle int,
    CompatibilityLevel tinyint, SoftwareVendorId int, SoftwareVersionMajor int,
    SoftwareVersionMinor int, SoftwareVersionBuild int, MachineName nvarchar(128),
    Flags int, BindingID uniqueidentifier, RecoveryForkID uniqueidentifier,
    Collation nvarchar(128), FamilyGUID uniqueidentifier,
    HasBulkLoggedData bit, IsSnapshot bit, IsReadOnly bit, IsSingleUser bit,
    HasBackupChecksums bit, IsDamaged bit, BeginsLogChain bit,
    HasIncompleteMetaData bit, IsForceOffline bit, IsCopyOnly bit,
    FirstRecoveryForkID uniqueidentifier, ForkPointLSN numeric(25,0),
    RecoveryModel nvarchar(60), DifferentialBaseLSN numeric(25,0),
    DifferentialBaseGUID uniqueidentifier, BackupTypeDescription nvarchar(60),
    BackupSetGUID uniqueidentifier, CompressedBackupSize bigint, Containment tinyint,
    KeyAlgorithm nvarchar(32), EncryptorThumbprint varbinary(20), EncryptorType nvarchar(32)
);
IF @Major >= 16
    ALTER TABLE #RHeader ADD LastValidRestoreTime datetime, TimeZone nvarchar(32), CompressionAlgorithm nvarchar(32);

CREATE TABLE #RBackups
(
    FileID int, DatabaseName nvarchar(128) COLLATE DATABASE_DEFAULT,
    SourceServer nvarchar(128) COLLATE DATABASE_DEFAULT, FamilyGUID uniqueidentifier,
    BackupSetGUID uniqueidentifier, Position int, FinishTime datetime,
    SourceMajor int, IsDamaged bit, IsSnapshot bit, IsCopyOnly bit,
    MediaSetId uniqueidentifier, FamilyCount int, FamilySequenceNumber int,
    MediaFamilyId uniqueidentifier
);
DECLARE @FileID int, @File nvarchar(4000), @SQL nvarchar(max);
DECLARE RFileCursor CURSOR LOCAL FAST_FORWARD FOR SELECT ID, FilePath FROM #RFiles ORDER BY ID;
OPEN RFileCursor;
FETCH NEXT FROM RFileCursor INTO @FileID, @File;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        TRUNCATE TABLE #RLabel;
        TRUNCATE TABLE #RHeader;
        SET @SQL = N'RESTORE LABELONLY FROM DISK = N''' + REPLACE(@File, N'''', N'''''') + N''';';
        INSERT #RLabel EXEC sys.sp_executesql @SQL;
        IF (SELECT COUNT(*) FROM #RLabel) <> 1
            THROW 50009, N'LABELONLY did not return exactly one valid media header.', 1;
        IF EXISTS (SELECT 1 FROM #RLabel WHERE MediaSetId IS NULL OR MediaFamilyId IS NULL
            OR FamilyCount IS NULL OR FamilyCount NOT BETWEEN 1 AND 64
            OR FamilySequenceNumber IS NULL OR FamilySequenceNumber NOT BETWEEN 1 AND FamilyCount)
            THROW 50010, N'The media header contains invalid stripe metadata.', 1;
        SET @SQL = N'RESTORE HEADERONLY FROM DISK = N''' + REPLACE(@File, N'''', N'''''') + N''';';
        INSERT #RHeader EXEC sys.sp_executesql @SQL;
        IF NOT EXISTS (SELECT 1 FROM #RHeader)
            THROW 50011, N'HEADERONLY returned no backup metadata.', 1;
        IF EXISTS (SELECT 1 FROM #RHeader WHERE BackupType IS NULL OR DatabaseName IS NULL
            OR (BackupType = 1 AND (BackupSetGUID IS NULL OR BackupFinishDate IS NULL OR Position IS NULL)))
            THROW 50012, N'Backup headers are incomplete or password-protected; the latest backup cannot be determined reliably.', 1;
        INSERT #RBackups
        SELECT @FileID, H.DatabaseName, H.ServerName, H.FamilyGUID,
               H.BackupSetGUID, H.Position, H.BackupFinishDate, H.SoftwareVersionMajor,
               H.IsDamaged, H.IsSnapshot, H.IsCopyOnly,
               L.MediaSetId, L.FamilyCount, L.FamilySequenceNumber, L.MediaFamilyId
        FROM #RHeader AS H CROSS JOIN #RLabel AS L
        WHERE H.BackupType = 1
          AND H.DatabaseName COLLATE Latin1_General_100_CI_AS NOT IN (N'master', N'model', N'msdb', N'tempdb');
    END TRY
    BEGIN CATCH
        INSERT #RIssues VALUES (N'MetadataError', @File, ERROR_MESSAGE());
    END CATCH;
    FETCH NEXT FROM RFileCursor INTO @FileID, @File;
END;
CLOSE RFileCursor;
DEALLOCATE RFileCursor;
IF EXISTS (SELECT 1 FROM #RIssues WHERE Stage = N'MetadataError')
BEGIN
    SELECT * FROM #RIssues;
    THROW 50013, N'Unreadable backups detected. Generation stopped to avoid selecting an older backup as the latest. Review the errors.', 1;
END;

/*==================== 3. Latest full backup per database (no fallback) ====================*/
SELECT DatabaseName, BackupSetGUID, MAX(FinishTime) AS FinishTime
INTO #RSets FROM #RBackups GROUP BY DatabaseName, BackupSetGUID;
;WITH Ranked AS
(
    SELECT *, ROW_NUMBER() OVER
        (PARTITION BY DatabaseName ORDER BY FinishTime DESC, BackupSetGUID DESC) AS RN
    FROM #RSets
)
SELECT DatabaseName, BackupSetGUID, FinishTime,
       CAST(N'Pending' AS nvarchar(30)) AS Status,
       CAST(NULL AS nvarchar(4000)) AS Detail
INTO #RLatest FROM Ranked WHERE RN = 1;

CREATE TABLE #RFileList
(
    LogicalName nvarchar(128), PhysicalName nvarchar(260), [Type] char(1),
    FileGroupName nvarchar(128), [Size] numeric(20,0), MaxSize numeric(20,0),
    FileID bigint, CreateLSN numeric(25,0), DropLSN numeric(25,0), UniqueID uniqueidentifier,
    ReadOnlyLSN numeric(25,0), ReadWriteLSN numeric(25,0), BackupSizeInBytes bigint,
    SourceBlockSize int, FileGroupID int, LogGroupGUID uniqueidentifier,
    DifferentialBaseLSN numeric(25,0), DifferentialBaseGUID uniqueidentifier,
    IsReadOnly bit, IsPresent bit, TDEThumbprint varbinary(32), SnapshotURL nvarchar(360)
);
CREATE TABLE #RMap
(
    DatabaseName nvarchar(128) COLLATE DATABASE_DEFAULT, FileID bigint,
    LogicalName nvarchar(128), FileType char(1), OriginalPath nvarchar(260),
    TargetPath nvarchar(4000), SizeBytes numeric(20,0)
);
CREATE TABLE #RScripts
(
    DatabaseName nvarchar(128) COLLATE DATABASE_DEFAULT, RestoreScript nvarchar(max)
);
DECLARE @DB nvarchar(128), @GUID uniqueidentifier, @Finish datetime,
        @Devices nvarchar(max), @Moves nvarchar(max), @Script nvarchar(max),
        @Position int, @Expected int, @NL nchar(2) = NCHAR(13) + NCHAR(10);
DECLARE RDBCursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatabaseName, BackupSetGUID, FinishTime FROM #RLatest ORDER BY DatabaseName;
OPEN RDBCursor;
FETCH NEXT FROM RDBCursor INTO @DB, @GUID, @Finish;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        IF DB_ID(@DB) IS NOT NULL
            INSERT #RIssues VALUES (N'Warning', @DB,
                N'A database with this name exists on the current instance. Script generation continues; generated SQL blocks restoration if the database exists on the execution instance.');
        IF EXISTS (SELECT 1 FROM #RBackups WHERE DatabaseName = @DB AND (SourceServer IS NULL OR FamilyGUID IS NULL))
            THROW 50015, N'Source server or database family metadata is missing.', 1;
        IF (SELECT COUNT(*) FROM
            (SELECT SourceServer, FamilyGUID FROM #RBackups WHERE DatabaseName = @DB
             GROUP BY SourceServer, FamilyGUID) AS Sources) <> 1
            THROW 50016, N'This database name has multiple source servers or families. Narrow the backup root scope.', 1;
        IF (SELECT COUNT(*) FROM #RSets WHERE DatabaseName = @DB AND FinishTime = @Finish) <> 1
            THROW 50017, N'Multiple full backups have the same finish time. Manually confirm the intended backup.', 1;
        IF EXISTS (SELECT 1 FROM #RBackups WHERE BackupSetGUID = @GUID
            AND (ISNULL(IsDamaged, 1) <> 0 OR ISNULL(IsSnapshot, 1) <> 0 OR ISNULL(SourceMajor, 99) > @Major))
            THROW 50018, N'The latest backup is marked damaged, is a snapshot, or has a newer source version. No older backup was selected.', 1;
        IF (SELECT COUNT(DISTINCT MediaSetId) FROM #RBackups WHERE BackupSetGUID = @GUID) <> 1
           OR (SELECT COUNT(DISTINCT Position) FROM #RBackups WHERE BackupSetGUID = @GUID) <> 1
           OR (SELECT COUNT(DISTINCT FamilyCount) FROM #RBackups WHERE BackupSetGUID = @GUID) <> 1
            THROW 50019, N'Media set, backup position, or stripe count metadata is inconsistent for this backup.', 1;
        SELECT @Expected = MAX(FamilyCount), @Position = MAX(Position)
        FROM #RBackups WHERE BackupSetGUID = @GUID;
        IF (SELECT COUNT(DISTINCT FamilySequenceNumber) FROM #RBackups WHERE BackupSetGUID = @GUID) <> @Expected
            THROW 50020, N'The latest full backup has missing stripes. Supply all files and rerun; no fallback to older backups.', 1;
        IF (SELECT COUNT(*) FROM #RBackups WHERE BackupSetGUID = @GUID) <> @Expected
           OR (SELECT COUNT(DISTINCT MediaFamilyId) FROM #RBackups WHERE BackupSetGUID = @GUID) <> @Expected
            THROW 50021, N'Duplicate stripes, mirror copies, or invalid media metadata detected. Include only one copy per stripe sequence.', 1;

        SELECT @Devices = STUFF((
            SELECT N',' + @NL + N'    DISK = N''' + REPLACE(F.FilePath, N'''', N'''''') + N''''
            FROM #RBackups AS B JOIN #RFiles AS F ON F.ID = B.FileID
            WHERE B.BackupSetGUID = @GUID ORDER BY B.FamilySequenceNumber
            FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 3, N'');
        TRUNCATE TABLE #RFileList;
        SET @SQL = N'RESTORE FILELISTONLY FROM ' + @Devices
            + N' WITH FILE = ' + CONVERT(nvarchar(10), @Position) + N';';
        INSERT #RFileList EXEC sys.sp_executesql @SQL;
        IF NOT EXISTS (SELECT 1 FROM #RFileList)
            THROW 50022, N'FILELISTONLY returned no files.', 1;
        IF EXISTS (SELECT 1 FROM #RFileList WHERE [Type] NOT IN ('D','L') OR [Type] IS NULL
            OR ISNULL(IsPresent, 0) <> 1 OR LogicalName IS NULL OR PhysicalName IS NULL
            OR SnapshotURL IS NOT NULL)
            THROW 50023, N'Special containers, missing files, or snapshot URLs require manual MOVE rules. Only ordinary D/L files are handled.', 1;

        ;WITH Names AS
        (
            SELECT *, REPLACE(PhysicalName, N'/', N'\') AS Normalized FROM #RFileList
        )
        INSERT #RMap
        SELECT @DB, FileID, LogicalName, [Type], PhysicalName,
               CASE WHEN [Type] = 'L' THEN @LogPath ELSE @DataPath END
               + RIGHT(Normalized, CHARINDEX(N'\', REVERSE(Normalized) + N'\') - 1), [Size]
        FROM Names;
        IF EXISTS (SELECT 1 FROM #RMap WHERE DatabaseName = @DB AND
            (LEN(TargetPath) > 259 OR RIGHT(TargetPath, 1) IN (N'\', N'.', N' ')))
            THROW 50024, N'A target filename is empty, has an invalid ending, or exceeds the path length limit.', 1;
        IF EXISTS (SELECT 1 FROM #RMap WHERE DatabaseName = @DB
            GROUP BY TargetPath COLLATE Latin1_General_100_CI_AS HAVING COUNT(*) > 1)
            THROW 50025, N'This database has duplicate physical filenames that collide in the target directory. Define different filenames.', 1;
        IF EXISTS (SELECT 1 FROM #RMap AS M JOIN sys.master_files AS F
            ON M.TargetPath COLLATE Latin1_General_100_CI_AS = F.physical_name COLLATE Latin1_General_100_CI_AS
            WHERE M.DatabaseName = @DB
              AND (DB_ID(@DB) IS NULL OR F.database_id <> DB_ID(@DB)))
            THROW 50026, N'A MOVE target path is used by a different database on the current instance. Choose a different directory.', 1;
        IF @RunVerifyOnly = 1
        BEGIN
            SET @SQL = N'RESTORE VERIFYONLY FROM ' + @Devices
                + N' WITH FILE = ' + CONVERT(nvarchar(10), @Position) + N', STOP_ON_ERROR;';
            EXEC sys.sp_executesql @SQL;
        END;
        SELECT @Moves = (
            SELECT N',' + @NL + N'    MOVE N''' + REPLACE(LogicalName, N'''', N'''''')
                   + N''' TO N''' + REPLACE(TargetPath, N'''', N'''''') + N''''
            FROM #RMap WHERE DatabaseName = @DB ORDER BY FileID
            FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)');
        SET @Script = CAST(N'USE [master];' AS nvarchar(max)) + @NL
            + N'-- Full backup finish: ' + CONVERT(nvarchar(19), @Finish, 120) + @NL
            + N'IF DB_ID(N''' + REPLACE(@DB, N'''', N'''''') + N''') IS NOT NULL' + @NL
            + N'BEGIN' + @NL
            + N'    THROW 51000, N''Target database already exists; restore blocked.'', 1;' + @NL
            + N'END;' + @NL
            + N'RESTORE DATABASE ' + QUOTENAME(@DB) + @NL
            + N'FROM ' + @Devices + @NL
            + N'WITH FILE = ' + CONVERT(nvarchar(10), @Position) + @Moves + N',' + @NL
            + N'    RECOVERY,' + @NL + N'    STATS = 5;' + @NL + N'GO' + @NL;
        INSERT #RScripts VALUES (@DB, @Script);
        UPDATE #RLatest SET Status = N'Ready', Detail =
            CASE WHEN DB_ID(@DB) IS NOT NULL
                THEN N'Warning: database exists on the current instance. Script generated with an execution-time database existence guard. '
                ELSE N'' END
            + CASE WHEN @RunVerifyOnly = 1
            THEN N'Stripe metadata checks and VERIFYONLY passed; a test restore is still required.'
            ELSE N'Stripe metadata checks passed; VERIFYONLY and a test restore were not performed.' END
        WHERE DatabaseName = @DB;
    END TRY
    BEGIN CATCH
        UPDATE #RLatest SET Status = N'Blocked', Detail = ERROR_MESSAGE() WHERE DatabaseName = @DB;
        INSERT #RIssues VALUES (N'Database', @DB, ERROR_MESSAGE());
        DELETE FROM #RMap WHERE DatabaseName = @DB;
        DELETE FROM #RScripts WHERE DatabaseName = @DB;
    END CATCH;
    FETCH NEXT FROM RDBCursor INTO @DB, @GUID, @Finish;
END;
CLOSE RDBCursor;
DEALLOCATE RDBCursor;

/* Different databases may have identical filenames in separate source directories; block target collisions. */
UPDATE L SET Status = N'Blocked', Detail = N'Different databases have the same MOVE target path. Define different directories or filenames.'
FROM #RLatest AS L
WHERE EXISTS
(
    SELECT 1 FROM #RMap AS A JOIN #RMap AS B
      ON A.TargetPath COLLATE Latin1_General_100_CI_AS = B.TargetPath COLLATE Latin1_General_100_CI_AS
     AND A.DatabaseName <> B.DatabaseName
    WHERE A.DatabaseName = L.DatabaseName
);
DELETE S FROM #RScripts AS S JOIN #RLatest AS L ON L.DatabaseName = S.DatabaseName WHERE L.Status <> N'Ready';

/*==================== 4. Prepare lines within the Unicode PRINT length limit ====================*/
CREATE TABLE #RLines (ScriptLineNumber int IDENTITY PRIMARY KEY, ScriptLine nvarchar(4000));
DECLARE @Remaining nvarchar(max), @Break int;
DECLARE ROutputCursor CURSOR LOCAL FAST_FORWARD FOR SELECT RestoreScript FROM #RScripts ORDER BY DatabaseName;
OPEN ROutputCursor;
FETCH NEXT FROM ROutputCursor INTO @Remaining;
WHILE @@FETCH_STATUS = 0
BEGIN
    WHILE DATALENGTH(@Remaining) > 0
    BEGIN
        SET @Break = CHARINDEX(NCHAR(10), @Remaining);
        IF @Break = 0 SET @Break = LEN(@Remaining) + 1;
        IF @Break - 1 > 4000 THROW 50027, N'An output line is too long. Manual review is required.', 1;
        INSERT #RLines VALUES (REPLACE(LEFT(@Remaining, @Break - 1), NCHAR(13), N''));
        SET @Remaining = SUBSTRING(@Remaining, @Break + 1, 2147483647);
    END;
    INSERT #RLines VALUES (N'');
    FETCH NEXT FROM ROutputCursor INTO @Remaining;
END;
CLOSE ROutputCursor;
DEALLOCATE ROutputCursor;

-- Result 1: review Ready/Blocked status for every database. Do not ignore blocked databases.
SELECT DatabaseName, FinishTime AS BackupFinishDate, BackupSetGUID, Status, Detail
FROM #RLatest ORDER BY DatabaseName;
-- Result 2: original file paths and MOVE target mapping.
SELECT M.DatabaseName, L.Status, M.LogicalName, M.FileType, M.OriginalPath, M.TargetPath,
       CAST(M.SizeBytes / 1048576.0 AS decimal(20,2)) AS FileSizeMB
FROM #RMap AS M JOIN #RLatest AS L ON L.DatabaseName = M.DatabaseName
ORDER BY M.DatabaseName, M.FileID;
-- Result 3: warnings and errors. Empty directory results may indicate insufficient permissions; verify manually.
SELECT Stage, Item, Detail FROM #RIssues ORDER BY Stage, Item;

-- Print generated commands only; never execute them here.
IF EXISTS (SELECT 1 FROM #RScripts)
BEGIN
    PRINT N'-- BEGIN GENERATED RESTORE SCRIPT';
    DECLARE @PrintLine nvarchar(4000);
    DECLARE RPrintCursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT ScriptLine FROM #RLines ORDER BY ScriptLineNumber;
    OPEN RPrintCursor;
    FETCH NEXT FROM RPrintCursor INTO @PrintLine;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        PRINT @PrintLine;
        FETCH NEXT FROM RPrintCursor INTO @PrintLine;
    END;
    CLOSE RPrintCursor;
    DEALLOCATE RPrintCursor;
    PRINT N'-- END GENERATED RESTORE SCRIPT';
END
ELSE
    PRINT N'No restore scripts were generated. Review database status and warnings/errors.';
IF NOT EXISTS (SELECT 1 FROM #RLatest)
    PRINT N'No identifiable user database full backups were found.';
