# PowerShell AI 撰寫規範：DBA 易讀簡單版

## 目的

這份規範用來要求 AI 撰寫容易讓 DBA 閱讀、理解與維護的 PowerShell。

重點不是使用最多的 PowerShell 技巧，也不是建立最完整的框架，而是用直接、清楚、容易追蹤的方式完成需求。

---

## 1. 以 DBA 容易閱讀與維護為優先

PowerShell 的第一優先是讓 DBA 能快速看懂程式在做什麼，而不是追求最短程式碼或最進階的寫法。

撰寫時應遵守：

- 主流程應由上往下直接閱讀即可理解。
- 不追求最少行數，可以多寫幾行換取清楚。
- 常修改的設定集中在程式最上方。
- 使用有實際意義的變數名稱。
- 變數名稱應能對應 DBA 常見概念，例如 Server、Instance、Database、Query、Credential、Result。
- 使用完整 Cmdlet 名稱，不使用 `%`、`?` 等 Alias。
- 不要把多個重要動作壓縮在同一行。
- Pipeline 保持簡單，不要串接過多步驟。
- 查詢、整理資料、過濾資料、寫入資料應盡量分成清楚的步驟。
- Function 不要拆得太細。
- 只有真正重複的邏輯，或主流程明顯過長時，才考慮建立 Function。
- 不要為只使用一次的簡單工作建立 Function。
- 註解應說明用途、原因與重要限制，不需要逐行解釋 PowerShell 語法。
- 修改現有 Script 時，只修改本次需求相關部分，不要順便全面重構。
- 若有兩種寫法，一種較短但較難懂，另一種稍長但容易理解，優先選擇容易理解的版本。

### 建議的主流程

通常可以依照以下順序撰寫：

1. 設定參數
2. 載入必要模組
3. 取得 Credential
4. 取得目標 Server 或 Database
5. 執行查詢或工作
6. 整理及過濾結果
7. 顯示或寫入結果
8. 顯示完成訊息

避免讓主要流程需要跳到多個 Function、Module 或其他檔案才能理解。

---

## 2. 優先使用基本 dbatools

如果 dbatools 已經可以直接完成工作，優先使用 dbatools。

例如：

- SQL Server 連線
- 執行 SQL Query
- 取得 Database 資訊
- 取得 Table 資訊
- 取得 Index 資訊
- 取得 Performance 資訊
- Backup / Restore
- Login / User 管理
- SQL Agent Job
- SQL Server 設定
- 寫入資料到 SQL Table

撰寫原則：

- 優先直接使用 dbatools Cmdlet。
- 優先使用 Cmdlet 原本提供的參數。
- 優先使用 Cmdlet 原本提供的錯誤處理能力。
- Cmdlet 參數不多時，直接逐行列出即可。
- 只有參數很多或需要重複使用時，才考慮簡單的 Hashtable splatting。
- dbatools 能直接完成的工作，不要另外用 .NET 重新實作。
- 不要為一個 dbatools Cmdlet 再包一層沒有實際價值的 Function。
- 不要重複實作 dbatools 已經具備的連線、查詢、備份、還原或資料寫入功能。
- 不要因為「最佳實務」而增加大量額外包裝，除非實際需求需要。
- 如果 dbatools 的基本功能不足，才考慮使用其他方法。

### 使用 dbatools 的判斷原則

先問：

1. dbatools 是否已經有對應 Cmdlet？
2. Cmdlet 原本的參數是否已經可以完成需求？
3. 是否真的有必要自行建立額外連線或包裝？
4. 額外設計是否真的能讓 DBA 更容易維護？

如果答案是否定的，就保持簡單。

---

## 3. 除非真的必要，否則不要使用進階技巧

預設不要加入 PowerShell 進階架構。

除非基本寫法確實無法合理完成需求，否則不要使用：

- Class
- 自訂型別
- Runspace
- Parallel
- Thread
- Background Job
- Reflection
- 泛型集合
- 動態產生程式碼
- 多層 Module
- Context Object
- Wrapper
- Factory Pattern
- Dependency Injection
- 過度通用的 Helper Function
- 複雜 ScriptBlock
- 多層巢狀 Pipeline
- 複雜 Retry Framework
- 複雜 Logging Framework
- Telemetry
- 自動相容多版本的複雜設計
- 為未來可能發生的需求預先建立大量功能

### 不要為了「看起來專業」而增加複雜度

AI 不應因為某種方式屬於「最佳實務」就自動加入。

應先判斷：

- 目前需求是否真的需要？
- 是否會讓 DBA 更難閱讀？
- 是否增加未來維護成本？
- 是否只是為尚未發生的情境做準備？

如果沒有實際需求，就不要加入。

### 如果真的需要使用進階技巧

AI 應先簡短說明：

1. 為什麼基本 PowerShell 或 dbatools 無法完成。
2. 這項技巧要解決什麼實際問題。
3. 為什麼這個方式比簡單方式更適合。
4. 對後續維護有什麼影響。

使用範圍應保持最小，不要因此把整支 Script 改成複雜架構。

---

## 4. 檢查與錯誤處理原則

原則不是「完全不檢查」，而是只保留真正影響正確性、安全性與執行結果的檢查。

### 通常需要保留的檢查

- 必要設定是否存在。
- 必要 Credential 是否可以取得。
- SQL Server 連線是否失敗。
- SQL Query 是否執行失敗。
- 查詢結果是否為空。
- 檔案或目錄是否為執行工作的必要條件。
- 寫入、刪除或修改資料時的必要安全確認。
- Credential 不可直接顯示在 Console 或 Log。
- 多台 Server 執行時，要能知道是哪一台 Server 發生錯誤。

### 通常不需要加入的檢查

- Import-Module 成功後，再逐一確認每個 Cmdlet 是否存在。
- 在正式查詢前，先做多層重複的 Connection Test。
- dbatools 已經會驗證的內容，再自行寫一套相同驗證。
- 每個小步驟都各包一層 try/catch。
- 為所有理論上可能出現的欄位名稱建立 fallback。
- 為尚未發生的錯誤情境加入大量防呆。
- 沒有實際需求時，自動加入 Retry。
- 沒有實際需求時，自動加入完整 Logging Framework。
- 同一項資料進行多次重複驗證。

### try/catch 使用原則

try/catch 應以「一個完整工作單位」為範圍。

例如：

- 取得 Repository 資訊
- 處理一台 SQL Server
- 處理一個 Database
- 執行一個主要收集工作
- 寫入結果

不要為每一行程式建立 try/catch。

### 多台 SQL Server 的錯誤處理

如果 Script 會處理多台 Server：

- 單台 Server 失敗時，顯示清楚錯誤。
- 錯誤訊息應包含 Server 或 Instance。
- 錯誤訊息應說明正在執行什麼動作。
- 如業務需求允許，失敗後繼續下一台。
- 不要因單台 Server 失敗而讓全部工作停止。

但如果發生的是全域必要條件錯誤，例如：

- Config 無法讀取
- Credential 無法載入
- Repository 無法使用
- 必要模組無法載入

則可以直接停止整支 Script。

### 錯誤訊息原則

錯誤訊息應讓 DBA 不需要 Debugger 就能判斷：

- 哪一台 Server
- 哪個 Database
- 正在做什麼
- 為什麼失敗

不要：

- 使用空的 catch。
- 把 Exception 吃掉。
- 只顯示「Failed」而沒有上下文。
- 顯示 Credential 或其他敏感資訊。

---

## 可直接貼給 AI 的提示詞

請用 SQL Server DBA 容易閱讀與維護的方式撰寫 PowerShell。

請遵守以下原則：

1. 以 DBA 容易閱讀與維護為第一優先。
2. 主流程必須可以由上往下直接看懂。
3. 不追求最短程式碼，可以多寫幾行換取清楚。
4. 優先使用基本 PowerShell 與 dbatools。
5. dbatools 已經能完成的工作，不另外重新實作。
6. 使用完整 Cmdlet 名稱與有 DBA 意義的變數名稱。
7. Pipeline 保持簡單，不要把過多工作壓成一行。
8. Function 只在真正重複或明顯改善主流程時使用。
9. 除非真的必要，不要使用 Class、Runspace、Parallel、Reflection、Context、Wrapper、Factory、Framework 或其他進階技巧。
10. 不要自行加入 Retry、Logging、Telemetry 或多版本相容框架。
11. 只保留真正影響正確性、安全性與執行結果的檢查。
12. 不要重複檢查 dbatools 已經會處理的內容。
13. try/catch 以完整工作單位為範圍，不要每一行都包錯誤處理。
14. 多台 Server 處理時，單台失敗應能看出是哪一台 Server 與執行動作；如需求允許，繼續下一台。
15. 修改既有 Script 時，只修改本次需求，不順便全面重構。
16. 如果確實需要進階技巧，先說明基本寫法為什麼不足，再使用最小範圍的進階設計。

---

## 簡單驗收清單

- [ ] DBA 可以由上往下看懂主流程。
- [ ] 變數名稱有明確 DBA 意義。
- [ ] 使用完整 Cmdlet 名稱。
- [ ] 優先使用基本 dbatools。
- [ ] 沒有重複實作 dbatools 已有功能。
- [ ] 沒有過長或難懂的 Pipeline。
- [ ] 沒有為簡單工作建立過多 Function。
- [ ] 沒有不必要的 Class、Context、Wrapper 或 Framework。
- [ ] 沒有自行加入不需要的 Retry 或 Parallel。
- [ ] 檢查只保留真正必要的項目。
- [ ] 沒有重複 dbatools 已執行的驗證。
- [ ] try/catch 沒有拆得太細。
- [ ] 錯誤訊息可以看出 Server 與失敗動作。
- [ ] Credential 不會顯示在 Console 或 Log。
- [ ] 修改現有 Script 時沒有順便重構無關內容。
- [ ] 如果使用進階技巧，已有明確理由。

---

## 最重要的原則

**保持簡單。**

不是功能越多越好，也不是防呆越多越好。

對 DBA 日常 PowerShell 而言，好的 Script 應該讓維護者能快速回答四個問題：

1. 這支 Script 要做什麼？
2. 我需要修改哪裡？
3. 現在執行到哪一步？
4. 出錯時我要去哪裡找原因？

如果程式可以做到這四點，就比過度抽象、過度通用、過度防呆的設計更適合日常 DBA 維護。
