# 设备回来后：操作手册

> 前提：所有产物已就绪，见 `status.md`。

## 第 0 步：确认设备在线、电量足够、并核对镜像

### 电量必须先查（经验库的"高频+耗时"坑）

> **低电量或电脑 USB 供电不足，伪装成软件故障**
> 现象：黑屏、触控失败、随机复位；同一份代码时好时坏。
> 原因：背光升压和面板偏置直接从电池取电，电量很低时起不来；
> 电脑 USB 口只给约 400–500 mA，桌面负载下净放电；**Linux 和 Fastboot 下通常不能净充电**。
> 解决：离开 Android 前读新鲜电量，**低于 40% 不开始实验**；用墙充。

```powershell
# 设备在 Android 时读
adb -s 3705933 shell cat /sys/class/power_supply/battery/capacity

# 或在 fastboot 里读（部分设备支持）
fastboot getvar battery-voltage
```

**低于 40% 就先充 20 分钟再来。** 否则你会看到"同一份镜像有时能起有时不能起"，
然后花几小时去怀疑内核——实际只是电量不够。

`run-test.ps1` 已内置这个检查（低于 40% 直接退出，verdict=`low_battery`）。

### 镜像核对

刷机前可先核对镜像哈希（见 [artifact-hashes.md](artifact-hashes.md)）：

```powershell
Get-FileHash "other\payload-bootb-efifb.img" -Algorithm SHA256
# 应为 9609bed90c7888aefaa993e9108a319bb76b0387c96a2a6644ebb9ce13d3a498
```


```powershell
& "C:\Android\platform-tools\fastboot.exe" devices
```

- 看到 `3705933  fastboot` → 继续
- 什么都没有 → 长按电源 15 秒，再按住音量下 + 电源进 fastboot
- 看到 `3705933  device`（Android 已启动）→ `adb reboot bootloader`

## 第 1 步：首选路径（4 KiB FAT16 + boot_b）

```powershell
.\tools\flash-uefi.ps1 -BootB
```

它会：刷 `boot_a` = UEFI 固件 → 刷 `boot_b` = 4 KiB FAT16 payload → 重启 → 监控 90 秒 USB 事件。

**同时请看屏幕，告诉我看到什么**（按可能性排序）：

| 屏幕现象 | 含义 | 下一步 |
|---|---|---|
| 出现 UniXNU 菜单，含 "Ubuntu Linux (self-contained)" 或 "EFI loader on volume N" | ✅ 配置/兜底 loader 生效 | 音量键选中 → 电源键确认 |
| 只有 Return to firmware / Restart / Power off | 内置菜单，没读到卷 | 走第 2 步 |
| 屏幕黑但背光亮 | 内核可能起了但显示没接管 | 走第 3 步 |
| 完全无反应/无背光 | UEFI 没跑起来 | 走第 4 步 |

## 第 2 步：如果只有内置菜单（卷没读到）

先验证 FAT 挂载是否成立：

```powershell
.\tools\flash-uefi.ps1 -Mode shell
```

（把 Shell 诊断盘刷到 `vendor_boot_a`）

- **出现 Shell 提示符** → FAT 挂载没问题，问题在配置解析。
  `esp-shell.img` 里带了 `startup.nsh`，Shell 启动后会自动：
  1. `map -r` 列出所有卷
  2. 遍历 `fs0`–`fs7` 找 `\Linux\BOOTAA64.EFI`
  3. 找到就**自动启动内核**
  4. 找不到就列出所有卷的 `\EFI` 目录（诊断用）

  如果自动启动成功，说明**内核和 FAT 都没问题，只是 UniXNU 没读到配置**。
  这时再刷 UEFI DEBUG 版看卷扫描日志：
  ```powershell
  .\tools\flash-uefi.ps1 -Debug
  ```
- **仍无反应** → FAT 没被挂载 → 走 TWRP 改 GPT 类型：
  ```
  adb push other/esp-nuwa.img /tmp/
  adb push public/nuwa/tools/twrp-install-esp.sh /tmp/
  adb shell sh /tmp/twrp-install-esp.sh --set-esp-type
  ```

## 第 2.5 步：分层诊断（黑屏时最有用的手段）

如果首选路径黑屏、但又不确定卡在哪一层，刷**最小诊断镜像**：

```powershell
.\tools\flash-uefi.ps1 -Min
```

它的 init 只做三件事：挂载 proc/sys/dev → 往 kmsg 写一行 `nuwa-min: start <uptime>` → sleep 120 后重启。

| 最小版表现 | 说明 | 下一步 |
|---|---|---|
| 屏幕出现 `nuwa-min: start` | 内核启动成功、initramfs 正常、**问题在完整 init 的某个环节** | 逐个功能排查（USB / applet / telnetd） |
| 屏幕有内核日志但没有 `nuwa-min` | 内核起来了但 initramfs 或 /init 有问题 | 检查 initramfs 打包 |
| 屏幕完全黑但背光亮 | 内核没起来或显示没继承 | 走第 3 步换 nodrm |
| 完全无反应 | UEFI 没加载内核 | 走第 4 步 |

**这个分层能把"不知道卡在哪"变成"卡在某一层"，是最省时间的诊断方式。**

## 第 3 步：黑屏但有背光

换 nodrm 版（已内建 efifb/simpledrm，带 `clk_ignore_unused pd_ignore_unused`）：

```powershell
.\tools\flash-uefi.ps1 -Mode vendor -Nodrm
```

（`esp-nuwa-nodrm.img` 刷到 `vendor_boot_a`）

若 nodrm 版有输出而正常版黑屏 → 确认是 msm 抢占 framebuffer，后续把 msm 做成 `=m` 手动 modprobe 做原生接管。

## 第 4 步：UEFI 完全没起来

1. 确认 `boot_a` 刷的是 `Mu-nuwa.img`（2.13 MB，`ANDROID!` 头）
2. 检查 `vbmeta_a`（应 flags=0x3）：
   ```powershell
   & "C:\Android\platform-tools\fastboot.exe" flash vbmeta_a "backup\nuwa-backup\vbmeta_a.img"
   ```
3. 重刷后再看

## 任何时候恢复 Android

```powershell
.\tools\device-recover.ps1
```

刷回 `boot_a` / `init_boot_a` / `vendor_boot_a`（均在 `backup/nuwa-backup/`）+ `set_active a`。
若改过 GPT 类型：加 `-RestoreGpt`。

若刷过 `boot_b`（payload），B 槽被覆盖，恢复：
```powershell
& "C:\Android\platform-tools\fastboot.exe" flash boot_b "backup\nuwa-backup\boot_b.img"
```

## 成功进 Linux 之后

屏幕应显示：

```
==============================================
  nuwa initramfs  |  mainline kernel + UEFI
==============================================
uptime : ...
cmdline: console=tty0 ...
kernel : 7.0.0-sm8550
-- 加载驱动模块 --
-- USB gadget (NCM) --
   udc: a600000.dwc3
   telnetd 已启动 (192.168.0.1:23)
=== 系统就绪：可 telnet 192.168.0.1 ===
```

然后 PC 侧：

```powershell
.\tools\pc-ncm-connect.ps1
telnet 192.168.0.1
```

进去后按 `首启检查清单`（见 `uefi-route.md`）逐项采集证据。
