[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$LogRoot = 'C:\autoscript\logs\OsRemediation'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-RemediationTranscript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $transcriptPath = Join-Path -Path $Path -ChildPath "Set-OsSqlServerPrerequisites-$timestamp.log"
    Start-Transcript -Path $transcriptPath -Force | Out-Null
    return $transcriptPath
}

function Write-Status {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter()]
        [ConsoleColor]$Color = 'White'
    )

    Write-Host $Message -ForegroundColor $Color
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

        throw "Could not resolve account SID: $Account"
    }
}

function Export-PrivilegeRights {
    $tempFile = Join-Path -Path $env:TEMP -ChildPath ("autoscript-rights-export-{0}.inf" -f ([guid]::NewGuid().ToString('N')))

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
            $values = @()

            if (-not [string]::IsNullOrWhiteSpace($matches[2])) {
                $values = $matches[2].Split(',') |
                    ForEach-Object { $_.Trim() } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            }

            $rights[$rightName] = @($values)
        }

        return $rights
    }
    finally {
        if (Test-Path -LiteralPath $tempFile -PathType Leaf) {
            Remove-Item -LiteralPath $tempFile -Force
        }
    }
}

function ConvertTo-SeceditValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $trimmedValue = $Value.Trim()

    if ($trimmedValue -match '^\*?S-\d-') {
        return '*' + $trimmedValue.TrimStart('*')
    }

    return $trimmedValue
}

function Add-PrivilegeRightAccounts {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RightName,

        [Parameter(Mandatory = $true)]
        [string[]]$Accounts
    )

    $rights = Export-PrivilegeRights
    $existingValues = New-Object System.Collections.ArrayList

    if ($rights.ContainsKey($RightName)) {
        foreach ($value in @($rights[$RightName])) {
            [void]$existingValues.Add((ConvertTo-SeceditValue -Value $value))
        }
    }

    foreach ($account in $Accounts) {
        $accountSid = Resolve-AccountSid -Account $account
        $sidValue = ConvertTo-SeceditValue -Value $accountSid

        if (@($existingValues | ForEach-Object { $_.ToUpperInvariant() }) -notcontains $sidValue.ToUpperInvariant()) {
            [void]$existingValues.Add($sidValue)
        }
    }

    $uniqueValues = @($existingValues | Select-Object -Unique)
    $infPath = Join-Path -Path $env:TEMP -ChildPath ("autoscript-rights-apply-{0}.inf" -f ([guid]::NewGuid().ToString('N')))
    $dbPath = Join-Path -Path $env:TEMP -ChildPath ("autoscript-rights-apply-{0}.sdb" -f ([guid]::NewGuid().ToString('N')))

    try {
        $content = @(
            '[Unicode]',
            'Unicode=yes',
            '[Version]',
            'signature="$CHICAGO$"',
            'Revision=1',
            '[Privilege Rights]',
            "$RightName = $($uniqueValues -join ',')"
        )

        Set-Content -LiteralPath $infPath -Value $content -Encoding Unicode
        $output = & secedit.exe /configure /db $dbPath /cfg $infPath /areas USER_RIGHTS 2>&1

        if ($LASTEXITCODE -ne 0) {
            throw "secedit configure failed with exit code $LASTEXITCODE. $output"
        }
    }
    finally {
        if (Test-Path -LiteralPath $infPath -PathType Leaf) {
            Remove-Item -LiteralPath $infPath -Force
        }

        if (Test-Path -LiteralPath $dbPath -PathType Leaf) {
            Remove-Item -LiteralPath $dbPath -Force
        }
    }
}

$transcriptStarted = $false
$logPath = $null

try {
    if ($WhatIfPreference) {
        Write-Status 'WhatIf mode: remediation log is not started.' Cyan
    }
    else {
        $logPath = Start-RemediationTranscript -Path $LogRoot
        $transcriptStarted = $true
        Write-Status "Remediation log: $logPath" Cyan
    }

    if (-not (Test-IsAdministrator)) {
        throw 'Run this script from an elevated PowerShell session.'
    }

    if ($PSCmdlet.ShouldProcess('Windows Firewall', 'Disable Domain, Private, and Public profiles')) {
        Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled False
        Write-Status '[OK] Windows Firewall profiles disabled.' Green
    }

    $highPerformanceGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'

    if ($PSCmdlet.ShouldProcess('Power plan', 'Set High performance')) {
        $powerOutput = & powercfg.exe /SETACTIVE $highPerformanceGuid 2>&1

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to set High performance power plan. $powerOutput"
        }

        Write-Status '[OK] Power plan set to High performance.' Green
    }

    if ($PSCmdlet.ShouldProcess('UAC', 'Set to Never notify')) {
        $uacPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
        Set-ItemProperty -LiteralPath $uacPath -Name ConsentPromptBehaviorAdmin -Value 0 -Type DWord
        Set-ItemProperty -LiteralPath $uacPath -Name PromptOnSecureDesktop -Value 0 -Type DWord
        Write-Status '[OK] UAC set to Never notify. Restart may be required before the UI reflects this setting.' Green
    }

    $rightAssignments = @(
        [pscustomobject]@{
            RightName = 'SeManageVolumePrivilege'
            Accounts  = @('NT Service\MSSQLSERVER')
            Label     = 'Perform volume maintenance tasks'
        },
        [pscustomobject]@{
            RightName = 'SeLockMemoryPrivilege'
            Accounts  = @('NT Service\MSSQLSERVER')
            Label     = 'Lock pages in memory'
        },
        [pscustomobject]@{
            RightName = 'SeChangeNotifyPrivilege'
            Accounts  = @('NT Service\MSSQLSERVER', 'NT Service\SQLSERVERAGENT')
            Label     = 'Bypass traverse checking'
        }
    )

    foreach ($assignment in $rightAssignments) {
        if ($PSCmdlet.ShouldProcess($assignment.Label, "Grant to $($assignment.Accounts -join ', ')")) {
            Add-PrivilegeRightAccounts -RightName $assignment.RightName -Accounts $assignment.Accounts
            Write-Status ("[OK] {0}: {1}" -f $assignment.Label, ($assignment.Accounts -join ', ')) Green
        }
    }

    Write-Status 'Run Test-OsSqlServerPrerequisites.ps1 again to verify the final state.' Cyan
}
finally {
    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
        Write-Host "Remediation log saved to: $logPath"
    }
}
