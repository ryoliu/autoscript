[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$IsoPath = 'C:\install\SQLServer2019-x64-ENU.iso',

    [Parameter()]
    [ValidateSet('Silent', 'UI')]
    [string]$InstallMode = 'UI',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$InstanceName = 'MSSQLSERVER',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Features = 'SQLENGINE,CONN,BC,SDK,SNAC_SDK',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$InstallSharedDir = 'E:\Program Files\Microsoft SQL Server',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$InstallSharedWowDir = 'E:\Program Files (x86)\Microsoft SQL Server',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$InstanceDir = 'E:\Program Files\Microsoft SQL Server',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$UserDbDir = 'T:\SQLServerData',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$UserDbLogDir = 'T:\SQLServerLog',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$TempDbDir = 'T:\SQLServerTempDB',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$BackupDir = 'T:\SQLServerBackup',

    [Parameter()]
    [ValidateRange(1, 2147483647)]
    [int]$TempDbFileSize = 1024,

    [Parameter()]
    [ValidateRange(1, 2147483647)]
    [int]$TempDbFileGrowth = 128,

    [Parameter()]
    [ValidateRange(1, 2147483647)]
    [int]$TempDbLogFileSize = 128,

    [Parameter()]
    [ValidateRange(1, 2147483647)]
    [int]$TempDbLogFileGrowth = 128,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$LogRoot = 'C:\autoscript\logs\SqlServer'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-CurrentWindowsAccount {
    return [Security.Principal.WindowsIdentity]::GetCurrent().Name
}

function ConvertTo-PlainText {
    param(
        [Parameter(Mandatory = $true)]
        [Security.SecureString]$SecureString
    )

    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        if ($ptr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
        }
    }
}

function Assert-DriveExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DriveName
    )

    if (-not (Test-Path -LiteralPath "${DriveName}:\")) {
        throw "Required drive ${DriveName}: does not exist."
    }
}

function Test-SqlServerInstanceInstalled {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $serviceName = if ($Name -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { "MSSQL`$$Name" }
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

    if ($null -ne $service) {
        return $true
    }

    $instanceRegistryPath = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'

    if (Test-Path -LiteralPath $instanceRegistryPath) {
        $instanceNames = Get-ItemProperty -LiteralPath $instanceRegistryPath

        if ($null -ne $instanceNames.PSObject.Properties[$Name]) {
            return $true
        }
    }

    return $false
}

function Write-SqlInstanceExistsHelp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    Write-Warning "SQL Server instance '$Name' is already installed."
    Write-Host ''
    Write-Host 'To install a second SQL Server instance, copy one of these examples:'
    Write-Host ''
    Write-Host 'Simple example:'
    Write-Host 'C:\AutoScript\scripts\Install-SqlServer.ps1 -InstanceName SQL2019DEV'
    Write-Host ''
    Write-Host 'Example with separate data folders:'
    Write-Host 'C:\AutoScript\scripts\Install-SqlServer.ps1 -InstanceName SQL2019DEV -UserDbDir T:\SQLServerData_SQL2019DEV -UserDbLogDir T:\SQLServerLog_SQL2019DEV -TempDbDir T:\SQLServerTempDB_SQL2019DEV -BackupDir T:\SQLServerBackup_SQL2019DEV'
    Write-Host ''
}

function Write-SqlIsoMissingHelp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $isoFolder = Split-Path -Path $Path -Parent

    if ([string]::IsNullOrWhiteSpace($isoFolder)) {
        $isoFolder = 'C:\install'
    }

    Write-Warning "SQL Server ISO file was not found: $Path"
    Write-Host ''

    if (Test-Path -LiteralPath $isoFolder -PathType Container) {
        $isoFiles = Get-ChildItem -LiteralPath $isoFolder -File -Filter '*.iso' -ErrorAction SilentlyContinue

        if ($null -ne $isoFiles) {
            Write-Host "ISO files found in ${isoFolder}:"

            foreach ($isoFile in $isoFiles) {
                Write-Host $isoFile.FullName
            }

            Write-Host ''
            Write-Host 'Copy one of these examples and replace the path if needed:'
            Write-Host "C:\AutoScript\scripts\Install-SqlServer.ps1 -IsoPath '$($isoFiles[0].FullName)'"
            Write-Host "C:\AutoScript\scripts\Install-SqlServer.ps1 -IsoPath '$($isoFiles[0].FullName)' -InstanceName SQL2019DEV"
            Write-Host ''
            return
        }
    }
    else {
        Write-Host "ISO folder does not exist: $isoFolder"
        Write-Host ''
    }

    Write-Host 'Put the SQL Server 2019 ISO at the default path, or run with -IsoPath.'
    Write-Host ''
    Write-Host 'Default expected path:'
    Write-Host 'C:\install\SQLServer2019-x64-ENU.iso'
    Write-Host ''
    Write-Host 'Example:'
    Write-Host "C:\AutoScript\scripts\Install-SqlServer.ps1 -IsoPath 'D:\ISO\SQLServer2019-x64-ENU.iso'"
    Write-Host ''
}

function Resolve-SqlIsoPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return (Resolve-Path -LiteralPath $Path).Path
    }

    $isoFolder = Split-Path -Path $Path -Parent

    if ([string]::IsNullOrWhiteSpace($isoFolder)) {
        $candidatePath = Join-Path -Path 'C:\install' -ChildPath $Path

        if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidatePath).Path
        }
    }

    return $Path
}

function Get-TempDbFileCount {
    $cpu = Get-CimInstance -ClassName Win32_ComputerSystem
    $logicalProcessorCount = [int]$cpu.NumberOfLogicalProcessors

    if ($logicalProcessorCount -lt 1) {
        return 1
    }

    return [Math]::Min($logicalProcessorCount, 8)
}

function Mount-SqlServerIso {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-SqlIsoMissingHelp -Path $Path
        throw "ISO file does not exist: $Path"
    }

    $diskImage = Get-DiskImage -ImagePath $Path -ErrorAction SilentlyContinue

    if ($null -eq $diskImage -or -not $diskImage.Attached) {
        $diskImage = Mount-DiskImage -ImagePath $Path -PassThru
    }

    $volume = $diskImage | Get-Volume | Select-Object -First 1

    if ($null -eq $volume -or [string]::IsNullOrWhiteSpace($volume.DriveLetter)) {
        throw "ISO mounted, but no drive letter was assigned: $Path"
    }

    $mountedDriveLetter = "$($volume.DriveLetter):"
    $setupPath = Join-Path -Path $mountedDriveLetter -ChildPath 'setup.exe'

    if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf)) {
        throw "setup.exe was not found on mounted ISO drive $mountedDriveLetter. Check that this is a SQL Server ISO."
    }

    return [pscustomobject]@{
        IsoPath            = $Path
        MountedDriveLetter = $mountedDriveLetter
        SetupPath          = $setupPath
    }
}

function New-DirectoryIfMissing {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Start-InstallTranscript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }

    $safeName = $Name -replace '[^a-zA-Z0-9_.-]', '_'
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $transcriptPath = Join-Path -Path $Path -ChildPath "Install-SqlServer-$safeName-$timestamp.log"

    Start-Transcript -Path $transcriptPath -Force | Out-Null

    return $transcriptPath
}

function Get-SqlServiceAccounts {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($Name -eq 'MSSQLSERVER') {
        return [pscustomobject]@{
            SqlServiceAccount   = 'NT Service\MSSQLSERVER'
            AgentServiceAccount = 'NT Service\SQLSERVERAGENT'
        }
    }

    return [pscustomobject]@{
        SqlServiceAccount   = "NT Service\MSSQL`$$Name"
        AgentServiceAccount = "NT Service\SQLAgent`$$Name"
    }
}

function Quote-SetupValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if ($Value.Contains('"')) {
        throw "SQL Server setup argument values cannot contain double quotes: $Value"
    }

    return '"' + $Value + '"'
}

function New-SetupSwitch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return "/$Name=$(Quote-SetupValue -Value $Value)"
}

function New-SqlSetupArguments {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Mode,

        [Parameter(Mandatory = $true)]
        [string]$SaPassword,

        [Parameter(Mandatory = $true)]
        [int]$TempDbFileCount,

        [Parameter(Mandatory = $true)]
        [string]$SysAdminAccount
    )

    $serviceAccounts = Get-SqlServiceAccounts -Name $InstanceName
    $quietSwitch = if ($Mode -eq 'Silent') { '/Q' } else { '/QS' }

    return @(
        $quietSwitch
        '/ACTION=Install'
        (New-SetupSwitch -Name 'FEATURES' -Value $Features)
        (New-SetupSwitch -Name 'INSTANCENAME' -Value $InstanceName)
        (New-SetupSwitch -Name 'INSTANCEID' -Value $InstanceName)
        '/SECURITYMODE=SQL'
        (New-SetupSwitch -Name 'SAPWD' -Value $SaPassword)
        (New-SetupSwitch -Name 'SQLSYSADMINACCOUNTS' -Value $SysAdminAccount)
        (New-SetupSwitch -Name 'SQLSVCACCOUNT' -Value $serviceAccounts.SqlServiceAccount)
        (New-SetupSwitch -Name 'AGTSVCACCOUNT' -Value $serviceAccounts.AgentServiceAccount)
        '/AGTSVCSTARTUPTYPE=Automatic'
        '/SQLSVCSTARTUPTYPE=Automatic'
        (New-SetupSwitch -Name 'INSTALLSHAREDDIR' -Value $InstallSharedDir)
        (New-SetupSwitch -Name 'INSTALLSHAREDWOWDIR' -Value $InstallSharedWowDir)
        (New-SetupSwitch -Name 'INSTANCEDIR' -Value $InstanceDir)
        (New-SetupSwitch -Name 'SQLUSERDBDIR' -Value $UserDbDir)
        (New-SetupSwitch -Name 'SQLUSERDBLOGDIR' -Value $UserDbLogDir)
        (New-SetupSwitch -Name 'SQLBACKUPDIR' -Value $BackupDir)
        (New-SetupSwitch -Name 'SQLTEMPDBDIR' -Value $TempDbDir)
        (New-SetupSwitch -Name 'SQLTEMPDBLOGDIR' -Value $TempDbDir)
        "/SQLTEMPDBFILECOUNT=$TempDbFileCount"
        "/SQLTEMPDBFILESIZE=$TempDbFileSize"
        "/SQLTEMPDBFILEGROWTH=$TempDbFileGrowth"
        "/SQLTEMPDBLOGFILESIZE=$TempDbLogFileSize"
        "/SQLTEMPDBLOGFILEGROWTH=$TempDbLogFileGrowth"
        '/TCPENABLED=1'
        '/NPENABLED=0'
        '/IACCEPTSQLSERVERLICENSETERMS'
    )
}

$result = [ordered]@{
    IsoPath            = $IsoPath
    mountedDriveLetter = $null
    InstallMode        = $InstallMode
    InstanceName       = $InstanceName
    AlreadyInstalled   = $false
    IsoMissing         = $false
    SkippedReason      = $null
    Features           = $Features
    InstallExitCode    = $null
    InstallSharedDir   = $InstallSharedDir
    InstallSharedWowDir = $InstallSharedWowDir
    InstanceDir        = $InstanceDir
    UserDbDir          = $UserDbDir
    UserDbLogDir       = $UserDbLogDir
    TempDbDir          = $TempDbDir
    BackupDir          = $BackupDir
    LogPath            = $null
}

if ($WhatIfPreference) {
    $result.TempDbFileCount = '<calculated at runtime, max 8>'
    [pscustomobject]$result
    return
}

$transcriptStarted = $false
$saPassword = $null

try {
    $result.LogPath = Start-InstallTranscript -Path $LogRoot -Name $InstanceName
    $transcriptStarted = $true
    Write-Host "Install log: $($result.LogPath)"

    $IsoPath = Resolve-SqlIsoPath -Path $IsoPath
    $result.IsoPath = $IsoPath

    if (Test-SqlServerInstanceInstalled -Name $InstanceName) {
        $result.AlreadyInstalled = $true
        $result.SkippedReason = "SQL Server instance '$InstanceName' is already installed."
        Write-SqlInstanceExistsHelp -Name $InstanceName
        [pscustomobject]$result
        return
    }

    if (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) {
        $result.IsoMissing = $true
        $result.SkippedReason = "SQL Server ISO file was not found: $IsoPath"
        Write-SqlIsoMissingHelp -Path $IsoPath
        [pscustomobject]$result
        return
    }

    if (-not (Test-IsAdministrator)) {
        throw 'Run this script from an elevated PowerShell session.'
    }

    Assert-DriveExists -DriveName 'E'
    Assert-DriveExists -DriveName 'T'

    $mountInfo = Mount-SqlServerIso -Path $IsoPath
    $result.mountedDriveLetter = $mountInfo.MountedDriveLetter

    @(
        $InstallSharedDir
        $InstallSharedWowDir
        $InstanceDir
        $UserDbDir
        $UserDbLogDir
        $TempDbDir
        $BackupDir
    ) | ForEach-Object {
        New-DirectoryIfMissing -Path $_
    }

    $secureSaPassword = Read-Host 'Enter db sa password' -AsSecureString
    $saPassword = ConvertTo-PlainText -SecureString $secureSaPassword

    if ([string]::IsNullOrWhiteSpace($saPassword)) {
        throw 'sa password is required for Mixed Mode installation.'
    }

    $tempDbFileCount = Get-TempDbFileCount
    $result.TempDbFileCount = $tempDbFileCount
    $sysAdminAccount = Get-CurrentWindowsAccount
    $setupArguments = New-SqlSetupArguments `
        -Mode $InstallMode `
        -SaPassword $saPassword `
        -TempDbFileCount $tempDbFileCount `
        -SysAdminAccount $sysAdminAccount

    if ($PSCmdlet.ShouldProcess($mountInfo.SetupPath, "Install SQL Server instance $InstanceName")) {
        $process = Start-Process `
            -FilePath $mountInfo.SetupPath `
            -ArgumentList ($setupArguments -join ' ') `
            -Wait `
            -PassThru

        $result.InstallExitCode = $process.ExitCode

        if ($process.ExitCode -ne 0) {
            throw "SQL Server setup failed with exit code $($process.ExitCode)."
        }
    }

    [pscustomobject]$result
}
finally {
    if ($null -ne $saPassword) {
        $saPassword = $null
    }

    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
        Write-Host "Install log saved to: $($result.LogPath)"
    }
}
