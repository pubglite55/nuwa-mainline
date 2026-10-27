<#
  nuwa 启动：两条路径
    A) ESP 在 vendor_boot_a（512B 扇区 FAT32，64MB）—— 可能不被 FatDxe 挂载
    B) payload 在 boot_b（4KiB 扇区 FAT16，192MB）—— 与 NUWA-PORT.md 验证过的格式一致 ★推荐

  用法:
    .\tools\flash-uefi.ps1            # 路径 A
    .\tools\flash-uefi.ps1 -BootB     # 路径 B（推荐）
#>
param(
  [switch]$BootB,
  [string]$Other = "C:\Users\L1872\Documents\nuwa ubt\other",
  [string]$Fastboot = "C:\Android\platform-tools\fastboot.exe",
  [string]$Adb = "C:\Android\platform-tools\adb.exe"
)

$fb = & $Fastboot devices 2>&1 | Out-String
if ($fb -notmatch "fastboot") {
  Write-Host "设备不在 fastboot。当前 adb:"
  & $Adb devices -l
  exit 1
}

$uefi = Join-Path $Other "uefi-nuwa\Mu-nuwa.img"
if (-not (Test-Path $uefi)) { Write-Host "缺少 $uefi"; exit 1 }

Write-Host "刷 UEFI 固件 -> boot_a ..."
& $Fastboot flash boot_a $uefi 2>&1 | Select-String "OKAY|FAILED"

if ($BootB) {
  $payload = Join-Path $Other "payload-bootb.img"
  if (-not (Test-Path $payload)) { Write-Host "缺少 $payload"; exit 1 }
  Write-Host "刷 payload(4KiB FAT16) -> boot_b ..."
  & $Fastboot flash boot_b $payload 2>&1 | Select-String "OKAY|FAILED"
} else {
  $esp = Join-Path $Other "esp-nuwa.img"
  if (-not (Test-Path $esp)) { Write-Host "缺少 $esp"; exit 1 }
  Write-Host "刷 ESP(512B FAT32) -> vendor_boot_a ..."
  & $Fastboot flash vendor_boot_a $esp 2>&1 | Select-String "OKAY|FAILED"
}

Write-Host "重启 ..."
& $Fastboot reboot 2>&1 | Out-Null

Write-Host ""
Write-Host "观察 90 秒 USB 枚举..."
for ($i = 0; $i -lt 45; $i++) {
  $usb = (Get-PnpDevice -PresentOnly 2>$null | Where-Object { $_.InstanceId -match "VID_18D1|VID_2717" } | Measure-Object).Count
  if ($usb -gt 0) { Write-Host ("  t=" + ($i * 2) + "s  USB ($usb)") }
  Start-Sleep -Seconds 2
}
Write-Host ""
Write-Host "看屏幕：UniXNU 菜单应出现 'EFI loader on volume N' 或 Ubuntu 条目"
