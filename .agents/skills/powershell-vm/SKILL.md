---
name: powershell-vm
description: Use when creating, configuring, starting, stopping, or inspecting virtual machines with PowerShell, especially VirtualBox VM creation, Windows Server 2019 ISO mounting, VM CPU/memory/disk/network settings, boot order, and manual Windows Server installation workflows.
---

# PowerShell VM

## Workflow

1. Identify the virtualization platform before writing commands. Use VirtualBox by default for Windows Server 2019 lab VM requests unless the user specifies Hyper-V or VMware.
2. Confirm or infer the VM name, ISO path, VM folder, CPU count, memory, disk size, and network mode.
3. Prefer parameterized PowerShell scripts over hard-coded one-off commands.
4. Validate required tools and paths before creating or changing a VM.
5. For VirtualBox, use `VBoxManage.exe` and fail clearly when it cannot be found.
6. Keep manual OS installation workflows manual: attach the ISO, set DVD-first boot order, and start the VM GUI.

## Defaults

- Target OS: Windows Server 2019 64-bit.
- CPU: 2 vCPU.
- Memory: 4096 MB.
- Disk: 80 GB dynamic VDI.
- Network: NAT.
- Boot order: DVD first, disk second.
- Installation mode: manual installation from a local ISO.

## Safety

- Do not download Windows ISO files automatically.
- Do not embed product keys, local administrator passwords, or license secrets.
- Do not overwrite, unregister, delete, or recreate an existing VM unless the user explicitly asks for that destructive behavior.
- Treat disk deletion, VM removal, snapshot deletion, and network reconfiguration as high-risk operations.

## Validation

- Check that the ISO path exists before creating the VM.
- Check that `VBoxManage.exe` exists or is discoverable.
- Check whether a VM with the requested name already exists before creating one.
- After creation, verify the VM, disk, ISO attachment, NAT adapter, and boot order with `VBoxManage showvminfo --machinereadable`.

## Local Script

Use `C:\AutoScript\scripts\New-VirtualBoxWinServer2019Vm.ps1` when the task is to create a Windows Server 2019 VirtualBox VM from PowerShell.
