---
name: create-oel-vm
description: Create Oracle Linux/OEL VirtualBox VMs from a local ISO with validated CPU, RAM, dynamic VDI disk, NAT networking, boot order, ISO attachment, and GUI startup. Use when Codex needs to create, inspect, or safely prepare an Oracle Linux VM installation in VirtualBox.
---

# Create OEL VM

## Workflow

1. Use VirtualBox through `VBoxManage.exe`.
2. Confirm the local ISO path exists before changing anything.
3. Confirm the target VM name is not already registered and the target VDI path does not already exist.
4. Prefer the bundled script:

```powershell
& "C:\powershell\Script\autoscript\.agents\skills\create-oel-vm\scripts\New-VirtualBoxOelVm.ps1"
```

5. Start the VM in GUI mode so the user can complete the Oracle Linux installer.
6. Verify the VM, disk, ISO attachment, NAT adapter, and boot order with `VBoxManage showvminfo --machinereadable` and `VBoxManage showmediuminfo`.

## Defaults

- VM name: `OEL8-R7`
- ISO path: `C:\ISO\OracleLinux-R8-U7-x86_64-dvd.iso`
- VM folder: `C:\VM`
- OS type: `Oracle8_64`
- CPU: `2`
- Memory: `4096` MB
- Disk: `102400` MB dynamic VDI
- Network: `nat`
- Boot order: DVD first, disk second
- Start type: `gui`

## Script Usage

Use `scripts/New-VirtualBoxOelVm.ps1` for deterministic VM creation:

```powershell
& "C:\powershell\Script\autoscript\.agents\skills\create-oel-vm\scripts\New-VirtualBoxOelVm.ps1" `
  -VMName "OEL8-R7" `
  -ISOPath "C:\ISO\OracleLinux-R8-U7-x86_64-dvd.iso" `
  -VMFolder "C:\VM" `
  -CPUCount 2 `
  -MemoryMB 4096 `
  -DiskSizeMB 102400 `
  -NetworkMode nat `
  -StartType gui
```

Use `-WhatIf` to validate inputs and show intent without creating or starting a VM.

## Safety

- Do not download ISO files.
- Do not guess ISO paths; require a concrete local ISO path.
- Do not embed passwords, product keys, license secrets, or Kickstart answers.
- Do not overwrite, unregister, delete, or recreate existing VMs or VDI files.
- If the VM or target VDI already exists, stop with a clear error and ask the user to provide another VM name or manually clean up.
- Treat disk deletion, VM removal, snapshot deletion, and network reconfiguration as destructive operations requiring explicit user confirmation.
- Leave Oracle Linux installation steps to the VirtualBox GUI. This skill does not perform unattended Kickstart installation.

## Validation

After creation, report these values to the user:

- VM state
- VM name and OS type
- CPU and memory
- Disk path, capacity, and dynamic VDI format
- ISO attachment
- NIC mode
- Boot order
