<#
  UEFI 路线一键刷写：boot_a = UEFI 固件，vendor_boot_a = ESP(FAT32)
  用法: .\tools\flash-uefi.ps1
  恢复: .\tools\device-recover.ps1
#>
param(
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
$esp  = Join-Path $Other "esp-nuwa.img"
foreach ($f in @($uefi, $esp)) {
  if (-not (Test-Path $f)) { Write-Host "缺少文件: $f"; exit 1 }
}

Write-Host "刷入 UEFI 固件 -> boot_a ..."
& $Fastboot flash boot_a $uefi 2>&1 | Select-String "OKAY|FAILED"

Write-Host "刷入 ESP(FAT32) -> vendor_boot_a ..."
& $Fastboot flash vendor_boot_a $esp 2>&1 | Select-String "OKAY|FAILED"

Write-Host "重启 ..."
& $Fastboot reboot 2>&1 | Out-Null

Write-Host ""
Write-Host "观察 90 秒 USB 枚举（UEFI 起来后应出现 VID_18D1）..."
for ($i = 0; $i -lt 45; $i++) {
  $usb = (Get-PnpDevice -PresentOnly 2>$null | Where-Object { $_.InstanceId -match "VID_18D1|VID_2717" } | Measure-Object).Count
  if ($usb -gt 0) { Write-Host ("  t=" + ($i * 2) + "s  USB 设备出现 ($usb)") }
  Start-Sleep -Seconds 2
}
Write-Host "完成。请观察屏幕：是否有 UniXNU 菜单 / 'EFI loader on volume N' / 内核日志"
