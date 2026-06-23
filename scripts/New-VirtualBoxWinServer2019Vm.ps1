[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$VMName = "WinSrv2019-Lab",

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$IsoPath,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$VMFolder = "C:\VirtualBox VMs",

    [Parameter()]
    [string]$VBoxManagePath,

    [Parameter()]
    [ValidateRange(2048, 1048576)]
    [int]$MemoryMB = 4096,

    [Parameter()]
    [ValidateRange(1, 64)]
    [int]$CpuCount = 2,

    [Parameter()]
    [ValidateRange(20, 4096)]
    [int]$DiskGB = 80
)

$ErrorActionPreference = "Stop"

function Resolve-VBoxManage {
    param(
        [string]$ExplicitPath
    )

    if ($ExplicitPath) {
        if (Test-Path -LiteralPath $ExplicitPath -PathType Leaf) {
            return (Resolve-Path -LiteralPath $ExplicitPath).Path
        }

        throw "VBoxManage.exe was not found at the provided path: $ExplicitPath"
    }

    $command = Get-Command VBoxManage.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $defaultPath = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
    if (Test-Path -LiteralPath $defaultPath -PathType Leaf) {
        return $defaultPath
    }

    throw "VBoxManage.exe was not found. Install Oracle VirtualBox or pass -VBoxManagePath."
}

function Invoke-VBoxManage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    Write-Verbose ("VBoxManage {0}" -f ($Arguments -join " "))
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

$resolvedIsoPath = if (Test-Path -LiteralPath $IsoPath -PathType Leaf) {
    (Resolve-Path -LiteralPath $IsoPath).Path
} else {
    throw "ISO file was not found: $IsoPath"
}

$resolvedVBoxManagePath = Resolve-VBoxManage -ExplicitPath $VBoxManagePath

if (Test-VirtualBoxVmExists -FilePath $resolvedVBoxManagePath -Name $VMName) {
    throw "A VirtualBox VM named '$VMName' already exists. Choose another -VMName or remove the existing VM manually."
}

if (-not (Test-Path -LiteralPath $VMFolder -PathType Container)) {
    New-Item -ItemType Directory -Path $VMFolder -Force | Out-Null
}

$resolvedVMFolder = (Resolve-Path -LiteralPath $VMFolder).Path
$vmDirectory = Join-Path -Path $resolvedVMFolder -ChildPath $VMName
$diskPath = Join-Path -Path $vmDirectory -ChildPath "$VMName.vdi"
$diskSizeMB = $DiskGB * 1024
$controllerName = "SATA Controller"

Invoke-VBoxManage -FilePath $resolvedVBoxManagePath -Arguments @(
    "createvm", "--name", $VMName, "--ostype", "Windows2019_64", "--basefolder", $resolvedVMFolder, "--register"
) | Out-Null

Invoke-VBoxManage -FilePath $resolvedVBoxManagePath -Arguments @(
    "modifyvm", $VMName,
    "--memory", "$MemoryMB",
    "--cpus", "$CpuCount",
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

Invoke-VBoxManage -FilePath $resolvedVBoxManagePath -Arguments @(
    "createhd", "--filename", $diskPath, "--size", "$diskSizeMB", "--format", "VDI", "--variant", "Standard"
) | Out-Null

Invoke-VBoxManage -FilePath $resolvedVBoxManagePath -Arguments @(
    "storagectl", $VMName, "--name", $controllerName, "--add", "sata", "--controller", "IntelAhci", "--portcount", "2", "--bootable", "on"
) | Out-Null

Invoke-VBoxManage -FilePath $resolvedVBoxManagePath -Arguments @(
    "storageattach", $VMName, "--storagectl", $controllerName, "--port", "0", "--device", "0", "--type", "hdd", "--medium", $diskPath
) | Out-Null

Invoke-VBoxManage -FilePath $resolvedVBoxManagePath -Arguments @(
    "storageattach", $VMName, "--storagectl", $controllerName, "--port", "1", "--device", "0", "--type", "dvddrive", "--medium", $resolvedIsoPath
) | Out-Null

Invoke-VBoxManage -FilePath $resolvedVBoxManagePath -Arguments @(
    "startvm", $VMName, "--type", "gui"
) | Out-Null

[pscustomobject]@{
    VMName            = $VMName
    VMFolder          = $resolvedVMFolder
    DiskPath          = $diskPath
    IsoPath           = $resolvedIsoPath
    MemoryMB          = $MemoryMB
    CpuCount          = $CpuCount
    DiskGB            = $DiskGB
    Network           = "NAT"
    BootOrder         = "DVD, Disk"
    VBoxManagePath    = $resolvedVBoxManagePath
    ManualInstallMode = $true
    Started           = $true
}
