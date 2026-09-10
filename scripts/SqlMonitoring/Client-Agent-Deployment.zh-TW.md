# SQL Monitoring Client Agent 與 ServerRepository 部署指南

## 文件狀態

本文件說明目前已完成的 Client Agent 與中央 ServerRepository 拆分架構、
帳號權限及部署流程。

預設監控 SQL Login 為 `dbmonitor`。Client 與 Repository SQL Instance 可以
使用相同名稱與密碼，但 SQL Login 是各 SQL Instance 內獨立的 Server
Principal。

## 架構

```text
Client Agent
    Creates the local monitoring Login
                    |
                    v
ServerRepository
    Registers SQL connection targets
    Stores the central credential
    Runs GetDBInfo collectors
                    |
                    v
Repository Database
    Stores monitoring results
```

Client Agent 只負責建立及驗證 Client 本機監控 Login。Repository 初始化、
Instance 註冊、Credential 保存、GetDBInfo Collector 與 SQL Agent Job 全部
留在 ServerRepository。

Client 不保存中央 Repository 使用的 AES key 或 Credential XML，也不直接
寫入 Repository Database。

## 元件責任

| 元件 | 部署位置 | 責任 |
| --- | --- | --- |
| Client Agent | Client | 建立監控 Login、授予唯讀監控權限及驗證連線 |
| ServerRepository | 中央 Repository 主機 | 初始化 Repository、管理 Instance 清單及 Credential |
| GetDBInfo Collector | 中央 Repository 主機 | 連線各 SQL Instance、收集並寫入資料 |
| SQL Agent Job | Repository SQL Server | 定期執行 GetDBInfo Controller |

## 部署目錄

### Client Agent

```text
C:\SQLSERVER\SqlMonitoringClient\
|-- Start-AgentSetup.ps1
|-- New-SqlServiceLogin.ps1
|-- Config\
|   `-- agent.config
|-- Modules\
|   `-- SqlMaintenance.Common\
|       `-- SqlMaintenance.Common.psm1
`-- Logs\
```

`agent.config`：

```ini
SqlLoginName=dbmonitor
```

### ServerRepository

```text
C:\SQLSERVER\SqlMonitoringServer\
|-- ServerRepository\
|   |-- Start-ServerRepositorySetup.ps1
|   |-- Initialize-SqlMonitorRepository.ps1
|   |-- New-SqlCredentialKey.ps1
|   |-- New-SqlServiceLogin.ps1
|   `-- Register-SqlMonitoringClient.ps1
|-- GetDBInfo\
|-- Config\
|   `-- repository.config
|-- Credentials\
|   |-- dbmonitor.key
|   `-- dbmonitor.credential.xml
|-- Modules\
|   `-- SqlMaintenance.Common\
|       `-- SqlMaintenance.Common.psm1
`-- Logs\
```

`repository.config` 範例：

```ini
RepositoryInstance=SQLREPOSITORY01
RepositoryDatabase=Monitor
RepositorySchema=dbo
RepositoryTable=InsList
SqlLoginName=dbmonitor
```

## 建立部署包

在原始碼目錄執行：

```powershell
.\New-SqlMonitoringDeploymentPackages.ps1 `
    -OutputRoot "C:\Deployment\SqlMonitoring"
```

使用上述路徑時會建立：

```text
C:\Deployment\SqlMonitoring\SqlMonitoringClient
C:\Deployment\SqlMonitoring\SqlMonitoringServer
```

省略 `-OutputRoot` 時，會使用腳本所在磁碟的根目錄。例如腳本位於
`E:\Scripts\SqlMonitoring`，執行：

```powershell
.\New-SqlMonitoringDeploymentPackages.ps1
```

會建立：

```text
E:\SqlMonitoringClient
E:\SqlMonitoringServer
```

`OutputRoot` 本身可以已經存在，但其下的 `SqlMonitoringClient` 與
`SqlMonitoringServer` 目錄不可事先存在。腳本遇到其中任一目錄已存在時會
停止，不會覆寫既有部署包。Client 包不會包含 Repository Config、GetDBInfo、
中央註冊腳本、AES key 或 Credential XML。

## 權限設計

### 共用權限

`ClientMonitor` 與 `RepositoryWriter` 都會取得：

```sql
GRANT CONNECT SQL TO [dbmonitor];

USE [msdb];

IF USER_ID(N'dbmonitor') IS NULL
BEGIN
    CREATE USER [dbmonitor] FOR LOGIN [dbmonitor];
END
ELSE
BEGIN
    ALTER USER [dbmonitor] WITH LOGIN = [dbmonitor];
END;

GRANT CONNECT TO [dbmonitor];
GRANT SELECT TO [dbmonitor];
GRANT EXECUTE ON OBJECT::dbo.agent_datetime TO [dbmonitor];
```

`CREATE USER` 具備冪等處理；User 已存在時會重新對應 Login。

腳本不會將 `dbmonitor` 加入 `SQLAgentUserRole`、`SQLAgentReaderRole` 或
`SQLAgentOperatorRole`。

### ClientMonitor

`ClientMonitor` 額外取得：

```sql
GRANT CONNECT ANY DATABASE TO [dbmonitor];
GRANT VIEW ANY DATABASE TO [dbmonitor];
GRANT VIEW ANY DEFINITION TO [dbmonitor];
GRANT VIEW SERVER STATE TO [dbmonitor];
```

SQL Server 2022 以上另外取得：

```sql
GRANT VIEW SERVER PERFORMANCE STATE TO [dbmonitor];
```

不會在每個使用者資料庫建立 `dbmonitor` User。

### RepositoryWriter

`RepositoryWriter` 不會撤銷既有 `ClientMonitor` 權限。兩個 Profile 採累加式
授權，避免同一個 `dbmonitor` 同時負責監控與 Repository 寫入時互相撤權。

`New-SqlServiceLogin.ps1` 不直接授予 Repository Database 權限；
`Initialize-SqlMonitorRepository.ps1` 會在設定的 Repository Database 建立或
重新對應 User，並加入 `db_owner`：

```sql
USE [Monitor];

IF USER_ID(N'dbmonitor') IS NULL
BEGIN
    CREATE USER [dbmonitor] FOR LOGIN [dbmonitor];
END
ELSE
BEGIN
    ALTER USER [dbmonitor] WITH LOGIN = [dbmonitor];
END;

GRANT CONNECT TO [dbmonitor];

IF IS_ROLEMEMBER(N'db_owner', N'dbmonitor') <> 1
BEGIN
    ALTER ROLE [db_owner] ADD MEMBER [dbmonitor];
END;
```

`db_owner` 僅限 Repository Database，但代表該帳號在此資料庫具有完整控制
權，包括資料讀寫、DDL、Stored Procedure 執行及權限管理。

### Repository 自我監控

Repository SQL Instance 也要被監控時，同一個 `dbmonitor` 最終具有：

```text
ClientMonitor server permissions
+ msdb backup read permissions
+ Repository Database db_owner
```

不需要分別執行兩次 `ClientMonitor` 與 `RepositoryWriter`。使用
`-MonitorRepositoryInstance`，由 ServerRepository Setup 套用 Client 監控
權限，再由 Repository 初始化程序加入 `db_owner`。

## 部署流程

### 1. 部署 Client Agent

將 Client 部署包複製到：

```text
C:\SQLSERVER\SqlMonitoringClient
```

確認 `Config\agent.config`：

```ini
SqlLoginName=dbmonitor
```

使用具備建立 Login 及授權能力的 Windows 帳號執行：

```powershell
$ServiceCredential = Get-Credential -UserName "dbmonitor"

& "C:\SQLSERVER\SqlMonitoringClient\Start-AgentSetup.ps1" `
    -Action ProvisionLogin `
    -SourceInstance "localhost" `
    -ServiceCredential $ServiceCredential
```

具名執行個體：

```powershell
-SourceInstance "localhost\INSTANCE01"
```

Client 只在記憶體中使用 `PSCredential`，不建立 key 或 Credential XML。

### 2. 初始化 ServerRepository

將 Server 部署包複製到：

```text
C:\SQLSERVER\SqlMonitoringServer
```

Repository SQL Instance 不監控自己：

```powershell
& "C:\SQLSERVER\SqlMonitoringServer\ServerRepository\Start-ServerRepositorySetup.ps1" `
    -Action RunAll `
    -EnableCollectorJob `
    -IncludeTopResourceUsage
```

Repository SQL Instance 同時監控自己：

```powershell
& "C:\SQLSERVER\SqlMonitoringServer\ServerRepository\Start-ServerRepositorySetup.ps1" `
    -Action RunAll `
    -MonitorRepositoryInstance `
    -EnableCollectorJob `
    -IncludeTopResourceUsage
```

`-IncludeTopResourceUsage` 預設為關閉。上述範例主動加入此參數，因此 SQL
Agent Job 會收集完整六類資料。若不加此參數，Repository 仍會建立六張報表
資料表，但 Collector 只會執行其他五類收集，並略過
`SqlTopResourceUsage`。

`RunAll` 會依序：

1. 建立或重新對應 `dbmonitor`。
2. 初始化 Repository Database、Schema、Instance 清單及六張報表資料表。
3. 將 `dbmonitor` 加入 Repository Database 的 `db_owner`。
4. 建立或更新 `_CollectDatabaseInformation` SQL Agent Job。
5. 建立中央 AES key 與 Credential XML。

若 Credential 檔案已存在，只有確定要替換時才使用：

```powershell
-ForceCredential
```

建立 Credential 檔案時，腳本會讓目前執行 Setup 的 Windows 帳號、Local
System 及本機 Administrators 擁有完整控制權，並預設授予
`NT SERVICE\SQLSERVERAGENT` 讀取權限。如果 SQL Agent 使用其他 Windows
帳號，執行 Setup 時應指定實際帳號：

```powershell
-CredentialAccessAccount "DOMAIN\SqlAgentService"
```

此參數只授予 Credential 檔案的讀取權，不會增加 SQL Server 權限。
指定此參數時會取代預設的 `NT SERVICE\SQLSERVERAGENT`；若兩個帳號都需要
讀取，請同時傳入：

```powershell
-CredentialAccessAccount @(
    "NT SERVICE\SQLSERVERAGENT",
    "DOMAIN\SqlAgentService"
)
```

### 3. 註冊 Client Instance

在 ServerRepository 執行：

```powershell
& "C:\SQLSERVER\SqlMonitoringServer\ServerRepository\Register-SqlMonitoringClient.ps1" `
    -SourceInstance "CLIENT01\INSTANCE01" `
    -RunCollectionTest `
    -IncludeTopResourceUsage
```

中央註冊程序會：

1. 載入中央保存的 `dbmonitor` Credential。
2. 測試 Client SQL 連線。
3. 取得 SQL Server 回報的正式 Instance Name。
4. 新增或更新 Repository Instance 清單。
5. 選擇性執行一次限定範圍的收集測試。

### 4. 註冊 Repository Instance

只有 Repository 需要監控自己時才執行：

```powershell
& "C:\SQLSERVER\SqlMonitoringServer\ServerRepository\Register-SqlMonitoringClient.ps1" `
    -SourceInstance "SQLREPOSITORY01" `
    -RunCollectionTest `
    -IncludeTopResourceUsage
```

`-MonitorRepositoryInstance` 只負責授權；Repository Instance 仍必須登錄到
Instance 清單，Collector 才會執行收集。

### 5. 確認集中收集

1. 確認 `_CollectDatabaseInformation` SQL Agent Job 已啟用。
2. 手動執行 Job 一次。
3. 檢查 Job History 與 ServerRepository Logs。
4. 確認六張報表資料表都有預期資料。

六類資料包括：

```text
SqlBackupInfo
SqlDiskSpace
SqlDuplicateIndexInfo
SqlTablePerformanceInfo
SqlTopResourceUsage
SqlUnusedIndexInfo
```

`CollectedAt` 使用執行 Collector 主機的 OS 本機時間，會依 OS 時區與日光
節約時間自動調整。

## Credential 與安全性

- 預設監控 SQL Login 是 `dbmonitor`。
- 不在 PowerShell、Config 或 Log 保存明碼密碼。
- AES key 與 Credential XML 只能保存在 ServerRepository。
- Client 部署包不可包含 key 或 Credential XML。
- Credential 檔案會授予目前執行 Setup 的 Windows 帳號、Local System 及本機
  Administrators 完整控制權。
- Credential 檔案預設授予 `NT SERVICE\SQLSERVERAGENT` 讀取權限。
- SQL Agent 若使用其他 Windows 帳號，必須透過 `-CredentialAccessAccount`
  指定實際讀取帳號。
- 防火牆只開放 ServerRepository 到 Client 的必要 SQL TCP Port。
- 具名執行個體建議使用固定 TCP Port。
- 正式環境應使用已簽署腳本及適當 Execution Policy。
- 若環境有 Active Directory，可評估以 gMSA 或網域服務帳號取代共用 SQL
  Login。
- Repository Database 的 `db_owner` 是明確部署需求，權限範圍高於最小權限
  模型，應限制 Credential 的保存位置與使用者。

## 帳號重建注意事項

將預設帳號由其他名稱改為 `dbmonitor` 時，需要同步處理：

1. 各 SQL Instance 的 Login。
2. `msdb` Database User。
3. Repository Database User 與 `db_owner` Membership。
4. ServerRepository 的 `dbmonitor.key`。
5. ServerRepository 的 `dbmonitor.credential.xml`。
6. `agent.config` 與 `repository.config`。

Config 修改不會自動重新命名既有 Login、User、key 或 Credential XML。

## 驗收清單

### Client

- [ ] Client 只有 Agent、Config、共用 Module 及 Logs。
- [ ] `agent.config` 使用 `SqlLoginName=dbmonitor`。
- [ ] Client 不包含 ServerRepository、GetDBInfo、key 或 Credential XML。
- [ ] `dbmonitor` Login 已建立且 Credential 驗證成功。
- [ ] `dbmonitor` 不具備 `sysadmin` 或 Server Role Membership。
- [ ] `dbmonitor` 具有 ClientMonitor Server 權限。
- [ ] `msdb` User 已建立並具有 Database-level `SELECT`。
- [ ] 使用者資料庫沒有因部署而建立 `dbmonitor` User。
- [ ] Agent Log 沒有權限或連線錯誤。

### ServerRepository

- [ ] `repository.config` 使用 `SqlLoginName=dbmonitor`。
- [ ] AES key 與 Credential XML 只存在 ServerRepository。
- [ ] `dbmonitor` 是 Repository Database 的 `db_owner`。
- [ ] ServerRepository 可以連線所有已註冊 Client。
- [ ] Instance 清單沒有重複或錯誤名稱。
- [ ] `_CollectDatabaseInformation` SQL Agent Job 指向實際 Controller 路徑。
- [ ] SQL Agent Job 已啟用並可成功完成。
- [ ] SQL Agent 執行帳號可以讀取 AES key 與 Credential XML。
- [ ] 六張報表資料表均有預期資料。

### Repository 自我監控

- [ ] Setup 使用 `-MonitorRepositoryInstance`。
- [ ] Repository Instance 已登錄到 Instance 清單。
- [ ] `dbmonitor` 同時具有 ClientMonitor、`msdb SELECT` 與 Repository
      Database `db_owner`。
- [ ] Repository 備份資訊已寫入 `dbo.SqlBackupInfo`。
