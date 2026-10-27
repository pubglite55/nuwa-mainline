<#
  完整恢复：把设备刷回原厂 Android（三件套 + slot a）
  用法: .\tools\device-recover.ps1
  前提: 设备在 fastboot（长按电源 15 秒 → 音量下 + 电源）

  备份来源（全部在 backup/nuwa-backup/）：
    boot_a.img / init_boot_a.img / vendor_boot_a.img
    gpt-sda-head.bin / gpt-sda-backup.bin（若改过分区表）
#>
param(
  [string]$BackupDir = "C:\Users\L1872\Documents\nuwa ubt\backup\nuwa-backup",
  [string]$Adb = "C:\Android\platform-tools\adb.exe",
  [string]$Fastboot = "C:\Android\platform-tools\fastboot.exe",
  [switch]$RestoreGpt
)

$fb = & $Fastboot devices 2>&1 | Out-String
if ($fb -notmatch "fastboot") {
  Write-Host "设备不在 fastboot。当前 adb:"
  & $Adb devices -l
  Write-Host ""
  Write-Host "请长按电源 15 秒，然后按住音量下 + 电源进入 fastboot。"
  exit 1
}

Write-Host "=== 恢复原厂 Android ==="

if ($RestoreGpt) {
  Write-Host "恢复 GPT 主表 -> sda ..."
  & $Fastboot flash sda (Join-Path $BackupDir "gpt-sda-head.bin") 2>&1 | Select-String "OKAY|FAILED"
}

foreach ($item in @(
  @{ Part = "boot_a";        File = "boot_a.img" },
  @{ Part = "init_boot_a";   File = "init_boot_a.img" },
  @{ Part = "vendor_boot_a"; File = "vendor_boot_a.img" }
)) {
  $path = Join-Path $BackupDir $item.File
  if (-not (Test-Path $path)) { Write-Host "缺少 $path"; continue }
  Write-Host ("刷 " + $item.Part + " ...")
  & $Fastboot flash $item.Part $path 2>&1 | Select-String "OKAY|FAILED"
}

Write-Host "设置活动槽 a ..."
& $Fastboot set_active a 2>&1 | Out-String | Write-Host

Write-Host "重启 ..."
& $Fastboot reboot 2>&1 | Out-Null

Start-Sleep -Seconds 45
Write-Host "=== 45 秒后设备状态 ==="
& $Adb devices -l
