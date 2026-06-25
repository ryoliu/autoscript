[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$LogRoot = 'C:\autoscript\logs\OsCheck'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-CheckResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Category,

        [Parameter(Mandatory = $true)]
        [string]$Check,

        [Parameter(Mandatory = $true)]
        [bool]$Passed,

        [Parameter(Mandatory = $true)]
        [string]$Details
    )

    [pscustomobject]@{
        Category = $Category
        Check   = $Check
        Passed  = $Passed
        Details = $Details
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-CheckResults {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Results
    )

    foreach ($category in @('Pre-Install', 'Post-Install')) {
        $categoryResults = @($Results | Where-Object { $_.Category -eq $category })

        if ($categoryResults.Count -eq 0) {
            continue
        }

        Write-Host "=== $category ===" -ForegroundColor Cyan

        foreach ($result in $categoryResults) {
            $status = if ($result.Passed) { 'PASS' } else { 'FAIL' }
            $color = if ($result.Passed) { 'Green' } else { 'Red' }

            Write-Host ("[{0}] {1}" -f $status, $result.Check) -ForegroundColor $color
            Write-Host ("      {0}" -f $result.Details) -ForegroundColor $color
            Write-Host ''
        }

        Write-Host ''
    }
}

function Start-CheckTranscript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $transcriptPath = Join-Path -Path $Path -ChildPath "Test-OsSqlServerPrerequisites-$timestamp.log"

    Start-Transcript -Path $transcriptPath -Force | Out-Null

    return $transcriptPath
}

function Resolve-AccountSid {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Account
    )

    try {
        return ([Security.Principal.NTAccount]$Account).Translate([Security.Principal.SecurityIdentifier]).Value
    }
    catch {
        if ($Account -match '^NT Service\\(.+)$') {
            $serviceName = $matches[1]
            $scOutput = & sc.exe showsid $serviceName 2>$null
            $serviceSid = $scOutput | Select-String -Pattern 'S-1-5-80-[0-9-]+' | Select-Object -First 1

            if ($null -ne $serviceSid) {
                return $serviceSid.Matches[0].Value
            }
        }

        return $null
    }
}

function Export-UserRightsAssignments {
    $tempFile = Join-Path -Path $env:TEMP -ChildPath ("autoscript-user-rights-{0}.inf" -f ([guid]::NewGuid().ToString('N')))

    try {
        $output = & secedit.exe /export /cfg $tempFile /areas USER_RIGHTS 2>&1

        if ($LASTEXITCODE -ne 0) {
            throw "secedit export failed with exit code $LASTEXITCODE. $output"
        }

        $rights = @{}

        foreach ($line in Get-Content -LiteralPath $tempFile) {
            if ($line -notmatch '^(Se[A-Za-z]+Privilege)\s*=\s*(.*)$') {
                continue
            }

            $rightName = $matches[1]
            $assignedValues = @()

            if (-not [string]::IsNullOrWhiteSpace($matches[2])) {
                $assignedValues = $matches[2].Split(',') |
                    ForEach-Object { $_.Trim().TrimStart('*') } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            }

            $rights[$rightName] = $assignedValues
        }

        return $rights
    }
    finally {
        if (Test-Path -LiteralPath $tempFile -PathType Leaf) {
            Remove-Item -LiteralPath $tempFile -Force
        }
    }
}

function Test-RequiredUserRightAssignment {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Rights,

        [Parameter(Mandatory = $true)]
        [string]$RightName,

        [Parameter(Mandatory = $true)]
        [string[]]$Accounts
    )

    if (-not $Rights.ContainsKey($RightName)) {
        return [pscustomobject]@{
            Passed  = $false
            Details = "$RightName is not assigned to any account. Required accounts: $($Accounts -join ', ')"
        }
    }

    $assigned = @($Rights[$RightName])
    $assignedNormalized = $assigned | ForEach-Object { $_.ToUpperInvariant() }
    $missingAccounts = New-Object System.Collections.ArrayList

    foreach ($account in $Accounts) {
        $accountSid = Resolve-AccountSid -Account $account

        if ([string]::IsNullOrWhiteSpace($accountSid)) {
            [void]$missingAccounts.Add("$account (SID not resolved)")
            continue
        }

        $accountNormalized = $account.ToUpperInvariant()
        $accountSidNormalized = $accountSid.ToUpperInvariant()

        if ($assignedNormalized -notcontains $accountNormalized -and $assignedNormalized -notcontains $accountSidNormalized) {
            [void]$missingAccounts.Add($account)
        }
    }

    $passed = ($missingAccounts.Count -eq 0)

    return [pscustomobject]@{
        Passed  = $passed
        Details = if ($passed) {
            "Required accounts are assigned: $($Accounts -join ', ')"
        }
        else {
            "Missing required accounts: $($missingAccounts -join ', '). Required: $($Accounts -join ', ')"
        }
    }
}

$results = New-Object System.Collections.ArrayList
$transcriptStarted = $false
$logPath = $null

try {
    $logPath = Start-CheckTranscript -Path $LogRoot
    $transcriptStarted = $true
    Write-Host "Check log: $logPath"

    if (-not (Test-IsAdministrator)) {
        Write-Warning 'Run this script from an elevated PowerShell session. Disk and local security policy checks require administrator permission.'

        [void]$results.Add((New-CheckResult `
            -Category 'Pre-Install' `
            -Check 'Run as administrator' `
            -Passed $false `
            -Details 'Run this script from an elevated PowerShell session. Disk and local security policy checks require administrator permission.'))

        Write-CheckResults -Results @($results)
        exit 1
    }

$disksToCheck = Get-Disk -ErrorAction Stop |
    Where-Object {
        $_.Number -ne 0 -and
        $_.PartitionStyle -ne 'RAW' -and
        $_.BusType -notin @('CDROM', 'DVD')
    }

$nonGptDisks = @($disksToCheck | Where-Object { $_.PartitionStyle -ne 'GPT' })

[void]$results.Add((New-CheckResult `
    -Category 'Pre-Install' `
    -Check 'Disk partition style is GPT' `
    -Passed ($nonGptDisks.Count -eq 0) `
    -Details $(if ($nonGptDisks.Count -eq 0) {
        'All checked initialized non-CD-ROM disks are GPT. Excluded: Disk 0.'
    }
    else {
        'Non-GPT disks: ' + (($nonGptDisks | ForEach-Object { "Disk $($_.Number)=$($_.PartitionStyle)" }) -join '; ')
    })))

$driveLetterToDiskNumber = @{}

Get-Partition -ErrorAction Stop |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_.DriveLetter) } |
    ForEach-Object {
        $driveLetterToDiskNumber[$_.DriveLetter.ToString().ToUpperInvariant()] = $_.DiskNumber
    }

$volumesToCheck = Get-CimInstance -ClassName Win32_Volume -ErrorAction Stop |
    Where-Object {
        if ($_.DriveType -eq 5 -or [string]::IsNullOrWhiteSpace($_.DriveLetter) -or $null -eq $_.BlockSize) {
            return $false
        }

        $driveLetter = $_.DriveLetter.TrimEnd(':').ToUpperInvariant()

        $driveLetterToDiskNumber.ContainsKey($driveLetter) -and
        $driveLetterToDiskNumber[$driveLetter] -ne 0
    }

$non64KVolumes = @($volumesToCheck | Where-Object { [int64]$_.BlockSize -ne 65536 })
$nonNtfsVolumes = @($volumesToCheck | Where-Object { $_.FileSystem -ne 'NTFS' })

[void]$results.Add((New-CheckResult `
    -Category 'Pre-Install' `
    -Check 'Volume allocation unit size is 64KB' `
    -Passed ($non64KVolumes.Count -eq 0) `
    -Details $(if ($non64KVolumes.Count -eq 0) {
        'All checked volumes use 64KB allocation units. Excluded: Disk 0 and CD-ROM volumes.'
    }
    else {
        'Non-64KB volumes: ' + (($non64KVolumes | ForEach-Object { "$($_.DriveLetter)=$($_.BlockSize) bytes" }) -join '; ')
    })))

[void]$results.Add((New-CheckResult `
    -Category 'Pre-Install' `
    -Check 'Volume file system is NTFS' `
    -Passed ($nonNtfsVolumes.Count -eq 0) `
    -Details $(if ($nonNtfsVolumes.Count -eq 0) {
        'All checked volumes use NTFS. Excluded: Disk 0 and CD-ROM volumes.'
    }
    else {
        'Non-NTFS volumes: ' + (($nonNtfsVolumes | ForEach-Object { "$($_.DriveLetter)=$($_.FileSystem)" }) -join '; ')
    })))

$firewallProfiles = @(Get-NetFirewallProfile -ErrorAction Stop)
$enabledFirewallProfiles = @($firewallProfiles | Where-Object { $_.Enabled })

[void]$results.Add((New-CheckResult `
    -Category 'Post-Install' `
    -Check 'Windows Firewall profiles are disabled' `
    -Passed ($enabledFirewallProfiles.Count -eq 0) `
    -Details $(if ($enabledFirewallProfiles.Count -eq 0) {
        'All firewall profiles are disabled.'
    }
    else {
        'Enabled profiles: ' + (($enabledFirewallProfiles | Select-Object -ExpandProperty Name) -join ', ')
    })))

$activePowerPlan = (& powercfg.exe /GETACTIVESCHEME) -join ' '
$highPerformanceGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$isHighPerformance = $activePowerPlan -match $highPerformanceGuid -or $activePowerPlan -match 'High performance'
$activePowerPlanName = if ($activePowerPlan -match '\(([^)]+)\)') { $matches[1] } else { $activePowerPlan.Trim() }

[void]$results.Add((New-CheckResult `
    -Category 'Post-Install' `
    -Check 'Power plan is High performance' `
    -Passed $isHighPerformance `
    -Details $(if ($isHighPerformance) {
        'Current power plan is High performance.'
    }
    else {
        "Current power plan is $activePowerPlanName."
    })))

$uacPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$uac = Get-ItemProperty -LiteralPath $uacPath -ErrorAction Stop
$enableLua = [int]$uac.EnableLUA
$consentPromptBehaviorAdmin = [int]$uac.ConsentPromptBehaviorAdmin
$promptOnSecureDesktop = [int]$uac.PromptOnSecureDesktop
$uacNeverNotify = ($enableLua -eq 0) -or ($consentPromptBehaviorAdmin -eq 0 -and $promptOnSecureDesktop -eq 0)

[void]$results.Add((New-CheckResult `
    -Category 'Post-Install' `
    -Check 'UAC is Never notify' `
    -Passed $uacNeverNotify `
    -Details $(if ($uacNeverNotify) {
        'UAC is set to Never notify.'
    }
    else {
        'UAC is not set to Never notify.'
    })))

$rights = Export-UserRightsAssignments
$rightChecks = @(
    [pscustomobject]@{
        CheckName = 'Perform volume maintenance tasks for SQL Server service'
        RightName = 'SeManageVolumePrivilege'
        Accounts = @('NT Service\MSSQLSERVER')
    },
    [pscustomobject]@{
        CheckName = 'Lock pages in memory for SQL Server service'
        RightName = 'SeLockMemoryPrivilege'
        Accounts = @('NT Service\MSSQLSERVER')
    },
    [pscustomobject]@{
        CheckName = 'Bypass traverse checking for SQL Server services'
        RightName = 'SeChangeNotifyPrivilege'
        Accounts = @('NT Service\MSSQLSERVER', 'NT Service\SQLSERVERAGENT')
    }
)

foreach ($rightCheck in $rightChecks) {
    $rightResult = Test-RequiredUserRightAssignment `
        -Rights $rights `
        -RightName $rightCheck.RightName `
        -Accounts $rightCheck.Accounts

    [void]$results.Add((New-CheckResult `
        -Category 'Post-Install' `
        -Check $rightCheck.CheckName `
        -Passed $rightResult.Passed `
        -Details $rightResult.Details))
}

    Write-CheckResults -Results @($results)

    if ($results | Where-Object { -not $_.Passed }) {
        exit 1
    }
}
finally {
    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
        Write-Host "Check log saved to: $logPath"
    }
}
