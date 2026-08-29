<#
.SYNOPSIS
Registers a SQL Server instance name in a central monitoring table.

.DESCRIPTION
Discovers local SQL Server instances unless SourceInstance is supplied. When
only one local instance exists, it is selected automatically. When multiple
instances exist, the script displays an interactive menu that supports one or
more selections.

The script connects to each selected source by using the srv.mn SQL Login,
retrieves its SQL Server instance name with T-SQL, and inserts the name into
Monitor.dbo.InsList when it does not already exist.

Unless a PSCredential is provided by the caller, the script loads an AES key and
encrypted credential created by New-SqlCredentialKey.ps1. The password is never
stored as plaintext in this script or in the credential file.

.PARAMETER SourceInstance
Optional SQL Server instance targets from which names are retrieved. Supplying
this parameter bypasses local discovery and the interactive selection menu.

.PARAMETER RepositoryInstance
SQL Server instance that contains the monitoring repository. The default is
WIN2019LAB. The parameter alias is Ins.

.PARAMETER RepositoryDatabase
Repository database name. The default is Monitor.

.PARAMETER RepositorySchema
Schema that owns the repository table. The default is dbo.

.PARAMETER RepositoryTable
Table that stores SQL Server instance names. The default is InsList.

.PARAMETER SqlLoginName
SQL Login used for both source and repository connections. The default is
srv.mn.

.PARAMETER CredentialDirectory
Directory containing the AES key and encrypted credential files. The default is
E:\Scripts.

.PARAMETER Credential
Optional SQL Login credential that overrides the stored credential files.

.EXAMPLE
.\getInstanceName.ps1

Discovers local SQL Server instances, selects the only instance automatically or
displays a selection menu, and registers the selected instance names in
WIN2019LAB.Monitor.dbo.InsList.

.EXAMPLE
$Credential = Get-Credential -UserName "srv.mn"
.\getInstanceName.ps1 -SourceInstance "localhost\LAB2" `
    -RepositoryInstance "WIN2019LAB" -Credential $Credential

Registers the localhost\LAB2 instance by using the supplied credential.

.NOTES
The srv.mn Login requires permission to connect to the source instance. On the
repository, it also requires a database user and SELECT/INSERT permission on
Monitor.dbo.InsList.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$SourceInstance,

    [Parameter()]
    [Alias("Ins")]
    [ValidateNotNullOrEmpty()]
    [string]$RepositoryInstance = "WIN2019LAB",

    [Parameter()]
    [ValidatePattern('^[A-Za-z_][A-Za-z0-9_@$#]*$')]
    [string]$RepositoryDatabase = "Monitor",

    [Parameter()]
    [ValidatePattern('^[A-Za-z_][A-Za-z0-9_@$#]*$')]
    [string]$RepositorySchema = "dbo",

    [Parameter()]
    [ValidatePattern('^[A-Za-z_][A-Za-z0-9_@$#]*$')]
    [string]$RepositoryTable = "InsList",

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$SqlLoginName = "srv.mn",

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$CredentialDirectory = "E:\Scripts",

    [Parameter()]
    [PSCredential]$Credential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function New-SqlLoginConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DataSource,

        [Parameter(Mandatory)]
        [string]$InitialCatalog,

        [Parameter(Mandatory)]
        [System.Data.SqlClient.SqlCredential]$SqlCredential
    )

    # Use the indexer because Windows PowerShell may reject property aliases
    # such as DataSource on SqlConnectionStringBuilder.
    $ConnectionStringBuilder =
        [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
    $ConnectionStringBuilder["Data Source"] = $DataSource
    $ConnectionStringBuilder["Initial Catalog"] = $InitialCatalog
    $ConnectionStringBuilder["Encrypt"] = $true
    $ConnectionStringBuilder["TrustServerCertificate"] = $true
    $ConnectionStringBuilder["Application Name"] =
        "Register SQL Server Instance"

    return [System.Data.SqlClient.SqlConnection]::new(
        $ConnectionStringBuilder.ConnectionString,
        $SqlCredential
    )
}

# Explicit source targets bypass local service discovery.
if ($PSBoundParameters.ContainsKey("SourceInstance")) {
    $SelectedSourceInstances = @(
        foreach ($ConnectionTarget in $SourceInstance) {
            [pscustomobject]@{
                Index            = $null
                InstanceName     = $ConnectionTarget
                ConnectionTarget = $ConnectionTarget
                Status           = "Specified"
            }
        }
    )
}
else {
    # Discover the default instance (MSSQLSERVER) and named instances
    # (MSSQL$InstanceName) from local Windows services.
    $SqlServices = @(
        Get-Service |
            Where-Object {
                $_.Name -eq "MSSQLSERVER" -or
                $_.Name -like 'MSSQL$*'
            } |
            Sort-Object Name
    )

    if ($SqlServices.Count -eq 0) {
        throw "No local SQL Server instances were found."
    }

    $LocalSqlInstances = @(
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
                InstanceName     = $InstanceName
                ConnectionTarget = $ConnectionTarget
                Status           = $SqlService.Status
            }
        }
    )

    $RunningSqlInstances = @(
        $LocalSqlInstances | Where-Object Status -eq "Running"
    )

    if ($RunningSqlInstances.Count -eq 0) {
        throw "No running local SQL Server instances were found."
    }

    if ($LocalSqlInstances.Count -eq 1) {
        # Do not display a menu when only one local instance exists.
        $SelectedSourceInstances = @($RunningSqlInstances[0])
        Write-Host (
            "SQL Server instance selected automatically: " +
            $SelectedSourceInstances[0].ConnectionTarget
        )
    }
    else {
        Write-Host ""
        Write-Host "Local SQL Server instances:"
        $LocalSqlInstances |
            Format-Table Index, InstanceName, ConnectionTarget, Status `
                -AutoSize |
            Out-Host

        # Accept one or more indexes, or A for every running instance.
        while ($true) {
            $Selection = (
                Read-Host (
                    "Select instance numbers " +
                    "(example: 1,3; A = all running)"
                )
            ).Trim()

            if ($Selection -match '^A$') {
                $SelectedSourceInstances = @($RunningSqlInstances)
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

            $SelectedIndexes = @(
                $SelectedIndexes | Select-Object -Unique
            )
            $SelectedSourceInstances = @(
                $LocalSqlInstances |
                    Where-Object { $SelectedIndexes -contains $_.Index }
            )

            if (
                -not $SelectionIsValid -or
                $SelectedSourceInstances.Count -eq 0
            ) {
                Write-Warning "Invalid selection. Please try again."
                continue
            }

            $StoppedSelections = @(
                $SelectedSourceInstances |
                    Where-Object Status -ne "Running"
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
            ($SelectedSourceInstances.InstanceName -join ", ")
        )
    }
}

if ($null -eq $Credential) {
    $KeyPath = Join-Path $CredentialDirectory "$SqlLoginName.key"
    $CredentialPath =
        Join-Path $CredentialDirectory "$SqlLoginName.credential.xml"

    if (-not (Test-Path -LiteralPath $KeyPath -PathType Leaf)) {
        throw (
            "SQL credential key not found: $KeyPath. Run " +
            "New-SqlCredentialKey.ps1 first."
        )
    }

    if (-not (Test-Path -LiteralPath $CredentialPath -PathType Leaf)) {
        throw (
            "Encrypted SQL credential not found: $CredentialPath. Run " +
            "New-SqlCredentialKey.ps1 first."
        )
    }

    $AesKey = [IO.File]::ReadAllBytes($KeyPath)

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

        $StoredPassword =
            $StoredCredential.EncryptedPassword |
                ConvertTo-SecureString -Key $AesKey
        $Credential = [PSCredential]::new(
            [string]$StoredCredential.UserName,
            $StoredPassword
        )
    }
    finally {
        # Remove the plaintext AES key bytes from the managed array after use.
        [Array]::Clear($AesKey, 0, $AesKey.Length)
    }
}

if ($Credential.UserName -cne $SqlLoginName) {
    throw (
        "Credential user [$($Credential.UserName)] does not match " +
        "SqlLoginName [$SqlLoginName]."
    )
}

# SqlCredential requires a read-only SecureString. The copied value is disposed
# after both SQL connections have finished.
$ReadOnlyPassword = $Credential.Password.Copy()
$ReadOnlyPassword.MakeReadOnly()
$SqlCredential = [System.Data.SqlClient.SqlCredential]::new(
    $SqlLoginName,
    $ReadOnlyPassword
)

$RepositoryConnection = $null
$RegistrationResults = [System.Collections.Generic.List[object]]::new()
$QualifiedTable = "[$RepositorySchema].[$RepositoryTable]"

try {
    # Open one repository connection and reuse it for all selected sources.
    $RepositoryConnection = New-SqlLoginConnection `
        -DataSource $RepositoryInstance `
        -InitialCatalog $RepositoryDatabase `
        -SqlCredential $SqlCredential
    $RepositoryConnection.Open()

    foreach ($SelectedSourceInstance in $SelectedSourceInstances) {
        $SourceConnection = $null
        $SqlInstanceName = $null

        try {
            Write-Host (
                "Processing source: " +
                $SelectedSourceInstance.ConnectionTarget
            )

            # Retrieve the configured SQL Server name, including the named
            # instance suffix when the source is not a default instance.
            $SourceConnection = New-SqlLoginConnection `
                -DataSource $SelectedSourceInstance.ConnectionTarget `
                -InitialCatalog "master" `
                -SqlCredential $SqlCredential
            $SourceConnection.Open()

            $InstanceNameCommand = $SourceConnection.CreateCommand()

            try {
                $InstanceNameCommand.CommandText = @"
SET NOCOUNT ON;
SELECT CONVERT(nvarchar(128), SERVERPROPERTY(N'ServerName'));
"@
                $SqlInstanceName =
                    [string]$InstanceNameCommand.ExecuteScalar()
            }
            finally {
                $InstanceNameCommand.Dispose()
            }

            if ([string]::IsNullOrWhiteSpace($SqlInstanceName)) {
                throw "SQL Server returned an empty instance name."
            }

            # InsList.InsName was previously handled as a 50-character value.
            if ($SqlInstanceName.Length -gt 50) {
                throw (
                    "SQL instance name exceeds 50 characters: " +
                    $SqlInstanceName
                )
            }

            # The instance name is sent as a SQL parameter rather than being
            # concatenated into the T-SQL batch.
            $RegisterCommand = $RepositoryConnection.CreateCommand()

            try {
                $RegisterCommand.CommandText = @"
SET NOCOUNT ON;

DECLARE @Inserted bit = 0;

IF NOT EXISTS
(
    SELECT 1
    FROM $QualifiedTable
    WHERE [InsName] = @InstanceName
)
BEGIN
    INSERT INTO $QualifiedTable ([InsName])
    VALUES (@InstanceName);

    SET @Inserted = 1;
END;

SELECT @Inserted;
"@
                [void]$RegisterCommand.Parameters.Add(
                    "@InstanceName",
                    [System.Data.SqlDbType]::NVarChar,
                    50
                )
                $RegisterCommand.Parameters["@InstanceName"].Value =
                    $SqlInstanceName

                $WasInserted = [bool]$RegisterCommand.ExecuteScalar()
            }
            finally {
                $RegisterCommand.Dispose()
            }

            if ($WasInserted) {
                $RegistrationStatus = "Inserted"
            }
            else {
                $RegistrationStatus = "Already exists"
            }

            $RegistrationResults.Add(
                [pscustomobject]@{
                    SourceTarget =
                        $SelectedSourceInstance.ConnectionTarget
                    InstanceName = $SqlInstanceName
                    Status       = $RegistrationStatus
                }
            )
        }
        catch {
            # Continue with the remaining selected instances after a failure.
            $RegistrationResults.Add(
                [pscustomobject]@{
                    SourceTarget =
                        $SelectedSourceInstance.ConnectionTarget
                    InstanceName = $SqlInstanceName
                    Status       = "Failed: $($_.Exception.Message)"
                }
            )
        }
        finally {
            if ($null -ne $SourceConnection) {
                $SourceConnection.Dispose()
            }
        }
    }
}
finally {
    if ($null -ne $RepositoryConnection) {
        $RepositoryConnection.Dispose()
    }

    $ReadOnlyPassword.Dispose()
}

Write-Host ""
Write-Host (
    "Registration results: " +
    "$RepositoryInstance.$RepositoryDatabase.$QualifiedTable"
)
$RegistrationResults | Format-Table -AutoSize

if ($RegistrationResults.Status -match '^Failed:') {
    throw "One or more SQL Server instances failed to register."
}
