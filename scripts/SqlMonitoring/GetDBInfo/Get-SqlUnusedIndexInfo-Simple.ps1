#Requires -Version 5.1

# ===== 1. Settings: Normally, only edit this section =====
$ConfigPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Config\repository.config'
# Read the Key=Value configuration file into a lookup table.
$ConfigText = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop
$Config = ConvertFrom-StringData -StringData $ConfigText -ErrorAction Stop

$RepositoryServer = $Config.RepositoryInstance
$RepositoryDatabase = $Config.RepositoryDatabase
$ServerListTable = "$($Config.RepositorySchema).$($Config.RepositoryTable)"
$ReportSchema = 'dbo'
$ReportTable = 'SqlUnusedIndexInfo'      # Destination report table
$SqlLoginName = [string]$Config.SqlLoginName
$CredentialDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) 'Credentials'
$Database = @()                         # Empty = all user databases; or use @('AppDb')
$ExcludedDatabases = @('master', 'model', 'msdb', 'tempdb')
$QueryTimeout = 120
$TrustServerCertificate = $true         # Keep the original setting

if ($SqlLoginName -notmatch '^[A-Za-z0-9._-]+$') {
    throw "Invalid or missing SqlLoginName in configuration file: $ConfigPath"
}

# ===== 2. Load module =====
Import-Module dbatools -ErrorAction Stop
$ErrorActionPreference = 'Stop'
$PreviousTrust = Get-DbatoolsConfigValue -FullName 'sql.connection.trustcert'
$SecurePassword = $null
$AesKey = $null
$Step = 'Load SQL credential'

try {
    Set-DbatoolsConfig -FullName 'sql.connection.trustcert' -Value $TrustServerCertificate -Register:$false | Out-Null

    # ===== 3. Load credential: Keep the existing AES key and XML format =====
    $KeyPath = Join-Path $CredentialDirectory "$SqlLoginName.key"
    $CredentialPath = Join-Path $CredentialDirectory "$SqlLoginName.credential.xml"
    $AesKey = [System.IO.File]::ReadAllBytes($KeyPath)
    $StoredCredential = Import-Clixml -LiteralPath $CredentialPath
    $SecurePassword = ConvertTo-SecureString -String $StoredCredential.EncryptedPassword -Key $AesKey
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
    $ServerList = @(Invoke-DbaQuery -SqlInstance $RepositoryServer -SqlCredential $Credential `
        -Database $RepositoryDatabase -Query $SqlQuery -QueryTimeout $QueryTimeout -EnableException)
    if ($ServerList.Count -eq 0) {
        throw "$ServerListTable does not contain a valid InsName."
    }

    # Create the destination table if it does not exist. Existing data is preserved.
    $Step = 'Create the report table'
    $QualifiedTable = '[' + $ReportSchema.Replace(']', ']]') + '].[' + $ReportTable.Replace(']', ']]') + ']'
    $TableLiteral = $QualifiedTable.Replace("'", "''")
    $SchemaLiteral = $ReportSchema.Replace("'", "''")
    $SchemaSql = ('CREATE SCHEMA [' + $ReportSchema.Replace(']', ']]') + '] AUTHORIZATION [dbo];').Replace("'", "''")
    $SqlQuery = @"
SET NOCOUNT ON;
IF SCHEMA_ID(N'$SchemaLiteral') IS NULL
    EXEC(N'$SchemaSql');

IF OBJECT_ID(N'$TableLiteral', N'U') IS NULL
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
    Invoke-DbaQuery -SqlInstance $RepositoryServer -SqlCredential $Credential `
        -Database $RepositoryDatabase -Query $SqlQuery -QueryTimeout $QueryTimeout -EnableException | Out-Null

    $CollectedAt = [datetime]::UtcNow
    $SucceededCount = 0
    $FailedCount = 0
    $WrittenCount = 0

    # ===== 5. Query each SQL Server =====
    foreach ($Server in $ServerList) {
        $SqlInstance = $Server.InsName
        $DatabaseLabel = 'all user databases'
        if ($Database.Count -gt 0) {
            $DatabaseLabel = $Database -join ', '
        }
        $Step = 'Query unused indexes'
        Write-Host "Processing: $SqlInstance"

        try {
            if ($Database.Count -gt 0) {
                $SqlResult = @(Find-DbaDbUnusedIndex -SqlInstance $SqlInstance `
                    -SqlCredential $Credential -Database $Database `
                    -ExcludeDatabase $ExcludedDatabases -EnableException)
            }
            else {
                $SqlResult = @(Find-DbaDbUnusedIndex -SqlInstance $SqlInstance `
                    -SqlCredential $Credential `
                    -ExcludeDatabase $ExcludedDatabases -EnableException)
            }
            $SqlResult = @($SqlResult | Sort-Object IndexSizeMB -Descending)

            if ($SqlResult.Count -eq 0) {
                Write-Warning "[$SqlInstance] No unused index information was returned."
                $SucceededCount++
                continue
            }

            # Each PSCustomObject represents one row to be written to the report table.
            $Step = 'Prepare report columns'
            $Rows = @(
                foreach ($Index in $SqlResult) {
                    $DatabaseLabel = [string]$Index.Database
                    [pscustomobject][ordered]@{
                        CollectedAt             = $CollectedAt
                        SourceInstance          = $SqlInstance
                        SqlInstance             = $Index.SqlInstance
                        Database                = $Index.Database
                        Schema                  = $Index.Schema
                        Table                   = $Index.Table
                        Index                   = $Index.IndexName
                        IndexId                 = $Index.IndexId
                        IndexType               = $Index.TypeDesc
                        UserSeeks               = $Index.UserSeeks
                        UserScans               = $Index.UserScans
                        UserLookups             = $Index.UserLookups
                        UserUpdates             = $Index.UserUpdates
                        LastUserSeek            = $Index.LastUserSeek
                        LastUserScan            = $Index.LastUserScan
                        LastUserLookup          = $Index.LastUserLookup
                        LastUserUpdate          = $Index.LastUserUpdate
                        IndexSizeMB             = $Index.IndexSizeMB
                        RowCount                = $Index.RowCount
                        CompressionDescription  = $Index.CompressionDescription
                    }
                }
            )

            # ===== 6. Write to the repository: Keep the original columns and bulk copy options =====
            $Step = "Write to $RepositoryServer / $RepositoryDatabase / $QualifiedTable"
            $DatabaseLabel = ($Rows | Select-Object -ExpandProperty Database -Unique) -join ', '
            Write-DbaDbTableData -SqlInstance $RepositoryServer -SqlCredential $Credential `
                -Database $RepositoryDatabase -Schema $ReportSchema -Table $ReportTable `
                -InputObject $Rows -BatchSize 1000 -BulkCopyTimeOut $QueryTimeout `
                -NoTableLock -KeepNulls -EnableException -Confirm:$false | Out-Null

            $WrittenCount += $Rows.Count
            $SucceededCount++
            $SqlResult | Format-Table -AutoSize | Out-Host
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
    # Release the secure password, clear the AES key, and restore the dbatools setting.
    if ($null -ne $SecurePassword) { $SecurePassword.Dispose() }
    if ($null -ne $AesKey) { [System.Array]::Clear($AesKey, 0, $AesKey.Length) }
    Set-DbatoolsConfig -FullName 'sql.connection.trustcert' -Value $PreviousTrust -Register:$false | Out-Null
}
