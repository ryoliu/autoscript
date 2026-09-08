#Requires -Version 5.1

# ===== 1. Settings: Normally, only edit this section =====
$ConfigPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Config\repository.config'
$CredentialDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) 'Credentials'
$ReportSchema = 'dbo'
$ReportTable = 'SqlTopResourceUsage'
$Database = @()                         # Empty = all user databases; or use @('AppDb')
$ExcludedDatabases = @('master', 'model', 'msdb', 'tempdb')
$ResourceTypes = @('CPU', 'IO', 'Duration')
$TopQueryLimit = 20
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

        foreach ($ResourceType in $ResourceTypes) {
            $DatabaseLabel = 'all user databases'
            $Step = "Query top $ResourceType resource usage"
            Write-Host "Processing: $SqlInstance / $ResourceType"

            try {
                if ($Database.Count -gt 0) {
                    $DatabaseLabel = $Database -join ', '
                    $SqlResult = @(
                        Get-DbaTopResourceUsage -SqlInstance $SqlInstance `
                            -SqlCredential $Credential `
                            -Database $Database `
                            -Type $ResourceType `
                            -Limit $TopQueryLimit `
                            -ExcludeDatabase $ExcludedDatabases `
                            -ExcludeSystem `
                            -EnableException
                    )
                }
                else {
                    $SqlResult = @(
                        Get-DbaTopResourceUsage -SqlInstance $SqlInstance `
                            -SqlCredential $Credential `
                            -Type $ResourceType `
                            -Limit $TopQueryLimit `
                            -ExcludeDatabase $ExcludedDatabases `
                            -ExcludeSystem `
                            -EnableException
                    )
                }

                # Filter excluded databases again after dbatools returns the result.
                # This guarantees that system databases are not written to the report.
                $SqlResult = @(
                    $SqlResult | Where-Object {
                        $_.Database -notin $ExcludedDatabases
                    }
                )

                if ($SqlResult.Count -eq 0) {
                    Write-Warning "[$SqlInstance] No top $ResourceType SQL information was returned."
                    $SucceededCount++
                    continue
                }

                # ===== 6. Prepare and write the report rows =====
                $Step = 'Prepare report rows'
                $Rows = @(
                    foreach ($Item in $SqlResult) {
                        $QueryHash = $null

                        if ($null -ne $Item.QueryHash) {
                            if ($Item.QueryHash -is [byte[]]) {
                                $QueryHash = '0x' + [System.BitConverter]::ToString($Item.QueryHash).Replace('-', '')
                            }
                            else {
                                $QueryHash = [string]$Item.QueryHash
                            }
                        }

                        [pscustomobject][ordered]@{
                            CollectedAt             = $CollectedAt
                            SourceInstance          = $SqlInstance
                            Metric                  = $ResourceType
                            SqlInstance             = $Item.SqlInstance
                            Database                = $Item.Database
                            ObjectName              = $Item.ObjectName
                            QueryHash               = $QueryHash
                            ExecutionCount          = $Item.ExecutionCount
                            TotalElapsedTimeMs      = $Item.TotalElapsedTimeMs
                            AverageDurationMs       = $Item.AverageDurationMs
                            QueryTotalElapsedTimeMs = $Item.QueryTotalElapsedTimeMs
                            TotalIO                 = $Item.TotalIO
                            AverageIO               = $Item.AverageIO
                            QueryTotalIO            = $Item.QueryTotalIO
                            CpuTime                 = $Item.CpuTime
                            AverageCpuMs            = $Item.AverageCpuMs
                            QueryTotalCpu           = $Item.QueryTotalCpu
                            QueryText               = $Item.QueryText
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
                Write-Warning "Server=[$SqlInstance]; Database=[$DatabaseLabel]; Metric=[$ResourceType]; Step=[$Step]; $($_.Exception.Message). Continue with the next item."
            }
        }
    }

    # ===== 7. Finish =====
    Write-Host "Completed: $SucceededCount item(s) succeeded; $FailedCount item(s) failed; $WrittenCount row(s) written."
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
