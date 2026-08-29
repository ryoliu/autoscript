/*
Version Date        Writer     Desc
1.0     20260804    William    Version 1.0
*/
/*====================================================================
  Create SQL Server Agent Jobs for FULL and Transaction Log Backups

  Default schedules:
    FULL backup : Daily at 01:00
    LOG backup  : Every 15 minutes

  Deployment behavior:
    Existing jobs with the same names are deleted and recreated.

  Requirements:
    - SQL Server Agent service must be running.
    - The Job owner must be a valid SQL Server login.
    - Update the settings inside each embedded backup script as needed.
====================================================================*/

USE [msdb];
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE
    @FullJobName sysname = N'_BackupFull-Split',
    @LogJobName sysname = N'_BackupTransactionLog-Split',
    @FullScheduleName sysname = N'_Schedule-BackupFull-Daily-0100',
    @LogScheduleName sysname = N'_Schedule-BackupLog-Every-15-Minutes',
    @JobOwnerLoginName sysname = N'sa',
    @FullCommand nvarchar(max),
    @LogCommand nvarchar(max),
    @JobId uniqueidentifier;

SET @FullCommand = N'/*====================================================================
  SQL Server FULL Backup to QNAP or Default Backup Path

  Scope:
    - master and msdb
    - All ONLINE user databases
    - master and msdb always use one backup file
    - User database file count is determined by logical CPU count

  COPY_ONLY:
    SCHEDULED = Regular FULL backup
    ADHOC / MIGRATION / TEST = COPY_ONLY FULL backup

  Folder creation:
    The root SMB share must already exist.
    Backup subfolders are created automatically by xp_create_subdir.
====================================================================*/

SET NOCOUNT ON;
SET XACT_ABORT OFF;

-- Settings
DECLARE
    @BackupPurpose varchar(20) = ''SCHEDULED'',
    @Execute bit = 1,
    @UseQnap bit = 1,
    @QnapIP nvarchar(128) = N''127.0.0.1'',
    @ShareName sysname = N''sqlbk'',
    @BufferCount int = 512,
    @MaxTransferSize int = 131072,
    @StatsPercent int = 10,
    @DeleteExpiredFiles bit = 1,
    @RetentionDays int = 7;

DECLARE
    @BackupRootPath nvarchar(2000),
    @MachineName sysname =
        REPLACE(CAST(@@SERVERNAME AS varchar(128)), N''\'', N''-''),
    @InstanceName sysname =
        CONVERT(sysname, SERVERPROPERTY(''InstanceName'')),
    @ServerFolder nvarchar(256),
    @InstanceFolder nvarchar(256),
    @DeleteDate datetime;

SET @BackupPurpose = UPPER(LTRIM(RTRIM(@BackupPurpose)));
SET @DeleteDate = DATEADD(DAY, -@RetentionDays, GETDATE());

IF @BackupPurpose NOT IN (''SCHEDULED'', ''ADHOC'', ''MIGRATION'', ''TEST'')
    THROW 50002,
          N''@BackupPurpose must be SCHEDULED, ADHOC, MIGRATION, or TEST.'',
          1;

IF @BufferCount <= 0
    THROW 50003, N''@BufferCount must be greater than zero.'', 1;

IF @MaxTransferSize <= 0
    THROW 50004, N''@MaxTransferSize must be greater than zero.'', 1;

IF NULLIF(@InstanceName, N'''') IS NULL
    SET @InstanceName = N''MSSQLSERVER'';

SET @ServerFolder = CONVERT(nvarchar(128), @MachineName);
SET @InstanceFolder = CONVERT(nvarchar(128), @InstanceName);

IF @UseQnap = 1
BEGIN
    SET @BackupRootPath =
        N''\\'' + @QnapIP + N''\'' + @ShareName + N''\'' + @ServerFolder;
END;
ELSE
BEGIN
    SET @BackupRootPath =
        CONVERT(nvarchar(2000), SERVERPROPERTY(''InstanceDefaultBackupPath''));

    IF NULLIF(@BackupRootPath, N'''') IS NULL
    BEGIN
        EXEC master.dbo.xp_instance_regread
             N''HKEY_LOCAL_MACHINE'',
             N''Software\Microsoft\MSSQLServer\MSSQLServer'',
             N''BackupDirectory'',
             @BackupRootPath OUTPUT;
    END;
END;

IF NULLIF(@BackupRootPath, N'''') IS NULL
    THROW 50006, N''Unable to determine the backup root path.'', 1;

IF RIGHT(@BackupRootPath, 1) = N''\''
    SET @BackupRootPath =
        LEFT(@BackupRootPath, LEN(@BackupRootPath) - 1);

-- CPU-based file count
DECLARE
    @CpuCount int,
    @FullBackupFileCount int,
    @UseCopyOnly bit;

SELECT @CpuCount = cpu_count
FROM sys.dm_os_sys_info;

SET @FullBackupFileCount =
    CASE
        WHEN @CpuCount BETWEEN 1 AND 3  THEN 1
        WHEN @CpuCount BETWEEN 4 AND 7  THEN 2
        WHEN @CpuCount BETWEEN 8 AND 15 THEN 4
        WHEN @CpuCount >= 16            THEN 8
        ELSE 1
    END;

SET @UseCopyOnly =
    CASE WHEN @BackupPurpose IN (''ADHOC'', ''MIGRATION'', ''TEST'')
         THEN 1 ELSE 0 END;

-- Results
DROP TABLE IF EXISTS #BackupResult;

CREATE TABLE #BackupResult
(
    ResultId          int IDENTITY(1,1) NOT NULL,
    DatabaseName      sysname NOT NULL,
    RecoveryModel     nvarchar(60) NULL,
    BackupFileCount   int NULL,
    BackupFolder      nvarchar(2000) NULL,
    StartTime         datetime2(3) NULL,
    EndTime           datetime2(3) NULL,
    DurationSeconds   decimal(18,3) NULL,
    BackupStatus      varchar(20) NOT NULL,
    ErrorNumber       int NULL,
    ErrorMessage      nvarchar(4000) NULL,
    BackupCommand     nvarchar(max) NULL
);

-- Backup
DECLARE
    @DatabaseName sysname,
    @RecoveryModel nvarchar(60),
    @FileCount int,
    @FileNumber int,
    @BackupFolder nvarchar(2000),
    @BackupFileName nvarchar(1000),
    @BackupFullPath nvarchar(3000),
    @Timestamp nvarchar(50),
    @ToClause nvarchar(max),
    @BackupCommand nvarchar(max),
    @StartTime datetime2(3),
    @EndTime datetime2(3),
    @BackupStatus varchar(20),
    @ErrorNumber int,
    @ErrorMessage nvarchar(4000);

DECLARE DatabaseCursor CURSOR LOCAL FAST_FORWARD FOR
SELECT
    name,
    recovery_model_desc
FROM sys.databases
WHERE state_desc = N''ONLINE''
  AND source_database_id IS NULL
  AND (name IN (N''master'', N''msdb'') OR database_id > 4)
ORDER BY
    CASE WHEN database_id <= 4 THEN 0 ELSE 1 END,
    name;

OPEN DatabaseCursor;
FETCH NEXT FROM DatabaseCursor
INTO @DatabaseName, @RecoveryModel;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @StartTime = SYSDATETIME();
    SET @EndTime = NULL;
    SET @BackupStatus = NULL;
    SET @ErrorNumber = NULL;
    SET @ErrorMessage = NULL;
    SET @ToClause = N'''';

    SET @FileCount =
        CASE WHEN @DatabaseName IN (N''master'', N''msdb'')
             THEN 1 ELSE @FullBackupFileCount END;

    SET @Timestamp =
        REPLACE(
            FORMAT(
                SYSDATETIMEOFFSET(),
                ''yyyy-MM-ddTHHmmssfffffffzzz'',
                ''en-US''
            ),
            N'':'',
            N''''
        );

    IF @UseQnap = 1
        SET @BackupFolder =
            @BackupRootPath + N''\data\''
            + @InstanceFolder + N''\'' + @DatabaseName;
    ELSE
        SET @BackupFolder =
            @BackupRootPath + N''\data\'' + @DatabaseName;

    SET @FileNumber = 1;

    WHILE @FileNumber <= @FileCount
    BEGIN
        SET @BackupFileName =
            LOWER(@DatabaseName)
            + N''_'' + @Timestamp
            + N''_Media1-Family''
            + CONVERT(nvarchar(10), @FileNumber)
            + N''of''
            + CONVERT(nvarchar(10), @FileCount)
            + N''.bak'';

        SET @BackupFullPath =
            @BackupFolder + N''\'' + @BackupFileName;

        SET @ToClause =
            @ToClause
            + CASE WHEN @FileNumber = 1
                   THEN N''DISK = N''''''
                   ELSE N'','' + CHAR(13) + CHAR(10) + N''    DISK = N''''''
              END
            + REPLACE(@BackupFullPath, N'''''''', N'''''''''''')
            + N'''''''';

        SET @FileNumber += 1;
    END;

    SET @BackupCommand =
        N''BACKUP DATABASE '' + QUOTENAME(@DatabaseName)
        + CHAR(13) + CHAR(10)
        + N''TO '' + @ToClause
        + CHAR(13) + CHAR(10)
        + N''WITH ''
        + CASE WHEN @UseCopyOnly = 1 THEN N''COPY_ONLY, '' ELSE N'''' END
        + N''COMPRESSION, CHECKSUM, ''
        + N''BUFFERCOUNT = '' + CONVERT(nvarchar(20), @BufferCount) + N'', ''
        + N''MAXTRANSFERSIZE = '' + CONVERT(nvarchar(20), @MaxTransferSize) + N'', ''
        + N''STATS = '' + CONVERT(nvarchar(20), @StatsPercent) + N'';'';

    IF @Execute = 0
    BEGIN
        SET @EndTime = SYSDATETIME();
        SET @BackupStatus = ''GENERATED'';
    END;
    ELSE
    BEGIN
        BEGIN TRY
            EXEC master.dbo.xp_create_subdir @BackupFolder;
            EXEC sys.sp_executesql @BackupCommand;

            SET @EndTime = SYSDATETIME();
            SET @BackupStatus = ''SUCCESS'';
        END TRY
        BEGIN CATCH
            SET @EndTime = SYSDATETIME();
            SET @BackupStatus = ''FAILED'';
            SET @ErrorNumber = ERROR_NUMBER();
            SET @ErrorMessage = ERROR_MESSAGE();
        END CATCH;
    END;

    INSERT INTO #BackupResult
    (
        DatabaseName,
        RecoveryModel,
        BackupFileCount,
        BackupFolder,
        StartTime,
        EndTime,
        DurationSeconds,
        BackupStatus,
        ErrorNumber,
        ErrorMessage,
        BackupCommand
    )
    VALUES
    (
        @DatabaseName,
        @RecoveryModel,
        @FileCount,
        @BackupFolder,
        @StartTime,
        @EndTime,
        DATEDIFF_BIG(MILLISECOND, @StartTime, @EndTime) / 1000.0,
        @BackupStatus,
        @ErrorNumber,
        @ErrorMessage,
        @BackupCommand
    );

    FETCH NEXT FROM DatabaseCursor
    INTO @DatabaseName, @RecoveryModel;
END;

CLOSE DatabaseCursor;
DEALLOCATE DatabaseCursor;

-- Delete expired .bak files; cleanup problems are warnings only.
IF @Execute = 1 AND @DeleteExpiredFiles = 1
BEGIN
    DECLARE
        @CleanupDatabaseName sysname,
        @BakCleanupFolder nvarchar(2000);

    DECLARE CleanupCursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM sys.databases
    WHERE source_database_id IS NULL
      AND (name IN (N''master'', N''msdb'') OR database_id > 4)
    ORDER BY name;

    OPEN CleanupCursor;
    FETCH NEXT FROM CleanupCursor INTO @CleanupDatabaseName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @UseQnap = 1
            SET @BakCleanupFolder =
                @BackupRootPath + N''\data\''
                + @InstanceFolder + N''\'' + @CleanupDatabaseName;
        ELSE
            SET @BakCleanupFolder =
                @BackupRootPath + N''\data\'' + @CleanupDatabaseName;

        BEGIN TRY
            EXEC master.sys.xp_delete_file
                 0,
                 @BakCleanupFolder,
                 N''bak'',
                 @DeleteDate,
                 0;

            PRINT N''Expired BAK cleanup checked: '' + @BakCleanupFolder;
        END TRY
        BEGIN CATCH
            PRINT N''WARNING - BAK cleanup failed: ''
                + @BakCleanupFolder + N''. '' + ERROR_MESSAGE();
        END CATCH;

        FETCH NEXT FROM CleanupCursor INTO @CleanupDatabaseName;
    END;

    CLOSE CleanupCursor;
    DEALLOCATE CleanupCursor;
END;

-- Output
SELECT
    ''FULL'' AS BackupType,
    @BackupPurpose AS BackupPurpose,
    @Execute AS ExecuteBackup,
    @CpuCount AS CpuCount,
    @FullBackupFileCount AS UserDatabaseFileCount,
    @UseCopyOnly AS UseCopyOnly,
    COUNT(*) AS ProcessedDatabaseCount
FROM #BackupResult;

SELECT
    ResultId,
    DatabaseName,
    RecoveryModel,
    BackupFileCount,
    BackupFolder,
    StartTime,
    EndTime,
    DurationSeconds,
    BackupStatus,
    ErrorNumber,
    ErrorMessage,
    BackupCommand
FROM #BackupResult
ORDER BY ResultId;

SELECT
    BackupStatus,
    COUNT(*) AS DatabaseCount
FROM #BackupResult
GROUP BY BackupStatus
ORDER BY BackupStatus;

IF EXISTS
(
    SELECT 1
    FROM #BackupResult
    WHERE BackupStatus = ''FAILED''
)
    THROW 50010, N''One or more FULL database backups failed.'', 1;
';
SET @LogCommand = N'/*====================================================================
  SQL Server Transaction Log Backup to QNAP or Default Backup Path

  Backup scope:
    - ONLINE user databases
    - FULL or BULK_LOGGED recovery model
    - One .trn file per database per execution

  Cleanup:
    Expired .trn files are checked for all user databases, including
    SIMPLE databases, because historical .trn files may remain after
    recovery model changes.

  Folder creation:
    The root SMB share must already exist.
    Backup subfolders are created automatically by xp_create_subdir.
====================================================================*/

SET NOCOUNT ON;
SET XACT_ABORT OFF;

-- Settings
DECLARE
    @Execute bit = 1,
    @UseQnap bit = 1,
    @QnapIP nvarchar(128) = N''127.0.0.1'',
    @ShareName sysname = N''sqlbk'',
    @BufferCount int = 512,
    @MaxTransferSize int = 131072,
    @StatsPercent int = 10,
    @DeleteExpiredFiles bit = 1,
    @RetentionDays int = 7;

DECLARE
    @BackupRootPath nvarchar(2000),
    @MachineName sysname =
        REPLACE(CAST(@@SERVERNAME AS varchar(128)), N''\'', N''-''),
    @InstanceName sysname =
        CONVERT(sysname, SERVERPROPERTY(''InstanceName'')),
    @ServerFolder nvarchar(256),
    @InstanceFolder nvarchar(256),
    @DeleteDate datetime;

SET @DeleteDate = DATEADD(DAY, -@RetentionDays, GETDATE());

IF @BufferCount <= 0
    THROW 50003, N''@BufferCount must be greater than zero.'', 1;

IF @MaxTransferSize <= 0
    THROW 50004, N''@MaxTransferSize must be greater than zero.'', 1;

IF NULLIF(@InstanceName, N'''') IS NULL
    SET @InstanceName = N''MSSQLSERVER'';

SET @ServerFolder = CONVERT(nvarchar(128), @MachineName);
SET @InstanceFolder = CONVERT(nvarchar(128), @InstanceName);

IF @UseQnap = 1
BEGIN
    SET @BackupRootPath =
        N''\\'' + @QnapIP + N''\'' + @ShareName + N''\'' + @ServerFolder;
END;
ELSE
BEGIN
    SET @BackupRootPath =
        CONVERT(nvarchar(2000), SERVERPROPERTY(''InstanceDefaultBackupPath''));

    IF NULLIF(@BackupRootPath, N'''') IS NULL
    BEGIN
        EXEC master.dbo.xp_instance_regread
             N''HKEY_LOCAL_MACHINE'',
             N''Software\Microsoft\MSSQLServer\MSSQLServer'',
             N''BackupDirectory'',
             @BackupRootPath OUTPUT;
    END;
END;

IF NULLIF(@BackupRootPath, N'''') IS NULL
    THROW 50006, N''Unable to determine the backup root path.'', 1;

IF RIGHT(@BackupRootPath, 1) = N''\''
    SET @BackupRootPath =
        LEFT(@BackupRootPath, LEN(@BackupRootPath) - 1);

-- Results
DROP TABLE IF EXISTS #BackupResult;

CREATE TABLE #BackupResult
(
    ResultId          int IDENTITY(1,1) NOT NULL,
    DatabaseName      sysname NOT NULL,
    RecoveryModel     nvarchar(60) NULL,
    BackupFolder      nvarchar(2000) NULL,
    StartTime         datetime2(3) NULL,
    EndTime           datetime2(3) NULL,
    DurationSeconds   decimal(18,3) NULL,
    BackupStatus      varchar(20) NOT NULL,
    ErrorNumber       int NULL,
    ErrorMessage      nvarchar(4000) NULL,
    BackupCommand     nvarchar(max) NULL
);

-- Backup eligible databases
DECLARE
    @DatabaseName sysname,
    @RecoveryModel nvarchar(60),
    @BackupFolder nvarchar(2000),
    @BackupFileName nvarchar(1000),
    @BackupFullPath nvarchar(3000),
    @Timestamp nvarchar(50),
    @BackupCommand nvarchar(max),
    @StartTime datetime2(3),
    @EndTime datetime2(3),
    @BackupStatus varchar(20),
    @ErrorNumber int,
    @ErrorMessage nvarchar(4000);

DECLARE DatabaseCursor CURSOR LOCAL FAST_FORWARD FOR
SELECT
    name,
    recovery_model_desc
FROM sys.databases
WHERE state_desc = N''ONLINE''
  AND source_database_id IS NULL
  AND database_id > 4
  AND recovery_model_desc IN (N''FULL'', N''BULK_LOGGED'')
ORDER BY name;

OPEN DatabaseCursor;
FETCH NEXT FROM DatabaseCursor
INTO @DatabaseName, @RecoveryModel;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @StartTime = SYSDATETIME();
    SET @EndTime = NULL;
    SET @BackupStatus = NULL;
    SET @ErrorNumber = NULL;
    SET @ErrorMessage = NULL;

    SET @Timestamp =
        REPLACE(
            FORMAT(
                SYSDATETIMEOFFSET(),
                ''yyyy-MM-ddTHHmmssfffffffzzz'',
                ''en-US''
            ),
            N'':'',
            N''''
        );

    IF @UseQnap = 1
        SET @BackupFolder =
            @BackupRootPath + N''\trn\''
            + @InstanceFolder + N''\'' + @DatabaseName;
    ELSE
        SET @BackupFolder =
            @BackupRootPath + N''\trn\'' + @DatabaseName;

    SET @BackupFileName =
        LOWER(@DatabaseName) + N''_'' + @Timestamp + N''.trn'';

    SET @BackupFullPath =
        @BackupFolder + N''\'' + @BackupFileName;

    SET @BackupCommand =
        N''BACKUP LOG '' + QUOTENAME(@DatabaseName)
        + CHAR(13) + CHAR(10)
        + N''TO DISK = N''''''
        + REPLACE(@BackupFullPath, N'''''''', N'''''''''''')
        + N''''''''
        + CHAR(13) + CHAR(10)
        + N''WITH COMPRESSION, CHECKSUM, ''
        + N''BUFFERCOUNT = '' + CONVERT(nvarchar(20), @BufferCount) + N'', ''
        + N''MAXTRANSFERSIZE = '' + CONVERT(nvarchar(20), @MaxTransferSize) + N'', ''
        + N''STATS = '' + CONVERT(nvarchar(20), @StatsPercent) + N'';'';

    IF @Execute = 0
    BEGIN
        SET @EndTime = SYSDATETIME();
        SET @BackupStatus = ''GENERATED'';
    END;
    ELSE
    BEGIN
        BEGIN TRY
            EXEC master.dbo.xp_create_subdir @BackupFolder;
            EXEC sys.sp_executesql @BackupCommand;

            SET @EndTime = SYSDATETIME();
            SET @BackupStatus = ''SUCCESS'';
        END TRY
        BEGIN CATCH
            SET @EndTime = SYSDATETIME();
            SET @BackupStatus = ''FAILED'';
            SET @ErrorNumber = ERROR_NUMBER();
            SET @ErrorMessage = ERROR_MESSAGE();
        END CATCH;
    END;

    INSERT INTO #BackupResult
    (
        DatabaseName,
        RecoveryModel,
        BackupFolder,
        StartTime,
        EndTime,
        DurationSeconds,
        BackupStatus,
        ErrorNumber,
        ErrorMessage,
        BackupCommand
    )
    VALUES
    (
        @DatabaseName,
        @RecoveryModel,
        @BackupFolder,
        @StartTime,
        @EndTime,
        DATEDIFF_BIG(MILLISECOND, @StartTime, @EndTime) / 1000.0,
        @BackupStatus,
        @ErrorNumber,
        @ErrorMessage,
        @BackupCommand
    );

    FETCH NEXT FROM DatabaseCursor
    INTO @DatabaseName, @RecoveryModel;
END;

CLOSE DatabaseCursor;
DEALLOCATE DatabaseCursor;

IF NOT EXISTS (SELECT 1 FROM #BackupResult)
    PRINT N''No eligible databases require transaction log backup.'';

-- Delete expired .trn files; cleanup problems are warnings only.
IF @Execute = 1 AND @DeleteExpiredFiles = 1
BEGIN
    DECLARE
        @CleanupDatabaseName sysname,
        @TrnCleanupFolder nvarchar(2000);

    DECLARE @FolderExists TABLE
    (
        FileExists int,
        FileIsDirectory int,
        ParentDirectoryExists int
    );

    DECLARE CleanupCursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM sys.databases
    WHERE source_database_id IS NULL
      AND database_id > 4
    ORDER BY name;

    OPEN CleanupCursor;
    FETCH NEXT FROM CleanupCursor INTO @CleanupDatabaseName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @UseQnap = 1
            SET @TrnCleanupFolder =
                @BackupRootPath + N''\trn\''
                + @InstanceFolder + N''\'' + @CleanupDatabaseName;
        ELSE
            SET @TrnCleanupFolder =
                @BackupRootPath + N''\trn\'' + @CleanupDatabaseName;

        DELETE FROM @FolderExists;

        INSERT INTO @FolderExists
        EXEC master.dbo.xp_fileexist @TrnCleanupFolder;

        IF EXISTS
        (
            SELECT 1
            FROM @FolderExists
            WHERE FileIsDirectory = 1
        )
        BEGIN
            BEGIN TRY
                EXEC master.sys.xp_delete_file
                     0,
                     @TrnCleanupFolder,
                     N''trn'',
                     @DeleteDate,
                     0;

                PRINT N''Expired TRN cleanup checked: '' + @TrnCleanupFolder;
            END TRY
            BEGIN CATCH
                PRINT N''WARNING - TRN cleanup failed: ''
                    + @TrnCleanupFolder + N''. '' + ERROR_MESSAGE();
            END CATCH;
        END
        ELSE
        BEGIN
            PRINT N''TRN folder does not exist; cleanup skipped: ''
                + @TrnCleanupFolder;
        END;

        FETCH NEXT FROM CleanupCursor INTO @CleanupDatabaseName;
    END;

    CLOSE CleanupCursor;
    DEALLOCATE CleanupCursor;
END;

-- Output
SELECT
    ''LOG'' AS BackupType,
    @Execute AS ExecuteBackup,
    COUNT(*) AS ProcessedDatabaseCount
FROM #BackupResult;

SELECT
    ResultId,
    DatabaseName,
    RecoveryModel,
    BackupFolder,
    StartTime,
    EndTime,
    DurationSeconds,
    BackupStatus,
    ErrorNumber,
    ErrorMessage,
    BackupCommand
FROM #BackupResult
ORDER BY ResultId;

SELECT
    BackupStatus,
    COUNT(*) AS DatabaseCount
FROM #BackupResult
GROUP BY BackupStatus
ORDER BY BackupStatus;

IF EXISTS
(
    SELECT 1
    FROM #BackupResult
    WHERE BackupStatus = ''FAILED''
)
    THROW 50011, N''One or more transaction log backups failed.'', 1;
';

IF NOT EXISTS
(
    SELECT 1
    FROM sys.server_principals
    WHERE name = @JobOwnerLoginName
)
BEGIN
    THROW 50020, N'The SQL Agent Job owner login does not exist.', 1;
END;

----------------------------------------------------------------------
-- Remove existing jobs
----------------------------------------------------------------------

IF EXISTS
(
    SELECT 1
    FROM msdb.dbo.sysjobs
    WHERE name = @FullJobName
)
BEGIN
    EXEC msdb.dbo.sp_delete_job
         @job_name = @FullJobName,
         @delete_unused_schedule = 1;
END;

IF EXISTS
(
    SELECT 1
    FROM msdb.dbo.sysjobs
    WHERE name = @LogJobName
)
BEGIN
    EXEC msdb.dbo.sp_delete_job
         @job_name = @LogJobName,
         @delete_unused_schedule = 1;
END;

----------------------------------------------------------------------
-- Create FULL backup job
----------------------------------------------------------------------

SET @JobId = NULL;

EXEC msdb.dbo.sp_add_job
     @job_name = @FullJobName,
     @enabled = 1,
     @description = N'Daily FULL backup for master, msdb, and all ONLINE user databases.',
     @start_step_id = 1,
     @category_name = N'Database Maintenance',
     @owner_login_name = @JobOwnerLoginName,
     @job_id = @JobId OUTPUT;

EXEC msdb.dbo.sp_add_jobstep
     @job_id = @JobId,
     @step_id = 1,
     @step_name = N'Backup FULL Databases',
     @subsystem = N'TSQL',
     @database_name = N'master',
     @command = @FullCommand,
     @on_success_action = 1,
     @on_fail_action = 2,
     @retry_attempts = 0,
     @retry_interval = 0;

EXEC msdb.dbo.sp_add_jobschedule
     @job_id = @JobId,
     @name = @FullScheduleName,
     @enabled = 1,
     @freq_type = 4,           -- Daily
     @freq_interval = 1,       -- Every day
     @freq_subday_type = 1,    -- At a specified time
     @freq_subday_interval = 0,
     @active_start_date = 20260731,
     @active_start_time = 010000;

EXEC msdb.dbo.sp_add_jobserver
     @job_id = @JobId,
     @server_name = N'(LOCAL)';

----------------------------------------------------------------------
-- Create transaction log backup job
----------------------------------------------------------------------

SET @JobId = NULL;

EXEC msdb.dbo.sp_add_job
     @job_name = @LogJobName,
     @enabled = 1,
     @description = N'Transaction log backup for ONLINE user databases using FULL or BULK_LOGGED recovery.',
     @start_step_id = 1,
     @category_name = N'Database Maintenance',
     @owner_login_name = @JobOwnerLoginName,
     @job_id = @JobId OUTPUT;

EXEC msdb.dbo.sp_add_jobstep
     @job_id = @JobId,
     @step_id = 1,
     @step_name = N'Backup Transaction Logs',
     @subsystem = N'TSQL',
     @database_name = N'master',
     @command = @LogCommand,
     @on_success_action = 1,
     @on_fail_action = 2,
     @retry_attempts = 0,
     @retry_interval = 0;

EXEC msdb.dbo.sp_add_jobschedule
     @job_id = @JobId,
     @name = @LogScheduleName,
     @enabled = 1,
     @freq_type = 4,           -- Daily
     @freq_interval = 1,       -- Every day
     @freq_subday_type = 4,    -- Minutes
     @freq_subday_interval = 15,
     @active_start_date = 20260731,
     @active_start_time = 000000,
     @active_end_time = 235959;

EXEC msdb.dbo.sp_add_jobserver
     @job_id = @JobId,
     @server_name = N'(LOCAL)';

----------------------------------------------------------------------
-- Display created jobs and schedules
----------------------------------------------------------------------

SELECT
    j.name AS JobName,
    j.enabled AS JobEnabled,
    s.name AS ScheduleName,
    s.enabled AS ScheduleEnabled,
    s.freq_type,
    s.freq_interval,
    s.freq_subday_type,
    s.freq_subday_interval,
    s.active_start_date,
    s.active_start_time,
    s.active_end_time
FROM msdb.dbo.sysjobs AS j
JOIN msdb.dbo.sysjobschedules AS js
    ON js.job_id = j.job_id
JOIN msdb.dbo.sysschedules AS s
    ON s.schedule_id = js.schedule_id
WHERE j.name IN (@FullJobName, @LogJobName)
ORDER BY j.name;

GO

------------------------------------------------------------------------------

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* ============================================================
   SQL Agent Job deployment settings
   ============================================================ */
DECLARE
    @JobName       sysname = N'_Maintenance.EveryDay',
    @ScheduleName  sysname = N'_Maintenance-Daily-1030',
    @JobOwner      sysname = N'sa',
    @Today         int,
    @JobId         uniqueidentifier,
    @JobCommand    nvarchar(max);

SET @Today = CONVERT(int, CONVERT(char(8), GETDATE(), 112));

/* ============================================================
   Delete the existing Job
   ============================================================ */
IF EXISTS
(
    SELECT 1
    FROM msdb.dbo.sysjobs
    WHERE name = @JobName
)
BEGIN
    EXEC msdb.dbo.sp_delete_job
         @job_name = @JobName,
         @delete_unused_schedule = 1;
END;

/* ============================================================
   Job command
   ============================================================ */
SET @JobCommand = N'
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE
    @RetentionDays       int = 30,
    @CutoffDate          datetime,
    @DatabaseName        sysname,
    @SqlCommand          nvarchar(max),
    @SaSid               varbinary(85),
    @DatabaseErrorCount  int = 0,
    @JobErrorCount       int = 0,
    @ErrorMessage        nvarchar(2048);

SET @CutoffDate = DATEADD(DAY, -@RetentionDays, GETDATE());
SET @SaSid = SUSER_SID(N''sa'');

IF @SaSid IS NULL
BEGIN
    THROW 51000, N''Login [sa] does not exist.'', 1;
END;

PRINT N''=================================================='';
PRINT N''MSDB maintenance started'';
PRINT N''Start time : '' + CONVERT(nvarchar(30), GETDATE(), 121);
PRINT N''Cutoff date: '' + CONVERT(nvarchar(30), @CutoffDate, 121);
PRINT N''=================================================='';

/* ============================================================
   1. Purge SQL Agent Job History
   ============================================================ */
BEGIN TRY
    PRINT N''[1/5] Purging SQL Agent Job History...'';

    EXEC msdb.dbo.sp_purge_jobhistory
         @oldest_date = @CutoffDate;

    PRINT N''SQL Agent Job History cleanup completed.'';
END TRY
BEGIN CATCH
    SET @ErrorMessage =
        N''SQL Agent Job History cleanup failed: ''
        + ERROR_MESSAGE();

    THROW 51001, @ErrorMessage, 1;
END CATCH;

/* ============================================================
   2. Purge backup and restore history
   ============================================================ */
BEGIN TRY
    PRINT N''[2/5] Purging Backup and Restore History...'';

    EXEC msdb.dbo.sp_delete_backuphistory
         @oldest_date = @CutoffDate;

    PRINT N''Backup and Restore History cleanup completed.'';
END TRY
BEGIN CATCH
    SET @ErrorMessage =
        N''Backup and Restore History cleanup failed: ''
        + ERROR_MESSAGE();

    THROW 51002, @ErrorMessage, 1;
END CATCH;

/* ============================================================
   3. Purge Database Mail history
   ============================================================ */
BEGIN TRY
    PRINT N''[3/5] Purging Database Mail items...'';

    EXEC msdb.dbo.sysmail_delete_mailitems_sp
         @sent_before = @CutoffDate;

    PRINT N''Database Mail items cleanup completed.'';

    PRINT N''Purging Database Mail event log...'';

    EXEC msdb.dbo.sysmail_delete_log_sp
         @logged_before = @CutoffDate;

    PRINT N''Database Mail event log cleanup completed.'';
END TRY
BEGIN CATCH
    SET @ErrorMessage =
        N''Database Mail cleanup failed: ''
        + ERROR_MESSAGE();

    THROW 51003, @ErrorMessage, 1;
END CATCH;

/* ============================================================
   4. Set database owners to sa

   Excludes:
   - tempdb
   - Database Snapshots
   - Offline databases
   ============================================================ */
PRINT N''[4/5] Checking database owners...'';

DECLARE DatabaseOwnerCursor CURSOR LOCAL FAST_FORWARD
FOR
    SELECT name
    FROM sys.databases
    WHERE name <> N''tempdb''
      AND source_database_id IS NULL
      AND state_desc = N''ONLINE''
      AND owner_sid <> @SaSid
    ORDER BY database_id;

OPEN DatabaseOwnerCursor;

FETCH NEXT FROM DatabaseOwnerCursor
INTO @DatabaseName;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @SqlCommand =
            N''ALTER AUTHORIZATION ON DATABASE::''
            + QUOTENAME(@DatabaseName)
            + N'' TO [sa];'';

        PRINT N''Changing database owner: ''
            + QUOTENAME(@DatabaseName)
            + N'' -> [sa]'';

        EXEC sys.sp_executesql @SqlCommand;
    END TRY
    BEGIN CATCH
        SET @DatabaseErrorCount += 1;

        PRINT N''WARNING: Failed to change database owner for ''
            + QUOTENAME(@DatabaseName)
            + N''. Error ''
            + CONVERT(nvarchar(20), ERROR_NUMBER())
            + N'': ''
            + ERROR_MESSAGE();
    END CATCH;

    FETCH NEXT FROM DatabaseOwnerCursor
    INTO @DatabaseName;
END;

CLOSE DatabaseOwnerCursor;
DEALLOCATE DatabaseOwnerCursor;

/* ============================================================
   5. Set SQL Agent Job owners to sa
   ============================================================ */
PRINT N''[5/5] Checking SQL Agent Job owners...'';

DECLARE
    @CurrentJobId   uniqueidentifier,
    @CurrentJobName sysname;

DECLARE JobOwnerCursor CURSOR LOCAL FAST_FORWARD
FOR
    SELECT
        job_id,
        name
    FROM msdb.dbo.sysjobs
    WHERE owner_sid <> @SaSid
    ORDER BY name;

OPEN JobOwnerCursor;

FETCH NEXT FROM JobOwnerCursor
INTO @CurrentJobId, @CurrentJobName;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        PRINT N''Changing SQL Agent Job owner: ''
            + QUOTENAME(@CurrentJobName)
            + N'' -> [sa]'';

        EXEC msdb.dbo.sp_update_job
             @job_id = @CurrentJobId,
             @owner_login_name = N''sa'';
    END TRY
    BEGIN CATCH
        SET @JobErrorCount += 1;

        PRINT N''WARNING: Failed to change SQL Agent Job owner for ''
            + QUOTENAME(@CurrentJobName)
            + N''. Error ''
            + CONVERT(nvarchar(20), ERROR_NUMBER())
            + N'': ''
            + ERROR_MESSAGE();
    END CATCH;

    FETCH NEXT FROM JobOwnerCursor
    INTO @CurrentJobId, @CurrentJobName;
END;

CLOSE JobOwnerCursor;
DEALLOCATE JobOwnerCursor;

/* ============================================================
   Final validation
   ============================================================ */
PRINT N''=================================================='';
PRINT N''Database owner failures: ''
    + CONVERT(nvarchar(20), @DatabaseErrorCount);

PRINT N''SQL Agent Job owner failures: ''
    + CONVERT(nvarchar(20), @JobErrorCount);

PRINT N''End time: ''
    + CONVERT(nvarchar(30), GETDATE(), 121);
PRINT N''=================================================='';

IF @DatabaseErrorCount > 0 OR @JobErrorCount > 0
BEGIN
    SET @ErrorMessage =
        N''MSDB maintenance completed with errors. ''
        + N''Database owner failures: ''
        + CONVERT(nvarchar(20), @DatabaseErrorCount)
        + N'', Job owner failures: ''
        + CONVERT(nvarchar(20), @JobErrorCount)
        + N''.'';

    THROW 51004, @ErrorMessage, 1;
END;

PRINT N''MSDB maintenance completed successfully.'';
';

/* ============================================================
   Create Job
   ============================================================ */
EXEC msdb.dbo.sp_add_job
     @job_name = @JobName,
     @enabled = 1,
     @description = N'
MSDB maintenance:
1. Retain SQL Agent Job History for 30 days
2. Retain Backup and Restore History for 30 days
3. Retain Database Mail History for 30 days
4. Set online database owners to sa
5. Set SQL Agent Job owners to sa
Schedule: Daily at 10:30',
     @category_name = N'Database Maintenance',
     @owner_login_name = @JobOwner,
     @job_id = @JobId OUTPUT;

/* ============================================================
   Add Job Step
   ============================================================ */
EXEC msdb.dbo.sp_add_jobstep
     @job_id = @JobId,
     @step_name = N'MaintainMSDBAndOwners',
     @step_id = 1,
     @subsystem = N'TSQL',
     @command = @JobCommand,
     @database_name = N'msdb',
     @on_success_action = 1,  -- Quit with success
     @on_fail_action = 2,     -- Quit with failure
     @retry_attempts = 0,
     @retry_interval = 0;

/* Set the first execution step */
EXEC msdb.dbo.sp_update_job
     @job_id = @JobId,
     @start_step_id = 1;

/* ============================================================
   Create daily schedule at 10:30
   ============================================================ */
EXEC msdb.dbo.sp_add_schedule
     @schedule_name = @ScheduleName,
     @enabled = 1,
     @freq_type = 4,               -- Daily
     @freq_interval = 1,           -- Every 1 day
     @freq_subday_type = 1,        -- Execute once
     @active_start_date = @Today,
     @active_start_time = 103000;  -- 10:30:00

EXEC msdb.dbo.sp_attach_schedule
     @job_id = @JobId,
     @schedule_name = @ScheduleName;

/* Assign Job to the local SQL Server */
EXEC msdb.dbo.sp_add_jobserver
     @job_id = @JobId,
     @server_name = N'(LOCAL)';

PRINT N'Job created successfully: ' + @JobName;
PRINT N'Schedule: Daily at 10:30';
GO


DECLARE @Jobs TABLE
(
    JobName sysname
);

INSERT INTO @Jobs (JobName)
VALUES (N'_BackupFull-Split'),(N'_BackupTransactionLog-Split');

DECLARE @JobName sysname;
DECLARE JobCursor CURSOR LOCAL FAST_FORWARD FOR SELECT JobName FROM @Jobs;

OPEN JobCursor;

FETCH NEXT FROM JobCursor INTO @JobName;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF EXISTS
    (
        SELECT 1 FROM dbo.sysjobs WHERE [name] = @JobName
    )
    BEGIN
        EXEC dbo.sp_update_job @job_name = @JobName, @enabled = 0;
        PRINT N'Disabled: ' + @JobName;
    END
    ELSE
    BEGIN
        PRINT N'Not found: ' + @JobName;
    END;

    FETCH NEXT FROM JobCursor INTO @JobName;
END;

CLOSE JobCursor;
DEALLOCATE JobCursor;
GO
