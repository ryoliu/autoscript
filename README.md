# AutoScript

AutoScript 是 William 的 DBA 自動化腳本專案，以 PowerShell 與 T-SQL 管理 Windows Server Lab 環境、VirtualBox 虛擬機器，以及 SQL Server 的安裝、設定與維護。

目前主要使用情境為 Windows Server 2019 與 SQL Server 2019 Lab。腳本包含特定環境的主機名稱、IP、磁碟與安裝路徑，使用前應先檢查並依實際環境調整。

## 主要功能

| 功能 | 說明 |
| --- | --- |
| Windows Lab VM | 使用 VirtualBox 建立 Windows Server 2019 VM，執行無人值守安裝與額外資料磁碟設定。 |
| VM 複製與驗證 | 複製既有 VM，檢查來源與複本的識別資訊、電源狀態、網路模式與 MAC 位址。 |
| SQL Server 安裝 | 透過 WinForms 介面逐步執行 OS 檢查、前置設定、SQL Server、SSMS、dbatools 與 Hotfix 安裝。 |
| SQL Server 設定與檢查 | 提供獨立腳本，設定與驗證 SQL Server Instance。 |
| 遠端管理 | 透過 PowerShell Remoting 操作 Lab 主機，或建立遠端 SQL Server 安裝排程工作。 |
| SQL 維護 | 提供備份 Job、還原指令產生、登入失敗分析與 WhoIsActive 部署腳本。 |
| Oracle Linux VM | 提供專案內的 Codex Skill，建立 Oracle Linux/OEL VM 並啟動至 ISO 安裝畫面。 |

## 目錄結構

```text
autoscript/
|-- README.md
|-- AGENTS.md
|-- .gitignore
|-- .agents/
|   `-- skills/
|       |-- create-oel-vm/
|       |-- powershell-vm/
|       |-- sql-monitoring-powershell/
|       `-- virtualbox-clone-report/
|-- docs/
|   |-- InstallSql-Spec.md
|   `-- CreateOelVm-Skill.md
`-- scripts/
    |-- Connect-Win2019LabRemoting.ps1
    |-- InstallOs/
    |   `-- New-VirtualBoxWinServer2019UnattendedVm.ps1
    |-- CloneVm/
    |   |-- New-VirtualBoxCloneVm.ps1
    |   |-- Get-VirtualBoxCloneReport.ps1
    |   `-- guestConfig.ps1
    |-- InstallSql/
    |   |-- Start-AutoScriptUi.ps1
    |   |-- Start-RemoteSqlInstallTask.ps1
    |   |-- Test-AutoScriptInstallSqlPackage.ps1
    |   `-- psmodules/
    |       |-- Install-Dbatools.ps1
    |       |-- Install-SqlServer.ps1
    |       |-- Install-SqlServerHotfix.ps1
    |       |-- Install-Ssms.ps1
    |       |-- Set-OsSqlServerPrerequisites.ps1
    |       |-- Set-SqlServerInstanceConfiguration.ps1
    |       |-- Test-OsSqlServerPrerequisites.ps1
    |       |-- Test-SqlServerInstanceConfiguration.ps1
    |       `-- offline-modules.zip
    `-- MaintanceSql/
        |-- _MaintanceJob.sql
        |-- _Generate_All_UserDB_Restore.sql
        |-- GenRestoredScript-Full.sql
        |-- Generate_Latest_Full_Restore_V1.sql
        |-- usp_AnalyzeLoginFailed.sql
        `-- WhoIsActive_11_Deployment_In_Once.sql
```

`MaintanceSql` 為現有目錄名稱。`.agents/skills/` 提供 Codex 工作指引與輔助工具，通常從 `scripts/` 選擇需要的腳本執行。

## 執行環境與準備

- Windows 主機；SQL 安裝介面使用 Windows Forms，並呼叫 Windows PowerShell（`powershell.exe`）。
- 安裝、OS 設定與部分遠端管理操作需要系統管理員權限。
- VM 相關功能需安裝 Oracle VirtualBox，並準備對應的 Windows Server 或 Oracle Linux ISO。
- SQL 安裝需自行準備 SQL Server ISO、SSMS 安裝檔及所需 Hotfix。實際路徑以腳本參數與介面設定為準。
- dbatools 提供 `psmodules/offline-modules.zip` 離線安裝來源。
- 遠端操作需先確認 WinRM、帳號權限、名稱解析與網路連線可用。
- T-SQL 腳本需使用具適當權限的 SQL Server 連線執行。

## 使用方式

以下 PowerShell 範例均從專案根目錄執行。

### SQL Server 安裝與設定

啟動安裝介面：

```powershell
powershell.exe -NoProfile -File .\scripts\InstallSql\Start-AutoScriptUi.ps1
```

先確認目標 Instance、SQL ISO、SSMS 與 Hotfix 路徑，再依 `Setup Workflow` 順序操作：

1. `Run OS Check`：檢查 OS 前置條件。
2. `Set OS SQL Server`：套用 OS 前置設定。
3. `Run SQL Install`：安裝 SQL Server。
4. `Run SSMS Install`：安裝 SSMS。
5. `Install dbatools`：安裝 dbatools。
6. `Run Hotfix`：安裝 SQL Server 更新。
7. `Set SQL Server Ins`：套用 Instance 設定。
8. `Test SQL Server Ins`：驗證 Instance 設定。

每個步驟執行後，先確認結果再繼續。各功能腳本位於 `scripts/InstallSql/psmodules/`，也可依參數單獨執行。

檢查安裝套件完整性、PowerShell 語法與 UI 腳本引用：

```powershell
powershell.exe -NoProfile -File .\scripts\InstallSql\Test-AutoScriptInstallSqlPackage.ps1
```

此檢查包含 dbatools 的 `-WhatIf` 流程，會暫存解壓離線套件；通過檢查不代表已完成實際 SQL Server 安裝驗證。

### VirtualBox VM

Windows Server 2019 建立入口為 `scripts/InstallOs/New-VirtualBoxWinServer2019UnattendedVm.ps1`。先查看腳本說明，確認 ISO、VM 規格、磁碟及帳號參數：

```powershell
Get-Help .\scripts\InstallOs\New-VirtualBoxWinServer2019UnattendedVm.ps1 -Full
```

複製 VM 前，先確認來源 VM 已關機且複本名稱未使用：

```powershell
.\scripts\CloneVm\New-VirtualBoxCloneVm.ps1 `
    -SourceVmName 'WIN2019-LAB' `
    -CloneVmName 'WIN2019-LAB2' `
    -BaseFolder 'C:\VM'
```

檢查來源與複本：

```powershell
.\scripts\CloneVm\Get-VirtualBoxCloneReport.ps1 `
    -SourceVmName 'WIN2019-LAB' `
    -CloneVmName 'WIN2019-LAB2'
```

`guestConfig.ps1` 包含 Guest 改名、網路與 Remoting 設定步驟，需依註解分階段操作，並調整 IP 與網卡名稱；其中包含重新啟動，不適合直接整份執行。

Oracle Linux/OEL VM 的參數、預設規格與建立方式，請參閱 [Create OEL VM Skill 說明](docs/CreateOelVm-Skill.md)。

### 遠端管理

`scripts/Connect-Win2019LabRemoting.ps1` 提供連線驗證、目錄與檔案列出，以及指定檔案刪除功能。使用前確認目標主機、帳號及操作參數。

`scripts/InstallSql/Start-RemoteSqlInstallTask.ps1` 會透過 Remoting 建立並啟動遠端安裝工作。目標主機須事先放置 InstallSql 套件，並以 `-RemoteInstallSqlPath` 指定遠端套件目錄；此腳本不負責傳送套件。

### SQL 維護

`scripts/MaintanceSql/` 內的 `.sql` 依需求個別使用。執行前檢查目標 Instance、資料庫、備份來源與目的路徑、Job 名稱及排程。

`_MaintanceJob.sql` 會刪除並重建同名備份 Job，預設完整備份每日 01:00 執行，交易記錄備份每 15 分鐘執行。還原指令產生腳本的輸出需先審閱，再決定是否執行。

## 變更與資料保護

- Windows VM 建立腳本的 `-Recreate`、VM 複製腳本的 `-DeleteExistingClone` 可能刪除既有 VM 與磁碟，使用前應確認備份與目標名稱。
- OS、網路與 SQL 設定腳本會修改目標環境，請先在 Lab 驗證，並保留必要備份或 VM 快照。
- 任何新增、修改或刪除 Table、Column、Index、Constraint 的操作，執行前必須依 [AGENTS.md](AGENTS.md) 顯示醒目的 `TABLE SCHEMA 變更警告`，列出物件、資料影響、程式／Job／Stored Procedure／報表影響、回復方式及備份建議，並取得 William 明確確認。
- 密碼、私鑰、憑證、資料庫備份與匯出檔應存放在版本控制之外；提交前確認 `.gitignore` 與實際變更內容。

## 相關文件

- [InstallSql 規格書](docs/InstallSql-Spec.md)：安裝介面、操作流程、腳本職責與驗證方式。規格書提及的部分遠端部署檔案目前未包含在專案內，請以現有檔案為準。
- [Create OEL VM Skill 說明](docs/CreateOelVm-Skill.md)：Oracle Linux/OEL VM 建立流程。
- [AGENTS.md](AGENTS.md)：專案協作偏好與 Table Schema 變更規則。
