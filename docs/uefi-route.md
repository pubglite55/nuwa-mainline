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


## 离线验证成果（第三轮）

### EFI 应用格式验证（QEMU/PE 头）

`BOOTAA64.EFI` 解析结果：

```
DOS magic      : MZ
PE offset      : 0x40, signature PE\0\0
machine        : 0xAA64 (AArch64)
optional magic : 0x20B (PE32+)
subsystem      : 10 (EFI application)   ← UEFI LoadImage 可接受
```

结论：内核是**合法的 AArch64 EFI 应用**，UEFI 的 `LoadImage`+`StartImage` 必定能加载。

### QEMU + AAVMF 实测

`qemu-system-aarch64 -M virt -cpu max -m 2G` + `AAVMF_CODE.fd` + ESP 作为 virtio 磁盘：
固件正常启动（`UEFI firmware version 2025.11-3ubuntu7.3`），但 AAVMF 未自动启动 `\EFI\BOOT\BOOTAA64.EFI`（其启动顺序/超时策略所致），45 秒内无 EFI stub 输出。

真机路径不受影响：nuwa 的 UEFI 里 UniXNU 的 `AddFallbackLoaders` 会主动扫描并列出该文件。

### 已消除的风险

| 风险 | 状态 |
|---|---|
| 内核不是有效 EFI 应用 | ✅ 已排除（PE32+ / subsystem 10） |
| initramfs 未内嵌 | ✅ 已排除（内核 +384 KB，与模块总和吻合） |
| cmdline 缺失 | ✅ 已排除（`CONFIG_CMDLINE` 写入并 `CMDLINE_EXTEND`） |
| USB gadget 依赖模块 | ✅ 已排除（DWC3_QCOM/F_NCM/CONFIGFS_NCM 全 `=y`） |
| ESP 的 FAT32 结构 | ⚠️ 待真机验证（UEFI 是否挂载 vendor_boot_a） |
| UEFI 菜单是否列出 ESP | ⚠️ 待真机验证 |


## 第四轮验证：initramfs 内容

### busybox 架构（关键）

CI 日志确认：

```
ir-root/bin/busybox: ELF 64-bit LSB executable, ARM aarch64, version 1 (GNU/Linux),
                     statically linked, BuildID[sha1]=9a56c116...
```

**注意**：本地 WSL 的 `/bin/busybox` 是 x86-64，不能用于本地验证 initramfs；
只有 CI（`ubuntu-24.04-arm`）生成的才是正确的 aarch64 版本。

### initramfs 结构

```
/
├── init          （tools/init，busybox sh 脚本，exec >/dev/tty0）
├── bin/busybox   （aarch64 静态）
├── dev/ proc/ sys/ tmp/
└── lib/modules/  （panel / fts / cs35l41 三个 .ko）
```

内核执行 `/init`，无需 `root=` 参数。

### 验证清单（全部通过）

| 项 | 证据 |
|---|---|
| 内核是 EFI 应用 | PE32+ / 0xAA64 / subsystem 10 |
| initramfs 内嵌 | 内核 48.8 → 49.2 MB（+384 KB = 三模块） |
| busybox 架构 | CI 日志：ARM aarch64 static |
| cmdline | `CONFIG_CMDLINE="console=tty0 ignore_loglevel loglevel=7"` |
| USB 内建 | `USB_DWC3_QCOM=y` / `USB_F_NCM=y` / `USB_CONFIGFS_NCM=y` |
| ESP FAT | 卷标 NUNIXNU / NUSHELL / NUNODRM |


## ★ 第五轮：找到 FAT 挂载的关键约束（重大修正）

### 来源

`pubglite55/UniXNU-nuwa` 的 `NUWA-PORT.md` 与 `scripts/build-sheng-payload.py` 记录了**已在本机验证过的启动链**：

```
ABL → BootShim → UEFI → BDS → UniXNU
  → Fat attaches NUWAESP → \EFI\UniXNU\unixnu.toml
  → 内核入口
```

### 关键约束 1：UFS 的逻辑块是 4 KiB

`board.toml`：
```toml
[userdata]
first_lba = 0x2f7840
last_lba  = 0x3afc3fa
lba_bytes = 4096          # ← 4 KiB
```

`build-sheng-payload.py`：
```
payload.py formats with mformat -M 4096 -T size_mib*256 and no -F:
with 4 KiB sectors the image has 48,128 clusters, below the 65,525 that
FAT32 requires, so the volume is FAT16.
```

**我们此前用 `mkfs.vfat` 默认 512 B 扇区做的 FAT32，与 UFS 的 4 KiB LBA 不匹配** ——
这极可能就是 `vendor_boot_a` 上的 ESP 没被 FatDxe 挂载的原因。

### 关键约束 2：payload 放 boot_b（192 MiB）

`NUWA-PORT.md`：
> The payload is therefore a 4 KiB FAT16 volume written bare into the UFS `boot_b`
> partition (192 MiB), which Fat attaches as `NUWAESP`.

`boot_b` 与 `boot_a` 同为 201,326,592 字节，正好容纳。

### 关键约束 3：用 dd 写，不用 fastboot flash:raw

> `boot_b` payload is written with `dd` (`fastboot flash:raw` wraps the image in a
> boot header, which Fat cannot parse).

普通的 `fastboot flash boot_b xxx.img` 是原样写入，应可用；`flash:raw` 会加 header，不可用。

### 关键约束 4：vbmeta_a 必须带 flags 0x3

> `vbmeta_a` must carry flags `0x3`, otherwise the ABL refuses to start `boot_a`.

我们的 `Mu-nuwa.img` 目前能启动，说明当前 vbmeta 状态可接受；若某次刷完回 fastboot，需检查此项。

### 已生成的正确 payload

`other/payload-bootb.img`（201,326,592 字节）

BPB 验证：
```
bytes/sector : 4096      ← 与 UFS LBA 一致
sectors/clust: 1
cluster bytes: 4096
FAT type     : FAT16/12  （48,128 簇 < 65,525）
卷标         : NUWAESP
内容         : \EFI\BOOT\BOOTAA64.EFI（自包含内核 49.2 MB）
               \EFI\UniXNU\unixnu.toml
```

### 下一步验证（设备回来后首选）

```powershell
.\tools\flash-uefi.ps1 -BootB
```

即：`boot_a` ← UEFI 固件，`boot_b` ← 4 KiB FAT16 payload。

这条路径的每一环都有社区在**同一台设备**上的验证记录，比我们之前 512 B FAT32 的尝试更有依据。


### 补充：社区 payload 制作的两种实现

`build-sheng-payload.py`（sheng，macOS 上跑）：

```python
FAT_SIZE = os.environ.get('SHENG_FAT_SIZE', '192m')   # 176m 可适配 boot 分区
subprocess.run(['hdiutil', 'create', '-size', FAT_SIZE, '-layout', 'NONE',
                '-fs', 'MS-DOS FAT32', '-volname', 'SHENGESP', '-ov', str(image)])
```

`NUWA-PORT.md`（nuwa 版）改用 mtools：

```
payload.py formats with mformat -M 4096 -T size_mib*256 and no -F
```

我们采用后者（Linux/WSL 可复现）：

```bash
dd if=/dev/zero of=payload.img bs=1M count=192
mformat -i payload.img -M 4096 -T $((192*256)) -v NUWAESP ::
```

**为什么 4 KiB 扇区是对的**：UFS 的 `lba_bytes = 4096`，BlockIo 以 4 KiB 为单位；
FAT BPB 的 `bytes/sector` 必须与之匹配，否则 FatDxe 解析偏移全错。
EDK2 FatPkg 支持 512/1024/2048/4096 四种扇区大小。

### 配置路径写法

社区用**相对路径**（相对 `\EFI\UniXNU\`）：

```toml
[[entry]]
type = "xnu"
path = "Payloads/kernel.macho"
```

我们用的是绝对路径 `path = "\\EFI\\BOOT\\BOOTAA64.EFI"`，经 `UniXNUNormalizePath` 的
`Absolute = (Path[0] == '\\')` 判定也是合法的。若真机上配置不被识别，可改为
`path = "Payloads/BOOTAA64.EFI"`（把内核放 `\EFI\UniXNU\Payloads\`）以完全对齐社区写法。


### 分区尺寸核对（fastboot getvar 存档）

| 分区 | 大小（hex） | 字节 | 我们的镜像 |
|---|---|---|---|
| `boot_a` / `boot_b` | `0xC000000` | 201,326,592（192 MiB） | `payload-bootb.img` = **201,326,592** ✓ 完全匹配 |
| `vendor_boot_a` | `0x6000000` | 100,663,296（96 MiB） | `esp-nuwa.img` = 67,108,864（64 MiB）→ 余 32 MiB 保留旧数据，FatDxe 按 BPB 读不受影响 |
| `init_boot_a` | `0x800000` | 8,388,608（8 MiB） | 未使用 |
| `userdata` | `0x3804BBB000` | 240,525,004,800（≈224 GiB） | 未动 |

`payload-bootb.img` 与 `boot_b` 尺寸**精确相等**，`fastboot flash boot_b` 会完整覆盖该分区。

> 注意：`boot_b` 是 Android 的 B 槽内核分区。覆盖后 B 槽不可用（A 槽不受影响）；
> 恢复只需 `fastboot flash boot_b backup/nuwa-backup/boot_b.img`（已备份，201,326,592 字节）。


### vbmeta_a 校验（已确认满足条件）

`backup/nuwa-backup/vbmeta_a.img` 头部 dump：

```
0000  41 56 42 30 00 00 00 01 00 00 00 00 00 00 00 00   AVB0............
...
0070  00 00 00 00 00 00 00 00 00 00 00 03 00 00 00 00   ................
0080  61 76 62 74 6f 6f 6c 20 31 2e 33 2e 30 00 00 00   avbtool 1.3.0...
```

- magic = `AVB0`，版本 1.0，算法 1（RSA2048）
- **flags 在 `0x78`–`0x7B` = `0x00000003`** ✅

`NUWA-PORT.md` 要求：

> `vbmeta_a` must carry flags `0x3`, otherwise the ABL refuses to start `boot_a`.

**当前已满足**，这解释了为什么我们的 `Mu-nuwa.img` 能被 ABL 接受并执行到 UEFI。

> 若某次刷写后设备刷完直接回 fastboot（UEFI 不执行），优先检查 vbmeta_a 是否被覆盖成 flags≠0x3。
> 恢复：`fastboot flash vbmeta_a backup/nuwa-backup/vbmeta_a.img`。
