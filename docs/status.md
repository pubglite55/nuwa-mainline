# nuwa 主线移植 — 当前状态

更新时间：2026-10-28
**本文件是唯一的进度来源。** 操作步骤见 [next-steps.md](next-steps.md)，技术债见 [tech-debt.md](tech-debt.md)。

## 一句话状态

走 **UEFI 路线**（ABL 直启已放弃）。所有离线产物就绪并逐项验证，
**唯一阻塞是设备不在线**，三个物理问题待真机回答。

## 路线选择依据

| 路线 | 结论 |
|---|---|
| ABL 整段换主线 dtb | ❌ ABL 拒绝，回 fastboot |
| ABL 只换首 FDT（原厂树 + USB 补丁） | ⚠️ ABL 接受，内核卡米标，无输出 |
| ABL 只换首 FDT（社区 dtb） | ⚠️ 同上 |
| ABL `fastboot boot` | ❌ 此设备不可用 |
| **UEFI（BootShim + FD）** | ✅ **已起来**，屏幕有界面，USB 枚举出 `VID_18D1` |

## 启动镜像（other/，9 个）

| 文件 | 大小 | 刷到 | 用途 |
|---|---|---|---|
| **`payload-bootb-efifb.img`** | 192 MiB | `boot_b` | **首选**：4 KiB FAT16 + efifb 内核（QEMU 验证过） |
| `payload-bootb.img` | 192 MiB | `boot_b` | 4 KiB FAT16 + CI nodrm 内核 |
| `payload-bootb-min.img` | 192 MiB | `boot_b` | 最小诊断（只打一行 + 重启） |
| `esp-efifb.img` | 64 MiB | `vendor_boot_a` | 512 B FAT32 + efifb 内核 |
| `esp-nuwa.img` | 64 MiB | `vendor_boot_a` | 512 B FAT32 + 正常版内核 |
| `esp-nuwa-nodrm.img` | 64 MiB | `vendor_boot_a` | 512 B FAT32 + nodrm 内核 |
| `esp-shell.img` | 64 MiB | `vendor_boot_a` | UEFI Shell + 内核 + 自动 startup.nsh |
| `esp-refind.img` | 64 MiB | `vendor_boot_a` | rEFInd + 内核 |
| `vendor_boot-initrd-esp.img` | 67.7 MiB | `vendor_boot_a` | ramdisk 路径（**固件已禁用**，仅留档） |

**UEFI 固件**：`uefi-nuwa/Mu-nuwa.img`（2.03 MiB）/ `uefi-nuwa-debug/Mu-nuwa.img`（2.14 MiB）

哈希清单见 [artifact-hashes.md](artifact-hashes.md)（15 项）。

### 结构验收结果（2026-10-28）

逐个用 mtools 检查，全部通过：

| 镜像 | 扇区 | /EFI/BOOT | /EFI/UniXNU | /Linux | startup.nsh |
|---|---|---|---|---|---|
| payload-bootb-efifb.img | **4096** | ✓ | ✓ | — | — |
| payload-bootb.img | **4096** | ✓ | ✓ | — | — |
| payload-bootb-min.img | **4096** | ✓ | ✓ | — | — |
| esp-efifb.img | 512 | ✓ | ✓ | — | — |
| esp-nuwa.img | 512 | ✓ | ✓ | — | — |
| esp-nuwa-nodrm.img | 512 | ✓ | ✓ | — | — |
| esp-shell.img | 512 | ✓ | — | ✓ | ✓（657 B） |
| esp-refind.img | 512 | ✓ | — | ✓ | — |
| vendor_boot-initrd-esp.img | VNDRBOOT v4 | （ramdisk 内） | | | |

**判读**：4 KiB 组的扇区值全部是 4096（符合 UFS 要求），512 B 组全部是 512，
Shell 盘的 `startup.nsh` 存在，rEFInd 盘的内核在 `/Linux`。

## 内核（4 个变体）

| 变体 | 大小 | 显示机制 | 来源 |
|---|---|---|---|
| `bootefi/BOOTAA64.EFI` | 47.05 MiB | `DRM_MSM=y` | CI 社区 7.0 |
| `bootefi-nodrm/BOOTAA64-NODRM.EFI` | 45.62 MiB | `DRM_SIMPLEDRM` | CI 社区 7.0 |
| `bootefi-efifb/BOOTAA64-EFIFB.EFI` | 42.20 MiB | **`FB_EFI=y` 内建 efifb** | 本地 7.4 + nuwa dts |
| `bootefi-efifb/BOOTAA64-MIN.EFI` | 42.20 MiB | 同上 + init-min | 本地 |

**统一 cmdline**（四个变体一致）：

```
console=tty0 ignore_loglevel loglevel=7 keep_bootcon clk_ignore_unused pd_ignore_unused fbcon=rotate:1
```

**内建清单**（全部 `=y`，零模块依赖）：
USB（DWC3/QCOM/NCM/configfs/role-switch/TYPEC）、网络（NET/INET/PACKET/IP_PNP）、
显示（FB_EFI）、触控（ST_FTS_V521_SPI + INPUT_EVDEV）、按键（POWER_RESET_QCOM_PON +
INPUT_GPIO_KEYS + KEYBOARD_GPIO）、存储（BLK_DEV_SD/UFSHCD/SCSI_UFS_QCOM/EXT4）、
平台（PINCTRL_SM8550/ARM_SMMU/QCOM_LLCC/QCOM_RPMH）。

## init 的实际行为

所有输出走 `/dev/kmsg`（屏幕和 dmesg 双可见），流程：

```
nuwa-init: bound to /dev/kmsg
-- busybox applet 自检 --        （10 项，实测全 OK）
-- 加载驱动模块 --
-- USB gadget (NCM) --
   udc: a600000.dwc3            （若无 UDC 会打印 dwc3 相关 dmesg）
   usb0: inet 192.168.0.1/24    （ip 失败时用 ifconfig 兜底）
   telnetd 已启动
-- 网络接口 --
=== 系统就绪：可 telnet 192.168.0.1 ===
=== 120 秒后自动重启 ===        （reboot -f -n）
```

## 离线验证成果（有硬证据）

| 项 | 证据 |
|---|---|
| 内核 + initramfs + `/init` 端到端 | QEMU 日志：`Run /init as init process` + `nuwa-min: start 9.04` |
| 防回收参数生效 | 日志从 `Disabling unused clocks` 变为 `Not disabling` |
| init 输出可见 | `nuwa-init: bound to /dev/kmsg` + 全部后续输出 |
| 4 KiB FAT16 兼容 | EDK2 源码 `MAX_BLOCK_ALIGNMENT=12`，九项检查全过 |
| FAT 扇区与 BlockIo 解耦 | `DiskCache.c` 用 BlockIo 的块大小 |
| boot_b 会被枚举 | `Partition.c` 无分区类型过滤 |
| `efi`/`linux` entry 等价 | `Boot.c`：都是 LoadImage + StartImage，LoadOptions 为空 |

## 待真机验证（三个问题）

| # | 问题 | 判据 |
|---|---|---|
| 1 | 4 KiB FAT16 的 `boot_b` 能否被挂载 | UniXNU 菜单出现 `EFI loader on volume N` 或配置项 |
| 2 | `console=tty0` 是否真有屏幕输出 | 屏幕出现 `nuwa-init: bound to /dev/kmsg` 等 |
| 3 | `usb0` 能否建立 | `ip -4 addr show usb0` 显示 `192.168.0.1/24`，PC 能 telnet |

**建议顺序**：`-Min`（分层诊断）→ `-BootB -Efifb`（完整）→ 失败则 `-Mode shell` → `-Debug`。

## 工具（18 个）

| 脚本 | 用途 |
|---|---|
| `flash-uefi.ps1` | **统一刷写入口**：`-BootB` / `-Efifb` / `-Min` / `-Mode shell` / `-Nodrm` / `-Debug` / `-Initrd` |
| `device-recover.ps1` | 恢复原厂（每步查退出码、GPT 二次确认、重启后验证 adb） |
| `run-test.ps1` | 上机编排（含电量检查，<40% 拒绝开始） |
| `pc-ncm-connect.ps1` | PC 端配 NCM 并连 telnet |
| `read-bootlog.sh` | TWRP 内读 `WriteBootLog` 启动计数 |
| `read-pstore.sh` | TWRP 内读 pstore |
| `install-rootfs.sh` | 阶段 2：安装 Ubuntu rootfs 到分区 |
| `mk-vendor-boot-ramdisk.py` | 替换 vendor_boot 的 ramdisk |
| `mk-vendor-boot.py` | 替换 vendor_boot 的 FDT |
| `mk-esp.sh` / `mk-initramfs.sh` / `mk-bootimg.sh` / `mk-flash-images.py` | 镜像构建 |
| `twrp-install-esp.sh` / `twrp-set-esp-type.sh` | TWRP 内写 ESP / 改 GPT 类型 |
| `init` / `init-min` / `init-probe` | initramfs 的三种 init |
| `run-probe-experiment.ps1` | 探针实验编排 |

## 阶段 2 准备（已完成的部分）

| 项 | 状态 |
|---|---|
| Ubuntu 26.04 base arm64 rootfs | ✅ 33.5 MiB，6564 文件，解压 0 错误 |
| 缺 systemd 的应对 | ✅ 两条路线（`init=/bin/bash` 或 chroot 补装） |
| apt 源 + arm64 索引 | ✅ `resolute` 三 suite 全 200 |
| 安装脚本 | ✅ `install-rootfs.sh` |
| 备选桌面镜像 | ✅ URL 确认（2.85 GiB，未下载） |

## 备份完整性

`backup/nuwa-backup/`：27 项，含 boot_a/b、init_boot_a/b、vendor_boot_a、vbmeta、dtbo、
persist、modemst1/2、fsg、gpt-sd[a-d]-head/backup，有 `SHA256SUMS`。

## 已知限制（详见 [tech-debt.md](tech-debt.md)）

| 限制 | 原因 |
|---|---|
| 无亮度控制/熄屏/刷新率 | 借用固件画面（TD-01） |
| **无音频** | UEFI 的 PIL 被禁用，ADSP 不上电（TD-07） |
| 无传感器/移动数据/GPU | 同上 |
| 依赖 `clk_ignore_unused` | 防止显示资源被回收（TD-02） |

## 当前阻塞

**设备不在线**（`fastboot devices` 与 `adb devices` 均空）。
离线工作已饱和，剩余三个问题必须真机回答。
