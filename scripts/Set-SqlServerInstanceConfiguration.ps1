[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ServerInstance = 'localhost',

    [Parameter()]
    [switch]$CheckOnly,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$LogRoot = 'C:\autoscript\logs\SqlInstanceConfig'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-SqlServerConnectionTarget {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Instance
    )

    $trimmed = $Instance.Trim()

    if ($trimmed -ieq 'MSSQLSERVER') {
        return 'localhost'
    }

    if ($trimmed -in @('localhost', '.', '(local)')) {
        return $trimmed
    }

    if ($trimmed -match '[\\,:]') {
        return $trimmed
    }

    $serviceName = "MSSQL`$$trimmed"
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

    if ($null -ne $service) {
        return "localhost\$trimmed"
    }

    return $trimmed
}

function Start-ConfigTranscript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Instance
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }

    $safeInstance = $Instance -replace '[^a-zA-Z0-9_.-]', '_'
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $transcriptPath = Join-Path -Path $Path -ChildPath "Set-SqlServerInstanceConfiguration-$safeInstance-$timestamp.log"

    Start-Transcript -Path $transcriptPath -Force | Out-Null

    return $transcriptPath
}

function Get-SqlCmdPath {
    $command = Get-Command -Name sqlcmd.exe -ErrorAction SilentlyContinue

    if ($null -ne $command) {
        return $command.Source
    }

    $candidates = @(
        'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\sqlcmd.exe',
        'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\130\Tools\Binn\sqlcmd.exe',
        'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\110\Tools\Binn\sqlcmd.exe',
        'C:\Program Files\Microsoft SQL Server\160\Tools\Binn\sqlcmd.exe',
        'C:\Program Files\Microsoft SQL Server\150\Tools\Binn\sqlcmd.exe',
        'C:\Program Files\Microsoft SQL Server\140\Tools\Binn\sqlcmd.exe',
        'C:\Program Files\Microsoft SQL Server\130\Tools\Binn\sqlcmd.exe',
        'C:\Program Files\Microsoft SQL Server\120\Tools\Binn\sqlcmd.exe',
        'C:\Program Files\Microsoft SQL Server\110\Tools\Binn\sqlcmd.exe'
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    Write-Warning 'sqlcmd.exe was not found. SQL Server instance configuration cannot continue.'
    Write-Host 'Checked PATH and these common locations:' -ForegroundColor Yellow
    foreach ($candidate in $candidates) {
        Write-Host "  $candidate" -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host 'Install SSMS or SQL Server command line tools, then run this script again.' -ForegroundColor Yellow
    Write-Host "Example: C:\AutoScript\scripts\Install-Ssms.ps1 -InstallerPath 'C:\install\SSMS-Setup-ENU.exe'" -ForegroundColor Yellow
    throw 'sqlcmd.exe was not found.'
}

function Invoke-SqlText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query,

        [Parameter()]
        [switch]$NoResult
    )

    $sqlcmd = Get-SqlCmdPath
    $arguments = @(
        '-S', $SqlConnectionTarget,
        '-E',
        '-b',
        '-W',
        '-h', '-1',
        '-s', '|',
        '-Q', $Query
    )

    $output = & $sqlcmd @arguments 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "sqlcmd failed with exit code $LASTEXITCODE. $output"
    }

    if ($NoResult) {
        return
    }

    return @($output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Convert-SqlRows {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Rows,

        [Parameter(Mandatory = $true)]
        [string[]]$Columns
    )

    $objects = foreach ($row in $Rows) {
        $parts = $row.Split('|')
        $item = [ordered]@{}

        for ($index = 0; $index -lt $Columns.Count; $index++) {
            $value = if ($index -lt $parts.Count) { $parts[$index].Trim() } else { '' }
            $item[$Columns[$index]] = $value
        }

        [pscustomobject]$item
    }

    return @($objects)
}

function New-CheckResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Item,

        [Parameter(Mandatory = $true)]
        [bool]$Passed,

        [Parameter(Mandatory = $true)]
        [string]$Expected,

        [Parameter(Mandatory = $true)]
        [string]$Actual
    )

    [pscustomobject]@{
        Item     = $Item
        Passed   = $Passed
        Expected = $Expected
        Actual   = $Actual
    }
}

function Write-CheckResults {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Results
    )

    foreach ($result in $Results) {
        $status = if ($result.Passed) { 'PASS' } else { 'FAIL' }
        $color = if ($result.Passed) { 'Green' } else { 'Red' }

        Write-Host ("[{0}] {1}" -f $status, $result.Item) -ForegroundColor $color
        Write-Host ("      Expected: {0}" -f $result.Expected) -ForegroundColor $color
        Write-Host ("      Actual  : {0}" -f $result.Actual) -ForegroundColor $color
        Write-Host ''
    }
}

function Get-TargetMaxDop {
    param(
        [Parameter(Mandatory = $true)]
        [int]$CpuCoreCount
    )

    if ($CpuCoreCount -le 8) {
        return 2
    }

    if ($CpuCoreCount -le 16) {
        return 4
    }

    return 8
}

function Get-TargetValues {
    $rows = Invoke-SqlText -Query @"
SET NOCOUNT ON;
SELECT
    CAST(SERVERPROPERTY('Edition') AS nvarchar(200)) AS Edition,
    CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(50)) AS ProductVersion,
    CAST(SERVERPROPERTY('IsIntegratedSecurityOnly') AS int) AS IsIntegratedSecurityOnly,
    CAST((SELECT physical_memory_kb FROM sys.dm_os_sys_info) / 1024 AS bigint) AS PhysicalMemoryMb,
    CAST((SELECT cpu_count FROM sys.dm_os_sys_info) AS int) AS CpuCount;
"@

    $info = (Convert-SqlRows -Rows $rows -Columns @('Edition', 'ProductVersion', 'IsIntegratedSecurityOnly', 'PhysicalMemoryMb', 'CpuCount'))[0]
    $physicalMemoryMb = [int64]$info.PhysicalMemoryMb
    $cpuCount = [int]$info.CpuCount
    $targetMaxMemoryMb = [Math]::Max([int][Math]::Floor($physicalMemoryMb * 0.75), 2048)

    [pscustomobject]@{
        Edition = $info.Edition
        ProductVersion = $info.ProductVersion
        IsIntegratedSecurityOnly = [int]$info.IsIntegratedSecurityOnly
        PhysicalMemoryMb = $physicalMemoryMb
        CpuCount = $cpuCount
        MaxServerMemoryMb = $targetMaxMemoryMb
        MaxDop = Get-TargetMaxDop -CpuCoreCount $cpuCount
    }
}

function Set-InstanceConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Target
    )

    $query = @"
SET NOCOUNT ON;
EXEC sys.sp_configure N'show advanced options', 1;
RECONFIGURE WITH OVERRIDE;
EXEC sys.sp_configure N'max server memory (MB)', $($Target.MaxServerMemoryMb);
EXEC sys.sp_configure N'max worker threads', 0;
EXEC sys.sp_configure N'remote access', 1;
EXEC sys.sp_configure N'remote query timeout (s)', 0;
EXEC sys.sp_configure N'fill factor', 90;
EXEC sys.sp_configure N'backup compression default', 1;
EXEC sys.sp_configure N'optimize for ad hoc workloads', 1;
EXEC sys.sp_configure N'cost threshold for parallelism', 20;
EXEC sys.sp_configure N'max degree of parallelism', $($Target.MaxDop);
RECONFIGURE WITH OVERRIDE;
EXEC master.dbo.xp_instance_regwrite
    N'HKEY_LOCAL_MACHINE',
    N'Software\Microsoft\MSSQLServer\MSSQLServer',
    N'LoginMode',
    REG_DWORD,
    2;
EXEC master.dbo.xp_instance_regwrite
    N'HKEY_LOCAL_MACHINE',
    N'Software\Microsoft\MSSQLServer\MSSQLServer',
    N'AuditLevel',
    REG_DWORD,
    2;
"@

    Invoke-SqlText -Query $query -NoResult
}

function Get-CurrentConfiguration {
    $rows = Invoke-SqlText -Query @"
SET NOCOUNT ON;
DECLARE @LoginMode int;
DECLARE @AuditLevel int;

EXEC master.dbo.xp_instance_regread
    N'HKEY_LOCAL_MACHINE',
    N'Software\Microsoft\MSSQLServer\MSSQLServer',
    N'LoginMode',
    @LoginMode OUTPUT;

EXEC master.dbo.xp_instance_regread
    N'HKEY_LOCAL_MACHINE',
    N'Software\Microsoft\MSSQLServer\MSSQLServer',
    N'AuditLevel',
    @AuditLevel OUTPUT;

SELECT
    CAST(SERVERPROPERTY('Edition') AS nvarchar(200)) AS Edition,
    CAST(SERVERPROPERTY('IsIntegratedSecurityOnly') AS int) AS IsIntegratedSecurityOnly,
    CAST((SELECT cpu_count FROM sys.dm_os_sys_info) AS int) AS CpuCount,
    CAST((SELECT COUNT(*) FROM sys.dm_os_schedulers WHERE status = 'VISIBLE ONLINE') AS int) AS VisibleOnlineSchedulers,
    CAST((SELECT COUNT(DISTINCT parent_node_id) FROM sys.dm_os_schedulers WHERE status = 'VISIBLE ONLINE') AS int) AS NumaNodeCount,
    CAST((SELECT value_in_use FROM sys.configurations WHERE name = 'max server memory (MB)') AS int) AS MaxServerMemoryMb,
    CAST((SELECT value_in_use FROM sys.configurations WHERE name = 'max worker threads') AS int) AS MaxWorkerThreads,
    CAST((SELECT value_in_use FROM sys.configurations WHERE name = 'remote access') AS int) AS RemoteAccess,
    CAST((SELECT value_in_use FROM sys.configurations WHERE name = 'remote query timeout (s)') AS int) AS RemoteQueryTimeout,
    CAST((SELECT value FROM sys.configurations WHERE name = 'fill factor (%)') AS int) AS [FillFactorConfigured],
    CAST((SELECT value_in_use FROM sys.configurations WHERE name = 'fill factor (%)') AS int) AS [FillFactorInUse],
    CAST((SELECT value_in_use FROM sys.configurations WHERE name = 'backup compression default') AS int) AS BackupCompressionDefault,
    CAST((SELECT value_in_use FROM sys.configurations WHERE name = 'optimize for ad hoc workloads') AS int) AS OptimizeForAdHocWorkloads,
    CAST((SELECT value_in_use FROM sys.configurations WHERE name = 'cost threshold for parallelism') AS int) AS CostThresholdForParallelism,
    CAST((SELECT value_in_use FROM sys.configurations WHERE name = 'max degree of parallelism') AS int) AS MaxDop,
    ISNULL(@LoginMode, -1) AS LoginMode,
    ISNULL(@AuditLevel, -1) AS AuditLevel;
"@

    return (Convert-SqlRows -Rows $rows -Columns @(
        'Edition',
        'IsIntegratedSecurityOnly',
        'CpuCount',
        'VisibleOnlineSchedulers',
        'NumaNodeCount',
        'MaxServerMemoryMb',
        'MaxWorkerThreads',
        'RemoteAccess',
        'RemoteQueryTimeout',
        'FillFactorConfigured',
        'FillFactorInUse',
        'BackupCompressionDefault',
        'OptimizeForAdHocWorkloads',
        'CostThresholdForParallelism',
        'MaxDop',
        'LoginMode',
        'AuditLevel'
    ))[0]
}

function Test-InstanceConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Target,

        [Parameter(Mandatory = $true)]
        [object]$Current
    )

    $edition = [string]$Current.Edition
    $cpuCount = [int]$Current.CpuCount
    $visibleOnlineSchedulers = [int]$Current.VisibleOnlineSchedulers

    return @(
        (New-CheckResult `
            -Item 'Version' `
            -Passed ($edition -eq 'Enterprise Edition: Core-based Licensing (64-bit)' -or $edition -like '*Enterprise*Core-based Licensing*(64-bit)*') `
            -Expected 'Microsoft SQL Server Enterprise: Core-based Licensing (64-bit)' `
            -Actual $edition),
        (New-CheckResult `
            -Item 'Max Server Memory' `
            -Passed ([int]$Current.MaxServerMemoryMb -eq [int]$Target.MaxServerMemoryMb) `
            -Expected "75% of total memory, minimum 2048 MB. Target=$($Target.MaxServerMemoryMb) MB" `
            -Actual "$($Current.MaxServerMemoryMb) MB"),
        (New-CheckResult `
            -Item 'NumaNode' `
            -Passed ($visibleOnlineSchedulers -eq $cpuCount) `
            -Expected 'Visible online SQL schedulers equal SQL CPU core count' `
            -Actual "CpuCount=$cpuCount; VisibleOnlineSchedulers=$visibleOnlineSchedulers; NumaNodeCount=$($Current.NumaNodeCount)"),
        (New-CheckResult `
            -Item 'Maximum worker thread' `
            -Passed ([int]$Current.MaxWorkerThreads -eq 0) `
            -Expected '0' `
            -Actual "$($Current.MaxWorkerThreads)"),
        (New-CheckResult `
            -Item 'Server authentication' `
            -Passed ([int]$Current.LoginMode -eq 2 -and [int]$Current.IsIntegratedSecurityOnly -eq 0) `
            -Expected 'SQL Server and Windows Authentication mode' `
            -Actual "LoginMode=$($Current.LoginMode); IsIntegratedSecurityOnly=$($Current.IsIntegratedSecurityOnly)"),
        (New-CheckResult `
            -Item 'Login auditing' `
            -Passed ([int]$Current.AuditLevel -eq 2) `
            -Expected 'Failed logins only' `
            -Actual "AuditLevel=$($Current.AuditLevel)"),
        (New-CheckResult `
            -Item 'Allow Remote Connections to this server' `
            -Passed ([int]$Current.RemoteAccess -eq 1) `
            -Expected 'Enable' `
            -Actual "$($Current.RemoteAccess)"),
        (New-CheckResult `
            -Item 'Remote query timeout' `
            -Passed ([int]$Current.RemoteQueryTimeout -eq 0) `
            -Expected '0' `
            -Actual "$($Current.RemoteQueryTimeout)"),
        (New-CheckResult `
            -Item 'Default index fill factor' `
            -Passed ([int]$Current.FillFactorConfigured -eq 90) `
            -Expected 'Configured=90' `
            -Actual "Configured=$($Current.FillFactorConfigured); InUse=$($Current.FillFactorInUse)"),
        (New-CheckResult `
            -Item 'Compress backup' `
            -Passed ([int]$Current.BackupCompressionDefault -eq 1) `
            -Expected 'Enable' `
            -Actual "$($Current.BackupCompressionDefault)"),
        (New-CheckResult `
            -Item 'Optimize for ad hoc workloads' `
            -Passed ([int]$Current.OptimizeForAdHocWorkloads -eq 1) `
            -Expected 'TRUE' `
            -Actual "$($Current.OptimizeForAdHocWorkloads)"),
        (New-CheckResult `
            -Item 'Cost threshold for parallelism' `
            -Passed ([int]$Current.CostThresholdForParallelism -eq 20) `
            -Expected '20' `
            -Actual "$($Current.CostThresholdForParallelism)"),
        (New-CheckResult `
            -Item 'Max degree of parallelism' `
            -Passed ([int]$Current.MaxDop -eq [int]$Target.MaxDop) `
            -Expected "CPU <=8: 2; <=16: 4; >=17: 8. Target=$($Target.MaxDop)" `
            -Actual "$($Current.MaxDop)")
    )
}

$transcriptStarted = $false
$logPath = $null
$SqlConnectionTarget = Resolve-SqlServerConnectionTarget -Instance $ServerInstance

try {
    if (-not $WhatIfPreference) {
        $logPath = Start-ConfigTranscript -Path $LogRoot -Instance $ServerInstance
        $transcriptStarted = $true
        Write-Host "Instance config log: $logPath" -ForegroundColor Cyan
        Write-Host "SQL Server connection target: $SqlConnectionTarget" -ForegroundColor Cyan
    }

    if (-not (Test-IsAdministrator)) {
        throw 'Run this script from an elevated PowerShell session.'
    }

    $sqlcmdPath = Get-SqlCmdPath
    Write-Host "sqlcmd.exe found: $sqlcmdPath" -ForegroundColor Green

    $target = Get-TargetValues

    if (-not $CheckOnly) {
        if ($PSCmdlet.ShouldProcess($SqlConnectionTarget, 'Configure SQL Server instance settings')) {
            Set-InstanceConfiguration -Target $target
            Write-Host 'SQL Server instance configuration has been applied.' -ForegroundColor Green
            Write-Host 'Restart SQL Server service for authentication mode and login auditing registry changes to fully apply.' -ForegroundColor Yellow
        }
    }

    $current = Get-CurrentConfiguration
    $results = Test-InstanceConfiguration -Target $target -Current $current
    Write-CheckResults -Results $results

    if ($results | Where-Object { -not $_.Passed }) {
        exit 1
    }
}
finally {
    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
        Write-Host "Instance config log saved to: $logPath"
    }
}
