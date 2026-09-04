<#
.SYNOPSIS
Registers selected SQL Server instance names in a central monitoring table.

.DESCRIPTION
Uses one shared instance selection supplied by the CLI, or discovers and selects
local instances when run independently. The script loads the encrypted srv.mn
credential, validates the Monitor repository before any write, retrieves each
SQL Server instance name with T-SQL, and inserts names that do not already exist.

SQL connections and commands use configurable timeouts. Only transient SQL or
network failures are retried; authentication, permission, schema, and credential
errors fail immediately.

.PARAMETER SourceInstance
Optional SQL Server connection targets. Supplying this parameter bypasses local
discovery and the interactive instance menu.

.PARAMETER ConfigPath
Path to the repository configuration file. The default is repository.config in
the shared Config directory.

.PARAMETER RepositoryInstance
Optional SQL Server instance that overrides RepositoryInstance in the
repository configuration file. The parameter alias is Ins.

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
SQL Login used for source and repository connections. The default is srv.mn.

.PARAMETER CredentialDirectory
Directory containing the AES key and encrypted credential files. The default is
the shared Credentials directory.

.PARAMETER Credential
Optional SQL Login credential that overrides the stored credential files.

.EXAMPLE
.\getInstanceName.ps1

Selects local SQL Server instances and registers them after repository
validation.

.EXAMPLE
.\getInstanceName.ps1 `
    -SourceInstance "localhost","localhost\LAB2" `
    -RepositoryInstance "WIN2019LAB"

Uses the supplied instance list without displaying an instance menu.

.NOTES
Run Initialize-SqlMonitorRepository.ps1 first when the repository database,
schema, table, or srv.mn database user has not been initialized.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string[]]$SourceInstance,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath = (
        Join-Path `
            (Split-Path -Parent $PSScriptRoot) `
            "Config\repository.config"
    ),

    [Parameter()]
    [Alias("Ins")]
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
    [ValidateNotNullOrEmpty()]
    [string]$CredentialDirectory = (
        Join-Path `
            (Split-Path -Parent $PSScriptRoot) `
            "Credentials"
    ),

    [Parameter()]
    [PSCredential]$Credential,

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

if ($null -eq $LogContext) {
    $LogContext = New-SqlMaintenanceLogContext `
        -LogDirectory $LogDirectory `
        -OperationName "Register-SqlInstance"
}

$SelectionParameters = @{}

if ($PSBoundParameters.ContainsKey("SourceInstance")) {
    $SelectionParameters.SourceInstance = $SourceInstance
}

$SelectedSourceInstances = @(
    Select-SqlInstance @SelectionParameters
)
$LoadedCredentialPassword = $null

if ($null -eq $Credential) {
    $KeyPath = Join-Path $CredentialDirectory "$SqlLoginName.key"
    $CredentialPath =
        Join-Path $CredentialDirectory "$SqlLoginName.credential.xml"

    if (-not (Test-Path -LiteralPath $KeyPath -PathType Leaf)) {
        throw (
            "SQL credential key not found: $KeyPath. Run " +
            "New-SqlCredentialKey.ps1 first."
        )
    }

    if (-not (Test-Path -LiteralPath $CredentialPath -PathType Leaf)) {
        throw (
            "Encrypted SQL credential not found: $CredentialPath. Run " +
            "New-SqlCredentialKey.ps1 first."
        )
    }

    $AesKey = [IO.File]::ReadAllBytes($KeyPath)

    try {
        if ($AesKey.Length -notin 16, 24, 32) {
            throw (
                "Invalid AES key length in [$KeyPath]: " +
                "$($AesKey.Length) bytes."
            )
        }

        $StoredCredential = Import-Clixml -LiteralPath $CredentialPath

        if (
            $StoredCredential.PSObject.Properties.Name `
                -notcontains "UserName" -or
            $StoredCredential.PSObject.Properties.Name `
                -notcontains "EncryptedPassword"
        ) {
            throw "Invalid SQL credential file: $CredentialPath"
        }

        $LoadedCredentialPassword =
            $StoredCredential.EncryptedPassword |
                ConvertTo-SecureString -Key $AesKey
        $Credential = [PSCredential]::new(
            [string]$StoredCredential.UserName,
            $LoadedCredentialPassword
        )
    }
    finally {
        [Array]::Clear($AesKey, 0, $AesKey.Length)
    }
}

if ($Credential.UserName -cne $SqlLoginName) {
    throw (
        "Credential user [$($Credential.UserName)] does not match " +
        "SqlLoginName [$SqlLoginName]."
    )
}

Write-SqlMaintenanceLog `
    -LogContext $LogContext `
    -Level Info `
    -Step "RegisterInstances" `
    -Message (
        "Starting registration for: " +
        ($SelectedSourceInstances.ConnectionTarget -join ", ")
    )

# Repository validation is intentionally performed inside this script as well
# as the CLI so direct execution cannot bypass the prerequisite checks.
$RepositoryPreflight = Test-SqlMonitorRepository `
    -RepositoryInstance $RepositoryInstance `
    -RepositoryDatabase $RepositoryDatabase `
    -RepositorySchema $RepositorySchema `
    -RepositoryTable $RepositoryTable `
    -Credential $Credential `
    -ConnectionTimeoutSeconds $ConnectionTimeoutSeconds `
    -CommandTimeoutSeconds $CommandTimeoutSeconds `
    -RetryCount $RetryCount `
    -RetryDelaySeconds $RetryDelaySeconds `
    -LogContext $LogContext

$MaximumInstanceNameLength = if (
    $RepositoryPreflight.InsNameLength -eq -1
) {
    128
}
else {
    $RepositoryPreflight.InsNameLength
}

$ReadOnlyPassword = $Credential.Password.Copy()
$ReadOnlyPassword.MakeReadOnly()
$SqlCredential = [System.Data.SqlClient.SqlCredential]::new(
    $Credential.UserName,
    $ReadOnlyPassword
)
$RegistrationResults = [System.Collections.Generic.List[object]]::new()
$QualifiedTable = "[$RepositorySchema].[$RepositoryTable]"

try {
    foreach ($SelectedSourceInstance in $SelectedSourceInstances) {
        $SqlInstanceName = $null

        try {
            $SqlInstanceName = Invoke-SqlWithRetry `
                -Step "ReadInstanceName" `
                -Instance $SelectedSourceInstance.ConnectionTarget `
                -RetryCount $RetryCount `
                -RetryDelaySeconds $RetryDelaySeconds `
                -LogContext $LogContext `
                -Operation {
                    $Connection = New-SqlConnection `
                        -DataSource `
                            $SelectedSourceInstance.ConnectionTarget `
                        -InitialCatalog "master" `
                        -SqlCredential $SqlCredential `
                        -ConnectionTimeoutSeconds `
                            $ConnectionTimeoutSeconds `
                        -ApplicationName "Read SQL Instance Name"

                    try {
                        $Connection.Open()
                        $Command = $Connection.CreateCommand()

                        try {
                            $Command.CommandTimeout = $CommandTimeoutSeconds
                            $Command.CommandText = @"
SET NOCOUNT ON;
SELECT CONVERT(nvarchar(128), SERVERPROPERTY(N'ServerName'));
"@
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

            if ([string]::IsNullOrWhiteSpace($SqlInstanceName)) {
                throw "SQL Server returned an empty instance name."
            }

            if ($SqlInstanceName.Length -gt $MaximumInstanceNameLength) {
                throw (
                    "SQL instance name length $($SqlInstanceName.Length) " +
                    "exceeds repository InsName length " +
                    "${MaximumInstanceNameLength}: $SqlInstanceName"
                )
            }

            $WasInserted = Invoke-SqlWithRetry `
                -Step "WriteRepository" `
                -Instance $RepositoryInstance `
                -RetryCount $RetryCount `
                -RetryDelaySeconds $RetryDelaySeconds `
                -LogContext $LogContext `
                -Operation {
                    $Connection = New-SqlConnection `
                        -DataSource $RepositoryInstance `
                        -InitialCatalog $RepositoryDatabase `
                        -SqlCredential $SqlCredential `
                        -ConnectionTimeoutSeconds `
                            $ConnectionTimeoutSeconds `
                        -ApplicationName "Register SQL Instance"

                    try {
                        $Connection.Open()
                        $Command = $Connection.CreateCommand()

                        try {
                            $Command.CommandTimeout = $CommandTimeoutSeconds
                            $Command.CommandText = @"
SET NOCOUNT ON;

DECLARE @Inserted bit = 0;

IF NOT EXISTS
(
    SELECT 1
    FROM $QualifiedTable
    WHERE [InsName] = @InstanceName
)
BEGIN
    INSERT INTO $QualifiedTable ([InsName])
    VALUES (@InstanceName);

    SET @Inserted = 1;
END;

SELECT @Inserted;
"@
                            [void]$Command.Parameters.Add(
                                "@InstanceName",
                                [System.Data.SqlDbType]::NVarChar,
                                128
                            )
                            $Command.Parameters["@InstanceName"].Value =
                                $SqlInstanceName
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

            $Status = if ($WasInserted) {
                "Inserted"
            }
            else {
                "Already exists"
            }

            Write-SqlMaintenanceLog `
                -LogContext $LogContext `
                -Level Info `
                -Step "RegisterInstances" `
                -Instance $SelectedSourceInstance.ConnectionTarget `
                -Message "${SqlInstanceName}: $Status"
            $RegistrationResults.Add(
                [pscustomobject]@{
                    SourceTarget =
                        $SelectedSourceInstance.ConnectionTarget
                    InstanceName = $SqlInstanceName
                    Status       = $Status
                    Detail       = "Success"
                }
            )
        }
        catch {
            Write-SqlMaintenanceLog `
                -LogContext $LogContext `
                -Level Error `
                -Step "RegisterInstances" `
                -Instance $SelectedSourceInstance.ConnectionTarget `
                -Message $_.Exception.Message
            $RegistrationResults.Add(
                [pscustomobject]@{
                    SourceTarget =
                        $SelectedSourceInstance.ConnectionTarget
                    InstanceName = $SqlInstanceName
                    Status       = "Failed"
                    Detail       = $_.Exception.Message
                }
            )
        }
    }
}
finally {
    $ReadOnlyPassword.Dispose()

    if ($null -ne $LoadedCredentialPassword) {
        $LoadedCredentialPassword.Dispose()
    }
}

Write-Host ""
Write-Host (
    "Registration results: " +
    "$RepositoryInstance.$RepositoryDatabase.$QualifiedTable"
)
$RegistrationResults | Format-Table -AutoSize

$FailedResults = @(
    $RegistrationResults | Where-Object Status -eq "Failed"
)

if ($FailedResults.Count -gt 0) {
    throw "One or more SQL Server instances failed to register."
}

Write-SqlMaintenanceLog `
    -LogContext $LogContext `
    -Level Info `
    -Step "RegisterInstances" `
    -Message (
        "Registration completed for " +
        "$($RegistrationResults.Count) instance(s)."
    )

$RegistrationResults
