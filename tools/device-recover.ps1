<#
  设备恢复脚本：检测到 fastboot 时刷回原厂三件套；检测到 Android 时报告状态。
  用法: .\device-recover.ps1 [-BackupDir <备份目录>] [-FirmwareDir <固件包 firmware-update>]
#>
param(
  [string]$BackupDir = "C:\Users\L1872\Documents\nuwa ubt\backup\nuwa-backup",
  [string]$FirmwareDir = "C:\Users\L1872\Downloads\NikoHyper_NUWA_OS4.0.24.0.XEOCNXM_5b3041959e_17.0\firmware-update",
  [string]$Adb = "C:\Android\platform-tools\adb.exe",
  [string]$Fastboot = "C:\Android\platform-tools\fastboot.exe"
)

$fb = & $Fastboot devices 2>&1 | Out-String
if ($fb -match "fastboot") {
  Write-Host "检测到 fastboot，开始恢复原厂三件套..."
  & $Fastboot flash vendor_boot_a (Join-Path $FirmwareDir "vendor_boot.img")
  & $Fastboot flash boot_a (Join-Path $BackupDir "boot_a.img")
  & $Fastboot flash init_boot_a (Join-Path $BackupDir "init_boot_a.img")
  & $Fastboot reboot
  Write-Host "已恢复并重启，等待 Android 启动..."
  Start-Sleep -Seconds 80
}
$ad = & $Adb devices 2>&1 | Out-String
if ($ad -match "device") { Write-Host "设备已回到 Android：" ; Write-Host $ad }
else { Write-Host "设备仍未上线（可能在内核卡死状态，需要长按电源）" }
