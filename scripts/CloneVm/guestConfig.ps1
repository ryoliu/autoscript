#在 WIN2019-LAB2 內用系統管理員 PowerShell 執行：
Rename-Computer -NewName 'WIN2019-LAB2' -Restart
#重開後設定 Host-only IP：
Get-NetIPAddress -IPAddress '192.168.56.101' | Select-Object InterfaceAlias,IPAddress
#看查出來的 InterfaceAlias，假設是 Ethernet 2，執行：
Remove-NetIPAddress -InterfaceAlias 'Ethernet 2' -IPAddress '192.168.56.101' -Confirm:$false

New-NetIPAddress -InterfaceAlias 'Ethernet 2' -IPAddress '192.168.56.102' -PrefixLength 24
#Host-only 網卡不要設定 Default Gateway。NAT 的 10.0.2.15 可以保留，不用改。
#最後驗證：
hostname
ipconfig
ping 192.168.56.101
#如果 ping 不通，在兩台 guest 都開 ICMP：
New-NetFirewallRule -DisplayName "Allow ICMPv4-In" -Protocol ICMPv4 -IcmpType 8 -Direction Inbound -Action Allow
#
Enable-PSRemoting -Force

#WIN2019-LAB
Set-Item WSMan:\localhost\Client\TrustedHosts -Value '192.168.56.102' -Force
Get-Item WSMan:\localhost\Client\TrustedHosts



Enter-PSSession -ComputerName 192.168.56.101 -Credential WIN2019-LAB\Administrator
cd C:\Autoscript\InstallSql\psmodules
.\Install-SqlServer.ps1 -InstallMode Silent