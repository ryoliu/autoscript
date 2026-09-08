#Requires -Version 5.1

# ===== 1. Settings: Normally, only edit this section =====
$ConfigPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Config\repository.config'
$CredentialDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) 'Credentials'
$ReportSchema = 'dbo'
$ReportTable = 'SqlDiskSpace'
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

    # Create the destination table if it does not exist.
    $Step = 'Create the report table'
    $QualifiedTable = "[$ReportSchema].[$ReportTable]"
    $SqlQuery = @"
SET NOCOUNT ON;

IF OBJECT_ID(N'$QualifiedTable', N'U') IS NULL
BEGIN
    CREATE TABLE $QualifiedTable
    (
        [ReportId] bigint IDENTITY(1,1) NOT NULL CONSTRAINT [PK_SqlDiskSpace] PRIMARY KEY CLUSTERED,
        [CollectedAt] datetime2(3) NOT NULL,
        [SourceInstance] nvarchar(256) NOT NULL,
        [Drive] nvarchar(512) NOT NULL,
        [TotalSizeGB] decimal(19,2) NULL,
        [FreeSpaceGB] decimal(19,2) NULL,
        [FreePercentage] decimal(9,2) NULL
    );

    CREATE INDEX [IX_SqlDiskSpace_CollectedAt]
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

    # The DMV returns only volumes that contain SQL Server database files.
    $DiskSpaceQuery = @"
SET NOCOUNT ON;

SELECT DISTINCT
    CONVERT(nvarchar(512), [VolumeStats].[volume_mount_point]) AS [Drive],
    CONVERT
    (
        decimal(19, 2),
        [VolumeStats].[total_bytes] / 1073741824.0
    ) AS [TotalSizeGB],
    CONVERT
    (
        decimal(19, 2),
        [VolumeStats].[available_bytes] / 1073741824.0
    ) AS [FreeSpaceGB],
    CONVERT
    (
        decimal(9, 2),
        CASE
            WHEN [VolumeStats].[total_bytes] = 0 THEN NULL
            ELSE [VolumeStats].[available_bytes] * 100.0 /
                 [VolumeStats].[total_bytes]
        END
    ) AS [FreePercentage]
FROM sys.master_files AS [MasterFile]
CROSS APPLY sys.dm_os_volume_stats
(
    [MasterFile].[database_id],
    [MasterFile].[file_id]
) AS [VolumeStats]
ORDER BY [Drive];
"@

    # ===== 5. Query each SQL Server =====
    foreach ($Server in $ServerList) {
        $SqlInstance = $Server.InsName
        $Step = 'Query disk space'
        Write-Host "Processing: $SqlInstance"

        try {
            $DiskSpaceResult = @(
                Invoke-DbaQuery -SqlInstance $SqlInstance `
                    -SqlCredential $Credential `
                    -Database 'master' `
                    -Query $DiskSpaceQuery `
                    -QueryTimeout $QueryTimeout `
                    -EnableException
            )

            if ($DiskSpaceResult.Count -eq 0) {
                Write-Warning "[$SqlInstance] No disk space information was returned."
                $SucceededCount++
                continue
            }

            # ===== 6. Prepare and write the report rows =====
            $Step = 'Prepare report rows'
            $Rows = @(
                foreach ($Disk in $DiskSpaceResult) {
                    [pscustomobject][ordered]@{
                        CollectedAt    = $CollectedAt
                        SourceInstance = $SqlInstance
                        Drive          = $Disk.Drive
                        TotalSizeGB    = $Disk.TotalSizeGB
                        FreeSpaceGB    = $Disk.FreeSpaceGB
                        FreePercentage = $Disk.FreePercentage
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
            $Rows | Sort-Object Drive | Format-Table -AutoSize | Out-Host
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
