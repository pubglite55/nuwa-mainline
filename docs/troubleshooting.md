# nuwa UEFI 路线 — 故障排查决策树

> 每一步都给出「现象 → 判据 → 行动」，避免盲猜。

## 0. 刷写前检查

```powershell
& "C:\Android\platform-tools\fastboot.exe" devices    # 必须看到 3705933 fastboot
```

设备不在 fastboot → 长按电源 15 秒，再按住音量下 + 电源。

## 1. 刷完 UEFI 后，屏幕无任何反应（黑屏无背光）

| 判据 | 含义 | 行动 |
|---|---|---|
| 主机也看不到 `VID_18D1` | UEFI 没跑起来 | 确认 `boot_a` 刷的是 `Mu-nuwa.img`（2.13 MB，`ANDROID!` 头）；重刷 |
| 主机能看到 `VID_18D1` | UEFI 在跑，只是屏幕没亮 | 用 `esp-shell.img` 测链路；查 `DisplayDxe` 是否匹配面板 |

## 2. UEFI 界面出现，但没有我们的启动项

屏幕只有 `Return to firmware` / `Restart` / `Power off`（**内置菜单**）→ 说明**没读到 unixnu.toml，也没扫到 BOOTAA64.EFI**。

按顺序尝试：

### 2a. 先验证 FAT 挂载是否成立

刷 `esp-shell.img`（内含 UEFI Shell 作为 `\EFI\BOOT\BOOTAA64.EFI`）：

- **出现 Shell 提示符** → FAT 挂载没问题，问题在菜单/配置 → 进 2b
- **仍无反应** → FAT 没被挂载 → 进 2c

进 Shell 后手动确认：
```
Shell> map -r
Shell> fs0:
Shell> ls
```
能列出 `\EFI\BOOT\BOOTAA64.EFI` 就说明卷可读。

### 2b. FAT 正常但菜单不显示

- 检查 ESP 里 `\EFI\UniXNU\unixnu.toml` 是否存在、路径是否 `\\EFI\\BOOT\\BOOTAA64.EFI`
- 刷 **UEFI DEBUG 版**，屏幕上会打印 `config: loaded ...` 或扫描到的卷标签（`NUNIXNU`）
- 若 DEBUG 版显示扫到了 `NUNIXNU` 却仍无项 → 配置语法问题（用 `unixnu.com/zh/reference/boot-configuration` 对照）

### 2c. FAT 没被挂载

- TWRP 里跑 `tools/twrp-set-esp-type.sh`：把 `vendor_boot_a` 的 GPT 类型改成 **EFI System Partition**（脚本会自动打印恢复命令）
- 或换分区：把 ESP 刷到 `boot_b`（201 MB，当前槽位未使用）
- 极端情况：刷 UEFI DEBUG 版，看 UFSDxe 是否报错

## 3. 有启动项，选中后黑屏

- 换 `esp-nuwa-nodrm.img`（禁用 `DRM_MSM`，用 `simpledrm` 直接继承 UEFI framebuffer）
- nodrm 版有输出 → 说明是 msm 驱动抢占了 framebuffer，后续再修 msm/panel
- nodrm 版也黑屏 → 内核在极早期挂了（内存/GIC/时钟），需要 UART

## 4. 内核日志出现，但停在某处

屏幕会显示（自包含内核 + `console=tty0`）：

```
==============================================
  nuwa initramfs  |  mainline kernel + UEFI
==============================================
```

| 停在 | 含义 | 行动 |
|---|---|---|
| 内核启动日志之前 | EFI stub 失败（dtb 缺失/不兼容） | 检查 UEFI 的 FdtBlob 是否正常；换 nodrm 版 |
| 到 `-- 加载驱动模块 --` 卡住 | 某模块 insmod 挂死 | 从 init 里逐个注释模块定位 |
| 到 `-- USB gadget --` 显示 `udc: <none>` | DWC3 未绑定 | 检查 dtb 里 `usb_1`/`dwc3` 节点；确认 PHY 驱动 |
| 显示 `telnetd 已启动` | ✅ 成功 | 主机跑 `tools/pc-ncm-connect.ps1` |

## 5. 内核起来了，主机没看到 NCM 网卡

```powershell
Get-NetAdapter | Where-Object { $_.InterfaceDescription -match "NCM|RNDIS" }
```

- 完全没有 → 设备侧 `usb0` 没建（看屏幕 `udc:` 与 `usb0:` 行）
- 有但状态 Down → 手动 `Enable-NetAdapter`
- Windows 缺驱动 → 设备管理器里看是否有未知设备；CDC-NCM 在 Win10+ 自带

## 6. 恢复 Android（任何阶段）

```powershell
.\tools\device-recover.ps1
```

刷回 `boot_a` / `init_boot_a` / `vendor_boot_a`（均已在 `backup/nuwa-backup/`，含 vendor_boot 100 MB 原厂镜像）+ `set_active a`。

若改过 GPT 类型：`.\tools\device-recover.ps1 -RestoreGpt`（用 `gpt-sda-head.bin`）。


## 7. Shell 内手动启动（绕过 UniXNU 菜单）

`esp-shell.img` 里同时放了 Shell 和内核，所以即使菜单不认，也能手动启动：

```
Shell> map -r                          # 列出所有卷
Shell> fs0:                            # 切到含 EFI 的卷（逐个试 fs1: fs2: ...）
Shell> ls                              # 应看到 EFI\  Linux\  README.TXT
Shell> \Linux\BOOTAA64.EFI            # 直接启动 Linux 内核
```

内核会接管屏幕，输出 `nuwa initramfs` 日志。

**注意**：Shell 里启动的内核同样没有 LoadOptions，靠内置 `CONFIG_CMDLINE`（`console=tty0 ignore_loglevel loglevel=7`）。

## 8. 三层启动路径（按可靠性排序）

| 路径 | 机制 | 依赖 |
|---|---|---|
| 1. UniXNU 配置 | 读 `\EFI\UniXNU\unixnu.toml` | 卷可读 + 配置正确 |
| 2. UniXNU 兜底 | `AddFallbackLoaders` 扫 `\EFI\BOOT\BOOTAA64.EFI` | 卷可读 |
| 3. Shell 手动 | Shell 里执行 `\Linux\BOOTAA64.EFI` | 卷可读 + 有输入设备 |

三条都不成 → 说明卷不可读（FAT 挂载问题），按 2c 处理。


## 9. 社区提供的两条「直接写分区」通道

### 9a. UEFI Mass Storage（开机时按住音量下）

来自 `Project-Silicium/Guides → SoCs/Snapdragon/Fixing-UFS-LUNs`：

1. 刷 UEFI 镜像后重启
2. **看到 Project Silicium Logo 时按住音量下**
3. 屏幕出现蓝手机图标
4. 用音量键选到 `Current LUN: 0`，电源键确认
5. 连 PC → 出现一个大磁盘（含全部分区）

> 之前观察到 "Generic STORAGE DEVICE / No Media"，就是因为没进这个专用模式，Mass Storage 未激活。

### 9b. TWRP MassStorage.sh（把 /dev/block/sda 暴露为 U 盘）

来自 `Guides → SoCs/Snapdragon/Mass-Storage`，SM8550 用 `0x0A600000/MassStorage.sh`：

```sh
setenforce 0
echo 0xEF > /config/usb_gadget/g1/bDeviceClass
echo 0x02 > /config/usb_gadget/g1/bDeviceSubClass
echo 0x01 > /config/usb_gadget/g1/bDeviceProtocol
ln -s /config/usb_gadget/g1/functions/mass_storage.0/ /config/usb_gadget/g1/configs/b.1/
echo /dev/block/sda > /config/usb_gadget/g1/configs/b.1/mass_storage.0/lun.0/file
echo 0 > .../lun.0/cdrom
echo 0 > .../lun.0/removable
echo 0 > .../lun.0/ro
sh -c 'echo > /config/usb_gadget/g1/UDC; echo a600000.dwc3 > /config/usb_gadget/g1/UDC' &
```

在 TWRP 里执行后，PC 直接看到整个 UFS LUN0，可以用 gdisk/parted 操作分区、格式化、拷文件——**不需要 fastboot 刷整个镜像**。

### 9c. 本项目的综合脚本

`tools/twrp-install-esp.sh`：

```sh
adb push other/esp-nuwa.img /tmp/
adb push public/nuwa/tools/twrp-install-esp.sh /tmp/
adb shell sh /tmp/twrp-install-esp.sh                  # 只写镜像
adb shell sh /tmp/twrp-install-esp.sh --set-esp-type   # 写镜像 + 改 GPT 类型为 ESP
```

脚本会：定位 vendor_boot_a 分区号/起始扇区 → dd 写入 → 尝试挂载验证 → 打印分区类型恢复命令。


---

## 10. 分层诊断：黑屏时先确定卡在哪一层

**不要一上来就试遍所有镜像。** 先刷最小诊断镜像：

```powershell
.\tools\flash-uefi.ps1 -Min
```

它的 init 只做三件事：挂载 proc/sys/dev → 往 kmsg 写一行 `nuwa-min: start <uptime>` → sleep 120 后重启。

| 屏幕表现 | 卡在哪一层 | 下一步 |
|---|---|---|
| 出现 `nuwa-min: start` | **内核 + initramfs + /init 全通** | 问题在完整 init 的某个功能 → 见 §11 |
| 有内核日志但无 `nuwa-min` | initramfs 没解开 / `/init` 没执行 | 检查 initramfs 打包 |
| 黑屏有背光 | 内核没起 / 显示没继承 | 见 §3 |
| 全黑无反应 | UEFI 没加载到内核 | 见 §1 |

---

## 11. 内核起来了但功能不对

最小镜像能打印 `nuwa-min: start` 但完整版不行时，逐个功能排查：

### 11a. 输出设备

完整 init 的所有输出走 `/dev/kmsg`，因此 **dmesg 和屏幕应该都能看到**。
如果屏幕没有但 TWRP 里 `dmesg` 有 → 屏幕路径问题，不是 init 问题。

### 11b. applet 自检

完整 init 会打印 10 个关键 applet 的检查结果：

```
-- busybox applet 自检 --
   OK   ip
   OK   ifconfig
   ...
```

如果某个是 `MISS` → busybox 缺该功能（当前实测全 OK）。

### 11c. USB gadget

```
-- USB gadget (NCM) --
   udc: a600000.dwc3          ← 正常
   !! 没有 UDC（dwc3 未绑定）   ← 问题
```

如果是后者，init 会紧接着打印 `dwc3|udc|phy.*usb` 的 dmesg，直接看为什么控制器没绑定。

---

## 12. WriteBootLog：不依赖内核的事后取证

uefi-nuwa 的 `ShengBootMemoryDxe` 每次启动都会在 payload 卷的**最后一块**写入：

```
NUWABOOT count=<N> dtb=0x<addr> started
```

**前提**：FAT 卷偏移 3 处的 OEM 标签必须是 `MTOO4043`（我们的 payload 已修正）。

在 TWRP 里读：

```
adb push public/nuwa/tools/read-bootlog.sh /tmp/
adb shell sh /tmp/read-bootlog.sh
```

| 现象 | 含义 |
|---|---|
| 有 `NUWABOOT count=N` 且 N 递增 | UEFI 走到了交接点，内核被启动过（问题在内核侧） |
| 有该字符串但 count 恒为 1 | 内核启动后没重启（可能卡住） |
| 没有该字符串 | UEFI 没走到 WriteBootLog（更早环节失败） |
| 全零 | boot_b 没被识别为 payload（OEM 标签或分区大小不符） |

**这是继 pstore 之后的第二个事后取证通道，且不依赖内核是否活着。**

---

## 13. 4 KiB FAT16 还是 512 B FAT32

我们有两种 FAT 格式，选错会浪费一次刷机：

| 格式 | 镜像 | 刷到 | 依据 |
|---|---|---|---|
| **4 KiB FAT16** | `payload-bootb*.img` | `boot_b` | UFS 的 `lba_bytes=4096`；EDK2 `MAX_BLOCK_ALIGNMENT=12` 正好允许 |
| **512 B FAT32** | `esp-*.img` | `vendor_boot_a` | 最保险的通用格式，所有 UEFI 实现都支持 |

**如果 4 KiB 版挂不上，直接换 512 B 版**——不用怀疑 FAT 格式本身，
因为 4 KiB 已经通过 EDK2 源码的全部九项检查，只差 UFSDxe 这一环。

---

## 14. 屏幕文字方向不对

UEFI 的 framebuffer 是横向的（3200×1440），面板是竖屏（1440×3200），
所以 cmdline 里带了 `fbcon=rotate:1`。

| 现象 | 改法 |
|---|---|
| 躺倒、顶部在左 | `fbcon=rotate:1`（当前） |
| 倒置 | `fbcon=rotate:2` |
| 躺倒、顶部在右 | `fbcon=rotate:3` |
| 本来就是正的 | 去掉参数 |

改完重新 `make Image`（30 秒）+ 重建镜像。


---

## 15. 改了内核参数却不生效

**症状**：cmdline 里加了 `console=tty0` / `clk_ignore_unused` / `fbcon=rotate:1`，
但真机上完全看不到效果；QEMU 里却正常。

**原因**（我们踩过）：`CONFIG_CMDLINE_FROM_BOOTLOADER=y`（arm64 的默认值）意味着
**内核优先用 bootloader 传来的 cmdline，忽略 `CONFIG_CMDLINE`**。

nuwa 的 ABL 会往 dtb 的 `/chosen/bootargs` 塞约 1100 字符的参数，而 UniXNU 调
`LoadImage(..., NULL, 0, ...)`（LoadOptions 为空），内核就退回读 dtb 的 bootargs。

**怎么确认**：

```bash
# 1. 看内核实际用的命令行（启动日志第一屏）
#    应该出现 "Kernel command line: ..."
dmesg | grep "Kernel command line"

# 2. 对比内建的
cat /proc/cmdline
```

如果 `Kernel command line` 里没有你写的参数，而是一堆 `msm_drm.`、`block2mtd.` 之类，
就是这个问题。

**修复**：

```
# CONFIG_CMDLINE_FROM_BOOTLOADER is not set
CONFIG_CMDLINE_FORCE=y
CONFIG_CMDLINE="console=tty0 console=ttyAMA0 ignore_loglevel loglevel=7 keep_bootcon clk_ignore_unused pd_ignore_unused fbcon=rotate:1"
```

**两个坑中坑**：

1. **arm64 没有 `CMDLINE_EXTEND`** —— 它的 Kconfig choice 只有 `FROM_BOOTLOADER` 和 `FORCE` 两项
   （`EXTEND` 只存在于 powerpc 等架构）。用 `--enable CMDLINE_EXTEND` 会被 `olddefconfig` 丢掉。
2. **`scripts/config --disable` 对 choice 型选项不可靠** —— 必须直接编辑 `.config` 里的那三行
   （`# CONFIG_CMDLINE_FROM_BOOTLOADER is not set` + `CONFIG_CMDLINE_FORCE=y`）。

**验证修复是否生效**（不用真机）：

```bash
qemu-system-aarch64 -M virt -cpu max -m 2G -kernel Image -append "" -nographic
# 日志里应该有完整的 "Kernel command line: console=tty0 ..."
# -append 是空的却能出现完整 cmdline ⇒ FORCE 生效
```

**代价**：FORCE 会丢掉 ABL 的所有参数（`msm_drm.dsi_display0`、`kpti=0` 等）。
阶段 1（自包含 initramfs + efifb）不需要它们。阶段 2 若需要，改用 UniXNU 的
`[[dt_patch]]` 精确改 dtb。
