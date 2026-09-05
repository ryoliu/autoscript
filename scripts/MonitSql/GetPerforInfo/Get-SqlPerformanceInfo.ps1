#Requires -Version 5.1

<#
.SYNOPSIS
Runs the SQL Server table, unused-index, and duplicate-index reports.

.DESCRIPTION
This is the compact controller script. Each report is implemented in a
separate PS1 file and shares the same repository configuration, credential,
and instance list.

By default, it scans every instance in RepositoryTable.InsName and every user
database accessible to the login. The top-resource report is disabled by
default and requires -IncludeTopResourceUsage.

.EXAMPLE
.\Get-SqlPerformanceInfo.ps1

.EXAMPLE
.\Get-SqlPerformanceInfo.ps1 -Database AppDb,ReportDb

.EXAMPLE
.\Get-SqlPerformanceInfo.ps1 -IncludeTopResourceUsage -TopQueryLimit 10
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "Config\repository.config"),
    [Alias('Ins')][string]$RepositoryInstance,
    [string]$RepositoryDatabase,
    [string]$RepositorySchema,
    [string]$RepositoryTable,
    [string]$SqlLoginName = "srv.mn",
    [string]$CredentialDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) "Credentials"),
    [pscredential]$Credential,
    [string[]]$Database,
    [switch]$IncludeTopResourceUsage,
    [ValidateRange(1, 1000)][int]$TopQueryLimit = 20,
    [bool]$TrustServerCertificate = $true,
    [ValidateRange(1, 300)][int]$ConnectionTimeoutSeconds = 15,
    [ValidateRange(1, 86400)][int]$CommandTimeoutSeconds = 120,
    [ValidateRange(0, 20)][int]$RetryCount = 3,
    [ValidateRange(0, 300)][int]$RetryDelaySeconds = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "SqlPerformanceInfo.Common.psm1") -Force -ErrorAction Stop

$RequiredCommands = @(
    'Get-DbaDbTable',
    'Get-DbaDatabase',
    'Find-DbaDbUnusedIndex',
    'Find-DbaDbDuplicateIndex'
)
if ($IncludeTopResourceUsage) {
    $RequiredCommands += 'Get-DbaTopResourceUsage'
}

$Context = $null
try {
    $Context = New-SqlPerformanceContext `
        -ConfigPath $ConfigPath `
        -RepositoryInstance $RepositoryInstance `
        -RepositoryDatabase $RepositoryDatabase `
        -RepositorySchema $RepositorySchema `
        -RepositoryTable $RepositoryTable `
        -SqlLoginName $SqlLoginName `
        -CredentialDirectory $CredentialDirectory `
        -Credential $Credential `
        -TrustServerCertificate:$TrustServerCertificate `
        -ConnectionTimeoutSeconds $ConnectionTimeoutSeconds `
        -CommandTimeoutSeconds $CommandTimeoutSeconds `
        -RetryCount $RetryCount `
        -RetryDelaySeconds $RetryDelaySeconds `
        -RequiredDbatoolsCommands $RequiredCommands

    Show-SqlPerformanceContext -Context $Context
    $CollectedAt = [datetime]::UtcNow
    $ChildParameters = @{
        SharedContext = $Context
        CollectedAt   = $CollectedAt
    }
    if ($null -ne $Database -and $Database.Length -gt 0) {
        $ChildParameters.Database = $Database
    }

    & (Join-Path $PSScriptRoot "Get-SqlTablePerformanceInfo.ps1") @ChildParameters
    & (Join-Path $PSScriptRoot "Get-SqlUnusedIndexInfo.ps1") @ChildParameters
    & (Join-Path $PSScriptRoot "Get-SqlDuplicateIndexInfo.ps1") @ChildParameters

    if ($IncludeTopResourceUsage) {
        $TopParameters = $ChildParameters.Clone()
        $TopParameters.TopQueryLimit = $TopQueryLimit
        & (Join-Path $PSScriptRoot "Get-SqlTopResourceUsage.ps1") @TopParameters
    }
    else {
        Write-Host "Top resource report skipped by default. Use -IncludeTopResourceUsage to run it."
    }
}
finally {
    if ($null -ne $Context) {
        Close-SqlPerformanceContext -Context $Context
    }
}
