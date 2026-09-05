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
            -RequiredDbatoolsCommands @(
                "Get-DbaDatabase",
                "Find-DbaDbDuplicateIndex"
            )
        $OwnsContext = $true
        Show-SqlPerformanceContext -Context $Context
    }

    $Schema = $Context.ReportSchema.Replace(']', ']]')
    $TableName = "SqlDuplicateIndexInfo"
    $QualifiedTable = "[$Schema].[$TableName]"
    $CreateTableSql = @"
SET NOCOUNT ON;
IF SCHEMA_ID(N'$Schema') IS NULL
    EXEC(N'CREATE SCHEMA [$Schema] AUTHORIZATION [dbo];');

IF OBJECT_ID(N'$QualifiedTable', N'U') IS NULL
BEGIN
    CREATE TABLE $QualifiedTable
    (
        [ReportId] bigint IDENTITY(1,1) NOT NULL CONSTRAINT [PK_SqlDuplicateIndexInfo] PRIMARY KEY CLUSTERED,
        [CollectedAt] datetime2(3) NOT NULL,
        [SourceInstance] nvarchar(256) NOT NULL,
        [Database] nvarchar(128) NULL,
        [Table] nvarchar(512) NULL,
        [Index] nvarchar(128) NULL,
        [KeyColumns] nvarchar(max) NULL,
        [IncludedColumns] nvarchar(max) NULL,
        [IndexType] nvarchar(128) NULL,
        [IndexSizeMB] decimal(19,2) NULL,
        [RowCount] bigint NULL,
        [IsDisabled] bit NULL,
        [IsUnique] bit NULL,
        [IsFiltered] bit NULL,
        [CompressionDescription] nvarchar(128) NULL
    );
    CREATE INDEX [IX_SqlDuplicateIndexInfo_CollectedAt]
        ON $QualifiedTable ([CollectedAt], [SourceInstance]);
END;
"@
    Initialize-SqlPerformanceReportTable -Context $Context -CommandText $CreateTableSql

    $SucceededCount = 0
    $FailedCount = 0
    $WrittenCount = 0
    $SystemDatabases = @('master', 'model', 'msdb', 'tempdb')

    foreach ($SqlInstance in $Context.SqlInstances) {
        Write-Host ""
        Write-Host "Instance: $SqlInstance"
        Write-Host "Duplicate and overlapping index report"

        try {
            $DatabaseParameters = @{
                SqlInstance      = $SqlInstance
                SqlCredential    = $Context.Credential
                ExcludeSystem    = $true
                OnlyAccessible   = $true
                EnableException  = $true
            }
            if ($null -ne $Database -and $Database.Length -gt 0) {
                $DatabaseParameters.Database = $Database
            }

            $TargetDatabases = @(
                Get-DbaDatabase @DatabaseParameters |
                    Select-Object -ExpandProperty Name
            )

            if ($TargetDatabases.Length -eq 0) {
                Write-Warning "[$SqlInstance] No accessible user databases remain after excluding system databases."
                $SucceededCount++
                continue
            }

            $Parameters = @{
                SqlInstance        = $SqlInstance
                SqlCredential      = $Context.Credential
                Database           = $TargetDatabases
                IncludeOverlapping = $true
                EnableException    = $true
            }

            $Report = @(
                Find-DbaDbDuplicateIndex @Parameters |
                    Where-Object {
                        (Get-ObjectPropertyValue `
                            -InputObject $_ `
                            -Name @('DatabaseName', 'Database')) `
                            -notin $SystemDatabases
                    }
            )
            if ($Report.Count -eq 0) {
                Write-Warning "[$SqlInstance] No duplicate or overlapping index information was returned."
            }
            else {
                $Rows = @(
                    foreach ($Item in $Report) {
                        [pscustomobject][ordered]@{
                            CollectedAt            = $CollectedAt.ToUniversalTime()
                            SourceInstance         = [string]$SqlInstance
                            Database               = [string](Get-ObjectPropertyValue $Item @('DatabaseName', 'Database'))
                            Table                  = [string](Get-ObjectPropertyValue $Item @('TableName', 'Table'))
                            Index                  = [string](Get-ObjectPropertyValue $Item @('IndexName', 'Index'))
                            KeyColumns             = [string](Get-ObjectPropertyValue $Item @('KeyColumns'))
                            IncludedColumns        = [string](Get-ObjectPropertyValue $Item @('IncludedColumns', 'IncludeColumns'))
                            IndexType              = [string](Get-ObjectPropertyValue $Item @('IndexType', 'TypeDesc'))
                            IndexSizeMB            = Convert-ToNullableDouble (Get-ObjectPropertyValue $Item @('IndexSizeMB'))
                            RowCount               = Convert-ToNullableInt64 (Get-ObjectPropertyValue $Item @('RowCount'))
                            IsDisabled             = Convert-ToNullableBoolean (Get-ObjectPropertyValue $Item @('IsDisabled'))
                            IsUnique               = Convert-ToNullableBoolean (Get-ObjectPropertyValue $Item @('IsUnique'))
                            IsFiltered             = Convert-ToNullableBoolean (Get-ObjectPropertyValue $Item @('IsFiltered'))
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
            Write-Warning "[$SqlInstance] Duplicate index report failed: $($_.Exception.Message)"
        }
    }

    Write-Host "Duplicate index report completed. Succeeded: $SucceededCount; failed: $FailedCount; rows appended: $WrittenCount."
}
finally {
    if ($OwnsContext -and $null -ne $Context) {
        Close-SqlPerformanceContext -Context $Context
    }
}
