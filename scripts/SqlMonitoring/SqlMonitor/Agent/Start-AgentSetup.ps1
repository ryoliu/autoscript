<#
.SYNOPSIS
Runs SQL monitoring setup tasks assigned to an Agent host.

.DESCRIPTION
Uses a supplied in-memory service credential, or prompts once when it is not
supplied, to provision the monitoring Login on selected Client SQL Server
instances and register them in the central Repository. This script does not
read or create repository credential files.

.PARAMETER Action
Agent action to run. RunAll provisions the Login and then registers the selected
instances. Menu displays the interactive menu. The default is Menu.

.PARAMETER SourceInstance
Optional SQL Server connection targets. Supplying this parameter bypasses local
discovery and the interactive instance selection menu.

.PARAMETER SqlLoginName
Optional service SQL Login name that overrides SqlLoginName in agent.config.

.PARAMETER ServiceCredential
Optional service SQL Login credential. When omitted, the script prompts once
and reuses the credential for all selected Client instances.

.PARAMETER SqlAdminCredential
Optional fallback SQL administrator credential used when Windows authentication
cannot provision the service Login.

.EXAMPLE
.\Start-AgentSetup.ps1 -Action ProvisionLogin

Prompts once for the monitoring credential and provisions selected instances.

.EXAMPLE
$ServiceCredential = Get-Credential -UserName "dbmonitor"
.\Start-AgentSetup.ps1 `
    -Action RunAll `
    -SourceInstance "localhost","localhost\LAB2" `
    -ServiceCredential $ServiceCredential

Provisions and registers the supplied SQL Server instances without local
discovery.

.NOTES
Repository connection settings are read from agent.config. Repository key files
and credential XML files belong only on ServerRepository.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet("Menu", "ProvisionLogin", "RegisterClient", "RunAll")]
    [string]$Action = "Menu",

    [Parameter()]
    [string[]]$SourceInstance,

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$SqlLoginName,

    [Parameter()]
    [PSCredential]$ServiceCredential,

    [Parameter()]
    [PSCredential]$SqlAdminCredential,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath = (
        Join-Path $PSScriptRoot "Config\agent.config"
    ),

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

$PackagedModulePath = Join-Path `
    $PSScriptRoot `
    "Modules\SqlMaintenance.Common\SqlMaintenance.Common.psm1"
$SourceModulePath = Join-Path `
    (Split-Path -Parent $PSScriptRoot) `
    "Modules\SqlMaintenance.Common\SqlMaintenance.Common.psm1"
$CommonModulePath = if (
    Test-Path -LiteralPath $PackagedModulePath -PathType Leaf
) {
    $PackagedModulePath
}
else {
    $SourceModulePath
}
$PackagedProvisionLoginScript = Join-Path `
    $PSScriptRoot `
    "Scripts\New-SqlServiceLogin.ps1"
$SourceProvisionLoginScript = Join-Path `
    $PSScriptRoot `
    "New-SqlServiceLogin.ps1"
$ProvisionLoginScript = if (
    Test-Path -LiteralPath $PackagedProvisionLoginScript -PathType Leaf
) {
    $PackagedProvisionLoginScript
}
else {
    $SourceProvisionLoginScript
}
$PackagedRegisterClientScript = Join-Path `
    $PSScriptRoot `
    "Scripts\Register-SqlMonitoringClient.ps1"
$SourceRegisterClientScript = Join-Path `
    (Split-Path -Parent $PSScriptRoot) `
    "ServerRepository\Register-SqlMonitoringClient.ps1"
$RegisterClientScript = if (
    Test-Path -LiteralPath $PackagedRegisterClientScript -PathType Leaf
) {
    $PackagedRegisterClientScript
}
else {
    $SourceRegisterClientScript
}

foreach ($RequiredPath in @(
    $CommonModulePath,
    $ProvisionLoginScript,
    $RegisterClientScript
)) {
    if (-not (Test-Path -LiteralPath $RequiredPath -PathType Leaf)) {
        throw "Required file not found: $RequiredPath"
    }
}

Import-Module $CommonModulePath -Force

$AgentConfig = Get-SqlAgentConfig -LiteralPath $ConfigPath

if (-not $PSBoundParameters.ContainsKey("SqlLoginName")) {
    $SqlLoginName = $AgentConfig.SqlLoginName
}

$LogContext = New-SqlMaintenanceLogContext `
    -LogDirectory $LogDirectory `
    -OperationName "AgentSetup"
$SourceInstanceWasSpecified =
    $PSBoundParameters.ContainsKey("SourceInstance")
$script:SelectedSqlInstances = $null
$script:ServiceCredential = $ServiceCredential

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

function Get-AgentServiceCredential {
    [CmdletBinding()]
    param()

    if ($null -eq $script:ServiceCredential) {
        $script:ServiceCredential = Get-Credential `
            -UserName $SqlLoginName `
            -Message "Enter the monitoring SQL Login credential"
    }

    if ($null -eq $script:ServiceCredential) {
        throw "A monitoring SQL Login credential is required."
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
    $Credential = Get-AgentServiceCredential
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

function Invoke-AgentRegisterClient {
    [CmdletBinding()]
    param()

    $SelectedInstances = @(Get-AgentSqlInstanceSelection)
    $Credential = Get-AgentServiceCredential

    Write-Host (
        "Repository instance: $($AgentConfig.RepositoryInstance)"
    )
    Write-Host (
        "Repository database: $($AgentConfig.RepositoryDatabase)"
    )
    Write-Host (
        "Repository table: " +
        "[$($AgentConfig.RepositorySchema)]." +
        "[$($AgentConfig.RepositoryTable)]"
    )

    $Parameters = @{
        SourceInstance           = $SelectedInstances.ConnectionTarget
        ConfigPath               = $ConfigPath
        SqlLoginName             = $SqlLoginName
        Credential               = $Credential
        ConnectionTimeoutSeconds = $ConnectionTimeoutSeconds
        CommandTimeoutSeconds    = $CommandTimeoutSeconds
        RetryCount               = $RetryCount
        RetryDelaySeconds        = $RetryDelaySeconds
        LogDirectory             = $LogDirectory
    }

    [void](& $RegisterClientScript @Parameters)
}

function Invoke-AgentAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet("ProvisionLogin", "RegisterClient", "RunAll")]
        [string]$SelectedAction
    )

    if (
        @("RegisterClient", "RunAll") -contains $SelectedAction -and
        -not $AgentConfig.HasRepositoryConfiguration
    ) {
        throw (
            "RegisterClient requires RepositoryInstance, " +
            "RepositoryDatabase, RepositorySchema, and RepositoryTable " +
            "in agent configuration [$ConfigPath]."
        )
    }

    Write-SqlMaintenanceLog `
        -LogContext $LogContext `
        -Level Info `
        -Step $SelectedAction `
        -Message "Agent action started."

    switch ($SelectedAction) {
        "ProvisionLogin" {
            Invoke-AgentProvisionLogin
        }
        "RegisterClient" {
            Invoke-AgentRegisterClient
        }
        "RunAll" {
            Invoke-AgentProvisionLogin
            Invoke-AgentRegisterClient
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

if ($Action -ne "Menu") {
    Invoke-AgentAction -SelectedAction $Action
    return
}

while ($true) {
    Write-Host ""
    Write-Host "SQL Monitoring Agent Setup"
    Write-Host "=========================="
    Write-Host "1. Provision service Login on selected instances"
    Write-Host "2. Register selected instances in Repository"
    Write-Host "3. Run all Agent setup actions"
    Write-Host "Q. Exit"
    Write-Host ""

    $MenuSelection = (Read-Host "Select an action").Trim()

    if ($MenuSelection -match '^Q$') {
        break
    }

    $SelectedAction = switch ($MenuSelection) {
        "1" { "ProvisionLogin" }
        "2" { "RegisterClient" }
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
