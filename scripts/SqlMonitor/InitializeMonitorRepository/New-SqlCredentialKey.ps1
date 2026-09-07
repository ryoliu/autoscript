<#
.SYNOPSIS
Creates an AES key and an encrypted SQL Login credential file.

.DESCRIPTION
Prompts for a SQL Login credential, creates a 256-bit AES key, and stores the
password as an encrypted SecureString. The key and credential files are created
under the shared Credentials directory by default. The directory is created
automatically when it does not exist.

File access is restricted to the current Windows account, Local System, and the
local Administrators group. Both files are required to decrypt the password.

.PARAMETER SqlLoginName
Optional SQL Login name stored in the credential file. It overrides
SqlLoginName in repository.config.

.PARAMETER ConfigPath
Path to repository.config, which supplies the default SqlLoginName.

.PARAMETER CredentialDirectory
Directory in which the key and credential files are created. The default is
the shared Credentials directory.

.PARAMETER Credential
Optional credential supplied by the caller. When omitted, Get-Credential opens
an interactive credential prompt.

.PARAMETER Force
Replaces existing key and credential files.

.PARAMETER LogDirectory
Directory for text and JSON Lines execution logs.

.EXAMPLE
.\New-SqlCredentialKey.ps1

Prompts for the configured service Login password and creates the credential files.

.EXAMPLE
.\New-SqlCredentialKey.ps1 -Force

Replaces the existing service Login key and credential files after prompting for the
current password.

.NOTES
The encrypted credential is only as secure as the AES key file. Keep both files
protected and do not commit either file to source control.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "Medium")]
param(
    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$SqlLoginName,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath = (
        Join-Path `
            (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) `
            "Config\repository.config"
    ),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$CredentialDirectory = (
        Join-Path `
            (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) `
            "Credentials"
    ),

    [Parameter()]
    [PSCredential]$Credential,

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$LogDirectory = (Join-Path $PSScriptRoot "Logs"),

    [Parameter()]
    [psobject]$LogContext
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$CommonModulePath = Join-Path `
    (Split-Path -Parent $PSScriptRoot) `
    "Modules\SqlMaintenance.Common\SqlMaintenance.Common.psm1"

if (-not (Test-Path -LiteralPath $CommonModulePath -PathType Leaf)) {
    throw "Required module not found: $CommonModulePath"
}

Import-Module $CommonModulePath -Force

$RepositoryConfig = Get-SqlRepositoryConfig -LiteralPath $ConfigPath

if (-not $PSBoundParameters.ContainsKey("SqlLoginName")) {
    $SqlLoginName = $RepositoryConfig.SqlLoginName
}

if ($null -eq $LogContext) {
    $LogContext = New-SqlMaintenanceLogContext `
        -LogDirectory $LogDirectory `
        -OperationName "New-SqlCredentialKey"
}

Write-SqlMaintenanceLog `
    -LogContext $LogContext `
    -Level Info `
    -Step "CreateCredential" `
    -Message "Starting encrypted credential creation for [$SqlLoginName]."

function Set-RestrictedFileAcl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath
    )

    # Build the ACL from well-known SIDs so the script works on localized
    # versions of Windows.
    $AllowedSids = @(
        [Security.Principal.WindowsIdentity]::GetCurrent().User,
        [Security.Principal.SecurityIdentifier]::new("S-1-5-18"),
        [Security.Principal.SecurityIdentifier]::new("S-1-5-32-544")
    )

    $Acl = [Security.AccessControl.FileSecurity]::new()
    $Acl.SetAccessRuleProtection($true, $false)

    foreach ($Sid in $AllowedSids) {
        $AccessRule = [Security.AccessControl.FileSystemAccessRule]::new(
            $Sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.AccessControlType]::Allow
        )
        [void]$Acl.AddAccessRule($AccessRule)
    }

    Set-Acl -LiteralPath $LiteralPath -AclObject $Acl
}

$CredentialDrive = Split-Path -Path $CredentialDirectory -Qualifier

if (
    -not [string]::IsNullOrWhiteSpace($CredentialDrive) -and
    -not (Test-Path -LiteralPath $CredentialDrive -PathType Container)
) {
    throw "Credential drive not found: $CredentialDrive"
}

if (-not (Test-Path -LiteralPath $CredentialDirectory -PathType Container)) {
    [void](
        New-Item `
            -Path $CredentialDirectory `
            -ItemType Directory `
            -Force
    )
}

$KeyPath = Join-Path $CredentialDirectory "$SqlLoginName.key"
$CredentialPath =
    Join-Path $CredentialDirectory "$SqlLoginName.credential.xml"

$ExistingFiles = @(
    @(
        $KeyPath,
        $CredentialPath
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
)

if ($ExistingFiles.Count -gt 0 -and -not $Force) {
    throw (
        "Credential files already exist. Use -Force to replace them: " +
        ($ExistingFiles -join ", ")
    )
}

if ($null -eq $Credential) {
    $Credential = Get-Credential `
        -UserName $SqlLoginName `
        -Message "Enter the SQL Login credential to encrypt"
}

if ($null -eq $Credential) {
    throw "A SQL Login credential is required."
}

if ($Credential.UserName -cne $SqlLoginName) {
    throw (
        "Credential user [$($Credential.UserName)] does not match " +
        "SqlLoginName [$SqlLoginName]."
    )
}

if (
    -not $PSCmdlet.ShouldProcess(
        $CredentialDirectory,
        "Create encrypted credential files for SQL Login [$SqlLoginName]"
    )
) {
    return
}

# Generate a new 256-bit AES key every time the credential is created.
$AesKey = [byte[]]::new(32)
$RandomNumberGenerator =
    [Security.Cryptography.RandomNumberGenerator]::Create()

try {
    $RandomNumberGenerator.GetBytes($AesKey)
}
finally {
    $RandomNumberGenerator.Dispose()
}

$EncryptedPassword =
    $Credential.Password | ConvertFrom-SecureString -Key $AesKey
$StoredCredential = [pscustomobject]@{
    UserName          = $Credential.UserName
    EncryptedPassword = $EncryptedPassword
    CreatedAt         = [DateTimeOffset]::Now
}

# Write both files before applying restrictive ACLs.
[IO.File]::WriteAllBytes($KeyPath, $AesKey)
$StoredCredential | Export-Clixml -LiteralPath $CredentialPath -Force

Set-RestrictedFileAcl -LiteralPath $KeyPath
Set-RestrictedFileAcl -LiteralPath $CredentialPath

# Clear the in-memory byte array after it has been written.
[Array]::Clear($AesKey, 0, $AesKey.Length)
$EncryptedPassword = $null

Write-Host "SQL credential files created:"
Write-Host "  Key:        $KeyPath"
Write-Host "  Credential: $CredentialPath"

Write-SqlMaintenanceLog `
    -LogContext $LogContext `
    -Level Info `
    -Step "CreateCredential" `
    -Message (
        "Encrypted credential files created for [$SqlLoginName] in " +
        "[$CredentialDirectory]."
    )
