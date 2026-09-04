<#
.SYNOPSIS
Provisions and validates a service SQL Login on selected local SQL Server
instances.

.DESCRIPTION
Uses one shared instance selection supplied by the CLI, or discovers and selects
local instances when run independently. The script checks whether the current
Windows account can provision each instance and requests a fallback SQL
administrator credential only when required.

The srv.mn Login is created when missing, its server and msdb permissions are
applied idempotently, and the supplied service credential is then used to make a
real SQL connection to every selected instance. Existing Login passwords are not
changed; a mismatched stored password causes validation to fail.

.PARAMETER SourceInstance
Optional SQL Server connection targets. Supplying this parameter bypasses local
discovery and the interactive instance menu.

.PARAMETER ServiceLoginName
Name of the SQL Login to provision and validate. The default is srv.mn.

.PARAMETER ServiceCredential
Credential used to create and validate the service Login. When omitted, the
script prompts for it once.

.PARAMETER SqlAdminCredential
Optional fallback SQL administrator credential. It is used only when the current
Windows account cannot provision one or more selected instances.

.PARAMETER ConnectionTimeoutSeconds
SQL connection timeout. The default is 15 seconds.

.PARAMETER CommandTimeoutSeconds
SQL command timeout. The default is 30 seconds.

.PARAMETER RetryCount
Number of retries after the first failed transient operation. The default is 3.

.PARAMETER RetryDelaySeconds
Initial retry delay. The delay doubles for each retry and is capped at 30
seconds. The default is 2 seconds.

.EXAMPLE
.\New-SqlServiceLogin.ps1

Selects local instances, prompts for the srv.mn credential, provisions the
Login, and validates that the credential can connect.

.EXAMPLE
$Credential = Get-Credential -UserName "srv.mn"
.\New-SqlServiceLogin.ps1 `
    -SourceInstance "localhost","localhost\LAB2" `
    -ServiceCredential $Credential

Uses the supplied instance list and credential without displaying an instance
selection menu.

.NOTES
This Agent script intentionally grants only server and msdb permissions. The
Monitor repository database, table, user mapping, and db_owner membership are
owned by Initialize-SqlMonitorRepository.ps1.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string[]]$SourceInstance,

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$ServiceLoginName = "srv.mn",

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

if ($null -eq $LogContext) {
    $LogContext = New-SqlMaintenanceLogContext `
        -LogDirectory $LogDirectory `
        -OperationName "New-SqlServiceLogin"
}

$SelectionParameters = @{}

if ($PSBoundParameters.ContainsKey("SourceInstance")) {
    $SelectionParameters.SourceInstance = $SourceInstance
}

$SelectedSqlInstances = @(
    Select-SqlInstance @SelectionParameters
)

if ($null -eq $ServiceCredential) {
    $ServiceCredential = Get-Credential `
        -UserName $ServiceLoginName `
        -Message (
            "Enter the service SQL Login credential to provision and validate"
        )
}

if ($null -eq $ServiceCredential) {
    throw "A service SQL Login credential is required."
}

if ($ServiceCredential.UserName -cne $ServiceLoginName) {
    throw (
        "Service credential user [$($ServiceCredential.UserName)] does not " +
        "match ServiceLoginName [$ServiceLoginName]."
    )
}

Write-SqlMaintenanceLog `
    -LogContext $LogContext `
    -Level Info `
    -Step "ProvisionLogin" `
    -Message (
        "Starting Login provisioning for: " +
        ($SelectedSqlInstances.ConnectionTarget -join ", ")
    )

$ReadOnlyServicePassword = $ServiceCredential.Password.Copy()
$ReadOnlyServicePassword.MakeReadOnly()
$ServiceSqlCredential = [System.Data.SqlClient.SqlCredential]::new(
    $ServiceCredential.UserName,
    $ReadOnlyServicePassword
)
$ReadOnlyAdminPassword = $null
$ProvisioningSqlCredential = $null
$ProvisioningResults = [System.Collections.Generic.List[object]]::new()
$CurrentWindowsAccount =
    [Security.Principal.WindowsIdentity]::GetCurrent().Name

try {
    $WindowsAuthenticationResults =
        [System.Collections.Generic.List[object]]::new()

    foreach ($SelectedInstance in $SelectedSqlInstances) {
        try {
            $PreflightResult = Invoke-SqlWithRetry `
                -Step "WindowsPermissionPreflight" `
                -Instance $SelectedInstance.ConnectionTarget `
                -RetryCount $RetryCount `
                -RetryDelaySeconds $RetryDelaySeconds `
                -LogContext $LogContext `
                -Operation {
                    $Connection = New-SqlConnection `
                        -DataSource $SelectedInstance.ConnectionTarget `
                        -InitialCatalog "master" `
                        -IntegratedSecurity `
                        -ConnectionTimeoutSeconds `
                            $ConnectionTimeoutSeconds `
                        -ApplicationName "SQL Login Permission Preflight"

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
                                    DatabaseLogin =
                                        [string]$Reader["LoginName"]
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

            $CanCreateLogin =
                $PreflightResult.IsSysadmin -or
                $PreflightResult.HasControlServer
            $Detail = if ($CanCreateLogin) {
                "sysadmin or CONTROL SERVER"
            }
            else {
                "Connected, but lacks sysadmin or CONTROL SERVER"
            }

            $WindowsAuthenticationResults.Add(
                [pscustomobject]@{
                    ConnectionTarget =
                        $SelectedInstance.ConnectionTarget
                    Instance         = $SelectedInstance.InstanceName
                    WindowsAccount   = $CurrentWindowsAccount
                    DatabaseLogin    = $PreflightResult.DatabaseLogin
                    CanConnect       = $true
                    CanCreateLogin   = $CanCreateLogin
                    Detail           = $Detail
                }
            )
        }
        catch {
            $WindowsAuthenticationResults.Add(
                [pscustomobject]@{
                    ConnectionTarget =
                        $SelectedInstance.ConnectionTarget
                    Instance         = $SelectedInstance.InstanceName
                    WindowsAccount   = $CurrentWindowsAccount
                    DatabaseLogin    = $null
                    CanConnect       = $false
                    CanCreateLogin   = $false
                    Detail           = $_.Exception.Message
                }
            )
        }
    }

    Write-Host ""
    Write-Host "Windows authentication preflight:"
    $WindowsAuthenticationResults |
        Format-Table `
            Instance,
            WindowsAccount,
            DatabaseLogin,
            CanConnect,
            CanCreateLogin,
            Detail `
            -AutoSize |
        Out-Host

    $InstancesNeedingSqlCredential = @(
        $WindowsAuthenticationResults |
            Where-Object { -not $_.CanCreateLogin }
    )

    if ($InstancesNeedingSqlCredential.Count -gt 0) {
        if ($null -eq $SqlAdminCredential) {
            Write-Warning (
                "Windows authentication cannot provision every selected " +
                "instance. A fallback SQL administrator credential is " +
                "required."
            )
            $SqlAdminCredential = Get-Credential `
                -UserName "zabbix" `
                -Message (
                    "Enter a SQL Login that can create logins and grant " +
                    "permissions"
                )
        }

        if ($null -eq $SqlAdminCredential) {
            throw "A fallback SQL administrator credential is required."
        }

        $ReadOnlyAdminPassword = $SqlAdminCredential.Password.Copy()
        $ReadOnlyAdminPassword.MakeReadOnly()
        $ProvisioningSqlCredential =
            [System.Data.SqlClient.SqlCredential]::new(
                $SqlAdminCredential.UserName,
                $ReadOnlyAdminPassword
            )
    }

    foreach ($SelectedInstance in $SelectedSqlInstances) {
        $WindowsAuthenticationResult =
            $WindowsAuthenticationResults |
                Where-Object {
                    $_.ConnectionTarget -eq
                        $SelectedInstance.ConnectionTarget
                } |
                Select-Object -First 1
        $AuthenticationMode = if (
            $WindowsAuthenticationResult.CanCreateLogin
        ) {
            "Windows"
        }
        else {
            "SQL Login"
        }
        $LoginWasCreated = $false
        $ResolvedInstanceName = $SelectedInstance.ConnectionTarget

        try {
            $ProvisionResult = Invoke-SqlWithRetry `
                -Step "EnsureServiceLogin" `
                -Instance $SelectedInstance.ConnectionTarget `
                -RetryCount $RetryCount `
                -RetryDelaySeconds $RetryDelaySeconds `
                -LogContext $LogContext `
                -Operation {
                    if ($AuthenticationMode -eq "Windows") {
                        $Connection = New-SqlConnection `
                            -DataSource `
                                $SelectedInstance.ConnectionTarget `
                            -InitialCatalog "master" `
                            -IntegratedSecurity `
                            -ConnectionTimeoutSeconds `
                                $ConnectionTimeoutSeconds `
                            -ApplicationName "Provision SQL Service Login"
                    }
                    else {
                        $Connection = New-SqlConnection `
                            -DataSource `
                                $SelectedInstance.ConnectionTarget `
                            -InitialCatalog "master" `
                            -SqlCredential $ProvisioningSqlCredential `
                            -ConnectionTimeoutSeconds `
                                $ConnectionTimeoutSeconds `
                            -ApplicationName "Provision SQL Service Login"
                    }

                    try {
                        $Connection.Open()
                        $ServerNameCommand = $Connection.CreateCommand()

                        try {
                            $ServerNameCommand.CommandTimeout =
                                $CommandTimeoutSeconds
                            $ServerNameCommand.CommandText =
                                "SELECT CONVERT(nvarchar(128), " +
                                "SERVERPROPERTY(N'ServerName'));"
                            $CurrentResolvedInstanceName =
                                [string]$ServerNameCommand.ExecuteScalar()
                        }
                        finally {
                            $ServerNameCommand.Dispose()
                        }

                        $LoginCheckCommand = $Connection.CreateCommand()

                        try {
                            $LoginCheckCommand.CommandTimeout =
                                $CommandTimeoutSeconds
                            $LoginCheckCommand.CommandText = @"
SELECT [type_desc], [is_disabled]
FROM sys.server_principals
WHERE [name] = @LoginName;
"@
                            [void]$LoginCheckCommand.Parameters.Add(
                                "@LoginName",
                                [System.Data.SqlDbType]::NVarChar,
                                128
                            )
                            $LoginCheckCommand.Parameters["@LoginName"].Value =
                                $ServiceLoginName
                            $Reader = $LoginCheckCommand.ExecuteReader()

                            try {
                                if ($Reader.Read()) {
                                    $LoginExists = $true
                                    $LoginType =
                                        [string]$Reader["type_desc"]
                                    $LoginIsDisabled =
                                        [bool]$Reader["is_disabled"]
                                }
                                else {
                                    $LoginExists = $false
                                    $LoginType = $null
                                    $LoginIsDisabled = $false
                                }
                            }
                            finally {
                                $Reader.Dispose()
                            }
                        }
                        finally {
                            $LoginCheckCommand.Dispose()
                        }

                        if ($LoginExists -and $LoginType -ne "SQL_LOGIN") {
                            throw (
                                "Principal [$ServiceLoginName] exists as " +
                                "[$LoginType], not SQL_LOGIN."
                            )
                        }

                        if ($LoginExists -and $LoginIsDisabled) {
                            throw "SQL Login [$ServiceLoginName] is disabled."
                        }

                        $CreatedDuringAttempt = $false

                        if (-not $LoginExists) {
                            $PasswordPointer = [IntPtr]::Zero

                            try {
                                $PasswordPointer =
                                    [Runtime.InteropServices.Marshal]::
                                        SecureStringToBSTR(
                                            $ServiceCredential.Password
                                        )
                                $PlainPassword =
                                    [Runtime.InteropServices.Marshal]::
                                        PtrToStringBSTR($PasswordPointer)
                                $EscapedPassword =
                                    $PlainPassword.Replace("'", "''")
                                $CreateLoginCommand =
                                    $Connection.CreateCommand()

                                try {
                                    $CreateLoginCommand.CommandTimeout =
                                        $CommandTimeoutSeconds
                                    $CreateLoginCommand.CommandText = @"
CREATE LOGIN [$ServiceLoginName]
WITH
    PASSWORD = N'$EscapedPassword',
    CHECK_POLICY = OFF,
    CHECK_EXPIRATION = OFF;
"@
                                    [void](
                                        $CreateLoginCommand.ExecuteNonQuery()
                                    )
                                }
                                finally {
                                    $CreateLoginCommand.Dispose()
                                }

                                $CreatedDuringAttempt = $true
                            }
                            finally {
                                if ($PasswordPointer -ne [IntPtr]::Zero) {
                                    [Runtime.InteropServices.Marshal]::
                                        ZeroFreeBSTR($PasswordPointer)
                                }

                                $PlainPassword = $null
                                $EscapedPassword = $null
                            }
                        }

                        $GrantCommand = $Connection.CreateCommand()

                        try {
                            $GrantCommand.CommandTimeout =
                                $CommandTimeoutSeconds
                            $GrantCommand.CommandText = @"
GRANT CONNECT SQL TO [$ServiceLoginName];
GRANT VIEW ANY DATABASE TO [$ServiceLoginName];
GRANT VIEW ANY DEFINITION TO [$ServiceLoginName];
GRANT VIEW SERVER STATE TO [$ServiceLoginName];

USE [msdb];

IF USER_ID(N'$ServiceLoginName') IS NULL
BEGIN
    CREATE USER [$ServiceLoginName] FOR LOGIN [$ServiceLoginName];
END
ELSE
BEGIN
    ALTER USER [$ServiceLoginName] WITH LOGIN = [$ServiceLoginName];
END;

IF NOT EXISTS
(
    SELECT 1
    FROM sys.database_role_members AS drm
    INNER JOIN sys.database_principals AS role_principal
        ON role_principal.principal_id = drm.role_principal_id
    INNER JOIN sys.database_principals AS member_principal
        ON member_principal.principal_id = drm.member_principal_id
    WHERE role_principal.name = N'SQLAgentOperatorRole'
      AND member_principal.name = N'$ServiceLoginName'
)
BEGIN
    ALTER ROLE [SQLAgentOperatorRole]
        ADD MEMBER [$ServiceLoginName];
END;

GRANT EXECUTE ON OBJECT::dbo.agent_datetime
    TO [$ServiceLoginName];
"@
                            [void]$GrantCommand.ExecuteNonQuery()
                        }
                        finally {
                            $GrantCommand.Dispose()
                        }

                        [pscustomobject]@{
                            InstanceName = $CurrentResolvedInstanceName
                            LoginCreated = $CreatedDuringAttempt
                        }
                    }
                    finally {
                        $Connection.Dispose()
                    }
                }

            $LoginWasCreated = $ProvisionResult.LoginCreated
            $ResolvedInstanceName = $ProvisionResult.InstanceName

            $ValidationResult = Invoke-SqlWithRetry `
                -Step "ValidateServiceCredential" `
                -Instance $SelectedInstance.ConnectionTarget `
                -RetryCount $RetryCount `
                -RetryDelaySeconds $RetryDelaySeconds `
                -LogContext $LogContext `
                -Operation {
                    $Connection = New-SqlConnection `
                        -DataSource $SelectedInstance.ConnectionTarget `
                        -InitialCatalog "master" `
                        -SqlCredential $ServiceSqlCredential `
                        -ConnectionTimeoutSeconds `
                            $ConnectionTimeoutSeconds `
                        -ApplicationName "Validate SQL Service Credential"

                    try {
                        $Connection.Open()
                        $Command = $Connection.CreateCommand()

                        try {
                            $Command.CommandTimeout = $CommandTimeoutSeconds
                            $Command.CommandText = @"
SELECT
    CONVERT(nvarchar(128), ORIGINAL_LOGIN()) AS [LoginName],
    CONVERT(nvarchar(128), SERVERPROPERTY(N'ServerName'))
        AS [ServerName];
"@
                            $Reader = $Command.ExecuteReader()

                            try {
                                [void]$Reader.Read()
                                [pscustomobject]@{
                                    LoginName =
                                        [string]$Reader["LoginName"]
                                    ServerName =
                                        [string]$Reader["ServerName"]
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

            if ($ValidationResult.LoginName -ine $ServiceLoginName) {
                throw (
                    "Credential authenticated as " +
                    "[$($ValidationResult.LoginName)], expected " +
                    "[$ServiceLoginName]."
                )
            }

            Write-SqlMaintenanceLog `
                -LogContext $LogContext `
                -Level Info `
                -Step "ValidateServiceCredential" `
                -Instance $SelectedInstance.ConnectionTarget `
                -Message "Credential validation succeeded."

            $ProvisioningResults.Add(
                [pscustomobject]@{
                    Instance           = $ResolvedInstanceName
                    Login              = $ServiceLoginName
                    Authentication     = $AuthenticationMode
                    LoginCreated       = $LoginWasCreated
                    Permissions        = "Granted"
                    CredentialVerified = $true
                    Detail              = "Success"
                }
            )
        }
        catch {
            Write-SqlMaintenanceLog `
                -LogContext $LogContext `
                -Level Error `
                -Step "ProvisionLogin" `
                -Instance $SelectedInstance.ConnectionTarget `
                -Message $_.Exception.Message
            $ProvisioningResults.Add(
                [pscustomobject]@{
                    Instance           = $ResolvedInstanceName
                    Login              = $ServiceLoginName
                    Authentication     = $AuthenticationMode
                    LoginCreated       = $LoginWasCreated
                    Permissions        = "Failed"
                    CredentialVerified = $false
                    Detail              = $_.Exception.Message
                }
            )
        }
    }
}
finally {
    $ReadOnlyServicePassword.Dispose()

    if ($null -ne $ReadOnlyAdminPassword) {
        $ReadOnlyAdminPassword.Dispose()
    }
}

Write-Host ""
Write-Host "Provisioning and credential validation results:"
$ProvisioningResults | Format-Table -AutoSize

$FailedResults = @(
    $ProvisioningResults |
        Where-Object {
            $_.Permissions -eq "Failed" -or
            -not $_.CredentialVerified
        }
)

if ($FailedResults.Count -gt 0) {
    throw "One or more SQL Server instances failed provisioning or validation."
}

Write-SqlMaintenanceLog `
    -LogContext $LogContext `
    -Level Info `
    -Step "ProvisionLogin" `
    -Message (
        "Provisioning and credential validation completed for " +
        "$($ProvisioningResults.Count) instance(s)."
    )

$ProvisioningResults
