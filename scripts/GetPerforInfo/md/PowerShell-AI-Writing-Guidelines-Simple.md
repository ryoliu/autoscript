# PowerShell AI 撰寫規範：簡單、易讀、可維護版

## 目的

這份規範用來要求 AI 撰寫容易閱讀、容易修改、容易除錯的 PowerShell。

目標使用者以具備 PowerShell 基礎、熟悉 Windows 與 SQL Server 維運的 DBA 為主。

重點不是追求最短程式碼、最多技巧或最完整的通用框架，而是讓維護者可以由上往下理解流程，快速找到設定、執行步驟與錯誤位置。

---

## 一、核心原則

### 1. 優先讓人看得懂

AI 撰寫 PowerShell 時，第一優先不是「程式碼最漂亮」，而是「維護者能快速理解」。

應遵守：

- 主流程應由上往下閱讀即可理解。
- 不追求最短行數。
- 可以多寫幾行，換取清楚的執行步驟。
- 重要步驟應明確分段。
- 不要把多個重要動作壓縮在同一行。
- 變數名稱應直接反映用途。
- 避免只有作者自己看得懂的縮寫。
- 使用完整 Cmdlet 名稱，不使用不易理解的 Alias。

---

### 2. 保持簡單，不要過度設計

日常 DBA Script 應以完成目前需求為主。

除非需求明確提出，AI 不應主動加入：

- Class
- 多層 Module
- Context Object
- Wrapper Framework
- Factory Pattern
- Dependency Injection
- Runspace
- Parallel
- Thread Job
- Background Job
- Reflection
- 動態產生程式碼
- 複雜的 Retry Framework
- 複雜的 Logging Framework
- Telemetry
- 多種 Config Format
- 多種 Credential Provider
- 自動相容多版本的複雜機制

如果基本 PowerShell 與現有工具已經可以完成工作，就不要增加抽象層。

---

### 3. 只解決目前需求

修改現有 Script 時，只修改本次需求需要的部分。

例如需求只是：

- 增加一個過濾條件
- 修改一個 SQL Query
- 多收集一個欄位
- 更換 Repository Table
- 調整 Top N
- 增加一個 Database 排除條件

就只處理相關部分。

不要因為看到舊程式，就順便：

- 全面重構
- 改成 Function Framework
- 改成 Module
- 改成物件導向
- 加 Retry
- 加 Logging
- 加 Parallel
- 重寫 Credential 架構

除非使用者明確要求。

---

## 二、程式流程規則

### 1. 常修改的設定放最上方

例如：

- Server
- Database
- Repository
- Table
- Path
- Login Name
- Query Timeout
- Top N
- Excluded Database
- Feature Switch

維護者應該不用搜尋整支 Script，就能找到常改設定。

---

### 2. 依照實際執行順序排列

建議主流程保持類似：

1. 設定
2. 載入必要模組
3. 取得 Credential
4. 取得目標主機或 Database
5. 執行查詢或收集
6. 整理結果
7. 寫入或輸出
8. 顯示完成訊息
9. 清理必要資源

不要把主要邏輯拆散到很多 Function 或其他檔案，導致需要來回跳轉才能理解。

---

### 3. Function 不要拆得太細

只有以下情況才優先考慮 Function：

- 相同邏輯實際重複多次。
- 主流程因為一段複雜邏輯而難以閱讀。
- 該功能有明確輸入與輸出。
- 抽出 Function 後，主流程真的更清楚。

不要為只呼叫一次的簡單 Cmdlet 建立 Function。

不要把每個小步驟都拆成 Function。

---

## 三、dbatools 使用原則

### 1. 優先直接使用 dbatools

如果 dbatools 已經能完成工作，優先直接使用。

例如：

- SQL Server 連線
- SQL Query
- Database 資訊
- Table 資訊
- Index 資訊
- Performance 資訊
- 寫入 SQL Table
- Backup / Restore
- Login / User
- Job
- Instance 設定

不要重新使用 .NET 寫一套相同功能，除非 dbatools 無法滿足實際需求。

---

### 2. 不重複 dbatools 已經做的檢查

AI 不應為了看起來「更完整」，增加大量重複驗證。

例如：

- 模組已成功 Import 後，不需逐一檢查每個 Cmdlet 是否存在。
- dbatools 已會處理 SQL 連線，不需先自行建立多層連線測試。
- Cmdlet 已有參數驗證時，不需再做一套相同驗證。
- 已使用正式 Exception 機制時，不需每個小步驟都再包一層。

保留真正會影響正確性、安全性或執行結果的檢查即可。

---

## 四、PowerShell 撰寫風格

### 1. 變數名稱要有意義

建議名稱應能直接對應 DBA 工作內容，例如：

- SqlInstance
- DatabaseName
- ServerList
- QueryResult
- TargetDatabases
- RepositoryServer
- RepositoryDatabase
- ReportTable
- Credential
- CollectedAt
- FailedCount
- WrittenCount

避免：

- x
- a
- tmp
- obj
- data1
- ctx

---

### 2. Pipeline 不要過長

Pipeline 適合簡單資料處理。

如果同一段同時包含：

- 查詢
- 過濾
- 欄位轉換
- 排序
- Group
- 寫入

應考慮拆成幾個有名稱的變數與步驟。

重點是維護者可以知道：

- 原始資料在哪裡
- 過濾後資料在哪裡
- 最後寫入哪些資料

---

### 3. 不使用壓縮式寫法

避免為了少幾行而使用難讀的：

- 巢狀三元運算
- 多層 ScriptBlock
- 多層 Pipeline
- 多個動作塞在同一行
- 過度簡寫
- 不常見語法技巧

如果一般 if / else / foreach 比較容易閱讀，就使用基本寫法。

---

## 五、註解規則

註解的目的不是解釋 PowerShell 語法，而是幫助 DBA 理解「這段在做什麼」以及「為什麼要這樣做」。

應註解：

- 每個主要流程區段的目的。
- 特殊過濾條件的原因。
- 特殊 workaround。
- 重要安全限制。
- DBA 未來可能需要修改的位置。

不需要：

- 每一行都加註解。
- 解釋明顯的變數指定。
- 解釋 foreach 是迴圈。
- 解釋 if 是條件判斷。
- 解釋 Cmdlet 名稱已經很清楚的功能。

---

## 六、錯誤處理原則

### 1. 保留必要的錯誤處理

通常需要處理：

- Config 無法讀取。
- Credential 無法取得。
- Repository 無法連線。
- SQL Query 執行失敗。
- 寫入資料失敗。
- 多台 Server 中某一台失敗。
- 危險操作執行失敗。

---

### 2. 多台 Server 的 Script

如果工作是逐台處理多個 SQL Server，建議：

- 單台失敗時顯示清楚錯誤。
- 記錄是哪一台 Server。
- 記錄目前執行哪個動作。
- 繼續下一台 Server。

除非錯誤發生在全域必要條件，例如：

- Repository 無法使用。
- Credential 無法載入。
- Config 錯誤。

這類錯誤可以直接停止整支 Script。

---

### 3. 不要每一行都包 try/catch

錯誤處理應以「工作單位」為範圍。

例如：

- Repository 初始化
- 單台 Server 處理
- 單個 Database 處理
- 寫入 Report

不要造成大量巢狀 try/catch，反而讓程式難讀。

---

## 七、Credential 與安全性

AI 撰寫 PowerShell 時：

- 不要把明碼 Password 寫進 Script。
- 不要把 Credential 印到畫面。
- 不要把 SecureString 轉成明碼後輸出。
- 不要在錯誤訊息中顯示 Password。
- 沿用既有 Credential 機制，不要自行更換架構。
- 除非使用者明確要求，不要新增新的 Credential 儲存方案。

---

## 八、設定檔規則

如果現有 Script 已使用 Config File：

- 優先沿用現有格式。
- 不要自行改成 JSON、YAML、XML 或其他格式。
- 不要為少量設定建立複雜 Config Class。
- 共用設定放 Config。
- 單支 Script 專用設定可以保留在 Script 最上方。

---

## 九、SQL 與資料處理規則

### 1. SQL 保持 DBA 可閱讀

SQL 不需要為了短而壓成一行。

複雜查詢應保留正常格式，讓 DBA 可以：

- 複製到 SSMS 測試
- 單獨修改 WHERE
- 單獨修改 SELECT 欄位
- 快速看懂 JOIN 條件

---

### 2. 查詢、整理、寫入分開

建議流程：

- 先取得 Query Result。
- 再過濾不需要的資料。
- 再整理成要寫入的欄位。
- 最後寫入 Repository。

不要把全部壓成一條 Pipeline。

---

### 3. 過濾條件要明確

如果有：

- System Database
- Offline Database
- Read Only Database
- 特定 Schema
- 特定 Table
- 特定 Server

等排除條件，應使用明確變數或明確條件。

不要把重要條件藏在很長的 Pipeline 中。

---

## 十、Repository Script 原則

如果 Script 會把資料寫入 Repository：

- Repository Server / Database 等共用資訊應沿用既有 Config。
- 寫入前先整理成明確欄位。
- 不要直接把整個複雜物件原封不動寫入。
- Table 不存在時可以依現有架構建立。
- 已存在的 Table 不要隨意 Drop。
- 不要自行 TRUNCATE。
- 不要自行刪除歷史資料。
- 不要在沒有需求時加入 Retention。

Schema 變更應視為獨立修改，不要偷偷在一般收集流程中自動 ALTER。

---

## 十一、系統資料庫過濾原則

SQL Server 收集類 Script 預設應避免把系統 Database 當成一般 User Database 處理。

常見需要排除：

- master
- model
- msdb
- tempdb

但不要假設每個 dbatools Cmdlet 的 System 排除參數都有完全相同語意。

如果實際測試發現 Cmdlet 的排除參數仍會回傳不需要的 Database，可以在結果取得後再做一層簡單明確的 PowerShell 過濾。

這種二次過濾屬於實際需求，不算過度防呆。

---

## 十二、主控 Script 原則

如果有一支主控 Script 負責執行多支 Collector：

主控 Script 只負責：

- 決定執行順序。
- 決定是否執行 Optional Report。
- 呼叫各子 Script。
- 顯示簡單執行狀態。

不要讓主控 Script 建立：

- Shared Context
- 共用巨大物件
- 通用 Collector Framework
- Retry Engine
- 複雜參數傳遞架構

每支子 Script 應盡可能仍可獨立執行。

---

## 十三、相容性規則

除非使用者指定其他版本：

- 以 Windows PowerShell 5.1 相容為優先。
- 不要自行使用 PowerShell 7 才支援的語法。
- 不要為了同時支援很多未知版本加入大量相容程式。
- 如果真的需要特殊版本功能，先說明原因。

---

## 十四、修改現有 Script 的規則

AI 收到現有 Script 時：

1. 先理解目前流程。
2. 找出本次需求真正需要修改的位置。
3. 儘量保留其他已經正常工作的邏輯。
4. 不改變未被要求的輸出格式。
5. 不改變未被要求的 Credential 機制。
6. 不改變未被要求的 Config。
7. 不改變未被要求的 Table Schema。
8. 不重新設計整個架構。
9. 如果必須影響其他部分，要先說明原因。
10. 修改完成後列出前後差異。

---

## 十五、回答方式規則

AI 回覆 PowerShell 開發需求時，預設依照以下方式：

1. 先用幾句話說明執行流程。
2. 提供完整程式，不使用省略號。
3. 說明使用者最常需要修改的設定。
4. 提供簡單執行方式。
5. 說明必要的外部依賴。
6. 修改既有 Script 時，列出修改前後差異。
7. 明確說明做過哪些驗證。
8. 不把靜態檢查說成已在實際 SQL Server 執行成功。

---

## 十六、AI 不應自行增加的內容

沒有明確需求時，不要自行加入：

- 自動 Retry
- 平行執行
- Thread
- Job
- Runspace
- Class
- Framework
- Context
- Wrapper
- Factory
- Reflection
- Telemetry
- 複雜 Logging
- Email Notification
- Teams Notification
- HTML Report
- JSON Config
- YAML Config
- 自動 Cleanup
- 自動 Retention
- 自動修復
- 自動 Drop Index
- 自動 ALTER TABLE
- 多版本相容框架

---

## 十七、何時可以使用進階技巧

只有在基本寫法真的無法合理完成需求時才使用。

使用前應先說明：

1. 基本寫法遇到什麼限制。
2. 為什麼需要進階技巧。
3. 這個技巧解決什麼實際問題。
4. 維護者未來需要注意什麼。

使用範圍保持最小，不要因此把整支 Script 改成複雜架構。

---

## 十八、可直接貼給 AI 的提示詞

請用 SQL Server DBA 容易閱讀與維護的方式撰寫或修改 PowerShell。

請遵守以下原則：

1. 主流程必須可以由上往下直接看懂。
2. 不追求最短程式碼，可以多寫幾行換取清楚。
3. 優先使用基本 PowerShell 與 dbatools。
4. dbatools 已能完成的工作，不另外重寫一套。
5. 常修改的設定集中在 Script 最上方。
6. 使用有 DBA 意義的完整變數名稱。
7. 使用完整 Cmdlet 名稱，不使用 Alias。
8. 避免過長 Pipeline 與壓縮式一行寫法。
9. Function 只在真正重複或明顯改善主流程時才使用。
10. 只保留必要的檢查與錯誤處理，不做重複驗證。
11. 多台 Server 處理時，單台失敗應顯示錯誤後繼續下一台。
12. 沿用既有 Config、Credential、Repository 與檔案架構。
13. 修改既有 Script 時，只修改本次需求，不順便全面重構。
14. 不自行加入 Retry、Parallel、Runspace、Class、Context、Framework、Logging 或其他進階機制。
15. 如果確實需要進階技巧，先說明基本寫法不足的原因。
16. 保持 Windows PowerShell 5.1 相容，除非我另外指定。
17. PS1 內的變數、註解及 Console Message 使用英文。
18. 回覆說明可以使用繁體中文。
19. 提供完整可執行程式，不使用省略號。
20. 修改完成後列出「修改前、修改後、修改原因」。

我提供的現有 Script 是目前可運作的基礎與撰寫風格參考。

請優先保留現有架構，只處理本次工作目標。

---

## 十九、簡單驗收清單

- [ ] 主流程能由上往下理解。
- [ ] 常改設定集中在最上方。
- [ ] 優先使用基本 PowerShell 與 dbatools。
- [ ] 沒有不必要的抽象層。
- [ ] 沒有不必要的 Class、Context、Wrapper 或 Framework。
- [ ] 沒有自行增加 Retry 或 Parallel。
- [ ] 沒有過長 Pipeline。
- [ ] 變數名稱能直接看懂用途。
- [ ] 錯誤訊息可以看出 Instance 與失敗動作。
- [ ] 只修改本次需求相關範圍。
- [ ] Credential 沒有明碼或輸出到畫面。
- [ ] Config 與既有架構沒有被任意更換。
- [ ] System Database 排除符合需求。
- [ ] PowerShell 5.1 可以使用。
- [ ] 提供的是完整程式。
- [ ] 修改後有清楚列出差異。
- [ ] 沒有把靜態檢查描述成實際執行成功。

---

## 最重要的判斷原則

如果有兩種寫法：

一種比較短，但需要理解很多 PowerShell 技巧；

另一種稍微多幾行，但 DBA 可以直接看懂；

優先選擇第二種。

這份規範的最終目標是：

**讓接手的 DBA 不需要成為 PowerShell 專家，也能知道 Script 在做什麼、設定在哪裡、錯誤發生在哪裡，以及應該去哪裡修改。**
