#Requires -Version 5.1

<#
.SYNOPSIS
Collects high CPU, I/O, and duration SQL and appends it to the repository database.

.DESCRIPTION
This script reads the SQL Server plan cache and can add CPU, I/O, and network
load. The controller script does not run this report by default. Collection
occurs only when this script is run directly or -IncludeTopResourceUsage is
specified on the controller script.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "Config\repository.config"),
    [string]$RepositoryInstance,
    [string]$RepositoryDatabase,
    [string]$RepositorySchema,
    [string]$RepositoryTable,
    [string]$SqlLoginName = "srv.mn",
    [string]$CredentialDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) "Credentials"),
    [pscredential]$Credential,
    [string[]]$Database,
    [ValidateSet('CPU', 'IO', 'Duration')][string[]]$Type = @('CPU', 'IO', 'Duration'),
    [ValidateRange(1, 1000)][int]$TopQueryLimit = 20,
    [bool]$TrustServerCertificate = $true,
    [ValidateRange(1, 300)][int]$ConnectionTimeoutSeconds = 15,
    [ValidateRange(1, 86400)][int]$CommandTimeoutSeconds = 120,
    [ValidateRange(0, 20)][int]$RetryCount = 3,
    [ValidateRange(0, 300)][int]$RetryDelaySeconds = 2,
    [datetime]$CollectedAt = [datetime]::UtcNow,
    [psobject]$SharedContext
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "SqlPerformanceInfo.Common.psm1") -ErrorAction Stop
$OwnsContext = $false
$Context = $SharedContext

try {
    if ($null -eq $Context) {
        $Context = New-SqlPerformanceContext `
            -ConfigPath $ConfigPath `
            -RepositoryInstance $RepositoryInstance `
            -RepositoryDatabase $RepositoryDatabase `
            -RepositorySchema $RepositorySchema `
            -RepositoryTable $RepositoryTable `
            -SqlLoginName $SqlLoginName `
            -CredentialDirectory $CredentialDirectory `
            -Credential $Credential `
            -TrustServerCertificate:$TrustServerCertificate `
            -ConnectionTimeoutSeconds $ConnectionTimeoutSeconds `
            -CommandTimeoutSeconds $CommandTimeoutSeconds `
            -RetryCount $RetryCount `
            -RetryDelaySeconds $RetryDelaySeconds `
            -RequiredDbatoolsCommands "Get-DbaTopResourceUsage"
        $OwnsContext = $true
        Show-SqlPerformanceContext -Context $Context
    }

    $Schema = $Context.ReportSchema.Replace(']', ']]')
    $TableName = "SqlTopResourceUsage"
    $QualifiedTable = "[$Schema].[$TableName]"
    $CreateTableSql = @"
SET NOCOUNT ON;
IF SCHEMA_ID(N'$Schema') IS NULL
    EXEC(N'CREATE SCHEMA [$Schema] AUTHORIZATION [dbo];');

IF OBJECT_ID(N'$QualifiedTable', N'U') IS NULL
BEGIN
    CREATE TABLE $QualifiedTable
    (
        [ReportId] bigint IDENTITY(1,1) NOT NULL CONSTRAINT [PK_SqlTopResourceUsage] PRIMARY KEY CLUSTERED,
        [CollectedAt] datetime2(3) NOT NULL,
        [SourceInstance] nvarchar(256) NOT NULL,
        [Metric] nvarchar(20) NOT NULL,
        [SqlInstance] nvarchar(256) NULL,
        [Database] nvarchar(128) NULL,
        [ObjectName] nvarchar(512) NULL,
        [QueryHash] nvarchar(130) NULL,
        [ExecutionCount] bigint NULL,
        [TotalElapsedTimeMs] decimal(38,4) NULL,
        [AverageDurationMs] decimal(38,4) NULL,
        [QueryTotalElapsedTimeMs] decimal(38,4) NULL,
        [TotalIO] bigint NULL,
        [AverageIO] decimal(38,4) NULL,
        [QueryTotalIO] bigint NULL,
        [CpuTime] bigint NULL,
        [AverageCpuMs] decimal(38,4) NULL,
        [QueryTotalCpu] bigint NULL,
        [QueryText] nvarchar(max) NULL
    );
    CREATE INDEX [IX_SqlTopResourceUsage_CollectedAt]
        ON $QualifiedTable ([CollectedAt], [SourceInstance], [Metric]);
END;
"@
    Initialize-SqlPerformanceReportTable -Context $Context -CommandText $CreateTableSql

    $SucceededCount = 0
    $FailedCount = 0
    $WrittenCount = 0

    foreach ($SqlInstance in $Context.SqlInstances) {
        foreach ($ResourceType in $Type) {
            Write-Host ""
            Write-Host "Instance: $SqlInstance"
            Write-Host "Top $ResourceType resource usage report"

            try {
                $Parameters = @{
                    SqlInstance     = $SqlInstance
                    SqlCredential   = $Context.Credential
                    Type            = $ResourceType
                    Limit           = $TopQueryLimit
                    ExcludeSystem   = $true
                    EnableException = $true
                }
                if ($null -ne $Database -and $Database.Length -gt 0) {
                    $Parameters.Database = $Database
                }

                $Report = @(Get-DbaTopResourceUsage @Parameters)
                if ($Report.Count -eq 0) {
                    Write-Warning "[$SqlInstance] No top $ResourceType SQL information was returned."
                }
                else {
                    $Rows = @(
                        foreach ($Item in $Report) {
                            [pscustomobject][ordered]@{
                                CollectedAt            = $CollectedAt.ToUniversalTime()
                                SourceInstance         = [string]$SqlInstance
                                Metric                 = $ResourceType
                                SqlInstance            = [string](Get-ObjectPropertyValue $Item @('SqlInstance'))
                                Database               = [string](Get-ObjectPropertyValue $Item @('Database'))
                                ObjectName             = [string](Get-ObjectPropertyValue $Item @('ObjectName'))
                                QueryHash              = Convert-QueryHashToString (Get-ObjectPropertyValue $Item @('QueryHash'))
                                ExecutionCount         = Convert-ToNullableInt64 (Get-ObjectPropertyValue $Item @('ExecutionCount'))
                                TotalElapsedTimeMs     = Convert-ToNullableDouble (Get-ObjectPropertyValue $Item @('TotalElapsedTimeMs'))
                                AverageDurationMs      = Convert-ToNullableDouble (Get-ObjectPropertyValue $Item @('AverageDurationMs'))
                                QueryTotalElapsedTimeMs = Convert-ToNullableDouble (Get-ObjectPropertyValue $Item @('QueryTotalElapsedTimeMs'))
                                TotalIO                = Convert-ToNullableInt64 (Get-ObjectPropertyValue $Item @('TotalIO'))
                                AverageIO              = Convert-ToNullableDouble (Get-ObjectPropertyValue $Item @('AverageIO'))
                                QueryTotalIO           = Convert-ToNullableInt64 (Get-ObjectPropertyValue $Item @('QueryTotalIO'))
                                CpuTime                = Convert-ToNullableInt64 (Get-ObjectPropertyValue $Item @('CpuTime'))
                                AverageCpuMs           = Convert-ToNullableDouble (Get-ObjectPropertyValue $Item @('AverageCpuMs'))
                                QueryTotalCpu          = Convert-ToNullableInt64 (Get-ObjectPropertyValue $Item @('QueryTotalCpu'))
                                QueryText              = [string](Get-ObjectPropertyValue $Item @('QueryText'))
                            }
                        }
                    )

                    $WrittenCount += Write-SqlPerformanceRows -Context $Context -Table $TableName -Rows $Rows
                    $Report | Format-Table -AutoSize | Out-Host
                }

                $SucceededCount++
            }
            catch {
                $FailedCount++
                Write-Warning "[$SqlInstance] Top $ResourceType report failed: $($_.Exception.Message)"
            }
        }
    }

    Write-Host "Top resource report completed. Succeeded: $SucceededCount; failed: $FailedCount; rows appended: $WrittenCount."
}
finally {
    if ($OwnsContext -and $null -ne $Context) {
        Close-SqlPerformanceContext -Context $Context
    }
}
