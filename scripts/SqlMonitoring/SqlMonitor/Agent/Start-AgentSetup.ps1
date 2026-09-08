<#
.SYNOPSIS
Runs SQL monitoring setup tasks assigned to an Agent host.

.DESCRIPTION
Loads the matching AES key and encrypted credential XML that were generated on
ServerRepository and manually copied to this Agent. The credential is loaded
once and reused to provision the service Login and register selected SQL Server
instances in the central repository.

This script never creates credential files or initializes repository objects.

.PARAMETER Action
Agent action to run. Menu displays the interactive menu. The default is Menu.

.PARAMETER SourceInstance
Optional SQL Server connection targets. Supplying this parameter bypasses local
discovery and the interactive instance selection menu.

.PARAMETER SqlLoginName
Optional service SQL Login name that overrides SqlLoginName in repository.config.

.PARAMETER CredentialDirectory
Directory containing the matching AES key and encrypted credential XML copied
from ServerRepository.

.PARAMETER SqlAdminCredential
Optional fallback SQL administrator credential used when Windows authentication
cannot provision the service Login.

.EXAMPLE
.\Start-AgentSetup.ps1 -Action RunAll

Loads the copied credential once, provisions selected instances, and registers
them in the repository.

.EXAMPLE
.\Start-AgentSetup.ps1 `
    -Action RegisterInstances `
    -SourceInstance "localhost","localhost\LAB2"

Registers the supplied SQL Server instances without local discovery.

.NOTES
Create the AES key and encrypted credential XML only on ServerRepository. Copy
both files to this Agent as a matching pair and protect them for the Agent
runtime account before running this script.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet("Menu", "ProvisionLogin", "RegisterInstances", "RunAll")]
    [string]$Action = "Menu",

    [Parameter()]
    [string[]]$SourceInstance,

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$SqlLoginName,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$CredentialDirectory = (
        Join-Path `
            (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) `
            "Credentials"
    ),

    [Parameter()]
    [PSCredential]$SqlAdminCredential,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath = (
        Join-Path `
            (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) `
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
    [string]$LogDirectory = (Join-Path $PSScriptRoot "Logs")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$CommonModulePath = Join-Path `
    (Split-Path -Parent $PSScriptRoot) `
    "Modules\SqlMaintenance.Common\SqlMaintenance.Common.psm1"
$ProvisionLoginScript = Join-Path $PSScriptRoot "New-SqlServiceLogin.ps1"
$RegisterInstancesScript = Join-Path $PSScriptRoot "Sync-InstanceName.ps1"

foreach ($RequiredPath in @(
    $CommonModulePath,
    $ProvisionLoginScript,
    $RegisterInstancesScript
)) {
    if (-not (Test-Path -LiteralPath $RequiredPath -PathType Leaf)) {
        throw "Required file not found: $RequiredPath"
    }
}

Import-Module $CommonModulePath -Force

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

$LogContext = New-SqlMaintenanceLogContext `
    -LogDirectory $LogDirectory `
    -OperationName "AgentSetup"
$SourceInstanceWasSpecified =
    $PSBoundParameters.ContainsKey("SourceInstance")
$script:SelectedSqlInstances = $null
$script:ServiceCredential = $null
$script:LoadedCredentialPassword = $null

function Get-AgentSqlInstanceSelection {
    [CmdletBinding()]
    param()

    if ($null -ne $script:SelectedSqlInstances) {
        return $script:SelectedSqlInstances
    }

    $SelectionParameters = @{}

    if ($SourceInstanceWasSpecified) {
        $SelectionParameters.SourceInstance = $SourceInstance
    }

    $script:SelectedSqlInstances = @(
        Select-SqlInstance @SelectionParameters
    )

    Write-SqlMaintenanceLog `
        -LogContext $LogContext `
        -Level Info `
        -Step "SelectInstances" `
        -Message (
            "Selected Agent instances: " +
            ($script:SelectedSqlInstances.ConnectionTarget -join ", ")
        )

    return $script:SelectedSqlInstances
}

function Get-CopiedServiceCredential {
    [CmdletBinding()]
    param()

    if ($null -ne $script:ServiceCredential) {
        return $script:ServiceCredential
    }

    $KeyPath = Join-Path $CredentialDirectory "$SqlLoginName.key"
    $CredentialPath =
        Join-Path $CredentialDirectory "$SqlLoginName.credential.xml"

    if (-not (Test-Path -LiteralPath $KeyPath -PathType Leaf)) {
        throw (
            "SQL credential key not found: $KeyPath. Copy the matching key " +
            "and credential XML files from ServerRepository."
        )
    }

    if (-not (Test-Path -LiteralPath $CredentialPath -PathType Leaf)) {
        throw (
            "Encrypted SQL credential not found: $CredentialPath. Copy the " +
            "matching key and credential XML files from ServerRepository."
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

        $script:LoadedCredentialPassword =
            $StoredCredential.EncryptedPassword |
                ConvertTo-SecureString -Key $AesKey
        $script:ServiceCredential = [PSCredential]::new(
            [string]$StoredCredential.UserName,
            $script:LoadedCredentialPassword
        )
    }
    finally {
        [Array]::Clear($AesKey, 0, $AesKey.Length)
    }

    if ($script:ServiceCredential.UserName -cne $SqlLoginName) {
        throw (
            "Credential user [$($script:ServiceCredential.UserName)] does " +
            "not match SqlLoginName [$SqlLoginName]."
        )
    }

    return $script:ServiceCredential
}

function Invoke-AgentProvisionLogin {
    [CmdletBinding()]
    param()

    $SelectedInstances = @(Get-AgentSqlInstanceSelection)
    $Credential = Get-CopiedServiceCredential
    $Parameters = @{
        SourceInstance           = $SelectedInstances.ConnectionTarget
        ConfigPath               = $ConfigPath
        ServiceLoginName         = $SqlLoginName
        ServiceCredential        = $Credential
        ConnectionTimeoutSeconds = $ConnectionTimeoutSeconds
        CommandTimeoutSeconds    = $CommandTimeoutSeconds
        RetryCount               = $RetryCount
        RetryDelaySeconds        = $RetryDelaySeconds
        LogDirectory             = $LogDirectory
        LogContext               = $LogContext
    }

    if ($null -ne $SqlAdminCredential) {
        $Parameters.SqlAdminCredential = $SqlAdminCredential
    }

    [void](& $ProvisionLoginScript @Parameters)
}

function Invoke-AgentRegisterInstances {
    [CmdletBinding()]
    param()

    $SelectedInstances = @(Get-AgentSqlInstanceSelection)
    $Credential = Get-CopiedServiceCredential
    $Parameters = @{
        SourceInstance           = $SelectedInstances.ConnectionTarget
        ConfigPath               = $ConfigPath
        RepositoryInstance       = $RepositoryInstance
        RepositoryDatabase       = $RepositoryDatabase
        RepositorySchema         = $RepositorySchema
        RepositoryTable          = $RepositoryTable
        SqlLoginName             = $SqlLoginName
        Credential               = $Credential
        ConnectionTimeoutSeconds = $ConnectionTimeoutSeconds
        CommandTimeoutSeconds    = $CommandTimeoutSeconds
        RetryCount               = $RetryCount
        RetryDelaySeconds        = $RetryDelaySeconds
        LogDirectory             = $LogDirectory
        LogContext               = $LogContext
    }

    [void](& $RegisterInstancesScript @Parameters)
}

function Invoke-AgentAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet("ProvisionLogin", "RegisterInstances", "RunAll")]
        [string]$SelectedAction
    )

    Write-SqlMaintenanceLog `
        -LogContext $LogContext `
        -Level Info `
        -Step $SelectedAction `
        -Message "Agent action started."

    switch ($SelectedAction) {
        "ProvisionLogin" {
            Invoke-AgentProvisionLogin
        }
        "RegisterInstances" {
            Invoke-AgentRegisterInstances
        }
        "RunAll" {
            Invoke-AgentProvisionLogin
            Invoke-AgentRegisterInstances
        }
    }

    Write-SqlMaintenanceLog `
        -LogContext $LogContext `
        -Level Info `
        -Step $SelectedAction `
        -Message "Agent action completed."
}

Write-Host "Execution log: $($LogContext.TextLogPath)"
Write-Host "JSON log:      $($LogContext.JsonLogPath)"

try {
    if ($Action -ne "Menu") {
        Invoke-AgentAction -SelectedAction $Action
        return
    }

    while ($true) {
        Write-Host ""
        Write-Host "SQL Monitoring Agent Setup"
        Write-Host "=========================="
        Write-Host "1. Provision service Login on selected instances"
        Write-Host "2. Register selected instances in ServerRepository"
        Write-Host "3. Run Agent steps 1-2 in order"
        Write-Host "Q. Exit"
        Write-Host ""

        $MenuSelection = (Read-Host "Select an action").Trim()

        if ($MenuSelection -match '^Q$') {
            break
        }

        $SelectedAction = switch ($MenuSelection) {
            "1" { "ProvisionLogin" }
            "2" { "RegisterInstances" }
            "3" { "RunAll" }
            default { $null }
        }

        if ($null -eq $SelectedAction) {
            Write-Warning "Invalid selection. Please try again."
            continue
        }

        try {
            Invoke-AgentAction -SelectedAction $SelectedAction
            Write-Host ""
            Write-Host "Action completed."
        }
        catch {
            Write-SqlMaintenanceLog `
                -LogContext $LogContext `
                -Level Error `
                -Step $SelectedAction `
                -Message $_.Exception.Message
        }

        [void](Read-Host "Press Enter to return to the menu")
    }
}
finally {
    if ($null -ne $script:LoadedCredentialPassword) {
        $script:LoadedCredentialPassword.Dispose()
    }
}
