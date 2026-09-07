#Requires -Version 5.1

# ===== 1. Settings: Normally, only edit this section =====
$ConfigPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Config\repository.config'
$CredentialDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) 'Credentials'
$ReportSchema = 'dbo'
$ReportTable = 'SqlTablePerformanceInfo'
$Database = @()                         # Empty = all user databases; or use @('AppDb')
$ExcludedDatabases = @('master', 'model', 'msdb', 'tempdb')
$QueryTimeout = 120
$TrustServerCertificate = $true

# Read the Repository settings from repository.config.
$ConfigText = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop
$Config = ConvertFrom-StringData -StringData $ConfigText -ErrorAction Stop
$SqlLoginName = [string]$Config.SqlLoginName

if ($SqlLoginName -notmatch '^[A-Za-z0-9._-]+$') {
    throw "Invalid or missing SqlLoginName in configuration file: $ConfigPath"
}

$RepositoryServer = $Config.RepositoryInstance
$RepositoryDatabase = $Config.RepositoryDatabase
$ServerListTable = "$($Config.RepositorySchema).$($Config.RepositoryTable)"

# ===== 2. Load module =====
Import-Module dbatools -ErrorAction Stop
$ErrorActionPreference = 'Stop'

$PreviousTrust = Get-DbatoolsConfigValue -FullName 'sql.connection.trustcert'
$SecurePassword = $null
$AesKey = $null
$Step = 'Configure dbatools'

try {
    Set-DbatoolsConfig -FullName 'sql.connection.trustcert' `
        -Value $TrustServerCertificate -Register:$false | Out-Null

    # ===== 3. Load credential =====
    $Step = 'Load SQL credential'
    # The credential files are stored in the shared Credentials folder.
    $KeyPath = Join-Path $CredentialDirectory "$SqlLoginName.key"
    $CredentialPath = Join-Path $CredentialDirectory "$SqlLoginName.credential.xml"

    $AesKey = [System.IO.File]::ReadAllBytes($KeyPath)
    $StoredCredential = Import-Clixml -LiteralPath $CredentialPath
    $SecurePassword = ConvertTo-SecureString `
        -String $StoredCredential.EncryptedPassword -Key $AesKey
    $Credential = [pscredential]::new($StoredCredential.UserName, $SecurePassword)

    # ===== 4. Get the SQL Server list =====
    $Step = 'Get the SQL Server list'
    $SqlQuery = @"
SELECT DISTINCT LTRIM(RTRIM(CONVERT(nvarchar(256), InsName))) AS InsName
FROM $ServerListTable
WHERE InsName IS NOT NULL
  AND LTRIM(RTRIM(CONVERT(nvarchar(256), InsName))) <> N''
ORDER BY InsName;
"@

    # @() ensures that zero, one, or multiple results are handled as an array.
    $ServerList = @(
        Invoke-DbaQuery -SqlInstance $RepositoryServer `
            -SqlCredential $Credential `
            -Database $RepositoryDatabase `
            -Query $SqlQuery `
            -QueryTimeout $QueryTimeout `
            -EnableException
    )

    if ($ServerList.Count -eq 0) {
        throw "$ServerListTable does not contain a valid InsName."
    }

    # Create the destination table if it does not exist.
    $Step = 'Create the report table'
    $QualifiedTable = "[$ReportSchema].[$ReportTable]"
    $SqlQuery = @"
SET NOCOUNT ON;

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

    Invoke-DbaQuery -SqlInstance $RepositoryServer `
        -SqlCredential $Credential `
        -Database $RepositoryDatabase `
        -Query $SqlQuery `
        -QueryTimeout $QueryTimeout `
        -EnableException | Out-Null

    $CollectedAt = [datetime]::UtcNow
    $SucceededCount = 0
    $FailedCount = 0
    $WrittenCount = 0

    $DatabaseQuery = @"
SET NOCOUNT ON;

SELECT CONVERT(nvarchar(128), [name]) AS [DatabaseName]
FROM sys.databases
WHERE [database_id] > 4
  AND [state_desc] = N'ONLINE'
  AND [source_database_id] IS NULL
  AND HAS_DBACCESS([name]) = 1
ORDER BY [name];
"@

    # sys.dm_db_partition_stats supplies row and page counts without relying
    # on the SMO Table.RowCount property.
    $TableQuery = @"
SET NOCOUNT ON;

WITH [TableStats] AS
(
    SELECT
        [object_id],
        SUM
        (
            CASE WHEN [index_id] IN (0, 1)
                 THEN [row_count]
                 ELSE CONVERT(bigint, 0)
            END
        ) AS [RowCount],
        SUM
        (
            CASE WHEN [index_id] IN (0, 1)
                 THEN [in_row_data_page_count]
                    + [lob_used_page_count]
                    + [row_overflow_used_page_count]
                 ELSE CONVERT(bigint, 0)
            END
        ) AS [DataPages],
        SUM([used_page_count]) AS [UsedPages]
    FROM sys.dm_db_partition_stats
    GROUP BY [object_id]
)
SELECT
    CONVERT(nvarchar(256), SERVERPROPERTY(N'ServerName')) AS [SqlInstance],
    CONVERT(nvarchar(128), DB_NAME()) AS [Database],
    CONVERT(nvarchar(128), [s].[name]) AS [Schema],
    CONVERT(nvarchar(128), [t].[name]) AS [Name],
    CONVERT(bigint, [ts].[RowCount]) AS [RowCount],
    CONVERT
    (
        bit,
        CASE WHEN EXISTS
        (
            SELECT 1
            FROM sys.indexes AS [i]
            WHERE [i].[object_id] = [t].[object_id]
              AND [i].[index_id] = 1
        ) THEN 1 ELSE 0 END
    ) AS [HasClusteredIndex],
    CONVERT(decimal(19, 2), [ts].[DataPages] * 8.0 / 1024.0)
        AS [DataMB],
    CONVERT
    (
        decimal(19, 2),
        ([ts].[UsedPages] - [ts].[DataPages]) * 8.0 / 1024.0
    ) AS [IndexMB]
FROM sys.tables AS [t]
INNER JOIN sys.schemas AS [s]
    ON [s].[schema_id] = [t].[schema_id]
INNER JOIN [TableStats] AS [ts]
    ON [ts].[object_id] = [t].[object_id]
WHERE [t].[is_ms_shipped] = 0
  AND [ts].[RowCount] > 0
ORDER BY [DataMB] DESC, [Schema], [Name];
"@

    # ===== 5. Query each SQL Server =====
    foreach ($Server in $ServerList) {
        $SqlInstance = $Server.InsName
        $DatabaseLabel = 'all user databases'
        $Step = 'Query table information'
        Write-Host "Processing: $SqlInstance"

        try {
            $Step = 'Get the user database list'
            $AvailableDatabases = @(
                Invoke-DbaQuery -SqlInstance $SqlInstance `
                    -SqlCredential $Credential `
                    -Database 'master' `
                    -Query $DatabaseQuery `
                    -QueryTimeout $QueryTimeout `
                    -EnableException |
                    ForEach-Object { [string]$_.DatabaseName }
            )

            if ($Database.Count -gt 0) {
                $DatabaseLabel = $Database -join ', '
                $TargetDatabases = @(
                    $AvailableDatabases |
                        Where-Object {
                            $_ -in $Database -and
                            $_ -notin $ExcludedDatabases
                        }
                )
            }
            else {
                $TargetDatabases = @(
                    $AvailableDatabases |
                        Where-Object { $_ -notin $ExcludedDatabases }
                )
            }

            $TableReport = @(
                foreach ($TargetDatabase in $TargetDatabases) {
                    $Step = "Query table information for [$TargetDatabase]"
                    Invoke-DbaQuery -SqlInstance $SqlInstance `
                        -SqlCredential $Credential `
                        -Database $TargetDatabase `
                        -Query $TableQuery `
                        -QueryTimeout $QueryTimeout `
                        -EnableException
                }
            )

            if ($TableReport.Count -eq 0) {
                Write-Warning "[$SqlInstance] No user tables with a RowCount greater than zero were returned."
                $SucceededCount++
                continue
            }

            # ===== 6. Prepare and write the report rows =====
            $Step = 'Prepare report rows'
            $Rows = @(
                foreach ($Table in $TableReport) {
                    [pscustomobject][ordered]@{
                        CollectedAt       = $CollectedAt
                        SourceInstance    = $SqlInstance
                        SqlInstance       = $Table.SqlInstance
                        Database          = $Table.Database
                        Schema            = $Table.Schema
                        Name              = $Table.Name
                        RowCount          = $Table.RowCount
                        HasClusteredIndex = $Table.HasClusteredIndex
                        DataMB            = $Table.DataMB
                        IndexMB           = $Table.IndexMB
                    }
                }
            )

            $Step = "Write to $RepositoryServer / $RepositoryDatabase / $QualifiedTable"
            Write-DbaDbTableData -SqlInstance $RepositoryServer `
                -SqlCredential $Credential `
                -Database $RepositoryDatabase `
                -Schema $ReportSchema `
                -Table $ReportTable `
                -InputObject $Rows `
                -BatchSize 1000 `
                -BulkCopyTimeOut $QueryTimeout `
                -NoTableLock `
                -KeepNulls `
                -EnableException `
                -Confirm:$false | Out-Null

            $WrittenCount += $Rows.Count
            $SucceededCount++
            $Rows | Sort-Object DataMB -Descending | Format-Table -AutoSize | Out-Host
        }
        catch {
            $FailedCount++
            Write-Warning "Server=[$SqlInstance]; Database=[$DatabaseLabel]; Step=[$Step]; $($_.Exception.Message). Continue with the next server."
        }
    }

    # ===== 7. Finish =====
    Write-Host "Completed: $SucceededCount server(s) succeeded; $FailedCount server(s) failed; $WrittenCount row(s) written."
}
catch {
    throw "Repository=[$RepositoryServer/$RepositoryDatabase]; Step=[$Step]; $($_.Exception.Message). Execution stopped."
}
finally {
    # Release sensitive values and restore the temporary trust setting.
    if ($null -ne $SecurePassword) {
        $SecurePassword.Dispose()
    }

    if ($null -ne $AesKey) {
        [System.Array]::Clear($AesKey, 0, $AesKey.Length)
    }

    Set-DbatoolsConfig -FullName 'sql.connection.trustcert' `
        -Value $PreviousTrust -Register:$false | Out-Null
}
