<#
.SYNOPSIS
Registers SQL Server Client connection targets in the central repository.

.DESCRIPTION
Runs only on ServerRepository. The script loads the centrally stored monitoring
credential, verifies each Client connection, reads the SQL Server reported
instance name, and inserts or updates the repository instance list. An optional
scoped collection test runs only against the registered connection targets.

InsName stores the connection target used by GetDBInfo. ReportedInstanceName
stores the name returned by SERVERPROPERTY and is not used as a connection
string.

.PARAMETER SourceInstance
One or more Client SQL Server connection targets, such as CLIENT01,
CLIENT01\INSTANCE01, or CLIENT01,14330.

.PARAMETER Credential
Optional monitoring credential. When omitted, the central AES key and encrypted
credential XML are loaded from the Credentials directory.

.PARAMETER RunCollectionTest
Runs the central GetDBInfo Collector against only the successfully registered
connection targets. This option requires the central credential files.

.PARAMETER IncludeTopResourceUsage
Includes the Top Resource Usage report when RunCollectionTest is selected.

.EXAMPLE
.\Register-SqlMonitoringClient.ps1 `
    -SourceInstance "CLIENT01\INSTANCE01"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$SourceInstance,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath,

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
    [string]$SqlLoginName,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$CredentialDirectory,

    [Parameter()]
    [PSCredential]$Credential,

    [Parameter()]
    [switch]$RunCollectionTest,

    [Parameter()]
    [switch]$IncludeTopResourceUsage,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$CollectorScriptPath,

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
    [string]$LogDirectory = (
        Join-Path (Split-Path -Parent $PSScriptRoot) "Logs"
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ServerRoot = Split-Path -Parent $PSScriptRoot
$SourceRoot = Split-Path -Parent $ServerRoot
$CommonModulePath = Join-Path `
    $ServerRoot `
    "Modules\SqlMaintenance.Common\SqlMaintenance.Common.psm1"

if (-not (Test-Path -LiteralPath $CommonModulePath -PathType Leaf)) {
    throw "Required module not found: $CommonModulePath"
}

Import-Module $CommonModulePath -Force

if (-not $PSBoundParameters.ContainsKey("ConfigPath")) {
    $ConfigCandidates = @(
        (Join-Path $ServerRoot "Config\repository.config"),
        (Join-Path $SourceRoot "Config\repository.config")
    )
    $ConfigPath = $ConfigCandidates |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        throw "Repository configuration file was not found."
    }
}

$RepositoryConfigParameters = @{ LiteralPath = $ConfigPath }

foreach ($ParameterName in @(
    "RepositoryInstance",
    "RepositoryDatabase",
    "RepositorySchema",
    "RepositoryTable"
)) {
    if ($PSBoundParameters.ContainsKey($ParameterName)) {
        $RepositoryConfigParameters[$ParameterName] =
            $PSBoundParameters[$ParameterName]
    }
}

$RepositoryConfig = Get-SqlRepositoryConfig @RepositoryConfigParameters
$RepositoryInstance = $RepositoryConfig.RepositoryInstance
$RepositoryDatabase = $RepositoryConfig.RepositoryDatabase
$RepositorySchema = $RepositoryConfig.RepositorySchema
$RepositoryTable = $RepositoryConfig.RepositoryTable

if (-not $PSBoundParameters.ContainsKey("SqlLoginName")) {
    $SqlLoginName = $RepositoryConfig.SqlLoginName
}

if (-not $PSBoundParameters.ContainsKey("CredentialDirectory")) {
    $CredentialCandidates = @(
        (Join-Path $ServerRoot "Credentials"),
        (Join-Path $SourceRoot "Credentials")
    )
    $CredentialDirectory = $CredentialCandidates |
        Where-Object { Test-Path -LiteralPath $_ -PathType Container } |
        Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace($CredentialDirectory)) {
        throw "Central credential directory was not found."
    }
}

$LogContext = New-SqlMaintenanceLogContext `
    -LogDirectory $LogDirectory `
    -OperationName "Register-SqlMonitoringClient"
$LoadedCredentialPassword = $null

if ($null -eq $Credential) {
    $KeyPath = Join-Path $CredentialDirectory "$SqlLoginName.key"
    $CredentialPath =
        Join-Path $CredentialDirectory "$SqlLoginName.credential.xml"

    if (-not (Test-Path -LiteralPath $KeyPath -PathType Leaf)) {
        throw "SQL credential key not found: $KeyPath"
    }

    if (-not (Test-Path -LiteralPath $CredentialPath -PathType Leaf)) {
        throw "Encrypted SQL credential not found: $CredentialPath"
    }

    $AesKey = [System.IO.File]::ReadAllBytes($KeyPath)

    try {
        if ($AesKey.Length -notin 16, 24, 32) {
            throw "Invalid AES key length in [$KeyPath]."
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

        $LoadedCredentialPassword = ConvertTo-SecureString `
            -String $StoredCredential.EncryptedPassword `
            -Key $AesKey
        $Credential = [PSCredential]::new(
            [string]$StoredCredential.UserName,
            $LoadedCredentialPassword
        )
    }
    finally {
        [System.Array]::Clear($AesKey, 0, $AesKey.Length)
    }
}

if ($Credential.UserName -cne $SqlLoginName) {
    throw (
        "Credential user [$($Credential.UserName)] does not match " +
        "SqlLoginName [$SqlLoginName]."
    )
}

$SelectedSourceInstances = @(
    Select-SqlInstance -SourceInstance $SourceInstance
)
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
$MaximumConnectionTargetLength = if (
    $RepositoryPreflight.InsNameLength -eq -1
) {
    256
}
else {
    [Math]::Min($RepositoryPreflight.InsNameLength, 256)
}

$ReadOnlyPassword = $Credential.Password.Copy()
$ReadOnlyPassword.MakeReadOnly()
$SqlCredential = [System.Data.SqlClient.SqlCredential]::new(
    $Credential.UserName,
    $ReadOnlyPassword
)
$QualifiedTable = "[$RepositorySchema].[$RepositoryTable]"
$RegistrationResults = @()

try {
    foreach ($SelectedSourceInstance in $SelectedSourceInstances) {
        $ConnectionTarget = $SelectedSourceInstance.ConnectionTarget
        $ReportedInstanceName = $null

        try {
            if ($ConnectionTarget.Length -gt $MaximumConnectionTargetLength) {
                throw (
                    "Connection target length $($ConnectionTarget.Length) " +
                    "exceeds repository InsName length " +
                    "${MaximumConnectionTargetLength}: $ConnectionTarget"
                )
            }

            $ReportedInstanceName = Invoke-SqlWithRetry `
                -Step "ReadInstanceName" `
                -Instance $ConnectionTarget `
                -RetryCount $RetryCount `
                -RetryDelaySeconds $RetryDelaySeconds `
                -LogContext $LogContext `
                -Operation {
                    $Connection = New-SqlConnection `
                        -DataSource $ConnectionTarget `
                        -InitialCatalog "master" `
                        -SqlCredential $SqlCredential `
                        -ConnectionTimeoutSeconds $ConnectionTimeoutSeconds `
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

            if ([string]::IsNullOrWhiteSpace($ReportedInstanceName)) {
                throw "SQL Server returned an empty instance name."
            }

            $RegistrationStatus = Invoke-SqlWithRetry `
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
                        -ConnectionTimeoutSeconds $ConnectionTimeoutSeconds `
                        -ApplicationName "Register SQL Monitoring Client"

                    try {
                        $Connection.Open()
                        $Command = $Connection.CreateCommand()

                        try {
                            $Command.CommandTimeout = $CommandTimeoutSeconds
                            $Command.CommandText = @"
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF COL_LENGTH(N'$RepositorySchema.$RepositoryTable', N'ReportedInstanceName') IS NULL
    THROW 50001, 'ReportedInstanceName column is missing.', 1;

DECLARE @RegistrationStatus nvarchar(20);

BEGIN TRANSACTION;

IF EXISTS
(
    SELECT 1
    FROM $QualifiedTable WITH (UPDLOCK, HOLDLOCK)
    WHERE [InsName] = @ConnectionTarget
)
BEGIN
    UPDATE $QualifiedTable
    SET [ReportedInstanceName] = @ReportedInstanceName
    WHERE [InsName] = @ConnectionTarget;

    SET @RegistrationStatus = N'Updated';
END
ELSE
BEGIN
    INSERT INTO $QualifiedTable
    (
        [InsName],
        [ReportedInstanceName]
    )
    VALUES
    (
        @ConnectionTarget,
        @ReportedInstanceName
    );

    SET @RegistrationStatus = N'Inserted';
END;

COMMIT TRANSACTION;

SELECT @RegistrationStatus;
"@
                            [void]$Command.Parameters.Add(
                                "@ConnectionTarget",
                                [System.Data.SqlDbType]::NVarChar,
                                256
                            )
                            [void]$Command.Parameters.Add(
                                "@ReportedInstanceName",
                                [System.Data.SqlDbType]::NVarChar,
                                128
                            )
                            $Command.Parameters["@ConnectionTarget"].Value =
                                $ConnectionTarget
                            $Command.Parameters["@ReportedInstanceName"].Value =
                                $ReportedInstanceName
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

            Write-SqlMaintenanceLog `
                -LogContext $LogContext `
                -Level Info `
                -Step "RegisterClient" `
                -Instance $ConnectionTarget `
                -Message "${ReportedInstanceName}: $RegistrationStatus"

            $RegistrationResults += [pscustomobject]@{
                ConnectionTarget     = $ConnectionTarget
                ReportedInstanceName = $ReportedInstanceName
                Status               = $RegistrationStatus
                Detail               = "Success"
            }
        }
        catch {
            Write-SqlMaintenanceLog `
                -LogContext $LogContext `
                -Level Error `
                -Step "RegisterClient" `
                -Instance $ConnectionTarget `
                -Message $_.Exception.Message

            $RegistrationResults += [pscustomobject]@{
                ConnectionTarget     = $ConnectionTarget
                ReportedInstanceName = $ReportedInstanceName
                Status               = "Failed"
                Detail               = $_.Exception.Message
            }
        }
    }
}
finally {
    $ReadOnlyPassword.Dispose()

    if ($null -ne $LoadedCredentialPassword) {
        $LoadedCredentialPassword.Dispose()
    }
}

$FailedResults = @(
    $RegistrationResults | Where-Object Status -eq "Failed"
)

if ($FailedResults.Count -gt 0) {
    throw "One or more SQL Server Clients failed to register."
}

if ($RunCollectionTest) {
    if (-not $PSBoundParameters.ContainsKey("CollectorScriptPath")) {
        $CollectorScriptPath = @(
            (Join-Path $ServerRoot "GetDBInfo\_Get-DBInfo-Simple.ps1"),
            (Join-Path $SourceRoot "GetDBInfo\_Get-DBInfo-Simple.ps1")
        ) |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            Select-Object -First 1
    }

    if (
        [string]::IsNullOrWhiteSpace($CollectorScriptPath) -or
        -not (Test-Path -LiteralPath $CollectorScriptPath -PathType Leaf)
    ) {
        throw "GetDBInfo Collector script was not found."
    }

    $CollectionTestParameters = @{
        SourceInstance = @(
            $RegistrationResults | ForEach-Object ConnectionTarget
        )
    }

    if ($IncludeTopResourceUsage) {
        $CollectionTestParameters.IncludeTopResourceUsage = $true
    }

    Write-SqlMaintenanceLog `
        -LogContext $LogContext `
        -Level Info `
        -Step "CollectionTest" `
        -Instance $RepositoryInstance `
        -Message "Starting scoped GetDBInfo collection test."

    try {
        & $CollectorScriptPath @CollectionTestParameters

        Write-SqlMaintenanceLog `
            -LogContext $LogContext `
            -Level Info `
            -Step "CollectionTest" `
            -Instance $RepositoryInstance `
            -Message "Scoped GetDBInfo collection test completed."
    }
    catch {
        Write-SqlMaintenanceLog `
            -LogContext $LogContext `
            -Level Error `
            -Step "CollectionTest" `
            -Instance $RepositoryInstance `
            -Message $_.Exception.Message
        throw
    }
}

$RegistrationResults
