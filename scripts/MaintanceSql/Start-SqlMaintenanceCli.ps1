<#
.SYNOPSIS
Provides an interactive CLI for SQL Agent Login provisioning and instance
registration.

.DESCRIPTION
The CLI owns one SQL Server instance selection for the entire session. Run All
performs a repository preflight before any mutation, provisions and validates the
srv.mn Login on the same selected instances, writes the encrypted credential only
after all Login validations succeed, and then registers those same instances.

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
E:\Scripts.

.PARAMETER RepositoryInstance
SQL Server instance containing the monitoring repository. The default is
WIN2019LAB.

.PARAMETER RepositoryDatabase
Monitoring repository database. The default is Monitor.

.PARAMETER RepositorySchema
Schema owning the instance table. The default is dbo.

.PARAMETER RepositoryTable
Table storing SQL Server instance names. The default is InsList.

.EXAMPLE
.\Start-SqlMaintenanceCli.ps1

Displays the interactive SQL maintenance menu.

.EXAMPLE
.\Start-SqlMaintenanceCli.ps1 `
    -Action RunAll `
    -SourceInstance "localhost","localhost\LAB2"

Runs the complete workflow for the supplied instances without displaying an
instance selection menu.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet(
        "Menu",
        "ProvisionLogin",
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
    [string]$CredentialDirectory = "E:\Scripts",

    [Parameter()]
    [Alias("Ins")]
    [ValidateNotNullOrEmpty()]
    [string]$RepositoryInstance = "WIN2019LAB",

    [Parameter()]
    [ValidatePattern('^[A-Za-z_][A-Za-z0-9_@$#]*$')]
    [string]$RepositoryDatabase = "Monitor",

    [Parameter()]
    [ValidatePattern('^[A-Za-z_][A-Za-z0-9_@$#]*$')]
    [string]$RepositorySchema = "dbo",

    [Parameter()]
    [ValidatePattern('^[A-Za-z_][A-Za-z0-9_@$#]*$')]
    [string]$RepositoryTable = "InsList",

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

$CommonModulePath = Join-Path $PSScriptRoot "SqlMaintenance.Common.psm1"
$ProvisionLoginScript =
    Join-Path $PSScriptRoot "New-SqlServiceLogin.ps1"
$CreateCredentialScript =
    Join-Path $PSScriptRoot "New-SqlCredentialKey.ps1"
$RegisterInstancesScript =
    Join-Path $PSScriptRoot "getInstanceName.ps1"

if (-not (Test-Path -LiteralPath $CommonModulePath -PathType Leaf)) {
    throw "Required module not found: $CommonModulePath"
}

Import-Module $CommonModulePath -Force

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

function Invoke-RepositoryPreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCredential]$Credential
    )

    Write-Host ""
    Write-Host "Preflight - Validate Monitor repository"
    [void](
        Test-SqlMonitorRepository `
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
    )
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
    [void](
        & $ProvisionLoginScript `
            -SourceInstance $SelectedInstances.ConnectionTarget `
            -ServiceLoginName $SqlLoginName `
            -ServiceCredential $ServiceCredential `
            -ConnectionTimeoutSeconds $ConnectionTimeoutSeconds `
            -CommandTimeoutSeconds $CommandTimeoutSeconds `
            -RetryCount $RetryCount `
            -RetryDelaySeconds $RetryDelaySeconds `
            -LogDirectory $LogDirectory `
            -LogContext $LogContext
    )
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
    Write-Host "Step 2 - Create encrypted SQL credential"

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
    Write-Host "Step 3 - Register SQL Server instances"
    [void](
        & $RegisterInstancesScript `
            -SourceInstance $SelectedInstances.ConnectionTarget `
            -SqlLoginName $SqlLoginName `
            -CredentialDirectory $CredentialDirectory `
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

    # Repository readiness is checked before Login or credential mutation.
    Invoke-RepositoryPreflight -Credential $Credential
    Invoke-ProvisionLogin `
        -SelectedInstances $SelectedInstances `
        -ServiceCredential $Credential
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
    Write-Host "2. Create or replace encrypted $SqlLoginName credential"
    Write-Host "3. Select and register SQL Server instances"
    Write-Host "4. Run steps 1-3 in order"
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
        "2" { "CreateCredential" }
        "3" { "RegisterInstances" }
        "4" { "RunAll" }
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
