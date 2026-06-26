[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$InstallerPath = 'C:\install\SSMS-Setup-ENU.exe',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$InstallPath = 'E:\Program Files\Microsoft SQL Server Management Studio',

    [Parameter()]
    [ValidateSet('Silent', 'UI')]
    [string]$InstallMode = 'UI',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$LogRoot = 'C:\autoscript\logs\Ssms'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-DriveExistsFromPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $driveName = Split-Path -Path $Path -Qualifier

    if ([string]::IsNullOrWhiteSpace($driveName)) {
        throw "Install path must include a drive letter: $Path"
    }

    if (-not (Test-Path -LiteralPath "$driveName\")) {
        throw "Install path drive does not exist: $driveName"
    }
}

function Quote-SetupValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if ($Value.Contains('"')) {
        throw "SSMS setup argument values cannot contain double quotes: $Value"
    }

    return '"' + $Value + '"'
}

function Write-SsmsInstallerMissingHelp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $installerFolder = Split-Path -Path $Path -Parent

    Write-Warning "SSMS installer was not found: $Path"
    Write-Host ''

    if (Test-Path -LiteralPath $installerFolder -PathType Container) {
        $installerFiles = Get-ChildItem -LiteralPath $installerFolder -File -Filter '*.exe' -ErrorAction SilentlyContinue

        if ($null -ne $installerFiles) {
            Write-Host "EXE files found in ${installerFolder}:"

            foreach ($installerFile in $installerFiles) {
                Write-Host $installerFile.FullName
            }

            Write-Host ''
            Write-Host 'Copy one of these examples and replace the path if needed:'
            Write-Host "C:\AutoScript\scripts\InstallSql\Install-Ssms.ps1 -InstallerPath '$($installerFiles[0].FullName)'"
            Write-Host "C:\AutoScript\scripts\InstallSql\Install-Ssms.ps1 -InstallerPath '$($installerFiles[0].FullName)' -InstallPath 'E:\SSMS'"
            Write-Host ''
            return
        }
    }
    else {
        Write-Host "Installer folder does not exist: $installerFolder"
        Write-Host ''
    }

    Write-Host 'Put the SSMS installer at the default path, or run with -InstallerPath.'
    Write-Host ''
    Write-Host 'Default expected path:'
    Write-Host 'C:\install\SSMS-Setup-ENU.exe'
    Write-Host ''
    Write-Host 'Example:'
    Write-Host "C:\AutoScript\scripts\InstallSql\Install-Ssms.ps1 -InstallerPath 'D:\install\SSMS-Setup-ENU.exe'"
    Write-Host ''
}

function Test-SsmsInstalled {
    param(
        [Parameter()]
        [string]$Path
    )

    $knownSsmsPaths = @(
        "${env:ProgramFiles}\Microsoft SQL Server Management Studio 21\Common7\IDE\Ssms.exe",
        "${env:ProgramFiles(x86)}\Microsoft SQL Server Management Studio 21\Common7\IDE\Ssms.exe",
        "${env:ProgramFiles}\Microsoft SQL Server Management Studio 20\Common7\IDE\Ssms.exe",
        "${env:ProgramFiles(x86)}\Microsoft SQL Server Management Studio 20\Common7\IDE\Ssms.exe",
        "${env:ProgramFiles}\Microsoft SQL Server Management Studio 19\Common7\IDE\Ssms.exe",
        "${env:ProgramFiles(x86)}\Microsoft SQL Server Management Studio 19\Common7\IDE\Ssms.exe",
        "${env:ProgramFiles(x86)}\Microsoft SQL Server Management Studio 18\Common7\IDE\Ssms.exe"
    )

    $installPathDrive = Split-Path -Path $Path -Qualifier

    if (-not [string]::IsNullOrWhiteSpace($installPathDrive) -and (Test-Path -LiteralPath "$installPathDrive\")) {
        $knownSsmsPaths += (Join-Path -Path $Path -ChildPath 'Common7\IDE\Ssms.exe')
    }

    foreach ($path in $knownSsmsPaths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return $true
        }
    }

    $uninstallRegistryPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($path in $uninstallRegistryPaths) {
        $match = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
            Where-Object {
                $displayNameProperty = $_.PSObject.Properties['DisplayName']

                if ($null -eq $displayNameProperty) {
                    return $false
                }

                $displayNameProperty.Value -like 'Microsoft SQL Server Management Studio*' -or
                $displayNameProperty.Value -like 'SQL Server Management Studio*'
            } |
            Select-Object -First 1

        if ($null -ne $match) {
            return $true
        }
    }

    return $false
}

function Start-InstallTranscript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $transcriptPath = Join-Path -Path $Path -ChildPath "Install-Ssms-$timestamp.log"

    Start-Transcript -Path $transcriptPath -Force | Out-Null

    return $transcriptPath
}

function New-SsmsSetupArguments {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Mode,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $arguments = @('/install', '--installPath', (Quote-SetupValue -Value $Path), '/norestart')

    if ($Mode -eq 'Silent') {
        return $arguments + '/quiet'
    }

    return $arguments + '/passive'
}

$result = [ordered]@{
    InstallerPath   = $InstallerPath
    InstallPath     = $InstallPath
    InstallMode     = $InstallMode
    AlreadyInstalled = $false
    SkippedReason   = $null
    InstallExitCode = $null
    LogPath         = $null
}

if ($WhatIfPreference) {
    [pscustomobject]$result
    return
}

$transcriptStarted = $false

try {
    $result.LogPath = Start-InstallTranscript -Path $LogRoot
    $transcriptStarted = $true
    Write-Host "Install log: $($result.LogPath)"

    if (Test-SsmsInstalled -Path $InstallPath) {
        $result.AlreadyInstalled = $true
        $result.SkippedReason = 'SQL Server Management Studio is already installed.'
        Write-Warning $result.SkippedReason
        [pscustomobject]$result
        return
    }

    if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
        Write-SsmsInstallerMissingHelp -Path $InstallerPath
        throw "SSMS installer does not exist: $InstallerPath"
    }

    if (-not (Test-IsAdministrator)) {
        throw 'Run this script from an elevated PowerShell session.'
    }

    Assert-DriveExistsFromPath -Path $InstallPath

    $setupArguments = New-SsmsSetupArguments -Mode $InstallMode -Path $InstallPath

    if ($PSCmdlet.ShouldProcess($InstallPath, 'Install SQL Server Management Studio')) {
        $process = Start-Process `
            -FilePath $InstallerPath `
            -ArgumentList ($setupArguments -join ' ') `
            -Wait `
            -PassThru

        $result.InstallExitCode = $process.ExitCode

        if ($process.ExitCode -ne 0) {
            throw "SSMS setup failed with exit code $($process.ExitCode)."
        }
    }

    [pscustomobject]$result
}
finally {
    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
        Write-Host "Install log saved to: $($result.LogPath)"
    }
}
