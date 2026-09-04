<#
.SYNOPSIS
Creates and configures the SQL monitoring repository when required.

.DESCRIPTION
Reads the repository target from repository.config, connects with Windows
authentication when possible, and requests a fallback SQL administrator
credential when required. The database, schema, and table are created only when
missing. Existing objects are never dropped or rebuilt.

The srv.mn SQL Login must already exist on the repository instance. Its database
user is created or remapped and added to the db_owner database role. The service
credential is used for a final repository validation.

.PARAMETER ConfigPath
Path to the repository configuration file. The default is repository.config in
the script directory.

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
SQL Login mapped to the repository database and added to db_owner. The default
is srv.mn.

.PARAMETER ServiceCredential
Credential used for the final repository validation. When omitted, the script
prompts for it.

.PARAMETER SqlAdminCredential
Optional fallback SQL administrator credential used when Windows authentication
does not have sysadmin or CONTROL SERVER.

.EXAMPLE
.\Initialize-SqlMonitorRepository.ps1

Creates missing repository objects and configures srv.mn as db_owner.

.NOTES
Run New-SqlServiceLogin.ps1 for the repository instance before this script when
the srv.mn SQL Login does not exist.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath = (
        Join-Path $PSScriptRoot "repository.config"
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
    [string]$SqlLoginName = "srv.mn",

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

$CommonModulePath = Join-Path $PSScriptRoot "SqlMaintenance.Common.psm1"

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
            "instance [$RepositoryInstance]. Run New-SqlServiceLogin.ps1 " +
            "for this instance first."
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

IF USER_ID(@LoginName) IS NULL
BEGIN
    CREATE USER [$SqlLoginName] FOR LOGIN [$SqlLoginName];
    SET @UserCreated = 1;
END
ELSE
BEGIN
    ALTER USER [$SqlLoginName] WITH LOGIN = [$SqlLoginName];
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
