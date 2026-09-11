<#
.SYNOPSIS
Registers SQL Server Client connection targets in the central repository.

.DESCRIPTION
Runs from a Client Agent deployment package. The script uses an in-memory SQL
credential to verify each Client connection, reads the SQL Server reported
instance name, reads the Repository target from agent.config, and inserts or
updates the central repository instance list.

The Client package does not store the central AES key, credential XML, or
GetDBInfo Collector scripts.

InsName stores the SQL Server name returned by SERVERPROPERTY. SourceInstance
is used only to connect during registration and is not stored in the Repository.

.PARAMETER SourceInstance
Optional Client SQL Server connection targets, such as CLIENT01,
CLIENT01\INSTANCE01, or CLIENT01,14330. When omitted, the script displays local
SQL Server instances and prompts for the instances to register.

.PARAMETER RepositoryInstance
Optional central SQL monitoring Repository instance that overrides
RepositoryInstance in agent.config.

.PARAMETER RepositoryDatabase
Optional central SQL monitoring Repository database that overrides
RepositoryDatabase in agent.config.

.PARAMETER RepositorySchema
Optional schema containing the Repository instance list that overrides
RepositorySchema in agent.config.

.PARAMETER RepositoryTable
Optional Repository instance list table that overrides RepositoryTable in
agent.config.

.PARAMETER ConfigPath
Optional path to agent.config. When omitted, the script locates agent.config
in the Client Agent package.

.PARAMETER Credential
Optional monitoring SQL credential. When omitted, the script prompts once and
uses the credential only in memory.

.EXAMPLE
$Credential = Get-Credential -UserName "dbmonitor"
.\Register-SqlMonitoringClient.ps1 `
    -Credential $Credential
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$SourceInstance,

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
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath,

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$SqlLoginName,

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
    [string]$LogDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ModuleRootCandidates = @(
    (Split-Path -Parent $PSScriptRoot),
    (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
)
$PackageRoot = $ModuleRootCandidates |
    Where-Object {
        Test-Path `
            -LiteralPath (
                Join-Path `
                    $_ `
                    "Modules\SqlMaintenance.Common\SqlMaintenance.Common.psm1"
            ) `
            -PathType Leaf
    } |
    Select-Object -First 1

if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
    throw "Required SqlMaintenance.Common module was not found."
}

$CommonModulePath = Join-Path `
    $PackageRoot `
    "Modules\SqlMaintenance.Common\SqlMaintenance.Common.psm1"

if (-not (Test-Path -LiteralPath $CommonModulePath -PathType Leaf)) {
    throw "Required module not found: $CommonModulePath"
}

Import-Module $CommonModulePath -Force

if (-not $PSBoundParameters.ContainsKey("LogDirectory")) {
    $LogDirectory = Join-Path $PackageRoot "Logs"
}

if (-not $PSBoundParameters.ContainsKey("ConfigPath")) {
    $ConfigPath = @(
        (Join-Path $PackageRoot "Config\agent.config"),
        (Join-Path $PackageRoot "Agent\Config\agent.config")
    )
    $ConfigPath = $ConfigPath |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1
}

if (
    [string]::IsNullOrWhiteSpace($ConfigPath) -or
    -not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)
) {
    throw "Agent configuration file was not found: $ConfigPath"
}

$AgentConfig = Get-SqlAgentConfig -LiteralPath $ConfigPath

if (-not $PSBoundParameters.ContainsKey("SqlLoginName")) {
    $SqlLoginName = $AgentConfig.SqlLoginName
}

if (-not $PSBoundParameters.ContainsKey("RepositoryInstance")) {
    $RepositoryInstance = $AgentConfig.RepositoryInstance
}

if (-not $PSBoundParameters.ContainsKey("RepositoryDatabase")) {
    $RepositoryDatabase = $AgentConfig.RepositoryDatabase
}

if (-not $PSBoundParameters.ContainsKey("RepositorySchema")) {
    $RepositorySchema = $AgentConfig.RepositorySchema
}

if (-not $PSBoundParameters.ContainsKey("RepositoryTable")) {
    $RepositoryTable = $AgentConfig.RepositoryTable
}

$RequiredRepositorySettings = [ordered]@{
    RepositoryInstance = $RepositoryInstance
    RepositoryDatabase = $RepositoryDatabase
    RepositorySchema   = $RepositorySchema
    RepositoryTable    = $RepositoryTable
}

foreach ($RepositorySetting in $RequiredRepositorySettings.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace([string]$RepositorySetting.Value)) {
        throw (
            "Repository setting [$($RepositorySetting.Key)] was not " +
            "provided and is missing from agent configuration [$ConfigPath]."
        )
    }
}

$LogContext = New-SqlMaintenanceLogContext `
    -LogDirectory $LogDirectory `
    -OperationName "Register-SqlMonitoringClient"

$SelectionParameters = @{}

if ($PSBoundParameters.ContainsKey("SourceInstance")) {
    $SelectionParameters.SourceInstance = $SourceInstance
}

$SelectedSourceInstances = @(
    Select-SqlInstance @SelectionParameters
)

if ($null -eq $Credential) {
    $Credential = Get-Credential `
        -UserName $SqlLoginName `
        -Message "Enter the monitoring SQL credential"
}

if ($null -eq $Credential) {
    throw "A monitoring SQL credential is required."
}

if ($Credential.UserName -cne $SqlLoginName) {
    throw (
        "Credential user [$($Credential.UserName)] does not match " +
        "SqlLoginName [$SqlLoginName]."
    )
}

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
$MaximumInsNameLength = if (
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
        $CanonicalInstanceName = $null

        try {
            $CanonicalInstanceName = Invoke-SqlWithRetry `
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

            if ([string]::IsNullOrWhiteSpace($CanonicalInstanceName)) {
                throw "SQL Server returned an empty instance name."
            }

            $CanonicalInstanceName = $CanonicalInstanceName.Trim()

            if ($CanonicalInstanceName.Length -gt $MaximumInsNameLength) {
                throw (
                    "SQL Server instance name length " +
                    "$($CanonicalInstanceName.Length) exceeds repository " +
                    "InsName length ${MaximumInsNameLength}: " +
                    $CanonicalInstanceName
                )
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

DECLARE @RegistrationStatus nvarchar(20);

BEGIN TRANSACTION;

IF EXISTS
(
    SELECT 1
    FROM $QualifiedTable WITH (UPDLOCK, HOLDLOCK)
    WHERE [InsName] = @InsName
)
BEGIN
    SET @RegistrationStatus = N'AlreadyExists';
END
ELSE
BEGIN
    INSERT INTO $QualifiedTable
    (
        [InsName]
    )
    VALUES
    (
        @InsName
    );

    SET @RegistrationStatus = N'Inserted';
END;

COMMIT TRANSACTION;

SELECT @RegistrationStatus;
"@
                            [void]$Command.Parameters.Add(
                                "@InsName",
                                [System.Data.SqlDbType]::NVarChar,
                                256
                            )
                            $Command.Parameters["@InsName"].Value =
                                $CanonicalInstanceName
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
                -Message "${CanonicalInstanceName}: $RegistrationStatus"

            $RegistrationResults += [pscustomobject]@{
                ConnectionTarget = $ConnectionTarget
                InsName          = $CanonicalInstanceName
                Status           = $RegistrationStatus
                Detail           = "Success"
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
                ConnectionTarget = $ConnectionTarget
                InsName          = $CanonicalInstanceName
                Status           = "Failed"
                Detail           = $_.Exception.Message
            }
        }
    }
}
finally {
    $ReadOnlyPassword.Dispose()
}

$FailedResults = @(
    $RegistrationResults | Where-Object Status -eq "Failed"
)

if ($FailedResults.Count -gt 0) {
    throw "One or more SQL Server Clients failed to register."
}

$RegistrationResults
