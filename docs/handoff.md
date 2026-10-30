# 交接文档（handoff）— 小米 13 Pro（nuwa）主线 Linux 移植

> **面向接手的 AI 助手。** 上一任在 2026-10-30 完成本轮工作后停工，本文是唯一入口。
> 读完本文 → 再看 [status.md](status.md) → 再看 [abl-direct-boot.md](abl-direct-boot.md) → 然后按 [next-steps.md](next-steps.md) 动手。

## 0. 一句话交接

**路线已从「自制 Mu UEFI」切换到「ABL 直启」**（把 Android boot.img 放进 `recovery_a`，
内核用内建主线 DTB，显示走原生 MSM DSI + 自写面板驱动）。
内核、设备树、面板驱动、DSC/时序参数**全部离线就绪并交叉核对过**，产物 `other/abl-nuwa-drm-v4.img` 已就绪。
**唯一阻塞：设备不在线，还没刷过任何东西。** 接手后第一件事是备份 `recovery_a`，第二件事才是刷入。

## 1. 硬约束（违反即失败，优先级高于任何进度诉求）

| 编号 | 约束 | 说明 |
|---|---|---|
| C1 | **不允许动 `vendor_boot`** | 用户明确要求。不得 flash / format / 修改 `vendor_boot_a`、`vendor_boot_b` |
| C2 | 只写 `recovery_a`（本轮方案）与已有的 `boot_a`/`boot_b` | `recovery_a` 首次覆盖前**必须先备份** |
| C3 | 必须先问才能动：`userdata`、GPT、`persist`/`modemst`/`fsg` 等本机数据分区 | 不可逆 |
| C4 | 电量低于 40% 不做实验 | 低电量会伪装成黑屏/随机复位 |
| C5 | 刷写失败不重启，留在 fastboot 修正 | 重启可能进不了 fastboot |
| C6 | 一次只改一个变量；同一失败出现两次就停下找最早出错的层 | 见 `AGENTS.md` |
| C7 | 密钥只在命令行内联，**绝不写入文件或 `.git/config`** | PAT / API key 见 §11 |

## 2. 项目目标（用户明确表态过）

- 在 Xiaomi 13 Pro（`nuwa` / 2210132C / SM8550 kalama）上跑**主线 Linux**，发行版 = **Ubuntu 26.04 + GNOME**。
- **保留 HyperOS 双系统**，可来回切换。
- 首版范围：**启动 + 显示 + 触控 + USB 网络 + Wi-Fi/蓝牙 + 音频**。
- 恢复源：`NikoHyper_NUWA_OS4.0.24.0.XEOCNXM` 线刷包；本机校准分区已单独备份。

## 3. 设备与环境（照抄即可）

| 项 | 值 |
|---|---|
| 设备 | Xiaomi 13 Pro，`nuwa`，SM8550 |
| serial | `3705933` |
| bootloader | 已解锁（`verifiedbootstate=orange`） |
| 当前活动槽 | `_a` |
| root | KernelSU（`u:r:ksu:s0`） |
| 原系统 | HyperOS `OS4.0.24.0.XEOCNXM` / Android 17 |
| fastboot/adb | `C:\Android\platform-tools\` |
| 面板 | `samsung,amb673cp01-m2`，1440×3200 120Hz LTPO，DSI 4 lane |
| 触控 | FocalTech FTS（SPI4，compatible 写的是 `st,fts`） |
| 存储 | UFS，**逻辑块 4096 字节** |

### 工作区在哪（很容易搞错，先确认）

| 内容 | 路径 |
|---|---|
| Windows 项目目录（git 仓库） | `C:\Users\L1872\Documents\nuwa ubt\` |
| 项目文档 | `public\nuwa\docs\` |
| **内核源码树** | **WSL 内 `/home/l1872/nuwa/linux`**（内核 7.3.0，git @ `734bef548`）|
| initramfs 源目录 | WSL 内 `/home/l1872/nuwa/ir-root` |
| 临时脚本（不进 git） | `private\`，以及 WSL 里 `/mnt/c/Users/L1872/Documents/nuwa ubt/private/` |
| 大产物（不进 git） | `other\` |
| 官方备份（不进 git） | `backup\nuwa-backup\`（27 项，带 SHA256SUMS） |

> ⚠️ 内核树**不在** Windows 项目目录里，别在 `public\nuwa\linux` 下找（那是旧副本/不存在）。
> 跨系统访问用 WSL 路径 `/mnt/c/Users/L1872/Documents/nuwa ubt/...`。

### 工具链注意（踩过坑）

- WSL 里 `mkbootimg`、`unpack_bootimg` 可用；**没有 `avbtool`**。
- 交叉编译：`ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-`（必须设，否则报 `-mlittle-endian`）。
- **给 WSL 传命令必须写成 `.sh` 文件再执行**：`wsl.exe -d Ubuntu-26.04 bash "/mnt/c/.../x.sh"`。
  直接把多行命令 / 含 `$F` 的内容塞进 `wsl.exe bash -lc "..."` 会被 PowerShell 与 bash 双层转义搞坏。
  同理，heredoc 在这条链路上不可用。
- Python 脚本同样：写成 `.py` 再 `wsl.exe bash -c "python3 /mnt/c/.../x.py"`。

## 4. 当前进度快照

| 功能 | 状态 | 依据 |
|---|---|---|
| ABL 直启链路（离线） | **离线通过** | 镜像已组装并 `unpack_bootimg` 回读校验：header v1、page 4096、kernel_size = Image.gz + 930579 |
| 内建 DTB（`CONFIG_NUWA_FORCE_BUILTIN_DTB`） | **离线通过** | `nm vmlinux` 有 `nuwa_dtb` / `nuwa_dtb_end`；Image 里能搜到面板 compatible 与 cmdline |
| 面板驱动 `panel-nuwa-m2` | **离线通过** | 编译进内核（`CONFIG_DRM_PANEL_NUWA_M2=y`），DSC/时序/lane 速率与厂商逐项对齐 |
| 触控 FTS 驱动 | **离线通过** | `CONFIG_TOUCHSCREEN_ST_FTS_V521_SPI=y` 编过（靠新增的 notifier 空桩，见 TD-09） |
| 显示 | **待真机** | 从未刷入 |
| USB 网络 / Wi-Fi / BT / 音频 | **待真机 / 待做** | 见 §9 |
| HyperOS 双系统 | **真机通过（原状）** | 未动 `boot_a` |

## 5. 为什么换路线（别回退到 UEFI，除非有明确理由）

同 SoC 的 fuxi（小米 13）移植已在真机跑通桌面，**它没用 Mu UEFI**。
回头看 Mu UEFI 路线的死结，全都只在 UEFI 里存在：

| 死结 | 现象 |
|---|---|
| GOP 只有 BLT、stride=0 | `efifb` 在 `!lfb_linelength` 处放弃 → 黑屏 |
| simple-framebuffer 只能继承一次 | 内核接管后资源被回收 → 2–3 秒后黑屏 |
| UFS 走 UEFI BlockIo + 4 KiB 逻辑块 | FAT 卷兼容/枚举问题 |
| PIL 被注释掉 | ADSP/GPU/相机不上电（音频因此被判死） |

ABL 直启把这些全绕过：内核自己驱动硬件，Android 固件链（`abl`/`tz`/`hyp`/`aop`/`modem`…）原封不动。
**且 fuxi 的实机结果推翻了「音频因 PIL 禁用不可达」的旧结论**（它双 CS35L41 是响的）—— nuwa 音频要重新评估，见 §9。

## 6. 本轮内核改动（都在 WSL 的 `~/nuwa/linux`，逐文件）

| 文件 | 改动 | 状态 |
|---|---|---|
| `arch/arm64/Kconfig` | 新增 `config NUWA_FORCE_BUILTIN_DTB` | 已编过 |
| `arch/arm64/include/asm/setup.h` | `extern const unsigned char nuwa_dtb[]` | 已编过 |
| `arch/arm64/kernel/setup.c` | `early_ioremap_init()` 后插 `__fdt_pointer = __pa_symbol((unsigned long)nuwa_dtb);` | 已编过 |
| `arch/arm64/kernel/nuwa_dtb.S` | 新增，`.incbin NUWA_DTB_FILE` | 已编过 |
| `arch/arm64/kernel/Makefile` | `obj-$(CONFIG_NUWA_FORCE_BUILTIN_DTB) += nuwa_dtb.o` + `NUWA_DTB ?= sm8550-xiaomi-nuwa` + `-DNUWA_DTB_FILE` + .dtb 依赖 | 已编过 |
| `include/drm/drm_mipi_dsi.h` | `struct mipi_dsi_device` 加 `unsigned long hs_rate` | 已编过 |
| `drivers/gpu/drm/msm/dsi/dsi_host.c` | `dsi_calc_pclk()` 用 `hs_rate` 覆盖 byte clock；`dsi_host_attach()` 拷贝 `hs_rate`；带一行 `pr_info` 打印 lane/byte clock | 已编过 |
| `drivers/gpu/drm/panel/panel-nuwa-m2.c` | **整份重写**（fuxi 模式：prepare/unprepare + DSC + 背光，无 enable/disable 之外的杂项） | 已编过 |
| `drivers/gpu/drm/panel/panel-amb673cp01-sequences.h` | 43 KB，厂商初始化序列（`seq_60hz_0` 在用，其余 5 个未用 → 6 条 `-Wunused-const-variable` 警告，无害） | — |
| `drivers/gpu/drm/panel/Kconfig` / `Makefile` | 面板驱动条目（`DRM_PANEL_NUWA_M2`） | 已编过 |
| `include/linux/soc/qcom/panel_event_notifier.h` | **新增**，高通下游 API 的空桩（TD-09） | 已编过 |
| `arch/arm64/boot/dts/qcom/sm8550-xiaomi-nuwa.dts` | 删 simple-framebuffer 与 `nuwa_fb_mem`；写正式 `bootargs` + `stdout-path`；修 reset 极性；panel/DSI 节点启用 | 已编过 |
| `arch/arm64/boot/dts/qcom/Makefile` | `dtb-$(CONFIG_ARCH_QCOM) += sm8550-xiaomi-nuwa.dtb` | — |

### 内核树当前工作状态（接手必看）

`~/nuwa/linux` 有 **30 项未提交改动**（含未跟踪文件）：

- 本轮的：`nuwa_dtb.S`、`nuwa_dtb` 相关四处、`dsi_host.c`（hs_rate）、`panel-nuwa-m2.c`、
  `panel-amb673cp01-sequences.h`、`sm8550-xiaomi-nuwa.dts`、`fts_spi/`、`panel_event_notifier.h`。
- **旧 UEFI 路线的遗留**：`arch/arm64/kernel/head.S`、`init/main.c`、`drivers/firmware/efi/libstub/gop.c`。
  这几处是当时为了定位「黑屏 + breadcrumb 写坏地址」做的实验性改动（breadcrumb 已删），
  **ABL 路线不需要它们**，但目前**没有回退**。要做干净的内核改动集，先 `git diff` 逐个确认再决定去留。
- 备份残留（可删）：`sm8550-xiaomi-nuwa.dts.orig-bc` / `.orig-usb` / `.uefi-bak`、
  `head.S.orig-bc` / `head.S.withbc`、`panel-nuwa-m2.c.skeleton-bak`。

建议：在真机点亮成功后，用 `git diff > ../nuwa-kernel-changes.patch` 归档一份，再决定哪些进上游补丁集。
### `.config` 关键项（现状）

```
CONFIG_NUWA_FORCE_BUILTIN_DTB=y
CONFIG_CMDLINE_FORCE=y
CONFIG_CMDLINE="console=tty0 console=ttyAMA0,115200 earlycon loglevel=7 ignore_loglevel clk_ignore_unused pd_ignore_unused iommu.passthrough=1"
CONFIG_DRM=y  CONFIG_DRM_MSM=y  CONFIG_DRM_MSM_DPU=y  CONFIG_DRM_MSM_DSI=y
CONFIG_DRM_MSM_DSI_7NM_PHY=y  CONFIG_DRM_MSM_MDSS=y  CONFIG_QCOM_LLCC=y
CONFIG_DRM_PANEL_NUWA_M2=y  CONFIG_BACKLIGHT_CLASS_DEVICE=y
CONFIG_DRM_FBDEV_EMULATION=y  CONFIG_FRAMEBUFFER_CONSOLE=y
CONFIG_TOUCHSCREEN_ST_FTS_V521_SPI=y
CONFIG_USB_DWC3=y  CONFIG_USB_DWC3_DUAL_ROLE=y  CONFIG_USB_CONFIGFS=y  CONFIG_USB_CONFIGFS_NCM=y
# CONFIG_QCOM_OCMEM is not set      ← 它若为 m，会把 DRM_MSM 从 y 拉回 m
CONFIG_INITRAMFS_SOURCE="/home/l1872/nuwa/ir-root"
```

## 7. 构建与打包（复制粘贴即可）

### 编译

```bash
cd ~/nuwa/linux
rm -f usr/initramfs_data.cpio usr/initramfs_data.cpio.gz     # initramfs 改动不会自动触发重打包
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
     NUWA_DTB=sm8550-xiaomi-nuwa Image.gz -j$(nproc)
```

产物：`arch/arm64/boot/Image`（约 46 MB）、`arch/arm64/boot/Image.gz`（约 16.9 MB）。

### 打包成 ABL 可引导镜像

```bash
BAIT="/mnt/c/Users/L1872/Documents/nuwa ubt/private/nuwa-bait.dtb"
CMDLINE='console=tty0 console=ttyAMA0,115200 earlycon loglevel=7 ignore_loglevel clk_ignore_unused pd_ignore_unused iommu.passthrough=1'
cat arch/arm64/boot/Image.gz "$BAIT" > /tmp/kernel-dtb      # kernel 字段 = Image.gz + 诱饵 DTB
: > /tmp/ramdisk                                             # ramdisk 空，initramfs 编进内核
mkbootimg --header_version 1 --os_version 13.0.0 --os_patch_level 2022-11 \
  --kernel /tmp/kernel-dtb --ramdisk /tmp/ramdisk \
  --base 0x0 --kernel_offset 0x00000000 --ramdisk_offset 0x01000000 --tags_offset 0x00000100 \
  --pagesize 4096 --cmdline "$CMDLINE" -o /tmp/abl-nuwa.img
unpack_bootimg --boot_img /tmp/abl-nuwa.img --out /tmp/ub   # 回读校验 header v1 / pagesize 4096
```

### 诱饵 DTB 是什么、在哪

- 文件：`private\nuwa-bait.dtb`（930,579 字节）。
- 来源：`other\uefi-nuwa-v7\Mu-nuwa.img` 偏移 **1,179,568** 处的 FDT（`totalsize = 930,579`）。
- 内容确认：`model = "Qualcomm Technologies, Inc. 8550 nuwa"`、`qcom,msm-id = <0x207 0x20000>`、`qcom,board-id = <0x10008 0x0>`。
- 为什么需要：ABL 自己按 id 选 DTB 并叠 `dtbo` overlay，**叠到主线 DTB 上会「Booting OKAY 后卡死」**（fuxi 实测）。
- 失效时的替代：从 `recovery_a` 原镜像或 `dtbo_a` 里取真厂商 DTB。

## 8. 产物与哈希

| 文件 | 大小 | sha256 |
|---|---|---|
| **`other/abl-nuwa-drm-v6.img`** | **17,858,560** | **`d7ba3eff2dddd735b8fad8658247486c51e7089f4c2c46093e09c75e0636e0ce`（当前，刷这个）** |
| `other/abl-nuwa-drm-v5.img` | 17,854,464 | `91f2d68f…`（dispcc 已内建，缺面板 off 序列） |
| `other/abl-nuwa-drm-v4.img` | 17,854,464 | `c97ff6f7…`（**dispcc 还是模块，会静默黑屏**） |
| `other/abl-nuwa-drm-v3.img` 及更早 | 17,854,464 | 早期版本（reset 极性 / 序列延时未修），**不要用** |
| `other/uefi-nuwa-v7/Mu-nuwa.img` | 2,113,536 | Mu UEFI 回退用（`boot_a`）+ 诱饵 DTB 的来源 |

版本演进：v1/v2 reset 极性写反 + 序列延时被跳过；v4 换成原生 DRM 版 initramfs；
**v5 修掉最致命的一条 —— `CONFIG_SM_DISPCC_8550=m`（显示时钟控制器是模块，initramfs 环境里不会加载，
`mdss` 只会 probe defer 到黑屏）**；v6 补上厂商关机序列（`0x28`+20 ms、`0x10`+100 ms）。

## 9. 待办（按顺序，别跳步）

### P0 真机点亮显示（设备上线后第一件事）

1. **备份 `recovery_a`**（它会覆盖，且不在现有备份集里）：
   ```powershell
   adb -s 3705933 shell su -c "dd if=/dev/block/by-name/recovery_a of=/sdcard/recovery_a.img bs=1M"
   adb -s 3705933 pull /sdcard/recovery_a.img "backup\nuwa-backup\recovery_a.img"
   ```
   预期 **104,857,600 字节**（`0x6400000`），核对后再动。
2. 查电量（<40% 先充），`fastboot devices` 确认在线。
3. `fastboot flash recovery_a other\abl-nuwa-drm-v4.img` → `fastboot reboot recovery`。
4. 判读见 §10 表格。成功标志：屏幕出现内核日志 + `nuwa-init: 就绪`。

### P1 显示稳定后

5. 触控：`st,fts` 节点已在 DTS；确认 SPI 探测、固件下载、`/dev/input/event*` 有事件。
6. 背光：`/sys/class/backlight/*` 已由面板驱动注册，确认亮度可调、熄屏可关。
7. USB 网络：initramfs 已建 NCM gadget（`192.168.0.1/24`）+ `telnetd`，确认 `usb0` 起来。

### P2 首版范围剩余

8. Wi-Fi / BT：WCN6856 → `ath11k`（PCIe）+ `hci_qca`（UART）。固件要从原厂 `/vendor/firmware` 或 `/odm/firmware` 取。
   **注意 fuxi 用的是 WCN7850/ath12k，与 nuwa 不同**，别照抄。
9. 音频：ADSP + 双 CS35L41（I2C `0x40`/`0x42`）+ WCD938x。
   **fuxi 的实机结果证明「PIL 禁用 ⇒ 音频不可达」是错的**（那是 UEFI 的限制，ABL 路线没有）。
   参考 `tech-debt.md` TD-07 需要重写结论。
10. 根文件系统：fuxi 用独立 `linux` 分区（sda33）。nuwa 需要自己决定落在哪个分区（**动分区表要先问用户**）。
11. Ubuntu 26.04 + GNOME 用户空间、双系统切换入口。

## 10. 故障判读表

| 现象 | 含义 | 行动 |
|---|---|---|
| 屏幕出现内核日志，300 秒后自动重启回 Android | 链路通了 | 正常，去修 rootfs |
| 屏幕亮但全黑无文字 | DPU 起了，面板时序/DSC 没对上 | `telnet 192.168.0.1`，看 `dmesg \| grep -i msm`，重点看 `dsi_calc_pclk` 打印的 lane/byte clock |
| 完全黑屏且 USB 不枚举 | 内核或 DSI 早期就死 | 加 `console=ttyAMA0,115200` 走串口；或回退 |
| 卡在 `Booting OKAY` 黑屏不动 | 诱饵 DTB 被 ABL 拒绝 | 换诱饵（从 `dtbo_a` 取真厂商 DTB） |
| 刷完直接进 Android | recovery 引导没被触发 | 用「音量上 + 电源」Cold boot，或 `adb reboot recovery` |
| 刷完 ABL 拒绝后续镜像 | ABL 一次失败启动后的已知行为 | `fastboot reboot bootloader` 再刷 |
| 画面有彩色噪点/色带 | DSC 速率模型偏差 | 见 TD-10，给 `dsi_populate_dsc_params()` 加厂商表 |

**回退**：`fastboot flash recovery_a "backup\nuwa-backup\recovery_a.img"`。
最坏情况：`public\nuwa\tools\device-recover.ps1`（三件套 + slot a；加 `-IncludeBootB` 连 B 槽）。

## 11. 敏感信息（**不要写进任何文件**）

- GitHub PAT 与搜索 API key 由用户按需提供，只在命令行内联使用。
- 设备备份（`backup\`）含本机校准/序列号数据，**不进公开仓**。
- `private\`、`other\` 均不进 git（见 `.gitignore`）。

## 12. 提交规范（项目 `AGENTS.md` 有完整版）

```
git -c user.name=nuwa -c user.email=nuwa@localhost commit -m "<范围>: <做了什么>"
```
- 中文提交信息；不配置全局 git 身份。
- **加临时做法必须同时登记技术债**（`docs/tech-debt.md`）在同一个提交里。

## 13. 技术债现状（详见 [tech-debt.md](tech-debt.md)）

| 编号 | 标题 | 影响 |
|---|---|---|
| TD-11 | 诱饵 DTB + 内建 DTB | 决定能否启动；掩盖 DTB 传递语义 |
| TD-10 | DSC 速率参数与厂商 PPS 有细微差异 | 可能局部噪点/色带 |
| TD-08 | `CMDLINE_FORCE` 放弃 ABL 参数 | 丢失 ABL 调优参数 |
| TD-02 | `clk_ignore_unused pd_ignore_unused` | 掩盖资源回收问题 |
| TD-09 | 触控 panel 事件是空桩 | 熄屏功耗偏高 |
| TD-05 | 4 KiB FAT | 只影响 UEFI 路线 |
| TD-06/07 | reboot 同步 / 无线音频 | 见原表（TD-07 结论需修正） |
| TD-01 | ~~借用固件画面~~ | **已还**（切到原生 MSM 显示） |

## 14. 文档地图

| 文档 | 用途 |
|---|---|
| `status.md` | 唯一的进度来源，含 2026-10-30 参数核对表 |
| **`abl-direct-boot.md`** | **当前路线的完整原理 / 分区账 / 打包命令 / 坑** |
| `next-steps.md` | 设备在线后的操作手册（顶部是 ABL 流程） |
| `tech-debt.md` | 技术债，用临时做法必查 |
| `troubleshooting.md` | 决策树 |
| `panel-params.md` / `peripherals.md` | 面板与外设对照 |
| `uefi-route.md` / `uefi-build.md` | 旧 UEFI 路线（已冻结，回退参考） |
| `artifact-hashes.md` | 产物哈希 |
| `install-plan.md` | 三阶段规划 |

## 15. 接手第一小时清单

1. 读本文 + `status.md` 的 2026-10-30 章节。
2. `wsl.exe -d Ubuntu-26.04 bash -c "cd ~/nuwa/linux && git log --oneline -5 && git status --short | head"` —— 看内核树有没有未提交改动。
3. `ls other/abl-nuwa-drm-v4.img` 并核对 §8 的 sha256。
4. `fastboot devices` 看设备在不在（大概率不在——本轮结束时设备离机）。
5. 设备在线后：**先备份 `recovery_a`**，再刷。

## 16. 不要做的事

- ❌ 不要动 `vendor_boot`（C1）。
- ❌ 不要在没备份 `recovery_a` 的情况下刷它。
- ❌ 不要用 v1/v2 镜像（有已知 bug）。
- ❌ 不要把 `console=ttyGS0` 写进 cmdline（/dev/console 变 USB 串口，主机不读会写满阻塞）。
- ❌ 不要直接改 `drivers/gpu/drm/panel/panel-nuwa-m2.c` 里的 DSC 数值后又指望它生效 ——
  `msm` 的 `dsi_populate_dsc_params()` 会**无条件覆盖** RC 相关字段。
- ❌ 不要为 `DRM_MSM` 配 `CONFIG_QCOM_OCMEM=m`（会把 `DRM_MSM` 拉回 `m`）。
- ❌ 不要让显示链路的任何依赖停在 `=m`：`SM_DISPCC_8550`、`ARM_SMMU`、`INTERCONNECT_QCOM_SM8550`、
  `QCOM_RPMHPD`、`DRM_MSM_*`、`DRM_PANEL_NUWA_M2` 必须全 `=y`。initramfs 里没有模块，缺一个就静默黑屏。
  自查：`nm vmlinux | grep dispcc_sm8550` 应看到 `__initcall__kmod_dispcc_sm8550…`（带 `kmod_` 前缀是内建符号命名，不是模块）。
- ❌ 不要以为内核树在 `C:\Users\L1872\Documents\nuwa ubt\public\nuwa\linux`（不在那儿）。

---

交接完成。上一任已停工，本轮未做任何真机写入。
