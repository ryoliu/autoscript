<#
.SYNOPSIS
Provides an interactive CLI for SQL Login provisioning and instance
registration.

.DESCRIPTION
Lists three SQL maintenance functions in their required order:

1. Create the srv.mn SQL Login and grant its server and msdb permissions.
2. Create or replace the AES key and encrypted srv.mn credential files.
3. Discover and select local SQL Server instances, then register their names in
   WIN2019LAB.Monitor.dbo.InsList.

The CLI can run an individual function or all three functions in order. All
supporting scripts must be in the same directory as this script.

.PARAMETER Action
Action to run. Menu displays the interactive CLI. Other values run the selected
action directly. The default is Menu.

.PARAMETER SqlLoginName
SQL Login used by the supporting scripts. The default is srv.mn.

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
.\Start-SqlMaintenanceCli.ps1 -Action RegisterInstances

Runs only the local instance discovery and registration function.
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
    [string]$RepositoryTable = "InsList"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProvisionLoginScript =
    Join-Path $PSScriptRoot "New-SqlServiceLogin.ps1"
$CreateCredentialScript =
    Join-Path $PSScriptRoot "New-SqlCredentialKey.ps1"
$RegisterInstancesScript =
    Join-Path $PSScriptRoot "getInstanceName.ps1"

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

function Invoke-ProvisionLogin {
    [CmdletBinding()]
    param(
        [Parameter()]
        [PSCredential]$ServiceCredential
    )

    Assert-SupportingScript -LiteralPath $ProvisionLoginScript

    Write-Host ""
    Write-Host "Step 1 - Provision SQL Login [$SqlLoginName]"
    $ProvisionParameters = @{
        ServiceLoginName = $SqlLoginName
    }

    if ($null -ne $ServiceCredential) {
        $ProvisionParameters.ServiceCredential = $ServiceCredential
    }

    & $ProvisionLoginScript @ProvisionParameters
}

function Invoke-CreateCredential {
    [CmdletBinding()]
    param(
        [Parameter()]
        [PSCredential]$Credential
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

    if ($CredentialFilesExist) {
        $ReplaceCredential = (
            Read-Host "Credential files exist. Replace them? (Y/N)"
        ).Trim()

        if ($ReplaceCredential -notmatch '^Y(?:ES)?$') {
            Write-Host "Credential creation skipped."
            return
        }

        $CredentialParameters = @{
            SqlLoginName       = $SqlLoginName
            CredentialDirectory = $CredentialDirectory
            Force              = $true
            Confirm            = $false
        }

        if ($null -ne $Credential) {
            $CredentialParameters.Credential = $Credential
        }

        & $CreateCredentialScript @CredentialParameters
        return
    }

    $CredentialParameters = @{
        SqlLoginName        = $SqlLoginName
        CredentialDirectory = $CredentialDirectory
        Confirm             = $false
    }

    if ($null -ne $Credential) {
        $CredentialParameters.Credential = $Credential
    }

    & $CreateCredentialScript @CredentialParameters
}

function Invoke-RegisterInstances {
    [CmdletBinding()]
    param()

    Assert-SupportingScript -LiteralPath $RegisterInstancesScript

    Write-Host ""
    Write-Host "Step 3 - Register SQL Server instances"
    & $RegisterInstancesScript `
        -SqlLoginName $SqlLoginName `
        -CredentialDirectory $CredentialDirectory `
        -RepositoryInstance $RepositoryInstance `
        -RepositoryDatabase $RepositoryDatabase `
        -RepositorySchema $RepositorySchema `
        -RepositoryTable $RepositoryTable
}

function Invoke-AllSqlMaintenanceSteps {
    [CmdletBinding()]
    param()

    $ServiceCredential = Get-Credential `
        -UserName $SqlLoginName `
        -Message (
            "Enter the service Login credential for steps 1 and 2"
        )

    if ($null -eq $ServiceCredential) {
        throw "A service Login credential is required."
    }

    # Stop the sequence when a required earlier step fails. Reuse the same
    # in-memory credential so the service password is entered only once.
    Invoke-ProvisionLogin -ServiceCredential $ServiceCredential
    Invoke-CreateCredential -Credential $ServiceCredential
    Invoke-RegisterInstances
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

    switch ($SelectedAction) {
        "ProvisionLogin" {
            Invoke-ProvisionLogin
        }
        "CreateCredential" {
            Invoke-CreateCredential
        }
        "RegisterInstances" {
            Invoke-RegisterInstances
        }
        "RunAll" {
            Invoke-AllSqlMaintenanceSteps
        }
    }
}

if ($Action -ne "Menu") {
    Invoke-SqlMaintenanceAction -SelectedAction $Action
    return
}

while ($true) {
    Write-Host ""
    Write-Host "SQL Maintenance CLI"
    Write-Host "==================="
    Write-Host "1. Create srv.mn SQL Login and permissions"
    Write-Host "2. Create or replace encrypted srv.mn credential"
    Write-Host "3. Select and register SQL Server instances"
    Write-Host "4. Run steps 1-3 in order"
    Write-Host "Q. Exit"
    Write-Host ""

    $MenuSelection = (Read-Host "Select an action").Trim()

    if ($MenuSelection -match '^Q$') {
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
        Write-Host ""
        Write-Error $_.Exception.Message -ErrorAction Continue
    }

    [void](Read-Host "Press Enter to return to the menu")
}
