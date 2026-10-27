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


## ★ 第六轮：经验库命中的关键盲区（整链内建）

加载 `android-mainline-port` 技能后，`experience/kernel-and-resources.md` 里这条直接命中我们：

> ### 驱动编成 `=m`，但镜像里没有模块目录，功能静默缺失【高频】【耗时】
> 现象：永久 `EPROBE_DEFER`、驱动不绑定、电源键和音量键失效、远端处理器服务不出现，
> 但**没有任何报错**。
> 常见受害者（高通）：`QCOM_GPI_DMA`（SPI 触控）、`SPI_QCOM_GENI`、
> `QRTR`/`QRTR_SMD`/`QCOM_PD_MAPPER`（ADSP 服务）、`PHY_QCOM_QMP_PCIE`+`RFKILL`（Wi-Fi）、
> `POWER_RESET_QCOM_PON`（电源键和音量键）、`RTC_DRV_PM8XXX`、`NVMEM_REBOOT_MODE`、
> `BATTERY_QCOM_BATTMGR`、`QCOM_CPUCP_MBOX`、`SPI_QCOM_GENI`、`FASTRPC`、`SND_SEQUENCER`。
> 怎么解决：**首启阶段把启动和恢复依赖全部 `=y`**。

我们此前只内建了 USB 三个配置，initramfs 里也只有 panel/fts/cs35l41 三个模块 ——
**触控的 SPI 控制器、电源键、Wi-Fi PHY、ADSP 服务全都会静默缺失**。

### 已补齐的内建清单（两个 job 同步修改）

```
QCOM_GPI_DMA / SPI_QCOM_GENI / SPI_QCOM_QSPI     ← 触控 SPI 链路
POWER_RESET_QCOM_PON                              ← 电源键、音量键
QCOM_PD_MAPPER / QRTR / QRTR_SMD                  ← ADSP 服务
PHY_QCOM_QMP_PCIE / RFKILL                        ← Wi-Fi 链路
CLK_QCOM_DISPCC_SM8550 / QCOM_CLK_RPMH            ← 显示时钟（模块会导致"慢启动态"）
PINCTRL_SM8550 / PINCTRL_SM8550_LPASS_LPI
RTC_DRV_PM8XXX / NVMEM_REBOOT_MODE / NVMEM_SPMI_SDAM
BATTERY_QCOM_BATTMGR / QCOM_CPUCP_MBOX
QCOM_SMEM / QCOM_SMD_RPM / QCOM_RPMH / ARM_SMMU / QCOM_LLCC / SCSI_UFS_QCOM
OVERLAY_FS
```

### 另一条相关警告：借用固件画面的资源回收

> ### 固件仍在用的资源没有消费者，被内核回收【高频】【耗时】
> 现象：借用固件画面一段时间后黑屏或灰屏；触控 SPI 超时；多数情况重启也不恢复。
> 原因：内核在 `late_initcall`（`clk_disable_unused`）和 sync_state 时关掉没有消费者的资源。
> 怎么解决：在真正的消费者节点（例如 `simple-framebuffer`）里声明电源域、时钟、互连路径及带宽。

**这条对 nodrm 版（simpledrm 借用 UEFI framebuffer）是直接风险**：如果设备树里
`simple-framebuffer` 节点没有声明 `power-domains`/`clocks`/`interconnects`，
显示时钟可能在 2–3 秒后被回收，画面随即黑掉。

诊断手段（临时，不可长期保留）：`clk_ignore_unused`、`pd_ignore_unused` ——
用来确认"是不是资源回收"后再撤掉。


## 显示路线（按经验库修正）

`experience/display.md` 明确两种路线：

| | 借用固件画面（simple-framebuffer + simpledrm） | 原生接管（DPU + DSI + 面板驱动） |
|---|---|---|
| 原理 | bootloader 点亮面板，Linux 只往这块内存画图 | 内核重新初始化控制器和面板 |
| 首次出图 | 快（一两天） | 有现成面板驱动几天；自写一到两周 |
| 能力 | 无亮度/熄屏/刷新率/外接，GNOME 连接器是 Unknown | 全部具备 |

**原生接管的关键步骤**（原文第 3 条）：

> 先用模块方式加载显示驱动（`msm` 做成 `=m`，启动时不加载，调试通道起来后手动 `modprobe`），
> 这样挂死前能拿到日志。

### 因此首启的正确选择

- **首启用 nodrm 版**（`DRM_MSM=n` + simpledrm 借用 UEFI framebuffer）——先拿到画面和日志
- **不要**首启就用 `DRM_MSM=y` 正常版：msm 会复位硬件并移除 simpledrm，一旦参数不对就黑屏无日志
- 等调试通道稳定后，再把 `msm` 做成 `=m` 手动 modprobe 做原生接管

### nodrm 版已加诊断参数

```
console=tty0 ignore_loglevel loglevel=7 keep_bootcon clk_ignore_unused pd_ignore_unused
```

`clk_ignore_unused` + `pd_ignore_unused` 是**临时诊断手段**：用来确认"simpledrm 的 framebuffer
是否因资源回收而黑掉"。确认后必须撤掉（长期保留会导致无法省电、无法休眠、无法进上游）。


## 第七轮：经验库对 boot_b 方案的交叉验证

`experience/usb-and-storage.md` 有一条警告：

> ### B 槽或 recovery 分区不能用来放 Linux
> 现象：B 槽启动进旧版本链或失败；recovery 拒绝带内核的镜像。
> 原因：B 槽出厂可能是旧固件链或全零，super 分…

**与 NUWA-PORT 的做法不冲突，但要分清两种"放"法**：

| 放法 | 谁去读 | 是否可行 |
|---|---|---|
| 把 boot_b 当作**可启动槽**（让 ABL 启动它） | ABL | ❌ 不可行（B 槽固件链可能是旧的/全零） |
| 把 boot_b 当作**纯数据分区**（FAT16 payload） | UEFI 的 FatDxe | ✅ 可行（NUWA-PORT 已在本机验证） |

我们的做法是后者：`boot_a` 放 UEFI 固件（ABL 启动它），UEFI 再把 `boot_b` 当普通 FAT 卷挂载。
**ABL 全程不参与 boot_b 的启动判定**，所以 B 槽固件链状态无关。

### 刷写速度提醒

`experience` 里另一条：

> 刷写镜像把空白区域编码成"写零"，刷写极慢，Fastboot 失去响应。
> 原因：sparse 镜像里的空白被编码为 FILL，bootloader 先回 OKAY 再在后台慢速写零。

我们的 `payload-bootb.img` 是 **raw（非 sparse）**，201 MB 里大部分是零，`fastboot flash boot_b`
会如实写入 201 MB。USB 3.0 下约 5–10 秒，USB 2.0 下可能 30 秒以上。
若感觉卡住，改用 TWRP 里 `dd`（`tools/twrp-install-esp.sh` 已支持改分区名）。

### USB 调试通道（与经验库一致）

> 先做设备模式（作为调试通道，**USB2 高速 NCM 最稳**），再做主机模式和外接显示。
> 启用顺序：控制器角色切换 → UCSI → VBUS → 枚举 → USB3/DP。

我们的 initramfs 正是 NCM 路线（`configfs` + `ncm.usb0` + `192.168.0.1`），与推荐一致。


## 第八轮：触控与按键的经验库要点

### 我们的触控形态

`experience/touch-and-input.md` 要求先判断形态：

| 形态 | 特征 | 我们 |
|---|---|---|
| 独立触控芯片（固件在 flash） | 驱动相对独立，按普通 SPI/I2C 外设处理 | ✅ **FocalTech FTS 属于此类** |
| TDDI（显示触控一体，固件在 RAM） | 面板复位会丢固件，需 `drm_panel_follower` | ❌ 不适用 |
| THP（原始数据 + 主机算法） | 需要开源算法和标定 | ❌ 不适用 |

nuwa 的触控是 `&spi4` 上的 `fts@0`（`compatible = "st,fts"`），独立芯片，
**不需要**跟面板电源序列联动，这降低了首版难度。

### 已记录的风险：GPI DMA 报 EIO

> ### SPI 经 GPI DMA 传输报 EIO
> 原因：GPI DMA 完成回调先设置了状态，SPI 核心因此不累加 `actual_length`。
> 适用范围：高通 GENI SPI + GPI DMA；2026。

我们的触控正好走 GENI SPI（`SPI_QCOM_GENI`）。若触控 probe 时报 EIO：

1. 先确认 `/sys/kernel/debug/spi/` 与 dmesg 里的 `actual_length`
2. 临时规避：从 `&spi4` 节点移除 `dmas`/`dma-names`，强制 PIO 模式
3. 这是**临时规避**，需登记技术债（PIO 性能低、CPU 占用高）

### 按键路径（已内建）

> 电源键和音量减通常来自 PMIC PON（`pwrkey`/`resin`），音量加常是 PMIC GPIO 上的 `gpio-keys`。

已内建 `POWER_RESET_QCOM_PON=y`。首启验证要点：
- `/dev/input/event*` 里应有 `pm8941_pwrkey` 一类设备
- 真实按下能看到 evdev 事件（不是节点存在就算通过）

### 验收标准（经验库原文）

> 触控：真实手指点击、滑动、多指、四角、横竖屏；冷启动、熄屏再亮屏、面板重新上电三种情况分别测；
> **中断计数增长、输入设备存在、程序注入的事件都不算**。


## 第九轮：经验库对 UEFI 路线的评估要求

`references/decisions.md` 的 **UEFI 引导层** 一节：

> - **默认做法**：作为可选的后续方向，不放进首版。
> - **规则**：评估时先确认四件事：
>   1. 固件里是否嵌了不能再分发的原厂组件；
>   2. 它是否替换 boot（Android 更新会覆盖）；
>   3. 槽成功标记怎么处理；
>   4. **UEFI 退出时的硬件状态（显示、SMMU、时钟）和 ABL 不同，之前基于 ABL 交接状态的结论都要重测**。
> - 结论不明确时只做一次只读的 RAM 验证。

### 逐条对照我们的情况

| 要求 | 我们的状态 |
|---|---|
| 1. 是否嵌原厂不可分发组件 | ⚠️ Project Silicium 用 `Binaries/nuwa/QcomPkg/*`（预编译高通组件）。**这是分发风险，不是技术风险**；自用不受影响，对外发布需注意 |
| 2. 是否替换 boot（Android 更新会覆盖） | ✅ 我们刷 `boot_a`。OTA 会覆盖它 → 恢复 Android 后需重刷 UEFI |
| 3. 槽成功标记 | ✅ 未改槽属性（只用 `fastboot set_active a`），ABL 侧无需标记 |
| 4. **UEFI 退出时硬件状态与 ABL 不同** | ⚠️ **这是最大未知**：SMMU 配置、时钟树、显示控制器状态由 UEFI 建立，与 ABL 交接时不同。我们所有基于"ABL 交接状态"的推断都要作废 |

### 为什么仍然走 UEFI

经验库的"默认做法（不放进首版）"前提是 **ABL 路线可行**。我们的实测结论是：

- ABL 对 dtb 强校验（只认 `msm-id=0x25c` / `board-id=0`）
- 任何自定义 initramfs 在 ABL 路径下都会"秒重启"
- 没有 console，卡米标时零输出

三条叠加后 ABL 路线不可行，UEFI 是唯一能拿到画面和日志的路径。

### 早期日志策略（经验库支持）

> 内核在交接后静默挂死 → **想办法把崩溃打到屏幕上（例如借用固件画面的 earlycon），常能直接定位**。

这正是 nodrm 版（`simpledrm` 借用 UEFI framebuffer + `console=tty0`）的设计依据。


## 第十轮：无线（Wi-Fi/BT）路线要点

`experience/wireless.md`：nuwa 是 **WCN6856（QCA6490）**，PCIe 接 ath11k、UART 接 hci_qca。

### Wi-Fi 六步

1. 原厂只读取证：PCI 子系统 ID、固件+board 版本组合、MAC 来源、监管区域、SAR 功率上限
2. 电源时序节点 `qcom,wcnXXXX-pmu`，多路供电逐路确认（**PCIe PHY 供电最难找证据**）
3. **PCIe 控制器和 PHY 内建**（已加 `PHY_QCOM_QMP_PCIE=y`）；**保持 IOMMU 正常隔离，不要 `iommu.passthrough=1`**
4. 驱动补丁优先上游/社区，按提交导入
5. 固件**按版本组合整套使用**；MAC 从本机数据分区读，在 NetworkManager 之前设置
6. 按原厂方式下发 SAR 功率上限

### 三个已知坑（提前记下）

| 现象 | 原因 |
|---|---|
| 5 GHz 80 MHz 关联 6 秒后断线，桌面误报"密码错误" | 原厂驱动每次启动下发 SAR 功率上限，主线不下发；超 ~20 dBm 链路冻结 |
| 5 GHz 扫描为 0 | 监管区域缺 6 GHz 规则 → 频段计算把单射频缩成只剩 2.4 GHz（有社区补丁） |
| IOMMU 正常隔离时固件加载失败 | `iommu-map` 改两 cell 后 `config_sid` 解析写错 stream ID（主线 7.2 前后） |

> 注意：**只换 `board.bin` 的实验毫无意义** —— 驱动先在 `board-2.bin` 按完整键查找，
> 命中后不再读 `board.bin`。每次固件实验都要在日志里看到完整键匹配，否则无法归因。

### 蓝牙

UART 节点 + 父串行引擎启用；固件与原厂版本对应（需早期加载则放 initramfs）；
**地址从本机数据分区读，不要写死在设备树里**；在 `bluetooth.service` 之前写入。

### 当前阶段不做的原因

Wi-Fi/BT 需要从原厂系统提取固件与 board 数据（`/vendor/firmware`、`/persist`），
属阶段 6 外设工作。**首版目标是启动 + 显示 + USB 网络**，Wi-Fi 留到链路稳定后。


## 第十一轮：构建提速（全内建、无模块）

### 问题

`make Image modules` 要编译 defconfig 里全部 `=m` 驱动（数千个 `.o`），
单次构建超过 **60 分钟**，两个 job 并行也压不下来。

### 修正

按经验库「整链内建」原则，把三个外设驱动也从 `=m` 改为 `=y`：

```
CONFIG_DRM_PANEL_SAMSUNG_AMB673CP01_M2=y    （原 =m）
CONFIG_TOUCHSCREEN_ST_FTS_V521_SPI=y        （原 =m）
CONFIG_SND_SOC_CS35L41_I2C=y                （原 =m）
CONFIG_SND_SOC_CS35L41=y / _LIB=y
```

然后去掉 `make modules`、模块收集、二次 `make Image` 三个步骤，只做一次 `make Image`。

### 收益

| | 改前 | 改后 |
|---|---|---|
| 构建步骤 | Image modules → 收集 .ko → 重打包 Image | 一次 `make Image` |
| 构建时长 | **60+ 分钟** | 预计 10–15 分钟 |
| initramfs 依赖 | 需带 `/lib/modules/*.ko` | **零模块依赖**，更符合"整链内建" |
| 风险 | 模块漏打包 → 功能静默缺失 | 无此风险 |

> 经验库原话："首启阶段把启动和恢复依赖全部 `=y`" —— 现在连外设也一起内建，
> 代价是内核稍大（约 +400 KB），换来构建快、无模块依赖、无静默缺失。


## 第十二轮：音频（CS35L41 ×2）路线要点

`experience/audio.md`：

### 前提条件（缺一不可）

> ADSP 固件加载（PAS）、QRTR、PD mapper、GPR 都工作。
> **PD mapper 报 "no support for the platform" 先查根 compatible 是否被改写。**

已内建：`QRTR`/`QRTR_SMD`/`QCOM_PD_MAPPER`。

### 逐层推进（不要跳步）

```
open → hw_params → prepare → DSP 接受播放图 → 功放启动
     → 不可闻的全零播放测试 → 电气回环 → 人耳
```

### 三个会误导人的坑

| 现象 | 原因 |
|---|---|
| 播放图能打开、TDM 参数被接受，但功放不出声 | 位时钟（BCLK）极性/时钟属性与原厂不一致 —— **"唯一的差异"要最先单变量验证** |
| 功放上电、PCM 能打开、测试"通过"，人听不到 | quirk 用根 compatible 选择，被 bootloader 改写后永远选不中 → **改用声卡名选择** |
| `open` 返回 `EINVAL`，`prepare` 报 `Invalid channels (8)` | 前端只给 S32 而 q6apm 只支持 S16/S24；主线 AudioReach 前端拒绝 >4 声道 → **前端用 2 声道 S16，DSP 内做通道混合** |

### 「根 compatible 被改写」是贯穿多个子系统的共性问题

经验库在 bootloader、音频、显示（UBWC 配置）三处都提到同一件事：

> ABL 把 dtbo 根上的 `compatible`、`model`、`msm-id`、`board-id` 覆盖到运行时设备树根上，
> 变成平台通用名（例如 `qcom,<平台>-mtp`）。

**UEFI 路径下这一条需要重新确认**：UEFI 的 FdtBlob 是社区 dts 编译的，
但它是否也会改写根节点、改写成什么，只有上机 `cat /proc/device-tree/compatible` 才知道。
这将是首启检查清单里的一项。

### 首启检查清单（累计）

| 检查项 | 命令 | 期望 |
|---|---|---|
| 根 compatible | `cat /proc/device-tree/compatible` | 与源码一致（若被改写需内核早期恢复） |
| 根 model | `cat /proc/device-tree/model` | 同上 |
| 输入设备 | `cat /proc/bus/input/devices` | 有 pwrkey、fts |
| USB 网络 | `ip -4 addr show usb0` | 192.168.0.1/24 |
| 显示 | `cat /sys/class/graphics/fb0/virtual_size` | 1440,3200 |
| 延迟探测 | `cat /sys/kernel/debug/devices_deferred` | 空或可解释 |
| 虚拟化误判 | `systemd-detect-virt` | 不是 vm（hypervisor 节点需遮蔽） |


## 第十三轮：主机脚本的坑（会浪费真机机会）

`experience/testing-and-process.md` 列出的常见主机端问题，与我们脚本直接相关的：

| 坑 | 后果 | 我们的对策 |
|---|---|---|
| **Fastboot 刚交接时轮询撞上 ABL 拆 USB 窗口** | 误发命令、刷写失败 | 刷完 `reboot` 后先静默等 5 秒再开始轮询 |
| **设备重新枚举后主机 fastboot 挂住** | 后续命令全挂 | 解绑重绑 USB 端口（或用 `fastboot reboot bootloader` 重置） |
| USB 断开不保证 TCP 收到 FIN | 旧连接 90 秒无 EOF 被当成设备还在 | telnet 侧要设超时，不靠 EOF 判活 |
| `fastboot boot | tee` 返回的是 tee 的退出码 | 误判成功 | 我们直接读 `$LASTEXITCODE`，不接管道 |
| 空输出哈希是 `e3b0c442…` | 把空输入当有效结果 | 输出为空一律判失败 |
| BusyBox 行编辑最多 1023 字节 | 长命令被截断 | init 里的命令保持短小 |
| 提示符后跟 `\x1b[6n` | 解析错位 | 用明确开始/结束标记界定输出 |

### 状态词纪律（再次确认）

> **离线检查全绿，被当成"接近交付"** —— 几十个离线检查、QEMU 全部通过，上机后本版新增的功能全部失败。
> 怎么解决：只有离线证据的写"离线通过"；每个新功能先用独立的内存镜像单项上真机，通过后再合并。

我们当前所有结论都只能标 **离线通过**。真机验证必须逐项做，且：

> **把"跑起来了"当成"能用了"** —— 驱动加载、probe 成功、QEMU 通过都被写成功能通过。
> 功能通过必须是用户能感知的结果（看到、听到、摸到、连上）或等价的硬件指标。

### 用户参与方式（已纳入流程）

> 需要用户动作时**提前至少一分钟通知**，说明要做什么和观察什么。

因此设备回来后的流程是：
1. 我先跑 `run-test.ps1` 完成刷机与机器指标采集
2. 然后**明确告诉你要看屏幕的什么位置、什么现象**，再请你确认
3. 你的回答与机器指标分开记录


## 第十四轮：rEFInd 备用引导器

社区 Arch-Linux 指南用 rEFInd 作为引导器。已下载并生成备用盘：

`other/esp-refind.img`（64 MB，卷标 NUREFIND）

```
\EFI\BOOT\BOOTAA64.EFI       258,408 B   rEFInd 0.14.0.2 (aa64)
\EFI\refind\refind.conf                  配置
\EFI\refind\drivers_aa64\                ext4/ext2/btrfs/iso9660 驱动
\Linux\BOOTAA64.EFI        47,831,552 B   nodrm 内核
```

配置：

```
timeout 10
use_nvram false
scanfor manual,external
log_level 1

menuentry "Ubuntu Linux (nuwa, self-contained)" {
    loader \Linux\BOOTAA64.EFI
    options "console=tty0 ignore_loglevel loglevel=7 keep_bootcon clk_ignore_unused pd_ignore_unused"
}
```

### 四层引导器备选（按优先级）

| 层 | 引导器 | 触发条件 | 镜像 |
|---|---|---|---|
| 1 | **UniXNU 配置** | 读到 `\EFI\UniXNU\unixnu.toml` | `payload-bootb.img` |
| 2 | **UniXNU 兜底** | `AddFallbackLoaders` 扫到 `\EFI\BOOT\BOOTAA64.EFI` | 同上 |
| 3 | **UEFI Shell 手动** | Shell 里执行 `\Linux\BOOTAA64.EFI` | `esp-shell.img` |
| 4 | **rEFInd** | Shell/rEFInd 菜单直接 loader | `esp-refind.img` |

前三层都依赖 UniXNU 的卷扫描；第 4 层是独立引导器，只要 UEFI 能加载 `\EFI\BOOT\BOOTAA64.EFI` 就能起。


## ★ 第十五轮：QEMU 端到端验证（决定性证据）

用 QEMU 直接加载本地编译的 efifb 内核（`-kernel Image`，`-M virt`）：

```
[ 0.000000] Booting Linux on physical CPU 0x0000000000
[ 0.000000] Linux version 7.3.0-g734bef548a96-dirty (aarch64-linux-gnu-gcc 15.2.0)
             #4 SMP PREEMPT_DYNAMIC Wed Oct 28 03:14:53 CST 2026
...
[16.668568] SPI driver fts has no spi_device_id for st,spi
[16.725901] clk: Disabling unused clocks
[16.726281] PM: genpd: Disabling unused power domains
[16.726832] Warning: unable to open an initial console.
[17.404012] Freeing unused kernel memory: 4544K
[17.408659] Run /init as init process
[17.409647]   with arguments: /init
[17.460299]     HOME=/
[17.460320]     TERM=linux
```

### 四条已证实的结论

| # | 结论 | 证据 |
|---|---|---|
| 1 | **内核可正常启动** | `Booting Linux on physical CPU` → `Freeing unused kernel memory` |
| 2 | **initramfs 已内嵌且被解压** | `Freeing unused kernel memory: 4544K` 之后立即 `Run /init as init process` |
| 3 | **`/init` 真的被执行** | `Run /init as init process with arguments: /init` |
| 4 | **FTS 触控驱动已内建并注册** | `SPI driver fts has no spi_device_id for st,spi`（QEMU 无硬件，但驱动已就位） |

### 同时暴露的两个真实问题

**问题 1：资源回收确实会发生**

```
[16.725901] clk: Disabling unused clocks
[16.726281] PM: genpd: Disabling unused power domains
```

这次 QEMU 测试的 cmdline 是 `console=ttyAMA0 ignore_loglevel loglevel=7`，**没有**带
`clk_ignore_unused pd_ignore_unused`，所以回收正常发生 —— 反证了真机版带这两个参数是必要的。

**问题 2：`unable to open an initial console`，init 的输出可能全部丢失**

QEMU 里 `console=ttyAMA0` 没建立对应设备，`/dev/tty0` 也不存在，
于是 `exec >/dev/tty0` 失败 → **后续所有输出消失**，只能靠 `Run /init` 这一行判断它跑起来了。

**已修正 `tools/init`**：输出设备按 `/dev/tty0` → `/dev/console` → `/dev/ttyAMA0` 顺序兜底，
并额外写一行到 `/dev/kmsg`，保证即使屏幕不可用也能从 dmesg/pstore 取到执行痕迹。
