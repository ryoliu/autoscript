<#
.SYNOPSIS
Creates separate Client and ServerRepository deployment packages.

.DESCRIPTION
Copies only the files required by each deployment role. The Client package does
not include repository configuration, central registration scripts, AES keys,
credential XML files, or GetDBInfo Collectors.

.PARAMETER OutputRoot
Parent directory where SqlMonitoringClient and SqlMonitoringServer are created.
When omitted, the root of the drive containing this script is used.

.EXAMPLE
.\New-SqlMonitoringDeploymentPackages.ps1

Creates both deployment packages in the root of the drive containing this
script.

.EXAMPLE
.\New-SqlMonitoringDeploymentPackages.ps1 `
    -OutputRoot "C:\Deployment\SqlMonitoring"
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $PSBoundParameters.ContainsKey("OutputRoot")) {
    $OutputRoot = [System.IO.Path]::GetPathRoot($PSScriptRoot)
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    throw "Unable to determine the deployment output root."
}

$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
$ClientPackageRoot = Join-Path $OutputRoot "SqlMonitoringClient"
$ServerPackageRoot = Join-Path $OutputRoot "SqlMonitoringServer"

foreach ($PackageRoot in @($ClientPackageRoot, $ServerPackageRoot)) {
    if (Test-Path -LiteralPath $PackageRoot) {
        throw (
            "Deployment package directory already exists: $PackageRoot. " +
            "Choose an empty OutputRoot."
        )
    }
}

$AgentSource = Join-Path $PSScriptRoot "SqlMonitor\Agent"
$ServerRepositorySource = Join-Path `
    $PSScriptRoot `
    "SqlMonitor\ServerRepository"
$CommonModuleSource = Join-Path `
    $PSScriptRoot `
    "SqlMonitor\Modules\SqlMaintenance.Common"
$GetDBInfoSource = Join-Path $PSScriptRoot "GetDBInfo"
$RepositoryConfigSource = Join-Path `
    $PSScriptRoot `
    "Config\repository.config"

$RequiredSourcePaths = @(
    (Join-Path $AgentSource "Start-AgentSetup.ps1"),
    (Join-Path $AgentSource "New-SqlServiceLogin.ps1"),
    (Join-Path $AgentSource "Config\agent.config"),
    (Join-Path $ServerRepositorySource "Start-ServerRepositorySetup.ps1"),
    (Join-Path $ServerRepositorySource "Initialize-SqlMonitorRepository.ps1"),
    (Join-Path $ServerRepositorySource "New-SqlCredentialKey.ps1"),
    (Join-Path $ServerRepositorySource "Register-SqlMonitoringClient.ps1"),
    $CommonModuleSource,
    $GetDBInfoSource,
    $RepositoryConfigSource
)

foreach ($RequiredSourcePath in $RequiredSourcePaths) {
    if (-not (Test-Path -LiteralPath $RequiredSourcePath)) {
        throw "Required deployment source not found: $RequiredSourcePath"
    }
}

$ClientDirectories = @(
    $ClientPackageRoot,
    (Join-Path $ClientPackageRoot "Config"),
    (Join-Path $ClientPackageRoot "Modules"),
    (Join-Path $ClientPackageRoot "Logs")
)
$ServerDirectories = @(
    $ServerPackageRoot,
    (Join-Path $ServerPackageRoot "ServerRepository"),
    (Join-Path $ServerPackageRoot "GetDBInfo"),
    (Join-Path $ServerPackageRoot "Config"),
    (Join-Path $ServerPackageRoot "Credentials"),
    (Join-Path $ServerPackageRoot "Modules"),
    (Join-Path $ServerPackageRoot "Logs")
)

foreach ($Directory in @($ClientDirectories + $ServerDirectories)) {
    [void](New-Item -Path $Directory -ItemType Directory -Force)
}

Copy-Item `
    -LiteralPath (Join-Path $AgentSource "Start-AgentSetup.ps1") `
    -Destination $ClientPackageRoot
Copy-Item `
    -LiteralPath (Join-Path $AgentSource "New-SqlServiceLogin.ps1") `
    -Destination $ClientPackageRoot
Copy-Item `
    -LiteralPath (Join-Path $AgentSource "Config\agent.config") `
    -Destination (Join-Path $ClientPackageRoot "Config")
Copy-Item `
    -LiteralPath $CommonModuleSource `
    -Destination (Join-Path $ClientPackageRoot "Modules") `
    -Recurse

foreach ($ServerRepositoryScript in @(
    "Start-ServerRepositorySetup.ps1",
    "Initialize-SqlMonitorRepository.ps1",
    "New-SqlCredentialKey.ps1",
    "Register-SqlMonitoringClient.ps1"
)) {
    Copy-Item `
        -LiteralPath (
            Join-Path $ServerRepositorySource $ServerRepositoryScript
        ) `
        -Destination (Join-Path $ServerPackageRoot "ServerRepository")
}

# The repository setup uses the same Login creation implementation with the
# RepositoryWriter permission profile.
Copy-Item `
    -LiteralPath (Join-Path $AgentSource "New-SqlServiceLogin.ps1") `
    -Destination (Join-Path $ServerPackageRoot "ServerRepository")
Copy-Item `
    -Path (Join-Path $GetDBInfoSource "*.ps1") `
    -Destination (Join-Path $ServerPackageRoot "GetDBInfo")
Copy-Item `
    -LiteralPath $RepositoryConfigSource `
    -Destination (Join-Path $ServerPackageRoot "Config")
Copy-Item `
    -LiteralPath $CommonModuleSource `
    -Destination (Join-Path $ServerPackageRoot "Modules") `
    -Recurse

[pscustomobject]@{
    ClientPackage = $ClientPackageRoot
    ServerPackage = $ServerPackageRoot
}
