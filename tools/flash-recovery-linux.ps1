#Requires -Version 5.1
<#
.SYNOPSIS
    把 ABL 直启的 Linux 内核刷进 nuwa 的 recovery_a（含强制备份与校验）。

.DESCRIPTION
    这是 ABL 直启路线的唯一刷写入入口。它把三条血的教训写成代码检查：
      1. recovery_a 不在 backup/nuwa-backup 里，第一次刷之前必须先从设备 dd 出来；
      2. 电量低于 40% 不刷（低电量会伪装成黑屏/随机复位）；
      3. 镜像 sha256 必须和登记值一致（防止刷到旧的 v1/v2 坏镜像）。

.PARAMETER Image
    要刷的 boot.img，默认 other/abl-nuwa-drm-v7.img。

.PARAMETER DryRun
    只做检查不刷写。

.EXAMPLE
    .\flash-recovery-linux.ps1            # 备份(如缺) + 校验 + 刷写 + 进 recovery
    .\flash-recovery-linux.ps1 -DryRun    # 只检查
#>
[CmdletBinding()]
param(
    [string]$Image = (Join-Path $PSScriptRoot '..\..\..\other\abl-nuwa-drm-v7.img'),
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$Serial    = '3705933'
$Fastboot  = 'C:\Android\platform-tools\fastboot.exe'
$Adb       = 'C:\Android\platform-tools\adb.exe'
$RepoRoot  = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$Backup    = Join-Path $RepoRoot 'backup\nuwa-backup\recovery_a.img'
$MinBattery = 40

# 已登记镜像的哈希（见 docs/artifact-hashes.md、docs/status.md）
$KnownImages = @{
    'abl-nuwa-drm-v7.img' = '4b3845d53e4e12307f402ae39e27da3377d7f6f0dc80b8a8f93fdf6c9afb091f'
    'abl-nuwa-drm-v6.img' = 'd7ba3eff2dddd735b8fad8658247486c51e7089f4c2c46093e09c75e0636e0ce'
    'abl-nuwa-drm-v5.img' = '91f2d68f2a34aba6d950cacf5ec2120b4fc4d0dadc24798c28780ebdf5d17445'
}

function Fail($msg) { Write-Host "[X] $msg" -ForegroundColor Red; exit 1 }
function Ok($msg)   { Write-Host "[OK] $msg" -ForegroundColor Green }
function Info($msg) { Write-Host "     $msg" -ForegroundColor Gray }

if (-not (Test-Path $Fastboot)) { Fail "找不到 fastboot: $Fastboot" }

# ---- 1. 镜像与哈希 ----
if (-not (Test-Path $Image)) { Fail "找不到镜像: $Image" }
$img     = (Resolve-Path $Image).Path
$imgName = Split-Path $img -Leaf
$hash    = (Get-FileHash $img -Algorithm SHA256).Hash.ToLower()
$size    = (Get-Item $img).Length
Ok "镜像 $imgName  $size 字节"
Info "sha256 $hash"
if ($KnownImages.ContainsKey($imgName)) {
    if ($hash -ne $KnownImages[$imgName]) {
        Fail "哈希与登记值不符，拒绝刷写（期望 $($KnownImages[$imgName])）"
    }
    Ok '哈希与登记值一致'
} else {
    Write-Host "[!] 该镜像名没有登记哈希，请人工确认后再刷" -ForegroundColor Yellow
}
if ($size -gt 100MB) { Fail '镜像超过 recovery_a 分区大小（100 MiB）' }

# ---- 2. 设备状态 ----
$fbDevices = & $Fastboot devices 2>$null | Out-String
$adbDevices = if (Test-Path $Adb) { & $Adb devices 2>$null | Out-String } else { '' }
$inFastboot = $fbDevices -match $Serial
$inAndroid  = $adbDevices -match "$Serial\s+device"
if (-not ($inFastboot -or $inAndroid)) {
    Fail '设备既不在 fastboot 也不在 Android。检查 USB / 长按电源 15 秒后按住音量下+电源进 fastboot'
}
if ($inAndroid -and -not $inFastboot) { Info '设备在 Android 侧' }
if ($inFastboot) { Info '设备在 fastboot 侧' }

# ---- 3. 电量 ----
$battery = $null
if ($inAndroid) {
    $raw = & $Adb -s $Serial shell cat /sys/class/power_supply/battery/capacity 2>$null
    if ($raw -match '\d+') { $battery = [int]$Matches[0] }
}
if ($null -ne $battery) {
    Ok "电量 $battery%"
    if ($battery -lt $MinBattery) {
        Fail "电量低于 $MinBattery%，先充电。低电量会伪装成黑屏/随机复位"
    }
} else {
    Write-Host '[!] 读不到电量（fastboot 下通常读不到）。若距上次充电超过 1 小时，先回 Android 确认' -ForegroundColor Yellow
}

# ---- 4. 备份 recovery_a（关键：不存在就必须先备份）----
if (Test-Path $Backup) {
    $bsize = (Get-Item $Backup).Length
    Ok "recovery_a 备份已存在  $bsize 字节"
    if ($bsize -ne 104857600) {
        Write-Host "[!] 备份大小不是 0x6400000(104857600)，请人工确认它是否完整" -ForegroundColor Yellow
    }
} else {
    Write-Host '[!] recovery_a 没有备份 —— 这是唯一副本，必须先备份' -ForegroundColor Yellow
    if (-not $inAndroid) {
        Fail '备份必须在 Android 侧做（需要 root dd）。先正常开机进 Android 再跑本脚本'
    }
    if ($DryRun) { Fail 'DryRun 模式下不备份，但备份缺失；请去掉 -DryRun 完成备份' }
    Info '执行 dd（约 100 MiB，需要几十秒）'
    & $Adb -s $Serial shell su -c "dd if=/dev/block/by-name/recovery_a of=/sdcard/recovery_a.img bs=1M"
    if ($LASTEXITCODE -ne 0) { Fail 'dd 失败（设备是否已 root？KernelSU 是否已授权？）' }
    & $Adb -s $Serial pull /sdcard/recovery_a.img $Backup
    if ($LASTEXITCODE -ne 0) { Fail 'adb pull 失败' }
    & $Adb -s $Serial shell su -c "rm -f /sdcard/recovery_a.img" | Out-Null
    $bsize = (Get-Item $Backup).Length
    if ($bsize -ne 104857600) { Fail "备份大小 $bsize 不等于 104857600，不要继续" }
    Ok "备份完成 $Backup"
    Info ("sha256 " + (Get-FileHash $Backup -Algorithm SHA256).Hash.ToLower())
}

if ($DryRun) { Ok 'DryRun：所有检查通过，不刷写'; exit 0 }

# ---- 5. 刷写 ----
if (-not $inFastboot) {
    Info '重启到 fastboot'
    & $Adb -s $Serial reboot bootloader
    Start-Sleep -Seconds 8
    if (-not ((& $Fastboot devices) -match $Serial)) { Fail '进不去 fastboot' }
}
Info 'fastboot flash recovery_a'
& $Fastboot flash recovery_a $img
if ($LASTEXITCODE -ne 0) {
    Write-Host '[X] 刷写失败。留在 fastboot，可用下面的回退命令修：' -ForegroundColor Red
    Write-Host "    $Fastboot flash recovery_a `"$Backup`"" -ForegroundColor Yellow
    exit 1
}
Ok '已写入 recovery_a'

# ---- 6. 进 recovery 引导 Linux ----
Info 'fastboot reboot recovery（内核起来后 300 秒会自动重启回 Android）'
& $Fastboot reboot recovery

Write-Host ''
Write-Host '回退命令（随时可用）：' -ForegroundColor Cyan
Write-Host "    $Fastboot flash recovery_a `"$Backup`"" -ForegroundColor Cyan
Write-Host '若 ABL 拒绝后续镜像：先 fastboot reboot bootloader 再刷。' -ForegroundColor Cyan
Write-Host '屏上没有任何输出时：连 USB 网卡，telnet 192.168.0.1 看 dmesg。' -ForegroundColor Cyan
