# PowerShell AI 工作目標範例

## 範例 1：建立新 Script

```text
工作目標：

請建立一支 PowerShell，用 dbatools 收集多台 SQL Server 的 Disk Space 資訊。

需求：
1. Server List 從 Repository DB 取得。
2. 每台 Server 收集 Drive、Total Size、Free Space、Free Percentage。
3. 將結果寫入 Repository 的 dbo.SqlDiskSpace。
4. 單台 Server 失敗時繼續下一台。
5. 不需要 Email、Retry、Parallel 或額外 Logging Framework。
```

---

## 範例 2：修改現有 Script

```text
工作目標：

請修改我提供的 Get-SqlTopResourceUsage.ps1。

本次只修改以下需求：
1. 排除 master、model、msdb、tempdb。
2. 確認過濾後的 System Database 不會顯示，也不會寫入 Repository。
3. 其他原有功能、欄位、流程與錯誤處理維持不變。
4. 修改完成後列出修改前與修改後的差異。
```

---

## 範例 3：修改一整組收集 Script

```text
工作目標：

請修改現有的 SQL Server Performance 收集 PowerShell。

需求：
1. 從 repository.config 取得 Repository Server、Database 與 Instance List Table。
2. 從 Repository 的 InsList 取得要處理的 SQL Server Instance。
3. 使用現有 Credential 機制連線。
4. 收集 SQL Server 使用者資料庫的 Performance 資訊。
5. 排除 master、model、msdb、tempdb。
6. 將結果寫入 Repository Database 的指定 Table。
7. 單一 Instance 執行失敗時顯示錯誤並繼續下一台。
8. 保留目前 Script 的主要流程與架構，不修改與本次需求無關的部分。
```
