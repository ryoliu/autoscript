# AutoScript InstallSql 規格書

## 1. 目的

本規格定義 `InstallSql` 工具組的目錄結構、UI 操作流程、PowerShell 腳本職責與驗證方式。此工具組主要用於 Windows Server 2019 Lab VM，例如 `WIN2019-LAB`，自動化 SQL Server 2019、SSMS、SQL Server Hotfix 與 dbatools 的安裝與檢查。

目標是讓 DBA 依照 UI 上的 `Setup Workflow` 從左到右、由上到下執行，不需要記憶各腳本位置與參數。

## 2. 目錄結構

正式部署時，`InstallSql` 目錄應維持以下結構：

```text
InstallSql
├─ Start-AutoScriptUi.ps1
├─ Invoke-InstallSqlRemote.ps1
├─ RemoteInstallSql-Computers.sample.csv
├─ Test-AutoScriptInstallSqlPackage.ps1
└─ psmodules
   ├─ Install-Dbatools.ps1
   ├─ Install-SqlServer.ps1
   ├─ Install-SqlServerHotfix.ps1
   ├─ Install-Ssms.ps1
   ├─ offline-modules.zip
   ├─ Set-OsSqlServerPrerequisites.ps1
   ├─ Set-SqlServerInstanceConfiguration.ps1
   ├─ Test-OsSqlServerPrerequisites.ps1
   └─ Test-SqlServerInstanceConfiguration.ps1
```

規則：

- `Start-AutoScriptUi.ps1` 固定放在 `InstallSql` 根目錄。
- `Invoke-InstallSqlRemote.ps1` 固定放在 `InstallSql` 根目錄，用於多台主機遠端部署。
- `RemoteInstallSql-Computers.sample.csv` 固定放在 `InstallSql` 根目錄，作為遠端部署主機清單範例。
- 所有實際執行的功能腳本固定放在 `InstallSql\psmodules`。
- `offline-modules.zip` 固定放在 `InstallSql\psmodules`，供 `Install-Dbatools.ps1` 離線安裝使用。
- 不應在 `InstallSql` 根目錄放置其他功能型 `.ps1`，避免 UI 呼叫與手動執行混淆。

## 3. UI 規格

啟動檔案：

```powershell
.\Start-AutoScriptUi.ps1
```

UI 分成四個參數區與一個流程區：

- `Target SQL Instance`
- `SQL Server Install`
- `SSMS Install`
- `SQL Server Hotfix`
- `Setup Workflow`

### 3.1 Target SQL Instance

只保留一個 Instance Name 輸入欄位。

此欄位是整個流程唯一的 SQL instance 來源，會被下列步驟共用：

- SQL Server 安裝
- OS SQL Server 前置設定
- SQL Server Hotfix
- SQL Server Instance 設定
- SQL Server Instance 檢查

預設值：

```text
MSSQLSERVER
```

若欄位空白，UI helper 會視為：

```text
MSSQLSERVER
```

### 3.2 SQL Server Install

保留參數：

- ISO Path
- Install Mode

不在此區塊放置執行按鈕。

預設 ISO Path：

```text
C:\install\SQLServer2019-x64-ENU.iso
```

Install Mode 可選：

```text
UI
Silent
```

### 3.3 SSMS Install

保留參數：

- Installer Path
- Install Path
- Install Mode

不在此區塊放置執行按鈕。

預設 Installer Path：

```text
C:\install\SSMS-Setup-ENU.exe
```

預設 Install Path：

```text
E:\Program Files\Microsoft SQL Server Management Studio
```

### 3.4 SQL Server Hotfix

保留參數：

- Installer Path
- Install Mode

不提供獨立 Instance Name 欄位。

Hotfix 一律使用 `Target SQL Instance` 的 Instance Name。

UI 不提供 `SkipPendingRebootCheck` 選項。若需要略過 pending reboot 檢查，只允許用命令列手動執行 `Install-SqlServerHotfix.ps1` 並明確傳入參數。

預設 Installer Path：

```text
C:\install\SQLServer2019-KB5008996-x64.exe
```

### 3.5 Setup Workflow

所有執行按鈕集中於 `Setup Workflow` 區塊。

按鈕順序固定如下：

```text
1. Run OS Check
2. Set OS SQL Server
3. Run SQL Install
4. Run SSMS Install
5. Install dbatools
6. Run Hotfix
7. Set SQL Server Ins
8. Test SQL Server Ins
```

設計原則：

- 操作者應由左到右、由上到下逐步執行。
- 不提供一鍵全自動流程。
- 每一步執行後由操作者確認結果，再進行下一步。
- 每個按鈕透過 elevated PowerShell 執行對應腳本。

## 4. 腳本職責

### 4.1 Start-AutoScriptUi.ps1

職責：

- 顯示 WinForms UI。
- 收集路徑、模式與 Target Instance 參數。
- 將按鈕動作導向 `psmodules` 內的功能腳本。

路徑規則：

```powershell
$psModuleRoot = Join-Path -Path $PSScriptRoot -ChildPath 'psmodules'
```

所有功能腳本呼叫都必須透過 `$psModuleRoot`。

### 4.1.1 Invoke-InstallSqlRemote.ps1

職責：

- 讀取 CSV 主機清單。
- 建立 PowerShell Remoting session。
- 將本機 `InstallSql` package 複製到遠端主機。
- 依指定 `-Steps` 在遠端執行既有 `psmodules` 腳本。
- 支援多台主機，以 `-ThrottleLimit` 控制同時執行數量。

此腳本適合多台主機部署；單機互動操作仍使用 `Start-AutoScriptUi.ps1`。

預設遠端部署路徑：

```text
C:\Autoscript\InstallSql
```

CSV 欄位：

```text
ComputerName,InstanceName,IsoPath,SsmsInstallerPath,SsmsInstallPath,HotfixInstallerPath,SqlInstallMode,SsmsInstallMode,HotfixInstallMode,ForceDbatools
```

範例：

```powershell
$cred = Get-Credential

.\Invoke-InstallSqlRemote.ps1 `
  -ComputerListPath .\RemoteInstallSql-Computers.sample.csv `
  -Credential $cred `
  -Steps PackageTest,InstallDbatools,RunOsCheck
```

正式安裝範例：

```powershell
$cred = Get-Credential

.\Invoke-InstallSqlRemote.ps1 `
  -ComputerListPath .\computers.csv `
  -Credential $cred `
  -Steps PackageTest,InstallDbatools,RunOsCheck,SetOsSqlServer,InstallSqlServer,InstallSsms,InstallHotfix,SetSqlServerInstance,TestSqlServerInstance `
  -ThrottleLimit 2
```

限制：

- 遠端 SQL Server / SSMS / Hotfix 安裝應使用 `Silent` 模式。
- 遠端主機須先啟用 WinRM / PowerShell Remoting。
- SQL Server ISO、SSMS installer、Hotfix installer 應預先存在於每台遠端主機本機路徑。
- 不建議透過 UNC share 直接安裝，避免 double-hop 問題。

### 4.2 Install-SqlServer.ps1

職責：

- 安裝 SQL Server 2019。
- 使用 Target Instance Name。
- `sa` 密碼預設為：

```text
P@ssword
```

安裝前會檢查：

- ISO 是否存在
- 是否已安裝同名 instance
- 是否為系統管理員權限
- 必要磁碟機是否存在

### 4.3 Install-Ssms.ps1

職責：

- 安裝 SSMS。
- 支援 UI 或 Silent 模式。
- 使用 UI 傳入的 installer path 與 install path。

### 4.4 Install-Dbatools.ps1

職責：

- 離線安裝 dbatools。
- 預設來源為同目錄：

```text
offline-modules.zip
```

執行流程：

1. 檢查是否已安裝 dbatools。
2. 若已安裝且未指定 `-Force`，顯示 skipped 並結束。
3. 若需安裝，解壓 `offline-modules.zip` 到 `%TEMP%`。
4. 從解壓後的 `offline-modules` 複製：
   - `dbatools`
   - `dbatools.library`
5. 安裝後匯入 dbatools 驗證。
6. 清除暫存解壓資料夾。

### 4.5 Install-SqlServerHotfix.ps1

職責：

- 安裝固定 Hotfix：

```text
SQLServer2019-KB5008996-x64.exe
```

Hotfix 版本判斷：

- 以 SQL Server instance 的 `SERVERPROPERTY('ProductVersion')` 判斷。
- 目標版本：

```text
15.0.4198.2
```

若指定 instance 目前版本大於或等於 `15.0.4198.2`，視為 Hotfix 已安裝並略過。

Instance 規則：

- `InstanceName` 為必要參數。
- 不支援 `/AllInstances`。
- 安裝參數固定使用：

```text
/InstanceName=<InstanceName>
```

KB registry 規則：

- 若 Windows uninstall registry 出現 `KB5008996`，只顯示警告。
- Registry 檢查不作為是否略過安裝的依據，因為它不是 instance-specific。

### 4.6 Set-OsSqlServerPrerequisites.ps1

職責：

- 設定 OS 層級 SQL Server 前置條件。
- 使用 Target Instance Name。

### 4.7 Test-OsSqlServerPrerequisites.ps1

職責：

- 檢查 OS 層級 SQL Server 前置條件。
- 作為流程第 1 步。

### 4.8 Set-SqlServerInstanceConfiguration.ps1

職責：

- 設定 SQL Server instance 層級設定。
- 使用 UI 的 Target Instance Name。

### 4.9 Test-SqlServerInstanceConfiguration.ps1

職責：

- 檢查 SQL Server instance 設定。
- 使用 UI 的 Target Instance Name。

## 5. Log 規格

各安裝與設定腳本應輸出 transcript log 到 `C:\autoscript\logs` 底下對應目錄。

Hotfix log 目錄：

```text
C:\autoscript\logs\SqlServerHotfix
```

Hotfix 若 SQL setup 失敗，應輸出：

- SQL setup exit code
- unsigned hex exit code
- SQL setup summary log path
- summary log 重點行，例如：
  - Final result
  - Exit code
  - Exit message
  - Error result
  - Feature failure reason

## 6. 自動測試規格

測試腳本：

```powershell
.\Test-AutoScriptInstallSqlPackage.ps1
```

測試內容：

- `Start-AutoScriptUi.ps1` 是否存在。
- `psmodules` 目錄是否存在。
- 必要功能腳本是否存在。
- `offline-modules.zip` 是否存在。
- `InstallSql` 根目錄是否沒有多餘功能型 `.ps1`。
- 所有 `.ps1` 是否能 PowerShell parse。
- UI 是否使用 `$psModuleRoot`。
- UI 是否引用所有必要功能腳本。
- `Install-Dbatools.ps1 -Scope CurrentUser -Force -WhatIf` 是否會解壓 zip 到暫存資料夾。

成功輸出：

```text
All AutoScript InstallSql package checks passed.
```

## 7. 部署與使用方式

建議將整個 `InstallSql` 資料夾複製到 VM：

```text
C:\Autoscript\InstallSql
```

VM 內執行：

```powershell
cd C:\Autoscript\InstallSql
.\Test-AutoScriptInstallSqlPackage.ps1
.\Start-AutoScriptUi.ps1
```

正式操作前應先執行 package test。

## 8. 驗收條件

符合下列條件即視為此工具組符合規格：

- UI 可正常啟動。
- UI 只保留一個 Target Instance Name。
- Hotfix UI 不提供獨立 Instance Name。
- Hotfix UI 不提供 SkipPendingRebootCheck。
- 所有功能腳本都放在 `psmodules`。
- `offline-modules` 不以散檔目錄存在，只保留 `offline-modules.zip`。
- `Test-AutoScriptInstallSqlPackage.ps1` 全部 PASS。
- Hotfix 對已達 `15.0.4198.2` 的 instance 會略過。
- Hotfix 不產生 `/AllInstances` 參數。
