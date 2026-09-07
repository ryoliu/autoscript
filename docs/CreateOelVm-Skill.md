# Create OEL VM Skill 說明

## 目的

`create-oel-vm` 是用來建立 Oracle Linux/OEL VirtualBox VM 的 Codex Skill。它使用本機既有 ISO，建立 VM、配置 CPU/RAM/VDI/NAT、掛載 ISO，並啟動到 Oracle Linux 安裝畫面。

此 Skill 不做 Kickstart unattended 安裝，也不會自動填入 root 密碼、分割區或套件選項。Oracle Linux 安裝流程仍由使用者在 VirtualBox GUI 內完成。

## 檔案位置

- Skill 設定：`C:\powershell\Script\autoscript\.agents\skills\create-oel-vm\SKILL.md`
- Codex UI metadata：`C:\powershell\Script\autoscript\.agents\skills\create-oel-vm\agents\openai.yaml`
- 建立 VM 腳本：`C:\powershell\Script\autoscript\.agents\skills\create-oel-vm\scripts\New-VirtualBoxOelVm.ps1`

## 預設規格

| 項目 | 預設值 |
| --- | --- |
| VM 名稱 | `OEL8-R7` |
| ISO | `C:\ISO\OracleLinux-R8-U7-x86_64-dvd.iso` |
| VM 目錄 | `C:\VM` |
| VirtualBox OS Type | `Oracle8_64` |
| CPU | `2 vCPU` |
| RAM | `4096 MB` |
| 磁碟 | `102400 MB` dynamic VDI |
| 網路 | `NAT` |
| 開機順序 | DVD 第一、Disk 第二 |
| 啟動模式 | `gui` |

## 使用方式

先做 dry run，確認路徑與名稱：

```powershell
& "C:\powershell\Script\autoscript\.agents\skills\create-oel-vm\scripts\New-VirtualBoxOelVm.ps1" -WhatIf
```

使用預設值建立 VM：

```powershell
& "C:\powershell\Script\autoscript\.agents\skills\create-oel-vm\scripts\New-VirtualBoxOelVm.ps1"
```

建立指定名稱的 VM：

```powershell
& "C:\powershell\Script\autoscript\.agents\skills\create-oel-vm\scripts\New-VirtualBoxOelVm.ps1" -VMName "OEL8-R7-NEW"
```

使用不同 ISO 或 VM 目錄：

```powershell
& "C:\powershell\Script\autoscript\.agents\skills\create-oel-vm\scripts\New-VirtualBoxOelVm.ps1" `
  -VMName "OEL8-R7-TEST" `
  -ISOPath "C:\ISO\OracleLinux-R8-U7-x86_64-dvd.iso" `
  -VMFolder "C:\VM"
```

## 參數

| 參數 | 說明 | 預設值 |
| --- | --- | --- |
| `-VMName` | VirtualBox VM 名稱 | `OEL8-R7` |
| `-ISOPath` | Oracle Linux ISO 路徑 | `C:\ISO\OracleLinux-R8-U7-x86_64-dvd.iso` |
| `-VMFolder` | VM 儲存根目錄 | `C:\VM` |
| `-CPUCount` | vCPU 數量 | `2` |
| `-MemoryMB` | 記憶體 MB | `4096` |
| `-DiskSizeMB` | VDI 容量 MB | `102400` |
| `-NetworkMode` | 網路模式，目前僅支援 `nat` | `nat` |
| `-StartType` | VirtualBox 啟動模式，支援 `gui` 或 `headless` | `gui` |
| `-WhatIf` | 只顯示將執行的動作，不建立 VM | 無 |

## 安全行為

腳本會先驗證下列項目：

- `VBoxManage.exe` 是否存在
- ISO 檔是否存在
- VM 名稱是否已被註冊
- 目標 VDI 檔是否已存在
- VM folder 是否不是檔案路徑

若 VM 或 VDI 已存在，腳本會停止，不會覆蓋、不會 unregister、不會刪除既有 VM 或磁碟。

## 建立後驗證

腳本完成後會自動檢查並輸出：

- VM 狀態
- VM 名稱與 OS type
- CPU 與 RAM
- 開機順序
- NAT 網路
- ISO 掛載位置
- VDI 格式、容量與 dynamic 狀態

也可手動查詢：

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" showvminfo "OEL8-R7" --machinereadable
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" showmediuminfo "C:\VM\OEL8-R7\OEL8-R7.vdi"
```

## 常見錯誤

### VM already exists

代表 VirtualBox 已有同名 VM。改用新的 `-VMName`，或手動確認後再清理舊 VM。

### Target VDI already exists

代表目標磁碟檔已存在。改用新的 `-VMName`，或手動確認後再移除舊 VDI。

### ISO not found

代表 `-ISOPath` 指定的 ISO 檔不存在。確認檔案路徑後重新執行。

### VBoxManage.exe was not found

代表 VirtualBox 未安裝，或 `VBoxManage.exe` 不在預設路徑與 PATH 中。確認 VirtualBox 安裝狀態後重新執行。

## 驗證 Skill

修改 Skill 後可執行：

```powershell
python "C:\Users\admin\.codex\skills\.system\skill-creator\scripts\quick_validate.py" "C:\powershell\Script\autoscript\.agents\skills\create-oel-vm"
```

檢查 PowerShell 語法：

```powershell
$path = "C:\powershell\Script\autoscript\.agents\skills\create-oel-vm\scripts\New-VirtualBoxOelVm.ps1"
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
$errors
```
