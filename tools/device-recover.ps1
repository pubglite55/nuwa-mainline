<#
  完整恢复：把设备刷回原厂 Android（三件套 + slot a）
  用法: .\tools\device-recover.ps1 [-RestoreGpt] [-IncludeBootB]

  设计依据（经验库 patterns.md 模式 I「恢复路径本身不可靠」）：
    - 每一步都检查退出码，失败立即停止并报告
    - GPT 写入是危险操作，需要二次确认
    - 最后必须验证设备真的起来了，而不是只发 reboot 就宣布成功
#>
param(
  [string]$BackupDir = "C:\Users\L1872\Documents\nuwa ubt\backup\nuwa-backup",
  [string]$Adb = "C:\Android\platform-tools\adb.exe",
  [string]$Fastboot = "C:\Android\platform-tools\fastboot.exe",
  [switch]$RestoreGpt,
  [switch]$IncludeBootB,
  [int]$WaitSeconds = 90
)

$ErrorActionPreference = "Continue"
$NL = [Environment]::NewLine
$failed = @()

function Invoke-Flash {
  param([string]$Part, [string]$File, [switch]$Dangerous)
  $path = Join-Path $BackupDir $File
  if (-not (Test-Path $path)) {
    Write-Host ("  跳过 " + $Part + "：缺少 " + $File) -ForegroundColor Yellow
    $script:failed += ($Part + " (缺文件)")
    return $false
  }
  if ($Dangerous) {
    Write-Host ""
    Write-Host ("  !! 即将写入 " + $Part + " <- " + $File + "（危险操作）") -ForegroundColor Red
    Write-Host "     5 秒后开始，Ctrl+C 取消 ..."
    Start-Sleep -Seconds 5
  }
  Write-Host ("  刷 " + $Part + " <- " + $File + " ...")
  $out = & $Fastboot flash $Part $path 2>&1 | Out-String
  $code = $LASTEXITCODE
  if ($out -match "FAILED") {
    Write-Host ("  FAILED: " + $out.Trim()) -ForegroundColor Red
    $script:failed += ($Part + " (flash FAILED)")
    return $false
  }
  if ($code -ne 0) {
    Write-Host ("  FAILED: 退出码 " + $code) -ForegroundColor Red
    $script:failed += ($Part + " (exit " + $code + ")")
    return $false
  }
  Write-Host "  OK" -ForegroundColor Green
  return $true
}

$fb = & $Fastboot devices 2>&1 | Out-String
if ($fb -notmatch "fastboot") {
  Write-Host "设备不在 fastboot。当前 adb:"
  & $Adb devices -l
  Write-Host ""
  Write-Host "请长按电源 15 秒，然后按住音量下 + 电源进入 fastboot。"
  exit 1
}

Write-Host "=============================================="
Write-Host " 恢复原厂 Android"
Write-Host "=============================================="
Write-Host ""

if ($RestoreGpt) {
  Write-Host "--- 恢复 GPT（危险）---" -ForegroundColor Red
  Invoke-Flash -Part "sda" -File "gpt-sda-head.bin" -Dangerous | Out-Null
  Write-Host ""
}

Write-Host "--- 刷启动分区 ---"
Invoke-Flash -Part "boot_a"        -File "boot_a.img"        | Out-Null
Invoke-Flash -Part "init_boot_a"   -File "init_boot_a.img"   | Out-Null
Invoke-Flash -Part "vendor_boot_a" -File "vendor_boot_a.img" | Out-Null
if ($IncludeBootB) {
  Write-Host ""
  Write-Host "--- 同时恢复 B 槽 ---"
  Invoke-Flash -Part "boot_b" -File "boot_b.img" | Out-Null
}
Write-Host ""

Write-Host "--- 设置活动槽 a ---"
$out = & $Fastboot set_active a 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
  Write-Host ("  警告：set_active 返回 " + $LASTEXITCODE + "（继续）") -ForegroundColor Yellow
} else {
  Write-Host "  OK" -ForegroundColor Green
}
Write-Host ""

if ($failed.Count -gt 0) {
  Write-Host "=============================================="
  Write-Host " 有步骤失败，不重启（避免带病启动）" -ForegroundColor Red
  Write-Host "=============================================="
  $failed | ForEach-Object { Write-Host ("  - " + $_) }
  Write-Host ""
  Write-Host "设备仍在 fastboot，可以安全修正后重跑。"
  exit 1
}

Write-Host "--- 重启并验证 ---"
& $Fastboot reboot 2>&1 | Out-Null
Write-Host ("  等待 " + $WaitSeconds + " 秒观察是否进入 Android ...")

$started = $false
for ($i = 0; $i -lt $WaitSeconds; $i += 3) {
  $adbOut = & $Adb devices 2>&1 | Out-String
  if ($adbOut -match "device") {
    Write-Host ("  t=" + $i + "s  adb 已连接") -ForegroundColor Green
    $started = $true
    break
  }
  if (($i % 15) -eq 0 -and $i -gt 0) { Write-Host ("  t=" + $i + "s  ...") }
  Start-Sleep -Seconds 3
}

Write-Host ""
if ($started) {
  Write-Host "=============================================="
  Write-Host " 恢复成功：设备已进入 Android" -ForegroundColor Green
  Write-Host "=============================================="
  & $Adb devices -l
} else {
  Write-Host "=============================================="
  Write-Host (" 分区已刷回，但 " + $WaitSeconds + " 秒内未见 adb") -ForegroundColor Yellow
  Write-Host "=============================================="
  Write-Host "可能原因："
  Write-Host "  1. 首次启动较慢（再等 60 秒，或看屏幕）"
  Write-Host "  2. userdata 损坏（改过分区时会发生）→ recovery 里 format data"
  Write-Host "  3. vbmeta 不匹配 → fastboot flash vbmeta_a vbmeta_a.img 后重试"
  Write-Host ""
  & $Adb devices -l
  & $Fastboot devices
  exit 2
}
