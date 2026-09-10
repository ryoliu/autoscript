Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-SqlRepositoryConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LiteralPath,

        [Parameter()]
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
        [string]$RepositoryTable
    )

    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
        throw "Repository configuration file not found: $LiteralPath"
    }

    $RequiredKeys = @(
        "RepositoryInstance",
        "RepositoryDatabase",
        "RepositorySchema",
        "RepositoryTable",
        "SqlLoginName"
    )
    $FileValues = @{}
    $LineNumber = 0

    foreach (
        $ConfigLine in Get-Content `
            -LiteralPath $LiteralPath `
            -Encoding UTF8
    ) {
        $LineNumber++
        $TrimmedLine = $ConfigLine.Trim()

        if (
            [string]::IsNullOrWhiteSpace($TrimmedLine) -or
            $TrimmedLine.StartsWith("#")
        ) {
            continue
        }

        $SeparatorIndex = $TrimmedLine.IndexOf("=")

        if ($SeparatorIndex -lt 1) {
            throw (
                "Invalid repository configuration at " +
                "[$LiteralPath] line $LineNumber. Expected Key=Value."
            )
        }

        $Key = $TrimmedLine.Substring(0, $SeparatorIndex).Trim()
        $Value = $TrimmedLine.Substring($SeparatorIndex + 1).Trim()

        if ($RequiredKeys -notcontains $Key) {
            throw (
                "Unknown repository configuration key [$Key] at " +
                "[$LiteralPath] line $LineNumber."
            )
        }

        if ($FileValues.ContainsKey($Key)) {
            throw (
                "Duplicate repository configuration key [$Key] at " +
                "[$LiteralPath] line $LineNumber."
            )
        }

        if ([string]::IsNullOrWhiteSpace($Value)) {
            throw (
                "Repository configuration key [$Key] has no value at " +
                "[$LiteralPath] line $LineNumber."
            )
        }

        $FileValues[$Key] = $Value
    }

    foreach ($RequiredKey in $RequiredKeys) {
        if (-not $FileValues.ContainsKey($RequiredKey)) {
            throw (
                "Required repository configuration key [$RequiredKey] " +
                "not found in [$LiteralPath]."
            )
        }
    }

    foreach (
        $SqlIdentifierKey in @(
            "RepositoryDatabase",
            "RepositorySchema",
            "RepositoryTable"
        )
    ) {
        if (
            $FileValues[$SqlIdentifierKey] `
                -notmatch '^[A-Za-z_][A-Za-z0-9_@$#]*$'
        ) {
            throw (
                "Invalid SQL identifier [$($FileValues[$SqlIdentifierKey])] " +
                "for repository configuration key [$SqlIdentifierKey] in " +
                "[$LiteralPath]."
            )
        }
    }

    if ($FileValues.SqlLoginName -notmatch '^[A-Za-z0-9._-]+$') {
        throw (
            "Invalid SQL Login name [$($FileValues.SqlLoginName)] for " +
            "repository configuration key [SqlLoginName] in [$LiteralPath]."
        )
    }

    if ($PSBoundParameters.ContainsKey("RepositoryInstance")) {
        $FileValues.RepositoryInstance = $RepositoryInstance
    }

    if ($PSBoundParameters.ContainsKey("RepositoryDatabase")) {
        $FileValues.RepositoryDatabase = $RepositoryDatabase
    }

    if ($PSBoundParameters.ContainsKey("RepositorySchema")) {
        $FileValues.RepositorySchema = $RepositorySchema
    }

    if ($PSBoundParameters.ContainsKey("RepositoryTable")) {
        $FileValues.RepositoryTable = $RepositoryTable
    }

    [pscustomobject]@{
        RepositoryInstance = [string]$FileValues.RepositoryInstance
        RepositoryDatabase = [string]$FileValues.RepositoryDatabase
        RepositorySchema   = [string]$FileValues.RepositorySchema
        RepositoryTable    = [string]$FileValues.RepositoryTable
        SqlLoginName       = [string]$FileValues.SqlLoginName
    }
}

function Get-SqlAgentConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LiteralPath
    )

    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
        throw "Agent configuration file not found: $LiteralPath"
    }

    $FileValues = @{}
    $LineNumber = 0

    foreach (
        $ConfigLine in Get-Content `
            -LiteralPath $LiteralPath `
            -Encoding UTF8
    ) {
        $LineNumber++
        $TrimmedLine = $ConfigLine.Trim()

        if (
            [string]::IsNullOrWhiteSpace($TrimmedLine) -or
            $TrimmedLine.StartsWith("#")
        ) {
            continue
        }

        $SeparatorIndex = $TrimmedLine.IndexOf("=")

        if ($SeparatorIndex -lt 1) {
            throw (
                "Invalid agent configuration at [$LiteralPath] line " +
                "$LineNumber. Expected Key=Value."
            )
        }

        $Key = $TrimmedLine.Substring(0, $SeparatorIndex).Trim()
        $Value = $TrimmedLine.Substring($SeparatorIndex + 1).Trim()

        if ($Key -ne "SqlLoginName") {
            throw (
                "Unknown agent configuration key [$Key] at " +
                "[$LiteralPath] line $LineNumber."
            )
        }

        if ($FileValues.ContainsKey($Key)) {
            throw (
                "Duplicate agent configuration key [$Key] at " +
                "[$LiteralPath] line $LineNumber."
            )
        }

        if ([string]::IsNullOrWhiteSpace($Value)) {
            throw (
                "Agent configuration key [$Key] has no value at " +
                "[$LiteralPath] line $LineNumber."
            )
        }

        $FileValues[$Key] = $Value
    }

    if (-not $FileValues.ContainsKey("SqlLoginName")) {
        throw (
            "Required agent configuration key [SqlLoginName] not found " +
            "in [$LiteralPath]."
        )
    }

    if ($FileValues.SqlLoginName -notmatch '^[A-Za-z0-9._-]+$') {
        throw (
            "Invalid SQL Login name [$($FileValues.SqlLoginName)] for " +
            "agent configuration key [SqlLoginName] in [$LiteralPath]."
        )
    }

    [pscustomobject]@{
        SqlLoginName = [string]$FileValues.SqlLoginName
    }
}

function New-SqlMaintenanceLogContext {
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$LogDirectory = (Join-Path $PSScriptRoot "Logs"),

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$OperationName = "SqlMaintenance"
    )

    if (-not (Test-Path -LiteralPath $LogDirectory -PathType Container)) {
        [void](
            New-Item `
                -Path $LogDirectory `
                -ItemType Directory `
                -Force
        )
    }

    $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $RunId = "{0}-{1}-{2}" -f `
        $Timestamp,
        $env:COMPUTERNAME,
        ([guid]::NewGuid().ToString("N").Substring(0, 8))
    $SafeOperationName = $OperationName -replace '[^A-Za-z0-9._-]', '_'

    [pscustomobject]@{
        RunId       = $RunId
        TextLogPath = Join-Path `
            $LogDirectory `
            "${SafeOperationName}_${RunId}.log"
        JsonLogPath = Join-Path `
            $LogDirectory `
            "${SafeOperationName}_${RunId}.jsonl"
    }
}

function Write-SqlMaintenanceLog {
    [CmdletBinding()]
    param(
        [Parameter()]
        [psobject]$LogContext,

        [Parameter(Mandatory)]
        [ValidateSet("Info", "Warning", "Error")]
        [string]$Level,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Step,

        [Parameter()]
        [string]$Instance,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter()]
        [int]$Attempt = 0,

        [Parameter()]
        [nullable[int]]$DurationMs,

        [Parameter()]
        [nullable[int]]$ErrorNumber
    )

    $Timestamp = [DateTimeOffset]::Now.ToString("o")
    $SafeMessage = $Message -replace '[\r\n]+', ' '
    $DisplayInstance = if ([string]::IsNullOrWhiteSpace($Instance)) {
        "-"
    }
    else {
        $Instance
    }

    $TextLine = "{0} [{1}] [{2}] [{3}] {4}" -f `
        $Timestamp,
        $Level.ToUpperInvariant(),
        $Step,
        $DisplayInstance,
        $SafeMessage

    if ($null -ne $LogContext) {
        $Record = [ordered]@{
            Timestamp   = $Timestamp
            RunId       = $LogContext.RunId
            Level       = $Level
            Step        = $Step
            Instance    = $Instance
            Attempt     = $Attempt
            DurationMs  = $DurationMs
            ErrorNumber = $ErrorNumber
            Message     = $SafeMessage
        }

        Add-Content `
            -LiteralPath $LogContext.TextLogPath `
            -Value $TextLine `
            -Encoding UTF8
        Add-Content `
            -LiteralPath $LogContext.JsonLogPath `
            -Value ($Record | ConvertTo-Json -Compress -Depth 4) `
            -Encoding UTF8
    }

    $Color = switch ($Level) {
        "Info" { "Gray" }
        "Warning" { "Yellow" }
        "Error" { "Red" }
    }

    Write-Host $TextLine -ForegroundColor $Color
}

function Get-LocalSqlInstance {
    [CmdletBinding()]
    param()

    $SqlServices = @(
        Get-Service |
            Where-Object {
                $_.Name -eq "MSSQLSERVER" -or
                $_.Name -like 'MSSQL$*'
            } |
            Sort-Object Name
    )

    for ($Index = 0; $Index -lt $SqlServices.Count; $Index++) {
        $SqlService = $SqlServices[$Index]

        if ($SqlService.Name -eq "MSSQLSERVER") {
            $InstanceName = "MSSQLSERVER"
            $ConnectionTarget = "localhost"
        }
        else {
            $InstanceName = $SqlService.Name.Substring(6)
            $ConnectionTarget = "localhost\$InstanceName"
        }

        [pscustomobject]@{
            Index            = $Index + 1
            ServiceName      = $SqlService.Name
            InstanceName     = $InstanceName
            ConnectionTarget = $ConnectionTarget
            Status           = $SqlService.Status
        }
    }
}

function Select-SqlInstance {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string[]]$SourceInstance
    )

    if ($PSBoundParameters.ContainsKey("SourceInstance")) {
        $Targets = @(
            $SourceInstance |
                Where-Object { $null -ne $_ } |
                ForEach-Object { $_.Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -Unique
        )

        if ($Targets.Count -eq 0) {
            throw "SourceInstance does not contain a valid connection target."
        }

        foreach ($Target in $Targets) {
            [pscustomobject]@{
                Index            = $null
                ServiceName      = $null
                InstanceName     = $Target
                ConnectionTarget = $Target
                Status           = "Specified"
            }
        }

        return
    }

    $LocalSqlInstances = @(Get-LocalSqlInstance)

    if ($LocalSqlInstances.Count -eq 0) {
        throw "No local SQL Server instances were found."
    }

    $RunningSqlInstances = @(
        $LocalSqlInstances | Where-Object Status -eq "Running"
    )

    if ($RunningSqlInstances.Count -eq 0) {
        throw "No running local SQL Server instances were found."
    }

    if ($LocalSqlInstances.Count -eq 1) {
        Write-Host (
            "SQL Server instance selected automatically: " +
            $RunningSqlInstances[0].ConnectionTarget
        )
        $RunningSqlInstances[0]
        return
    }

    Write-Host ""
    Write-Host "Local SQL Server instances:"
    $LocalSqlInstances |
        Format-Table Index, InstanceName, ConnectionTarget, Status `
            -AutoSize |
        Out-Host

    while ($true) {
        $Selection = (
            Read-Host (
                "Select instance numbers " +
                "(example: 1,3; A = all running)"
            )
        ).Trim()

        if ($Selection -match '^A$') {
            $SelectedSqlInstances = @($RunningSqlInstances)
            break
        }

        $SelectedIndexes = @()
        $SelectionIsValid = $true

        foreach ($SelectionPart in ($Selection -split '[,\s]+')) {
            $SelectedIndex = 0

            if (
                [string]::IsNullOrWhiteSpace($SelectionPart) -or
                -not [int]::TryParse(
                    $SelectionPart,
                    [ref]$SelectedIndex
                ) -or
                $SelectedIndex -lt 1 -or
                $SelectedIndex -gt $LocalSqlInstances.Count
            ) {
                $SelectionIsValid = $false
                break
            }

            $SelectedIndexes += $SelectedIndex
        }

        $SelectedIndexes = @($SelectedIndexes | Select-Object -Unique)
        $SelectedSqlInstances = @(
            $LocalSqlInstances |
                Where-Object { $SelectedIndexes -contains $_.Index }
        )

        if (
            -not $SelectionIsValid -or
            $SelectedSqlInstances.Count -eq 0
        ) {
            Write-Warning "Invalid selection. Please try again."
            continue
        }

        $StoppedSelections = @(
            $SelectedSqlInstances | Where-Object Status -ne "Running"
        )

        if ($StoppedSelections.Count -gt 0) {
            Write-Warning (
                "The following instances are not running: " +
                ($StoppedSelections.InstanceName -join ", ")
            )
            continue
        }

        break
    }

    Write-Host (
        "Selected instances: " +
        ($SelectedSqlInstances.InstanceName -join ", ")
    )
    $SelectedSqlInstances
}

function New-SqlConnection {
    [CmdletBinding(DefaultParameterSetName = "Windows")]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$DataSource,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$InitialCatalog,

        [Parameter(Mandatory, ParameterSetName = "Windows")]
        [switch]$IntegratedSecurity,

        [Parameter(Mandatory, ParameterSetName = "SqlLogin")]
        [System.Data.SqlClient.SqlCredential]$SqlCredential,

        [Parameter()]
        [ValidateRange(1, 300)]
        [int]$ConnectionTimeoutSeconds = 15,

        [Parameter()]
        [bool]$TrustServerCertificate = $true,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$ApplicationName = "SQL Maintenance"
    )

    $Builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
    $Builder["Data Source"] = $DataSource
    $Builder["Initial Catalog"] = $InitialCatalog
    $Builder["Connect Timeout"] = $ConnectionTimeoutSeconds
    $Builder["Encrypt"] = $true
    $Builder["TrustServerCertificate"] = $TrustServerCertificate
    $Builder["Application Name"] = $ApplicationName

    if ($PSCmdlet.ParameterSetName -eq "Windows") {
        $Builder["Integrated Security"] = $true
        return [System.Data.SqlClient.SqlConnection]::new(
            $Builder.ConnectionString
        )
    }

    return [System.Data.SqlClient.SqlConnection]::new(
        $Builder.ConnectionString,
        $SqlCredential
    )
}

function Test-SqlTransientException {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Exception]$Exception
    )

    $TransientSqlNumbers = @(
        -2,
        53,
        64,
        121,
        233,
        1205,
        10053,
        10054,
        10060,
        10928,
        10929,
        40197,
        40501,
        40613,
        49918,
        49919,
        49920
    )

    $CurrentException = $Exception

    while ($null -ne $CurrentException) {
        if ($CurrentException -is [System.Data.SqlClient.SqlException]) {
            foreach ($SqlError in $CurrentException.Errors) {
                if ($TransientSqlNumbers -contains $SqlError.Number) {
                    return $true
                }
            }
        }

        if (
            $CurrentException -is [TimeoutException] -or
            $CurrentException -is [IO.IOException] -or
            $CurrentException -is [Net.Sockets.SocketException]
        ) {
            return $true
        }

        $CurrentException = $CurrentException.InnerException
    }

    return $false
}

function Get-SqlErrorNumber {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Exception]$Exception
    )

    $CurrentException = $Exception

    while ($null -ne $CurrentException) {
        if ($CurrentException -is [System.Data.SqlClient.SqlException]) {
            return [int]$CurrentException.Number
        }

        $CurrentException = $CurrentException.InnerException
    }

    return $null
}

function Invoke-SqlWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Operation,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Step,

        [Parameter()]
        [string]$Instance,

        [Parameter()]
        [ValidateRange(0, 20)]
        [int]$RetryCount = 3,

        [Parameter()]
        [ValidateRange(0, 300)]
        [int]$RetryDelaySeconds = 2,

        [Parameter()]
        [psobject]$LogContext
    )

    $MaximumAttempts = $RetryCount + 1

    for ($Attempt = 1; $Attempt -le $MaximumAttempts; $Attempt++) {
        $Stopwatch = [Diagnostics.Stopwatch]::StartNew()

        try {
            $Result = & $Operation
            $Stopwatch.Stop()

            if ($Attempt -gt 1) {
                Write-SqlMaintenanceLog `
                    -LogContext $LogContext `
                    -Level Info `
                    -Step $Step `
                    -Instance $Instance `
                    -Attempt $Attempt `
                    -DurationMs ([int]$Stopwatch.ElapsedMilliseconds) `
                    -Message "Operation succeeded after retry."
            }

            return $Result
        }
        catch {
            $Stopwatch.Stop()
            $Exception = $_.Exception
            $IsTransient = Test-SqlTransientException -Exception $Exception
            $ErrorNumber = Get-SqlErrorNumber -Exception $Exception

            if (-not $IsTransient -or $Attempt -ge $MaximumAttempts) {
                Write-SqlMaintenanceLog `
                    -LogContext $LogContext `
                    -Level Error `
                    -Step $Step `
                    -Instance $Instance `
                    -Attempt $Attempt `
                    -DurationMs ([int]$Stopwatch.ElapsedMilliseconds) `
                    -ErrorNumber $ErrorNumber `
                    -Message $Exception.Message
                throw
            }

            $DelaySeconds = [int][Math]::Min(
                30,
                $RetryDelaySeconds * [Math]::Pow(2, $Attempt - 1)
            )
            Write-SqlMaintenanceLog `
                -LogContext $LogContext `
                -Level Warning `
                -Step $Step `
                -Instance $Instance `
                -Attempt $Attempt `
                -DurationMs ([int]$Stopwatch.ElapsedMilliseconds) `
                -ErrorNumber $ErrorNumber `
                -Message (
                    "Transient failure. Retrying in " +
                    "$DelaySeconds second(s): $($Exception.Message)"
                )

            if ($DelaySeconds -gt 0) {
                Start-Sleep -Seconds $DelaySeconds
            }
        }
    }
}

function Test-SqlMonitorRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RepositoryInstance,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RepositoryDatabase,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RepositorySchema,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RepositoryTable,

        [Parameter(Mandatory)]
        [PSCredential]$Credential,

        [Parameter()]
        [ValidateRange(1, 300)]
        [int]$ConnectionTimeoutSeconds = 15,

        [Parameter()]
        [ValidateRange(1, 3600)]
        [int]$CommandTimeoutSeconds = 30,

        [Parameter()]
        [ValidateRange(0, 20)]
        [int]$RetryCount = 3,

        [Parameter()]
        [ValidateRange(0, 300)]
        [int]$RetryDelaySeconds = 2,

        [Parameter()]
        [psobject]$LogContext
    )

    foreach ($Identifier in @(
        $RepositoryDatabase,
        $RepositorySchema,
        $RepositoryTable
    )) {
        if ($Identifier -notmatch '^[A-Za-z_][A-Za-z0-9_@$#]*$') {
            throw "Invalid SQL identifier: $Identifier"
        }
    }

    $ReadOnlyPassword = $Credential.Password.Copy()
    $ReadOnlyPassword.MakeReadOnly()
    $SqlCredential = [System.Data.SqlClient.SqlCredential]::new(
        $Credential.UserName,
        $ReadOnlyPassword
    )
    $QualifiedTable = "[$RepositorySchema].[$RepositoryTable]"

    try {
        $DatabaseResult = Invoke-SqlWithRetry `
            -Step "RepositoryDatabasePreflight" `
            -Instance $RepositoryInstance `
            -RetryCount $RetryCount `
            -RetryDelaySeconds $RetryDelaySeconds `
            -LogContext $LogContext `
            -Operation {
                $Connection = New-SqlConnection `
                    -DataSource $RepositoryInstance `
                    -InitialCatalog "master" `
                    -SqlCredential $SqlCredential `
                    -ConnectionTimeoutSeconds $ConnectionTimeoutSeconds `
                    -ApplicationName "SQL Repository Preflight"

                try {
                    $Connection.Open()
                    $Command = $Connection.CreateCommand()

                    try {
                        $Command.CommandTimeout = $CommandTimeoutSeconds
                        $Command.CommandText = @"
SELECT
    [state_desc],
    HAS_DBACCESS([name]) AS [HasDatabaseAccess]
FROM sys.databases
WHERE [name] = @DatabaseName;
"@
                        [void]$Command.Parameters.Add(
                            "@DatabaseName",
                            [System.Data.SqlDbType]::NVarChar,
                            128
                        )
                        $Command.Parameters["@DatabaseName"].Value =
                            $RepositoryDatabase
                        $Reader = $Command.ExecuteReader()

                        try {
                            if (-not $Reader.Read()) {
                                throw (
                                    "Repository database not found: " +
                                    $RepositoryDatabase
                                )
                            }

                            $HasDatabaseAccessValue =
                                $Reader["HasDatabaseAccess"]
                            [pscustomobject]@{
                                State = [string]$Reader["state_desc"]
                                HasDatabaseAccess = ($HasDatabaseAccessValue -ne [DBNull]::Value -and [int]$HasDatabaseAccessValue -eq 1)
                            }
                        }
                        finally {
                            $Reader.Dispose()
                        }
                    }
                    finally {
                        $Command.Dispose()
                    }
                }
                finally {
                    $Connection.Dispose()
                }
            }

        if ($DatabaseResult.State -ne "ONLINE") {
            throw (
                "Repository database [$RepositoryDatabase] is not online: " +
                $DatabaseResult.State
            )
        }

        if (-not $DatabaseResult.HasDatabaseAccess) {
            throw (
                "SQL Login [$($Credential.UserName)] cannot access " +
                "repository database [$RepositoryDatabase]."
            )
        }

        $ObjectResult = Invoke-SqlWithRetry `
            -Step "RepositoryObjectPreflight" `
            -Instance $RepositoryInstance `
            -RetryCount $RetryCount `
            -RetryDelaySeconds $RetryDelaySeconds `
            -LogContext $LogContext `
            -Operation {
                $Connection = New-SqlConnection `
                    -DataSource $RepositoryInstance `
                    -InitialCatalog $RepositoryDatabase `
                    -SqlCredential $SqlCredential `
                    -ConnectionTimeoutSeconds $ConnectionTimeoutSeconds `
                    -ApplicationName "SQL Repository Preflight"

                try {
                    $Connection.Open()
                    $Command = $Connection.CreateCommand()

                    try {
                        $Command.CommandTimeout = $CommandTimeoutSeconds
                        $Command.CommandText = @"
DECLARE @ObjectId int = OBJECT_ID(@QualifiedTable, N'U');

SELECT
    @ObjectId AS [TableObjectId],
    ISNULL(
        HAS_PERMS_BY_NAME(@QualifiedTable, N'OBJECT', N'SELECT'),
        0
    ) AS [CanSelect],
    ISNULL(
        HAS_PERMS_BY_NAME(@QualifiedTable, N'OBJECT', N'INSERT'),
        0
    ) AS [CanInsert],
    ISNULL(
        HAS_PERMS_BY_NAME(@QualifiedTable, N'OBJECT', N'UPDATE'),
        0
    ) AS [CanUpdate],
    ISNULL(IS_ROLEMEMBER(N'db_owner'), 0) AS [IsDbOwner],
    ISNULL(
        HAS_PERMS_BY_NAME(DB_NAME(), N'DATABASE', N'CONTROL'),
        0
    ) AS [HasControlDatabase],
    (
        SELECT COUNT_BIG(*)
        FROM sys.database_role_members AS role_membership
        INNER JOIN sys.database_principals AS member_principal
            ON member_principal.[principal_id] =
                role_membership.[member_principal_id]
        WHERE member_principal.[name] = USER_NAME()
    ) AS [DatabaseRoleCount],
    ISNULL(IS_SRVROLEMEMBER(N'sysadmin'), 0) AS [IsSysAdmin],
    ISNULL(
        HAS_PERMS_BY_NAME(NULL, NULL, N'CONTROL SERVER'),
        0
    ) AS [HasControlServer],
    TYPE_NAME([system_type_id]) AS [DataType],
    CASE
        WHEN TYPE_NAME([system_type_id]) IN (N'nchar', N'nvarchar')
             AND [max_length] <> -1
            THEN [max_length] / 2
        ELSE [max_length]
    END AS [CharacterLength]
FROM sys.columns
WHERE [object_id] = @ObjectId
  AND [name] = N'InsName';
"@
                        [void]$Command.Parameters.Add(
                            "@QualifiedTable",
                            [System.Data.SqlDbType]::NVarChar,
                            257
                        )
                        $Command.Parameters["@QualifiedTable"].Value =
                            $QualifiedTable
                        $Reader = $Command.ExecuteReader()

                        try {
                            if (-not $Reader.Read()) {
                                throw (
                                    "Repository table or InsName column not " +
                                    "found: $RepositoryDatabase.$QualifiedTable"
                                )
                            }

                            [pscustomobject]@{
                                TableObjectId = [int]$Reader["TableObjectId"]
                                CanSelect = [int]$Reader["CanSelect"] -eq 1
                                CanInsert = [int]$Reader["CanInsert"] -eq 1
                                CanUpdate = [int]$Reader["CanUpdate"] -eq 1
                                IsDbOwner =
                                    [int]$Reader["IsDbOwner"] -eq 1
                                HasControlDatabase =
                                    [int]$Reader["HasControlDatabase"] -eq 1
                                DatabaseRoleCount =
                                    [long]$Reader["DatabaseRoleCount"]
                                IsSysAdmin =
                                    [int]$Reader["IsSysAdmin"] -eq 1
                                HasControlServer =
                                    [int]$Reader["HasControlServer"] -eq 1
                                DataType = [string]$Reader["DataType"]
                                CharacterLength =
                                    [int]$Reader["CharacterLength"]
                            }
                        }
                        finally {
                            $Reader.Dispose()
                        }
                    }
                    finally {
                        $Command.Dispose()
                    }
                }
                finally {
                    $Connection.Dispose()
                }
            }

        if ($ObjectResult.DataType -notin "varchar", "nvarchar") {
            throw (
                "Repository column InsName must be varchar or nvarchar; " +
                "found [$($ObjectResult.DataType)]."
            )
        }

        if (
            $ObjectResult.CharacterLength -ne -1 -and
            $ObjectResult.CharacterLength -lt 256
        ) {
            throw (
                "Repository column InsName must hold at least 256 " +
                "characters; found $($ObjectResult.CharacterLength)."
            )
        }

        if (
            -not $ObjectResult.CanSelect -or
            -not $ObjectResult.CanInsert -or
            -not $ObjectResult.CanUpdate
        ) {
            throw (
                "SQL Login [$($Credential.UserName)] requires SELECT, " +
                "INSERT, and UPDATE on " +
                "$RepositoryDatabase.$QualifiedTable."
            )
        }

        if (
            -not $ObjectResult.IsDbOwner -or
            $ObjectResult.DatabaseRoleCount -ne 1 -or
            $ObjectResult.IsSysAdmin -or
            $ObjectResult.HasControlServer
        ) {
            throw (
                "SQL Login [$($Credential.UserName)] must be a member of " +
                "only db_owner in repository database " +
                "[$RepositoryDatabase] and must not have sysadmin or " +
                "CONTROL SERVER permissions."
            )
        }

        Write-SqlMaintenanceLog `
            -LogContext $LogContext `
            -Level Info `
            -Step "RepositoryPreflight" `
            -Instance $RepositoryInstance `
            -Message (
                "Repository is ready: " +
                "$RepositoryDatabase.$QualifiedTable; " +
                "InsName=$($ObjectResult.DataType)" +
                "($($ObjectResult.CharacterLength)); " +
                "SELECT=True; INSERT=True; UPDATE=True."
            )

        [pscustomobject]@{
            RepositoryInstance = $RepositoryInstance
            RepositoryDatabase = $RepositoryDatabase
            QualifiedTable      = $QualifiedTable
            DatabaseState       = $DatabaseResult.State
            CanSelect           = $ObjectResult.CanSelect
            CanInsert           = $ObjectResult.CanInsert
            CanUpdate           = $ObjectResult.CanUpdate
            IsDbOwner           = $ObjectResult.IsDbOwner
            HasControlDatabase  = $ObjectResult.HasControlDatabase
            DatabaseRoleCount   = $ObjectResult.DatabaseRoleCount
            IsSysAdmin          = $ObjectResult.IsSysAdmin
            HasControlServer    = $ObjectResult.HasControlServer
            InsNameDataType     = $ObjectResult.DataType
            InsNameLength       = $ObjectResult.CharacterLength
            IsReady             = $true
        }
    }
    finally {
        $ReadOnlyPassword.Dispose()
    }
}

Export-ModuleMember -Function @(
    "Get-SqlRepositoryConfig",
    "Get-SqlAgentConfig",
    "Get-LocalSqlInstance",
    "Select-SqlInstance",
    "New-SqlConnection",
    "Invoke-SqlWithRetry",
    "New-SqlMaintenanceLogContext",
    "Write-SqlMaintenanceLog",
    "Test-SqlMonitorRepository"
)
