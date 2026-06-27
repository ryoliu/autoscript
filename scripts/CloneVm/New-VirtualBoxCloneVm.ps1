param(
    [string]$SourceVmName = 'WIN2019-LAB',
    [string]$CloneVmName = 'WIN2019-LAB2',
    [string]$BaseFolder = 'C:\VM',
    [string]$VBoxManagePath = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe',
    [switch]$DeleteExistingClone,
    [switch]$StartAfterClone
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-VBoxManage {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    Write-Host "VBoxManage $($Arguments -join ' ')"
    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $VBoxManagePath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }

    if ($exitCode -ne 0) {
        throw "VBoxManage failed with exit code $exitCode. Output: $($output -join ' ')"
    }

    return $output
}

function Test-VmExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName
    )

    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $VBoxManagePath showvminfo $VmName --machinereadable *> $null
    }
    finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }

    return $LASTEXITCODE -eq 0
}

function Get-VmState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName
    )

    $info = Invoke-VBoxManage -Arguments @('showvminfo', $VmName, '--machinereadable')
    $stateLine = $info | Where-Object { $_ -match '^VMState=' } | Select-Object -First 1
    if ($stateLine -match '^VMState="?(.*?)"?$') {
        return $matches[1]
    }

    return 'unknown'
}

function Get-EnabledNicSlots {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName
    )

    $info = Invoke-VBoxManage -Arguments @('showvminfo', $VmName, '--machinereadable')
    foreach ($line in $info) {
        if ($line -match '^nic([1-8])="?(?!none)([^"]+)"?$') {
            [int]$matches[1]
        }
    }
}

if (-not (Test-Path -LiteralPath $VBoxManagePath)) {
    throw "VBoxManage.exe not found: $VBoxManagePath"
}

if (-not (Test-Path -LiteralPath $BaseFolder)) {
    throw "BaseFolder not found: $BaseFolder"
}

if (-not (Test-VmExists -VmName $SourceVmName)) {
    throw "Source VM not found: $SourceVmName"
}

$sourceState = Get-VmState -VmName $SourceVmName
if ($sourceState -ne 'poweroff') {
    throw "Source VM '$SourceVmName' must be poweroff before clone. Current state: $sourceState"
}

$cloneExists = Test-VmExists -VmName $CloneVmName
if ($cloneExists) {
    if (-not $DeleteExistingClone) {
        throw "Clone VM already exists: $CloneVmName. Re-run with -DeleteExistingClone only if it is safe to delete it."
    }

    $cloneState = Get-VmState -VmName $CloneVmName
    if ($cloneState -eq 'running') {
        Invoke-VBoxManage -Arguments @('controlvm', $CloneVmName, 'poweroff') | Out-Null
    }

    Invoke-VBoxManage -Arguments @('unregistervm', $CloneVmName, '--delete') | Out-Null
}

$clonePath = Join-Path -Path $BaseFolder -ChildPath $CloneVmName
if (Test-Path -LiteralPath $clonePath) {
    if (-not $DeleteExistingClone) {
        throw "Clone folder already exists: $clonePath. Remove it manually or re-run with -DeleteExistingClone if it belongs to the clone."
    }
}

Invoke-VBoxManage -Arguments @(
    'clonevm',
    $SourceVmName,
    '--name',
    $CloneVmName,
    '--basefolder',
    $BaseFolder,
    '--register',
    '--mode',
    'machine'
) | Out-Host

$enabledNicSlots = @(Get-EnabledNicSlots -VmName $CloneVmName)
if ($enabledNicSlots.Count -gt 0) {
    $macArgs = @('modifyvm', $CloneVmName)
    foreach ($slot in $enabledNicSlots) {
        $macArgs += "--macaddress$slot"
        $macArgs += 'auto'
    }

    Invoke-VBoxManage -Arguments $macArgs | Out-Null
}

if ($StartAfterClone) {
    Invoke-VBoxManage -Arguments @('startvm', $CloneVmName, '--type', 'gui') | Out-Host
}

$reportScript = Join-Path -Path $PSScriptRoot -ChildPath 'Get-VirtualBoxCloneReport.ps1'
if (Test-Path -LiteralPath $reportScript) {
    & $reportScript -SourceVmName $SourceVmName -CloneVmName $CloneVmName -VBoxManagePath $VBoxManagePath
}
else {
    Invoke-VBoxManage -Arguments @('showvminfo', $CloneVmName, '--machinereadable') | Out-Host
}
