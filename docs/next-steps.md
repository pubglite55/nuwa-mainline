# 设备回来后：操作手册

> 前提：所有产物已就绪，见 `status.md`。

## ⚠️ 当前路线（2026-10-30 起）：ABL 直启，写入 `recovery_a`

> 旧 UEFI 流程（下面「第 0 步」之后的内容）保留作回退参考。原理见 [abl-direct-boot.md](abl-direct-boot.md)。
> **硬约束：不动 `vendor_boot_a` / `vendor_boot_b`。**

### A. 先备份 `recovery_a`（只做一次，必须做）

`recovery_a` 不在现有备份集里，而它就是我们要覆盖的分区。
设备在 **Android**（不是 fastboot）时：

```powershell
adb -s 3705933 shell su -c "dd if=/dev/block/by-name/recovery_a of=/sdcard/recovery_a.img bs=1M"
adb -s 3705933 pull /sdcard/recovery_a.img "backup\nuwa-backup\recovery_a.img"
adb -s 3705933 shell su -c "rm /sdcard/recovery_a.img"
Get-FileHash "backup\nuwa-backup\recovery_a.img" -Algorithm SHA256
```

预期大小 **104,857,600 字节**（`0x6400000`）。核对无误再往下走。

### B. 刷入 Linux 镜像（用脚本，别手敲）

```powershell
.\public\nuwa\tools\flash-recovery-linux.ps1 -DryRun   # 先只检查：镜像哈希、设备、电量、备份
.\public\nuwa\tools\flash-recovery-linux.ps1           # 备份(如缺) → 校验 → 刷 recovery_a → reboot recovery
```

脚本把三条教训写成了硬检查，任何一条不过就退出：

1. `recovery_a` 没有备份 → 强制先 dd + pull + 校验大小；
2. 电量 < 40% → 拒绝；
3. 镜像 sha256 与登记值不符 → 拒绝（防止误刷 v1/v2 坏镜像）。

手工等价命令（脚本不可用时）：

```powershell
& "C:\Android\platform-tools\fastboot.exe" devices           # 应看到 3705933  fastboot
& "C:\Android\platform-tools\fastboot.exe" flash recovery_a "other\abl-nuwa-drm-v9.img"
& "C:\Android\platform-tools\fastboot.exe" reboot recovery
```

`abl-nuwa-drm-v9.img` sha256 = `ef0e57013381758c9b73adbcccf5638b33639d72b49a31b8ba686bc6bd0c8e75`。
（v4 之前的版本有 dispcc 模块化 / reset 极性 / 序列延时问题，不要用。）

### C. 判读

| 现象 | 含义 | 下一步 |
|---|---|---|
| 屏幕出现内核日志 + `nuwa-init: 就绪` | 链路全通 | 记下 DRM connector / backlight 状态，进入 Ubuntu 部署 |
| 屏幕亮但全黑无文字 | DPU 起了、fbcon/面板时序没对上 | 连 USB 网 `telnet 192.168.0.1`，看 `dmesg | grep -i msm` |
| 完全黑屏、USB 也不枚举 | 内核或 DSI 早期就死了 | 300 秒后自动回 Android；用 `console=ttyAMA0` 加串口，或回退 |
| 卡在 `Booting OKAY` 不动 | 诱饵 DTB 被 ABL 拒绝 | 换诱饵：从 `dtbo_a` 取真厂商 DTB（TD-11） |

### D. 回退

```powershell
& "C:\Android\platform-tools\fastboot.exe" flash recovery_a "backup\nuwa-backup\recovery_a.img"
```

> ABL 一次失败启动后，同一个 fastboot 会话会拒绝后续镜像 —— 先 `fastboot reboot bootloader`。

---

## （旧 UEFI 路线）第 0 步：确认设备在线、电量足够、并核对镜像

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

---

## 黑屏问题：设备回来后照这个做（2026-10-29 更新）

### 状态

真机现状：UEFI 界面正常、能扫到 `boot_b` 的 FAT 卷、能点进菜单，
但点启动后**黑屏**，且 **USB 完全不枚举**。

已排除：
- 卷没被扫到（能扫到）
- 配置文件没读到（菜单能列出来）
- PE 装载失败（UniXNU 的 `StartImage` 没返回，说明内核确实开始跑了）

未确定：GOP 是 BLT-only 还是线性；内核死在哪一层。

### 第 0 步：前置检查

```powershell
# 电量必须 > 40%（低于此值黑屏/随机复位，见 troubleshooting.md）
fastboot getvar battery-voltage
```

### 第 1 步：刷入（boot_a 固件 + boot_b 内核）

```powershell
# 固件：双显示驱动 + dtb 保留 breadcrumb 内存
fastboot flash boot_a "other\uefi-nuwa-final\Mu-nuwa.img"

# 内核：4 个检查点
fastboot flash boot_b "other\payload-bootb-bc.img"

fastboot reboot
```

**注意**：`vendor_boot_a/b` 全程不碰（用户硬约束）。

### 第 2 步：读 breadcrumb（最关键）

进 UEFI 后**先别点启动**，看菜单上的这几行：

```
UNIXNU: note <a> <b> <c> <d>  (magic 4e4f5445)
last kernel boot reached stage mask 0x...
n1 ... ck ... ld ... sc ... ent ...
```

把 `<a> <b> <c> <d>` 和 `stage mask` 记下来。

**判读**（`<c>` 就是 checkpoint，即 `N[2]`）：

| `note` 的第三个数 | 内核走到哪 | 下一步 |
|---|---|---|
| magic 不是 `4e4f5445` | 没进内核入口 | 查 EFI stub / `StartImage`；见下方"分支 A" |
| `1` | 入口后、保存 boot args 或建页表时挂 | 分支 B |
| `3` | 读到 boot args，建页表时挂 | 分支 B |
| `5` | 页表建好，CPU setup / 开 MMU 时挂 | 分支 C |
| `6` | MMU 开了、`setup_arch` 完成 | 分支 D |

### 分支 A：magic 不对（内核没进入口）

说明 `LoadImage` 之后 `StartImage` 立即失败，或 PE 装载有问题。

```powershell
# 换诊断 payload，看 GOP 和 breadcrumb 地址
fastboot flash boot_b "other\payload-bootb-diag.img"
fastboot reboot
```

点 "GOP + breadcrumb probe"，拍照。重点看：
- `PixelFormat` 是几（3 = BLT-ONLY）
- `BREADCRUMB 0x8d3003000` 那节是否显示 "In memory map"

### 分支 B：ck=1 或 3（早期汇编阶段）

问题在 `head.S` 或页表构造。检查方向：
- `CONFIG_ARM64_VA_BITS_52` / `PA_BITS_52` 是否真的被硬件支持
- `CONFIG_ARM64_4K_PAGES` 与 UEFI 的页大小是否一致
- `__pi_create_init_idmap` 的页表大小是否够

### 分支 C：ck=5（CPU setup / MMU）

问题在 `__cpu_setup` / `__enable_mmu` / TCR/MAIR 配置。

### 分支 D：ck=6（start_kernel 之后）

内核主体起来了，问题在驱动或 init。这时候：
- 屏幕应该有 `earlycon=efifb` 的输出（如果没有，说明 efifb 还是没拿到 framebuffer）
- USB 应该枚举（如果没枚举，查 `dwc3` / `usb_1` 节点）

### 回退（任何一步出问题）

```powershell
.\public\nuwa\tools\device-recover.ps1
```

或者手工：

```
fastboot flash boot_a   backup\nuwa-backup\boot_a.img
fastboot flash boot_b   backup\nuwa-backup\boot_b.img
fastboot flash init_boot_a backup\nuwa-backup\init_boot_a.img
fastboot flash vendor_boot_a backup\nuwa-backup\vendor_boot_a.img
fastboot set_active a
fastboot reboot
```

### 备选镜像

| 场景 | 镜像 |
|---|---|
| 固件回退（DisplayDxe 原版） | `other\uefi-nuwa\Mu-nuwa.img` |
| 只想要线性 GOP | `other\uefi-nuwa-simplefb\Mu-nuwa.img` |
| 双驱动但无 dtb 保留 | `other\uefi-nuwa-dual\Mu-nuwa.img` |
| 诊断 GOP 类型 | `other\payload-bootb-diag.img` |
| 判断是否 framebuffer 导致崩溃 | `other\payload-bootb-noconsole.img` |
| 基线（earlycon + console） | `other\payload-bootb-efifb.img` |
