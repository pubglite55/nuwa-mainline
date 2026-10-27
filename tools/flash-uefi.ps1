<#
  nuwa 刷写（统一入口）
  用法:
    .\tools\flash-uefi.ps1                 # 默认：UEFI + esp-nuwa.img -> vendor_boot_a
    .\tools\flash-uefi.ps1 -BootB          # UEFI + payload-bootb.img -> boot_b（推荐，4KiB FAT16）
    .\tools\flash-uefi.ps1 -Mode shell     # UEFI + esp-shell.img -> vendor_boot_a（Shell 诊断）
    .\tools\flash-uefi.ps1 -Mode vendor -Nodrm   # UEFI + esp-nuwa-nodrm.img -> vendor_boot_a
    .\tools\flash-uefi.ps1 -Efifb                # 本地 efifb 版 -> vendor_boot_a
    .\tools\flash-uefi.ps1 -BootB -Efifb         # 本地 efifb 版 -> boot_b (4KiB FAT16)
    .\tools\flash-uefi.ps1 -Initrd               # FAT 放进 vendor ramdisk -> vendor_boot_a（不依赖 UFS）
    .\tools\flash-uefi.ps1 -Debug          # 刷 UEFI DEBUG 版到 boot_a
#>
param(
  [switch]$BootB,
  [ValidateSet("vendor","shell")] [string]$Mode = "vendor",
  [switch]$Nodrm,
  [switch]$Efifb,
  [switch]$Initrd,
  [switch]$Debug,
  [int]$WatchSeconds = 90,
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

# 选 UEFI 镜像
$uefi = if ($Debug) { Join-Path $Other "uefi-nuwa-debug\Mu-nuwa.img" } else { Join-Path $Other "uefi-nuwa\Mu-nuwa.img" }

# 选 payload
if ($Initrd) {
  $payload = Join-Path $Other "vendor_boot-initrd-esp.img"; $part = "vendor_boot_a"
} elseif ($BootB -and $Efifb) {
  $payload = Join-Path $Other "payload-bootb-efifb.img"; $part = "boot_b"
} elseif ($BootB) {
  $payload = Join-Path $Other "payload-bootb.img"; $part = "boot_b"
} elseif ($Efifb) {
  $payload = Join-Path $Other "esp-efifb.img"; $part = "vendor_boot_a"
} elseif ($Mode -eq "shell") {
  $payload = Join-Path $Other "esp-shell.img"; $part = "vendor_boot_a"
} elseif ($Nodrm) {
  $payload = Join-Path $Other "esp-nuwa-nodrm.img"; $part = "vendor_boot_a"
} else {
  $payload = Join-Path $Other "esp-nuwa.img"; $part = "vendor_boot_a"
}

foreach ($f in @($uefi, $payload)) {
  if (-not (Test-Path $f)) { Write-Host ("缺少 " + $f); exit 1 }
}
Write-Host ("UEFI  : " + $uefi + "  (" + (Get-Item $uefi).Length + " B)")
Write-Host ("payload: " + $payload + "  (" + (Get-Item $payload).Length + " B) -> " + $part)

Write-Host "刷 boot_a ..."
& $Fastboot flash boot_a $uefi 2>&1 | Select-String "OKAY|FAILED"
Write-Host ("刷 " + $part + " ...")
& $Fastboot flash $part $payload 2>&1 | Select-String "OKAY|FAILED"

Write-Host "重启 ..."
& $Fastboot reboot 2>&1 | Out-Null

# 先静默等待，避免撞上 ABL 拆 USB 窗口（经验库提醒）
Start-Sleep -Seconds 5
Write-Host ("观察 " + $WatchSeconds + " 秒 USB 枚举 ...")
$last = ""
for ($i = 0; $i -lt $WatchSeconds; $i += 2) {
  $usb = Get-PnpDevice -PresentOnly 2>$null | Where-Object { $_.InstanceId -match "VID_18D1|VID_2717" }
  $state = if ($usb) { "present(" + ($usb | Measure-Object).Count + ")" } else { "absent" }
  if ($state -ne $last) { Write-Host ("  t=" + $i + "s  " + $state); $last = $state }
  Start-Sleep -Seconds 2
}
Write-Host ""
Write-Host "请看屏幕：UniXNU 菜单是否出现 'Ubuntu Linux (self-contained)' 或 'EFI loader on volume N'"
