Set-StrictMode -Version Latest

$script:MaintenanceModulePath = Join-Path (Split-Path -Parent $PSScriptRoot) "Modules\SqlMaintenance.Common\SqlMaintenance.Common.psm1"
if (-not (Test-Path -LiteralPath $script:MaintenanceModulePath)) {
    throw "Shared module not found: $script:MaintenanceModulePath"
}

Import-Module $script:MaintenanceModulePath -Force -Scope Local -ErrorAction Stop

function Get-ObjectPropertyValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string[]]$Name
    )

    foreach ($PropertyName in $Name) {
        $Property = $InputObject.PSObject.Properties[$PropertyName]
        if ($null -ne $Property -and $null -ne $Property.Value) {
            return $Property.Value
        }
    }

    return $null
}

function Convert-ToNullableInt64 {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or $Value -is [System.DBNull] -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }

    try { return [long]$Value } catch { return $null }
}

function Convert-ToNullableDouble {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or $Value -is [System.DBNull] -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }

    try { return [double]$Value } catch { return $null }
}

function Convert-ToNullableDateTime {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or $Value -is [System.DBNull] -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }

    try { return [datetime]$Value } catch { return $null }
}

function Convert-ToNullableBoolean {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or $Value -is [System.DBNull] -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }

    try { return [bool]$Value } catch { return $null }
}

function Convert-QueryHashToString {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or $Value -is [System.DBNull]) {
        return $null
    }

    if ($Value -is [byte[]]) {
        return "0x$([System.BitConverter]::ToString($Value).Replace('-', ''))"
    }

    return [string]$Value
}

function Import-StoredSqlCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SqlLoginName,

        [Parameter(Mandatory)]
        [string]$CredentialDirectory
    )

    $KeyPath = Join-Path $CredentialDirectory "$SqlLoginName.key"
    $CredentialPath = Join-Path $CredentialDirectory "$SqlLoginName.credential.xml"

    if (-not (Test-Path -LiteralPath $KeyPath -PathType Leaf)) {
        throw "SQL credential AES key not found: $KeyPath"
    }

    if (-not (Test-Path -LiteralPath $CredentialPath -PathType Leaf)) {
        throw "Encrypted SQL credential not found: $CredentialPath"
    }

    [byte[]]$AesKey = [System.IO.File]::ReadAllBytes($KeyPath)

    try {
        if ($AesKey.Length -notin 16, 24, 32) {
            throw "Invalid AES key length: $($AesKey.Length) bytes."
        }

        $StoredCredential = Import-Clixml -LiteralPath $CredentialPath -ErrorAction Stop
        if (
            $StoredCredential.PSObject.Properties.Name -notcontains 'UserName' -or
            $StoredCredential.PSObject.Properties.Name -notcontains 'EncryptedPassword'
        ) {
            throw "Invalid SQL credential file format: $CredentialPath"
        }

        $SecurePassword = $StoredCredential.EncryptedPassword | ConvertTo-SecureString -Key $AesKey
        return [pscustomobject]@{
            Credential     = [pscredential]::new([string]$StoredCredential.UserName, $SecurePassword)
            SecurePassword = $SecurePassword
        }
    }
    finally {
        [System.Array]::Clear($AesKey, 0, $AesKey.Length)
    }
}

function Get-RepositoryInstanceName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryInstance,

        [Parameter(Mandatory)]
        [string]$RepositoryDatabase,

        [Parameter(Mandatory)]
        [string]$RepositorySchema,

        [Parameter(Mandatory)]
        [string]$RepositoryTable,

        [Parameter(Mandatory)]
        [System.Data.SqlClient.SqlCredential]$SqlCredential,

        [Parameter(Mandatory)]
        [bool]$TrustServerCertificate,

        [Parameter(Mandatory)]
        [int]$ConnectionTimeoutSeconds,

        [Parameter(Mandatory)]
        [int]$CommandTimeoutSeconds,

        [Parameter(Mandatory)]
        [int]$RetryCount,

        [Parameter(Mandatory)]
        [int]$RetryDelaySeconds
    )

    $SafeSchema = $RepositorySchema.Replace(']', ']]')
    $SafeTable = $RepositoryTable.Replace(']', ']]')
    $CommandText = @"
SELECT DISTINCT LTRIM(RTRIM(CONVERT(nvarchar(256), [InsName]))) AS [InsName]
FROM [$SafeSchema].[$SafeTable]
WHERE [InsName] IS NOT NULL
  AND LTRIM(RTRIM(CONVERT(nvarchar(256), [InsName]))) <> N''
ORDER BY [InsName];
"@

    $Connection = New-SqlConnection `
        -DataSource $RepositoryInstance `
        -InitialCatalog $RepositoryDatabase `
        -SqlCredential $SqlCredential `
        -ConnectionTimeoutSeconds $ConnectionTimeoutSeconds `
        -TrustServerCertificate:$TrustServerCertificate `
        -ApplicationName "SqlPerformanceInfo"

    try {
        Invoke-SqlWithRetry -Step "ReadRepositoryInstanceList" -Instance $RepositoryInstance -RetryCount $RetryCount -RetryDelaySeconds $RetryDelaySeconds -Operation {
            if ($Connection.State -ne [System.Data.ConnectionState]::Open) {
                $Connection.Open()
            }

            $Command = $Connection.CreateCommand()
            try {
                $Command.CommandText = $CommandText
                $Command.CommandTimeout = $CommandTimeoutSeconds
                $Reader = $Command.ExecuteReader()
                try {
                    $Names = [System.Collections.Generic.List[string]]::new()
                    while ($Reader.Read()) {
                        $Name = [string]$Reader['InsName']
                        if (-not [string]::IsNullOrWhiteSpace($Name)) {
                            $Names.Add($Name.Trim())
                        }
                    }
                    return $Names.ToArray()
                }
                finally {
                    if ($null -ne $Reader) { $Reader.Dispose() }
                }
            }
            finally {
                if ($null -ne $Command) { $Command.Dispose() }
            }
        }
    }
    finally {
        if ($Connection.State -ne [System.Data.ConnectionState]::Closed) { $Connection.Close() }
        $Connection.Dispose()
    }
}

function New-SqlPerformanceContext {
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
        [bool]$TrustServerCertificate = $true,
        [ValidateRange(1, 300)][int]$ConnectionTimeoutSeconds = 15,
        [ValidateRange(1, 86400)][int]$CommandTimeoutSeconds = 120,
        [ValidateRange(0, 20)][int]$RetryCount = 3,
        [ValidateRange(0, 300)][int]$RetryDelaySeconds = 2,
        [string[]]$RequiredDbatoolsCommands = @()
    )

    $OwnedSecurePassword = $null
    try {
        Import-Module dbatools -Global -ErrorAction Stop
    }
    catch {
        throw "Unable to import the dbatools module: $($_.Exception.Message)"
    }

    $RequiredCommands = @('Get-DbatoolsConfigValue', 'Set-DbatoolsConfig', 'Write-DbaDbTableData') + $RequiredDbatoolsCommands
    foreach ($CommandName in ($RequiredCommands | Select-Object -Unique)) {
        if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) {
            throw "Required command not found: $CommandName"
        }
    }

    $ConfigParameters = @{ LiteralPath = $ConfigPath }
    if (-not [string]::IsNullOrWhiteSpace($RepositoryInstance)) { $ConfigParameters.RepositoryInstance = $RepositoryInstance }
    if (-not [string]::IsNullOrWhiteSpace($RepositoryDatabase)) { $ConfigParameters.RepositoryDatabase = $RepositoryDatabase }
    if (-not [string]::IsNullOrWhiteSpace($RepositorySchema)) { $ConfigParameters.RepositorySchema = $RepositorySchema }
    if (-not [string]::IsNullOrWhiteSpace($RepositoryTable)) { $ConfigParameters.RepositoryTable = $RepositoryTable }

    $RepositoryConfig = Get-SqlRepositoryConfig @ConfigParameters
    $PreviousTrustServerCertificate = Get-DbatoolsConfigValue -FullName "sql.connection.trustcert"
    $TrustSettingChanged = $false

    try {
        [void](Set-DbatoolsConfig -FullName "sql.connection.trustcert" -Value $TrustServerCertificate -Register:$false)
        $TrustSettingChanged = $true

        if ($null -eq $Credential) {
            $StoredCredential = Import-StoredSqlCredential -SqlLoginName $SqlLoginName -CredentialDirectory $CredentialDirectory
            $Credential = $StoredCredential.Credential
            $OwnedSecurePassword = $StoredCredential.SecurePassword
        }

        if ($Credential.UserName -ne $SqlLoginName) {
            throw "Credential user is '$($Credential.UserName)'; expected '$SqlLoginName'."
        }

        [void](
            Test-SqlMonitorRepository `
                -RepositoryInstance $RepositoryConfig.RepositoryInstance `
                -RepositoryDatabase $RepositoryConfig.RepositoryDatabase `
                -RepositorySchema $RepositoryConfig.RepositorySchema `
                -RepositoryTable $RepositoryConfig.RepositoryTable `
                -Credential $Credential `
                -ConnectionTimeoutSeconds $ConnectionTimeoutSeconds `
                -CommandTimeoutSeconds $CommandTimeoutSeconds `
                -RetryCount $RetryCount `
                -RetryDelaySeconds $RetryDelaySeconds
        )

        $PasswordCopy = $Credential.Password.Copy()
        try {
            $PasswordCopy.MakeReadOnly()
            $SqlCredential = [System.Data.SqlClient.SqlCredential]::new($Credential.UserName, $PasswordCopy)
            $SqlInstances = @(Get-RepositoryInstanceName `
                -RepositoryInstance $RepositoryConfig.RepositoryInstance `
                -RepositoryDatabase $RepositoryConfig.RepositoryDatabase `
                -RepositorySchema $RepositoryConfig.RepositorySchema `
                -RepositoryTable $RepositoryConfig.RepositoryTable `
                -SqlCredential $SqlCredential `
                -TrustServerCertificate:$TrustServerCertificate `
                -ConnectionTimeoutSeconds $ConnectionTimeoutSeconds `
                -CommandTimeoutSeconds $CommandTimeoutSeconds `
                -RetryCount $RetryCount `
                -RetryDelaySeconds $RetryDelaySeconds)
        }
        finally {
            $PasswordCopy.Dispose()
        }

        if ($SqlInstances.Count -eq 0) {
            throw "RepositoryTable [$($RepositoryConfig.RepositorySchema)].[$($RepositoryConfig.RepositoryTable)] contains no usable InsName values."
        }

        return [pscustomobject]@{
            Credential                     = $Credential
            SqlInstances                   = $SqlInstances
            RepositoryInstance             = $RepositoryConfig.RepositoryInstance
            RepositoryDatabase             = $RepositoryConfig.RepositoryDatabase
            RepositorySchema               = $RepositoryConfig.RepositorySchema
            RepositoryTable                = $RepositoryConfig.RepositoryTable
            ReportSchema                   = 'dbo'
            TrustServerCertificate          = $TrustServerCertificate
            ConnectionTimeoutSeconds        = $ConnectionTimeoutSeconds
            CommandTimeoutSeconds           = $CommandTimeoutSeconds
            RetryCount                      = $RetryCount
            RetryDelaySeconds               = $RetryDelaySeconds
            PreviousTrustServerCertificate  = $PreviousTrustServerCertificate
            TrustSettingChanged             = $TrustSettingChanged
            OwnedSecurePassword             = $OwnedSecurePassword
            IsClosed                        = $false
        }
    }
    catch {
        if ($TrustSettingChanged) {
            [void](Set-DbatoolsConfig -FullName "sql.connection.trustcert" -Value $PreviousTrustServerCertificate -Register:$false)
        }
        if ($null -ne $OwnedSecurePassword) { $OwnedSecurePassword.Dispose() }
        throw
    }
}

function Close-SqlPerformanceContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Context)

    if ($Context.IsClosed) { return }

    if ($Context.TrustSettingChanged) {
        [void](Set-DbatoolsConfig -FullName "sql.connection.trustcert" -Value $Context.PreviousTrustServerCertificate -Register:$false)
    }

    if ($null -ne $Context.OwnedSecurePassword) {
        $Context.OwnedSecurePassword.Dispose()
        $Context.OwnedSecurePassword = $null
    }

    $Context.IsClosed = $true
}

function Show-SqlPerformanceContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Context)

    Write-Host "Repository: $($Context.RepositoryInstance) / $($Context.RepositoryDatabase)"
    Write-Host "Instance table: [$($Context.RepositorySchema)].[$($Context.RepositoryTable)]"
    Write-Host "Target instances: $($Context.SqlInstances -join ', ')"
    Write-Host "Report schema: [$($Context.ReportSchema)]"
}

function Initialize-SqlPerformanceReportTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [Parameter(Mandatory)][string]$CommandText
    )

    $PasswordCopy = $Context.Credential.Password.Copy()
    try {
        $PasswordCopy.MakeReadOnly()
        $SqlCredential = [System.Data.SqlClient.SqlCredential]::new($Context.Credential.UserName, $PasswordCopy)
        $Connection = New-SqlConnection `
            -DataSource $Context.RepositoryInstance `
            -InitialCatalog $Context.RepositoryDatabase `
            -SqlCredential $SqlCredential `
            -ConnectionTimeoutSeconds $Context.ConnectionTimeoutSeconds `
            -TrustServerCertificate:$Context.TrustServerCertificate `
            -ApplicationName "SqlPerformanceInfo"

        try {
            Invoke-SqlWithRetry -Step "InitializePerformanceRepositoryTable" -Instance $Context.RepositoryInstance -RetryCount $Context.RetryCount -RetryDelaySeconds $Context.RetryDelaySeconds -Operation {
                if ($Connection.State -ne [System.Data.ConnectionState]::Open) { $Connection.Open() }
                $Command = $Connection.CreateCommand()
                try {
                    $Command.CommandText = $CommandText
                    $Command.CommandTimeout = $Context.CommandTimeoutSeconds
                    [void]$Command.ExecuteNonQuery()
                }
                finally {
                    $Command.Dispose()
                }
            }
        }
        finally {
            if ($Connection.State -ne [System.Data.ConnectionState]::Closed) { $Connection.Close() }
            $Connection.Dispose()
        }
    }
    finally {
        $PasswordCopy.Dispose()
    }
}

function Write-SqlPerformanceRows {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [Parameter(Mandatory)][string]$Table,
        [AllowEmptyCollection()][object[]]$Rows
    )

    $InputRows = @($Rows)
    if ($InputRows.Count -eq 0) { return 0 }

    [void](
        Write-DbaDbTableData `
            -SqlInstance $Context.RepositoryInstance `
            -SqlCredential $Context.Credential `
            -Database $Context.RepositoryDatabase `
            -Schema $Context.ReportSchema `
            -Table $Table `
            -InputObject $InputRows `
            -BatchSize 1000 `
            -BulkCopyTimeOut $Context.CommandTimeoutSeconds `
            -NoTableLock `
            -KeepNulls `
            -EnableException `
            -Confirm:$false
    )

    return $InputRows.Count
}

Export-ModuleMember -Function @(
    'Get-ObjectPropertyValue',
    'Convert-ToNullableInt64',
    'Convert-ToNullableDouble',
    'Convert-ToNullableDateTime',
    'Convert-ToNullableBoolean',
    'Convert-QueryHashToString',
    'New-SqlPerformanceContext',
    'Close-SqlPerformanceContext',
    'Show-SqlPerformanceContext',
    'Initialize-SqlPerformanceReportTable',
    'Write-SqlPerformanceRows'
)
