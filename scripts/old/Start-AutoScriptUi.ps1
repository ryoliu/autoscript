[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$scriptRoot = $PSScriptRoot
$rootPath = Split-Path -Path $scriptRoot -Parent

function ConvertTo-CommandValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return "'" + ($Value -replace "'", "''") + "'"
}

function New-ScriptCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter()]
        [hashtable]$Parameters = @{},

        [Parameter()]
        [string[]]$Switches = @()
    )

    $parts = @('&', (ConvertTo-CommandValue -Value $ScriptPath))

    foreach ($key in ($Parameters.Keys | Sort-Object)) {
        $value = [string]$Parameters[$key]

        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $parts += "-$key"
            $parts += (ConvertTo-CommandValue -Value $value)
        }
    }

    foreach ($switch in $Switches) {
        $parts += "-$switch"
    }

    return ($parts -join ' ')
}

function Invoke-ScriptElevated {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter()]
        [hashtable]$Parameters = @{},

        [Parameter()]
        [string[]]$Switches = @()
    )

    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        [System.Windows.Forms.MessageBox]::Show("Script not found:`r`n$ScriptPath", 'AutoScript UI', 'OK', 'Error') | Out-Null
        return
    }

    $command = New-ScriptCommand -ScriptPath $ScriptPath -Parameters $Parameters -Switches $Switches
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $argumentList = @(
        '-NoExit',
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-EncodedCommand',
        $encodedCommand
    )

    Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentList -Verb RunAs
}

function Open-Folder {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }

    Start-Process -FilePath 'explorer.exe' -ArgumentList $Path
}

function Open-LogFolder {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Pattern
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }

    $latestLog = Get-ChildItem -LiteralPath $Path -File -Filter $Pattern -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($null -ne $latestLog) {
        Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$($latestLog.FullName)`""
        return
    }

    Start-Process -FilePath 'explorer.exe' -ArgumentList $Path
}

function New-Label {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [int]$X,

        [Parameter(Mandatory = $true)]
        [int]$Y
    )

    $label = [System.Windows.Forms.Label]::new()
    $label.Text = $Text
    $label.Location = [System.Drawing.Point]::new($X, $Y)
    $label.Size = [System.Drawing.Size]::new(120, 22)
    return $label
}

function New-TextBox {
    param(
        [Parameter()]
        [string]$Text = '',

        [Parameter(Mandatory = $true)]
        [int]$X,

        [Parameter(Mandatory = $true)]
        [int]$Y,

        [Parameter()]
        [int]$Width = 420
    )

    $textBox = [System.Windows.Forms.TextBox]::new()
    $textBox.Text = $Text
    $textBox.Location = [System.Drawing.Point]::new($X, $Y)
    $textBox.Size = [System.Drawing.Size]::new($Width, 22)
    return $textBox
}

function New-Button {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [int]$X,

        [Parameter(Mandatory = $true)]
        [int]$Y,

        [Parameter()]
        [int]$Width = 140
    )

    $button = [System.Windows.Forms.Button]::new()
    $button.Text = $Text
    $button.Location = [System.Drawing.Point]::new($X, $Y)
    $button.Size = [System.Drawing.Size]::new($Width, 30)
    return $button
}

function New-GroupBox {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [int]$X,

        [Parameter(Mandatory = $true)]
        [int]$Y,

        [Parameter(Mandatory = $true)]
        [int]$Width,

        [Parameter(Mandatory = $true)]
        [int]$Height
    )

    $groupBox = [System.Windows.Forms.GroupBox]::new()
    $groupBox.Text = $Text
    $groupBox.Location = [System.Drawing.Point]::new($X, $Y)
    $groupBox.Size = [System.Drawing.Size]::new($Width, $Height)
    return $groupBox
}

$form = [System.Windows.Forms.Form]::new()
$form.Text = 'AutoScript Launcher'
$form.StartPosition = 'CenterScreen'
$form.Size = [System.Drawing.Size]::new(760, 750)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false

$osGroup = New-GroupBox -Text 'OS SQL Server Prerequisites' -X 12 -Y 12 -Width 720 -Height 70
$runOsCheckButton = New-Button -Text 'Run OS Check' -X 18 -Y 25
$osGroup.Controls.AddRange(@($runOsCheckButton))

$sqlGroup = New-GroupBox -Text 'SQL Server Install' -X 12 -Y 92 -Width 720 -Height 150
$sqlIsoText = New-TextBox -Text 'C:\install\SQLServer2019-x64-ENU.iso' -X 140 -Y 28
$sqlInstanceText = New-TextBox -Text 'MSSQLSERVER' -X 140 -Y 58 -Width 180
$sqlModeCombo = [System.Windows.Forms.ComboBox]::new()
$sqlModeCombo.Location = [System.Drawing.Point]::new(140, 88)
$sqlModeCombo.Size = [System.Drawing.Size]::new(120, 24)
$sqlModeCombo.DropDownStyle = 'DropDownList'
[void]$sqlModeCombo.Items.AddRange(@('UI', 'Silent'))
$sqlModeCombo.SelectedItem = 'UI'
$sqlRunButton = New-Button -Text 'Run SQL Install' -X 555 -Y 105
$sqlGroup.Controls.AddRange(@(
    (New-Label -Text 'ISO Path' -X 18 -Y 30),
    $sqlIsoText,
    (New-Label -Text 'Instance Name' -X 18 -Y 60),
    $sqlInstanceText,
    (New-Label -Text 'Install Mode' -X 18 -Y 90),
    $sqlModeCombo,
    $sqlRunButton
))

$ssmsGroup = New-GroupBox -Text 'SSMS Install' -X 12 -Y 252 -Width 720 -Height 145
$ssmsInstallerText = New-TextBox -Text 'C:\install\SSMS-Setup-ENU.exe' -X 140 -Y 28
$ssmsPathText = New-TextBox -Text 'E:\Program Files\Microsoft SQL Server Management Studio' -X 140 -Y 58
$ssmsModeCombo = [System.Windows.Forms.ComboBox]::new()
$ssmsModeCombo.Location = [System.Drawing.Point]::new(140, 88)
$ssmsModeCombo.Size = [System.Drawing.Size]::new(120, 24)
$ssmsModeCombo.DropDownStyle = 'DropDownList'
[void]$ssmsModeCombo.Items.AddRange(@('UI', 'Silent'))
$ssmsModeCombo.SelectedItem = 'UI'
$ssmsRunButton = New-Button -Text 'Run SSMS Install' -X 555 -Y 100
$ssmsGroup.Controls.AddRange(@(
    (New-Label -Text 'Installer Path' -X 18 -Y 30),
    $ssmsInstallerText,
    (New-Label -Text 'Install Path' -X 18 -Y 60),
    $ssmsPathText,
    (New-Label -Text 'Install Mode' -X 18 -Y 90),
    $ssmsModeCombo,
    $ssmsRunButton
))

$hotfixGroup = New-GroupBox -Text 'SQL Server Hotfix' -X 12 -Y 407 -Width 720 -Height 150
$hotfixInstallerText = New-TextBox -Text 'C:\install\SQLServer2019-KB5008996-x64.exe' -X 140 -Y 28
$hotfixInstanceText = New-TextBox -Text '' -X 140 -Y 58 -Width 180
$hotfixModeCombo = [System.Windows.Forms.ComboBox]::new()
$hotfixModeCombo.Location = [System.Drawing.Point]::new(140, 88)
$hotfixModeCombo.Size = [System.Drawing.Size]::new(120, 24)
$hotfixModeCombo.DropDownStyle = 'DropDownList'
[void]$hotfixModeCombo.Items.AddRange(@('UI', 'Silent'))
$hotfixModeCombo.SelectedItem = 'UI'
$hotfixSkipRebootCheck = [System.Windows.Forms.CheckBox]::new()
$hotfixSkipRebootCheck.Text = 'Skip pending reboot check'
$hotfixSkipRebootCheck.Location = [System.Drawing.Point]::new(285, 90)
$hotfixSkipRebootCheck.Size = [System.Drawing.Size]::new(200, 22)
$hotfixRunButton = New-Button -Text 'Run Hotfix' -X 555 -Y 105
$hotfixGroup.Controls.AddRange(@(
    (New-Label -Text 'Installer Path' -X 18 -Y 30),
    $hotfixInstallerText,
    (New-Label -Text 'Instance Name' -X 18 -Y 60),
    $hotfixInstanceText,
    (New-Label -Text 'Install Mode' -X 18 -Y 90),
    $hotfixModeCombo,
    $hotfixSkipRebootCheck,
    $hotfixRunButton
))

$toolsGroup = New-GroupBox -Text 'Configuration Tools' -X 12 -Y 567 -Width 720 -Height 70
$setOsSqlServerButton = New-Button -Text 'Set OS SQL Server' -X 18 -Y 25
$setSqlServerInstanceButton = New-Button -Text 'Set SQL Server Ins' -X 170 -Y 25
$toolsGroup.Controls.AddRange(@($setOsSqlServerButton, $setSqlServerInstanceButton))

$form.Controls.AddRange(@($osGroup, $sqlGroup, $ssmsGroup, $hotfixGroup, $toolsGroup))

$sqlRunButton.Add_Click({
    Invoke-ScriptElevated `
        -ScriptPath (Join-Path -Path $scriptRoot -ChildPath 'Install-SqlServer.ps1') `
        -Parameters @{
            IsoPath = $sqlIsoText.Text
            InstanceName = $sqlInstanceText.Text
            InstallMode = [string]$sqlModeCombo.SelectedItem
        }
})

$ssmsRunButton.Add_Click({
    Invoke-ScriptElevated `
        -ScriptPath (Join-Path -Path $scriptRoot -ChildPath 'Install-Ssms.ps1') `
        -Parameters @{
            InstallerPath = $ssmsInstallerText.Text
            InstallPath = $ssmsPathText.Text
            InstallMode = [string]$ssmsModeCombo.SelectedItem
        }
})

$hotfixRunButton.Add_Click({
    $switches = @()

    if ($hotfixSkipRebootCheck.Checked) {
        $switches += 'SkipPendingRebootCheck'
    }

    Invoke-ScriptElevated `
        -ScriptPath (Join-Path -Path $scriptRoot -ChildPath 'Install-SqlServerHotfix.ps1') `
        -Parameters @{
            InstallerPath = $hotfixInstallerText.Text
            InstanceName = $hotfixInstanceText.Text
            InstallMode = [string]$hotfixModeCombo.SelectedItem
        } `
        -Switches $switches
})

$runOsCheckButton.Add_Click({
    Invoke-ScriptElevated -ScriptPath (Join-Path -Path $scriptRoot -ChildPath 'Test-OsSqlServerPrerequisites.ps1')
})

$setOsSqlServerButton.Add_Click({
    Invoke-ScriptElevated -ScriptPath (Join-Path -Path $scriptRoot -ChildPath 'Set-OsSqlServerPrerequisites.ps1')
})

$setSqlServerInstanceButton.Add_Click({
    Invoke-ScriptElevated `
        -ScriptPath (Join-Path -Path $scriptRoot -ChildPath 'Set-SqlServerInstanceConfiguration.ps1') `
        -Parameters @{
            ServerInstance = $sqlInstanceText.Text
        }
})

[void]$form.ShowDialog()
