[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateNotNullOrEmpty()]
    [string]$VMName = 'OEL8-R7',

    [ValidateNotNullOrEmpty()]
    [string]$ISOPath = 'C:\ISO\OracleLinux-R8-U7-x86_64-dvd.iso',

    [ValidateNotNullOrEmpty()]
    [string]$VMFolder = 'C:\VM',

    [ValidateRange(1, 64)]
    [int]$CPUCount = 2,

    [ValidateRange(512, 1048576)]
    [int]$MemoryMB = 4096,

    [ValidateRange(1024, 2097152)]
    [int]$DiskSizeMB = 102400,

    [ValidateSet('nat')]
    [string]$NetworkMode = 'nat',

    [ValidateSet('gui', 'headless')]
    [string]$StartType = 'gui'
)

$ErrorActionPreference = 'Stop'

function Get-VBoxManagePath {
    $candidates = @()

    if ($env:ProgramFiles) {
        $candidates += (Join-Path -Path $env:ProgramFiles -ChildPath 'Oracle\VirtualBox\VBoxManage.exe')
    }

    $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if ($programFilesX86) {
        $candidates += (Join-Path -Path $programFilesX86 -ChildPath 'Oracle\VirtualBox\VBoxManage.exe')
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $command = Get-Command -Name 'VBoxManage.exe' -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    throw 'VBoxManage.exe was not found. Install VirtualBox or add VBoxManage.exe to PATH.'
}

function ConvertTo-WindowsCommandLineArgument {
    param(
        [AllowEmptyString()]
        [string]$Argument
    )

    if ($null -eq $Argument) {
        return '""'
    }

    if ($Argument -ne '' -and $Argument -notmatch '[\s"]') {
        return $Argument
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashCount = 0

    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq '\') {
            $backslashCount++
            continue
        }

        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($backslashCount * 2) + 1)))
            [void]$builder.Append('"')
            $backslashCount = 0
            continue
        }

        if ($backslashCount -gt 0) {
            [void]$builder.Append(('\' * $backslashCount))
            $backslashCount = 0
        }

        [void]$builder.Append($character)
    }

    if ($backslashCount -gt 0) {
        [void]$builder.Append(('\' * ($backslashCount * 2)))
    }

    [void]$builder.Append('"')
    return $builder.ToString()
}

function Join-WindowsCommandLine {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    return (($Arguments | ForEach-Object { ConvertTo-WindowsCommandLineArgument -Argument $_ }) -join ' ')
}

function Invoke-VBoxManage {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $script:VBoxManage
    $startInfo.Arguments = Join-WindowsCommandLine -Arguments $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    try {
        if (-not $process.Start()) {
            throw 'Failed to start VBoxManage.exe.'
        }

        $stdout = $process.StandardOutput.ReadToEnd()
        $stderrText = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $exitCode = $process.ExitCode
    } finally {
        if ($process) {
            $process.Dispose()
        }
    }

    $output = @()
    if ($stdout) {
        $output = $stdout -split '\r?\n' | Where-Object { $_ -ne '' }
    }

    $stderr = @()
    if ($stderrText) {
        $stderr = $stderrText -split '\r?\n' | Where-Object { $_ -ne '' }
    }

    if ($exitCode -ne 0) {
        $message = (@($output) + @($stderr) | Out-String).Trim()
        throw "VBoxManage failed with exit code ${exitCode}: $($Arguments -join ' ')`n$message"
    }

    $nonProgressStderr = $stderr | Where-Object {
        $line = $_.Trim()
        $line -ne '' -and $line -notmatch '^\d+%(\.\.\.\d+%)*$'
    }

    return @($output) + @($nonProgressStderr)
}

function Assert-ContainsLine {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Lines,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedLine,

        [Parameter(Mandatory = $true)]
        [string]$FailureMessage
    )

    if ($Lines -notcontains $ExpectedLine) {
        throw $FailureMessage
    }
}

$script:VBoxManage = Get-VBoxManagePath

if (-not (Test-Path -LiteralPath $ISOPath -PathType Leaf)) {
    throw "ISO not found: $ISOPath"
}

if (Test-Path -LiteralPath $VMFolder -PathType Leaf) {
    throw "VM folder path points to a file: $VMFolder"
}

$resolvedIsoPath = (Resolve-Path -LiteralPath $ISOPath).Path
if (Test-Path -LiteralPath $VMFolder -PathType Container) {
    $vmRoot = (Resolve-Path -LiteralPath $VMFolder).Path
} else {
    $vmRoot = [System.IO.Path]::GetFullPath($VMFolder)
}

$vmDirectory = Join-Path -Path $vmRoot -ChildPath $VMName
$diskPath = Join-Path -Path $vmDirectory -ChildPath "$VMName.vdi"

$vmList = Invoke-VBoxManage -Arguments @('list', 'vms')
$vmPattern = '^"' + [regex]::Escape($VMName) + '"\s+\{'
if ($vmList | Where-Object { $_ -match $vmPattern }) {
    throw "VM '$VMName' already exists. Choose a different VM name or manually remove the existing VM."
}

if (Test-Path -LiteralPath $diskPath) {
    throw "Target VDI already exists: $diskPath. Choose a different VM name or manually remove the existing disk."
}

$target = "VirtualBox VM '$VMName' with disk '$diskPath'"
if (-not $PSCmdlet.ShouldProcess($target, 'Create Oracle Linux VM and start installer')) {
    Write-Output "Validated inputs. No VM was created."
    Write-Output "VBoxManage: $script:VBoxManage"
    Write-Output "ISO: $resolvedIsoPath"
    Write-Output "VM folder: $vmRoot"
    Write-Output "Disk: $diskPath"
    return
}

Write-Output "Creating VM '$VMName'..."
$vmRoot = (New-Item -ItemType Directory -Force -Path $VMFolder).FullName
Invoke-VBoxManage -Arguments @('createvm', '--name', $VMName, '--ostype', 'Oracle8_64', '--basefolder', $vmRoot, '--register') | Write-Output

Invoke-VBoxManage -Arguments @(
    'modifyvm', $VMName,
    '--cpus', $CPUCount,
    '--memory', $MemoryMB,
    '--vram', '128',
    '--nic1', $NetworkMode,
    '--boot1', 'dvd',
    '--boot2', 'disk',
    '--boot3', 'none',
    '--boot4', 'none',
    '--ioapic', 'on',
    '--pae', 'on',
    '--rtcuseutc', 'on',
    '--graphicscontroller', 'vmsvga'
) | Out-Null

Invoke-VBoxManage -Arguments @('createhd', '--filename', $diskPath, '--size', $DiskSizeMB, '--format', 'VDI', '--variant', 'Standard') | Write-Output
Invoke-VBoxManage -Arguments @('storagectl', $VMName, '--name', 'SATA Controller', '--add', 'sata', '--controller', 'IntelAhci', '--portcount', '4', '--bootable', 'on') | Out-Null
Invoke-VBoxManage -Arguments @('storageattach', $VMName, '--storagectl', 'SATA Controller', '--port', '0', '--device', '0', '--type', 'hdd', '--medium', $diskPath) | Out-Null
Invoke-VBoxManage -Arguments @('storageattach', $VMName, '--storagectl', 'SATA Controller', '--port', '1', '--device', '0', '--type', 'dvddrive', '--medium', $resolvedIsoPath) | Out-Null
Invoke-VBoxManage -Arguments @('startvm', $VMName, '--type', $StartType) | Write-Output

$vmInfo = Invoke-VBoxManage -Arguments @('showvminfo', $VMName, '--machinereadable')
$diskInfo = Invoke-VBoxManage -Arguments @('showmediuminfo', $diskPath)
$escapedIsoPath = $resolvedIsoPath.Replace('\', '\\')

Assert-ContainsLine -Lines $vmInfo -ExpectedLine "name=`"$VMName`"" -FailureMessage 'VM name validation failed.'
Assert-ContainsLine -Lines $vmInfo -ExpectedLine 'ostype="Oracle Linux 8.x (64-bit)"' -FailureMessage 'Oracle Linux OS type validation failed.'
Assert-ContainsLine -Lines $vmInfo -ExpectedLine "memory=$MemoryMB" -FailureMessage 'Memory validation failed.'
Assert-ContainsLine -Lines $vmInfo -ExpectedLine "cpus=$CPUCount" -FailureMessage 'CPU validation failed.'
Assert-ContainsLine -Lines $vmInfo -ExpectedLine 'boot1="dvd"' -FailureMessage 'DVD boot order validation failed.'
Assert-ContainsLine -Lines $vmInfo -ExpectedLine 'boot2="disk"' -FailureMessage 'Disk boot order validation failed.'
Assert-ContainsLine -Lines $vmInfo -ExpectedLine 'nic1="nat"' -FailureMessage 'NAT networking validation failed.'

if (-not ($vmInfo | Where-Object { $_ -match [regex]::Escape($escapedIsoPath) })) {
    throw 'ISO attachment validation failed.'
}

if (-not ($diskInfo | Where-Object { $_ -match '^Format variant:\s+dynamic' })) {
    throw 'Dynamic VDI validation failed.'
}

if (-not ($diskInfo | Where-Object { $_ -match "^Capacity:\s+$DiskSizeMB MBytes" })) {
    throw 'VDI capacity validation failed.'
}

Write-Output ''
Write-Output '[OK] Oracle Linux VM was created and started.'
Write-Output ''
Write-Output 'VM summary:'
$vmInfo | Where-Object {
    $_ -match '^(name=|ostype=|memory=|cpus=|boot1=|boot2=|VMState=|nic1=|storagecontrollername0=|"SATA Controller-)'
} | Write-Output

Write-Output ''
Write-Output 'Disk summary:'
$diskInfo | Where-Object {
    $_ -match '^(UUID:|State:|Type:|Location:|Storage format:|Format variant:|Capacity:|Size on disk:|In use by VMs:)'
} | Write-Output
