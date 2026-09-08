#Requires -Version 5.1

# ===== 1. Settings: Normally, only edit this section =====
$ConfigPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Config\repository.config'
$CredentialDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) 'Credentials'
$ReportSchema = 'dbo'
$ReportTable = 'SqlBackupInfo'
$ExcludedDatabases = @('tempdb')
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
    $KeyPath = Join-Path $CredentialDirectory "$SqlLoginName.key"
    $CredentialPath = Join-Path $CredentialDirectory "$SqlLoginName.credential.xml"

    $AesKey = [System.IO.File]::ReadAllBytes($KeyPath)
    $StoredCredential = Import-Clixml -LiteralPath $CredentialPath
    $SecurePassword = ConvertTo-SecureString `
        -String $StoredCredential.EncryptedPassword -Key $AesKey
    $Credential = [pscredential]::new(
        $StoredCredential.UserName,
        $SecurePassword
    )

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
        $Step = 'Get last backup information'
        Write-Host "Processing: $SqlInstance"

        try {
            $BackupResult = @(
                Get-DbaLastBackup -SqlInstance $SqlInstance `
                    -SqlCredential $Credential `
                    -ExcludeDatabase $ExcludedDatabases `
                    -EnableException
            )

            if ($BackupResult.Count -eq 0) {
                Write-Warning "[$SqlInstance] No backup information was returned."
                $SucceededCount++
                continue
            }

            # ===== 6. Prepare and write the report rows =====
            $Step = 'Prepare report rows'
            $Rows = @(
                foreach ($Backup in $BackupResult) {
                    $LastFullBackup = $null
                    $LastDiffBackup = $null
                    $LastLogBackup = $null

                    if ($null -ne $Backup.LastFullBackup) {
                        $LastFullBackup = $Backup.LastFullBackup.Date
                    }

                    if ($null -ne $Backup.LastDiffBackup) {
                        $LastDiffBackup = $Backup.LastDiffBackup.Date
                    }

                    if ($null -ne $Backup.LastLogBackup) {
                        $LastLogBackup = $Backup.LastLogBackup.Date
                    }

                    [pscustomobject][ordered]@{
                        CollectedAt                 = $CollectedAt
                        SourceInstance              = $SqlInstance
                        SqlInstance                 = $Backup.SqlInstance
                        Database                    = $Backup.Database
                        RecoveryModel               = $Backup.RecoveryModel
                        LastFullBackup              = $LastFullBackup
                        LastDiffBackup              = $LastDiffBackup
                        LastLogBackup               = $LastLogBackup
                        LastFullBackupIsCopyOnly    = $Backup.LastFullBackupIsCopyOnly
                        LastDiffBackupIsCopyOnly    = $Backup.LastDiffBackupIsCopyOnly
                        LastLogBackupIsCopyOnly     = $Backup.LastLogBackupIsCopyOnly
                        DatabaseCreated             = $Backup.DatabaseCreated
                        DaysSinceDbCreated          = $Backup.DaysSinceDbCreated
                        Status                      = $Backup.Status
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
            $Rows |
                Sort-Object Database |
                Format-Table `
                    SourceInstance,
                    Database,
                    RecoveryModel,
                    LastFullBackup,
                    LastDiffBackup,
                    LastLogBackup,
                    Status `
                    -AutoSize |
                Out-Host
        }
        catch {
            $FailedCount++
            Write-Warning "Server=[$SqlInstance]; Step=[$Step]; $($_.Exception.Message). Continue with the next server."
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
