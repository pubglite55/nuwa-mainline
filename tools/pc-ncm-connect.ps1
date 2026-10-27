<#
  PC 端：连接手机通过 USB NCM 暴露的网络（192.168.0.1）
  用法: .\tools\pc-ncm-connect.ps1 [-DeviceIp 192.168.0.1] [-LocalIp 192.168.0.2]
  前提: 手机已启动到 Linux，initramfs 已建好 usb0
#>
param(
  [string]$DeviceIp = "192.168.0.1",
  [string]$LocalIp  = "192.168.0.2",
  [string]$PrefixLen = "24"
)

Write-Host "=== 查找 NCM/RNDIS 网卡 ==="
$adapters = Get-NetAdapter | Where-Object {
  $_.InterfaceDescription -match "NCM|RNDIS|Remote NDIS|USB Ethernet|CDC" -or
  $_.Name -match "NCM|RNDIS"
}
if (-not $adapters) {
  Write-Host "未找到 NCM/RNDIS 网卡。请确认："
  Write-Host "  1) 手机已启动到 Linux（屏幕上应显示 '系统就绪'）"
  Write-Host "  2) USB 线已连接"
  Write-Host ""
  Write-Host "当前所有网卡："
  Get-NetAdapter | Select-Object Name,Status,InterfaceDescription | Format-Table -AutoSize
  exit 1
}

$adapters | Select-Object Name,Status,InterfaceDescription | Format-Table -AutoSize
$name = $adapters[0].Name
Write-Host ("使用网卡: " + $name)

Write-Host ("配置 " + $name + " -> " + $LocalIp + "/" + $PrefixLen + " ...")
$existing = Get-NetIPAddress -InterfaceAlias $name -AddressFamily IPv4 -ErrorAction SilentlyContinue
foreach ($ip in $existing) {
  if ($ip.IPAddress -ne $LocalIp) {
    Remove-NetIPAddress -InterfaceAlias $name -IPAddress $ip.IPAddress -Confirm:$false -ErrorAction SilentlyContinue
  }
}
New-NetIPAddress -InterfaceAlias $name -IPAddress $LocalIp -PrefixLength ([int]$PrefixLen) -ErrorAction SilentlyContinue | Out-Null
Set-NetIPInterface -InterfaceAlias $name -Dhcp Disabled -ErrorAction SilentlyContinue

Write-Host "测试连通性 ..."
$ok = Test-Connection -TargetName $DeviceIp -Count 2 -Quiet -ErrorAction SilentlyContinue
if ($ok) {
  Write-Host ("设备 " + $DeviceIp + " 可达 ✓")
} else {
  Write-Host ("ping " + $DeviceIp + " 无响应（有些内核不响应 ICMP，可直接试 telnet）")
}

Write-Host ""
Write-Host "连接方式："
Write-Host ("  telnet " + $DeviceIp)
Write-Host "  （Windows 若未启用 telnet 客户端：dism /online /Enable-Feature /FeatureName:TelnetClient）"
