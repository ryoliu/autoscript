[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$InstallerPath = 'C:\install\SQLServer2019-KB5008996-x64.exe',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$KbNumber = 'KB5008996',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$InstanceName,

    [Parameter()]
    [ValidateSet('Silent', 'UI')]
    [string]$InstallMode = 'UI',

    [Parameter()]
    [switch]$SkipPendingRebootCheck,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$LogRoot = 'C:\autoscript\logs\SqlServerHotfix'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-PendingReboot {
    $rebootRegistryPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )

    foreach ($path in $rebootRegistryPaths) {
        if (Test-Path -LiteralPath $path) {
            return $true
        }
    }

    $sessionManagerPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    $sessionManager = Get-ItemProperty -LiteralPath $sessionManagerPath -ErrorAction SilentlyContinue

    if ($null -ne $sessionManager -and $null -ne $sessionManager.PSObject.Properties['PendingFileRenameOperations']) {
        return $true
    }

    return $false
}

function Test-SqlServerHotfixInstalled {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Kb
    )

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

                $displayNameProperty.Value -like "*$Kb*"
            } |
            Select-Object -First 1

        if ($null -ne $match) {
            return $true
        }
    }

    return $false
}

function New-SqlServerHotfixArguments {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Mode,

        [Parameter()]
        [string]$Name
    )

    $arguments = @()

    if ($Mode -eq 'Silent') {
        $arguments += '/quiet'
    }
    else {
        $arguments += '/qs'
    }

    $arguments += '/IAcceptSQLServerLicenseTerms'
    $arguments += '/Action=Patch'

    if ([string]::IsNullOrWhiteSpace($Name)) {
        $arguments += '/AllInstances'
    }
    else {
        $arguments += "/InstanceName=$Name"
    }

    return $arguments
}

function ConvertTo-UnsignedHexExitCode {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ExitCode
    )

    return '0x{0:X8}' -f (([int64]$ExitCode) -band 0xffffffff)
}

function Get-RecentSqlSetupSummaryLog {
    $setupBootstrapPath = Join-Path -Path ${env:ProgramFiles} -ChildPath 'Microsoft SQL Server\150\Setup Bootstrap\Log'

    if (-not (Test-Path -LiteralPath $setupBootstrapPath -PathType Container)) {
        return $null
    }

    return Get-ChildItem -LiteralPath $setupBootstrapPath -Recurse -Filter Summary.txt -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}

function Write-HotfixInstallerMissingHelp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $installerFolder = Split-Path -Path $Path -Parent

    if ([string]::IsNullOrWhiteSpace($installerFolder)) {
        $installerFolder = 'C:\install'
    }

    Write-Warning "SQL Server hotfix installer was not found: $Path"
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
            Write-Host "C:\AutoScript\scripts\Install-SqlServerHotfix.ps1 -InstallerPath '$($installerFiles[0].FullName)'"
            Write-Host "C:\AutoScript\scripts\Install-SqlServerHotfix.ps1 -InstallerPath '$($installerFiles[0].FullName)' -InstanceName MSSQLSERVER"
            Write-Host ''
            return
        }
    }
    else {
        Write-Host "Installer folder does not exist: $installerFolder"
        Write-Host ''
    }

    Write-Host 'Put the SQL Server hotfix installer at the default path, or run with -InstallerPath.'
    Write-Host ''
    Write-Host 'Default expected path:'
    Write-Host 'C:\install\SQLServer2019-KB5008996-x64.exe'
    Write-Host ''
    Write-Host 'Example:'
    Write-Host "C:\AutoScript\scripts\Install-SqlServerHotfix.ps1 -InstallerPath 'D:\install\SQLServer2019-KB5008996-x64.exe'"
    Write-Host ''
}

function Start-InstallTranscript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Kb,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }

    $safeName = $Name -replace '[^a-zA-Z0-9_.-]', '_'
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $transcriptPath = Join-Path -Path $Path -ChildPath "Install-SqlServerHotfix-$Kb-$safeName-$timestamp.log"

    Start-Transcript -Path $transcriptPath -Force | Out-Null

    return $transcriptPath
}

$result = [ordered]@{
    InstallerPath   = $InstallerPath
    KbNumber        = $KbNumber
    InstanceName    = if ([string]::IsNullOrWhiteSpace($InstanceName)) { '<all instances>' } else { $InstanceName }
    InstallMode     = $InstallMode
    AlreadyInstalled = $false
    PendingReboot   = $false
    InstallerMissing = $false
    NotApplicable   = $false
    RebootRequired  = $false
    InstallExitCode = $null
    InstallExitCodeHex = $null
    SetupSummaryLog = $null
    SkippedReason   = $null
    LogPath         = $null
}

if ($WhatIfPreference) {
    [pscustomobject]$result
    return
}

$transcriptStarted = $false

try {
    $result.LogPath = Start-InstallTranscript -Path $LogRoot -Kb $KbNumber -Name $result.InstanceName
    $transcriptStarted = $true
    Write-Host "Install log: $($result.LogPath)"

    if (-not $SkipPendingRebootCheck -and (Test-PendingReboot)) {
        $result.PendingReboot = $true
        $result.RebootRequired = $true
        $result.SkippedReason = "Windows has a pending restart. Restart the server first, then run this hotfix installer again."
        Write-Warning $result.SkippedReason
        Write-Host ''
        Write-Host 'After restart, run:'
        Write-Host 'C:\AutoScript\scripts\Install-SqlServerHotfix.ps1'
        Write-Host ''
        Write-Host 'If you intentionally want to bypass this check, run:'
        Write-Host 'C:\AutoScript\scripts\Install-SqlServerHotfix.ps1 -SkipPendingRebootCheck'
        [pscustomobject]$result
        return
    }

    if (Test-SqlServerHotfixInstalled -Kb $KbNumber) {
        $result.AlreadyInstalled = $true
        $result.SkippedReason = "SQL Server hotfix $KbNumber appears to be already installed."
        Write-Warning $result.SkippedReason
        [pscustomobject]$result
        return
    }

    if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
        $result.InstallerMissing = $true
        $result.SkippedReason = "SQL Server hotfix installer was not found: $InstallerPath"
        Write-HotfixInstallerMissingHelp -Path $InstallerPath
        [pscustomobject]$result
        return
    }

    if (-not (Test-IsAdministrator)) {
        throw 'Run this script from an elevated PowerShell session.'
    }

    $setupArguments = New-SqlServerHotfixArguments -Mode $InstallMode -Name $InstanceName

    if ($PSCmdlet.ShouldProcess($InstallerPath, "Install SQL Server hotfix $KbNumber")) {
        $process = Start-Process `
            -FilePath $InstallerPath `
            -ArgumentList ($setupArguments -join ' ') `
            -Wait `
            -PassThru

        $result.InstallExitCode = $process.ExitCode
        $result.InstallExitCodeHex = ConvertTo-UnsignedHexExitCode -ExitCode $process.ExitCode
        $result.SetupSummaryLog = Get-RecentSqlSetupSummaryLog

        switch ($process.ExitCode) {
            0 {
                Write-Host "SQL Server hotfix $KbNumber installed successfully."
            }
            3010 {
                $result.RebootRequired = $true
                Write-Warning "SQL Server hotfix $KbNumber installed successfully. Restart is required."
            }
            1641 {
                $result.RebootRequired = $true
                Write-Warning "SQL Server hotfix $KbNumber installed successfully. Installer initiated a restart."
            }
            -2067919934 {
                $result.NotApplicable = $true
                $result.SkippedReason = "SQL Server hotfix $KbNumber was not applied because no applicable SQL Server instance was found. It may already be installed, superseded by a newer update, or not match the installed SQL Server version."
                Write-Warning $result.SkippedReason

                if ($null -ne $result.SetupSummaryLog) {
                    Write-Host ''
                    Write-Host "SQL setup summary log: $($result.SetupSummaryLog)"
                }
            }
            default {
                $message = "SQL Server hotfix setup failed with exit code $($process.ExitCode) ($($result.InstallExitCodeHex))."

                if ($null -ne $result.SetupSummaryLog) {
                    $message += " SQL setup summary log: $($result.SetupSummaryLog)"
                }

                throw $message
            }
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
