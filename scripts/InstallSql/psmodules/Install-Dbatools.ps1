[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ModuleSourcePath,

    [Parameter()]
    [ValidateSet('AllUsers', 'CurrentUser')]
    [string]$Scope = 'AllUsers',

    [Parameter()]
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:TempExtractPath = $null

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ModuleInstallRoot {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('AllUsers', 'CurrentUser')]
        [string]$Scope
    )

    if ($Scope -eq 'AllUsers') {
        return Join-Path -Path $env:ProgramFiles -ChildPath 'WindowsPowerShell\Modules'
    }

    return Join-Path -Path ([Environment]::GetFolderPath('MyDocuments')) -ChildPath 'WindowsPowerShell\Modules'
}

function Copy-OfflineModule {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$SourceRoot,

        [Parameter(Mandatory = $true)]
        [string]$InstallRoot,

        [Parameter(Mandatory = $true)]
        [bool]$Force
    )

    $sourcePath = Join-Path -Path $SourceRoot -ChildPath $Name

    if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
        throw "Offline module folder was not found: $sourcePath"
    }

    $destinationPath = Join-Path -Path $InstallRoot -ChildPath $Name

    if ((Test-Path -LiteralPath $destinationPath) -and -not $Force) {
        Write-Host "Module already exists, skipped: $destinationPath" -ForegroundColor Yellow
        return
    }

    if ($PSCmdlet.ShouldProcess($destinationPath, "Install offline module $Name")) {
        if (Test-Path -LiteralPath $destinationPath) {
            Remove-Item -LiteralPath $destinationPath -Recurse -Force
        }

        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Recurse -Force
        Get-ChildItem -LiteralPath $destinationPath -Recurse -File -ErrorAction SilentlyContinue |
            Unblock-File -ErrorAction SilentlyContinue
    }
}

function Resolve-ModuleSourcePath {
    param(
        [Parameter()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Join-Path -Path $PSScriptRoot -ChildPath 'offline-modules.zip'
    }

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path

    if (Test-Path -LiteralPath $resolvedPath -PathType Container) {
        return $resolvedPath
    }

    if ([IO.Path]::GetExtension($resolvedPath) -ne '.zip') {
        throw "ModuleSourcePath must be an offline-modules folder or zip file: $resolvedPath"
    }

    $script:TempExtractPath = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "dbatools-offline-$([guid]::NewGuid().ToString('N'))"
    [IO.Directory]::CreateDirectory($script:TempExtractPath) | Out-Null
    $previousWhatIfPreference = $WhatIfPreference

    try {
        $WhatIfPreference = $false
        Expand-Archive -LiteralPath $resolvedPath -DestinationPath $script:TempExtractPath -Force -WhatIf:$false
    }
    finally {
        $WhatIfPreference = $previousWhatIfPreference
    }

    $zipModulePath = Join-Path -Path $script:TempExtractPath -ChildPath 'offline-modules'

    if (Test-Path -LiteralPath $zipModulePath -PathType Container) {
        return (Resolve-Path -LiteralPath $zipModulePath).Path
    }

    return $script:TempExtractPath
}

try {
    $installedModule = Get-Module -ListAvailable -Name dbatools |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if ($null -ne $installedModule -and -not $Force) {
        Import-Module dbatools -Force
        Write-Host "dbatools is already installed, skipped. Version: $($installedModule.Version)" -ForegroundColor Yellow
        [pscustomobject]@{
            Status          = 'Skipped'
            Reason          = 'AlreadyInstalled'
            DbatoolsVersion = $installedModule.Version.ToString()
            ModuleBase      = $installedModule.ModuleBase
        }
        return
    }

    if ($Scope -eq 'AllUsers' -and -not (Test-IsAdministrator)) {
        throw 'Run this script from an elevated PowerShell session, or use -Scope CurrentUser.'
    }

    $resolvedSourcePath = Resolve-ModuleSourcePath -Path $ModuleSourcePath
    $installRoot = Get-ModuleInstallRoot -Scope $Scope

    if (-not (Test-Path -LiteralPath $installRoot -PathType Container)) {
        New-Item -Path $installRoot -ItemType Directory -Force | Out-Null
    }

    Write-Host "Module source: $resolvedSourcePath" -ForegroundColor Cyan
    Write-Host "Install root: $installRoot" -ForegroundColor Cyan

    Copy-OfflineModule -Name 'dbatools.library' -SourceRoot $resolvedSourcePath -InstallRoot $installRoot -Force ([bool]$Force)
    Copy-OfflineModule -Name 'dbatools' -SourceRoot $resolvedSourcePath -InstallRoot $installRoot -Force ([bool]$Force)

    if ($WhatIfPreference) {
        [pscustomobject]@{
            Status           = 'Planned'
            ModuleSourcePath = $resolvedSourcePath
            InstallRoot      = $installRoot
            Scope            = $Scope
            DbatoolsVersion  = '<not imported in WhatIf>'
        }
        return
    }

    Import-Module dbatools -Force
    $dbatoolsModule = Get-Module dbatools

    Write-Host "dbatools installation succeeded. Version: $($dbatoolsModule.Version)" -ForegroundColor Green

    [pscustomobject]@{
        Status           = 'Installed'
        ModuleSourcePath = $resolvedSourcePath
        InstallRoot      = $installRoot
        Scope            = $Scope
        DbatoolsVersion  = $dbatoolsModule.Version.ToString()
    }
}
finally {
    if ($null -ne $script:TempExtractPath -and (Test-Path -LiteralPath $script:TempExtractPath)) {
        Remove-Item -LiteralPath $script:TempExtractPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}
