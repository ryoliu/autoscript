[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
$psModuleRoot = Join-Path -Path $scriptRoot -ChildPath 'psmodules'

function Write-Check {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [bool]$Passed,

        [Parameter()]
        [string]$Detail = ''
    )

    $status = if ($Passed) { 'PASS' } else { 'FAIL' }
    $color = if ($Passed) { 'Green' } else { 'Red' }
    $message = "[$status] $Name"

    if (-not [string]::IsNullOrWhiteSpace($Detail)) {
        $message += " - $Detail"
    }

    Write-Host $message -ForegroundColor $color

    if (-not $Passed) {
        throw $message
    }
}

function Test-PowerShellSyntax {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $tokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)

    if ($parseErrors.Count -gt 0) {
        $messages = ($parseErrors | ForEach-Object { $_.Message }) -join '; '
        throw "Parse failed: $Path - $messages"
    }
}

Write-Host "AutoScript InstallSql package test: $scriptRoot" -ForegroundColor Cyan

Write-Check -Name 'Start-AutoScriptUi.ps1 exists' -Passed (Test-Path -LiteralPath (Join-Path $scriptRoot 'Start-AutoScriptUi.ps1') -PathType Leaf)
Write-Check -Name 'psmodules folder exists' -Passed (Test-Path -LiteralPath $psModuleRoot -PathType Container)

$requiredFiles = @(
    'Install-Dbatools.ps1',
    'Install-SqlServer.ps1',
    'Install-SqlServerHotfix.ps1',
    'Install-Ssms.ps1',
    'offline-modules.zip',
    'Set-OsSqlServerPrerequisites.ps1',
    'Set-SqlServerInstanceConfiguration.ps1',
    'Test-OsSqlServerPrerequisites.ps1',
    'Test-SqlServerInstanceConfiguration.ps1'
)

foreach ($file in $requiredFiles) {
    $path = Join-Path -Path $psModuleRoot -ChildPath $file
    Write-Check -Name "Required file $file" -Passed (Test-Path -LiteralPath $path -PathType Leaf)
}

$unexpectedRootFiles = Get-ChildItem -LiteralPath $scriptRoot -File -Filter '*.ps1' |
    Where-Object { $_.Name -notin @('Start-AutoScriptUi.ps1', 'Test-AutoScriptInstallSqlPackage.ps1') }

$unexpectedRootFileNames = @($unexpectedRootFiles | ForEach-Object { $_.Name })
Write-Check -Name 'No executable ps1 files outside psmodules' -Passed ($unexpectedRootFileNames.Count -eq 0) -Detail ($unexpectedRootFileNames -join ', ')

$ps1Files = @(
    Join-Path -Path $scriptRoot -ChildPath 'Start-AutoScriptUi.ps1'
    Join-Path -Path $scriptRoot -ChildPath 'Test-AutoScriptInstallSqlPackage.ps1'
) + (Get-ChildItem -LiteralPath $psModuleRoot -File -Filter '*.ps1' | ForEach-Object { $_.FullName })

foreach ($file in $ps1Files) {
    Test-PowerShellSyntax -Path $file
}

Write-Check -Name 'PowerShell syntax' -Passed $true -Detail "$($ps1Files.Count) ps1 files parsed"

$uiContent = Get-Content -LiteralPath (Join-Path $scriptRoot 'Start-AutoScriptUi.ps1') -Raw
Write-Check -Name 'UI uses psmodules path' -Passed ($uiContent -match '\$psModuleRoot')

foreach ($file in ($requiredFiles | Where-Object { $_ -like '*.ps1' })) {
    $escaped = [regex]::Escape("ChildPath '$file'")
    Write-Check -Name "UI references $file" -Passed ($uiContent -match $escaped)
}

$dbatoolsTest = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $psModuleRoot 'Install-Dbatools.ps1') -Scope CurrentUser -Force -WhatIf 2>&1
$dbatoolsText = ($dbatoolsTest | Out-String)
Write-Check -Name 'Install-Dbatools WhatIf uses zip extraction' -Passed ($dbatoolsText -match 'dbatools-offline-' -and $dbatoolsText -match 'offline-modules')

Write-Host 'All AutoScript InstallSql package checks passed.' -ForegroundColor Green
