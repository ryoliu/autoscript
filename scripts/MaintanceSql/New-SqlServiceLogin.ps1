<#
.SYNOPSIS
Lists local SQL Server instances and provisions a service SQL Login on the
selected instances.

.DESCRIPTION
Discovers local default and named SQL Server instances from Windows services,
displays an interactive selection menu, and tests whether the current Windows
account can connect and provision a SQL Login.

Windows authentication is used when the current account has sysadmin membership
or CONTROL SERVER permission. If it does not, the script requests a fallback SQL
administrator credential. The target service Login is created only when it does
not already exist; its server and msdb permissions are then applied on every
selected instance.

.PARAMETER ServiceLoginName
Name of the SQL Login to create or update. The default value is srv.mn.

.PARAMETER ServiceCredential
Optional credential containing the service Login name and password. The password
is used only when the Login must be created. An existing Login password is not
changed.

.PARAMETER SqlAdminCredential
Optional fallback SQL administrator credential. It is used only for instances
that cannot be provisioned by the current Windows account. When omitted, the
script prompts for a credential if one is required.

.EXAMPLE
.\New-SqlServiceLogin.ps1

Interactively selects instances, checks the current Windows account, and prompts
for credentials and the new Login password only when required.

.EXAMPLE
$SqlCredential = Get-Credential -UserName "sa"
.\New-SqlServiceLogin.ps1 -SqlAdminCredential $SqlCredential

Supplies a fallback SQL administrator credential before running the interactive
instance selection.

.NOTES
The provisioning account must be a sysadmin or have CONTROL SERVER permission.
An existing service Login password is not changed. New Logins are created with
CHECK_POLICY and CHECK_EXPIRATION disabled.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$ServiceLoginName = "srv.mn",

    [Parameter()]
    [PSCredential]$ServiceCredential,

    [Parameter()]
    [PSCredential]$SqlAdminCredential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Keep sensitive values in SecureString-based objects whenever possible.
$CurrentWindowsAccount =
    [Security.Principal.WindowsIdentity]::GetCurrent().Name
$ReadOnlyAdminPassword = $null
$ProvisioningCredential = $null
$ServicePassword = $null
$ProvisioningResults = [System.Collections.Generic.List[object]]::new()

if ($null -ne $ServiceCredential) {
    if ($ServiceCredential.UserName -cne $ServiceLoginName) {
        throw (
            "Service credential user [$($ServiceCredential.UserName)] " +
            "does not match ServiceLoginName [$ServiceLoginName]."
        )
    }

    $ServicePassword = $ServiceCredential.Password.Copy()
    $ServicePassword.MakeReadOnly()
}

try {
    # Discover local default and named SQL Server instances from services.
    $SqlServices = @(
        Get-Service |
            Where-Object {
                $_.Name -eq "MSSQLSERVER" -or
                $_.Name -like 'MSSQL$*'
            } |
            Sort-Object Name
    )

    if ($SqlServices.Count -eq 0) {
        throw "No local SQL Server instances were found."
    }

    $SqlInstances = @(
        for ($Index = 0; $Index -lt $SqlServices.Count; $Index++) {
            $SqlService = $SqlServices[$Index]

            # The default instance uses localhost; named instances use
            # localhost\InstanceName.
            if ($SqlService.Name -eq "MSSQLSERVER") {
                $InstanceName = "MSSQLSERVER"
                $ConnectionTarget = "localhost"
            }
            else {
                $InstanceName = $SqlService.Name.Substring(6)
                $ConnectionTarget = "localhost\$InstanceName"
            }

            [pscustomobject]@{
                Index            = $Index + 1
                InstanceName     = $InstanceName
                ConnectionTarget = $ConnectionTarget
                Status           = $SqlService.Status
            }
        }
    )

    Write-Host ""
    Write-Host "Local SQL Server instances:"
    $SqlInstances |
        Format-Table Index, InstanceName, ConnectionTarget, Status -AutoSize |
        Out-Host

    if (-not ($SqlInstances | Where-Object Status -eq "Running")) {
        throw "No running local SQL Server instances were found."
    }

    # Accept one or more menu indexes, or A to select every running instance.
    while ($true) {
        $Selection = (
            Read-Host "Select instance numbers (example: 1,3; A = all running)"
        ).Trim()

        if ($Selection -match '^(?i)A$') {
            $SelectedSqlInstances = @(
                $SqlInstances | Where-Object Status -eq "Running"
            )
            break
        }

        $SelectedIndexes = @()
        $SelectionIsValid = $true

        # Allow comma-separated, space-separated, or mixed input.
        foreach ($SelectionPart in ($Selection -split '[,\s]+')) {
            $SelectedIndex = 0

            if (
                [string]::IsNullOrWhiteSpace($SelectionPart) -or
                -not [int]::TryParse($SelectionPart, [ref]$SelectedIndex) -or
                $SelectedIndex -lt 1 -or
                $SelectedIndex -gt $SqlInstances.Count
            ) {
                $SelectionIsValid = $false
                break
            }

            $SelectedIndexes += $SelectedIndex
        }

        $SelectedIndexes = @($SelectedIndexes | Select-Object -Unique)
        $SelectedSqlInstances = @(
            $SqlInstances |
                Where-Object { $SelectedIndexes -contains $_.Index }
        )

        if (
            -not $SelectionIsValid -or
            $SelectedSqlInstances.Count -eq 0
        ) {
            Write-Warning "Invalid selection. Please try again."
            continue
        }

        $StoppedSelections = @(
            $SelectedSqlInstances | Where-Object Status -ne "Running"
        )

        if ($StoppedSelections.Count -gt 0) {
            Write-Warning (
                "The following instances are not running: " +
                (($StoppedSelections.InstanceName) -join ", ")
            )
            continue
        }

        break
    }

    Write-Host "Selected instances: $($SelectedSqlInstances.InstanceName -join ', ')"

    # Test the current Windows account before requesting a SQL credential.
    # The conservative permission check requires sysadmin or CONTROL SERVER.
    $WindowsAuthenticationResults =
        [System.Collections.Generic.List[object]]::new()

    foreach ($SelectedInstance in $SelectedSqlInstances) {
        $PreflightConnectionStringBuilder =
            [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
        $PreflightConnectionStringBuilder["Data Source"] =
            $SelectedInstance.ConnectionTarget
        $PreflightConnectionStringBuilder["Initial Catalog"] = "master"
        $PreflightConnectionStringBuilder["Integrated Security"] = $true
        $PreflightConnectionStringBuilder["Encrypt"] = $true
        $PreflightConnectionStringBuilder["TrustServerCertificate"] = $true
        $PreflightConnectionStringBuilder["Application Name"] =
            "Test SQL Login Provisioning Permission"

        $PreflightConnection = [System.Data.SqlClient.SqlConnection]::new(
            $PreflightConnectionStringBuilder.ConnectionString
        )

        try {
            $PreflightConnection.Open()

            # Read the SQL login identity and server-level provisioning rights.
            $PermissionCommand = $PreflightConnection.CreateCommand()
            $PermissionCommand.CommandText = @"
SELECT
    SYSTEM_USER AS LoginName,
    CASE WHEN IS_SRVROLEMEMBER(N'sysadmin') = 1 THEN 1 ELSE 0 END
        AS IsSysadmin,
    CASE WHEN HAS_PERMS_BY_NAME(NULL, NULL, N'CONTROL SERVER') = 1
         THEN 1 ELSE 0 END AS HasControlServer;
"@
            $PermissionReader = $PermissionCommand.ExecuteReader()
            [void]$PermissionReader.Read()

            $DatabaseLogin = [string]$PermissionReader["LoginName"]
            $IsSysadmin = [bool]$PermissionReader["IsSysadmin"]
            $HasControlServer = [bool]$PermissionReader["HasControlServer"]
            $CanCreateLogin = $IsSysadmin -or $HasControlServer

            $PermissionReader.Close()
            $PermissionCommand.Dispose()

            if ($CanCreateLogin) {
                $PermissionDetail = "sysadmin or CONTROL SERVER"
            }
            else {
                $PermissionDetail =
                    "Connected, but lacks sysadmin or CONTROL SERVER"
            }

            $WindowsAuthenticationResults.Add(
                [pscustomobject]@{
                    ConnectionTarget = $SelectedInstance.ConnectionTarget
                    Instance         = $SelectedInstance.InstanceName
                    WindowsAccount   = $CurrentWindowsAccount
                    DatabaseLogin    = $DatabaseLogin
                    CanConnect       = $true
                    CanCreateLogin   = $CanCreateLogin
                    Detail           = $PermissionDetail
                }
            )
        }
        catch {
            $WindowsAuthenticationResults.Add(
                [pscustomobject]@{
                    ConnectionTarget = $SelectedInstance.ConnectionTarget
                    Instance         = $SelectedInstance.InstanceName
                    WindowsAccount   = $CurrentWindowsAccount
                    DatabaseLogin    = $null
                    CanConnect       = $false
                    CanCreateLogin   = $false
                    Detail           = $_.Exception.Message
                }
            )
        }
        finally {
            $PreflightConnection.Dispose()
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
        # Request the fallback credential only when Windows authentication is
        # insufficient for at least one selected instance.
        if ($null -eq $SqlAdminCredential) {
            Write-Warning (
                "Windows authentication cannot provision every selected " +
                "instance. A fallback SQL credential is required."
            )

            $SqlAdminCredential = Get-Credential `
                -UserName "zabbix" `
                -Message (
                    "Enter a SQL Login that can create logins and " +
                    "grant permissions"
                )
        }

        if ($null -eq $SqlAdminCredential) {
            throw "A fallback SQL administrator credential is required."
        }

        $ReadOnlyAdminPassword = $SqlAdminCredential.Password.Copy()
        $ReadOnlyAdminPassword.MakeReadOnly()

        # SqlCredential avoids placing the administrator password in the
        # connection string.
        $ProvisioningCredential =
            [System.Data.SqlClient.SqlCredential]::new(
                $SqlAdminCredential.UserName,
                $ReadOnlyAdminPassword
            )
    }

    foreach ($SelectedInstance in $SelectedSqlInstances) {
        # Build a separate connection for each selected SQL Server instance.
        $ConnectionStringBuilder =
            [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
        $ConnectionStringBuilder["Data Source"] =
            $SelectedInstance.ConnectionTarget
        $ConnectionStringBuilder["Initial Catalog"] = "master"
        $ConnectionStringBuilder["Encrypt"] = $true
        $ConnectionStringBuilder["TrustServerCertificate"] = $true
        $ConnectionStringBuilder["Application Name"] =
            "Create SQL Service Login"

        $WindowsAuthenticationResult =
            $WindowsAuthenticationResults |
                Where-Object {
                    $_.ConnectionTarget -eq
                        $SelectedInstance.ConnectionTarget
                } |
                Select-Object -First 1

        if ($WindowsAuthenticationResult.CanCreateLogin) {
            # Prefer the already validated Windows account.
            $ConnectionStringBuilder["Integrated Security"] = $true
            $AuthenticationMode = "Windows"
            $SqlConnection = [System.Data.SqlClient.SqlConnection]::new(
                $ConnectionStringBuilder.ConnectionString
            )
        }
        else {
            # Use the fallback SQL credential only for instances where the
            # Windows account did not pass the provisioning preflight.
            $AuthenticationMode = "SQL Login"
            $SqlConnection = [System.Data.SqlClient.SqlConnection]::new(
                $ConnectionStringBuilder.ConnectionString,
                $ProvisioningCredential
            )
        }

        $LoginWasCreated = $false

        try {
            Write-Host "Processing: $($SelectedInstance.ConnectionTarget)"
            $SqlConnection.Open()

            $InstanceNameCommand = $SqlConnection.CreateCommand()
            $InstanceNameCommand.CommandText =
                "SELECT CAST(SERVERPROPERTY('ServerName') AS nvarchar(128));"
            $ResolvedInstanceName =
                [string]$InstanceNameCommand.ExecuteScalar()
            $InstanceNameCommand.Dispose()

            # Existing Logins keep their current password. The password prompt
            # is shown once and reused only when new Logins must be created.
            $LoginCheckCommand = $SqlConnection.CreateCommand()
            $LoginCheckCommand.CommandText =
                "SELECT CASE WHEN SUSER_ID(@LoginName) IS NULL THEN 0 ELSE 1 END;"
            [void]$LoginCheckCommand.Parameters.Add(
                "@LoginName",
                [System.Data.SqlDbType]::NVarChar,
                128
            )
            $LoginCheckCommand.Parameters["@LoginName"].Value =
                $ServiceLoginName

            $LoginExists = [bool]$LoginCheckCommand.ExecuteScalar()
            $LoginCheckCommand.Dispose()

            if (-not $LoginExists) {
                if ($null -eq $ServicePassword) {
                    $ServicePassword = Read-Host `
                        "Input password for SQL Login [$ServiceLoginName]" `
                        -AsSecureString
                }

                $PasswordPointer = [IntPtr]::Zero

                try {
                    # SQL Server CREATE LOGIN requires a plaintext password in
                    # the batch. Keep the conversion window as short as possible.
                    $PasswordPointer =
                        [Runtime.InteropServices.Marshal]::SecureStringToBSTR(
                            $ServicePassword
                        )

                    $PlainServicePassword =
                        [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
                            $PasswordPointer
                        )

                    $EscapedServicePassword =
                        $PlainServicePassword.Replace("'", "''")

                    $CreateLoginCommand = $SqlConnection.CreateCommand()
                    $CreateLoginCommand.CommandText = @"
CREATE LOGIN [$ServiceLoginName]
WITH
    PASSWORD = N'$EscapedServicePassword',
    CHECK_POLICY = OFF,
    CHECK_EXPIRATION = OFF;
"@
                    [void]$CreateLoginCommand.ExecuteNonQuery()
                    $CreateLoginCommand.Dispose()
                    $LoginWasCreated = $true
                }
                finally {
                    # Zero the unmanaged buffer immediately after execution.
                    if ($PasswordPointer -ne [IntPtr]::Zero) {
                        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR(
                            $PasswordPointer
                        )
                    }

                    $PlainServicePassword = $null
                    $EscapedServicePassword = $null
                }
            }

            # Apply idempotent server permissions, create or remap the msdb
            # user, add the Agent role membership, and grant agent_datetime.
            $GrantCommand = $SqlConnection.CreateCommand()
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
    ALTER ROLE [SQLAgentOperatorRole] ADD MEMBER [$ServiceLoginName];
END;

GRANT EXECUTE ON OBJECT::dbo.agent_datetime TO [$ServiceLoginName];
"@
            [void]$GrantCommand.ExecuteNonQuery()
            $GrantCommand.Dispose()

            $ProvisioningResults.Add(
                [pscustomobject]@{
                    Instance     = $ResolvedInstanceName
                    Login        = $ServiceLoginName
                    Authentication = $AuthenticationMode
                    LoginCreated = $LoginWasCreated
                    Permissions  = "Granted"
                }
            )
        }
        catch {
            # Record per-instance failures so remaining instances can continue.
            $ProvisioningResults.Add(
                [pscustomobject]@{
                    Instance     = $SelectedInstance.ConnectionTarget
                    Login        = $ServiceLoginName
                    Authentication = $AuthenticationMode
                    LoginCreated = $LoginWasCreated
                    Permissions  = "Failed: $($_.Exception.Message)"
                }
            )
        }
        finally {
            $SqlConnection.Dispose()
        }
    }
}
finally {
    # Dispose SecureString copies after all instances have been processed.
    if ($null -ne $ServicePassword) {
        $ServicePassword.Dispose()
    }

    if ($null -ne $ReadOnlyAdminPassword) {
        $ReadOnlyAdminPassword.Dispose()
    }
}

Write-Host ""
Write-Host "Provisioning results:"
$ProvisioningResults | Format-Table -AutoSize

# Return a failing process state to callers when any instance failed.
if ($ProvisioningResults.Permissions -match '^Failed:') {
    throw "One or more SQL Server instances failed."
}
