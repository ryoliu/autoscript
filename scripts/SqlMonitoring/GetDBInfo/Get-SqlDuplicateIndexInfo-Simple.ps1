#Requires -Version 5.1

# ===== 1. Settings: Normally, only edit this section =====
$ConfigPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Config\repository.config'
$CredentialDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) 'Credentials'
$ReportSchema = 'dbo'
$ReportTable = 'SqlDuplicateIndexInfo'
$Database = @()                         # Empty = all accessible user databases; or use @('AppDb')
$ExcludedDatabases = @('master', 'model', 'msdb', 'tempdb')
$IncludeOverlapping = $true
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
$Step = 'Load SQL credential'

try {
    Set-DbatoolsConfig -FullName 'sql.connection.trustcert' `
        -Value $TrustServerCertificate -Register:$false | Out-Null

    # ===== 3. Load credential =====
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

    $QualifiedTable = "[$ReportSchema].[$ReportTable]"

    $CollectedAt = [datetime]::UtcNow
    $SucceededCount = 0
    $FailedCount = 0
    $WrittenCount = 0

    # ===== 5. Query each SQL Server =====
    foreach ($Server in $ServerList) {
        $SqlInstance = $Server.InsName
        $DatabaseLabel = 'all accessible user databases'
        $Step = 'Get user databases'
        Write-Host "Processing: $SqlInstance"

        try {
            if ($Database.Count -gt 0) {
                $DatabaseLabel = $Database -join ', '
                $TargetDatabases = @(
                    Get-DbaDatabase -SqlInstance $SqlInstance `
                        -SqlCredential $Credential `
                        -Database $Database `
                        -OnlyAccessible `
                        -EnableException |
                        Where-Object { $_.Name -notin $ExcludedDatabases } |
                        Select-Object -ExpandProperty Name
                )
            }
            else {
                $TargetDatabases = @(
                    Get-DbaDatabase -SqlInstance $SqlInstance `
                        -SqlCredential $Credential `
                        -OnlyAccessible `
                        -EnableException |
                        Where-Object { $_.Name -notin $ExcludedDatabases } |
                        Select-Object -ExpandProperty Name
                )
            }

            if ($TargetDatabases.Count -eq 0) {
                Write-Warning "[$SqlInstance] No accessible user databases were found."
                $SucceededCount++
                continue
            }

            $Step = 'Query duplicate indexes'

            if ($IncludeOverlapping) {
                $SqlResult = @(
                    Find-DbaDbDuplicateIndex -SqlInstance $SqlInstance `
                        -SqlCredential $Credential `
                        -Database $TargetDatabases `
                        -IncludeOverlapping `
                        -EnableException
                )
            }
            else {
                $SqlResult = @(
                    Find-DbaDbDuplicateIndex -SqlInstance $SqlInstance `
                        -SqlCredential $Credential `
                        -Database $TargetDatabases `
                        -EnableException
                )
            }

            $SqlResult = @($SqlResult | Sort-Object IndexSizeMB -Descending)

            if ($SqlResult.Count -eq 0) {
                Write-Warning "[$SqlInstance] No duplicate or overlapping index information was returned."
                $SucceededCount++
                continue
            }

            # ===== 6. Prepare and write the report rows =====
            $Step = 'Prepare report rows'
            $Rows = @(
                foreach ($Index in $SqlResult) {
                    [pscustomobject][ordered]@{
                        CollectedAt            = $CollectedAt
                        SourceInstance         = $SqlInstance
                        Database               = $Index.DatabaseName
                        Table                  = $Index.TableName
                        Index                  = $Index.IndexName
                        KeyColumns             = $Index.KeyColumns
                        IncludedColumns        = $Index.IncludedColumns
                        IndexType              = $Index.IndexType
                        IndexSizeMB            = $Index.IndexSizeMB
                        RowCount               = $Index.RowCount
                        IsDisabled             = $Index.IsDisabled
                        IsUnique               = $Index.IsUnique
                        IsFiltered             = $Index.IsFiltered
                        CompressionDescription = $Index.CompressionDescription
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
            $Rows | Format-Table -AutoSize | Out-Host
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
    if ($null -ne $SecurePassword) {
        $SecurePassword.Dispose()
    }

    if ($null -ne $AesKey) {
        [System.Array]::Clear($AesKey, 0, $AesKey.Length)
    }

    Set-DbatoolsConfig -FullName 'sql.connection.trustcert' `
        -Value $PreviousTrust -Register:$false | Out-Null
}
