<#
.SYNOPSIS
Runs setup tasks assigned to the SQL monitoring ServerRepository host.

.DESCRIPTION
Provisions the repository service Login on the repository instance,
initializes repository objects and the Collector Job, and creates the AES key
and encrypted credential XML used only by ServerRepository.

.PARAMETER Action
ServerRepository action to run. Menu displays the interactive menu. The default
is Menu.

.PARAMETER SqlLoginName
Optional service SQL Login name that overrides SqlLoginName in repository.config.

.PARAMETER ServiceCredential
Optional service SQL Login credential. When omitted, the script prompts once and
reuses the credential for the selected workflow.

.PARAMETER SqlAdminCredential
Optional fallback SQL administrator credential used when Windows authentication
cannot provision the Login or initialize the repository.

.PARAMETER ForceCredential
Replaces the existing matching key and credential XML pair.

.PARAMETER CredentialAccessAccount
Windows accounts that receive read access to the generated credential files.
The default is NT SERVICE\SQLSERVERAGENT. Specify the actual service account
when SQL Server Agent uses a different identity.

.PARAMETER CollectorScriptPath
Absolute path to the GetDBInfo controller script used by the SQL Agent Job.

.PARAMETER EnableCollectorJob
Enables the Collector Job. New Jobs are disabled unless this switch is used.

.PARAMETER DisableCollectorJob
Disables an existing Collector Job.

.PARAMETER IncludeTopResourceUsage
Runs the optional top resource usage Collector from the SQL Agent Job.

.PARAMETER MonitorRepositoryInstance
Also grants Client monitoring permissions on the Repository SQL Server itself.
Use this only when the Repository instance is registered for collection.

.EXAMPLE
.\Start-ServerRepositorySetup.ps1 -Action RunAll

Provisions the repository Login, initializes repository objects, and creates the
credential files on ServerRepository.

.EXAMPLE
.\Start-ServerRepositorySetup.ps1 `
    -Action CreateCredential `
    -ForceCredential

Replaces the matching AES key and encrypted credential XML pair.

.NOTES
Do not run the credential generation step on Client Agent hosts. Keep both
credential files on ServerRepository and restrict access to the SQL Agent
runtime account and required administrators.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet(
        "Menu",
        "ProvisionLogin",
        "InitializeRepository",
        "CreateCredential",
        "RunAll"
    )]
    [string]$Action = "Menu",

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$SqlLoginName,

    [Parameter()]
    [PSCredential]$ServiceCredential,

    [Parameter()]
    [PSCredential]$SqlAdminCredential,

    [Parameter()]
    [switch]$ForceCredential,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$CredentialAccessAccount = @(
        "NT SERVICE\SQLSERVERAGENT"
    ),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$CollectorScriptPath,

    [Parameter()]
    [switch]$EnableCollectorJob,

    [Parameter()]
    [switch]$DisableCollectorJob,

    [Parameter()]
    [switch]$IncludeTopResourceUsage,

    [Parameter()]
    [switch]$MonitorRepositoryInstance,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$CredentialDirectory,

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

$CommonModulePath = Join-Path `
    (Split-Path -Parent $PSScriptRoot) `
    "Modules\SqlMaintenance.Common\SqlMaintenance.Common.psm1"
$PackagedProvisionLoginScript = Join-Path `
    $PSScriptRoot `
    "New-SqlServiceLogin.ps1"
$SourceProvisionLoginScript = Join-Path `
    (Split-Path -Parent $PSScriptRoot) `
    "Agent\New-SqlServiceLogin.ps1"
$ProvisionLoginScript = if (
    Test-Path -LiteralPath $PackagedProvisionLoginScript -PathType Leaf
) {
    $PackagedProvisionLoginScript
}
else {
    $SourceProvisionLoginScript
}
$InitializeRepositoryScript =
    Join-Path $PSScriptRoot "Initialize-SqlMonitorRepository.ps1"
$CreateCredentialScript = Join-Path $PSScriptRoot "New-SqlCredentialKey.ps1"

foreach ($RequiredPath in @(
    $CommonModulePath,
    $ProvisionLoginScript,
    $InitializeRepositoryScript,
    $CreateCredentialScript
)) {
    if (-not (Test-Path -LiteralPath $RequiredPath -PathType Leaf)) {
        throw "Required file not found: $RequiredPath"
    }
}

Import-Module $CommonModulePath -Force

$ServerRoot = Split-Path -Parent $PSScriptRoot
$SourceRoot = Split-Path -Parent $ServerRoot

if (-not $PSBoundParameters.ContainsKey("ConfigPath")) {
    $ConfigPath = @(
        (Join-Path $ServerRoot "Config\repository.config"),
        (Join-Path $SourceRoot "Config\repository.config")
    ) |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        throw "Repository configuration file was not found."
    }
}

if (-not $PSBoundParameters.ContainsKey("CredentialDirectory")) {
    $CredentialDirectory = @(
        (Join-Path $ServerRoot "Credentials"),
        (Join-Path $SourceRoot "Credentials")
    ) |
        Where-Object { Test-Path -LiteralPath $_ -PathType Container } |
        Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace($CredentialDirectory)) {
        $CredentialDirectory = Join-Path $ServerRoot "Credentials"
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

$LogContext = New-SqlMaintenanceLogContext `
    -LogDirectory $LogDirectory `
    -OperationName "ServerRepositorySetup"
$script:ServiceCredential = $ServiceCredential

function Get-ServerRepositoryServiceCredential {
    [CmdletBinding()]
    param()

    if ($null -eq $script:ServiceCredential) {
        $script:ServiceCredential = Get-Credential `
            -UserName $SqlLoginName `
            -Message "Enter the service SQL Login credential"
    }

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

function Assert-CredentialFilesCanBeCreated {
    [CmdletBinding()]
    param()

    if ($ForceCredential) {
        return
    }

    $KeyPath = Join-Path $CredentialDirectory "$SqlLoginName.key"
    $CredentialPath =
        Join-Path $CredentialDirectory "$SqlLoginName.credential.xml"
    $ExistingFiles = @(
        @($KeyPath, $CredentialPath) |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
    )

    if ($ExistingFiles.Count -gt 0) {
        throw (
            "Credential files already exist. Use -ForceCredential to replace " +
            "the matching pair: " + ($ExistingFiles -join ", ")
        )
    }
}

function Invoke-ServerRepositoryProvisionLogin {
    [CmdletBinding()]
    param()

    $Credential = Get-ServerRepositoryServiceCredential
    $PermissionProfile = if ($MonitorRepositoryInstance) {
        "ClientMonitor"
    }
    else {
        "RepositoryWriter"
    }
    $Parameters = @{
        SourceInstance           = @($RepositoryInstance)
        ServiceLoginName         = $SqlLoginName
        PermissionProfile        = $PermissionProfile
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

function Invoke-ServerRepositoryInitialization {
    [CmdletBinding()]
    param()

    $Credential = Get-ServerRepositoryServiceCredential
    $Parameters = @{
        ConfigPath               = $ConfigPath
        RepositoryInstance       = $RepositoryInstance
        RepositoryDatabase       = $RepositoryDatabase
        RepositorySchema         = $RepositorySchema
        RepositoryTable          = $RepositoryTable
        SqlLoginName             = $SqlLoginName
        ServiceCredential        = $Credential
        ConnectionTimeoutSeconds = $ConnectionTimeoutSeconds
        CommandTimeoutSeconds    = $CommandTimeoutSeconds
        RetryCount               = $RetryCount
        RetryDelaySeconds        = $RetryDelaySeconds
        LogDirectory             = $LogDirectory
        LogContext               = $LogContext
    }

    if (-not [string]::IsNullOrWhiteSpace($CollectorScriptPath)) {
        $Parameters.CollectorScriptPath = $CollectorScriptPath
    }

    if ($EnableCollectorJob) {
        $Parameters.EnableCollectorJob = $true
    }

    if ($DisableCollectorJob) {
        $Parameters.DisableCollectorJob = $true
    }

    if ($IncludeTopResourceUsage) {
        $Parameters.IncludeTopResourceUsage = $true
    }

    if ($null -ne $SqlAdminCredential) {
        $Parameters.SqlAdminCredential = $SqlAdminCredential
    }

    [void](& $InitializeRepositoryScript @Parameters)
}

function Invoke-ServerRepositoryCredentialCreation {
    [CmdletBinding()]
    param()

    Assert-CredentialFilesCanBeCreated
    $Credential = Get-ServerRepositoryServiceCredential
    $Parameters = @{
        SqlLoginName        = $SqlLoginName
        ConfigPath          = $ConfigPath
        CredentialDirectory = $CredentialDirectory
        Credential          = $Credential
        Confirm             = $false
        LogDirectory        = $LogDirectory
        LogContext          = $LogContext
    }

    if ($ForceCredential) {
        $Parameters.Force = $true
    }

    if (
        $null -ne $CredentialAccessAccount -and
        $CredentialAccessAccount.Count -gt 0
    ) {
        $Parameters.CredentialAccessAccount = $CredentialAccessAccount
    }

    [void](& $CreateCredentialScript @Parameters)
}

function Invoke-ServerRepositoryAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet(
            "ProvisionLogin",
            "InitializeRepository",
            "CreateCredential",
            "RunAll"
        )]
        [string]$SelectedAction
    )

    Write-SqlMaintenanceLog `
        -LogContext $LogContext `
        -Level Info `
        -Step $SelectedAction `
        -Message "ServerRepository action started."

    switch ($SelectedAction) {
        "ProvisionLogin" {
            Invoke-ServerRepositoryProvisionLogin
        }
        "InitializeRepository" {
            Invoke-ServerRepositoryInitialization
        }
        "CreateCredential" {
            Invoke-ServerRepositoryCredentialCreation
        }
        "RunAll" {
            Assert-CredentialFilesCanBeCreated
            Invoke-ServerRepositoryProvisionLogin
            Invoke-ServerRepositoryInitialization
            Invoke-ServerRepositoryCredentialCreation
        }
    }

    Write-SqlMaintenanceLog `
        -LogContext $LogContext `
        -Level Info `
        -Step $SelectedAction `
        -Message "ServerRepository action completed."
}

Write-Host "Execution log: $($LogContext.TextLogPath)"
Write-Host "JSON log:      $($LogContext.JsonLogPath)"

if ($Action -ne "Menu") {
    Invoke-ServerRepositoryAction -SelectedAction $Action
    return
}

while ($true) {
    Write-Host ""
    Write-Host "SQL Monitoring ServerRepository Setup"
    Write-Host "====================================="
    Write-Host "1. Provision service Login on the repository instance"
    Write-Host "2. Initialize repository database and table"
    Write-Host "3. Create or replace encrypted credential files"
    Write-Host "4. Run ServerRepository steps 1-3 in order"
    Write-Host "Q. Exit"
    Write-Host ""

    $MenuSelection = (Read-Host "Select an action").Trim()

    if ($MenuSelection -match '^Q$') {
        break
    }

    $SelectedAction = switch ($MenuSelection) {
        "1" { "ProvisionLogin" }
        "2" { "InitializeRepository" }
        "3" { "CreateCredential" }
        "4" { "RunAll" }
        default { $null }
    }

    if ($null -eq $SelectedAction) {
        Write-Warning "Invalid selection. Please try again."
        continue
    }

    try {
        Invoke-ServerRepositoryAction -SelectedAction $SelectedAction
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
