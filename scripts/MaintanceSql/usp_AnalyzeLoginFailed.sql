USE [MS_PERF_COLLECTION]
GO
IF  EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[LoginFailed]') AND type in (N'U'))
DROP TABLE [dbo].[LoginFailed]
GO
CREATE TABLE LoginFailed
(
    LogDate         DATETIME,
    LoginName       NVARCHAR(256),
    FailureType     VARCHAR(50),
    Reason          NVARCHAR(2000),
    ClientIP        VARCHAR(48),
    ProcessInfo     NVARCHAR(50),
    ErrorText       NVARCHAR(MAX)
);
GO
CREATE OR ALTER PROCEDURE dbo.usp_AnalyzeLoginFailed
(
    @StartTime      DATETIME = NULL,
    @EndTime        DATETIME = NULL,
    @LoginName      SYSNAME = NULL,
    @ClientIP       VARCHAR(48) = NULL,
    @MaxArchiveNo   INT = 10
)
AS
BEGIN
    SET NOCOUNT ON;


    ----------------------------------------------------------------
    -- Default: Previous calendar day
    ----------------------------------------------------------------
    IF @StartTime IS NULL
        SET @StartTime = DATEADD(DAY, -1, CONVERT(DATE, GETDATE()));

    IF @EndTime IS NULL
        SET @EndTime = CONVERT(DATE, GETDATE());


    ----------------------------------------------------------------
    -- Validate input parameters
    ----------------------------------------------------------------
    IF @StartTime >= @EndTime
    BEGIN
        RAISERROR('@StartTime must be earlier than @EndTime.', 16, 1);
        RETURN;
    END;

    IF @MaxArchiveNo < 0
    BEGIN
        RAISERROR('@MaxArchiveNo must be 0 or greater.', 16, 1);
        RETURN;
    END;


    ----------------------------------------------------------------
    -- 1. Get available SQL Server Error Logs
    ----------------------------------------------------------------
    CREATE TABLE #ErrorLogs
    (
        ArchiveNo      INT,
        LogDate        DATETIME,
        LogFileSize    BIGINT
    );

    INSERT INTO #ErrorLogs
    EXEC master.dbo.sp_enumerrorlogs;


    ----------------------------------------------------------------
    -- 2. Read SQL Server Error Logs
    ----------------------------------------------------------------
    CREATE TABLE #RawLog
    (
        LogDate        DATETIME,
        ProcessInfo    NVARCHAR(50),
        [Text]         NVARCHAR(MAX)
    );

    DECLARE @LogNo INT = 0;

    WHILE @LogNo <= @MaxArchiveNo
    BEGIN

        -- Read only Error Logs that actually exist
        IF EXISTS
        (
            SELECT 1
            FROM #ErrorLogs
            WHERE ArchiveNo = @LogNo
        )
        BEGIN
            INSERT INTO #RawLog
            (
                LogDate,
                ProcessInfo,
                [Text]
            )
            EXEC master.dbo.xp_readerrorlog
                 @LogNo,
                 1,
                 N'Login failed for user',
                 NULL,
                 @StartTime,
                 @EndTime,
                 N'ASC';
        END;

        SET @LogNo += 1;
    END;


    ----------------------------------------------------------------
    -- 3. Parse Login Name, Failure Reason, and Client IP
    ----------------------------------------------------------------
    CREATE TABLE #LoginFailed
    (
        LogDate         DATETIME,
        LoginName       NVARCHAR(256),
        FailureType     VARCHAR(50),
        Reason          NVARCHAR(2000),
        ClientIP        VARCHAR(48),
        ProcessInfo     NVARCHAR(50),
        ErrorText       NVARCHAR(MAX)
    );


    INSERT INTO #LoginFailed
    (
        LogDate,
        LoginName,
        FailureType,
        Reason,
        ClientIP,
        ProcessInfo,
        ErrorText
    )
    SELECT
        R.LogDate,

        ----------------------------------------------------------------
        -- Login Name
        ----------------------------------------------------------------
        CASE
            WHEN P.LoginStart > 0
             AND P.LoginEnd > P.LoginStart
            THEN
                SUBSTRING
                (
                    R.[Text],
                    P.LoginStart,
                    P.LoginEnd - P.LoginStart
                )
        END AS LoginName,


        ----------------------------------------------------------------
        -- Failure Type
        ----------------------------------------------------------------
        CASE
            WHEN R.[Text] LIKE N'%locked out%'
                THEN 'ACCOUNT_LOCKED'

            WHEN R.[Text] LIKE N'%password did not match%'
                THEN 'BAD_PASSWORD'

            WHEN R.[Text] LIKE N'%login does not exist%'
              OR R.[Text] LIKE N'%Could not find a login matching%'
                THEN 'LOGIN_NOT_FOUND'

            WHEN R.[Text] LIKE N'%login is disabled%'
                THEN 'LOGIN_DISABLED'

            WHEN R.[Text] LIKE N'%failed to open the explicitly specified database%'
                THEN 'DATABASE_ACCESS'

            WHEN R.[Text] LIKE N'%untrusted domain%'
                THEN 'UNTRUSTED_DOMAIN'

            WHEN R.[Text] LIKE N'%server is in single user mode%'
                THEN 'SINGLE_USER_MODE'

            WHEN R.[Text] LIKE N'%infrastructure error%'
                THEN 'INFRASTRUCTURE_ERROR'

            ELSE 'OTHER'
        END AS FailureType,


        ----------------------------------------------------------------
        -- Failure Reason
        ----------------------------------------------------------------
        CASE
            WHEN P.ReasonStart > 0
            THEN
                TRIM
                (
                    SUBSTRING
                    (
                        R.[Text],
                        P.ReasonStart + LEN(N'Reason:'),

                        CASE
                            WHEN P.ClientStart > P.ReasonStart
                            THEN
                                P.ClientStart
                                - (P.ReasonStart + LEN(N'Reason:'))

                            ELSE
                                LEN(R.[Text])
                        END
                    )
                )
        END AS Reason,


        ----------------------------------------------------------------
        -- Client IP Address
        ----------------------------------------------------------------
        CASE
            WHEN P.ClientStart > 0
             AND P.ClientEnd > P.ClientStart
            THEN
                TRIM
                (
                    SUBSTRING
                    (
                        R.[Text],
                        P.ClientStart + LEN(N'[CLIENT:'),

                        P.ClientEnd
                        - (P.ClientStart + LEN(N'[CLIENT:'))
                    )
                )
        END AS ClientIP,


        R.ProcessInfo,
        R.[Text]

    FROM #RawLog AS R

    CROSS APPLY
    (
        SELECT
            CHARINDEX
            (
                N'Login failed for user ''',
                R.[Text]
            ) + LEN(N'Login failed for user ''') AS LoginStart,

            CHARINDEX
            (
                N'Reason:',
                R.[Text]
            ) AS ReasonStart,

            CHARINDEX
            (
                N'[CLIENT:',
                R.[Text]
            ) AS ClientStart
    ) AS A

    CROSS APPLY
    (
        SELECT
            A.LoginStart,

            CHARINDEX
            (
                N'''',
                R.[Text],
                A.LoginStart
            ) AS LoginEnd,

            A.ReasonStart,
            A.ClientStart,

            CASE
                WHEN A.ClientStart > 0
                THEN
                    CHARINDEX
                    (
                        N']',
                        R.[Text],
                        A.ClientStart
                    )
            END AS ClientEnd
    ) AS P;


    ----------------------------------------------------------------
    -- 4. Login Failure Details
    ----------------------------------------------------------------
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DELETE FROM dbo.LoginFailed
        WHERE LogDate >= @StartTime
          AND LogDate < @EndTime;

        INSERT INTO dbo.LoginFailed
        (
            LogDate,
            LoginName,
            FailureType,
            Reason,
            ClientIP,
            ProcessInfo,
            ErrorText
        )
        SELECT
            LogDate,
            LoginName,
            FailureType,
            Reason,
            ClientIP,
            ProcessInfo,
            ErrorText
        FROM #LoginFailed
        WHERE LogDate >= @StartTime
          AND LogDate < @EndTime;

        DELETE FROM dbo.LoginFailed
        WHERE LogDate < DATEADD
        (
            DAY,
            -30,
            CONVERT(DATE, GETDATE())
        );

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH;


    ----------------------------------------------------------------
    -- 5. Login Failure Summary
    ----------------------------------------------------------------
    SELECT
        LoginName,
        ClientIP,
        FailureType,
        COUNT(*) AS FailedCount,
        MIN(LogDate) AS FirstFailedTime,
        MAX(LogDate) AS LastFailedTime
    FROM #LoginFailed
    WHERE
        (@LoginName IS NULL OR LoginName = @LoginName)
        AND
        (@ClientIP IS NULL OR ClientIP = @ClientIP)
    GROUP BY
        LoginName,
        ClientIP,
        FailureType
    ORDER BY
        FailedCount DESC;

END;
GO
