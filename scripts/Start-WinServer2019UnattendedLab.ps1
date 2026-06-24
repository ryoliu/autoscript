[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$IsoPath,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$VBoxManage = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe",

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$VMName = "WIN2019-LAB",

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$BaseFolder = "C:\VM",

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

    [Parameter()]
    [string]$GuestPassword,

    [Parameter()]
    [string]$AdminPassword,

    [Parameter()]
    [ValidatePattern("^[A-Za-z0-9][A-Za-z0-9-]{0,14}$")]
    [string]$GuestHostName = "WIN2019LAB",

    [Parameter()]
    [string]$ProductKey = "",

    [Parameter()]
    [ValidateSet("gui", "headless", "separate")]
    [string]$StartType = "gui",

    [Parameter()]
    [switch]$SkipExtraDataDisks,

    [Parameter()]
    [switch]$Recreate
)

$ErrorActionPreference = "Stop"

function ConvertTo-PlainText {
    param(
        [Parameter(Mandatory = $true)]
        [Security.SecureString]$SecureString
    )

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

$scriptPath = Join-Path -Path $PSScriptRoot -ChildPath "New-VirtualBoxWinServer2019UnattendedVm.ps1"
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw "Cannot find unattended VM script: $scriptPath"
}

if (-not $GuestPassword) {
    $GuestPassword = ConvertTo-PlainText -SecureString (Read-Host -Prompt "Guest user password" -AsSecureString)
}

if (-not $AdminPassword) {
    $AdminPassword = ConvertTo-PlainText -SecureString (Read-Host -Prompt "Administrator password" -AsSecureString)
}

$arguments = @{
    VBoxManage    = $VBoxManage
    VMName        = $VMName
    BaseFolder    = $BaseFolder
    IsoPath       = $IsoPath
    MemoryMB      = $MemoryMB
    CPUs          = $CPUs
    DiskSizeMB    = $DiskSizeMB
    EDriveSizeMB  = $EDriveSizeMB
    TDriveSizeMB  = $TDriveSizeMB
    EDriveLabel   = $EDriveLabel
    TDriveLabel   = $TDriveLabel
    ImageIndex    = $ImageIndex
    GuestUser     = $GuestUser
    GuestPassword = $GuestPassword
    AdminPassword = $AdminPassword
    GuestHostName = $GuestHostName
    ProductKey    = $ProductKey
    StartType     = $StartType
}

if ($SkipExtraDataDisks) {
    $arguments.SkipExtraDataDisks = $true
}

if ($Recreate) {
    $arguments.Recreate = $true
}

& $scriptPath @arguments
