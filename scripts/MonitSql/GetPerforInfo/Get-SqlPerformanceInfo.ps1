<#
.SYNOPSIS
Collects SQL Server table, index, and cached-query performance information.

.DESCRIPTION
Reads SQL Server instance names from the configured monitoring repository table
(the InsName column), then uses dbatools to collect the following information
from every listed instance:

* Table row counts, data/index space usage, and heap status
* Index usage, statistics, and optional fragmentation
* Duplicate/overlapping and unused indexes
* Top CPU, IO, and duration cached queries

Each collection step is isolated. A failure on one instance or one collection
type is written to Errors.csv and does not prevent the remaining work from
running. Results are exported as UTF-8 CSV files beneath a timestamped output
directory.

The same SQL credential is used for the repository and monitored instances.
When Credential is omitted, the AES key and encrypted credential created by
New-SqlCredentialKey.ps1 are loaded from CredentialDirectory.

.PARAMETER ConfigPath
Path to repository.config. The default is the configuration file under the
shared Config directory.

.PARAMETER RepositoryInstance
Optional override for RepositoryInstance in repository.config.

.PARAMETER RepositoryDatabase
Optional override for RepositoryDatabase in repository.config.

.PARAMETER RepositorySchema
Optional override for RepositorySchema in repository.config.

.PARAMETER RepositoryTable
Optional override for RepositoryTable in repository.config. The table must
contain an InsName varchar or nvarchar column.

.PARAMETER SqlLoginName
SQL Login whose stored credential is loaded. The default is srv.mn.

.PARAMETER CredentialDirectory
Directory containing <SqlLoginName>.key and
<SqlLoginName>.credential.xml. The default is the shared Credentials directory.

.PARAMETER Credential
Optional credential used instead of the encrypted credential files.

.PARAMETER Database
Optional user database names to include. When omitted, all accessible user
databases are included.

.PARAMETER ExcludeDatabase
Optional user database names to exclude.

.PARAMETER IncludeFragmentation
Controls collection of index fragmentation. The default is true. dbatools
Get-DbaHelpIndex uses DETAILED mode for this collection, which can be expensive
on large databases. Set it to false for lightweight inventory runs.

.PARAMETER IncludeOverlappingIndexes
Controls whether overlapping indexes are included with exact duplicate indexes.
The default is true.

.PARAMETER IgnoreUptimeForUnusedIndex
Bypasses the dbatools seven-day SQL Server uptime safeguard when identifying
unused indexes. The default is false because index usage DMV data is reset by
SQL Server restart and other events.

.PARAMETER TopQueryLimit
Maximum number of query hashes requested for each of CPU, IO, and Duration.

.PARAMETER OutputDirectory
Parent directory for timestamped result directories.

.PARAMETER TrustServerCertificate
Controls whether dbatools accepts SQL Server certificates whose chain is not
trusted by the local computer. The default is true for lab and self-signed
certificates. This setting applies only while this script runs and is restored
after collection completes.

.EXAMPLE
.\Get-SqlPerformanceInfo.ps1

Collects all report types from every instance in the configured repository.

.EXAMPLE
.\Get-SqlPerformanceInfo.ps1 `
    -Database AppDb,ReportDb `
    -IncludeFragmentation $false `
    -TopQueryLimit 10

Collects a lighter report for two databases.

.EXAMPLE
$Credential = Get-Credential -UserName srv.mn
.\Get-SqlPerformanceInfo.ps1 -Credential $Credential

Uses an explicitly supplied SQL credential instead of stored credential files.

.NOTES
Requires the dbatools PowerShell module. Cached-query and index usage data are
DMV-based and can be reset by SQL Server restart, database detach/close, or
plan-cache eviction. Do not remove indexes based on a single collection.

SQL Server 2019 and earlier generally require VIEW SERVER STATE. SQL Server
2022 and later generally require VIEW SERVER PERFORMANCE STATE for the related
server-level performance DMVs.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath = (
        Join-Path `
            (Split-Path -Parent $PSScriptRoot) `
            "Config\repository.config"
    ),

    [Parameter()]
    [Alias("Ins")]
    [ValidateNotNullOrEmpty()]
    [string]$RepositoryInstance,

    [Parameter()]
    [ValidatePattern('^[A-Za-z_][A-Za-z0-9_@$#]*$')]
    [string]$RepositoryDatabase,

    [Parameter()]
    [ValidatePattern('^[A-Za-z_][A-Za-z0-9_@$#]*$')]
    [string]$RepositorySchema,

    [Parameter()]
    [ValidatePattern('^[A-Za-z_][A-Za-z0-9_@$#]*$')]
    [string]$RepositoryTable,

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$SqlLoginName = "srv.mn",

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$CredentialDirectory = (
        Join-Path `
            (Split-Path -Parent $PSScriptRoot) `
            "Credentials"
    ),

    [Parameter()]
    [PSCredential]$Credential,

    [Parameter()]
    [string[]]$Database,

    [Parameter()]
    [string[]]$ExcludeDatabase,

    [Parameter()]
    [bool]$IncludeFragmentation = $true,

    [Parameter()]
    [bool]$IncludeOverlappingIndexes = $true,

    [Parameter()]
    [switch]$IgnoreUptimeForUnusedIndex,

    [Parameter()]
    [ValidateRange(1, 1000)]
    [int]$TopQueryLimit = 20,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory = (Join-Path $PSScriptRoot "Output"),

    [Parameter()]
    [bool]$TrustServerCertificate = $true,

    [Parameter()]
    [ValidateRange(1, 300)]
    [int]$ConnectionTimeoutSeconds = 15,

    [Parameter()]
    [ValidateRange(1, 3600)]
    [int]$CommandTimeoutSeconds = 120,

    [Parameter()]
    [ValidateRange(0, 20)]
    [int]$RetryCount = 3,

    [Parameter()]
    [ValidateRange(0, 300)]
    [int]$RetryDelaySeconds = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-ObjectPropertyValue {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    foreach ($CandidateName in $Name) {
        $Property = $InputObject.PSObject.Properties[$CandidateName]

        if ($null -ne $Property) {
            # Preserve byte arrays and other enumerable property values as one
            # value instead of allowing the PowerShell pipeline to unwrap them.
            return ,$Property.Value
        }
    }

    return $null
}

function Convert-ToNullableInt64 {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value
    )

    if (
        $null -eq $Value -or
        $Value -eq [DBNull]::Value -or
        [string]::IsNullOrWhiteSpace([string]$Value)
    ) {
        return $null
    }

    try {
        return [Convert]::ToInt64($Value)
    }
    catch {
        return $Value
    }
}

function Convert-ToNullableDouble {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value,

        [Parameter()]
        [ValidateRange(0, 10)]
        [int]$DecimalPlaces = 2
    )

    if (
        $null -eq $Value -or
        $Value -eq [DBNull]::Value -or
        [string]::IsNullOrWhiteSpace([string]$Value)
    ) {
        return $null
    }

    try {
        return [Math]::Round([Convert]::ToDouble($Value), $DecimalPlaces)
    }
    catch {
        return $Value
    }
}

function Convert-KilobyteToMegabyte {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value
    )

    if (
        $null -eq $Value -or
        $Value -eq [DBNull]::Value -or
        [string]::IsNullOrWhiteSpace([string]$Value)
    ) {
        return $null
    }

    $MegabyteValue = Get-ObjectPropertyValue `
        -InputObject $Value `
        -Name @("Megabyte", "Megabytes")

    if ($null -ne $MegabyteValue) {
        return [Math]::Round([double]$MegabyteValue, 2)
    }

    $KilobyteValue = Get-ObjectPropertyValue `
        -InputObject $Value `
        -Name @("Kilobyte", "Kilobytes")

    if ($null -ne $KilobyteValue) {
        return [Math]::Round(([double]$KilobyteValue / 1024), 2)
    }

    $ByteValue = Get-ObjectPropertyValue `
        -InputObject $Value `
        -Name @("Byte", "Bytes")

    if ($null -ne $ByteValue) {
        return [Math]::Round(([double]$ByteValue / 1MB), 2)
    }

    try {
        return [Math]::Round(([double]$Value / 1024), 2)
    }
    catch {
        return $Value
    }
}

function Convert-QueryHashToString {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value -or $Value -eq [DBNull]::Value) {
        return $null
    }

    if ($Value -is [byte[]]) {
        return "0x$([BitConverter]::ToString($Value).Replace('-', ''))"
    }

    $InnerValue = Get-ObjectPropertyValue `
        -InputObject $Value `
        -Name @("Value")

    if ($InnerValue -is [byte[]]) {
        return "0x$([BitConverter]::ToString($InnerValue).Replace('-', ''))"
    }

    return [string]$Value
}

function Convert-DateTimeToText {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value
    )

    if (
        $null -eq $Value -or
        $Value -eq [DBNull]::Value -or
        [string]::IsNullOrWhiteSpace([string]$Value)
    ) {
        return $null
    }

    try {
        $DateValue = [datetime]$Value

        if ($DateValue.Year -le 1901) {
            return $null
        }

        return $DateValue.ToString("yyyy-MM-ddTHH:mm:ss")
    }
    catch {
        return [string]$Value
    }
}

function Import-StoredSqlCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LoginName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LiteralDirectory
    )

    $KeyPath = Join-Path $LiteralDirectory "$LoginName.key"
    $CredentialPath =
        Join-Path $LiteralDirectory "$LoginName.credential.xml"

    if (-not (Test-Path -LiteralPath $KeyPath -PathType Leaf)) {
        throw (
            "SQL credential key not found: $KeyPath. Run " +
            "New-SqlCredentialKey.ps1 first or supply -Credential."
        )
    }

    if (-not (Test-Path -LiteralPath $CredentialPath -PathType Leaf)) {
        throw (
            "Encrypted SQL credential not found: $CredentialPath. Run " +
            "New-SqlCredentialKey.ps1 first or supply -Credential."
        )
    }

    [byte[]]$AesKey = [IO.File]::ReadAllBytes($KeyPath)

    try {
        if ($AesKey.Length -notin 16, 24, 32) {
            throw (
                "Invalid AES key length in [$KeyPath]: " +
                "$($AesKey.Length) bytes."
            )
        }

        $StoredCredential = Import-Clixml -LiteralPath $CredentialPath

        if (
            $StoredCredential.PSObject.Properties.Name `
                -notcontains "UserName" -or
            $StoredCredential.PSObject.Properties.Name `
                -notcontains "EncryptedPassword"
        ) {
            throw "Invalid SQL credential file: $CredentialPath"
        }

        $SecurePassword =
            $StoredCredential.EncryptedPassword |
                ConvertTo-SecureString -Key $AesKey

        return [pscustomobject]@{
            Credential = [PSCredential]::new(
                [string]$StoredCredential.UserName,
                $SecurePassword
            )
            SecurePassword = $SecurePassword
        }
    }
    finally {
        [Array]::Clear($AesKey, 0, $AesKey.Length)
    }
}

function New-UniqueRunDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ParentDirectory
    )

    if (-not (Test-Path -LiteralPath $ParentDirectory -PathType Container)) {
        [void](
            New-Item `
                -Path $ParentDirectory `
                -ItemType Directory `
                -Force
        )
    }

    $BaseName = "SqlPerformance_{0}" -f (Get-Date -Format "yyyyMMdd_HHmmss")
    $CandidatePath = Join-Path $ParentDirectory $BaseName
    $Suffix = 0

    while (Test-Path -LiteralPath $CandidatePath) {
        $Suffix++
        $CandidatePath = Join-Path `
            $ParentDirectory `
            ("{0}_{1:D2}" -f $BaseName, $Suffix)
    }

    [void](New-Item -Path $CandidatePath -ItemType Directory)
    return (Resolve-Path -LiteralPath $CandidatePath).Path
}

function Export-ResultRows {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [object[]]$Rows,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LiteralPath
    )

    $MaterializedRows = @($Rows)

    if ($MaterializedRows.Count -eq 0) {
        return 0
    }

    $ExportParameters = @{
        LiteralPath       = $LiteralPath
        NoTypeInformation = $true
        Encoding          = "UTF8"
    }

    if (Test-Path -LiteralPath $LiteralPath -PathType Leaf) {
        $ExportParameters.Append = $true
    }

    $MaterializedRows | Export-Csv @ExportParameters
    return $MaterializedRows.Count
}

function Add-CollectionError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$ErrorList,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SourceInstance,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Step,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Message
    )

    $ErrorList.Add(
        [pscustomobject][ordered]@{
            CollectedAtUtc = [DateTime]::UtcNow.ToString("o")
            SourceInstance = $SourceInstance
            Step           = $Step
            Message        = $Message
        }
    )
}

function Get-RepositoryInstanceName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$DataSource,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$InitialCatalog,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Schema,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Table,

        [Parameter(Mandatory)]
        [System.Data.SqlClient.SqlCredential]$SqlCredential,

        [Parameter(Mandatory)]
        [ValidateRange(1, 300)]
        [int]$ConnectionTimeout,

        [Parameter(Mandatory)]
        [ValidateRange(1, 3600)]
        [int]$CommandTimeout,

        [Parameter(Mandatory)]
        [ValidateRange(0, 20)]
        [int]$Retries,

        [Parameter(Mandatory)]
        [ValidateRange(0, 300)]
        [int]$RetryDelay,

        [Parameter()]
        [psobject]$LogContext
    )

    $QualifiedTable = "[$Schema].[$Table]"

    $Names = Invoke-SqlWithRetry `
        -Step "ReadRepositoryInstances" `
        -Instance $DataSource `
        -RetryCount $Retries `
        -RetryDelaySeconds $RetryDelay `
        -LogContext $LogContext `
        -Operation {
            $Connection = New-SqlConnection `
                -DataSource $DataSource `
                -InitialCatalog $InitialCatalog `
                -SqlCredential $SqlCredential `
                -ConnectionTimeoutSeconds $ConnectionTimeout `
                -ApplicationName "SQL Performance Inventory"

            try {
                $Connection.Open()
                $Command = $Connection.CreateCommand()

                try {
                    $Command.CommandTimeout = $CommandTimeout
                    $Command.CommandText = @"
SET NOCOUNT ON;

SELECT DISTINCT
    LTRIM(RTRIM(CONVERT(nvarchar(128), [InsName]))) AS [InsName]
FROM $QualifiedTable
WHERE NULLIF(
    LTRIM(RTRIM(CONVERT(nvarchar(128), [InsName]))),
    N''
) IS NOT NULL
ORDER BY [InsName];
"@
                    $Reader = $Command.ExecuteReader()
                    $Result = [System.Collections.Generic.List[string]]::new()

                    try {
                        while ($Reader.Read()) {
                            $Result.Add([string]$Reader["InsName"])
                        }
                    }
                    finally {
                        $Reader.Dispose()
                    }

                    return $Result.ToArray()
                }
                finally {
                    $Command.Dispose()
                }
            }
            finally {
                $Connection.Dispose()
            }
        }

    return @($Names)
}

$CommonModulePath = Join-Path `
    (Split-Path -Parent $PSScriptRoot) `
    "Modules\SqlMaintenance.Common\SqlMaintenance.Common.psm1"

if (-not (Test-Path -LiteralPath $CommonModulePath -PathType Leaf)) {
    throw "Required module not found: $CommonModulePath"
}

Import-Module $CommonModulePath -Force

$RequiredDbatoolsCommands = @(
    "Get-DbaDatabase",
    "Get-DbaDbTable",
    "Get-DbaHelpIndex",
    "Find-DbaDbDuplicateIndex",
    "Find-DbaDbUnusedIndex",
    "Get-DbaTopResourceUsage",
    "Get-DbatoolsConfigValue",
    "Set-DbatoolsConfig"
)

try {
    Import-Module dbatools -ErrorAction Stop
}
catch {
    throw (
        "The dbatools PowerShell module is required but could not be " +
        "loaded. Install it with Install-Module dbatools -Scope " +
        "CurrentUser. $($_.Exception.Message)"
    )
}

$MissingDbatoolsCommands = @(
    foreach ($CommandName in $RequiredDbatoolsCommands) {
        if ($null -eq (Get-Command $CommandName -ErrorAction SilentlyContinue)) {
            $CommandName
        }
    }
)

if ($MissingDbatoolsCommands.Count -gt 0) {
    throw (
        "The installed dbatools module does not provide: " +
        ($MissingDbatoolsCommands -join ", ")
    )
}

$RepositoryConfigParameters = @{
    LiteralPath = $ConfigPath
}

foreach (
    $RepositoryParameterName in @(
        "RepositoryInstance",
        "RepositoryDatabase",
        "RepositorySchema",
        "RepositoryTable"
    )
) {
    if ($PSBoundParameters.ContainsKey($RepositoryParameterName)) {
        $RepositoryConfigParameters[$RepositoryParameterName] =
            $PSBoundParameters[$RepositoryParameterName]
    }
}

$RepositoryConfig = Get-SqlRepositoryConfig @RepositoryConfigParameters
$RepositoryInstance = $RepositoryConfig.RepositoryInstance
$RepositoryDatabase = $RepositoryConfig.RepositoryDatabase
$RepositorySchema = $RepositoryConfig.RepositorySchema
$RepositoryTable = $RepositoryConfig.RepositoryTable
$RunOutputDirectory = New-UniqueRunDirectory `
    -ParentDirectory $OutputDirectory
$LogContext = New-SqlMaintenanceLogContext `
    -LogDirectory (Join-Path $RunOutputDirectory "Logs") `
    -OperationName "Get-SqlPerformanceInfo"
$LoadedSecurePassword = $null
$ReadOnlyPassword = $null
$RepositorySqlCredential = $null
$DbatoolsTrustCertificateConfigName = "sql.connection.trustcert"
$PreviousDbatoolsTrustCertificate = $null
$DbatoolsTrustCertificateConfigured = $false
$CollectionErrors = [System.Collections.Generic.List[object]]::new()
$RunSummary = [System.Collections.Generic.List[object]]::new()

$OutputPaths = @{
    Tables           = Join-Path $RunOutputDirectory "Tables.csv"
    IndexUsage       = Join-Path $RunOutputDirectory "IndexUsage.csv"
    Statistics       = Join-Path $RunOutputDirectory "Statistics.csv"
    DuplicateIndexes = Join-Path $RunOutputDirectory "DuplicateIndexes.csv"
    UnusedIndexes    = Join-Path $RunOutputDirectory "UnusedIndexes.csv"
    TopQueries       = Join-Path $RunOutputDirectory "TopQueries.csv"
    Errors           = Join-Path $RunOutputDirectory "Errors.csv"
    Summary          = Join-Path $RunOutputDirectory "RunSummary.csv"
}

try {
    $PreviousDbatoolsTrustCertificate = Get-DbatoolsConfigValue `
        -FullName $DbatoolsTrustCertificateConfigName
    Set-DbatoolsConfig `
        -FullName $DbatoolsTrustCertificateConfigName `
        -Value $TrustServerCertificate
    $DbatoolsTrustCertificateConfigured = $true

    if ($null -eq $Credential) {
        $LoadedCredential = Import-StoredSqlCredential `
            -LoginName $SqlLoginName `
            -LiteralDirectory $CredentialDirectory
        $Credential = $LoadedCredential.Credential
        $LoadedSecurePassword = $LoadedCredential.SecurePassword
    }

    if ($Credential.UserName -cne $SqlLoginName) {
        throw (
            "Credential user [$($Credential.UserName)] does not match " +
            "SqlLoginName [$SqlLoginName]."
        )
    }

    Write-SqlMaintenanceLog `
        -LogContext $LogContext `
        -Level Info `
        -Step "Start" `
        -Message (
            "Starting SQL performance collection. Output: " +
            $RunOutputDirectory
        )

    [void](
        Test-SqlMonitorRepository `
            -RepositoryInstance $RepositoryInstance `
            -RepositoryDatabase $RepositoryDatabase `
            -RepositorySchema $RepositorySchema `
            -RepositoryTable $RepositoryTable `
            -Credential $Credential `
            -ConnectionTimeoutSeconds $ConnectionTimeoutSeconds `
            -CommandTimeoutSeconds $CommandTimeoutSeconds `
            -RetryCount $RetryCount `
            -RetryDelaySeconds $RetryDelaySeconds `
            -LogContext $LogContext
    )

    $ReadOnlyPassword = $Credential.Password.Copy()
    $ReadOnlyPassword.MakeReadOnly()
    $RepositorySqlCredential =
        [System.Data.SqlClient.SqlCredential]::new(
            $Credential.UserName,
            $ReadOnlyPassword
        )
    $SourceInstances = @(
        Get-RepositoryInstanceName `
            -DataSource $RepositoryInstance `
            -InitialCatalog $RepositoryDatabase `
            -Schema $RepositorySchema `
            -Table $RepositoryTable `
            -SqlCredential $RepositorySqlCredential `
            -ConnectionTimeout $ConnectionTimeoutSeconds `
            -CommandTimeout $CommandTimeoutSeconds `
            -Retries $RetryCount `
            -RetryDelay $RetryDelaySeconds `
            -LogContext $LogContext
    )

    if ($SourceInstances.Count -eq 0) {
        throw (
            "No SQL Server instances were found in " +
            "$RepositoryDatabase.[$RepositorySchema].[$RepositoryTable]."
        )
    }

    Write-Host "Repository: $RepositoryInstance/$RepositoryDatabase"
    Write-Host "Instance count: $($SourceInstances.Count)"
    Write-Host "Output: $RunOutputDirectory"

    for (
        $InstanceIndex = 0;
        $InstanceIndex -lt $SourceInstances.Count;
        $InstanceIndex++
    ) {
        $SourceInstance = $SourceInstances[$InstanceIndex]
        $CollectedAtUtc = [DateTime]::UtcNow.ToString("o")
        $InstanceHadError = $false
        $TableCount = 0
        $IndexUsageCount = 0
        $StatisticsCount = 0
        $DuplicateIndexCount = 0
        $UnusedIndexCount = 0
        $TopQueryCount = 0
        $DatabaseCount = 0

        Write-Progress `
            -Activity "Collecting SQL Server performance information" `
            -Status $SourceInstance `
            -PercentComplete (
                [int](($InstanceIndex / $SourceInstances.Count) * 100)
            )

        Write-SqlMaintenanceLog `
            -LogContext $LogContext `
            -Level Info `
            -Step "Instance" `
            -Instance $SourceInstance `
            -Message "Collection started."

        try {
            $DatabaseParameters = @{
                SqlInstance    = $SourceInstance
                SqlCredential  = $Credential
                ExcludeSystem  = $true
                OnlyAccessible = $true
                EnableException = $true
            }

            if ($PSBoundParameters.ContainsKey("Database")) {
                $DatabaseParameters.Database = $Database
            }

            if ($PSBoundParameters.ContainsKey("ExcludeDatabase")) {
                $DatabaseParameters.ExcludeDatabase = $ExcludeDatabase
            }

            $DatabaseObjects = @(
                Get-DbaDatabase @DatabaseParameters
            )
            $DatabaseNames = @(
                foreach ($DatabaseObject in $DatabaseObjects) {
                    $DatabaseObject.Name
                }
            )
            $DatabaseCount = $DatabaseNames.Count

            if ($DatabaseCount -eq 0) {
                throw "No accessible user databases matched the filters."
            }
        }
        catch {
            $InstanceHadError = $true
            Add-CollectionError `
                -ErrorList $CollectionErrors `
                -SourceInstance $SourceInstance `
                -Step "DatabaseDiscovery" `
                -Message $_.Exception.Message
            Write-SqlMaintenanceLog `
                -LogContext $LogContext `
                -Level Error `
                -Step "DatabaseDiscovery" `
                -Instance $SourceInstance `
                -Message $_.Exception.Message

            $RunSummary.Add(
                [pscustomobject][ordered]@{
                    CollectedAtUtc      = $CollectedAtUtc
                    SourceInstance      = $SourceInstance
                    Status              = "Failed"
                    DatabaseCount       = 0
                    TableCount          = 0
                    IndexUsageCount     = 0
                    StatisticsCount     = 0
                    DuplicateIndexCount = 0
                    UnusedIndexCount    = 0
                    TopQueryCount       = 0
                }
            )
            continue
        }

        try {
            $TableRows = @(
                foreach (
                    $TableInfo in Get-DbaDbTable `
                        -InputObject $DatabaseObjects `
                        -EnableException
                ) {
                    $DataMB = Convert-KilobyteToMegabyte `
                        -Value (Get-ObjectPropertyValue `
                            -InputObject $TableInfo `
                            -Name @("DataSpaceUsed"))
                    $IndexMB = Convert-KilobyteToMegabyte `
                        -Value (Get-ObjectPropertyValue `
                            -InputObject $TableInfo `
                            -Name @("IndexSpaceUsed"))
                    $HasClusteredIndex = [bool](
                        Get-ObjectPropertyValue `
                            -InputObject $TableInfo `
                            -Name @("HasClusteredIndex")
                    )

                    [pscustomobject][ordered]@{
                        CollectedAtUtc     = $CollectedAtUtc
                        SourceInstance     = $SourceInstance
                        SqlInstance        = Get-ObjectPropertyValue `
                            -InputObject $TableInfo `
                            -Name @("SqlInstance")
                        Database           = Get-ObjectPropertyValue `
                            -InputObject $TableInfo `
                            -Name @("Database")
                        Schema             = Get-ObjectPropertyValue `
                            -InputObject $TableInfo `
                            -Name @("Schema")
                        Table              = Get-ObjectPropertyValue `
                            -InputObject $TableInfo `
                            -Name @("Name")
                        RowCount           = Convert-ToNullableInt64 `
                            -Value (Get-ObjectPropertyValue `
                                -InputObject $TableInfo `
                                -Name @("RowCount"))
                        DataMB             = $DataMB
                        IndexMB            = $IndexMB
                        TotalMB            = if (
                            $DataMB -is [ValueType] -and
                            $IndexMB -is [ValueType]
                        ) {
                            [Math]::Round(
                                ([double]$DataMB + [double]$IndexMB),
                                2
                            )
                        }
                        else {
                            $null
                        }
                        HasClusteredIndex = $HasClusteredIndex
                        IsHeap             = -not $HasClusteredIndex
                    }
                }
            )
            $TableCount = Export-ResultRows `
                -Rows $TableRows `
                -LiteralPath $OutputPaths.Tables
        }
        catch {
            $InstanceHadError = $true
            Add-CollectionError `
                -ErrorList $CollectionErrors `
                -SourceInstance $SourceInstance `
                -Step "Tables" `
                -Message $_.Exception.Message
        }

        try {
            $IndexParameters = @{
                InputObject     = $DatabaseObjects
                IncludeStats    = $true
                Raw             = $true
                EnableException = $true
            }

            if ($IncludeFragmentation) {
                $IndexParameters.IncludeFragmentation = $true
            }

            $IndexDetails = @(Get-DbaHelpIndex @IndexParameters)
            $IndexUsageRows = @(
                foreach ($IndexInfo in $IndexDetails) {
                    $IndexName = Get-ObjectPropertyValue `
                        -InputObject $IndexInfo `
                        -Name @("Index", "IndexName")

                    if ([string]::IsNullOrWhiteSpace([string]$IndexName)) {
                        continue
                    }

                    [pscustomobject][ordered]@{
                        CollectedAtUtc     = $CollectedAtUtc
                        SourceInstance     = $SourceInstance
                        SqlInstance        = Get-ObjectPropertyValue `
                            -InputObject $IndexInfo `
                            -Name @("SqlInstance")
                        Database           = Get-ObjectPropertyValue `
                            -InputObject $IndexInfo `
                            -Name @("Database")
                        Object             = Get-ObjectPropertyValue `
                            -InputObject $IndexInfo `
                            -Name @("Object", "ObjectName")
                        Index              = $IndexName
                        IndexType          = Get-ObjectPropertyValue `
                            -InputObject $IndexInfo `
                            -Name @("IndexType")
                        KeyColumns         = Get-ObjectPropertyValue `
                            -InputObject $IndexInfo `
                            -Name @("KeyColumns")
                        IncludeColumns     = Get-ObjectPropertyValue `
                            -InputObject $IndexInfo `
                            -Name @("IncludeColumns", "IncludedColumns")
                        FilterDefinition   = Get-ObjectPropertyValue `
                            -InputObject $IndexInfo `
                            -Name @("FilterDefinition")
                        FillFactor         = Convert-ToNullableInt64 `
                            -Value (Get-ObjectPropertyValue `
                                -InputObject $IndexInfo `
                                -Name @("FillFactor"))
                        DataCompression    = Get-ObjectPropertyValue `
                            -InputObject $IndexInfo `
                            -Name @("DataCompression")
                        IndexReads         = Convert-ToNullableInt64 `
                            -Value (Get-ObjectPropertyValue `
                                -InputObject $IndexInfo `
                                -Name @("IndexReads"))
                        IndexUpdates       = Convert-ToNullableInt64 `
                            -Value (Get-ObjectPropertyValue `
                                -InputObject $IndexInfo `
                                -Name @("IndexUpdates"))
                        IndexLookups       = Convert-ToNullableInt64 `
                            -Value (Get-ObjectPropertyValue `
                                -InputObject $IndexInfo `
                                -Name @("IndexLookups"))
                        MostRecentlyUsed   = Convert-DateTimeToText `
                            -Value (Get-ObjectPropertyValue `
                                -InputObject $IndexInfo `
                                -Name @("MostRecentlyUsed"))
                        SizeMB             = Convert-KilobyteToMegabyte `
                            -Value (Get-ObjectPropertyValue `
                                -InputObject $IndexInfo `
                                -Name @("Size", "SizeKB"))
                        IndexRows          = Convert-ToNullableInt64 `
                            -Value (Get-ObjectPropertyValue `
                                -InputObject $IndexInfo `
                                -Name @("IndexRows"))
                        FragmentationPct   = Convert-ToNullableDouble `
                            -Value (Get-ObjectPropertyValue `
                                -InputObject $IndexInfo `
                                -Name @("IndexFragInPercent"))
                        StatsSampleRows    = Convert-ToNullableInt64 `
                            -Value (Get-ObjectPropertyValue `
                                -InputObject $IndexInfo `
                                -Name @("StatsSampleRows"))
                        StatsRowMods       = Convert-ToNullableInt64 `
                            -Value (Get-ObjectPropertyValue `
                                -InputObject $IndexInfo `
                                -Name @("StatsRowMods"))
                        HistogramSteps     = Convert-ToNullableInt64 `
                            -Value (Get-ObjectPropertyValue `
                                -InputObject $IndexInfo `
                                -Name @("HistogramSteps"))
                        StatsLastUpdated   = Convert-DateTimeToText `
                            -Value (Get-ObjectPropertyValue `
                                -InputObject $IndexInfo `
                                -Name @("StatsLastUpdated"))
                    }
                }
            )
            $StatisticsRows = @(
                foreach ($IndexInfo in $IndexDetails) {
                    $StatisticsName = Get-ObjectPropertyValue `
                        -InputObject $IndexInfo `
                        -Name @("Statistics", "StatisticsName")

                    if (
                        [string]::IsNullOrWhiteSpace(
                            [string]$StatisticsName
                        )
                    ) {
                        continue
                    }

                    [pscustomobject][ordered]@{
                        CollectedAtUtc   = $CollectedAtUtc
                        SourceInstance   = $SourceInstance
                        SqlInstance      = Get-ObjectPropertyValue `
                            -InputObject $IndexInfo `
                            -Name @("SqlInstance")
                        Database         = Get-ObjectPropertyValue `
                            -InputObject $IndexInfo `
                            -Name @("Database")
                        Object           = Get-ObjectPropertyValue `
                            -InputObject $IndexInfo `
                            -Name @("Object", "ObjectName")
                        Statistics       = $StatisticsName
                        Columns          = Get-ObjectPropertyValue `
                            -InputObject $IndexInfo `
                            -Name @("KeyColumns")
                        RowCount         = Convert-ToNullableInt64 `
                            -Value (Get-ObjectPropertyValue `
                                -InputObject $IndexInfo `
                                -Name @("IndexRows"))
                        SampleRows       = Convert-ToNullableInt64 `
                            -Value (Get-ObjectPropertyValue `
                                -InputObject $IndexInfo `
                                -Name @("StatsSampleRows"))
                        ModifiedRows     = Convert-ToNullableInt64 `
                            -Value (Get-ObjectPropertyValue `
                                -InputObject $IndexInfo `
                                -Name @("StatsRowMods"))
                        HistogramSteps   = Convert-ToNullableInt64 `
                            -Value (Get-ObjectPropertyValue `
                                -InputObject $IndexInfo `
                                -Name @("HistogramSteps"))
                        LastUpdated      = Convert-DateTimeToText `
                            -Value (Get-ObjectPropertyValue `
                                -InputObject $IndexInfo `
                                -Name @("StatsLastUpdated"))
                    }
                }
            )
            $IndexUsageCount = Export-ResultRows `
                -Rows $IndexUsageRows `
                -LiteralPath $OutputPaths.IndexUsage
            $StatisticsCount = Export-ResultRows `
                -Rows $StatisticsRows `
                -LiteralPath $OutputPaths.Statistics
        }
        catch {
            $InstanceHadError = $true
            Add-CollectionError `
                -ErrorList $CollectionErrors `
                -SourceInstance $SourceInstance `
                -Step "IndexUsageAndFragmentation" `
                -Message $_.Exception.Message
        }

        try {
            $DuplicateSearchTypes = @("Exact")

            if ($IncludeOverlappingIndexes) {
                $DuplicateSearchTypes += "Overlapping"
            }

            $DuplicateRows = @(
                foreach ($DuplicateSearchType in $DuplicateSearchTypes) {
                    $DuplicateParameters = @{
                        SqlInstance     = $SourceInstance
                        SqlCredential   = $Credential
                        Database        = $DatabaseNames
                        EnableException = $true
                    }

                    if ($DuplicateSearchType -eq "Overlapping") {
                        $DuplicateParameters.IncludeOverlapping = $true
                    }

                    foreach (
                        $DuplicateInfo in Find-DbaDbDuplicateIndex `
                            @DuplicateParameters
                    ) {
                        [pscustomobject][ordered]@{
                            CollectedAtUtc        = $CollectedAtUtc
                            SourceInstance        = $SourceInstance
                            DetectionType         = $DuplicateSearchType
                            Database              = Get-ObjectPropertyValue `
                                -InputObject $DuplicateInfo `
                                -Name @("DatabaseName", "Database")
                            Table                 = Get-ObjectPropertyValue `
                                -InputObject $DuplicateInfo `
                                -Name @("TableName", "Table")
                            Index                 = Get-ObjectPropertyValue `
                                -InputObject $DuplicateInfo `
                                -Name @("IndexName", "Index")
                            KeyColumns            = Get-ObjectPropertyValue `
                                -InputObject $DuplicateInfo `
                                -Name @("KeyColumns")
                            IncludedColumns       = Get-ObjectPropertyValue `
                                -InputObject $DuplicateInfo `
                                -Name @(
                                    "IncludedColumns",
                                    "IncludeColumns"
                                )
                            IndexType             = Get-ObjectPropertyValue `
                                -InputObject $DuplicateInfo `
                                -Name @("IndexType", "TypeDesc")
                            IndexSizeMB           = Convert-ToNullableDouble `
                                -Value (Get-ObjectPropertyValue `
                                    -InputObject $DuplicateInfo `
                                    -Name @("IndexSizeMB"))
                            RowCount              = Convert-ToNullableInt64 `
                                -Value (Get-ObjectPropertyValue `
                                    -InputObject $DuplicateInfo `
                                    -Name @("RowCount"))
                            IsDisabled            = Get-ObjectPropertyValue `
                                -InputObject $DuplicateInfo `
                                -Name @("IsDisabled")
                            IsUnique              = Get-ObjectPropertyValue `
                                -InputObject $DuplicateInfo `
                                -Name @("IsUnique")
                            IsFiltered            = Get-ObjectPropertyValue `
                                -InputObject $DuplicateInfo `
                                -Name @("IsFiltered")
                            CompressionDescription =
                                Get-ObjectPropertyValue `
                                    -InputObject $DuplicateInfo `
                                    -Name @("CompressionDescription")
                        }
                    }
                }
            )
            $DuplicateIndexCount = Export-ResultRows `
                -Rows $DuplicateRows `
                -LiteralPath $OutputPaths.DuplicateIndexes
        }
        catch {
            $InstanceHadError = $true
            Add-CollectionError `
                -ErrorList $CollectionErrors `
                -SourceInstance $SourceInstance `
                -Step "DuplicateIndexes" `
                -Message $_.Exception.Message
        }

        try {
            $UnusedParameters = @{
                InputObject     = $DatabaseObjects
                EnableException = $true
            }

            if ($IgnoreUptimeForUnusedIndex) {
                $UnusedParameters.IgnoreUptime = $true
            }

            $UnusedRows = @(
                foreach (
                    $UnusedInfo in Find-DbaDbUnusedIndex `
                        @UnusedParameters
                ) {
                    [pscustomobject][ordered]@{
                        CollectedAtUtc = $CollectedAtUtc
                        SourceInstance = $SourceInstance
                        SqlInstance    = Get-ObjectPropertyValue `
                            -InputObject $UnusedInfo `
                            -Name @("SqlInstance")
                        Database       = Get-ObjectPropertyValue `
                            -InputObject $UnusedInfo `
                            -Name @("Database")
                        Schema         = Get-ObjectPropertyValue `
                            -InputObject $UnusedInfo `
                            -Name @("Schema")
                        Table          = Get-ObjectPropertyValue `
                            -InputObject $UnusedInfo `
                            -Name @("Table")
                        Index          = Get-ObjectPropertyValue `
                            -InputObject $UnusedInfo `
                            -Name @("IndexName", "Index")
                        IndexId        = Convert-ToNullableInt64 `
                            -Value (Get-ObjectPropertyValue `
                                -InputObject $UnusedInfo `
                                -Name @("IndexId"))
                        IndexType      = Get-ObjectPropertyValue `
                            -InputObject $UnusedInfo `
                            -Name @("TypeDesc", "IndexType")
                        UserSeeks      = Convert-ToNullableInt64 `
                            -Value (Get-ObjectPropertyValue `
                                -InputObject $UnusedInfo `
                                -Name @("UserSeeks"))
                        UserScans      = Convert-ToNullableInt64 `
                            -Value (Get-ObjectPropertyValue `
                                -InputObject $UnusedInfo `
                                -Name @("UserScans"))
                        UserLookups    = Convert-ToNullableInt64 `
                            -Value (Get-ObjectPropertyValue `
                                -InputObject $UnusedInfo `
                                -Name @("UserLookups"))
                        UserUpdates    = Convert-ToNullableInt64 `
                            -Value (Get-ObjectPropertyValue `
                                -InputObject $UnusedInfo `
                                -Name @("UserUpdates"))
                        LastUserSeek   = Convert-DateTimeToText `
                            -Value (Get-ObjectPropertyValue `
                                -InputObject $UnusedInfo `
                                -Name @("LastUserSeek"))
                        LastUserScan   = Convert-DateTimeToText `
                            -Value (Get-ObjectPropertyValue `
                                -InputObject $UnusedInfo `
                                -Name @("LastUserScan"))
                        LastUserLookup = Convert-DateTimeToText `
                            -Value (Get-ObjectPropertyValue `
                                -InputObject $UnusedInfo `
                                -Name @("LastUserLookup"))
                        LastUserUpdate = Convert-DateTimeToText `
                            -Value (Get-ObjectPropertyValue `
                                -InputObject $UnusedInfo `
                                -Name @("LastUserUpdate"))
                        IndexSizeMB    = Convert-ToNullableDouble `
                            -Value (Get-ObjectPropertyValue `
                                -InputObject $UnusedInfo `
                                -Name @("IndexSizeMB"))
                        RowCount       = Convert-ToNullableInt64 `
                            -Value (Get-ObjectPropertyValue `
                                -InputObject $UnusedInfo `
                                -Name @("RowCount"))
                        CompressionDescription = Get-ObjectPropertyValue `
                            -InputObject $UnusedInfo `
                            -Name @("CompressionDescription")
                        UptimeIgnored  = [bool]$IgnoreUptimeForUnusedIndex
                    }
                }
            )
            $UnusedIndexCount = Export-ResultRows `
                -Rows $UnusedRows `
                -LiteralPath $OutputPaths.UnusedIndexes
        }
        catch {
            $InstanceHadError = $true
            Add-CollectionError `
                -ErrorList $CollectionErrors `
                -SourceInstance $SourceInstance `
                -Step "UnusedIndexes" `
                -Message $_.Exception.Message
        }

        foreach ($Metric in @("CPU", "IO", "Duration")) {
            try {
                $TopQueryRows = @(
                    foreach (
                        $QueryInfo in Get-DbaTopResourceUsage `
                            -SqlInstance $SourceInstance `
                            -SqlCredential $Credential `
                            -Database $DatabaseNames `
                            -Type $Metric `
                            -Limit $TopQueryLimit `
                            -ExcludeSystem `
                            -EnableException
                    ) {
                        [pscustomobject][ordered]@{
                            CollectedAtUtc         = $CollectedAtUtc
                            SourceInstance         = $SourceInstance
                            Metric                 = $Metric
                            SqlInstance            = Get-ObjectPropertyValue `
                                -InputObject $QueryInfo `
                                -Name @("SqlInstance")
                            Database               = Get-ObjectPropertyValue `
                                -InputObject $QueryInfo `
                                -Name @("Database")
                            ObjectName             = Get-ObjectPropertyValue `
                                -InputObject $QueryInfo `
                                -Name @("ObjectName")
                            QueryHash              = Convert-QueryHashToString `
                                -Value (Get-ObjectPropertyValue `
                                    -InputObject $QueryInfo `
                                    -Name @("QueryHash"))
                            ExecutionCount         = Convert-ToNullableInt64 `
                                -Value (Get-ObjectPropertyValue `
                                    -InputObject $QueryInfo `
                                    -Name @("ExecutionCount"))
                            TotalElapsedTimeMs     = Convert-ToNullableDouble `
                                -Value (Get-ObjectPropertyValue `
                                    -InputObject $QueryInfo `
                                    -Name @("TotalElapsedTimeMs"))
                            AverageDurationMs      = Convert-ToNullableDouble `
                                -Value (Get-ObjectPropertyValue `
                                    -InputObject $QueryInfo `
                                    -Name @("AverageDurationMs"))
                            QueryTotalElapsedTimeMs = Convert-ToNullableDouble `
                                -Value (Get-ObjectPropertyValue `
                                    -InputObject $QueryInfo `
                                    -Name @("QueryTotalElapsedTimeMs"))
                            TotalIO                = Convert-ToNullableInt64 `
                                -Value (Get-ObjectPropertyValue `
                                    -InputObject $QueryInfo `
                                    -Name @("TotalIO"))
                            AverageIO              = Convert-ToNullableDouble `
                                -Value (Get-ObjectPropertyValue `
                                    -InputObject $QueryInfo `
                                    -Name @("AverageIO"))
                            QueryTotalIO           = Convert-ToNullableInt64 `
                                -Value (Get-ObjectPropertyValue `
                                    -InputObject $QueryInfo `
                                    -Name @("QueryTotalIO"))
                            CpuTime                = Convert-ToNullableInt64 `
                                -Value (Get-ObjectPropertyValue `
                                    -InputObject $QueryInfo `
                                    -Name @("CpuTime"))
                            AverageCpuMs           = Convert-ToNullableDouble `
                                -Value (Get-ObjectPropertyValue `
                                    -InputObject $QueryInfo `
                                    -Name @("AverageCpuMs"))
                            QueryTotalCpu          = Convert-ToNullableInt64 `
                                -Value (Get-ObjectPropertyValue `
                                    -InputObject $QueryInfo `
                                    -Name @("QueryTotalCpu"))
                            QueryText              = Get-ObjectPropertyValue `
                                -InputObject $QueryInfo `
                                -Name @("QueryText")
                        }
                    }
                )
                $TopQueryCount += Export-ResultRows `
                    -Rows $TopQueryRows `
                    -LiteralPath $OutputPaths.TopQueries
            }
            catch {
                $InstanceHadError = $true
                Add-CollectionError `
                    -ErrorList $CollectionErrors `
                    -SourceInstance $SourceInstance `
                    -Step "TopQuery-$Metric" `
                    -Message $_.Exception.Message
            }
        }

        $InstanceStatus = if ($InstanceHadError) {
            "CompletedWithErrors"
        }
        else {
            "Success"
        }

        $RunSummary.Add(
            [pscustomobject][ordered]@{
                CollectedAtUtc      = $CollectedAtUtc
                SourceInstance      = $SourceInstance
                Status              = $InstanceStatus
                DatabaseCount       = $DatabaseCount
                TableCount          = $TableCount
                IndexUsageCount     = $IndexUsageCount
                StatisticsCount     = $StatisticsCount
                DuplicateIndexCount = $DuplicateIndexCount
                UnusedIndexCount    = $UnusedIndexCount
                TopQueryCount       = $TopQueryCount
            }
        )

        Write-SqlMaintenanceLog `
            -LogContext $LogContext `
            -Level Info `
            -Step "Instance" `
            -Instance $SourceInstance `
            -Message (
                "Collection completed with status [$InstanceStatus]."
            )
    }

    Write-Progress `
        -Activity "Collecting SQL Server performance information" `
        -Completed

    [void](
        Export-ResultRows `
            -Rows $RunSummary.ToArray() `
            -LiteralPath $OutputPaths.Summary
    )

    if ($CollectionErrors.Count -gt 0) {
        [void](
            Export-ResultRows `
                -Rows $CollectionErrors.ToArray() `
                -LiteralPath $OutputPaths.Errors
        )
    }

    Write-SqlMaintenanceLog `
        -LogContext $LogContext `
        -Level Info `
        -Step "Complete" `
        -Message (
            "Collection finished for $($SourceInstances.Count) " +
            "instance(s) with $($CollectionErrors.Count) error(s)."
        )

    Write-Host ""
    Write-Host "Collection completed."
    Write-Host "Output: $RunOutputDirectory"
    Write-Host "Errors: $($CollectionErrors.Count)"

    [pscustomobject]@{
        OutputDirectory = $RunOutputDirectory
        InstanceCount   = $SourceInstances.Count
        ErrorCount      = $CollectionErrors.Count
        SummaryPath     = $OutputPaths.Summary
        ErrorPath       = if ($CollectionErrors.Count -gt 0) {
            $OutputPaths.Errors
        }
        else {
            $null
        }
    }
}
finally {
    if ($DbatoolsTrustCertificateConfigured) {
        try {
            Set-DbatoolsConfig `
                -FullName $DbatoolsTrustCertificateConfigName `
                -Value $PreviousDbatoolsTrustCertificate
        }
        catch {
            Write-Warning (
                "Could not restore dbatools setting " +
                "[$DbatoolsTrustCertificateConfigName]: " +
                $_.Exception.Message
            )
        }
    }

    $RepositorySqlCredential = $null

    if ($null -ne $ReadOnlyPassword) {
        $ReadOnlyPassword.Dispose()
    }

    if ($null -ne $LoadedSecurePassword) {
        $LoadedSecurePassword.Dispose()
    }
}
