---
name: powershell-vm
description: Use when creating, configuring, starting, stopping, or inspecting virtual machines with PowerShell, especially VirtualBox VM creation, Windows Server 2019 ISO mounting, unattended installation, VM CPU/memory/disk/network settings, and boot order workflows.
---

# PowerShell VM

## Workflow

1. Identify the virtualization platform before writing commands. Use VirtualBox by default for Windows Server 2019 lab VM requests unless the user specifies Hyper-V or VMware.
2. Confirm or infer the VM name, ISO path, VM folder, CPU count, memory, disk size, and network mode.
3. Prefer parameterized PowerShell scripts over hard-coded one-off commands.
4. Validate required tools and paths before creating or changing a VM.
5. For VirtualBox, use `VBoxManage.exe` and fail clearly when it cannot be found.
6. Use the manual script when the user wants to attach an ISO and install Windows interactively.
7. Use the unattended script when the user asks to automatically install Windows Server 2019 with `VBoxManage unattended install`.

## Defaults

- Target OS: Windows Server 2019 64-bit.
- CPU: 2 vCPU.
- Memory: 4096 MB.
- Disk: 80 GB dynamic VDI for manual installs; 60 GB dynamic VDI for unattended Windows Server 2019 lab installs.
- Network: NAT.
- Boot order: DVD first, disk second.
- Manual installation mode: local ISO attached and VM started in GUI mode.
- Unattended installation mode: ImageIndex 2, Standard Desktop Experience, started headless unless the user asks for GUI.

## Safety

- Do not download Windows ISO files automatically.
- Do not embed product keys, local administrator passwords, or license secrets.
- Do not guess ISO paths. Ask for or require the local ISO path.
- Do not overwrite, unregister, delete, or recreate an existing VM unless the user explicitly asks for that destructive behavior.
- Treat disk deletion, VM removal, snapshot deletion, and network reconfiguration as high-risk operations.
- Treat `-Recreate` as destructive. Use it only when the user explicitly confirms the existing VM and disk can be deleted.

## Validation

- Check that the ISO path exists before creating the VM.
- Check that `VBoxManage.exe` exists or is discoverable.
- Check whether a VM with the requested name already exists before creating one.
- After creation, verify the VM, disk, ISO attachment, NAT adapter, and boot order with `VBoxManage showvminfo --machinereadable`.
- For unattended installs, prefer a first test with `-StartType gui` so the user can observe setup failures.

## Local Scripts

- Use `C:\AutoScript\scripts\New-VirtualBoxWinServer2019Vm.ps1` for manual Windows Server 2019 VirtualBox VM creation from PowerShell.
- Use `C:\AutoScript\scripts\New-VirtualBoxWinServer2019UnattendedVm.ps1` for automated Windows Server 2019 VirtualBox VM creation with `VBoxManage unattended install`.
- Use `C:\AutoScript\scripts\Start-WinServer2019UnattendedLab.ps1` as the easier launcher for unattended Windows Server 2019 lab VM creation; it prompts for passwords when they are not provided.

## Unattended Install Notes

- Required inputs: local Windows Server 2019 ISO path, guest user password, and Administrator password.
- Default VM name: `WIN2019-LAB`.
- Default VM folder: `C:\VM`.
- Default memory: 4096 MB.
- Default CPU count: 2.
- Default disk size: 61440 MB.
- Default image index: 2, Windows Server Standard Desktop Experience.
- Default hostname: `WIN2019LAB`.
- Default start type: `headless`; use `gui` for learning or debugging.
- Leave product key blank for Windows Server Evaluation media unless the user provides a licensed key.
- By default the unattended script creates two extra VDI disks: `E-Data.vdi` at 102400 MB and `T-Data.vdi` at 204800 MB.
- The unattended script passes `--post-install-command` to initialize RAW disks in Windows and format them as `E:` label `Data` and `T:` label `Temp`.
- Use `-EDriveSizeMB`, `-TDriveSizeMB`, `-EDriveLabel`, and `-TDriveLabel` to customize the data disks, or `-SkipExtraDataDisks` to create only the OS disk.
