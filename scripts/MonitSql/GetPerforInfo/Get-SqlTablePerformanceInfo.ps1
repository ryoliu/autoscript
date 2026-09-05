#Requires -Version 5.1

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

$ModulePath = Join-Path $PSScriptRoot "SqlPerformanceInfo.Common.psm1"
Import-Module $ModulePath -ErrorAction Stop

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
            -RequiredDbatoolsCommands "Get-DbaDbTable"
        $OwnsContext = $true
        Show-SqlPerformanceContext -Context $Context
    }

    $Schema = $Context.ReportSchema.Replace(']', ']]')
    $TableName = "SqlTablePerformanceInfo"
    $QualifiedTable = "[$Schema].[$TableName]"
    $CreateTableSql = @"
SET NOCOUNT ON;
IF SCHEMA_ID(N'$Schema') IS NULL
    EXEC(N'CREATE SCHEMA [$Schema] AUTHORIZATION [dbo];');

IF OBJECT_ID(N'$QualifiedTable', N'U') IS NULL
BEGIN
    CREATE TABLE $QualifiedTable
    (
        [ReportId] bigint IDENTITY(1,1) NOT NULL CONSTRAINT [PK_SqlTablePerformanceInfo] PRIMARY KEY CLUSTERED,
        [CollectedAt] datetime2(3) NOT NULL,
        [SourceInstance] nvarchar(256) NOT NULL,
        [SqlInstance] nvarchar(256) NULL,
        [Database] nvarchar(128) NULL,
        [Schema] nvarchar(128) NULL,
        [Name] nvarchar(128) NULL,
        [RowCount] bigint NULL,
        [HasClusteredIndex] bit NULL,
        [DataMB] decimal(19,2) NULL,
        [IndexMB] decimal(19,2) NULL
    );
    CREATE INDEX [IX_SqlTablePerformanceInfo_CollectedAt]
        ON $QualifiedTable ([CollectedAt], [SourceInstance]);
END;
"@
    Initialize-SqlPerformanceReportTable -Context $Context -CommandText $CreateTableSql

    $SucceededCount = 0
    $FailedCount = 0
    $WrittenCount = 0

    foreach ($SqlInstance in $Context.SqlInstances) {
        Write-Host ""
        Write-Host "Instance: $SqlInstance"
        Write-Host "Table report"

        try {
            $Parameters = @{
                SqlInstance     = $SqlInstance
                SqlCredential   = $Context.Credential
                ExcludeDatabase = @("master", "model", "msdb", "tempdb")
                EnableException = $true
            }
            if ($null -ne $Database -and $Database.Length -gt 0) {
                $Parameters.Database = $Database
            }

            $TableReport = @(
                Get-DbaDbTable @Parameters |
                    Where-Object { [long]$_.RowCount -gt 0 } |
                    Select-Object SqlInstance, Database, Schema, Name, RowCount,
                        HasClusteredIndex,
                        @{ Name = 'DataMB'; Expression = { [math]::Round([double]$_.DataSpaceUsed / 1024, 2) } },
                        @{ Name = 'IndexMB'; Expression = { [math]::Round([double]$_.IndexSpaceUsed / 1024, 2) } }
            )

            if ($TableReport.Count -eq 0) {
                Write-Warning "[$SqlInstance] No user tables with RowCount greater than zero were returned."
            }
            else {
                $Rows = @(
                    foreach ($Item in $TableReport) {
                        [pscustomobject][ordered]@{
                            CollectedAt       = $CollectedAt.ToUniversalTime()
                            SourceInstance    = [string]$SqlInstance
                            SqlInstance       = [string]$Item.SqlInstance
                            Database          = [string]$Item.Database
                            Schema            = [string]$Item.Schema
                            Name              = [string]$Item.Name
                            RowCount          = Convert-ToNullableInt64 $Item.RowCount
                            HasClusteredIndex = Convert-ToNullableBoolean $Item.HasClusteredIndex
                            DataMB            = Convert-ToNullableDouble $Item.DataMB
                            IndexMB           = Convert-ToNullableDouble $Item.IndexMB
                        }
                    }
                )

                $WrittenCount += Write-SqlPerformanceRows -Context $Context -Table $TableName -Rows $Rows
                $TableReport | Sort-Object DataMB -Descending | Format-Table -AutoSize | Out-Host
            }

            $SucceededCount++
        }
        catch {
            $FailedCount++
            Write-Warning "[$SqlInstance] Table report failed: $($_.Exception.Message)"
        }
    }

    Write-Host "Table report completed. Succeeded: $SucceededCount; failed: $FailedCount; rows appended: $WrittenCount."
}
finally {
    if ($OwnsContext -and $null -ne $Context) {
        Close-SqlPerformanceContext -Context $Context
    }
}
