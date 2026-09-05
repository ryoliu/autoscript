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
            -RequiredDbatoolsCommands "Find-DbaDbUnusedIndex"
        $OwnsContext = $true
        Show-SqlPerformanceContext -Context $Context
    }

    $Schema = $Context.ReportSchema.Replace(']', ']]')
    $TableName = "SqlUnusedIndexInfo"
    $QualifiedTable = "[$Schema].[$TableName]"
    $CreateTableSql = @"
SET NOCOUNT ON;
IF SCHEMA_ID(N'$Schema') IS NULL
    EXEC(N'CREATE SCHEMA [$Schema] AUTHORIZATION [dbo];');

IF OBJECT_ID(N'$QualifiedTable', N'U') IS NULL
BEGIN
    CREATE TABLE $QualifiedTable
    (
        [ReportId] bigint IDENTITY(1,1) NOT NULL CONSTRAINT [PK_SqlUnusedIndexInfo] PRIMARY KEY CLUSTERED,
        [CollectedAt] datetime2(3) NOT NULL,
        [SourceInstance] nvarchar(256) NOT NULL,
        [SqlInstance] nvarchar(256) NULL,
        [Database] nvarchar(128) NULL,
        [Schema] nvarchar(128) NULL,
        [Table] nvarchar(128) NULL,
        [Index] nvarchar(128) NULL,
        [IndexId] bigint NULL,
        [IndexType] nvarchar(128) NULL,
        [UserSeeks] bigint NULL,
        [UserScans] bigint NULL,
        [UserLookups] bigint NULL,
        [UserUpdates] bigint NULL,
        [LastUserSeek] datetime2(3) NULL,
        [LastUserScan] datetime2(3) NULL,
        [LastUserLookup] datetime2(3) NULL,
        [LastUserUpdate] datetime2(3) NULL,
        [IndexSizeMB] decimal(19,2) NULL,
        [RowCount] bigint NULL,
        [CompressionDescription] nvarchar(128) NULL
    );
    CREATE INDEX [IX_SqlUnusedIndexInfo_CollectedAt]
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
        Write-Host "Unused index report"

        try {
            $Parameters = @{
                SqlInstance     = $SqlInstance
                SqlCredential   = $Context.Credential
                EnableException = $true
            }
            if ($null -ne $Database -and $Database.Length -gt 0) {
                $Parameters.Database = $Database
            }

            $Report = @(Find-DbaDbUnusedIndex @Parameters | Sort-Object IndexSizeMB -Descending)
            if ($Report.Count -eq 0) {
                Write-Warning "[$SqlInstance] No unused index information was returned."
            }
            else {
                $Rows = @(
                    foreach ($Item in $Report) {
                        [pscustomobject][ordered]@{
                            CollectedAt            = $CollectedAt.ToUniversalTime()
                            SourceInstance         = [string]$SqlInstance
                            SqlInstance            = [string](Get-ObjectPropertyValue $Item @('SqlInstance'))
                            Database               = [string](Get-ObjectPropertyValue $Item @('Database'))
                            Schema                 = [string](Get-ObjectPropertyValue $Item @('Schema'))
                            Table                  = [string](Get-ObjectPropertyValue $Item @('Table'))
                            Index                  = [string](Get-ObjectPropertyValue $Item @('IndexName', 'Index'))
                            IndexId                = Convert-ToNullableInt64 (Get-ObjectPropertyValue $Item @('IndexId'))
                            IndexType              = [string](Get-ObjectPropertyValue $Item @('TypeDesc', 'IndexType'))
                            UserSeeks              = Convert-ToNullableInt64 (Get-ObjectPropertyValue $Item @('UserSeeks'))
                            UserScans              = Convert-ToNullableInt64 (Get-ObjectPropertyValue $Item @('UserScans'))
                            UserLookups            = Convert-ToNullableInt64 (Get-ObjectPropertyValue $Item @('UserLookups'))
                            UserUpdates            = Convert-ToNullableInt64 (Get-ObjectPropertyValue $Item @('UserUpdates'))
                            LastUserSeek           = Convert-ToNullableDateTime (Get-ObjectPropertyValue $Item @('LastUserSeek'))
                            LastUserScan           = Convert-ToNullableDateTime (Get-ObjectPropertyValue $Item @('LastUserScan'))
                            LastUserLookup         = Convert-ToNullableDateTime (Get-ObjectPropertyValue $Item @('LastUserLookup'))
                            LastUserUpdate         = Convert-ToNullableDateTime (Get-ObjectPropertyValue $Item @('LastUserUpdate'))
                            IndexSizeMB            = Convert-ToNullableDouble (Get-ObjectPropertyValue $Item @('IndexSizeMB'))
                            RowCount               = Convert-ToNullableInt64 (Get-ObjectPropertyValue $Item @('RowCount'))
                            CompressionDescription = [string](Get-ObjectPropertyValue $Item @('CompressionDescription'))
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
            Write-Warning "[$SqlInstance] Unused index report failed: $($_.Exception.Message)"
        }
    }

    Write-Host "Unused index report completed. Succeeded: $SucceededCount; failed: $FailedCount; rows appended: $WrittenCount."
}
finally {
    if ($OwnsContext -and $null -ne $Context) {
        Close-SqlPerformanceContext -Context $Context
    }
}
