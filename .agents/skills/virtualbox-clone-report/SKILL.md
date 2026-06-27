---
name: virtualbox-clone-report
description: Verify and summarize VirtualBox cloned VM identity, registration state, VM path, power state, NIC modes, and MAC addresses. Use when documenting or validating a cloned VirtualBox lab VM such as WIN2019-LAB2 against its source VM.
---

# VirtualBox Clone Report

## Workflow

Use this skill when the user wants to verify, document, or report the result of a VirtualBox clone.

1. Prefer the bundled PowerShell script:
   `..\\..\\..\\scripts\\CloneVm\\Get-VirtualBoxCloneReport.ps1`
2. Compare source and clone VM metadata:
   - VM name
   - VM UUID
   - `.vbox` path
   - power state
   - NIC mode
   - MAC address
3. Treat different MAC addresses as required for cloned VMs.
4. For Windows guest settings, state clearly that VirtualBox can verify VM-level identity, but hostname and guest IP require guest OS login, Guest Control credentials, or manual execution inside Windows.

## Script Usage

Run from PowerShell:

```powershell
.\scripts\Get-VirtualBoxCloneReport.ps1 `
  -SourceVmName 'WIN2019-LAB' `
  -CloneVmName 'WIN2019-LAB2'
```

If `VBoxManage.exe` is not in the default install path, pass it explicitly:

```powershell
.\scripts\Get-VirtualBoxCloneReport.ps1 `
  -SourceVmName 'WIN2019-LAB' `
  -CloneVmName 'WIN2019-LAB2' `
  -VBoxManagePath 'D:\Tools\VirtualBox\VBoxManage.exe'
```

## Report Guidance

When answering the user, summarize in Traditional Chinese:

- Whether the clone VM exists.
- The clone VM path, UUID, NIC modes, MAC addresses, and power state.
- The source VM MAC addresses for comparison.
- Whether MAC addresses differ.
- Remaining guest-side work, such as renaming Windows hostname or changing Host-only IP.

Keep the report concise and operational.


