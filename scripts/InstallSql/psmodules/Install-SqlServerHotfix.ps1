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
    [version]$TargetProductVersion = '15.0.4198.2',

    [Parameter(Mandatory = $true)]
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

function Resolve-SqlServerConnectionTarget {
    param(
        [Parameter()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -ieq 'MSSQLSERVER') {
        return 'localhost'
    }

    if ($Name -in @('localhost', '.', '(local)')) {
        return $Name
    }

    if ($Name -match '[\\,:]') {
        return $Name
    }

    return "localhost\$Name"
}

function Get-SqlCmdPath {
    $command = Get-Command -Name sqlcmd.exe -ErrorAction SilentlyContinue

    if ($null -ne $command) {
        return $command.Source
    }

    $candidates = @(
        'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\sqlcmd.exe',
        'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\130\Tools\Binn\sqlcmd.exe',
        'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\110\Tools\Binn\sqlcmd.exe',
        'C:\Program Files\Microsoft SQL Server\160\Tools\Binn\sqlcmd.exe',
        'C:\Program Files\Microsoft SQL Server\150\Tools\Binn\sqlcmd.exe',
        'C:\Program Files\Microsoft SQL Server\140\Tools\Binn\sqlcmd.exe',
        'C:\Program Files\Microsoft SQL Server\130\Tools\Binn\sqlcmd.exe',
        'C:\Program Files\Microsoft SQL Server\120\Tools\Binn\sqlcmd.exe',
        'C:\Program Files\Microsoft SQL Server\110\Tools\Binn\sqlcmd.exe'
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    return $null
}

function Get-SqlServerProductVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $sqlcmd = Get-SqlCmdPath

    if ([string]::IsNullOrWhiteSpace($sqlcmd)) {
        Write-Warning 'sqlcmd.exe was not found. Product version check will be skipped.'
        return $null
    }

    $connectionTarget = Resolve-SqlServerConnectionTarget -Name $Name
    $arguments = @(
        '-S', $connectionTarget,
        '-E',
        '-b',
        '-W',
        '-h', '-1',
        '-Q', "SET NOCOUNT ON; SELECT CONVERT(varchar(32), SERVERPROPERTY('ProductVersion'));"
    )

    $output = & $sqlcmd @arguments 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "SQL Server product version check failed for $connectionTarget. $output"
        return $null
    }

    $versionText = @($output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)[0]

    if ([string]::IsNullOrWhiteSpace($versionText)) {
        return $null
    }

    return [version]$versionText.Trim()
}

function New-SqlServerHotfixArguments {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Mode,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
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
    $arguments += "/InstanceName=$Name"

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

function Write-SqlSetupSummaryLogExcerpt {
    param(
        [Parameter()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }

    Write-Host ''
    Write-Host "SQL setup summary log: $Path" -ForegroundColor Yellow

    $patterns = @(
        'Overall summary',
        'Final result',
        'Exit code',
        'Exit message',
        'Error result',
        'Feature failure reason',
        'Detailed results'
    )

    $summaryLines = Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue |
        Where-Object {
            $line = $_
            $patterns | Where-Object { $line -like "*$_*" } | Select-Object -First 1
        }

    if ($null -eq $summaryLines) {
        Get-Content -LiteralPath $Path -Tail 40 -ErrorAction SilentlyContinue
        return
    }

    $summaryLines | Select-Object -First 80
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
            Write-Host "C:\AutoScript\scripts\InstallSql\Install-SqlServerHotfix.ps1 -InstallerPath '$($installerFiles[0].FullName)'"
            Write-Host "C:\AutoScript\scripts\InstallSql\Install-SqlServerHotfix.ps1 -InstallerPath '$($installerFiles[0].FullName)' -InstanceName MSSQLSERVER"
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
    Write-Host "C:\AutoScript\scripts\InstallSql\Install-SqlServerHotfix.ps1 -InstallerPath 'D:\install\SQLServer2019-KB5008996-x64.exe'"
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
    TargetProductVersion = $TargetProductVersion.ToString()
    CurrentProductVersion = $null
    InstanceName    = $InstanceName
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
        Write-Host 'C:\AutoScript\scripts\InstallSql\Install-SqlServerHotfix.ps1'
        Write-Host ''
        Write-Host 'If you intentionally want to bypass this check, run:'
        Write-Host 'C:\AutoScript\scripts\InstallSql\Install-SqlServerHotfix.ps1 -SkipPendingRebootCheck'
        [pscustomobject]$result
        return
    }

    if (Test-SqlServerHotfixInstalled -Kb $KbNumber) {
        Write-Warning "SQL Server hotfix $KbNumber appears in Windows uninstall registry. The installer will still run because this check is not instance-specific."
    }

    $currentProductVersion = Get-SqlServerProductVersion -Name $InstanceName

    if ($null -ne $currentProductVersion) {
        $result.CurrentProductVersion = $currentProductVersion.ToString()
        Write-Host "SQL Server product version for ${InstanceName}: $currentProductVersion" -ForegroundColor Cyan

        if ($currentProductVersion -ge $TargetProductVersion) {
            $result.AlreadyInstalled = $true
            $result.SkippedReason = "SQL Server instance $InstanceName is already at version $currentProductVersion, which is greater than or equal to target hotfix version $TargetProductVersion."
            Write-Warning $result.SkippedReason
            [pscustomobject]$result
            return
        }
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
                    Write-SqlSetupSummaryLogExcerpt -Path $result.SetupSummaryLog
                }
            }
            default {
                $message = "SQL Server hotfix setup failed with exit code $($process.ExitCode) ($($result.InstallExitCodeHex))."

                if ($null -ne $result.SetupSummaryLog) {
                    $message += " SQL setup summary log: $($result.SetupSummaryLog)"
                    Write-SqlSetupSummaryLogExcerpt -Path $result.SetupSummaryLog
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
