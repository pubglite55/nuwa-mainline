<#
  探针实验：验证 init_boot 的 ramdisk 是否被内核执行。
  刷入：原厂内核 + 探针 initramfs（5 秒重启）+ 原厂 vendor_boot。
  判定：设备周期性重启 => init_boot 生效。
#>
param(
  [string]$Backup = "C:\Users\L1872\Documents\nuwa ubt\backup\nuwa-backup",
  [string]$Firmware = "C:\Users\L1872\Downloads\NikoHyper_NUWA_OS4.0.24.0.XEOCNXM_5b3041959e_17.0\firmware-update",
  [string]$Other = "C:\Users\L1872\Documents\nuwa ubt\other",
  [string]$Fastboot = "C:\Android\platform-tools\fastboot.exe",
  [string]$Adb = "C:\Android\platform-tools\adb.exe"
)

$fb = & $Fastboot devices 2>&1 | Out-String
if ($fb -notmatch "fastboot") {
  Write-Host "设备不在 fastboot，请先长按电源 15 秒。当前 adb:"
  & $Adb devices -l
  exit 1
}

Write-Host "刷入探针组合 ..."
& $Fastboot flash boot_a (Join-Path $Backup "boot_a.img")      | Select-String "OKAY|FAILED"
& $Fastboot flash init_boot_a (Join-Path $Other "init_boot-probe.img") | Select-String "OKAY|FAILED"
& $Fastboot flash vendor_boot_a (Join-Path $Firmware "vendor_boot.img") | Select-String "OKAY|FAILED"
& $Fastboot reboot | Out-Null

Write-Host "观察 120 秒（探针应每 5 秒重启一次；USB 会周期性消失/出现）..."
$seen = 0
for ($i = 0; $i -lt 60; $i++) {
  $usb = (Get-PnpDevice -PresentOnly -Class USB 2>$null | Where-Object { $_.InstanceId -match "VID_2717" } | Measure-Object).Count
  if ($usb -gt 0) { $seen++; Write-Host ("  t=" + ($i * 2) + "s USB 出现") }
  Start-Sleep -Seconds 2
}
if ($seen -gt 0) { Write-Host "结论：USB 周期出现 => init_boot 的 ramdisk 被内核执行（探针生效）" }
else { Write-Host "结论：无周期信号 => init_boot 可能未被执行，或内核在 init 前挂死" }
