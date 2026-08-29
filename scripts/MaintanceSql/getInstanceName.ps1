# Create 256-bit AES Key
$Key = New-Object Byte[] 32
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($Key)

# Save Key
[System.IO.File]::WriteAllBytes(
    "C:\install\zabbix.key",
    $Key
)
# input pwd and Secure
$Password = Read-Host "input zabbix pwd" -AsSecureString
$Password | ConvertFrom-SecureString -Key $Key | Set-Content "C:\install\zabbix.pwd"
#####################

$KeyFile      = "C:\install\zabbix.key"
$PasswordFile = "C:\install\zabbix.pwd"

$RepositoryServer   = "JB-DBA-DBM109"
$RepositoryDatabase = "CORE"

# Validate that the required files exist
if (-not (Test-Path $KeyFile -PathType Leaf)) {
    throw "Key file not found: $KeyFile"
}

if (-not (Test-Path $PasswordFile -PathType Leaf)) {
    throw "Password file not found: $PasswordFile"
}

# Load the credential
$Key = [System.IO.File]::ReadAllBytes($KeyFile)

$SecurePassword = Get-Content $PasswordFile |
    ConvertTo-SecureString -Key $Key

$Credential = [PSCredential]::new(
    "zabbix",
    $SecurePassword
)

$env:SQLCMDPASSWORD = $Credential.GetNetworkCredential().Password

try {

    # ============================================================
    # Get local SQL Server instance name
    # ============================================================

    $SqlInstance = (
        sqlcmd `
            -S localhost `
            -U zabbix `
            -h -1 `
            -W `
            -b `
            -Q "SET NOCOUNT ON;
                SELECT
                    CAST(SERVERPROPERTY('MachineName') AS varchar(128))
                    +
                    CASE
                        WHEN SERVERPROPERTY('InstanceName') IS NULL
                            THEN ''
                        ELSE '\' + CAST(SERVERPROPERTY('InstanceName') AS varchar(128))
                    END;"
    ).Trim()

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to retrieve SQL Server instance name. ExitCode = $LASTEXITCODE"
    }

    Write-Host "SQL Instance: $SqlInstance"

    # ============================================================
    # Validate length
    # ============================================================

    if ($SqlInstance.Length -gt 50) {
        throw "SQL Instance name exceeds 50 characters: $SqlInstance"
    }

    # Escape single quotes for T-SQL
    $SqlInstanceEscaped = $SqlInstance.Replace("'", "''")

    # ============================================================
    # Insert into repository
    # ============================================================

    sqlcmd `
        -S $RepositoryServer `
        -d $RepositoryDatabase `
        -U zabbix `
        -b `
        -Q "
            SET NOCOUNT ON;

            IF NOT EXISTS (
                SELECT 1
                FROM dbo.InsList
                WHERE InsName = '$SqlInstanceEscaped'
            )
            BEGIN
                INSERT INTO dbo.InsList (InsName)
                VALUES ('$SqlInstanceEscaped');
            END;
        "

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to insert instance into repository. ExitCode = $LASTEXITCODE"
    }

    Write-Host "Instance registered successfully: $SqlInstance"
}
finally {

    Remove-Item Env:SQLCMDPASSWORD -ErrorAction SilentlyContinue
}
#####################
