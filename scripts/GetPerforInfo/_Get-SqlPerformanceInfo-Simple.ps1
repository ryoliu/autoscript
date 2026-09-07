#Requires -Version 5.1

# ===== 1. Settings: Normally, only edit this section =====
$IncludeTopResourceUsage = $false       # Set to $true when the top resource report is required.

# ===== 2. Run each report =====
$ErrorActionPreference = 'Stop'

Write-Host 'Starting SQL Server performance reports.'

Write-Host ''
Write-Host '1. Table performance information'
& (Join-Path $PSScriptRoot 'Get-SqlTablePerformanceInfo-Simple.ps1')

Write-Host ''
Write-Host '2. Unused index information'
& (Join-Path $PSScriptRoot 'Get-SqlUnusedIndexInfo-Simple.ps1')

Write-Host ''
Write-Host '3. Duplicate index information'
& (Join-Path $PSScriptRoot 'Get-SqlDuplicateIndexInfo-Simple.ps1')

if ($IncludeTopResourceUsage) {
    Write-Host ''
    Write-Host '4. Top resource usage'
    & (Join-Path $PSScriptRoot 'Get-SqlTopResourceUsage-Simple.ps1')
}
else {
    Write-Host ''
    Write-Host '4. Top resource usage skipped.'
}

# ===== 3. Finish =====
Write-Host ''
Write-Host 'All requested SQL Server performance reports completed.'
