[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$scriptRoot = $PSScriptRoot
$rootPath = Split-Path -Path $scriptRoot -Parent
$psModuleRoot = Join-Path -Path $scriptRoot -ChildPath 'psmodules'

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

    $scriptCommandParts = @(
        '&',
        'powershell.exe',
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        (ConvertTo-CommandValue -Value $ScriptPath)
    )

    foreach ($key in ($Parameters.Keys | Sort-Object)) {
        $value = [string]$Parameters[$key]

        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $scriptCommandParts += "-$key"
            $scriptCommandParts += (ConvertTo-CommandValue -Value $value)
        }
    }

    foreach ($switch in $Switches) {
        $scriptCommandParts += "-$switch"
    }

    $parts = @(
        "Write-Host 'ScriptPath: $($ScriptPath -replace "'", "''")' -ForegroundColor Cyan"
    )

    foreach ($key in ($Parameters.Keys | Sort-Object)) {
        $value = [string]$Parameters[$key]

        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $parts += "Write-Host 'Parameter $($key): $($value -replace "'", "''")' -ForegroundColor Cyan"
        }
    }

    foreach ($switch in $Switches) {
        $parts += "Write-Host 'Switch: $($switch -replace "'", "''")' -ForegroundColor Cyan"
    }

    $parts += ($scriptCommandParts -join ' ')
    $parts += '$autoScriptExitCode = $LASTEXITCODE'
    $parts += 'Write-Host '''''
    $parts += 'Read-Host ''Press Enter to close'''
    $parts += 'exit $autoScriptExitCode'

    return ($parts -join '; ')
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

function New-StepButton {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [int]$X,

        [Parameter(Mandatory = $true)]
        [int]$Y
    )

    return New-Button -Text $Text -X $X -Y $Y -Width 165
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

function Get-OsTargetInstanceName {
    $instanceName = $osInstanceText.Text.Trim()

    if ([string]::IsNullOrWhiteSpace($instanceName)) {
        $instanceName = 'MSSQLSERVER'
    }

    return $instanceName
}

function Get-SqlTargetServerInstance {
    $serverInstance = $osInstanceText.Text.Trim()

    if ([string]::IsNullOrWhiteSpace($serverInstance)) {
        $serverInstance = 'localhost'
    }

    return $serverInstance
}

$form = [System.Windows.Forms.Form]::new()
$form.Text = 'AutoScript Launcher'
$form.StartPosition = 'CenterScreen'
$form.Size = [System.Drawing.Size]::new(760, 750)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false

$osGroup = New-GroupBox -Text 'Target SQL Instance' -X 12 -Y 12 -Width 720 -Height 70
$osInstanceText = New-TextBox -Text 'MSSQLSERVER' -X 140 -Y 25 -Width 180
$osGroup.Controls.AddRange(@(
    (New-Label -Text 'Instance Name' -X 18 -Y 27),
    $osInstanceText
))

$sqlGroup = New-GroupBox -Text 'SQL Server Install' -X 12 -Y 92 -Width 720 -Height 120
$sqlIsoText = New-TextBox -Text 'C:\install\SQLServer2019-x64-ENU.iso' -X 140 -Y 28
$sqlModeCombo = [System.Windows.Forms.ComboBox]::new()
$sqlModeCombo.Location = [System.Drawing.Point]::new(140, 58)
$sqlModeCombo.Size = [System.Drawing.Size]::new(120, 24)
$sqlModeCombo.DropDownStyle = 'DropDownList'
[void]$sqlModeCombo.Items.AddRange(@('UI', 'Silent'))
$sqlModeCombo.SelectedItem = 'UI'
$sqlGroup.Controls.AddRange(@(
    (New-Label -Text 'ISO Path' -X 18 -Y 30),
    $sqlIsoText,
    (New-Label -Text 'Install Mode' -X 18 -Y 60),
    $sqlModeCombo
))

$ssmsGroup = New-GroupBox -Text 'SSMS Install' -X 12 -Y 222 -Width 720 -Height 145
$ssmsInstallerText = New-TextBox -Text 'C:\install\SSMS-Setup-ENU.exe' -X 140 -Y 28
$ssmsPathText = New-TextBox -Text 'E:\Program Files\Microsoft SQL Server Management Studio' -X 140 -Y 58
$ssmsModeCombo = [System.Windows.Forms.ComboBox]::new()
$ssmsModeCombo.Location = [System.Drawing.Point]::new(140, 88)
$ssmsModeCombo.Size = [System.Drawing.Size]::new(120, 24)
$ssmsModeCombo.DropDownStyle = 'DropDownList'
[void]$ssmsModeCombo.Items.AddRange(@('UI', 'Silent'))
$ssmsModeCombo.SelectedItem = 'UI'
$ssmsGroup.Controls.AddRange(@(
    (New-Label -Text 'Installer Path' -X 18 -Y 30),
    $ssmsInstallerText,
    (New-Label -Text 'Install Path' -X 18 -Y 60),
    $ssmsPathText,
    (New-Label -Text 'Install Mode' -X 18 -Y 90),
    $ssmsModeCombo
))

$hotfixGroup = New-GroupBox -Text 'SQL Server Hotfix' -X 12 -Y 377 -Width 720 -Height 120
$hotfixInstallerText = New-TextBox -Text 'C:\install\SQLServer2019-KB5008996-x64.exe' -X 140 -Y 28
$hotfixModeCombo = [System.Windows.Forms.ComboBox]::new()
$hotfixModeCombo.Location = [System.Drawing.Point]::new(140, 58)
$hotfixModeCombo.Size = [System.Drawing.Size]::new(120, 24)
$hotfixModeCombo.DropDownStyle = 'DropDownList'
[void]$hotfixModeCombo.Items.AddRange(@('UI', 'Silent'))
$hotfixModeCombo.SelectedItem = 'UI'
$hotfixGroup.Controls.AddRange(@(
    (New-Label -Text 'Installer Path' -X 18 -Y 30),
    $hotfixInstallerText,
    (New-Label -Text 'Install Mode' -X 18 -Y 60),
    $hotfixModeCombo
))

$workflowGroup = New-GroupBox -Text 'Setup Workflow' -X 12 -Y 507 -Width 720 -Height 115
$runOsCheckButton = New-StepButton -Text '1. Run OS Check' -X 18 -Y 25
$setOsSqlServerButton = New-StepButton -Text '2. Set OS SQL Server' -X 190 -Y 25
$sqlRunButton = New-StepButton -Text '3. Run SQL Install' -X 362 -Y 25
$ssmsRunButton = New-StepButton -Text '4. Run SSMS Install' -X 534 -Y 25
$installDbatoolsButton = New-StepButton -Text '5. Install dbatools' -X 18 -Y 65
$hotfixRunButton = New-StepButton -Text '6. Run Hotfix' -X 190 -Y 65
$setSqlServerInstanceButton = New-StepButton -Text '7. Set SQL Server Ins' -X 362 -Y 65
$testSqlServerInstanceButton = New-StepButton -Text '8. Test SQL Server Ins' -X 534 -Y 65
$workflowGroup.Controls.AddRange(@($runOsCheckButton, $setOsSqlServerButton, $sqlRunButton, $ssmsRunButton, $installDbatoolsButton, $hotfixRunButton, $setSqlServerInstanceButton, $testSqlServerInstanceButton))

$form.Controls.AddRange(@($osGroup, $sqlGroup, $ssmsGroup, $hotfixGroup, $workflowGroup))

$sqlRunButton.Add_Click({
    $targetInstanceName = Get-OsTargetInstanceName

    Invoke-ScriptElevated `
        -ScriptPath (Join-Path -Path $psModuleRoot -ChildPath 'Install-SqlServer.ps1') `
        -Parameters @{
            IsoPath = $sqlIsoText.Text
            InstanceName = $targetInstanceName
            InstallMode = [string]$sqlModeCombo.SelectedItem
        }
})

$ssmsRunButton.Add_Click({
    Invoke-ScriptElevated `
        -ScriptPath (Join-Path -Path $psModuleRoot -ChildPath 'Install-Ssms.ps1') `
        -Parameters @{
            InstallerPath = $ssmsInstallerText.Text
            InstallPath = $ssmsPathText.Text
            InstallMode = [string]$ssmsModeCombo.SelectedItem
        }
})

$hotfixRunButton.Add_Click({
    $targetInstanceName = Get-OsTargetInstanceName

    Invoke-ScriptElevated `
        -ScriptPath (Join-Path -Path $psModuleRoot -ChildPath 'Install-SqlServerHotfix.ps1') `
        -Parameters @{
            InstallerPath = $hotfixInstallerText.Text
            InstanceName = $targetInstanceName
            InstallMode = [string]$hotfixModeCombo.SelectedItem
        }
})

$runOsCheckButton.Add_Click({
    $targetInstanceName = Get-OsTargetInstanceName

    Invoke-ScriptElevated `
        -ScriptPath (Join-Path -Path $psModuleRoot -ChildPath 'Test-OsSqlServerPrerequisites.ps1') `
        -Parameters @{
            InstanceName = $targetInstanceName
        }
})

$setOsSqlServerButton.Add_Click({
    $targetInstanceName = Get-OsTargetInstanceName

    Invoke-ScriptElevated `
        -ScriptPath (Join-Path -Path $psModuleRoot -ChildPath 'Set-OsSqlServerPrerequisites.ps1') `
        -Parameters @{
            InstanceName = $targetInstanceName
        }
})

$setSqlServerInstanceButton.Add_Click({
    $targetServerInstance = Get-SqlTargetServerInstance

    Invoke-ScriptElevated `
        -ScriptPath (Join-Path -Path $psModuleRoot -ChildPath 'Set-SqlServerInstanceConfiguration.ps1') `
        -Parameters @{
            ServerInstance = $targetServerInstance
        }
})

$testSqlServerInstanceButton.Add_Click({
    $targetServerInstance = Get-SqlTargetServerInstance

    Invoke-ScriptElevated `
        -ScriptPath (Join-Path -Path $psModuleRoot -ChildPath 'Test-SqlServerInstanceConfiguration.ps1') `
        -Parameters @{
            ServerInstance = $targetServerInstance
        }
})

$installDbatoolsButton.Add_Click({
    Invoke-ScriptElevated `
        -ScriptPath (Join-Path -Path $psModuleRoot -ChildPath 'Install-Dbatools.ps1')
})

[void]$form.ShowDialog()
