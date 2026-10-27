# nuwa 主线移植 — 当前状态

更新时间：2026-10-28

## 路线切换：ABL → UEFI

ABL 直启路线已放弃（dtb 强校验 + 无 console 输出）。改走社区验证过的 **UEFI 路线**。

| 阶段 | 结论 |
|---|---|
| ABL 整段换主线 dtb | ❌ 拒绝，回 fastboot |
| ABL 只换首 FDT（原厂树+USB补丁） | ⚠️ 接受但内核卡米标，无输出 |
| ABL 只换首 FDT（社区 dtb） | ⚠️ 接受但内核卡米标 |
| ABL `fastboot boot` | ❌ 不可用 |
| **UEFI（BootShim + FD）** | ✅ **已起来，屏幕有界面，USB 枚举出 VID_18D1** |

## 已就绪产物（other/）

| 文件 | 大小 | 用途 |
|---|---|---|
| `uefi-nuwa/Mu-nuwa.img` | 2.13 MB | UEFI 固件 RELEASE，刷 `boot_a` |
| `uefi-nuwa-debug/Mu-nuwa.img` | 2.25 MB | UEFI DEBUG 版，屏幕打印卷扫描日志 |
| **`payload-bootb.img`** | 201,326,592（192 MiB） | **首选**：4 KiB 扇区 FAT16，刷 `boot_b`，内含 nodrm 内核 |
| `esp-nuwa.img` | 64 MB | 512 B FAT32 正常版，刷 `vendor_boot_a` |
| `esp-nuwa-nodrm.img` | 64 MB | 512 B FAT32 nodrm 版 |
| `esp-shell.img` | 64 MB | UEFI Shell + nodrm 内核（诊断 + 手动启动） |

## 自包含内核

三条独立路径（详见 [INDEX.md](INDEX.md)）：

| 路径 | 内核 | 显示机制 | 来源 |
|---|---|---|---|
| A | 49.3 MB | `DRM_MSM=y` | CI 社区 7.0 |
| B | 47.8 MB | `DRM_SIMPLEDRM` | CI 社区 7.0 |
| **C** | **44.25 MB** | **`FB_EFI=y` 内建 efifb** | 本地 7.4 + nuwa dts |

C 路径已通过 QEMU 端到端验证（内核启动 + /init 执行 + applet 自检全 OK）。

**内建清单**（全部 `=y`，无模块依赖）：
USB（DWC3/QCOM/NCM/configfs/role-switch）、网络（NET/INET/PACKET）、
显示（FB_EFI）、触控（ST_FTS_V521_SPI + INPUT_EVDEV）、电源键（POWER_RESET_QCOM_PON）、
GPIO 按键（INPUT_GPIO_KEYS + KEYBOARD_GPIO）、存储（BLK_DEV_SD/UFSHCD/SCSI_UFS_QCOM/EXT4）、
PINCTRL_SM8550、ARM_SMMU、QCOM_LLCC。

## init 的行为（可在屏幕上看到）

```
==============================================
  nuwa initramfs  |  mainline kernel + UEFI
==============================================
uptime : ...
cmdline: console=tty0 ...
kernel : 7.0.0-sm8550
-- 加载驱动模块 --
   ok  panel-samsung-amb673cp01-m2.ko
   ok  fts-spi.ko
   ok  snd-soc-cs35l41-i2c.ko
-- USB gadget (NCM) --
   udc: a600000.dwc3
   telnetd 已启动 (192.168.0.1:23)
=== 系统就绪：可 telnet 192.168.0.1 ===
```

## 工具

| 脚本 | 用途 |
|---|---|
| `tools/flash-uefi.ps1` | 一键刷 UEFI + ESP 并监控 USB |
| `tools/device-recover.ps1` | 一键恢复原厂 Android（三件套 + slot a + 可选 GPT） |
| `tools/pc-ncm-connect.ps1` | PC 端配置 NCM 网卡并连 telnet |
| `tools/twrp-set-esp-type.sh` | TWRP 内把 vendor_boot_a 类型改为 ESP（备用） |
| `tools/mk-esp.sh` | 生成 ESP 镜像 |

## 备份完整性

`backup/nuwa-backup/`：boot_a/b、init_boot_a/b、**vendor_boot_a**（已补）、vbmeta、dtbo、persist、gpt-sd[a-d]-head/backup 等。

恢复：`tools/device-recover.ps1`（设备需在 fastboot）。

## 待真机验证（按顺序）

1. 刷 `esp-shell.img` → 是否出现 UEFI Shell 提示符（= FAT 挂载通）
2. 刷 `esp-nuwa.img` → 屏幕是否出现内核日志与 init 输出
3. 若黑屏 → 刷 `esp-nuwa-nodrm.img`
4. 若菜单无启动项 → 刷 UEFI DEBUG 版看卷扫描日志，或 TWRP 改 GPT 类型
5. 成功进 Linux 后 → PC 跑 `pc-ncm-connect.ps1` → telnet 192.168.0.1

## 参考

- UEFI 路线细节：[public/nuwa/docs/uefi-route.md](<public/nuwa/docs/uefi-route.md>)
- 社区 UEFI：`pubglite55/uefi-nuwa`（fork 自 Project-Silicium/Mu-Silicium）
- 社区内核：`alfaonyt/nuwa-mainline`（7.0 + nuwa 补丁）
