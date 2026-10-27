<#
  nuwa 上机编排：一条命令完成 检查 → 刷机 → 等待 → 采集 → 判定 → (可选)恢复
  用法:
    .\tools\run-test.ps1 -Mode bootb        # 刷 UEFI + boot_b payload
    .\tools\run-test.ps1 -Mode shell        # 刷 Shell 诊断盘到 vendor_boot_a
    .\tools\run-test.ps1 -Mode bootb -RecoverAfter   # 测完自动恢复 Android

  输出：JSON 结果 + 证据路径（符合经验库"测试自动化"要求）
#>
param(
  [ValidateSet("bootb","vendor","shell")] [string]$Mode = "bootb",
  [switch]$RecoverAfter,
  [int]$WaitSeconds = 90,
  [string]$Serial = "3705933",
  [string]$Other = "C:\Users\L1872\Documents\nuwa ubt\other",
  [string]$Backup = "C:\Users\L1872\Documents\nuwa ubt\backup\nuwa-backup",
  [string]$Fastboot = "C:\Android\platform-tools\fastboot.exe",
  [string]$Adb = "C:\Android\platform-tools\adb.exe"
)

$ErrorActionPreference = "Continue"
$result = [ordered]@{
  timestamp = (Get-Date).ToString("o")
  mode = $Mode
  serial_ok = $false
  steps = @()
  usb_events = @()
  verdict = "unknown"
  evidence = @()
}
function AddStep($name, $ok, $detail) {
  $result.steps += [ordered]@{ name = $name; ok = $ok; detail = $detail }
  $mark = if ($ok) { "OK  " } else { "FAIL" }
  Write-Host ("[" + $mark + "] " + $name + " : " + $detail)
}

# 1. 身份检查
$fb = & $Fastboot devices 2>&1 | Out-String
if ($fb -match $Serial) {
  AddStep "device_identity" $true ("fastboot 找到 " + $Serial)
  $result.serial_ok = $true
} else {
  AddStep "device_identity" $false ("未找到 " + $Serial + "，当前: " + ($fb.Trim() -replace "\s+"," "))
  $result.verdict = "no_device"
  $result | ConvertTo-Json -Depth 6 | Out-File "C:\Users\L1872\Documents\nuwa ubt\private\test-result.json" -Encoding utf8
  Write-Host "设备不在 fastboot，退出。"
  exit 1
}

# 2. 选择镜像
$uefi = Join-Path $Other "uefi-nuwa\Mu-nuwa.img"
switch ($Mode) {
  "bootb"  { $payload = Join-Path $Other "payload-bootb.img"; $part = "boot_b" }
  "vendor" { $payload = Join-Path $Other "esp-nuwa.img";      $part = "vendor_boot_a" }
  "shell"  { $payload = Join-Path $Other "esp-shell.img";     $part = "vendor_boot_a" }
}
foreach ($f in @($uefi, $payload)) {
  if (-not (Test-Path $f)) { AddStep "image_present" $false ("缺少 " + $f); exit 1 }
}
AddStep "image_present" $true ("UEFI=" + (Get-Item $uefi).Length + "B, payload=" + (Get-Item $payload).Length + "B")

# 3. 刷写
$t0 = Get-Date
& $Fastboot flash boot_a $uefi 2>&1 | Out-Null
$okUefi = ($LASTEXITCODE -eq 0)
AddStep "flash_boot_a" $okUefi ("boot_a <- Mu-nuwa.img")

& $Fastboot flash $part $payload 2>&1 | Out-Null
$okPayload = ($LASTEXITCODE -eq 0)
AddStep ("flash_" + $part) $okPayload ($part + " <- " + (Split-Path $payload -Leaf))

if (-not ($okUefi -and $okPayload)) {
  $result.verdict = "flash_failed"
  $result | ConvertTo-Json -Depth 6 | Out-File "C:\Users\L1872\Documents\nuwa ubt\private\test-result.json" -Encoding utf8
  exit 1
}

# 4. 重启并采集 USB 事件
& $Fastboot reboot 2>&1 | Out-Null
AddStep "reboot" $true "已发送 reboot"

Write-Host ("观察 " + $WaitSeconds + " 秒 USB 枚举 ...")
$lastState = ""
for ($i = 0; $i -lt $WaitSeconds; $i += 2) {
  $usb = Get-PnpDevice -PresentOnly 2>$null | Where-Object { $_.InstanceId -match "VID_18D1|VID_2717" }
  $state = if ($usb) { "present(" + ($usb | Measure-Object).Count + ")" } else { "absent" }
  if ($state -ne $lastState) {
    $result.usb_events += [ordered]@{ t = $i; state = $state }
    Write-Host ("  t=" + $i + "s  " + $state)
    $lastState = $state
  }
  Start-Sleep -Seconds 2
}

# 5. 判定
$sawPresent = ($result.usb_events | Where-Object { $_.state -like "present*" }).Count -gt 0
$sawAbsentAfter = $false
$firstPresentIdx = -1
for ($k = 0; $k -lt $result.usb_events.Count; $k++) {
  if ($result.usb_events[$k].state -like "present*") { $firstPresentIdx = $k; break }
}
if ($firstPresentIdx -ge 0 -and $firstPresentIdx -lt ($result.usb_events.Count - 1)) { $sawAbsentAfter = $true }

if ($sawPresent) {
  $result.verdict = "usb_enumeration_seen"
} else {
  $result.verdict = "no_usb"
}
AddStep "usb_verdict" $sawPresent ("事件数=" + $result.usb_events.Count + ", 首现=" + $firstPresentIdx)

# 6. 可选恢复
if ($RecoverAfter) {
  Write-Host "恢复 Android ..."
  $recover = Join-Path "C:\Users\L1872\Documents\nuwa ubt\public\nuwa\tools" "device-recover.ps1"
  if (Test-Path $recover) {
    & powershell -NoProfile -File $recover
    AddStep "recover" $true "已调用 device-recover.ps1"
  } else {
    AddStep "recover" $false "缺少 device-recover.ps1"
  }
}

$out = "C:\Users\L1872\Documents\nuwa ubt\private\test-result.json"
$result | ConvertTo-Json -Depth 6 | Out-File $out -Encoding utf8
Write-Host ""
Write-Host ("结论: " + $result.verdict + "  （机器指标，待人眼确认）")
Write-Host ("结果已写入: " + $out)
