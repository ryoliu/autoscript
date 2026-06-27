param(
    [Parameter(Mandatory = $true)]
    [string]$SourceVmName,

    [Parameter(Mandatory = $true)]
    [string]$CloneVmName,

    [string]$VBoxManagePath = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-VBoxMachineInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName
    )

    $raw = & $VBoxManagePath showvminfo $VmName --machinereadable 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read VM '$VmName'. VBoxManage output: $($raw -join ' ')"
    }

    $info = [ordered]@{}
    foreach ($line in $raw) {
        if ($line -match '^([^=]+)=(.*)$') {
            $key = $matches[1]
            $value = $matches[2].Trim('"')
            $info[$key] = $value
        }
    }

    return [pscustomobject]$info
}

function Get-NicSummary {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Info
    )

    $items = foreach ($slot in 1..8) {
        $nicKey = "nic$slot"
        $macKey = "macaddress$slot"
        if ($Info.PSObject.Properties.Name -contains $nicKey -and $Info.$nicKey -ne 'none') {
            [pscustomobject]@{
                Slot = $slot
                Mode = $Info.$nicKey
                Mac  = if ($Info.PSObject.Properties.Name -contains $macKey) { $Info.$macKey } else { '' }
            }
        }
    }

    return @($items)
}

if (-not (Test-Path -LiteralPath $VBoxManagePath)) {
    throw "VBoxManage.exe not found: $VBoxManagePath"
}

$source = Get-VBoxMachineInfo -VmName $SourceVmName
$clone = Get-VBoxMachineInfo -VmName $CloneVmName
$sourceNics = Get-NicSummary -Info $source
$cloneNics = Get-NicSummary -Info $clone

$macComparison = foreach ($cloneNic in $cloneNics) {
    $sourceNic = $sourceNics | Where-Object { $_.Slot -eq $cloneNic.Slot } | Select-Object -First 1
    [pscustomobject]@{
        Slot = $cloneNic.Slot
        SourceMode = if ($sourceNic) { $sourceNic.Mode } else { '' }
        SourceMac = if ($sourceNic) { $sourceNic.Mac } else { '' }
        CloneMode = $cloneNic.Mode
        CloneMac = $cloneNic.Mac
        MacIsDifferent = if ($sourceNic) { $sourceNic.Mac -ne $cloneNic.Mac } else { $true }
    }
}

[pscustomobject]@{
    SourceVm = [pscustomobject]@{
        Name = $source.name
        UUID = $source.UUID
        CfgFile = $source.CfgFile
        State = $source.VMState
        Nics = $sourceNics
    }
    CloneVm = [pscustomobject]@{
        Name = $clone.name
        UUID = $clone.UUID
        CfgFile = $clone.CfgFile
        State = $clone.VMState
        Nics = $cloneNics
    }
    MacComparison = $macComparison
    AllComparedMacsDifferent = -not ($macComparison | Where-Object { -not $_.MacIsDifferent })
}

