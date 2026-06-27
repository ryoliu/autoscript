[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$ComputerName = @('WIN2019-LAB2'),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$AdministratorUserName = 'Administrator',

    [Parameter()]
    [Security.SecureString]$AdministratorPassword,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$RemoteInstallSqlPath = 'C:\Autoscript\InstallSql',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$TaskName = 'InstallSqlServer',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$TaskRoot = 'C:\Install',

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-PlainTextPassword {
    param(
        [Parameter(Mandatory = $true)]
        [Security.SecureString]$SecureString
    )

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

if ($null -eq $AdministratorPassword) {
    $AdministratorPassword = Read-Host 'Administrator password' -AsSecureString
}

$plainPassword = ConvertTo-PlainTextPassword -SecureString $AdministratorPassword

try {
    $results = foreach ($target in $ComputerName) {
        Write-Host "==== $target ====" -ForegroundColor Cyan

        $remoteCredential = [System.Management.Automation.PSCredential]::new(
            "$target\$AdministratorUserName",
            $AdministratorPassword
        )

        try {
            Invoke-Command `
                -ComputerName $target `
                -Credential $remoteCredential `
                -Authentication Negotiate `
                -ScriptBlock {
                    param(
                        [string]$RemoteInstallSqlPath,
                        [string]$TaskName,
                        [string]$TaskRoot,
                        [string]$AdministratorUserName,
                        [string]$TaskPassword
                    )

                    $scriptPath = Join-Path -Path $TaskRoot -ChildPath 'install_sql.ps1'
                    $logPath = Join-Path -Path $TaskRoot -ChildPath 'install_sql_task.log'
                    $psModuleRoot = Join-Path -Path $RemoteInstallSqlPath -ChildPath 'psmodules'
                    $installScript = Join-Path -Path $psModuleRoot -ChildPath 'Install-SqlServer.ps1'

                    if (-not (Test-Path -LiteralPath $installScript -PathType Leaf)) {
                        throw "Install-SqlServer.ps1 was not found: $installScript"
                    }

                    New-Item -Path $TaskRoot -ItemType Directory -Force | Out-Null

                    $taskScript = @"
`$ErrorActionPreference = 'Stop'
`$transcriptStarted = `$false

try {
    Start-Transcript -Path '$logPath' -Append
    `$transcriptStarted = `$true

    Set-Location '$psModuleRoot'
    .\Install-SqlServer.ps1 -InstallMode Silent
}
finally {
    if (`$transcriptStarted) {
        Stop-Transcript
    }
}
"@

                    Set-Content -Path $scriptPath -Value $taskScript -Encoding ASCII

                    $action = New-ScheduledTaskAction `
                        -Execute 'powershell.exe' `
                        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""

                    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1)
                    $taskUser = "$env:COMPUTERNAME\$AdministratorUserName"

                    Register-ScheduledTask `
                        -TaskName $TaskName `
                        -Action $action `
                        -Trigger $trigger `
                        -User $taskUser `
                        -Password $TaskPassword `
                        -RunLevel Highest `
                        -Force | Out-Null

                    Start-ScheduledTask -TaskName $TaskName
                    $taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName

                    [pscustomobject]@{
                        ComputerName   = $env:COMPUTERNAME
                        TaskName       = $TaskName
                        TaskUser       = $taskUser
                        ScriptPath     = $scriptPath
                        LogPath        = $logPath
                        LastRunTime    = $taskInfo.LastRunTime
                        LastTaskResult = $taskInfo.LastTaskResult
                        NextRunTime    = $taskInfo.NextRunTime
                    }
                } `
                -ArgumentList $RemoteInstallSqlPath, $TaskName, $TaskRoot, $AdministratorUserName, $plainPassword

            Write-Host "==== $target task started ====" -ForegroundColor Green
        }
        catch {
            Write-Host "==== $target failed ====" -ForegroundColor Red
            Write-Host $_.Exception.Message -ForegroundColor Red

            [pscustomobject]@{
                ComputerName   = $target
                TaskName       = $TaskName
                TaskUser       = $null
                ScriptPath     = $null
                LogPath        = $null
                LastRunTime    = $null
                LastTaskResult = $null
                NextRunTime    = $null
                ErrorMessage   = $_.Exception.Message
            }
        }
    }

    if ($PassThru) {
        return $results
    }

    $results | Format-Table -AutoSize
}
finally {
    $plainPassword = $null
}
