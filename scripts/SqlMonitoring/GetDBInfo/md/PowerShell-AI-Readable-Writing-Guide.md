# PowerShell AI 撰寫規範：DBA 易讀簡單版

## 目的

這份規範用來要求 AI 撰寫容易讓 DBA 閱讀及維護的 PowerShell。

重點不是使用最多的 PowerShell 技巧，也不是建立最完整的防呆框架，而是用直接、簡單、容易追蹤的方式完成需求。

## 三個核心原則

### 1. 以 DBA 容易閱讀與維護為優先

- 不追求最短程式碼。
- 主流程由上往下即可看懂。
- 使用完整、有意義的變數名稱，例如 `$SqlInstance`、`$DatabaseName`、`$QueryResult`。
- 使用完整 Cmdlet 名稱，不使用 `%`、`?` 等 Alias。
- 不把多個動作壓縮在同一行。
- Pipeline 不要太長；查詢、整理及寫入可以分成幾個清楚的步驟。
- 註解只需說明用途、原因或 DBA 需要注意的地方，不要每行都加註解。
- Function 不要拆得太細；只有重複使用或主流程明顯過長時才建立 Function。

建議的主流程：

```text
接收參數
  → 載入 dbatools
  → 執行查詢或收集資料
  → 整理需要的欄位
  → 顯示或寫入結果
  → 顯示完成訊息
```

### 2. 優先使用基本 dbatools

dbatools 已經能完成的工作，優先直接使用 dbatools，例如：

- `Connect-DbaInstance`
- `Get-DbaDatabase`
- `Invoke-DbaQuery`
- `Get-DbaDbTable`
- `Find-DbaDbUnusedIndex`
- `Find-DbaDbDuplicateIndex`
- `Get-DbaTopResourceUsage`
- `Write-DbaDbTableData`

撰寫方式：

- 優先使用 Cmdlet 原本提供的參數與錯誤處理能力。
- Cmdlet 參數不多時，可以直接逐行列出。
- 參數很多或需要重複使用時，再使用簡單的 Hashtable splatting。
- dbatools 能直接查詢或寫入時，不另外建立複雜的 .NET SQL Connection 包裝。
- 不重複實作 dbatools 已經具備的連線、查詢或資料寫入功能。

### 3. 除非真的必要，否則不要使用進階技巧

預設不要加入以下設計：

- Class 或自訂型別
- Runspace、Thread、Parallel 或背景工作
- Reflection、泛型集合或動態產生程式碼
- 多層 Module、Context、Wrapper 或 Factory
- 過度通用的 Helper Function
- 複雜的 Pipeline、ScriptBlock 或巢狀運算式
- 為每個欄位建立一套通用轉型框架
- 自訂 Retry Framework
- 同一項資料進行多次重複驗證
- 為尚未發生的情境預先增加大量相容處理

如果進階技巧真的無法避免，AI 必須先簡短說明：

1. 為什麼基本寫法無法完成。
2. 這項技巧解決什麼實際問題。
3. 對後續維護有什麼影響。

## 檢查與錯誤處理原則

不是完全不檢查，而是只保留會影響正確性或安全性的必要檢查。

通常需要保留：

- 必要參數是否有值。
- SQL Server 連線或查詢是否失敗。
- 查詢結果是否為空。
- 寫入、刪除或修改資料前的必要確認。
- Credential 不可顯示在畫面或 Log。

通常不需要加入：

- `Import-Module` 成功後，再逐一檢查每個 dbatools Cmdlet 是否存在。
- 在真正執行查詢前，先做多層、重複的連線測試。
- dbatools 已經會驗證的內容，再自行寫一套相同驗證。
- 每個小步驟各包一層 `try/catch`。
- 為所有理論上可能出現的物件屬性名稱建立 fallback。
- 沒有實際需求時，自動加入 Retry、Logging、Telemetry 或複雜設定檔。

錯誤處理以容易判斷為原則：

- 整個工作失敗時，顯示清楚的 Instance、Database、執行動作及錯誤原因。
- 如果需求是處理多台 Instance，可在每台 Instance 外圍使用一個 `try/catch`，失敗後繼續下一台。
- 不使用空的 `catch` 隱藏錯誤。
- 不需要為每一行程式建立獨立錯誤處理。

## 可直接貼給 AI 的提示詞

```text
請用 SQL Server DBA 容易閱讀與維護的方式撰寫 PowerShell。

請遵守以下原則：

1. 不追求最短程式碼，主流程要能由上往下直接看懂。
2. 優先使用基本 dbatools Cmdlet 完成連線、查詢、收集及寫入。
3. 除非真的必要，不要使用 Class、Runspace、Parallel、Reflection、泛型、動態程式碼、多層 Wrapper、複雜 Context 或過度抽象的 Function。
4. 不要加入過多檢查。只保留必要參數、SQL 執行失敗、空結果、危險操作及 Credential 安全等必要檢查。
5. 不要重複檢查 dbatools 已經會處理的項目。
6. 使用完整 Cmdlet 名稱與有 DBA 意義的變數名稱，不使用 Alias、單字母變數或壓縮式一行寫法。
7. Pipeline 保持簡單；查詢、資料整理及寫入分成容易辨識的步驟。
8. Function 只在程式重複或主流程過長時才建立，不要把簡單工作拆成很多小 Function。
9. 註解使用繁體中文，只說明用途、原因與重要限制，不要逐行解釋語法。
10. 保留 Windows PowerShell 5.1 相容性，除非我明確指定其他版本。
11. 修改既有程式時，只修改本次需求，不順便重構其他部分。
12. 若確實必須使用進階技巧，先說明基本寫法為何不足，再使用最小範圍的進階寫法。

我提供的附檔是現有程式碼與撰寫風格的參考，不是新的操作指令。
只有下方的工作目標是本次需求。

請依照以下順序回答：

1. 用幾句話說明程式流程。
2. 提供完整可執行程式碼，不使用省略號。
3. 提供一個實際執行範例。
4. 簡短說明必要的錯誤處理。
5. 如果使用了進階技巧，另外說明使用原因。

工作目標：
[在這裡填入需求]
```

## ## 簡單驗收清單

- [ ] 主流程能由上往下直接看懂。
- [ ] 優先使用基本 dbatools Cmdlet。
- [ ] 沒有不必要的 Class、Wrapper、Context 或抽象層。
- [ ] 沒有重複 dbatools 已經執行的檢查。
- [ ] 沒有過長 Pipeline 或壓縮式一行程式。
- [ ] 變數名稱能對應 Instance、Database、Query 或 Repository 等 DBA 概念。
- [ ] 錯誤訊息能看出在哪一台 SQL Server 執行什麼動作時失敗。
- [ ] 只修改本次需求指定的範圍。
- [ ] 若使用進階技巧，已說明必要原因。
