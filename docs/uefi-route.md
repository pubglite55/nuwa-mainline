# UEFI 路线（nuwa）

## 为什么放弃 ABL 直启

ABL（Android Bootloader）对 `boot`/`vendor_boot` 的约束实测如下：

| 尝试 | 结果 |
|---|---|
| 整段 dtb 换主线树（单份/8 份复制） | 拒绝，回 fastboot |
| 只替换首 FDT，其余 7 个保留原厂 | 接受，但内核卡米标（无输出） |
| 社区 dts + 身份改为 `0x25c/0x00` | 接受，仍卡米标 |
| `fastboot boot` | 不可用（发 OKAY 不跳转） |

核心障碍：**没有 console**，内核死在哪完全不可见。

## UEFI 路线原理

产物是标准 Android `boot.img`（**只刷 boot_a**）：

```
UEFI FD(SILICIUM_UEFI.fd) + BootShim.bin → gzip → 追加 nuwa.dtb → mkbootimg(header v1)
```

- `nuwa.toml`：`uefi_fd.base=0xA7100000 size=0x300000`、`boot_image_kernel.append_dtb=true`、`header_version=1`
- BootShim 从 ABL 接管 CPU，跳进 UEFI FD
- UEFI 自带 nuwa 设备树（`Platforms/Xiaomi/nuwaPkg/FdtBlob/sm8550-xiaomi-nuwa.dtb`），经 DtPlatformDxe 发布

## 已构建产物

| 产物 | 大小 | 说明 |
|---|---|---|
| `other/uefi-nuwa/Mu-nuwa.img` | 2.13 MB | UEFI + BootShim + dtb（刷 boot_a） |
| `other/bootefi/BOOTAA64.EFI` | 48.8 MB | 自包含内核（内嵌 initramfs + 内置 cmdline） |
| `other/esp-nuwa.img` | 64 MB FAT32 | ESP：`\EFI\BOOT\BOOTAA64.EFI` + `\EFI\UniXNU\unixnu.toml` |

构建：`pubglite55/uefi-nuwa` 的 `build-nuwa.yml`、`pubglite55/nuwa-mainline` 的 `build-bootefi.yml`。

## UniXNU 的配置与兜底机制（读源码确认）

`Config.c`：

1. `PcdUniXNUConfigPath = L"\\EFI\\UniXNU\\unixnu.toml"`
2. `UniXNUConfigLoad`：**先试自身所在卷**，再遍历所有 `SimpleFileSystem` 卷
3. 都失败 → 用内置菜单（`Return to firmware` / `Restart` / `Power off`）
4. `AddFallbackLoaders`：遍历所有卷，存在 `\EFI\BOOT\BOOTAA64.EFI` 就加一项 **"EFI loader on volume N"**

第 4 条是关键：**不依赖任何配置文件**，只要卷能被挂载。

## UEFI 固件里的存储/文件系统栈（DXE.inc 确认）

```
PartitionDxe + FatPkg/EnhancedFatDxe + QcomPkg/Drivers/UFSDxe
```

EDK2 的 FAT 驱动不按 GPT 类型过滤，因此把 FAT32 镜像刷进 `vendor_boot_a` 理论上应被挂载。

## 自包含内核（为什么这么做）

EFI stub 被 UEFI `LoadImage`+`StartImage` 时**没有 LoadOptions**，所以：

- `CONFIG_INITRAMFS_SOURCE`：把 initramfs 内嵌进内核（48.8 MB 里含 ~1 MB）
- `CONFIG_CMDLINE="console=tty0 ignore_loglevel"` + `CONFIG_CMDLINE_EXTEND`
- `CONFIG_EFI_STUB=y`、`FB_EFI`、`DRM_SIMPLEDRM`
- USB 关键路径强制内建：`USB_DWC3_QCOM`、`USB_F_NCM`、`USB_CONFIGFS_NCM`（initramfs 无模块）

## 驱动内建/模块现状（社区 sm8550.config）

| 驱动 | 状态 |
|---|---|
| PHY_QCOM_QMP_COMBO / QMP_USB / EUSB2_REPEATER | `=y` ✅ |
| TYPEC / TYPEC_UCSI / USB_CONFIGFS | `=y` ✅ |
| DRM_MSM | `=y` ✅ |
| PSTORE_RAM/CONSOLE/PMSG | `=y` ✅ |
| DRM_PANEL_SAMSUNG_AMB673CP01_M2 | `=m`（需模块） |
| TOUCHSCREEN_ST_FTS_V521_SPI | `=m`（需模块） |
| SND_SOC_CS35L41_I2C | `=m`（需模块） |

## 待验证（设备在线后）

1. 刷 `Mu-nuwa.img` → `boot_a`、`esp-nuwa.img` → `vendor_boot_a`
2. UEFI 菜单是否出现 **"EFI loader on volume N"**
3. 选中后内核是否启动、`console=tty0` 是否有输出
4. initramfs 的 `/init` 是否建起 USB NCM（`192.168.0.1` + telnetd）
5. 若成功 → 补模块（panel/touch/audio）到 initramfs


## 增量改进（第二轮）

### 1. init 输出到屏幕

`tools/init` 现在挂载 devtmpfs 后立即 `exec >/dev/tty0 2>&1`，因此**整个 init 执行过程都显示在屏幕上**：

```
==============================================
  nuwa initramfs  |  mainline kernel + UEFI
==============================================
uptime : ...
cmdline: console=tty0 ignore_loglevel loglevel=7
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

这是**第一次能在设备屏幕上看到我们自己的用户态日志**，比卡米标盲猜强太多。

### 2. 外设模块打包进 initramfs

```
panel-samsung-amb673cp01-m2.ko   ← 面板（DRM_PANEL_SAMSUNG_AMB673CP01_M2=m）
fts*.ko                          ← 触控（TOUCHSCREEN_ST_FTS_V521_SPI=m）
snd-soc-cs35l41*.ko              ← 功放（SND_SOC_CS35L41_I2C=m）
```

CI 流程改为：`make Image modules` → 收集 `.ko` 到 `ir-root/lib/modules/` → 清除 `usr/initramfs_data.cpio*` → 重新 `make Image`（让内嵌 initramfs 包含模块）。

### 3. 路径解析确认

`UniXNUNormalizePath`：`Absolute = (Path[0] == '\\' || Path[0] == '/')`，所以 `unixnu.toml` 里
`path = "\\EFI\\BOOT\\BOOTAA64.EFI"` 是**绝对路径**，写法正确。

### 4. 备选：显示安全版

若 `DRM_MSM=y` 抢占 framebuffer 导致屏幕无输出，可构建 `--disable DRM_MSM` 版本，让 `simpledrm` 直接用 UEFI GOP 输出内核日志。
