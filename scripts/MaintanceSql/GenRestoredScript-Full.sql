USE msdb;
GO

SET NOCOUNT ON;

DECLARE @DatabaseName        sysname = N'agilebetsyslog';
DECLARE @RestoreDatabaseName sysname = N'agilebetsyslog_RESTORE';

-- Restore destination directories
DECLARE @TargetDataPath nvarchar(4000) = N'T:\MSSQL\DATA\';
DECLARE @TargetLogPath  nvarchar(4000) = N'L:\MSSQL\LOG\';
DECLARE @SourceBackupServer nvarchar(255) = N'';
DECLARE @TargetBackupServer nvarchar(255) = N'';
DECLARE @FullBackupSetId int;
DECLARE @DiffBackupSetId int;
DECLARE @FullCheckpointLSN numeric(25,0);
DECLARE @RestoreStartLSN numeric(25,0);

------------------------------------------------------------
-- Ensure destination paths end with \
------------------------------------------------------------
IF RIGHT(@TargetDataPath, 1) <> '\'
    SET @TargetDataPath += '\';

IF RIGHT(@TargetLogPath, 1) <> '\'
    SET @TargetLogPath += '\';

------------------------------------------------------------
-- 1. Find the latest valid Full Backup
------------------------------------------------------------
SELECT TOP (1)
    @FullBackupSetId   = bs.backup_set_id,
    @FullCheckpointLSN = bs.checkpoint_lsn
FROM msdb.dbo.backupset AS bs
WHERE bs.database_name = @DatabaseName
  AND bs.type = 'D'
  AND bs.is_copy_only = 0
  AND bs.backup_finish_date IS NOT NULL
ORDER BY bs.backup_finish_date DESC;

IF @FullBackupSetId IS NULL
BEGIN
    RAISERROR('Full Backup not found.', 16, 1);
    RETURN;
END;

------------------------------------------------------------
-- 2. Find the latest Differential Backup based on this Full
------------------------------------------------------------
SELECT TOP (1)
    @DiffBackupSetId = bs.backup_set_id
FROM msdb.dbo.backupset AS bs
WHERE bs.database_name = @DatabaseName
  AND bs.type = 'I'
  AND bs.database_backup_lsn = @FullCheckpointLSN
  AND bs.backup_finish_date IS NOT NULL
ORDER BY bs.backup_finish_date DESC;

------------------------------------------------------------
-- 3. Determine the starting LSN for Transaction Log restore
------------------------------------------------------------
IF @DiffBackupSetId IS NOT NULL
BEGIN
    SELECT
        @RestoreStartLSN = bs.last_lsn
    FROM msdb.dbo.backupset AS bs
    WHERE bs.backup_set_id = @DiffBackupSetId;
END
ELSE
BEGIN
    SELECT
        @RestoreStartLSN = bs.checkpoint_lsn
    FROM msdb.dbo.backupset AS bs
    WHERE bs.backup_set_id = @FullBackupSetId;
END;

------------------------------------------------------------
-- 4. Build Restore Chain
------------------------------------------------------------
IF OBJECT_ID('tempdb..#RestoreChain') IS NOT NULL
    DROP TABLE #RestoreChain;

CREATE TABLE #RestoreChain
(
    Seq                 int IDENTITY(1,1),
    backup_set_id       int,
    backup_type         varchar(10),
    backup_start_date   datetime,
    backup_finish_date  datetime,
    first_lsn           numeric(25,0),
    last_lsn            numeric(25,0),
    checkpoint_lsn      numeric(25,0),
    database_backup_lsn numeric(25,0)
);

------------------------------------------------------------
-- Full Backup
------------------------------------------------------------
INSERT INTO #RestoreChain
(
    backup_set_id,
    backup_type,
    backup_start_date,
    backup_finish_date,
    first_lsn,
    last_lsn,
    checkpoint_lsn,
    database_backup_lsn
)
SELECT
    bs.backup_set_id,
    'FULL',
    bs.backup_start_date,
    bs.backup_finish_date,
    bs.first_lsn,
    bs.last_lsn,
    bs.checkpoint_lsn,
    bs.database_backup_lsn
FROM msdb.dbo.backupset AS bs
WHERE bs.backup_set_id = @FullBackupSetId;

------------------------------------------------------------
-- Differential Backup
------------------------------------------------------------
IF @DiffBackupSetId IS NOT NULL
BEGIN
    INSERT INTO #RestoreChain
    (
        backup_set_id,
        backup_type,
        backup_start_date,
        backup_finish_date,
        first_lsn,
        last_lsn,
        checkpoint_lsn,
        database_backup_lsn
    )
    SELECT
        bs.backup_set_id,
        'DIFF',
        bs.backup_start_date,
        bs.backup_finish_date,
        bs.first_lsn,
        bs.last_lsn,
        bs.checkpoint_lsn,
        bs.database_backup_lsn
    FROM msdb.dbo.backupset AS bs
    WHERE bs.backup_set_id = @DiffBackupSetId;
END;

------------------------------------------------------------
-- Transaction Log Backups
------------------------------------------------------------
INSERT INTO #RestoreChain
(
    backup_set_id,
    backup_type,
    backup_start_date,
    backup_finish_date,
    first_lsn,
    last_lsn,
    checkpoint_lsn,
    database_backup_lsn
)
SELECT
    bs.backup_set_id,
    'LOG',
    bs.backup_start_date,
    bs.backup_finish_date,
    bs.first_lsn,
    bs.last_lsn,
    bs.checkpoint_lsn,
    bs.database_backup_lsn
FROM msdb.dbo.backupset AS bs
WHERE bs.database_name = @DatabaseName
  AND bs.type = 'L'
  AND bs.last_lsn > @RestoreStartLSN
ORDER BY
    bs.first_lsn,
    bs.backup_finish_date;

------------------------------------------------------------
-- 5. Display Restore Chain
------------------------------------------------------------
SELECT
    rc.Seq,
    rc.backup_type,
    rc.backup_start_date,
    rc.backup_finish_date,
    rc.first_lsn,
    rc.last_lsn,
    rc.checkpoint_lsn,
    rc.database_backup_lsn,
    rc.backup_set_id
FROM #RestoreChain AS rc
ORDER BY rc.Seq;

------------------------------------------------------------
-- 6. Display Database Files contained in the Full Backup
------------------------------------------------------------
SELECT
    bf.logical_name,
    bf.physical_name,
    bf.file_type,
    CASE bf.file_type
        WHEN 'D' THEN 'DATA'
        WHEN 'L' THEN 'LOG'
        ELSE bf.file_type
    END AS FileType
FROM msdb.dbo.backupfile AS bf
WHERE bf.backup_set_id = @FullBackupSetId
ORDER BY
    bf.file_type,
    bf.file_number;

	------------------------------------------------------------
	-- 7. Generate Restore Commands
	------------------------------------------------------------
	IF OBJECT_ID('tempdb..#RestoreCommand') IS NOT NULL
		DROP TABLE #RestoreCommand;

	CREATE TABLE #RestoreCommand
	(
		Seq            int,
		RestoreCommand nvarchar(max)
	);

	DECLARE
		@BackupSetId int,
		@BackupType  varchar(10),
		@BackupFiles nvarchar(max),
		@MoveFiles   nvarchar(max),
		@Command     nvarchar(max),
		@Seq         int,
		@CRLF        nvarchar(2) = CHAR(13) + CHAR(10);

	DECLARE restore_cursor CURSOR LOCAL FAST_FORWARD
	FOR
	SELECT
		Seq,
		backup_set_id,
		backup_type
	FROM #RestoreChain
	ORDER BY Seq;

	OPEN restore_cursor;

	FETCH NEXT FROM restore_cursor
	INTO @Seq, @BackupSetId, @BackupType;

	WHILE @@FETCH_STATUS = 0
	BEGIN

		SET @BackupFiles = NULL;
		SET @MoveFiles   = NULL;
		SET @Command     = NULL;

		--------------------------------------------------------
		-- Generate striped backup file list
		--------------------------------------------------------
		SELECT
			@BackupFiles =
				STUFF
				(
					(
						SELECT
							N',' +
							@CRLF +
							N'    DISK = N''' +
							REPLACE
							(
								bmf.physical_device_name,
								'''',
								''''''
							) +
							N''''
						FROM msdb.dbo.backupset AS bs2
						INNER JOIN msdb.dbo.backupmediafamily AS bmf
							ON bs2.media_set_id = bmf.media_set_id
						WHERE bs2.backup_set_id = @BackupSetId
						ORDER BY
							bmf.family_sequence_number
						FOR XML PATH(''), TYPE
					).value('.', 'nvarchar(max)')
				,1,3,N'');

		--------------------------------------------------------
		-- FULL Backup
		--------------------------------------------------------
		IF @BackupType = 'FULL'
		BEGIN

			----------------------------------------------------
			-- Generate MOVE clauses
			----------------------------------------------------
			SELECT
				@MoveFiles =
					STUFF
					(
						(
							SELECT
								N',' +
								@CRLF +

								N'    MOVE N''' +
								REPLACE
								(
									bf.logical_name,
									'''',
									''''''
								) +
								N''' TO N''' +

								CASE bf.file_type

									------------------------------------------------
									-- DATA: MDF / NDF
									------------------------------------------------
									WHEN 'D'
									THEN
										@TargetDataPath +
										RIGHT
										(
											bf.physical_name,
											CHARINDEX
											(
												'\',
												REVERSE(bf.physical_name)
											) - 1
										)

									------------------------------------------------
									-- LOG: LDF
									------------------------------------------------
									WHEN 'L'
									THEN
										@TargetLogPath +
										RIGHT
										(
											bf.physical_name,
											CHARINDEX
											(
												'\',
												REVERSE(bf.physical_name)
											) - 1
										)

								END +

								N''''
							FROM msdb.dbo.backupfile AS bf
							WHERE bf.backup_set_id = @FullBackupSetId
							  AND bf.file_type IN ('D', 'L')
							ORDER BY
								bf.file_type,
								bf.file_number
							FOR XML PATH(''), TYPE
						).value('.', 'nvarchar(max)')
					,1,3,N'');

			----------------------------------------------------
			-- Build FULL Restore Command
			----------------------------------------------------
			SET @Command =
				  N'RESTORE DATABASE '
				+ QUOTENAME(@RestoreDatabaseName)
				+ @CRLF

				+ N'FROM'
				+ @CRLF

				+ @BackupFiles
				+ @CRLF

				+ N'WITH'
				+ @CRLF

				+ @MoveFiles
				+ N','
				+ @CRLF

				+ N'    NORECOVERY,'
				+ @CRLF

				+ N'    BUFFERCOUNT = 128,'
				+ @CRLF

				+ N'    MAXTRANSFERSIZE = 4194304,'
				+ @CRLF

				+ N'    STATS = 5;'
				+ @CRLF;
		END;

		--------------------------------------------------------
		-- Differential Backup
		--------------------------------------------------------
		IF @BackupType = 'DIFF'
		BEGIN

			SET @Command =
				  N'RESTORE DATABASE '
				+ QUOTENAME(@RestoreDatabaseName)
				+ @CRLF

				+ N'FROM'
				+ @CRLF

				+ @BackupFiles
				+ @CRLF

				+ N'WITH'
				+ @CRLF

				+ N'    NORECOVERY,'
				+ @CRLF

				+ N'    STATS = 5;'
				+ @CRLF;
		END;

		--------------------------------------------------------
		-- Transaction Log Backup
		--------------------------------------------------------
		IF @BackupType = 'LOG'
		BEGIN

			SET @Command =
				  N'RESTORE LOG '
				+ QUOTENAME(@RestoreDatabaseName)
				+ @CRLF

				+ N'FROM'
				+ @CRLF

				+ @BackupFiles
				+ @CRLF

				+ N'WITH'
				+ @CRLF

				+ N'    NORECOVERY,'
				+ @CRLF

				+ N'    STATS = 5;'
				+ @CRLF;
		END;

		--------------------------------------------------------
		-- Store generated command
		--------------------------------------------------------
		INSERT INTO #RestoreCommand
		(
			Seq,
			RestoreCommand
		)
		VALUES
		(
			@Seq,
			@Command
		);

		FETCH NEXT FROM restore_cursor
		INTO @Seq, @BackupSetId, @BackupType;
	END;

	CLOSE restore_cursor;
	DEALLOCATE restore_cursor;

------------------------------------------------------------
-- 8. Final RECOVERY
------------------------------------------------------------
INSERT INTO #RestoreCommand
(
    Seq,
    RestoreCommand
)
VALUES
(
    999999,
    N'RESTORE DATABASE ' +
    QUOTENAME(@RestoreDatabaseName) +
    N' WITH RECOVERY;'
);

------------------------------------------------------------
-- 9. Output the complete Restore Script
--    Print line by line to avoid PRINT 4000-char limit
------------------------------------------------------------
DECLARE
    @PrintCommand nvarchar(max),
    @PrintLine    nvarchar(max),
    @Position     int,
    @NextPosition int;

DECLARE print_cursor CURSOR LOCAL FAST_FORWARD
FOR
SELECT
    CASE
        WHEN NULLIF(@SourceBackupServer, N'') IS NOT NULL
         AND NULLIF(@TargetBackupServer, N'') IS NOT NULL
        THEN
            REPLACE
            (
                RestoreCommand,
                @SourceBackupServer,
                @TargetBackupServer
            )
        ELSE
            RestoreCommand
    END
FROM #RestoreCommand
ORDER BY Seq;

OPEN print_cursor;

FETCH NEXT FROM print_cursor
INTO @PrintCommand;

WHILE @@FETCH_STATUS = 0
BEGIN

    SET @Position = 1;

    --------------------------------------------------------
    -- Print one line at a time
    --------------------------------------------------------
    WHILE @Position <= LEN(@PrintCommand)
    BEGIN

        SET @NextPosition =
            CHARINDEX
            (
                @CRLF,
                @PrintCommand,
                @Position
            );

        IF @NextPosition = 0
        BEGIN
            SET @PrintLine =
                SUBSTRING
                (
                    @PrintCommand,
                    @Position,
                    LEN(@PrintCommand) - @Position + 1
                );

            PRINT @PrintLine;

            BREAK;
        END;

        SET @PrintLine =
            SUBSTRING
            (
                @PrintCommand,
                @Position,
                @NextPosition - @Position
            );

        PRINT @PrintLine;

        SET @Position =
            @NextPosition + LEN(@CRLF);
    END;

    --------------------------------------------------------
    -- Blank line between Restore Commands
    --------------------------------------------------------
    PRINT N'';

    FETCH NEXT FROM print_cursor
    INTO @PrintCommand;
END;

CLOSE print_cursor;
DEALLOCATE print_cursor;