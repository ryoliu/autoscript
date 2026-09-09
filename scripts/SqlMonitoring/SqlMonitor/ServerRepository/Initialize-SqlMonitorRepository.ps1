<#
.SYNOPSIS
Creates and configures the SQL monitoring repository when required.

.DESCRIPTION
Runs on ServerRepository, reads the repository target from repository.config,
connects with Windows authentication when possible, and requests a fallback SQL
administrator credential when required. The database, schema, and table are
created only when missing. The six GetDBInfo report tables and their indexes
are also created in dbo. The table row-count forecast procedure is created or
updated, and the GetDBInfo SQL Agent Job is created when missing. Existing
tables are never dropped or rebuilt.

The configured service SQL Login must already exist on the repository instance. Its database
user is created or remapped and added to the db_owner database role. The service
credential is used for a final repository validation.

.PARAMETER ConfigPath
Path to the repository configuration file. The default is repository.config in
the shared Config directory.

.PARAMETER RepositoryInstance
Optional SQL Server instance that overrides RepositoryInstance in the
repository configuration file.

.PARAMETER RepositoryDatabase
Optional database name that overrides RepositoryDatabase in the repository
configuration file.

.PARAMETER RepositorySchema
Optional schema name that overrides RepositorySchema in the repository
configuration file.

.PARAMETER RepositoryTable
Optional table name that overrides RepositoryTable in the repository
configuration file.

.PARAMETER SqlLoginName
Optional SQL Login mapped to the repository database and added to db_owner. It
overrides SqlLoginName in repository.config.

.PARAMETER ServiceCredential
Credential used for the final repository validation. When omitted, the script
prompts for it.

.PARAMETER SqlAdminCredential
Optional fallback SQL administrator credential used when Windows authentication
does not have sysadmin or CONTROL SERVER.

.EXAMPLE
.\Initialize-SqlMonitorRepository.ps1

Creates the Instance list table, GetDBInfo report tables, forecast procedure,
SQL Agent Job, and configures the service Login as db_owner.

.NOTES
Run Start-ServerRepositorySetup.ps1 to provision the repository Login before
initializing the repository when the configured service SQL Login does not exist.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath = (
        Join-Path `
            (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) `
            "Config\repository.config"
    ),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$RepositoryInstance,

    [Parameter()]
    [ValidatePattern('^[A-Za-z_][A-Za-z0-9_@$#]*$')]
    [string]$RepositoryDatabase,

    [Parameter()]
    [ValidatePattern('^[A-Za-z_][A-Za-z0-9_@$#]*$')]
    [string]$RepositorySchema,

    [Parameter()]
    [ValidatePattern('^[A-Za-z_][A-Za-z0-9_@$#]*$')]
    [string]$RepositoryTable,

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$SqlLoginName,

    [Parameter()]
    [PSCredential]$ServiceCredential,

    [Parameter()]
    [PSCredential]$SqlAdminCredential,

    [Parameter()]
    [ValidateRange(1, 300)]
    [int]$ConnectionTimeoutSeconds = 15,

    [Parameter()]
    [ValidateRange(1, 3600)]
    [int]$CommandTimeoutSeconds = 30,

    [Parameter()]
    [ValidateRange(0, 20)]
    [int]$RetryCount = 3,

    [Parameter()]
    [ValidateRange(0, 300)]
    [int]$RetryDelaySeconds = 2,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$LogDirectory = (Join-Path $PSScriptRoot "Logs"),

    [Parameter()]
    [psobject]$LogContext
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$CommonModulePath = Join-Path `
    (Split-Path -Parent $PSScriptRoot) `
    "Modules\SqlMaintenance.Common\SqlMaintenance.Common.psm1"

if (-not (Test-Path -LiteralPath $CommonModulePath -PathType Leaf)) {
    throw "Required module not found: $CommonModulePath"
}

Import-Module $CommonModulePath -Force

$RepositoryConfigParameters = @{
    LiteralPath = $ConfigPath
}

foreach (
    $RepositoryParameterName in @(
        "RepositoryInstance",
        "RepositoryDatabase",
        "RepositorySchema",
        "RepositoryTable"
    )
) {
    if ($PSBoundParameters.ContainsKey($RepositoryParameterName)) {
        $RepositoryConfigParameters[$RepositoryParameterName] =
            $PSBoundParameters[$RepositoryParameterName]
    }
}

$RepositoryConfig =
    Get-SqlRepositoryConfig @RepositoryConfigParameters
$RepositoryInstance = $RepositoryConfig.RepositoryInstance
$RepositoryDatabase = $RepositoryConfig.RepositoryDatabase
$RepositorySchema = $RepositoryConfig.RepositorySchema
$RepositoryTable = $RepositoryConfig.RepositoryTable

if (-not $PSBoundParameters.ContainsKey("SqlLoginName")) {
    $SqlLoginName = $RepositoryConfig.SqlLoginName
}

if (
    $RepositoryDatabase -in @(
        "master",
        "model",
        "msdb",
        "tempdb"
    )
) {
    throw (
        "System database [$RepositoryDatabase] cannot be used as the " +
        "monitoring repository."
    )
}

if ($null -eq $LogContext) {
    $LogContext = New-SqlMaintenanceLogContext `
        -LogDirectory $LogDirectory `
        -OperationName "Initialize-SqlMonitorRepository"
}

if ($null -eq $ServiceCredential) {
    $ServiceCredential = Get-Credential `
        -UserName $SqlLoginName `
        -Message "Enter the service SQL Login credential"
}

if ($null -eq $ServiceCredential) {
    throw "A service SQL Login credential is required."
}

if ($ServiceCredential.UserName -cne $SqlLoginName) {
    throw (
        "Credential user [$($ServiceCredential.UserName)] does not match " +
        "SqlLoginName [$SqlLoginName]."
    )
}

$CurrentWindowsAccount =
    [Security.Principal.WindowsIdentity]::GetCurrent().Name
$UseIntegratedSecurity = $false
$ReadOnlyAdminPassword = $null
$AdministratorSqlCredential = $null
$ReadOnlyServicePassword = $ServiceCredential.Password.Copy()
$ReadOnlyServicePassword.MakeReadOnly()
$ServiceSqlCredential = [System.Data.SqlClient.SqlCredential]::new(
    $ServiceCredential.UserName,
    $ReadOnlyServicePassword
)

function Test-RepositoryAdministratorPermission {
    [CmdletBinding()]
    param(
        [Parameter()]
        [System.Data.SqlClient.SqlCredential]$Credential,

        [Parameter()]
        [switch]$IntegratedSecurity
    )

    Invoke-SqlWithRetry `
        -Step "RepositoryAdminPreflight" `
        -Instance $RepositoryInstance `
        -RetryCount $RetryCount `
        -RetryDelaySeconds $RetryDelaySeconds `
        -LogContext $LogContext `
        -Operation {
            if ($IntegratedSecurity) {
                $Connection = New-SqlConnection `
                    -DataSource $RepositoryInstance `
                    -InitialCatalog "master" `
                    -IntegratedSecurity `
                    -ConnectionTimeoutSeconds $ConnectionTimeoutSeconds `
                    -ApplicationName "Repository Administrator Preflight"
            }
            else {
                $Connection = New-SqlConnection `
                    -DataSource $RepositoryInstance `
                    -InitialCatalog "master" `
                    -SqlCredential $Credential `
                    -ConnectionTimeoutSeconds $ConnectionTimeoutSeconds `
                    -ApplicationName "Repository Administrator Preflight"
            }

            try {
                $Connection.Open()
                $Command = $Connection.CreateCommand()

                try {
                    $Command.CommandTimeout = $CommandTimeoutSeconds
                    $Command.CommandText = @"
SELECT
    SYSTEM_USER AS [LoginName],
    CASE WHEN IS_SRVROLEMEMBER(N'sysadmin') = 1 THEN 1 ELSE 0 END
        AS [IsSysadmin],
    CASE WHEN HAS_PERMS_BY_NAME(NULL, NULL, N'CONTROL SERVER') = 1
         THEN 1 ELSE 0 END AS [HasControlServer];
"@
                    $Reader = $Command.ExecuteReader()

                    try {
                        [void]$Reader.Read()
                        [pscustomobject]@{
                            LoginName = [string]$Reader["LoginName"]
                            IsSysadmin =
                                [int]$Reader["IsSysadmin"] -eq 1
                            HasControlServer =
                                [int]$Reader["HasControlServer"] -eq 1
                        }
                    }
                    finally {
                        $Reader.Dispose()
                    }
                }
                finally {
                    $Command.Dispose()
                }
            }
            finally {
                $Connection.Dispose()
            }
        }
}

function New-RepositoryAdministratorConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$InitialCatalog,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ApplicationName
    )

    if ($UseIntegratedSecurity) {
        return New-SqlConnection `
            -DataSource $RepositoryInstance `
            -InitialCatalog $InitialCatalog `
            -IntegratedSecurity `
            -ConnectionTimeoutSeconds $ConnectionTimeoutSeconds `
            -ApplicationName $ApplicationName
    }

    New-SqlConnection `
        -DataSource $RepositoryInstance `
        -InitialCatalog $InitialCatalog `
        -SqlCredential $AdministratorSqlCredential `
        -ConnectionTimeoutSeconds $ConnectionTimeoutSeconds `
        -ApplicationName $ApplicationName
}

try {
    $WindowsPermission = $null

    try {
        $WindowsPermission =
            Test-RepositoryAdministratorPermission -IntegratedSecurity
    }
    catch {
        Write-SqlMaintenanceLog `
            -LogContext $LogContext `
            -Level Warning `
            -Step "RepositoryAdminPreflight" `
            -Instance $RepositoryInstance `
            -Message (
                "Windows authentication failed for " +
                "[$CurrentWindowsAccount]: $($_.Exception.Message)"
            )
    }

    if (
        $null -ne $WindowsPermission -and
        ($WindowsPermission.IsSysadmin -or
            $WindowsPermission.HasControlServer)
    ) {
        $UseIntegratedSecurity = $true
        $AdministratorLoginName = $WindowsPermission.LoginName
        $AuthenticationMode = "Windows"
    }
    else {
        if ($null -ne $WindowsPermission) {
            Write-Warning (
                "Windows account [$CurrentWindowsAccount] can connect to " +
                "[$RepositoryInstance] but lacks sysadmin or CONTROL SERVER."
            )
        }

        if ($null -eq $SqlAdminCredential) {
            $SqlAdminCredential = Get-Credential `
                -UserName "zabbix" `
                -Message (
                    "Enter a SQL Login with sysadmin or CONTROL SERVER on " +
                    "the repository instance"
                )
        }

        if ($null -eq $SqlAdminCredential) {
            throw "A SQL administrator credential is required."
        }

        $ReadOnlyAdminPassword = $SqlAdminCredential.Password.Copy()
        $ReadOnlyAdminPassword.MakeReadOnly()
        $AdministratorSqlCredential =
            [System.Data.SqlClient.SqlCredential]::new(
                $SqlAdminCredential.UserName,
                $ReadOnlyAdminPassword
            )
        $SqlPermission = Test-RepositoryAdministratorPermission `
            -Credential $AdministratorSqlCredential

        if (
            -not $SqlPermission.IsSysadmin -and
            -not $SqlPermission.HasControlServer
        ) {
            throw (
                "SQL Login [$($SqlPermission.LoginName)] lacks sysadmin " +
                "or CONTROL SERVER on [$RepositoryInstance]."
            )
        }

        $AdministratorLoginName = $SqlPermission.LoginName
        $AuthenticationMode = "SQL Login"
    }

    Write-SqlMaintenanceLog `
        -LogContext $LogContext `
        -Level Info `
        -Step "RepositoryAdminPreflight" `
        -Instance $RepositoryInstance `
        -Message (
            "Administrator validation succeeded using " +
            "$AuthenticationMode authentication as " +
            "[$AdministratorLoginName]."
        )

    $ServiceLoginResult = Invoke-SqlWithRetry `
        -Step "RepositoryServiceLoginPreflight" `
        -Instance $RepositoryInstance `
        -RetryCount $RetryCount `
        -RetryDelaySeconds $RetryDelaySeconds `
        -LogContext $LogContext `
        -Operation {
            $Connection = New-RepositoryAdministratorConnection `
                -InitialCatalog "master" `
                -ApplicationName "Repository Service Login Preflight"

            try {
                $Connection.Open()
                $Command = $Connection.CreateCommand()

                try {
                    $Command.CommandTimeout = $CommandTimeoutSeconds
                    $Command.CommandText = @"
SELECT [type_desc], [is_disabled]
FROM sys.server_principals
WHERE [name] = @LoginName;
"@
                    [void]$Command.Parameters.Add(
                        "@LoginName",
                        [System.Data.SqlDbType]::NVarChar,
                        128
                    )
                    $Command.Parameters["@LoginName"].Value = $SqlLoginName
                    $Reader = $Command.ExecuteReader()

                    try {
                        if (-not $Reader.Read()) {
                            return $null
                        }

                        [pscustomobject]@{
                            TypeDesc = [string]$Reader["type_desc"]
                            IsDisabled = [bool]$Reader["is_disabled"]
                        }
                    }
                    finally {
                        $Reader.Dispose()
                    }
                }
                finally {
                    $Command.Dispose()
                }
            }
            finally {
                $Connection.Dispose()
            }
        }

    if ($null -eq $ServiceLoginResult) {
        throw (
            "SQL Login [$SqlLoginName] does not exist on repository " +
            "instance [$RepositoryInstance]. Run the ProvisionLogin action in " +
            "Start-ServerRepositorySetup.ps1 first."
        )
    }

    if ($ServiceLoginResult.TypeDesc -ne "SQL_LOGIN") {
        throw (
            "Principal [$SqlLoginName] exists as " +
            "[$($ServiceLoginResult.TypeDesc)], not SQL_LOGIN."
        )
    }

    if ($ServiceLoginResult.IsDisabled) {
        throw "SQL Login [$SqlLoginName] is disabled."
    }

    $DatabaseWasCreated = Invoke-SqlWithRetry `
        -Step "EnsureRepositoryDatabase" `
        -Instance $RepositoryInstance `
        -RetryCount $RetryCount `
        -RetryDelaySeconds $RetryDelaySeconds `
        -LogContext $LogContext `
        -Operation {
            $Connection = New-RepositoryAdministratorConnection `
                -InitialCatalog "master" `
                -ApplicationName "Initialize SQL Repository Database"

            try {
                $Connection.Open()
                $Command = $Connection.CreateCommand()

                try {
                    $Command.CommandTimeout = $CommandTimeoutSeconds
                    $Command.CommandText = @"
IF DB_ID(@DatabaseName) IS NULL
BEGIN
    CREATE DATABASE [$RepositoryDatabase];
    SELECT CAST(1 AS bit);
END
ELSE
BEGIN
    SELECT CAST(0 AS bit);
END;
"@
                    [void]$Command.Parameters.Add(
                        "@DatabaseName",
                        [System.Data.SqlDbType]::NVarChar,
                        128
                    )
                    $Command.Parameters["@DatabaseName"].Value =
                        $RepositoryDatabase
                    [bool]$Command.ExecuteScalar()
                }
                finally {
                    $Command.Dispose()
                }
            }
            finally {
                $Connection.Dispose()
            }
        }

    $DatabaseState = Invoke-SqlWithRetry `
        -Step "ValidateRepositoryDatabaseState" `
        -Instance $RepositoryInstance `
        -RetryCount $RetryCount `
        -RetryDelaySeconds $RetryDelaySeconds `
        -LogContext $LogContext `
        -Operation {
            $Connection = New-RepositoryAdministratorConnection `
                -InitialCatalog "master" `
                -ApplicationName "Validate SQL Repository Database"

            try {
                $Connection.Open()
                $Command = $Connection.CreateCommand()

                try {
                    $Command.CommandTimeout = $CommandTimeoutSeconds
                    $Command.CommandText = @"
SELECT [state_desc]
FROM sys.databases
WHERE [name] = @DatabaseName;
"@
                    [void]$Command.Parameters.Add(
                        "@DatabaseName",
                        [System.Data.SqlDbType]::NVarChar,
                        128
                    )
                    $Command.Parameters["@DatabaseName"].Value =
                        $RepositoryDatabase
                    [string]$Command.ExecuteScalar()
                }
                finally {
                    $Command.Dispose()
                }
            }
            finally {
                $Connection.Dispose()
            }
        }

    if ($DatabaseState -ne "ONLINE") {
        throw (
            "Repository database [$RepositoryDatabase] is not online: " +
            $DatabaseState
        )
    }

    $ObjectResult = Invoke-SqlWithRetry `
        -Step "EnsureRepositoryObjects" `
        -Instance $RepositoryInstance `
        -RetryCount $RetryCount `
        -RetryDelaySeconds $RetryDelaySeconds `
        -LogContext $LogContext `
        -Operation {
            $Connection = New-RepositoryAdministratorConnection `
                -InitialCatalog $RepositoryDatabase `
                -ApplicationName "Initialize SQL Repository Objects"

            try {
                $Connection.Open()
                $Command = $Connection.CreateCommand()

                try {
                    $Command.CommandTimeout = $CommandTimeoutSeconds
                    $Command.CommandText = @"
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @SchemaCreated bit = 0;
DECLARE @TableCreated bit = 0;
DECLARE @SqlBackupInfoCreated bit = 0;
DECLARE @SqlDiskSpaceCreated bit = 0;
DECLARE @SqlDuplicateIndexInfoCreated bit = 0;
DECLARE @SqlTablePerformanceInfoCreated bit = 0;
DECLARE @SqlTopResourceUsageCreated bit = 0;
DECLARE @SqlUnusedIndexInfoCreated bit = 0;
DECLARE @UserCreated bit = 0;
DECLARE @DbOwnerAdded bit = 0;

BEGIN TRANSACTION;

IF SCHEMA_ID(@SchemaName) IS NULL
BEGIN
    EXEC(N'CREATE SCHEMA [$RepositorySchema] AUTHORIZATION [dbo];');
    SET @SchemaCreated = 1;
END;

IF OBJECT_ID(@QualifiedTable, N'U') IS NULL
BEGIN
    CREATE TABLE [$RepositorySchema].[$RepositoryTable]
    (
        [InsName] varchar(50) NOT NULL
    );
    SET @TableCreated = 1;
END;

IF NOT EXISTS
(
    SELECT 1
    FROM sys.columns
    WHERE [object_id] = OBJECT_ID(@QualifiedTable, N'U')
      AND [name] = N'InsName'
      AND TYPE_NAME([system_type_id]) IN (N'varchar', N'nvarchar')
      AND
      (
          [max_length] = -1
          OR CASE
                 WHEN TYPE_NAME([system_type_id]) = N'nvarchar'
                     THEN [max_length] / 2
                 ELSE [max_length]
             END >= 50
      )
)
BEGIN
    THROW 50001,
        N'Repository table InsName column is missing or incompatible.',
        1;
END;

IF OBJECT_ID(N'[dbo].[SqlBackupInfo]', N'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[SqlBackupInfo]
    (
        [ReportId] bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT [PK_SqlBackupInfo] PRIMARY KEY CLUSTERED,
        [CollectedAt] datetime2(3) NOT NULL,
        [SourceInstance] nvarchar(256) NOT NULL,
        [SqlInstance] nvarchar(256) NULL,
        [Database] nvarchar(128) NOT NULL,
        [RecoveryModel] nvarchar(60) NULL,
        [LastFullBackup] datetime2(3) NULL,
        [LastDiffBackup] datetime2(3) NULL,
        [LastLogBackup] datetime2(3) NULL,
        [LastFullBackupIsCopyOnly] bit NULL,
        [LastDiffBackupIsCopyOnly] bit NULL,
        [LastLogBackupIsCopyOnly] bit NULL,
        [DatabaseCreated] datetime2(3) NULL,
        [DaysSinceDbCreated] int NULL,
        [Status] nvarchar(256) NULL
    );

    CREATE INDEX [IX_SqlBackupInfo_CollectedAt]
        ON [dbo].[SqlBackupInfo]
            ([CollectedAt], [SourceInstance], [Database]);

    SET @SqlBackupInfoCreated = 1;
END;

IF OBJECT_ID(N'[dbo].[SqlDiskSpace]', N'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[SqlDiskSpace]
    (
        [ReportId] bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT [PK_SqlDiskSpace] PRIMARY KEY CLUSTERED,
        [CollectedAt] datetime2(3) NOT NULL,
        [SourceInstance] nvarchar(256) NOT NULL,
        [Drive] nvarchar(512) NOT NULL,
        [TotalSizeGB] decimal(19,2) NULL,
        [FreeSpaceGB] decimal(19,2) NULL,
        [FreePercentage] decimal(9,2) NULL
    );

    CREATE INDEX [IX_SqlDiskSpace_CollectedAt]
        ON [dbo].[SqlDiskSpace] ([CollectedAt], [SourceInstance]);

    SET @SqlDiskSpaceCreated = 1;
END;

IF OBJECT_ID(N'[dbo].[SqlDuplicateIndexInfo]', N'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[SqlDuplicateIndexInfo]
    (
        [ReportId] bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT [PK_SqlDuplicateIndexInfo] PRIMARY KEY CLUSTERED,
        [CollectedAt] datetime2(3) NOT NULL,
        [SourceInstance] nvarchar(256) NOT NULL,
        [Database] nvarchar(128) NULL,
        [Table] nvarchar(512) NULL,
        [Index] nvarchar(128) NULL,
        [KeyColumns] nvarchar(max) NULL,
        [IncludedColumns] nvarchar(max) NULL,
        [IndexType] nvarchar(128) NULL,
        [IndexSizeMB] decimal(19,2) NULL,
        [RowCount] bigint NULL,
        [IsDisabled] bit NULL,
        [IsUnique] bit NULL,
        [IsFiltered] bit NULL,
        [CompressionDescription] nvarchar(128) NULL
    );

    CREATE INDEX [IX_SqlDuplicateIndexInfo_CollectedAt]
        ON [dbo].[SqlDuplicateIndexInfo]
            ([CollectedAt], [SourceInstance]);

    SET @SqlDuplicateIndexInfoCreated = 1;
END;

IF OBJECT_ID(N'[dbo].[SqlTablePerformanceInfo]', N'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[SqlTablePerformanceInfo]
    (
        [ReportId] bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT [PK_SqlTablePerformanceInfo] PRIMARY KEY CLUSTERED,
        [CollectedAt] datetime2(3) NOT NULL,
        [SourceInstance] nvarchar(256) NOT NULL,
        [SqlInstance] nvarchar(256) NULL,
        [Database] nvarchar(128) NULL,
        [Schema] nvarchar(128) NULL,
        [Name] nvarchar(128) NULL,
        [RowCount] bigint NULL,
        [HasClusteredIndex] bit NULL,
        [DataMB] decimal(19,2) NULL,
        [IndexMB] decimal(19,2) NULL
    );

    CREATE INDEX [IX_SqlTablePerformanceInfo_CollectedAt]
        ON [dbo].[SqlTablePerformanceInfo]
            ([CollectedAt], [SourceInstance]);

    SET @SqlTablePerformanceInfoCreated = 1;
END;

IF OBJECT_ID(N'[dbo].[SqlTopResourceUsage]', N'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[SqlTopResourceUsage]
    (
        [ReportId] bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT [PK_SqlTopResourceUsage] PRIMARY KEY CLUSTERED,
        [CollectedAt] datetime2(3) NOT NULL,
        [SourceInstance] nvarchar(256) NOT NULL,
        [Metric] nvarchar(20) NOT NULL,
        [SqlInstance] nvarchar(256) NULL,
        [Database] nvarchar(128) NULL,
        [ObjectName] nvarchar(512) NULL,
        [QueryHash] nvarchar(130) NULL,
        [ExecutionCount] bigint NULL,
        [TotalElapsedTimeMs] decimal(38,4) NULL,
        [AverageDurationMs] decimal(38,4) NULL,
        [QueryTotalElapsedTimeMs] decimal(38,4) NULL,
        [TotalIO] bigint NULL,
        [AverageIO] decimal(38,4) NULL,
        [QueryTotalIO] bigint NULL,
        [CpuTime] bigint NULL,
        [AverageCpuMs] decimal(38,4) NULL,
        [QueryTotalCpu] bigint NULL,
        [QueryText] nvarchar(max) NULL
    );

    CREATE INDEX [IX_SqlTopResourceUsage_CollectedAt]
        ON [dbo].[SqlTopResourceUsage]
            ([CollectedAt], [SourceInstance], [Metric]);

    SET @SqlTopResourceUsageCreated = 1;
END;

IF OBJECT_ID(N'[dbo].[SqlUnusedIndexInfo]', N'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[SqlUnusedIndexInfo]
    (
        [ReportId] bigint IDENTITY(1,1) NOT NULL
            CONSTRAINT [PK_SqlUnusedIndexInfo] PRIMARY KEY CLUSTERED,
        [CollectedAt] datetime2(3) NOT NULL,
        [SourceInstance] nvarchar(256) NOT NULL,
        [SqlInstance] nvarchar(256) NULL,
        [Database] nvarchar(128) NULL,
        [Schema] nvarchar(128) NULL,
        [Table] nvarchar(128) NULL,
        [Index] nvarchar(128) NULL,
        [IndexId] bigint NULL,
        [IndexType] nvarchar(128) NULL,
        [UserSeeks] bigint NULL,
        [UserScans] bigint NULL,
        [UserLookups] bigint NULL,
        [UserUpdates] bigint NULL,
        [LastUserSeek] datetime2(3) NULL,
        [LastUserScan] datetime2(3) NULL,
        [LastUserLookup] datetime2(3) NULL,
        [LastUserUpdate] datetime2(3) NULL,
        [IndexSizeMB] decimal(19,2) NULL,
        [RowCount] bigint NULL,
        [CompressionDescription] nvarchar(128) NULL
    );

    CREATE INDEX [IX_SqlUnusedIndexInfo_CollectedAt]
        ON [dbo].[SqlUnusedIndexInfo]
            ([CollectedAt], [SourceInstance]);

    SET @SqlUnusedIndexInfoCreated = 1;
END;

IF USER_ID(@LoginName) IS NULL
BEGIN
    CREATE USER [$SqlLoginName] FOR LOGIN [$SqlLoginName];
    SET @UserCreated = 1;
END
ELSE
BEGIN
    ALTER USER [$SqlLoginName] WITH LOGIN = [$SqlLoginName];
END;

GRANT CONNECT TO [$SqlLoginName];
GRANT VIEW DEFINITION TO [$SqlLoginName];
GRANT VIEW DATABASE STATE TO [$SqlLoginName];

IF CONVERT(int, SERVERPROPERTY(N'ProductMajorVersion')) >= 16
BEGIN
    EXEC(N'GRANT VIEW DATABASE PERFORMANCE STATE TO [$SqlLoginName];');
END;

IF NOT EXISTS
(
    SELECT 1
    FROM sys.database_role_members AS drm
    INNER JOIN sys.database_principals AS role_principal
        ON role_principal.principal_id = drm.role_principal_id
    INNER JOIN sys.database_principals AS member_principal
        ON member_principal.principal_id = drm.member_principal_id
    WHERE role_principal.name = N'db_owner'
      AND member_principal.name = @LoginName
)
BEGIN
    ALTER ROLE [db_owner] ADD MEMBER [$SqlLoginName];
    SET @DbOwnerAdded = 1;
END;

COMMIT TRANSACTION;

SELECT
    @SchemaCreated AS [SchemaCreated],
    @TableCreated AS [TableCreated],
    @SqlBackupInfoCreated AS [SqlBackupInfoCreated],
    @SqlDiskSpaceCreated AS [SqlDiskSpaceCreated],
    @SqlDuplicateIndexInfoCreated AS [SqlDuplicateIndexInfoCreated],
    @SqlTablePerformanceInfoCreated AS [SqlTablePerformanceInfoCreated],
    @SqlTopResourceUsageCreated AS [SqlTopResourceUsageCreated],
    @SqlUnusedIndexInfoCreated AS [SqlUnusedIndexInfoCreated],
    @UserCreated AS [UserCreated],
    @DbOwnerAdded AS [DbOwnerAdded];
"@
                    [void]$Command.Parameters.Add(
                        "@SchemaName",
                        [System.Data.SqlDbType]::NVarChar,
                        128
                    )
                    [void]$Command.Parameters.Add(
                        "@QualifiedTable",
                        [System.Data.SqlDbType]::NVarChar,
                        257
                    )
                    [void]$Command.Parameters.Add(
                        "@LoginName",
                        [System.Data.SqlDbType]::NVarChar,
                        128
                    )
                    $Command.Parameters["@SchemaName"].Value =
                        $RepositorySchema
                    $Command.Parameters["@QualifiedTable"].Value =
                        "[$RepositorySchema].[$RepositoryTable]"
                    $Command.Parameters["@LoginName"].Value = $SqlLoginName
                    $Reader = $Command.ExecuteReader()

                    try {
                        [void]$Reader.Read()
                        [pscustomobject]@{
                            SchemaCreated =
                                [bool]$Reader["SchemaCreated"]
                            TableCreated = [bool]$Reader["TableCreated"]
                            SqlBackupInfoCreated =
                                [bool]$Reader["SqlBackupInfoCreated"]
                            SqlDiskSpaceCreated =
                                [bool]$Reader["SqlDiskSpaceCreated"]
                            SqlDuplicateIndexInfoCreated =
                                [bool]$Reader[
                                    "SqlDuplicateIndexInfoCreated"
                                ]
                            SqlTablePerformanceInfoCreated =
                                [bool]$Reader[
                                    "SqlTablePerformanceInfoCreated"
                                ]
                            SqlTopResourceUsageCreated =
                                [bool]$Reader[
                                    "SqlTopResourceUsageCreated"
                                ]
                            SqlUnusedIndexInfoCreated =
                                [bool]$Reader[
                                    "SqlUnusedIndexInfoCreated"
                                ]
                            UserCreated = [bool]$Reader["UserCreated"]
                            DbOwnerAdded = [bool]$Reader["DbOwnerAdded"]
                        }
                    }
                    finally {
                        $Reader.Dispose()
                    }
                }
                finally {
                    $Command.Dispose()
                }
            }
            finally {
                $Connection.Dispose()
            }
        }

    $ForecastProcedureExisted = Invoke-SqlWithRetry `
        -Step "EnsureTableRowCountForecastProcedure" `
        -Instance $RepositoryInstance `
        -RetryCount $RetryCount `
        -RetryDelaySeconds $RetryDelaySeconds `
        -LogContext $LogContext `
        -Operation {
            $Connection = New-RepositoryAdministratorConnection `
                -InitialCatalog $RepositoryDatabase `
                -ApplicationName "Initialize Row Count Forecast Procedure"

            try {
                $Connection.Open()
                $ProcedureExistsCommand = $Connection.CreateCommand()

                try {
                    $ProcedureExistsCommand.CommandTimeout =
                        $CommandTimeoutSeconds
                    $ProcedureExistsCommand.CommandText = @"
SELECT CASE
           WHEN OBJECT_ID(
               N'[dbo].[usp_GetTableRowCountForecast]',
               N'P'
           ) IS NULL THEN 0
           ELSE 1
       END;
"@
                    $ProcedureExisted =
                        [bool]$ProcedureExistsCommand.ExecuteScalar()
                }
                finally {
                    $ProcedureExistsCommand.Dispose()
                }

                $ProcedureCommand = $Connection.CreateCommand()

                try {
                    $ProcedureCommand.CommandTimeout = $CommandTimeoutSeconds
                    $ProcedureCommand.CommandText = @"
CREATE OR ALTER PROCEDURE dbo.usp_GetTableRowCountForecast
    @LookbackDays     int = 90,
    @ForecastDays     int = 30,
    @MinimumSamples   int = 14,
    @SourceInstance   nvarchar(256) = NULL,
    @DatabaseName     nvarchar(128) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @LookbackDays < 7
        THROW 50001, 'LookbackDays cannot be less than 7.', 1;

    IF @ForecastDays < 1
        THROW 50002, 'ForecastDays cannot be less than 1.', 1;

    DECLARE
        @Today date = CONVERT(date, SYSUTCDATETIME()),
        @StartDate date,
        @ForecastDate date;

    SET @StartDate = DATEADD(day, 1 - @LookbackDays, @Today);
    SET @ForecastDate = DATEADD(day, @ForecastDays, @Today);

    ;WITH LatestSamplePerDay AS
    (
        SELECT
            SourceInstance,
            SqlInstance,
            [Database],
            [Schema],
            [Name],
            CONVERT(date, CollectedAt) AS SampleDate,
            [RowCount],
            ROW_NUMBER() OVER
            (
                PARTITION BY
                    SourceInstance,
                    SqlInstance,
                    [Database],
                    [Schema],
                    [Name],
                    CONVERT(date, CollectedAt)
                ORDER BY
                    CollectedAt DESC,
                    ReportId DESC
            ) AS DailyRowNumber
        FROM dbo.SqlTablePerformanceInfo
        WHERE CollectedAt >= @StartDate
          AND [RowCount] IS NOT NULL
          AND
          (
              @SourceInstance IS NULL
              OR SourceInstance = @SourceInstance
          )
          AND
          (
              @DatabaseName IS NULL
              OR [Database] = @DatabaseName
          )
    ),
    DailySamples AS
    (
        SELECT
            SourceInstance,
            SqlInstance,
            [Database],
            [Schema],
            [Name],
            SampleDate,
            [RowCount],
            CONVERT(float, DATEDIFF(day, @StartDate, SampleDate)) AS X,
            CONVERT(float, [RowCount]) AS Y
        FROM LatestSamplePerDay
        WHERE DailyRowNumber = 1
    ),
    RankedSamples AS
    (
        SELECT
            *,
            ROW_NUMBER() OVER
            (
                PARTITION BY
                    SourceInstance,
                    SqlInstance,
                    [Database],
                    [Schema],
                    [Name]
                ORDER BY SampleDate DESC
            ) AS LatestRowNumber
        FROM DailySamples
    ),
    RegressionTotals AS
    (
        SELECT
            SourceInstance,
            SqlInstance,
            [Database],
            [Schema],
            [Name],
            COUNT(*) AS SampleCount,
            MIN(SampleDate) AS FirstSampleDate,
            MAX(SampleDate) AS LastSampleDate,
            MAX
            (
                CASE
                    WHEN LatestRowNumber = 1 THEN [RowCount]
                END
            ) AS CurrentRowCount,
            SUM(X) AS SumX,
            SUM(Y) AS SumY,
            SUM(X * Y) AS SumXY,
            SUM(X * X) AS SumXX,
            SUM(Y * Y) AS SumYY
        FROM RankedSamples
        GROUP BY
            SourceInstance,
            SqlInstance,
            [Database],
            [Schema],
            [Name]
        HAVING COUNT(*) >= @MinimumSamples
    ),
    FormulaParts AS
    (
        SELECT
            *,
            SampleCount * SumXY - SumX * SumY
                AS CovarianceNumerator,
            SampleCount * SumXX - SumX * SumX
                AS VarianceX,
            SampleCount * SumYY - SumY * SumY
                AS VarianceY
        FROM RegressionTotals
    ),
    RegressionSlope AS
    (
        SELECT
            *,
            CovarianceNumerator / NULLIF(VarianceX, 0.0)
                AS DailyGrowth
        FROM FormulaParts
        WHERE VarianceX <> 0
    ),
    RegressionModel AS
    (
        SELECT
            *,
            (SumY - DailyGrowth * SumX) / SampleCount
                AS InterceptValue
        FROM RegressionSlope
    )
    SELECT
        SourceInstance,
        SqlInstance,
        [Database],
        [Schema],
        [Name],
        SampleCount,
        FirstSampleDate,
        LastSampleDate,
        CurrentRowCount,
        CONVERT(decimal(19, 2), DailyGrowth)
            AS AverageDailyGrowth,
        @ForecastDate AS ForecastDate,
        TRY_CONVERT
        (
            bigint,
            ROUND
            (
                CASE
                    WHEN Prediction.PredictedRowCount < 0 THEN 0
                    ELSE Prediction.PredictedRowCount
                END,
                0
            )
        ) AS PredictedRowCount,
        CONVERT
        (
            decimal(9, 4),
            POWER(CovarianceNumerator, 2) /
            NULLIF(VarianceX * VarianceY, 0.0)
        ) AS RSquared
    FROM RegressionModel
    CROSS APPLY
    (
        VALUES
        (
            InterceptValue
            + DailyGrowth
            * DATEDIFF(day, @StartDate, @ForecastDate)
        )
    ) AS Prediction(PredictedRowCount)
    -- Exclude tables that have not received recent samples.
    WHERE LastSampleDate >= DATEADD(day, -2, @Today)
    ORDER BY
        DailyGrowth DESC,
        SourceInstance,
        [Database],
        [Schema],
        [Name];
END;
"@
                    [void]$ProcedureCommand.ExecuteNonQuery()
                }
                finally {
                    $ProcedureCommand.Dispose()
                }

                $ProcedureExisted
            }
            finally {
                $Connection.Dispose()
            }
        }

    $AgentJobWasCreated = Invoke-SqlWithRetry `
        -Step "EnsureGetDBInfoAgentJob" `
        -Instance $RepositoryInstance `
        -RetryCount $RetryCount `
        -RetryDelaySeconds $RetryDelaySeconds `
        -LogContext $LogContext `
        -Operation {
            $Connection = New-RepositoryAdministratorConnection `
                -InitialCatalog "msdb" `
                -ApplicationName "Initialize GetDBInfo SQL Agent Job"

            try {
                $Connection.Open()
                $Command = $Connection.CreateCommand()

                try {
                    $Command.CommandTimeout = $CommandTimeoutSeconds
                    $Command.CommandText = @"
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @JobId uniqueidentifier;
DECLARE @JobCreated bit = 0;

SELECT @JobId = [job_id]
FROM dbo.sysjobs
WHERE [name] = N'DBA - Collect Database Information';

IF @JobId IS NULL
BEGIN
    BEGIN TRANSACTION;

    BEGIN TRY
        EXEC dbo.sp_add_job
            @job_name = N'DBA - Collect Database Information',
            @enabled = 1,
            @description = N'Collects local and remote SQL Server instance information from InsList.',
            @job_id = @JobId OUTPUT;

        EXEC dbo.sp_add_jobstep
            @job_id = @JobId,
            @step_name = N'Run GetDBInfo Collector',
            @subsystem = N'CmdExec',
            @command = N'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "E:\Scripts\SqlMonitoring\GetDBInfo\_Get-DBInfo-Simple.ps1"',
            @retry_attempts = 2,
            @retry_interval = 5,
            @on_success_action = 1,
            @on_fail_action = 2;

        EXEC dbo.sp_add_jobschedule
            @job_id = @JobId,
            @name = N'Daily 01:00 - GetDBInfo',
            @enabled = 1,
            @freq_type = 4,
            @freq_interval = 1,
            @active_start_time = 10000;

        EXEC dbo.sp_add_jobserver
            @job_id = @JobId,
            @server_name = N'(LOCAL)';

        COMMIT TRANSACTION;
        SET @JobCreated = 1;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH;
END;

SELECT @JobCreated;
"@
                    [bool]$Command.ExecuteScalar()
                }
                finally {
                    $Command.Dispose()
                }
            }
            finally {
                $Connection.Dispose()
            }
        }

    [void](
        Test-SqlMonitorRepository `
            -RepositoryInstance $RepositoryInstance `
            -RepositoryDatabase $RepositoryDatabase `
            -RepositorySchema $RepositorySchema `
            -RepositoryTable $RepositoryTable `
            -Credential $ServiceCredential `
            -ConnectionTimeoutSeconds $ConnectionTimeoutSeconds `
            -CommandTimeoutSeconds $CommandTimeoutSeconds `
            -RetryCount $RetryCount `
            -RetryDelaySeconds $RetryDelaySeconds `
            -LogContext $LogContext
    )

    $DatabaseStatus = if ($DatabaseWasCreated) {
        "Created"
    }
    else {
        "Already exists"
    }
    $SchemaStatus = if ($ObjectResult.SchemaCreated) {
        "Created"
    }
    else {
        "Already exists"
    }
    $TableStatus = if ($ObjectResult.TableCreated) {
        "Created"
    }
    else {
        "Already exists"
    }
    $SqlBackupInfoStatus = if ($ObjectResult.SqlBackupInfoCreated) {
        "Created"
    }
    else {
        "Already exists"
    }
    $SqlDiskSpaceStatus = if ($ObjectResult.SqlDiskSpaceCreated) {
        "Created"
    }
    else {
        "Already exists"
    }
    $SqlDuplicateIndexInfoStatus = if (
        $ObjectResult.SqlDuplicateIndexInfoCreated
    ) {
        "Created"
    }
    else {
        "Already exists"
    }
    $SqlTablePerformanceInfoStatus = if (
        $ObjectResult.SqlTablePerformanceInfoCreated
    ) {
        "Created"
    }
    else {
        "Already exists"
    }
    $SqlTopResourceUsageStatus = if (
        $ObjectResult.SqlTopResourceUsageCreated
    ) {
        "Created"
    }
    else {
        "Already exists"
    }
    $SqlUnusedIndexInfoStatus = if (
        $ObjectResult.SqlUnusedIndexInfoCreated
    ) {
        "Created"
    }
    else {
        "Already exists"
    }
    $ForecastProcedureStatus = if ($ForecastProcedureExisted) {
        "Updated"
    }
    else {
        "Created"
    }
    $AgentJobStatus = if ($AgentJobWasCreated) {
        "Created"
    }
    else {
        "Already exists"
    }
    $UserStatus = if ($ObjectResult.UserCreated) {
        "Created"
    }
    else {
        "Mapped"
    }
    $DbOwnerStatus = if ($ObjectResult.DbOwnerAdded) {
        "Added"
    }
    else {
        "Already a member"
    }

    $Result = [pscustomobject]@{
        Component = "Database"
        Name = $RepositoryDatabase
        Status = $DatabaseStatus
    }, [pscustomobject]@{
        Component = "Schema"
        Name = $RepositorySchema
        Status = $SchemaStatus
    }, [pscustomobject]@{
        Component = "Table"
        Name = "$RepositorySchema.$RepositoryTable"
        Status = $TableStatus
    }, [pscustomobject]@{
        Component = "Report table"
        Name = "dbo.SqlBackupInfo"
        Status = $SqlBackupInfoStatus
    }, [pscustomobject]@{
        Component = "Report table"
        Name = "dbo.SqlDiskSpace"
        Status = $SqlDiskSpaceStatus
    }, [pscustomobject]@{
        Component = "Report table"
        Name = "dbo.SqlDuplicateIndexInfo"
        Status = $SqlDuplicateIndexInfoStatus
    }, [pscustomobject]@{
        Component = "Report table"
        Name = "dbo.SqlTablePerformanceInfo"
        Status = $SqlTablePerformanceInfoStatus
    }, [pscustomobject]@{
        Component = "Report table"
        Name = "dbo.SqlTopResourceUsage"
        Status = $SqlTopResourceUsageStatus
    }, [pscustomobject]@{
        Component = "Report table"
        Name = "dbo.SqlUnusedIndexInfo"
        Status = $SqlUnusedIndexInfoStatus
    }, [pscustomobject]@{
        Component = "Stored procedure"
        Name = "dbo.usp_GetTableRowCountForecast"
        Status = $ForecastProcedureStatus
    }, [pscustomobject]@{
        Component = "SQL Agent Job"
        Name = "DBA - Collect Database Information"
        Status = $AgentJobStatus
    }, [pscustomobject]@{
        Component = "Database user"
        Name = $SqlLoginName
        Status = $UserStatus
    }, [pscustomobject]@{
        Component = "Database role"
        Name = "db_owner/$SqlLoginName"
        Status = $DbOwnerStatus
    }

    Write-Host ""
    Write-Host "Repository initialization results:"
    $Result | Format-Table Component, Name, Status -AutoSize | Out-Host

    Write-SqlMaintenanceLog `
        -LogContext $LogContext `
        -Level Info `
        -Step "InitializeRepository" `
        -Instance $RepositoryInstance `
        -Message (
            "Repository initialization completed: " +
            "$RepositoryDatabase.[$RepositorySchema].[$RepositoryTable]; " +
            "six dbo report tables are ready; " +
            "the row-count forecast procedure is ready; " +
            "the GetDBInfo SQL Agent Job is ready; " +
            "[$SqlLoginName] is db_owner."
        )

    $Result
}
finally {
    $ServiceSqlCredential = $null
    $AdministratorSqlCredential = $null

    if ($null -ne $ReadOnlyServicePassword) {
        $ReadOnlyServicePassword.Dispose()
    }

    if ($null -ne $ReadOnlyAdminPassword) {
        $ReadOnlyAdminPassword.Dispose()
    }
}
