/*
    Version 1 - Generate restore commands for the latest full backup of every
                identifiable user database under one backup root.

    Safety boundary
    ---------------
    This generator executes only these metadata-reading operations:
        RESTORE LABELONLY
        RESTORE HEADERONLY
        RESTORE FILELISTONLY

    It never executes RESTORE DATABASE.  RESTORE DATABASE statements are only
    stored in a local temporary table, returned as a result set, and printed.

    Supported target versions
    -------------------------
    SQL Server 2016 CU1 or later, including SQL Server 2017/2019/2022/2025.

    Version 1 assumptions
    ---------------------
    1. By default every file below @BackupRoot is inspected.  Set
       @BackupFileExtension when the root also contains non-backup files.
    2. Files belonging to one striped backup are all present below @BackupRoot.
    3. Mirrored backup media are not auto-selected.  Duplicate stripe sequence
       numbers block that database and require DBA review.
    4. Destination names are generated from DatabaseName, file type, and FileID
       so files from different source directories do not collide by basename.
    5. xp_dirtree is used because pure T-SQL has no documented recursive file
       system enumeration statement.  It is undocumented and should be tested
       on the target SQL Server version.
    6. The target is Windows SQL Server.  D/F/S entries are placed below the
       Data path; L entries are placed below the Log path.  F/S retain their
       source leaf directory name because they are directory-type containers.
    7. Each DatabaseName below the root belongs to one source database lineage.
       If multiple source instances are mixed, scan them separately.

    Microsoft references
    --------------------
    https://learn.microsoft.com/sql/t-sql/statements/restore-statements-labelonly-transact-sql
    https://learn.microsoft.com/sql/t-sql/statements/restore-statements-headeronly-transact-sql
    https://learn.microsoft.com/sql/t-sql/statements/restore-statements-filelistonly-transact-sql
    https://learn.microsoft.com/sql/relational-databases/backup-restore/media-sets-media-families-and-backup-sets-sql-server
*/

USE [master];
GO

SET NOCOUNT ON;

/*==========================================================================
  Configuration
============================================================================*/

DECLARE @BackupRoot nvarchar(4000) = N'T:\SQLServerBackup\data';

/*
    By default, use the target instance's configured default paths.
    A DBA can replace either expression with an explicit path, for example:
        N'D:\MSSQL\DATA\'
        N'L:\MSSQL\LOG\'
*/
DECLARE @TargetDataPath nvarchar(4000)
    = CONVERT(nvarchar(4000), SERVERPROPERTY('InstanceDefaultDataPath'));
DECLARE @TargetLogPath nvarchar(4000)
    = CONVERT(nvarchar(4000), SERVERPROPERTY('InstanceDefaultLogPath'));

/* NULL = inspect every file; for example, use N'.bak' to limit the scan. */
DECLARE @BackupFileExtension nvarchar(20) = NULL;
DECLARE @MaximumFolderDepth int = 32;

/* 1 = print the metadata commands immediately before the generator runs them. */
DECLARE @PrintMetadataSql bit = 1;

DECLARE @NewLine nchar(2) = NCHAR(13) + NCHAR(10);
DECLARE @ProductMajorVersion int
    = TRY_CONVERT(int, SERVERPROPERTY('ProductMajorVersion'));
DECLARE @ProductBuild int
    = TRY_CONVERT(int, PARSENAME(CONVERT(varchar(50), SERVERPROPERTY('ProductVersion')), 2));

/*==========================================================================
  Step 0: Validate configuration
============================================================================*/

IF @ProductMajorVersion IS NULL
BEGIN
    ;THROW 50001, N'Cannot identify the SQL Server major version.', 1;
END;

IF @ProductMajorVersion < 13
BEGIN
    ;THROW 50002, N'Version 1 supports SQL Server 2016 CU1 or later.', 1;
END;

IF @ProductMajorVersion > 17
BEGIN
    ;THROW 50030, N'This SQL Server version is newer than the HEADERONLY schema validated by Version 1.', 1;
END;

IF @ProductMajorVersion = 13 AND ISNULL(@ProductBuild, 0) < 2149
BEGIN
    ;THROW 50003, N'SQL Server 2016 must be CU1 or later for this FILELISTONLY schema.', 1;
END;

IF @@TRANCOUNT <> 0
BEGIN
    ;THROW 50033, N'Do not run this generator inside a user transaction.', 1;
END;

SET @BackupRoot = NULLIF(LTRIM(RTRIM(@BackupRoot)), N'');
SET @TargetDataPath = NULLIF(LTRIM(RTRIM(@TargetDataPath)), N'');
SET @TargetLogPath = NULLIF(LTRIM(RTRIM(@TargetLogPath)), N'');
SET @BackupFileExtension = NULLIF(LTRIM(RTRIM(@BackupFileExtension)), N'');

IF @BackupRoot IS NULL
BEGIN
    ;THROW 50004, N'@BackupRoot cannot be empty.', 1;
END;

IF @TargetDataPath IS NULL OR @TargetLogPath IS NULL
BEGIN
    ;THROW 50005, N'The target Data/Log path is unavailable. Set both paths explicitly in Configuration.', 1;
END;

IF CHARINDEX(NCHAR(13), @BackupRoot) > 0
   OR CHARINDEX(NCHAR(10), @BackupRoot) > 0
   OR CHARINDEX(NCHAR(13), @TargetDataPath) > 0
   OR CHARINDEX(NCHAR(10), @TargetDataPath) > 0
   OR CHARINDEX(NCHAR(13), @TargetLogPath) > 0
   OR CHARINDEX(NCHAR(10), @TargetLogPath) > 0
BEGIN
    ;THROW 50040, N'Configured paths cannot contain line-break characters.', 1;
END;

IF RIGHT(@BackupRoot, 1) <> N'\'
    SET @BackupRoot = @BackupRoot + N'\';

IF RIGHT(@TargetDataPath, 1) <> N'\'
    SET @TargetDataPath = @TargetDataPath + N'\';

IF RIGHT(@TargetLogPath, 1) <> N'\'
    SET @TargetLogPath = @TargetLogPath + N'\';

IF @TargetDataPath COLLATE Latin1_General_100_CI_AS
   = @TargetLogPath COLLATE Latin1_General_100_CI_AS
BEGIN
    ;THROW 50006, N'Data and Log destinations must be different directories.', 1;
END;

IF @MaximumFolderDepth < 1
BEGIN
    ;THROW 50007, N'@MaximumFolderDepth must be at least 1.', 1;
END;

/*
    The DROP statements below affect local temporary tables only.  No permanent
    database object is dropped or altered by this generator.
*/
IF OBJECT_ID('tempdb..#FoldersToScan') IS NOT NULL DROP TABLE #FoldersToScan;
IF OBJECT_ID('tempdb..#DirectoryEntries') IS NOT NULL DROP TABLE #DirectoryEntries;
IF OBJECT_ID('tempdb..#BackupFiles') IS NOT NULL DROP TABLE #BackupFiles;
IF OBJECT_ID('tempdb..#BackupMediaLabel') IS NOT NULL DROP TABLE #BackupMediaLabel;
IF OBJECT_ID('tempdb..#BackupHeader') IS NOT NULL DROP TABLE #BackupHeader;
IF OBJECT_ID('tempdb..#BackupInventory') IS NOT NULL DROP TABLE #BackupInventory;
IF OBJECT_ID('tempdb..#GeneratorIssues') IS NOT NULL DROP TABLE #GeneratorIssues;
IF OBJECT_ID('tempdb..#DatabaseList') IS NOT NULL DROP TABLE #DatabaseList;
IF OBJECT_ID('tempdb..#LatestBackups') IS NOT NULL DROP TABLE #LatestBackups;
IF OBJECT_ID('tempdb..#SelectedStripes') IS NOT NULL DROP TABLE #SelectedStripes;
IF OBJECT_ID('tempdb..#BackupFileList') IS NOT NULL DROP TABLE #BackupFileList;
IF OBJECT_ID('tempdb..#MoveMap') IS NOT NULL DROP TABLE #MoveMap;
IF OBJECT_ID('tempdb..#GeneratedRestoreCommands') IS NOT NULL DROP TABLE #GeneratedRestoreCommands;

/*==========================================================================
  Step 1: Get backup files
============================================================================*/

/*
    #FoldersToScan is a queue of directories.  The WHILE loop lets the script
    support nested subdirectories without a recursive CTE.
*/
CREATE TABLE #FoldersToScan
(
    FolderID int IDENTITY(1,1) NOT NULL PRIMARY KEY,
    FolderPath nvarchar(4000) NOT NULL,
    FolderDepth int NOT NULL,
    IsProcessed bit NOT NULL DEFAULT (0)
);

/*
    #DirectoryEntries temporarily receives one directory level from xp_dirtree.
*/
CREATE TABLE #DirectoryEntries
(
    EntryName nvarchar(512) NULL,
    EntryDepth int NULL,
    IsFile bit NULL
);

/*
    #BackupFiles contains every distinct candidate file found below @BackupRoot.
*/
CREATE TABLE #BackupFiles
(
    BackupFileID int IDENTITY(1,1) NOT NULL PRIMARY KEY,
    BackupFilePath nvarchar(4000) NOT NULL
);

/*
    #GeneratorIssues records files or databases that require DBA attention.
*/
CREATE TABLE #GeneratorIssues
(
    IssueID int IDENTITY(1,1) NOT NULL PRIMARY KEY,
    Severity varchar(10) NOT NULL,
    StepName varchar(30) NOT NULL,
    ItemName nvarchar(4000) NULL,
    IssueMessage nvarchar(4000) NOT NULL
);

INSERT INTO #FoldersToScan
(
    FolderPath,
    FolderDepth
)
VALUES
(
    @BackupRoot,
    0
);

DECLARE @CurrentFolderID int;
DECLARE @CurrentFolderPath nvarchar(4000);
DECLARE @CurrentFolderDepth int;

SELECT @CurrentFolderID = MIN(FolderID)
FROM #FoldersToScan
WHERE IsProcessed = 0;

WHILE @CurrentFolderID IS NOT NULL
BEGIN
    SELECT
        @CurrentFolderPath = FolderPath,
        @CurrentFolderDepth = FolderDepth
    FROM #FoldersToScan
    WHERE FolderID = @CurrentFolderID;

    UPDATE #FoldersToScan
    SET IsProcessed = 1
    WHERE FolderID = @CurrentFolderID;

    DELETE FROM #DirectoryEntries;

    BEGIN TRY
        /*
            xp_dirtree is executed only for directory discovery.
            Depth = 1 means one level is read each time; subfolders are queued.
        */
        INSERT INTO #DirectoryEntries
        (
            EntryName,
            EntryDepth,
            IsFile
        )
        EXEC master.sys.xp_dirtree @CurrentFolderPath, 1, 1;

        IF EXISTS
        (
            SELECT 1
            FROM #DirectoryEntries
            WHERE LEN
                  (
                      CONVERT(nvarchar(max), @CurrentFolderPath)
                      + ISNULL(EntryName, N'')
                      + CASE WHEN IsFile = 0 THEN N'\' ELSE N'' END
                  ) > 4000
        )
        BEGIN
            ;THROW 50039, N'A discovered path exceeds the generator 4,000-character limit.', 1;
        END;

        INSERT INTO #BackupFiles
        (
            BackupFilePath
        )
        SELECT
            CONVERT(nvarchar(max), @CurrentFolderPath) + EntryName
        FROM #DirectoryEntries
        WHERE IsFile = 1
          AND
          (
              @BackupFileExtension IS NULL
              OR LOWER(RIGHT(EntryName, LEN(@BackupFileExtension)))
                 = LOWER(@BackupFileExtension)
          )
          AND NOT EXISTS
              (
                  SELECT 1
                  FROM #BackupFiles AS ExistingFile
                  WHERE ExistingFile.BackupFilePath
                        = CONVERT(nvarchar(max), @CurrentFolderPath) + EntryName
              );

        IF @CurrentFolderDepth >= @MaximumFolderDepth
           AND EXISTS
               (
                   SELECT 1
                   FROM #DirectoryEntries
                   WHERE IsFile = 0
               )
        BEGIN
            ;THROW 50008, N'The configured folder depth limit was reached.', 1;
        END;

        INSERT INTO #FoldersToScan
        (
            FolderPath,
            FolderDepth
        )
        SELECT
            CONVERT(nvarchar(max), @CurrentFolderPath) + EntryName + N'\',
            @CurrentFolderDepth + 1
        FROM #DirectoryEntries
        WHERE IsFile = 0
          AND EntryName NOT IN (N'.', N'..')
          AND NOT EXISTS
              (
                  SELECT 1
                  FROM #FoldersToScan AS ExistingFolder
                  WHERE ExistingFolder.FolderPath
                        = CONVERT(nvarchar(max), @CurrentFolderPath) + EntryName + N'\'
              );
    END TRY
    BEGIN CATCH
        INSERT INTO #GeneratorIssues
        (
            Severity,
            StepName,
            ItemName,
            IssueMessage
        )
        VALUES
        (
            'ERROR',
            'Step 1',
            @CurrentFolderPath,
            ERROR_MESSAGE()
        );
    END CATCH;

    SET @CurrentFolderID = NULL;

    SELECT @CurrentFolderID = MIN(FolderID)
    FROM #FoldersToScan
    WHERE IsProcessed = 0;
END;

IF EXISTS
(
    SELECT 1
    FROM #GeneratorIssues
    WHERE StepName = 'Step 1'
      AND Severity = 'ERROR'
)
BEGIN
    SELECT Severity, StepName, ItemName, IssueMessage
    FROM #GeneratorIssues
    ORDER BY IssueID;

    ;THROW 50009, N'Directory scan failed. No restore command was generated.', 1;
END;

IF NOT EXISTS (SELECT 1 FROM #BackupFiles)
BEGIN
    ;THROW 50010, N'No candidate files were found. Check the root path, extension filter, and SQL Server service account permissions.', 1;
END;

IF EXISTS
(
    SELECT 1
    FROM #BackupFiles
    WHERE LEN(BackupFilePath) > 259
)
BEGIN
    ;THROW 50041, N'A backup path exceeds the conservative 259-character limit used by Version 1.', 1;
END;

/*==========================================================================
  Step 2: Read backup metadata and identify full backup sets
============================================================================*/

/*
    #BackupMediaLabel temporarily receives RESTORE LABELONLY output.
    FamilyCount and FamilySequenceNumber identify striped backup files.
*/
CREATE TABLE #BackupMediaLabel
(
    MediaName nvarchar(128) NULL,
    MediaSetId uniqueidentifier NULL,
    FamilyCount int NULL,
    FamilySequenceNumber int NULL,
    MediaFamilyId uniqueidentifier NULL,
    MediaSequenceNumber int NULL,
    MediaLabelPresent tinyint NULL,
    MediaDescription nvarchar(255) NULL,
    SoftwareName nvarchar(128) NULL,
    SoftwareVendorId int NULL,
    MediaDate datetime NULL,
    Mirror_Count int NULL,
    IsCompressed bit NULL
);

/*
    #BackupHeader temporarily receives RESTORE HEADERONLY output.
    SQL Server 2022+ returns three additional columns, added below only to this
    local temporary table.
*/
CREATE TABLE #BackupHeader
(
    BackupName nvarchar(128) NULL,
    BackupDescription nvarchar(255) NULL,
    BackupType smallint NULL,
    ExpirationDate datetime NULL,
    Compressed bit NULL,
    Position smallint NULL,
    DeviceType tinyint NULL,
    UserName nvarchar(128) NULL,
    ServerName nvarchar(128) NULL,
    DatabaseName nvarchar(128) NULL,
    DatabaseVersion int NULL,
    DatabaseCreationDate datetime NULL,
    BackupSize numeric(20,0) NULL,
    FirstLSN numeric(25,0) NULL,
    LastLSN numeric(25,0) NULL,
    CheckpointLSN numeric(25,0) NULL,
    DatabaseBackupLSN numeric(25,0) NULL,
    BackupStartDate datetime NULL,
    BackupFinishDate datetime NULL,
    SortOrder smallint NULL,
    CodePage smallint NULL,
    UnicodeLocaleId int NULL,
    UnicodeComparisonStyle int NULL,
    CompatibilityLevel tinyint NULL,
    SoftwareVendorId int NULL,
    SoftwareVersionMajor int NULL,
    SoftwareVersionMinor int NULL,
    SoftwareVersionBuild int NULL,
    MachineName nvarchar(128) NULL,
    Flags int NULL,
    BindingID uniqueidentifier NULL,
    RecoveryForkID uniqueidentifier NULL,
    Collation nvarchar(128) NULL,
    FamilyGUID uniqueidentifier NULL,
    HasBulkLoggedData bit NULL,
    IsSnapshot bit NULL,
    IsReadOnly bit NULL,
    IsSingleUser bit NULL,
    HasBackupChecksums bit NULL,
    IsDamaged bit NULL,
    BeginsLogChain bit NULL,
    HasIncompleteMetaData bit NULL,
    IsForceOffline bit NULL,
    IsCopyOnly bit NULL,
    FirstRecoveryForkID uniqueidentifier NULL,
    ForkPointLSN numeric(25,0) NULL,
    RecoveryModel nvarchar(60) NULL,
    DifferentialBaseLSN numeric(25,0) NULL,
    DifferentialBaseGUID uniqueidentifier NULL,
    BackupTypeDescription nvarchar(60) NULL,
    BackupSetGUID uniqueidentifier NULL,
    CompressedBackupSize bigint NULL,
    Containment tinyint NULL,
    KeyAlgorithm nvarchar(32) NULL,
    EncryptorThumbprint varbinary(20) NULL,
    EncryptorType nvarchar(32) NULL
);

IF @ProductMajorVersion >= 16
BEGIN
    ALTER TABLE #BackupHeader ADD
        LastValidRestoreTime datetime NULL,
        TimeZone nvarchar(32) NULL,
        CompressionAlgorithm nvarchar(32) NULL;
END;

/*
    #BackupInventory is the normalized inventory used by the rest of the script.
    One row represents one backup set header found on one physical backup file.
*/
CREATE TABLE #BackupInventory
(
    BackupFileID int NOT NULL,
    BackupFilePath nvarchar(4000) NOT NULL,
    DatabaseName nvarchar(128) COLLATE Latin1_General_100_BIN2 NOT NULL,
    SourceServerName nvarchar(128) NULL,
    DatabaseFamilyGUID uniqueidentifier NULL,
    BackupSetGUID uniqueidentifier NULL,
    BackupPosition int NOT NULL,
    BackupStartDate datetime NULL,
    BackupFinishDate datetime NOT NULL,
    CheckpointLSN numeric(25,0) NULL,
    SourceVersionMajor int NULL,
    IsDamaged bit NULL,
    IsSnapshot bit NULL,
    IsCopyOnly bit NULL,
    MediaSetId uniqueidentifier NULL,
    ExpectedStripeCount int NULL,
    StripeSequenceNumber int NULL,
    MediaFamilyId uniqueidentifier NULL,
    MirrorCount int NULL,
    IsSelected bit NOT NULL DEFAULT (0)
);

DECLARE @CurrentBackupFileID int;
DECLARE @LastBackupFileID int;
DECLARE @BackupFilePath nvarchar(4000);
DECLARE @MetadataSql nvarchar(max);
DECLARE @PrintPosition int;
DECLARE @NextLinePosition int;
DECLARE @PrintLine nvarchar(4000);

SELECT @CurrentBackupFileID = MIN(BackupFileID)
FROM #BackupFiles;

WHILE @CurrentBackupFileID IS NOT NULL
BEGIN
    SELECT @BackupFilePath = BackupFilePath
    FROM #BackupFiles
    WHERE BackupFileID = @CurrentBackupFileID;

    DELETE FROM #BackupMediaLabel;
    DELETE FROM #BackupHeader;

    BEGIN TRY
        /*
            Dynamic SQL is required because INSERT...EXEC must capture the
            RESTORE LABELONLY result set.  This command reads metadata only.
        */
        SET @MetadataSql =
            CONVERT(nvarchar(max), N'RESTORE LABELONLY FROM DISK = N''')
            + REPLACE(CONVERT(nvarchar(max), @BackupFilePath), N'''', N'''''' )
            + N''';';

        IF @PrintMetadataSql = 1
        BEGIN
            PRINT N'-- Metadata read: LABELONLY';
            PRINT @MetadataSql;
        END;

        INSERT INTO #BackupMediaLabel
        EXEC sys.sp_executesql @MetadataSql;

        IF (SELECT COUNT(*) FROM #BackupMediaLabel) <> 1
        BEGIN
            ;THROW 50011, N'RESTORE LABELONLY did not return exactly one row.', 1;
        END;

        /*
            Dynamic SQL is required because INSERT...EXEC must capture the
            RESTORE HEADERONLY result set.  This command reads metadata only.
        */
        SET @MetadataSql =
            CONVERT(nvarchar(max), N'RESTORE HEADERONLY FROM DISK = N''')
            + REPLACE(CONVERT(nvarchar(max), @BackupFilePath), N'''', N'''''' )
            + N''';';

        IF @PrintMetadataSql = 1
        BEGIN
            PRINT N'-- Metadata read: HEADERONLY';
            PRINT @MetadataSql;
        END;

        INSERT INTO #BackupHeader
        EXEC sys.sp_executesql @MetadataSql;

        IF NOT EXISTS (SELECT 1 FROM #BackupHeader)
        BEGIN
            ;THROW 50012, N'RESTORE HEADERONLY returned no rows.', 1;
        END;

        INSERT INTO #GeneratorIssues
        (
            Severity,
            StepName,
            ItemName,
            IssueMessage
        )
        SELECT
            'ERROR',
            'Step 2',
            @BackupFilePath,
            N'A full backup header was found but database name, MediaSetId, position, or finish time is missing; the backup set cannot be grouped safely.'
        FROM #BackupHeader AS BackupHeader
        CROSS JOIN #BackupMediaLabel AS BackupMediaLabel
        WHERE BackupType = 1
          AND
          (
              DatabaseName IS NULL
              OR DatabaseName COLLATE Latin1_General_100_CI_AS
                 NOT IN (N'master', N'model', N'msdb', N'tempdb')
          )
          AND
          (
              DatabaseName IS NULL
              OR Position IS NULL
              OR BackupFinishDate IS NULL
              OR BackupMediaLabel.MediaSetId IS NULL
          );

        INSERT INTO #BackupInventory
        (
            BackupFileID,
            BackupFilePath,
            DatabaseName,
            SourceServerName,
            DatabaseFamilyGUID,
            BackupSetGUID,
            BackupPosition,
            BackupStartDate,
            BackupFinishDate,
            CheckpointLSN,
            SourceVersionMajor,
            IsDamaged,
            IsSnapshot,
            IsCopyOnly,
            MediaSetId,
            ExpectedStripeCount,
            StripeSequenceNumber,
            MediaFamilyId,
            MirrorCount
        )
        SELECT
            @CurrentBackupFileID,
            @BackupFilePath,
            BackupHeader.DatabaseName,
            BackupHeader.ServerName,
            BackupHeader.FamilyGUID,
            BackupHeader.BackupSetGUID,
            BackupHeader.Position,
            BackupHeader.BackupStartDate,
            BackupHeader.BackupFinishDate,
            BackupHeader.CheckpointLSN,
            BackupHeader.SoftwareVersionMajor,
            BackupHeader.IsDamaged,
            BackupHeader.IsSnapshot,
            BackupHeader.IsCopyOnly,
            BackupMediaLabel.MediaSetId,
            BackupMediaLabel.FamilyCount,
            BackupMediaLabel.FamilySequenceNumber,
            BackupMediaLabel.MediaFamilyId,
            BackupMediaLabel.Mirror_Count
        FROM #BackupHeader AS BackupHeader
        CROSS JOIN #BackupMediaLabel AS BackupMediaLabel
        WHERE BackupHeader.BackupType = 1
          AND BackupHeader.DatabaseName COLLATE Latin1_General_100_CI_AS
              NOT IN (N'master', N'model', N'msdb', N'tempdb')
          AND BackupHeader.DatabaseName IS NOT NULL
          AND BackupHeader.Position IS NOT NULL
          AND BackupHeader.BackupFinishDate IS NOT NULL
          AND BackupMediaLabel.MediaSetId IS NOT NULL;
    END TRY
    BEGIN CATCH
        INSERT INTO #GeneratorIssues
        (
            Severity,
            StepName,
            ItemName,
            IssueMessage
        )
        VALUES
        (
            'ERROR',
            'Step 2',
            @BackupFilePath,
            ERROR_MESSAGE()
        );
    END CATCH;

    SET @LastBackupFileID = @CurrentBackupFileID;
    SET @CurrentBackupFileID = NULL;

    SELECT @CurrentBackupFileID = MIN(BackupFileID)
    FROM #BackupFiles
    WHERE BackupFileID > @LastBackupFileID;
END;

/*
    Any unreadable candidate file could be the newest backup.  Stop here instead
    of silently selecting an older readable backup.  If the root contains other
    file types, set @BackupFileExtension in Configuration and rerun.
*/
IF EXISTS
(
    SELECT 1
    FROM #GeneratorIssues
    WHERE StepName = 'Step 2'
      AND Severity = 'ERROR'
)
BEGIN
    SELECT Severity, StepName, ItemName, IssueMessage
    FROM #GeneratorIssues
    ORDER BY IssueID;

    ;THROW 50013, N'Backup metadata errors were found. No restore command was generated.', 1;
END;

IF NOT EXISTS (SELECT 1 FROM #BackupInventory)
BEGIN
    ;THROW 50014, N'No identifiable user database full backup was found.', 1;
END;

/*==========================================================================
  Step 3: Identify the latest full backup for each database
============================================================================*/

/*
    #DatabaseList is a simple loop list.  It replaces a cursor and a window
    function when selecting one latest backup per database.
*/
CREATE TABLE #DatabaseList
(
    DatabaseRowID int IDENTITY(1,1) NOT NULL PRIMARY KEY,
    DatabaseName nvarchar(128) COLLATE Latin1_General_100_BIN2 NOT NULL
);

/*
    #LatestBackups stores the chosen full backup and its generation status.
    Status remains Blocked if the selected latest set is incomplete or unsafe.
*/
CREATE TABLE #LatestBackups
(
    LatestBackupID int IDENTITY(1,1) NOT NULL PRIMARY KEY,
    DatabaseName nvarchar(128) COLLATE Latin1_General_100_BIN2 NOT NULL,
    SourceServerName nvarchar(128) NULL,
    DatabaseFamilyGUID uniqueidentifier NULL,
    MediaSetId uniqueidentifier NOT NULL,
    BackupSetGUID uniqueidentifier NULL,
    BackupPosition int NOT NULL,
    BackupStartDate datetime NULL,
    BackupFinishDate datetime NOT NULL,
    CheckpointLSN numeric(25,0) NULL,
    GenerationStatus varchar(20) NOT NULL,
    StatusMessage nvarchar(4000) NULL
);

INSERT INTO #DatabaseList
(
    DatabaseName
)
SELECT DISTINCT
    DatabaseName
FROM #BackupInventory;

DECLARE @CurrentDatabaseRowID int;
DECLARE @LastDatabaseRowID int;
DECLARE @DatabaseName nvarchar(128);
DECLARE @SourceServerName nvarchar(128);
DECLARE @DatabaseFamilyGUID uniqueidentifier;
DECLARE @MediaSetId uniqueidentifier;
DECLARE @BackupSetGUID uniqueidentifier;
DECLARE @BackupPosition int;
DECLARE @BackupStartDate datetime;
DECLARE @BackupFinishDate datetime;
DECLARE @CheckpointLSN numeric(25,0);

SELECT @CurrentDatabaseRowID = MIN(DatabaseRowID)
FROM #DatabaseList;

WHILE @CurrentDatabaseRowID IS NOT NULL
BEGIN
    SELECT @DatabaseName = DatabaseName
    FROM #DatabaseList
    WHERE DatabaseRowID = @CurrentDatabaseRowID;

    SET @SourceServerName = NULL;
    SET @DatabaseFamilyGUID = NULL;
    SET @MediaSetId = NULL;
    SET @BackupSetGUID = NULL;
    SET @BackupPosition = NULL;
    SET @BackupStartDate = NULL;
    SET @BackupFinishDate = NULL;
    SET @CheckpointLSN = NULL;

    SELECT TOP (1)
        @SourceServerName = SourceServerName,
        @DatabaseFamilyGUID = DatabaseFamilyGUID,
        @MediaSetId = MediaSetId,
        @BackupSetGUID = BackupSetGUID,
        @BackupPosition = BackupPosition,
        @BackupStartDate = BackupStartDate,
        @BackupFinishDate = BackupFinishDate,
        @CheckpointLSN = CheckpointLSN
    FROM #BackupInventory
    WHERE DatabaseName = @DatabaseName
    ORDER BY
        BackupFinishDate DESC,
        BackupStartDate DESC,
        CheckpointLSN DESC,
        BackupSetGUID DESC;

    /*
        Mark the physical rows belonging to the selected set.  MediaSetId,
        Position, finish time, CheckpointLSN, and the nullable BackupSetGUID
        form the Version 1 identity; this also supports older NULL GUID headers.
    */
    UPDATE #BackupInventory
    SET IsSelected = 1
    WHERE DatabaseName = @DatabaseName
      AND MediaSetId = @MediaSetId
      AND BackupPosition = @BackupPosition
      AND BackupFinishDate = @BackupFinishDate
      AND
      (
          CheckpointLSN = @CheckpointLSN
          OR (CheckpointLSN IS NULL AND @CheckpointLSN IS NULL)
      )
      AND
      (
          BackupSetGUID = @BackupSetGUID
          OR (BackupSetGUID IS NULL AND @BackupSetGUID IS NULL)
      );

    INSERT INTO #LatestBackups
    (
        DatabaseName,
        SourceServerName,
        DatabaseFamilyGUID,
        MediaSetId,
        BackupSetGUID,
        BackupPosition,
        BackupStartDate,
        BackupFinishDate,
        CheckpointLSN,
        GenerationStatus,
        StatusMessage
    )
    VALUES
    (
        @DatabaseName,
        @SourceServerName,
        @DatabaseFamilyGUID,
        @MediaSetId,
        @BackupSetGUID,
        @BackupPosition,
        @BackupStartDate,
        @BackupFinishDate,
        @CheckpointLSN,
        'Pending',
        NULL
    );

    SET @LastDatabaseRowID = @CurrentDatabaseRowID;
    SET @CurrentDatabaseRowID = NULL;

    SELECT @CurrentDatabaseRowID = MIN(DatabaseRowID)
    FROM #DatabaseList
    WHERE DatabaseRowID > @LastDatabaseRowID;
END;

/*==========================================================================
  Step 4: Generate RESTORE DATABASE commands with all stripes and WITH MOVE
============================================================================*/

/*
    #SelectedStripes temporarily stores the validated files for one backup set,
    ordered by its media family sequence number.
*/
CREATE TABLE #SelectedStripes
(
    StripeSequenceNumber int NOT NULL PRIMARY KEY,
    BackupFilePath nvarchar(4000) NOT NULL
);

/*
    #BackupFileList temporarily receives RESTORE FILELISTONLY output for the
    selected backup set.
*/
CREATE TABLE #BackupFileList
(
    LogicalName nvarchar(128) NULL,
    PhysicalName nvarchar(260) NULL,
    [Type] char(1) NULL,
    FileGroupName nvarchar(128) NULL,
    [Size] numeric(20,0) NULL,
    MaxSize numeric(20,0) NULL,
    FileID bigint NULL,
    CreateLSN numeric(25,0) NULL,
    DropLSN numeric(25,0) NULL,
    UniqueID uniqueidentifier NULL,
    ReadOnlyLSN numeric(25,0) NULL,
    ReadWriteLSN numeric(25,0) NULL,
    BackupSizeInBytes bigint NULL,
    SourceBlockSize int NULL,
    FileGroupID int NULL,
    LogGroupGUID uniqueidentifier NULL,
    DifferentialBaseLSN numeric(25,0) NULL,
    DifferentialBaseGUID uniqueidentifier NULL,
    IsReadOnly bit NULL,
    IsPresent bit NULL,
    TDEThumbprint varbinary(32) NULL,
    SnapshotURL nvarchar(360) NULL
);

/*
    #MoveMap is the DBA review list for logical file to destination path mapping.
*/
CREATE TABLE #MoveMap
(
    DatabaseName nvarchar(128) COLLATE Latin1_General_100_BIN2 NOT NULL,
    FileID bigint NOT NULL,
    LogicalName nvarchar(128) NOT NULL,
    FileType char(1) NOT NULL,
    OriginalPhysicalPath nvarchar(260) NOT NULL,
    TargetPhysicalPath nvarchar(4000) NOT NULL,
    FileSizeBytes numeric(20,0) NULL
);

/*
    #GeneratedRestoreCommands stores complete nvarchar(max) commands.  No value
    from this table is ever passed to EXEC or sp_executesql.
*/
CREATE TABLE #GeneratedRestoreCommands
(
    RestoreCommandID int IDENTITY(1,1) NOT NULL PRIMARY KEY,
    DatabaseName nvarchar(128) COLLATE Latin1_General_100_BIN2 NOT NULL,
    RestoreCommand nvarchar(max) NOT NULL
);

DECLARE @CurrentLatestBackupID int;
DECLARE @LastLatestBackupID int;
DECLARE @ExpectedStripeCount int;
DECLARE @StripeSequenceNumber int;
DECLARE @LastStripeSequenceNumber int;
DECLARE @SourceVersionMajor int;
DECLARE @IsDamaged bit;
DECLARE @IsSnapshot bit;
DECLARE @BackupDeviceList nvarchar(max);
DECLARE @RestoreCommand nvarchar(max);
DECLARE @MoveClause nvarchar(max);
DECLARE @CurrentLogicalFileID bigint;
DECLARE @LastLogicalFileID bigint;
DECLARE @LogicalName nvarchar(128);
DECLARE @OriginalPhysicalPath nvarchar(260);
DECLARE @SafeDatabaseFilePrefix nvarchar(128);
DECLARE @TargetFileName nvarchar(260);
DECLARE @FileType char(1);
DECLARE @FileSizeBytes numeric(20,0);
DECLARE @TargetPhysicalPath nvarchar(max);
DECLARE @ControlCharacterCode int;

SELECT @CurrentLatestBackupID = MIN(LatestBackupID)
FROM #LatestBackups;

WHILE @CurrentLatestBackupID IS NOT NULL
BEGIN
    SELECT
        @DatabaseName = DatabaseName,
        @SourceServerName = SourceServerName,
        @DatabaseFamilyGUID = DatabaseFamilyGUID,
        @MediaSetId = MediaSetId,
        @BackupSetGUID = BackupSetGUID,
        @BackupPosition = BackupPosition,
        @BackupStartDate = BackupStartDate,
        @BackupFinishDate = BackupFinishDate,
        @CheckpointLSN = CheckpointLSN
    FROM #LatestBackups
    WHERE LatestBackupID = @CurrentLatestBackupID;

    SET @ExpectedStripeCount = NULL;
    SET @SourceVersionMajor = NULL;
    SET @IsDamaged = NULL;
    SET @IsSnapshot = NULL;
    SET @BackupDeviceList = N'';
    SET @MoveClause = N'';
    SET @RestoreCommand = NULL;

    DELETE FROM #SelectedStripes;
    DELETE FROM #BackupFileList;

    BEGIN TRY
        IF CHARINDEX(NCHAR(13), @DatabaseName) > 0
           OR CHARINDEX(NCHAR(10), @DatabaseName) > 0
        BEGIN
            ;THROW 50034, N'The database name contains a line-break character and requires manual review.', 1;
        END;

        IF @DatabaseFamilyGUID IS NOT NULL
           AND EXISTS
               (
                   SELECT 1
                   FROM #BackupInventory
                   WHERE DatabaseName = @DatabaseName
                     AND DatabaseFamilyGUID IS NOT NULL
                     AND DatabaseFamilyGUID <> @DatabaseFamilyGUID
               )
        BEGIN
            INSERT INTO #GeneratorIssues
            (
                Severity,
                StepName,
                ItemName,
                IssueMessage
            )
            VALUES
            (
                'WARNING',
                'Step 4',
                @DatabaseName,
                N'Multiple database FamilyGUID values were found for this name. The newest set was selected; confirm the source lineage.'
            );
        END;

        SELECT TOP (1)
            @ExpectedStripeCount = ExpectedStripeCount,
            @SourceVersionMajor = SourceVersionMajor,
            @IsDamaged = IsDamaged,
            @IsSnapshot = IsSnapshot
        FROM #BackupInventory
        WHERE DatabaseName = @DatabaseName
          AND IsSelected = 1
        ORDER BY StripeSequenceNumber;

        IF @MediaSetId IS NULL
           OR @ExpectedStripeCount IS NULL
           OR @ExpectedStripeCount < 1
           OR @ExpectedStripeCount > 64
        BEGIN
            ;THROW 50015, N'The latest backup has invalid media-set or stripe-count metadata.', 1;
        END;

        IF ISNULL(@IsDamaged, 1) <> 0
        BEGIN
            ;THROW 50016, N'The latest full backup is marked as damaged.', 1;
        END;

        IF ISNULL(@IsSnapshot, 1) <> 0
        BEGIN
            ;THROW 50017, N'The latest full backup is a snapshot backup and is outside Version 1 scope.', 1;
        END;

        IF @SourceVersionMajor IS NULL
           OR @SourceVersionMajor > @ProductMajorVersion
        BEGIN
            ;THROW 50018, N'The backup source version is unknown or newer than this target instance.', 1;
        END;

        IF EXISTS
        (
            SELECT 1
            FROM #BackupInventory
            WHERE DatabaseName = @DatabaseName
              AND IsSelected = 1
              AND
              (
                  MediaSetId IS NULL
                  OR MediaSetId <> @MediaSetId
                  OR ExpectedStripeCount IS NULL
                  OR ExpectedStripeCount <> @ExpectedStripeCount
                  OR BackupPosition <> @BackupPosition
                  OR
                  (
                      BackupStartDate <> @BackupStartDate
                      OR (BackupStartDate IS NULL AND @BackupStartDate IS NOT NULL)
                      OR (BackupStartDate IS NOT NULL AND @BackupStartDate IS NULL)
                  )
                  OR BackupFinishDate <> @BackupFinishDate
                  OR
                  (
                      DatabaseFamilyGUID <> @DatabaseFamilyGUID
                      OR (DatabaseFamilyGUID IS NULL AND @DatabaseFamilyGUID IS NOT NULL)
                      OR (DatabaseFamilyGUID IS NOT NULL AND @DatabaseFamilyGUID IS NULL)
                  )
                  OR
                  (
                      SourceServerName <> @SourceServerName
                      OR (SourceServerName IS NULL AND @SourceServerName IS NOT NULL)
                      OR (SourceServerName IS NOT NULL AND @SourceServerName IS NULL)
                  )
                  OR StripeSequenceNumber IS NULL
                  OR StripeSequenceNumber < 1
                  OR StripeSequenceNumber > @ExpectedStripeCount
                  OR SourceVersionMajor IS NULL
                  OR SourceVersionMajor <> @SourceVersionMajor
                  OR ISNULL(IsDamaged, 1) <> ISNULL(@IsDamaged, 1)
                  OR ISNULL(IsSnapshot, 1) <> ISNULL(@IsSnapshot, 1)
              )
        )
        BEGIN
            ;THROW 50019, N'The latest backup has inconsistent header or media-family metadata.', 1;
        END;

        IF
        (
            SELECT COUNT(*)
            FROM #BackupInventory
            WHERE DatabaseName = @DatabaseName
              AND IsSelected = 1
        ) <> @ExpectedStripeCount
        BEGIN
            ;THROW 50020, N'The latest full backup is missing stripes or contains duplicate/mirrored stripe files.', 1;
        END;

        IF
        (
            SELECT COUNT(DISTINCT StripeSequenceNumber)
            FROM #BackupInventory
            WHERE DatabaseName = @DatabaseName
              AND IsSelected = 1
        ) <> @ExpectedStripeCount
        BEGIN
            ;THROW 50021, N'The latest full backup does not contain exactly one file for every stripe sequence.', 1;
        END;

        IF
        (
            SELECT COUNT(DISTINCT MediaFamilyId)
            FROM #BackupInventory
            WHERE DatabaseName = @DatabaseName
              AND IsSelected = 1
        ) <> @ExpectedStripeCount
        BEGIN
            ;THROW 50031, N'The latest full backup has missing or duplicate media-family identifiers.', 1;
        END;

        IF EXISTS
        (
            SELECT 1
            FROM #BackupInventory
            WHERE DatabaseName = @DatabaseName
              AND BackupFinishDate = @BackupFinishDate
              AND IsSelected = 0
        )
        BEGIN
            ;THROW 50022, N'Multiple full backup sets have the same latest finish time. Select the intended set manually.', 1;
        END;

        INSERT INTO #SelectedStripes
        (
            StripeSequenceNumber,
            BackupFilePath
        )
        SELECT
            StripeSequenceNumber,
            BackupFilePath
        FROM #BackupInventory
        WHERE DatabaseName = @DatabaseName
          AND IsSelected = 1;

        SELECT @StripeSequenceNumber = MIN(StripeSequenceNumber)
        FROM #SelectedStripes;

        WHILE @StripeSequenceNumber IS NOT NULL
        BEGIN
            SELECT @BackupFilePath = BackupFilePath
            FROM #SelectedStripes
            WHERE StripeSequenceNumber = @StripeSequenceNumber;

            IF LEN(@BackupDeviceList) > 0
                SET @BackupDeviceList = @BackupDeviceList + N',' + @NewLine;

            SET @BackupDeviceList = @BackupDeviceList
                + N'    DISK = N'''
                + REPLACE(CONVERT(nvarchar(max), @BackupFilePath), N'''', N'''''' )
                + N'''';

            SET @LastStripeSequenceNumber = @StripeSequenceNumber;
            SET @StripeSequenceNumber = NULL;

            SELECT @StripeSequenceNumber = MIN(StripeSequenceNumber)
            FROM #SelectedStripes
            WHERE StripeSequenceNumber > @LastStripeSequenceNumber;
        END;

        /*
            Dynamic SQL is required to pass a variable number of DISK devices
            and capture RESTORE FILELISTONLY.  It reads metadata only.
        */
        SET @MetadataSql =
            N'RESTORE FILELISTONLY' + @NewLine
            + N'FROM' + @NewLine
            + @BackupDeviceList + @NewLine
            + N'WITH FILE = '
            + CONVERT(nvarchar(10), @BackupPosition)
            + N';';

        IF @PrintMetadataSql = 1
        BEGIN
            PRINT N'-- Metadata read: FILELISTONLY';

            SET @PrintPosition = 1;

            WHILE @PrintPosition <= LEN(@MetadataSql)
            BEGIN
                SET @NextLinePosition = CHARINDEX(@NewLine, @MetadataSql, @PrintPosition);

                IF @NextLinePosition = 0
                BEGIN
                    SET @PrintLine = SUBSTRING
                    (
                        @MetadataSql,
                        @PrintPosition,
                        LEN(@MetadataSql) - @PrintPosition + 1
                    );
                    SET @PrintPosition = LEN(@MetadataSql) + 1;
                END
                ELSE
                BEGIN
                    SET @PrintLine = SUBSTRING
                    (
                        @MetadataSql,
                        @PrintPosition,
                        @NextLinePosition - @PrintPosition
                    );
                    SET @PrintPosition = @NextLinePosition + LEN(@NewLine);
                END;

                PRINT @PrintLine;
            END;
        END;

        INSERT INTO #BackupFileList
        EXEC sys.sp_executesql @MetadataSql;

        IF NOT EXISTS (SELECT 1 FROM #BackupFileList)
        BEGIN
            ;THROW 50023, N'RESTORE FILELISTONLY returned no files.', 1;
        END;

        IF EXISTS
        (
            SELECT 1
            FROM #BackupFileList
            WHERE LogicalName IS NULL
               OR PhysicalName IS NULL
               OR FileID IS NULL
               OR [Type] IS NULL
               OR ISNULL(IsPresent, 0) <> 1
               OR SnapshotURL IS NOT NULL
        )
        BEGIN
            ;THROW 50024, N'FILELISTONLY returned a missing or snapshot-based file that needs manual handling.', 1;
        END;

        IF EXISTS
        (
            SELECT 1
            FROM #BackupFileList
            WHERE CHARINDEX(NCHAR(13), LogicalName) > 0
               OR CHARINDEX(NCHAR(10), LogicalName) > 0
               OR CHARINDEX(NCHAR(13), PhysicalName) > 0
               OR CHARINDEX(NCHAR(10), PhysicalName) > 0
        )
        BEGIN
            ;THROW 50035, N'FILELISTONLY returned a name containing a line-break character.', 1;
        END;

        IF EXISTS
        (
            SELECT 1
            FROM #BackupFileList
            WHERE [Type] NOT IN ('D', 'L', 'F', 'S')
        )
        BEGIN
            ;THROW 50025, N'FILELISTONLY returned an unsupported file type.', 1;
        END;

        IF EXISTS
        (
            SELECT FileID
            FROM #BackupFileList
            GROUP BY FileID
            HAVING COUNT(*) > 1
        )
        BEGIN
            ;THROW 50032, N'FILELISTONLY returned duplicate FileID values.', 1;
        END;

        /*
            Build a Windows-safe and readable filename prefix.  The suffixes
            below include file type and FileID, making every target unique
            within one database without trusting source physical basenames.
        */
        SET @SafeDatabaseFilePrefix = @DatabaseName;
        SET @SafeDatabaseFilePrefix = REPLACE(@SafeDatabaseFilePrefix, N'\', N'_');
        SET @SafeDatabaseFilePrefix = REPLACE(@SafeDatabaseFilePrefix, N'/', N'_');
        SET @SafeDatabaseFilePrefix = REPLACE(@SafeDatabaseFilePrefix, N':', N'_');
        SET @SafeDatabaseFilePrefix = REPLACE(@SafeDatabaseFilePrefix, N'*', N'_');
        SET @SafeDatabaseFilePrefix = REPLACE(@SafeDatabaseFilePrefix, N'?', N'_');
        SET @SafeDatabaseFilePrefix = REPLACE(@SafeDatabaseFilePrefix, N'"', N'_');
        SET @SafeDatabaseFilePrefix = REPLACE(@SafeDatabaseFilePrefix, N'<', N'_');
        SET @SafeDatabaseFilePrefix = REPLACE(@SafeDatabaseFilePrefix, N'>', N'_');
        SET @SafeDatabaseFilePrefix = REPLACE(@SafeDatabaseFilePrefix, N'|', N'_');

        SET @ControlCharacterCode = 1;

        WHILE @ControlCharacterCode <= 31
        BEGIN
            SET @SafeDatabaseFilePrefix = REPLACE
            (
                @SafeDatabaseFilePrefix,
                NCHAR(@ControlCharacterCode),
                N'_'
            );
            SET @ControlCharacterCode = @ControlCharacterCode + 1;
        END;

        SET @SafeDatabaseFilePrefix = RTRIM(@SafeDatabaseFilePrefix);

        WHILE RIGHT(@SafeDatabaseFilePrefix, 1) = N'.'
        BEGIN
            SET @SafeDatabaseFilePrefix = LEFT
            (
                @SafeDatabaseFilePrefix,
                LEN(@SafeDatabaseFilePrefix) - 1
            );
            SET @SafeDatabaseFilePrefix = RTRIM(@SafeDatabaseFilePrefix);
        END;

        IF NULLIF(@SafeDatabaseFilePrefix, N'') IS NULL
            SET @SafeDatabaseFilePrefix = N'Database';

        /* Keep room for type, FileID, extension, and a normal target root. */
        SET @SafeDatabaseFilePrefix = LEFT(@SafeDatabaseFilePrefix, 100);

        SELECT @CurrentLogicalFileID = MIN(FileID)
        FROM #BackupFileList;

        WHILE @CurrentLogicalFileID IS NOT NULL
        BEGIN
            SELECT
                @LogicalName = LogicalName,
                @OriginalPhysicalPath = PhysicalName,
                @FileType = [Type],
                @FileSizeBytes = [Size]
            FROM #BackupFileList
            WHERE FileID = @CurrentLogicalFileID;

            SET @TargetFileName =
                @SafeDatabaseFilePrefix
                + N'_'
                + @FileType
                + N'_'
                + CONVERT(nvarchar(20), @CurrentLogicalFileID)
                + CASE
                      WHEN @FileType = 'L' THEN N'.ldf'
                      WHEN @FileType = 'D' AND @CurrentLogicalFileID = 1 THEN N'.mdf'
                      WHEN @FileType = 'D' THEN N'.ndf'
                      ELSE N''
                  END;

            SET @TargetPhysicalPath =
                CONVERT
                (
                    nvarchar(max),
                    CASE
                        WHEN @FileType = 'L' THEN @TargetLogPath
                        ELSE @TargetDataPath
                    END
                )
                + @TargetFileName;

            IF LEN(@TargetPhysicalPath) > 259
            BEGIN
                ;THROW 50027, N'A generated target path exceeds the conservative 259-character limit.', 1;
            END;

            IF EXISTS
            (
                SELECT 1
                FROM #MoveMap
                WHERE DatabaseName = @DatabaseName
                  AND TargetPhysicalPath COLLATE Latin1_General_100_CI_AS
                      = @TargetPhysicalPath COLLATE Latin1_General_100_CI_AS
            )
            BEGIN
                ;THROW 50028, N'Two files in the same database would use the same target physical path.', 1;
            END;

            INSERT INTO #MoveMap
            (
                DatabaseName,
                FileID,
                LogicalName,
                FileType,
                OriginalPhysicalPath,
                TargetPhysicalPath,
                FileSizeBytes
            )
            VALUES
            (
                @DatabaseName,
                @CurrentLogicalFileID,
                @LogicalName,
                @FileType,
                @OriginalPhysicalPath,
                @TargetPhysicalPath,
                @FileSizeBytes
            );

            SET @LastLogicalFileID = @CurrentLogicalFileID;
            SET @CurrentLogicalFileID = NULL;

            SELECT @CurrentLogicalFileID = MIN(FileID)
            FROM #BackupFileList
            WHERE FileID > @LastLogicalFileID;
        END;

        IF EXISTS
        (
            SELECT 1
            FROM #MoveMap AS GeneratedFile
            INNER JOIN sys.master_files AS ExistingFile
                ON GeneratedFile.TargetPhysicalPath COLLATE Latin1_General_100_CI_AS
                   = ExistingFile.physical_name COLLATE Latin1_General_100_CI_AS
            WHERE GeneratedFile.DatabaseName = @DatabaseName
              AND
              (
                  DB_ID(@DatabaseName) IS NULL
                  OR ExistingFile.database_id <> DB_ID(@DatabaseName)
              )
        )
        BEGIN
            ;THROW 50029, N'A generated MOVE target is already registered in sys.master_files.', 1;
        END;

        SELECT @CurrentLogicalFileID = MIN(FileID)
        FROM #MoveMap
        WHERE DatabaseName = @DatabaseName;

        WHILE @CurrentLogicalFileID IS NOT NULL
        BEGIN
            SELECT
                @LogicalName = LogicalName,
                @TargetPhysicalPath = TargetPhysicalPath
            FROM #MoveMap
            WHERE DatabaseName = @DatabaseName
              AND FileID = @CurrentLogicalFileID;

            IF LEN(@MoveClause) > 0
                SET @MoveClause = @MoveClause + N',' + @NewLine;

            SET @MoveClause = @MoveClause
                + N'    MOVE N'''
                + REPLACE(@LogicalName, N'''', N'''''' )
                + N''' TO N'''
                + REPLACE(CONVERT(nvarchar(max), @TargetPhysicalPath), N'''', N'''''' )
                + N'''';

            SET @LastLogicalFileID = @CurrentLogicalFileID;
            SET @CurrentLogicalFileID = NULL;

            SELECT @CurrentLogicalFileID = MIN(FileID)
            FROM #MoveMap
            WHERE DatabaseName = @DatabaseName
              AND FileID > @LastLogicalFileID;
        END;

        SET @RestoreCommand =
            N'USE [master];' + @NewLine
            + N'-- Source server: '
            + REPLACE
              (
                  REPLACE(ISNULL(@SourceServerName, N'(unknown)'), NCHAR(13), N' '),
                  NCHAR(10),
                  N' '
              )
            + @NewLine
            + N'-- Full backup finish: '
            + CONVERT(nvarchar(19), @BackupFinishDate, 120) + @NewLine
            + N'-- BackupSetGUID: '
            + ISNULL(CONVERT(nvarchar(36), @BackupSetGUID), N'(NULL)') + @NewLine
            + N'IF DB_ID(N'''
            + REPLACE(@DatabaseName, N'''', N'''''' )
            + N''') IS NOT NULL' + @NewLine
            + N'BEGIN' + @NewLine
            + N'    ;THROW 51000, N''Target database already exists; restore was blocked.'', 1;'
            + @NewLine
            + N'END;' + @NewLine
            + N'RESTORE DATABASE ' + QUOTENAME(@DatabaseName) + @NewLine
            + N'FROM' + @NewLine
            + @BackupDeviceList + @NewLine
            + N'WITH FILE = '
            + CONVERT(nvarchar(10), @BackupPosition) + N',' + @NewLine
            + @MoveClause + N',' + @NewLine
            + N'    RECOVERY,' + @NewLine
            + N'    STATS = 5;' + @NewLine
            + N'GO';

        INSERT INTO #GeneratedRestoreCommands
        (
            DatabaseName,
            RestoreCommand
        )
        VALUES
        (
            @DatabaseName,
            @RestoreCommand
        );

        UPDATE #LatestBackups
        SET GenerationStatus = 'Ready',
            StatusMessage = N'All expected stripes were found and FILELISTONLY produced D/L/F/S MOVE mappings.'
        WHERE LatestBackupID = @CurrentLatestBackupID;

        IF DB_ID(@DatabaseName) IS NOT NULL
        BEGIN
            INSERT INTO #GeneratorIssues
            (
                Severity,
                StepName,
                ItemName,
                IssueMessage
            )
            VALUES
            (
                'WARNING',
                'Step 4',
                @DatabaseName,
                N'A database with this name already exists. The generated command contains an execution-time guard and no WITH REPLACE.'
            );
        END;
    END TRY
    BEGIN CATCH
        UPDATE #LatestBackups
        SET GenerationStatus = 'Blocked',
            StatusMessage = ERROR_MESSAGE()
        WHERE LatestBackupID = @CurrentLatestBackupID;

        DELETE FROM #MoveMap
        WHERE DatabaseName = @DatabaseName;

        DELETE FROM #GeneratedRestoreCommands
        WHERE DatabaseName = @DatabaseName;

        INSERT INTO #GeneratorIssues
        (
            Severity,
            StepName,
            ItemName,
            IssueMessage
        )
        VALUES
        (
            'ERROR',
            'Step 4',
            @DatabaseName,
            ERROR_MESSAGE()
        );
    END CATCH;

    SET @LastLatestBackupID = @CurrentLatestBackupID;
    SET @CurrentLatestBackupID = NULL;

    SELECT @CurrentLatestBackupID = MIN(LatestBackupID)
    FROM #LatestBackups
    WHERE LatestBackupID > @LastLatestBackupID;
END;

/*
    Database names are discovered with BIN2 semantics so case/accent-distinct
    source names are never merged.  If the target server collation considers
    two source names equal, both are blocked because they cannot coexist there.
*/
UPDATE LatestBackup
SET GenerationStatus = 'Blocked',
    StatusMessage = N'Two source database names collide under the target server collation.'
FROM #LatestBackups AS LatestBackup
WHERE LatestBackup.GenerationStatus = 'Ready'
  AND EXISTS
      (
          SELECT 1
          FROM #LatestBackups AS OtherBackup
          WHERE OtherBackup.LatestBackupID <> LatestBackup.LatestBackupID
            AND OtherBackup.DatabaseName COLLATE DATABASE_DEFAULT
                = LatestBackup.DatabaseName COLLATE DATABASE_DEFAULT
      );

INSERT INTO #GeneratorIssues
(
    Severity,
    StepName,
    ItemName,
    IssueMessage
)
SELECT
    'ERROR',
    'Step 4',
    DatabaseName,
    StatusMessage
FROM #LatestBackups
WHERE GenerationStatus = 'Blocked'
  AND StatusMessage = N'Two source database names collide under the target server collation.';

/*
    Block every still-ready database involved in a target-path collision.  This
    check is performed after all databases are mapped so both sides are blocked.
*/
UPDATE LatestBackup
SET GenerationStatus = 'Blocked',
    StatusMessage = N'Another selected database would use the same MOVE target path.'
FROM #LatestBackups AS LatestBackup
WHERE LatestBackup.GenerationStatus = 'Ready'
  AND EXISTS
(
    SELECT 1
    FROM #MoveMap AS FirstFile
    INNER JOIN #MoveMap AS SecondFile
        ON FirstFile.TargetPhysicalPath COLLATE Latin1_General_100_CI_AS
           = SecondFile.TargetPhysicalPath COLLATE Latin1_General_100_CI_AS
       AND FirstFile.DatabaseName <> SecondFile.DatabaseName
    WHERE FirstFile.DatabaseName = LatestBackup.DatabaseName
);

INSERT INTO #GeneratorIssues
(
    Severity,
    StepName,
    ItemName,
    IssueMessage
)
SELECT
    'ERROR',
    'Step 4',
    DatabaseName,
    StatusMessage
FROM #LatestBackups
WHERE GenerationStatus = 'Blocked'
  AND StatusMessage = N'Another selected database would use the same MOVE target path.';

DELETE GeneratedCommand
FROM #GeneratedRestoreCommands AS GeneratedCommand
INNER JOIN #LatestBackups AS LatestBackup
    ON LatestBackup.DatabaseName = GeneratedCommand.DatabaseName
WHERE LatestBackup.GenerationStatus <> 'Ready';

/*==========================================================================
  Step 5: Review result sets and print generated commands
============================================================================*/

/* Result 1: every selected database and whether command generation succeeded. */
SELECT
    DatabaseName,
    SourceServerName,
    DatabaseFamilyGUID,
    MediaSetId,
    BackupStartDate,
    BackupFinishDate,
    CheckpointLSN,
    BackupSetGUID,
    BackupPosition,
    GenerationStatus,
    StatusMessage
FROM #LatestBackups
ORDER BY DatabaseName;

/* Result 2: source logical/physical files and their proposed MOVE targets. */
SELECT
    MoveMap.DatabaseName,
    LatestBackup.GenerationStatus,
    MoveMap.FileID,
    MoveMap.LogicalName,
    MoveMap.FileType,
    MoveMap.OriginalPhysicalPath,
    MoveMap.TargetPhysicalPath,
    CAST(MoveMap.FileSizeBytes / 1048576.0 AS decimal(20,2)) AS FileSizeMB
FROM #MoveMap AS MoveMap
INNER JOIN #LatestBackups AS LatestBackup
    ON LatestBackup.DatabaseName = MoveMap.DatabaseName
ORDER BY MoveMap.DatabaseName, MoveMap.FileID;

/* Result 3: warnings and errors that must be reviewed before any restore. */
SELECT
    Severity,
    StepName,
    ItemName,
    IssueMessage
FROM #GeneratorIssues
ORDER BY IssueID;

/*
    Result 4: complete nvarchar(max) text.  This is the authoritative output if
    SSMS Messages or PRINT settings truncate anything.
*/
SELECT
    DatabaseName,
    RestoreCommand
FROM #GeneratedRestoreCommands
ORDER BY DatabaseName;

/* Print generated RESTORE scripts one logical line at a time. */
PRINT N'-- BEGIN GENERATED RESTORE SCRIPT';

DECLARE @CurrentRestoreCommandID int;
DECLARE @LastRestoreCommandID int;

SELECT @CurrentRestoreCommandID = MIN(RestoreCommandID)
FROM #GeneratedRestoreCommands;

WHILE @CurrentRestoreCommandID IS NOT NULL
BEGIN
    SELECT @RestoreCommand = RestoreCommand
    FROM #GeneratedRestoreCommands
    WHERE RestoreCommandID = @CurrentRestoreCommandID;

    SET @PrintPosition = 1;

    WHILE @PrintPosition <= LEN(@RestoreCommand)
    BEGIN
        SET @NextLinePosition = CHARINDEX(@NewLine, @RestoreCommand, @PrintPosition);

        IF @NextLinePosition = 0
        BEGIN
            SET @PrintLine = SUBSTRING
            (
                @RestoreCommand,
                @PrintPosition,
                LEN(@RestoreCommand) - @PrintPosition + 1
            );
            SET @PrintPosition = LEN(@RestoreCommand) + 1;
        END
        ELSE
        BEGIN
            SET @PrintLine = SUBSTRING
            (
                @RestoreCommand,
                @PrintPosition,
                @NextLinePosition - @PrintPosition
            );
            SET @PrintPosition = @NextLinePosition + LEN(@NewLine);
        END;

        PRINT @PrintLine;
    END;

    PRINT N'';

    SET @LastRestoreCommandID = @CurrentRestoreCommandID;
    SET @CurrentRestoreCommandID = NULL;

    SELECT @CurrentRestoreCommandID = MIN(RestoreCommandID)
    FROM #GeneratedRestoreCommands
    WHERE RestoreCommandID > @LastRestoreCommandID;
END;

PRINT N'-- END GENERATED RESTORE SCRIPT';

IF NOT EXISTS (SELECT 1 FROM #GeneratedRestoreCommands)
BEGIN
    PRINT N'No RESTORE DATABASE command was generated. Review the status and issue result sets.';
END;

/*
    End of generator.
    There is intentionally no EXEC(@RestoreCommand) or sp_executesql call for
    any generated RESTORE DATABASE statement.
*/
