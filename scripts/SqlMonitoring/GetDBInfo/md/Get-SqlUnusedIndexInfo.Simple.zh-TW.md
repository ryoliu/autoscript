# Get-SqlUnusedIndexInfo.Simple.ps1 說明

## 用途

此腳本用來收集 SQL Server 的未使用索引資訊，並寫入 Repository 的 `[dbo].[SqlUnusedIndexInfo]` 資料表。

腳本只收集資料，不會刪除或修改受監控 SQL Server 上的索引。

## 執行流程

1. 讀取 Repository 設定與 SQL Server 清單。
2. Repository 中沒有 `[dbo].[SqlUnusedIndexInfo]` 時建立資料表。
3. 使用 `Find-DbaDbUnusedIndex` 收集各 SQL Server 的未使用索引。
4. 使用 `Write-DbaDbTableData` 將結果寫入 Repository。
5. 顯示成功 Instance、失敗 Instance 與寫入筆數。

## 主要參數

| 參數 | 說明 |
|---|---|
| `ConfigPath` | Repository 設定檔路徑，一般不需要指定。 |
| `SqlLoginName` | 用來取得 SQL Credential 的登入名稱。 |
| `CredentialDirectory` | Credential 檔案目錄。 |
| `Credential` | 直接傳入 SQL Server Credential。 |
| `Database` | 只收集指定的 Database；未指定時收集所有可用的使用者 Database。 |
| `CollectedAt` | 資料收集時間，預設為目前 UTC 時間。 |
| `SharedContext` | 由 Controller 傳入的共用 Context；單獨執行時不需要指定。 |

## 執行範例

收集所有可用的使用者 Database：

```powershell
.\Get-SqlUnusedIndexInfo.Simple.ps1
```

只收集指定的 Database：

```powershell
.\Get-SqlUnusedIndexInfo.Simple.ps1 -Database AppDb,ReportDb
```

直接傳入 Credential：

```powershell
$Credential = Get-Credential
.\Get-SqlUnusedIndexInfo.Simple.ps1 -Credential $Credential
```

## 注意事項

- 執行環境需要安裝 `dbatools`。
- Repository 設定、SQL Server 清單與 Credential 必須正確。
- 不收集 `master`、`model`、`msdb`、`tempdb`。
- 未使用索引資料來自 SQL Server 使用統計。
- SQL Server 重新啟動後，索引使用統計可能重置。
- 收集結果只能作為檢查候選清單，不應直接依結果執行 `DROP INDEX`。
- `Get-SqlPerformanceInfo.ps1` 目前仍呼叫原本的 `Get-SqlUnusedIndexInfo.ps1`，尚未切換到此簡化版本。
