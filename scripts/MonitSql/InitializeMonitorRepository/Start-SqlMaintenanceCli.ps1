<#
.SYNOPSIS
Provides an interactive CLI for SQL Agent Login provisioning and instance
registration.

.DESCRIPTION
The CLI owns one SQL Server instance selection for the entire session. Run All
provisions and validates the srv.mn Login, initializes and validates the
repository, writes the encrypted credential, and then registers the selected
instances.

Every action writes human-readable and JSON Lines logs. SQL connection and
command timeouts and transient retry settings are passed consistently to all
supporting scripts.

.PARAMETER Action
Action to run. Menu displays the interactive CLI. The default is Menu.

.PARAMETER SourceInstance
Optional SQL Server connection targets. Supplying this parameter bypasses local
discovery and the interactive instance menu.

.PARAMETER SqlLoginName
Service SQL Login name. The default is srv.mn.

.PARAMETER CredentialDirectory
Directory containing the AES key and encrypted credential file. The default is
the shared Credentials directory.

.PARAMETER SqlAdminCredential
Optional fallback SQL administrator credential used when Windows authentication
cannot provision a Login or initialize the repository.

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

.EXAMPLE
.\Start-SqlMaintenanceCli.ps1

Displays the interactive SQL maintenance menu.

.EXAMPLE
.\Start-SqlMaintenanceCli.ps1 `
    -Action RunAll `
    -SourceInstance "localhost","localhost\LAB2"

Runs the complete workflow for the supplied instances without displaying an
instance selection menu.

.EXAMPLE
.\Start-SqlMaintenanceCli.ps1 -Action InitializeRepository

Creates missing repository objects, maps srv.mn, adds it to db_owner, and
validates the repository.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet(
        "Menu",
        "ProvisionLogin",
        "InitializeRepository",
        "CreateCredential",
        "RegisterInstances",
        "RunAll"
    )]
    [string]$Action = "Menu",

    [Parameter()]
    [string[]]$SourceInstance,

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
    [PSCredential]$SqlAdminCredential,

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
$ProvisionLoginScript =
    Join-Path $PSScriptRoot "New-SqlServiceLogin.ps1"
$CreateCredentialScript =
    Join-Path $PSScriptRoot "New-SqlCredentialKey.ps1"
$InitializeRepositoryScript =
    Join-Path $PSScriptRoot "Initialize-SqlMonitorRepository.ps1"
$RegisterInstancesScript =
    Join-Path $PSScriptRoot "getInstanceName.ps1"

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

$LogContext = New-SqlMaintenanceLogContext `
    -LogDirectory $LogDirectory `
    -OperationName "SqlMaintenanceCli"
$SourceInstanceWasSpecified =
    $PSBoundParameters.ContainsKey("SourceInstance")
$script:SelectedSqlInstances = $null
$script:ServiceCredential = $null

function Assert-SupportingScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath
    )

    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
        throw "Required script not found: $LiteralPath"
    }
}

function Get-SessionSqlInstanceSelection {
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
            "Selected instances: " +
            ($script:SelectedSqlInstances.ConnectionTarget -join ", ")
        )

    return $script:SelectedSqlInstances
}

function Get-SessionServiceCredential {
    [CmdletBinding()]
    param()

    if ($null -ne $script:ServiceCredential) {
        return $script:ServiceCredential
    }

    $script:ServiceCredential = Get-Credential `
        -UserName $SqlLoginName `
        -Message "Enter the service SQL Login credential"

    if ($null -eq $script:ServiceCredential) {
        throw "A service SQL Login credential is required."
    }

    if ($script:ServiceCredential.UserName -cne $SqlLoginName) {
        throw (
            "Credential user [$($script:ServiceCredential.UserName)] does " +
            "not match SqlLoginName [$SqlLoginName]."
        )
    }

    return $script:ServiceCredential
}

function Invoke-ProvisionLogin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$SelectedInstances,

        [Parameter(Mandatory)]
        [PSCredential]$ServiceCredential
    )

    Assert-SupportingScript -LiteralPath $ProvisionLoginScript
    Write-Host ""
    Write-Host "Step 1 - Provision and validate SQL Login [$SqlLoginName]"
    $ProvisioningTargets = @(
        @($SelectedInstances.ConnectionTarget) + @($RepositoryInstance) |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            } |
            Select-Object -Unique
    )
    $ProvisioningParameters = @{
        SourceInstance           = $ProvisioningTargets
        ServiceLoginName         = $SqlLoginName
        ServiceCredential        = $ServiceCredential
        ConnectionTimeoutSeconds = $ConnectionTimeoutSeconds
        CommandTimeoutSeconds    = $CommandTimeoutSeconds
        RetryCount               = $RetryCount
        RetryDelaySeconds        = $RetryDelaySeconds
        LogDirectory             = $LogDirectory
        LogContext               = $LogContext
    }

    if ($null -ne $SqlAdminCredential) {
        $ProvisioningParameters.SqlAdminCredential =
            $SqlAdminCredential
    }

    [void](& $ProvisionLoginScript @ProvisioningParameters)
}

function Invoke-InitializeRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCredential]$ServiceCredential
    )

    Assert-SupportingScript -LiteralPath $InitializeRepositoryScript
    Write-Host ""
    Write-Host (
        "Step 2 - Initialize and validate repository " +
        "[$RepositoryDatabase]"
    )
    $InitializationParameters = @{
        ConfigPath               = $ConfigPath
        RepositoryInstance       = $RepositoryInstance
        RepositoryDatabase       = $RepositoryDatabase
        RepositorySchema         = $RepositorySchema
        RepositoryTable          = $RepositoryTable
        SqlLoginName             = $SqlLoginName
        ServiceCredential        = $ServiceCredential
        ConnectionTimeoutSeconds = $ConnectionTimeoutSeconds
        CommandTimeoutSeconds    = $CommandTimeoutSeconds
        RetryCount               = $RetryCount
        RetryDelaySeconds        = $RetryDelaySeconds
        LogDirectory             = $LogDirectory
        LogContext               = $LogContext
    }

    if ($null -ne $SqlAdminCredential) {
        $InitializationParameters.SqlAdminCredential =
            $SqlAdminCredential
    }

    [void](& $InitializeRepositoryScript @InitializationParameters)
}

function Invoke-CreateCredential {
    [CmdletBinding()]
    param(
        [Parameter()]
        [PSCredential]$Credential,

        [Parameter()]
        [switch]$RequireCompletion
    )

    Assert-SupportingScript -LiteralPath $CreateCredentialScript
    Write-Host ""
    Write-Host "Step 3 - Create encrypted SQL credential"

    $KeyPath = Join-Path $CredentialDirectory "$SqlLoginName.key"
    $CredentialPath =
        Join-Path $CredentialDirectory "$SqlLoginName.credential.xml"
    $CredentialFilesExist =
        (Test-Path -LiteralPath $KeyPath -PathType Leaf) -or
        (Test-Path -LiteralPath $CredentialPath -PathType Leaf)
    $CredentialParameters = @{
        SqlLoginName        = $SqlLoginName
        CredentialDirectory = $CredentialDirectory
        Confirm             = $false
        LogDirectory        = $LogDirectory
        LogContext          = $LogContext
    }

    if ($null -ne $Credential) {
        $CredentialParameters.Credential = $Credential
    }

    if ($CredentialFilesExist) {
        $ReplaceCredential = (
            Read-Host "Credential files exist. Replace them? (Y/N)"
        ).Trim()

        if ($ReplaceCredential -notmatch '^Y(?:ES)?$') {
            if ($RequireCompletion) {
                throw (
                    "Run All requires the validated credential to be stored. " +
                    "Credential replacement was declined."
                )
            }

            Write-Host "Credential creation skipped."
            return
        }

        $CredentialParameters.Force = $true
    }

    & $CreateCredentialScript @CredentialParameters
}

function Invoke-RegisterInstances {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$SelectedInstances
    )

    Assert-SupportingScript -LiteralPath $RegisterInstancesScript
    Write-Host ""
    Write-Host "Step 4 - Register SQL Server instances"
    [void](
        & $RegisterInstancesScript `
            -SourceInstance $SelectedInstances.ConnectionTarget `
            -SqlLoginName $SqlLoginName `
            -CredentialDirectory $CredentialDirectory `
            -ConfigPath $ConfigPath `
            -RepositoryInstance $RepositoryInstance `
            -RepositoryDatabase $RepositoryDatabase `
            -RepositorySchema $RepositorySchema `
            -RepositoryTable $RepositoryTable `
            -ConnectionTimeoutSeconds $ConnectionTimeoutSeconds `
            -CommandTimeoutSeconds $CommandTimeoutSeconds `
            -RetryCount $RetryCount `
            -RetryDelaySeconds $RetryDelaySeconds `
            -LogDirectory $LogDirectory `
            -LogContext $LogContext
    )
}

function Invoke-AllSqlMaintenanceSteps {
    [CmdletBinding()]
    param()

    $SelectedInstances = @(Get-SessionSqlInstanceSelection)
    $Credential = Get-SessionServiceCredential

    Invoke-ProvisionLogin `
        -SelectedInstances $SelectedInstances `
        -ServiceCredential $Credential
    Invoke-InitializeRepository -ServiceCredential $Credential
    Invoke-CreateCredential `
        -Credential $Credential `
        -RequireCompletion
    Invoke-RegisterInstances -SelectedInstances $SelectedInstances
}

function Invoke-SqlMaintenanceAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet(
            "ProvisionLogin",
            "InitializeRepository",
            "CreateCredential",
            "RegisterInstances",
            "RunAll"
        )]
        [string]$SelectedAction
    )

    Write-SqlMaintenanceLog `
        -LogContext $LogContext `
        -Level Info `
        -Step $SelectedAction `
        -Message "Action started."

    switch ($SelectedAction) {
        "ProvisionLogin" {
            $SelectedInstances = @(Get-SessionSqlInstanceSelection)
            $Credential = Get-SessionServiceCredential
            Invoke-ProvisionLogin `
                -SelectedInstances $SelectedInstances `
                -ServiceCredential $Credential
        }
        "InitializeRepository" {
            $Credential = Get-SessionServiceCredential
            Invoke-InitializeRepository -ServiceCredential $Credential
        }
        "CreateCredential" {
            Invoke-CreateCredential
        }
        "RegisterInstances" {
            $SelectedInstances = @(Get-SessionSqlInstanceSelection)
            Invoke-RegisterInstances `
                -SelectedInstances $SelectedInstances
        }
        "RunAll" {
            Invoke-AllSqlMaintenanceSteps
        }
    }

    Write-SqlMaintenanceLog `
        -LogContext $LogContext `
        -Level Info `
        -Step $SelectedAction `
        -Message "Action completed."
}

Write-Host "Execution log: $($LogContext.TextLogPath)"
Write-Host "JSON log:      $($LogContext.JsonLogPath)"

if ($Action -ne "Menu") {
    try {
        Invoke-SqlMaintenanceAction -SelectedAction $Action
    }
    catch {
        Write-SqlMaintenanceLog `
            -LogContext $LogContext `
            -Level Error `
            -Step $Action `
            -Message $_.Exception.Message
        throw
    }

    return
}

while ($true) {
    Write-Host ""
    Write-Host "SQL Maintenance CLI"
    Write-Host "==================="
    Write-Host "1. Create $SqlLoginName SQL Login and permissions"
    Write-Host "2. Initialize repository database and table"
    Write-Host "3. Create or replace encrypted $SqlLoginName credential"
    Write-Host "4. Select and register SQL Server instances"
    Write-Host "5. Run steps 1-4 in order"
    Write-Host "Q. Exit"
    Write-Host ""

    $MenuSelection = (Read-Host "Select an action").Trim()

    if ($MenuSelection -match '^Q$') {
        Write-SqlMaintenanceLog `
            -LogContext $LogContext `
            -Level Info `
            -Step "CliSession" `
            -Message "CLI session ended."
        break
    }

    $SelectedAction = switch ($MenuSelection) {
        "1" { "ProvisionLogin" }
        "2" { "InitializeRepository" }
        "3" { "CreateCredential" }
        "4" { "RegisterInstances" }
        "5" { "RunAll" }
        default { $null }
    }

    if ($null -eq $SelectedAction) {
        Write-Warning "Invalid selection. Please try again."
        continue
    }

    try {
        Invoke-SqlMaintenanceAction -SelectedAction $SelectedAction
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
