<#
.SYNOPSIS
Creates a Windows Server 2019 VirtualBox VM and starts unattended installation.

.DESCRIPTION
This script uses VBoxManage.exe to create a Windows Server 2019 VM, attach a
Windows Server ISO, run `VBoxManage unattended detect`, and start
`VBoxManage unattended install`.

Passwords are required as parameters and are not hard-coded in this script.
Use -StartType gui for the first test so you can watch the installer screen.
Use -Recreate only when the existing VM and virtual disk can be deleted.

.EXAMPLE
PS C:\AutoScript> .\scripts\New-VirtualBoxWinServer2019UnattendedVm.ps1 `
  -IsoPath "C:\ISO\Windows_Server_2019.iso" `
  -GuestPassword "P@ssw0rd123!" `
  -AdminPassword "P@ssw0rd123!"

Creates WIN2019-LAB under C:\VM and starts unattended installation in headless mode.

.EXAMPLE
PS C:\AutoScript> .\scripts\New-VirtualBoxWinServer2019UnattendedVm.ps1 `
  -IsoPath "C:\ISO\Windows_Server_2019.iso" `
  -GuestPassword "P@ssw0rd123!" `
  -AdminPassword "P@ssw0rd123!" `
  -StartType gui

Creates the VM and starts installation with a visible VirtualBox window.

.EXAMPLE
PS C:\AutoScript> .\scripts\New-VirtualBoxWinServer2019UnattendedVm.ps1 `
  -VBoxManage "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" `
  -VMName "WIN2019-LAB" `
  -BaseFolder "C:\VM" `
  -IsoPath "C:\ISO\Windows_Server_2019.iso" `
  -MemoryMB 4096 `
  -CPUs 2 `
  -DiskSizeMB 61440 `
  -EDriveSizeMB 102400 `
  -TDriveSizeMB 204800 `
  -ImageIndex 2 `
  -GuestUser "vboxadmin" `
  -GuestPassword "P@ssw0rd123!" `
  -AdminPassword "P@ssw0rd123!" `
  -GuestHostName "WIN2019LAB" `
  -StartType gui `
  -Recreate

Recreates the VM with explicit settings. -Recreate deletes the existing VM and disk.

.EXAMPLE
PS C:\AutoScript> .\scripts\New-VirtualBoxWinServer2019UnattendedVm.ps1 `
  -IsoPath "C:\ISO\Windows_Server_2019.iso" `
  -GuestPassword "P@ssw0rd123!" `
  -AdminPassword "P@ssw0rd123!" `
  -EDriveSizeMB 102400 `
  -TDriveSizeMB 204800 `
  -StartType gui

Creates the OS disk plus E: and T: data disks. Post-install setup initializes
the RAW disks in Windows and formats them as E: and T:.

.NOTES
Common Windows Server 2019 ImageIndex values:
1 = Standard Core
2 = Standard Desktop Experience
3 = Datacenter Core
4 = Datacenter Desktop Experience

By default this script creates two extra VDI disks:
E-Data.vdi = 102400 MB, formatted as E: with label Data.
T-Data.vdi = 204800 MB, formatted as T: with label Temp.
Use -SkipExtraDataDisks to create only the OS disk.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$VBoxManage = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe",

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$VMName = "WIN2019-LAB",

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$BaseFolder = "C:\VM",

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$IsoPath,

    [Parameter()]
    [ValidateRange(2048, 1048576)]
    [int]$MemoryMB = 4096,

    [Parameter()]
    [ValidateRange(1, 64)]
    [int]$CPUs = 2,

    [Parameter()]
    [ValidateRange(20480, 4194304)]
    [int]$DiskSizeMB = 61440,

    [Parameter()]
    [ValidateRange(1024, 4194304)]
    [int]$EDriveSizeMB = 102400,

    [Parameter()]
    [ValidateRange(1024, 4194304)]
    [int]$TDriveSizeMB = 204800,

    [Parameter()]
    [ValidatePattern("^[A-Za-z0-9_-]{1,32}$")]
    [string]$EDriveLabel = "Data",

    [Parameter()]
    [ValidatePattern("^[A-Za-z0-9_-]{1,32}$")]
    [string]$TDriveLabel = "Temp",

    [Parameter()]
    [ValidateRange(1, 99)]
    [int]$ImageIndex = 2,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$GuestUser = "vboxadmin",

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$GuestPassword,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$AdminPassword,

    [Parameter()]
    [ValidatePattern("^[A-Za-z0-9][A-Za-z0-9-]{0,14}$")]
    [string]$GuestHostName = "WIN2019LAB",

    [Parameter()]
    [string]$ProductKey = "",

    [Parameter()]
    [ValidateSet("gui", "headless", "separate")]
    [string]$StartType = "headless",

    [Parameter()]
    [switch]$SkipExtraDataDisks,

    [Parameter()]
    [switch]$Recreate
)

$ErrorActionPreference = "Stop"

function Resolve-ExistingFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return (Resolve-Path -LiteralPath $Path).Path
    }

    throw ("Cannot find {0}: {1}" -f $Description, $Path)
}

function Invoke-VBoxManage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $displayArguments = [string[]]$Arguments.Clone()
    for ($index = 0; $index -lt $displayArguments.Count; $index++) {
        if ($displayArguments[$index] -in @("--password", "--admin-password", "--key")) {
            if (($index + 1) -lt $displayArguments.Count) {
                $displayArguments[$index + 1] = "<redacted>"
            }
        }
    }

    Write-Verbose ("VBoxManage {0}" -f ($displayArguments -join " "))
    $output = & $FilePath @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        $message = ($output | Out-String).Trim()
        if (-not $message) {
            $message = "VBoxManage exited with code $exitCode."
        }

        throw $message
    }

    return $output
}

function Test-VirtualBoxVmExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    & $FilePath showvminfo $Name --machinereadable *> $null
    return ($LASTEXITCODE -eq 0)
}

function Remove-VirtualBoxVm {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    Invoke-VBoxManage -FilePath $FilePath -Arguments @(
        "unregistervm", $Name, "--delete"
    ) | Out-Null
}

$resolvedVBoxManage = Resolve-ExistingFile -Path $VBoxManage -Description "VBoxManage.exe"
$resolvedIsoPath = Resolve-ExistingFile -Path $IsoPath -Description "Windows Server 2019 ISO"

if (-not (Test-Path -LiteralPath $BaseFolder -PathType Container)) {
    New-Item -ItemType Directory -Path $BaseFolder -Force | Out-Null
}

$resolvedBaseFolder = (Resolve-Path -LiteralPath $BaseFolder).Path
$vmDirectory = Join-Path -Path $resolvedBaseFolder -ChildPath $VMName
$diskPath = Join-Path -Path $vmDirectory -ChildPath "$VMName.vdi"
$controllerName = "SATA Controller"
$extraDisks = @()
if (-not $SkipExtraDataDisks) {
    $extraDisks = @(
        [pscustomobject]@{
            DriveLetter = "E"
            Label       = $EDriveLabel
            SizeMB      = $EDriveSizeMB
            Path        = Join-Path -Path $vmDirectory -ChildPath "E-Data.vdi"
            Port        = 2
        },
        [pscustomobject]@{
            DriveLetter = "T"
            Label       = $TDriveLabel
            SizeMB      = $TDriveSizeMB
            Path        = Join-Path -Path $vmDirectory -ChildPath "T-Data.vdi"
            Port        = 3
        }
    )
}

$vmExists = Test-VirtualBoxVmExists -FilePath $resolvedVBoxManage -Name $VMName
if ($vmExists -and -not $Recreate) {
    throw "VM '$VMName' already exists. Use -Recreate only if the existing VM and disk can be deleted."
}

if ((Test-Path -LiteralPath $diskPath -PathType Leaf) -and -not $Recreate) {
    throw "Virtual disk already exists: $diskPath. Use -Recreate only if it can be deleted."
}

foreach ($extraDisk in $extraDisks) {
    if ((Test-Path -LiteralPath $extraDisk.Path -PathType Leaf) -and -not $Recreate) {
        throw "Virtual disk already exists: $($extraDisk.Path). Use -Recreate only if it can be deleted."
    }
}

if ($Recreate) {
    if ($vmExists) {
        Remove-VirtualBoxVm -FilePath $resolvedVBoxManage -Name $VMName
    }

    if (Test-Path -LiteralPath $diskPath -PathType Leaf) {
        Remove-Item -LiteralPath $diskPath -Force
    }

    foreach ($extraDisk in $extraDisks) {
        if (Test-Path -LiteralPath $extraDisk.Path -PathType Leaf) {
            Remove-Item -LiteralPath $extraDisk.Path -Force
        }
    }
}

Invoke-VBoxManage -FilePath $resolvedVBoxManage -Arguments @(
    "createvm",
    "--name", $VMName,
    "--ostype", "Windows2019_64",
    "--basefolder", $resolvedBaseFolder,
    "--register"
) | Out-Null

Invoke-VBoxManage -FilePath $resolvedVBoxManage -Arguments @(
    "modifyvm", $VMName,
    "--memory", "$MemoryMB",
    "--cpus", "$CPUs",
    "--vram", "128",
    "--graphicscontroller", "vboxsvga",
    "--ioapic", "on",
    "--boot1", "dvd",
    "--boot2", "disk",
    "--boot3", "none",
    "--boot4", "none",
    "--nic1", "nat",
    "--audio", "none"
) | Out-Null

Invoke-VBoxManage -FilePath $resolvedVBoxManage -Arguments @(
    "createmedium",
    "disk",
    "--filename", $diskPath,
    "--size", "$DiskSizeMB",
    "--format", "VDI",
    "--variant", "Standard"
) | Out-Null

Invoke-VBoxManage -FilePath $resolvedVBoxManage -Arguments @(
    "storagectl", $VMName,
    "--name", $controllerName,
    "--add", "sata",
    "--controller", "IntelAhci",
    "--portcount", "$(2 + $extraDisks.Count)",
    "--bootable", "on"
) | Out-Null

Invoke-VBoxManage -FilePath $resolvedVBoxManage -Arguments @(
    "storageattach", $VMName,
    "--storagectl", $controllerName,
    "--port", "0",
    "--device", "0",
    "--type", "hdd",
    "--medium", $diskPath
) | Out-Null

Invoke-VBoxManage -FilePath $resolvedVBoxManage -Arguments @(
    "storageattach", $VMName,
    "--storagectl", $controllerName,
    "--port", "1",
    "--device", "0",
    "--type", "dvddrive",
    "--medium", $resolvedIsoPath
) | Out-Null

foreach ($extraDisk in $extraDisks) {
    Invoke-VBoxManage -FilePath $resolvedVBoxManage -Arguments @(
        "createmedium",
        "disk",
        "--filename", $extraDisk.Path,
        "--size", "$($extraDisk.SizeMB)",
        "--format", "VDI",
        "--variant", "Standard"
    ) | Out-Null

    Invoke-VBoxManage -FilePath $resolvedVBoxManage -Arguments @(
        "storageattach", $VMName,
        "--storagectl", $controllerName,
        "--port", "$($extraDisk.Port)",
        "--device", "0",
        "--type", "hdd",
        "--medium", $extraDisk.Path
    ) | Out-Null
}

$detectOutput = Invoke-VBoxManage -FilePath $resolvedVBoxManage -Arguments @(
    "unattended",
    "detect",
    "--iso", $resolvedIsoPath
)

$postInstallCommand = $null
if ($extraDisks.Count -gt 0) {
    $postInstallCommandTemplate = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$rawDisks = Get-Disk | Where-Object PartitionStyle -eq ''RAW'' | Sort-Object Number; $driveMap = @(@{{ Letter = ''E''; Label = ''{0}'' }}, @{{ Letter = ''T''; Label = ''{1}'' }}); for ($i = 0; $i -lt [Math]::Min($rawDisks.Count, $driveMap.Count); $i++) {{ $disk = $rawDisks[$i]; Initialize-Disk -Number $disk.Number -PartitionStyle GPT; New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter $driveMap[$i].Letter | Format-Volume -FileSystem NTFS -NewFileSystemLabel $driveMap[$i].Label -Confirm:$false }}"'
    $postInstallCommand = $postInstallCommandTemplate -f $EDriveLabel, $TDriveLabel
}

$unattendedArguments = @(
    "unattended", "install", $VMName,
    "--iso", $resolvedIsoPath,
    "--user", $GuestUser,
    "--password", $GuestPassword,
    "--admin-password", $AdminPassword,
    "--hostname", $GuestHostName,
    "--image-index", "$ImageIndex",
    "--locale", "en_US",
    "--country", "US",
    "--time-zone", "UTC",
    "--start-vm", $StartType
)

if ($postInstallCommand) {
    $unattendedArguments += @("--post-install-command", $postInstallCommand)
}

if ($ProductKey) {
    $unattendedArguments += @("--key", $ProductKey)
}

$guestAdditionsIso = "C:\Program Files\Oracle\VirtualBox\VBoxGuestAdditions.iso"
$guestAdditionsEnabled = Test-Path -LiteralPath $guestAdditionsIso -PathType Leaf
if ($guestAdditionsEnabled) {
    $unattendedArguments += @("--install-additions", "--additions-iso", $guestAdditionsIso)
} else {
    $unattendedArguments += @("--no-install-additions")
}

Invoke-VBoxManage -FilePath $resolvedVBoxManage -Arguments $unattendedArguments | Out-Null

[pscustomobject]@{
    VMName                = $VMName
    VMFolder              = $vmDirectory
    DiskPath              = $diskPath
    IsoPath               = $resolvedIsoPath
    MemoryMB              = $MemoryMB
    CPUs                  = $CPUs
    DiskSizeMB            = $DiskSizeMB
    ExtraDisks            = $extraDisks
    ImageIndex            = $ImageIndex
    GuestUser             = $GuestUser
    GuestHostName         = $GuestHostName
    PostInstallCommand    = $postInstallCommand
    StartType             = $StartType
    Network               = "NAT"
    BootOrder             = "DVD, Disk"
    GuestAdditionsEnabled = $guestAdditionsEnabled
    VBoxManage            = $resolvedVBoxManage
    DetectOutput          = ($detectOutput | Out-String).Trim()
    NextStep              = "VM '$VMName' has been created and unattended Windows Server 2019 installation has started."
}
