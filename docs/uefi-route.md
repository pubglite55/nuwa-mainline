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


### 第二次 QEMU 验证：两个改进都生效

加上 `clk_ignore_unused pd_ignore_unused` 并更新 init 后重跑：

```
[16.671423] clk: Not disabling unused clocks               ← 从 "Disabling" 变为 "Not disabling"
[16.671775] PM: genpd: Not disabling unused power domains  ← 同上
[17.384674] Run /init as init process
[17.801054] nuwa-init: output bound                        ← 新 init 执行并写了 kmsg
```

| 改进 | 验证结果 |
|---|---|
| `clk_ignore_unused pd_ignore_unused` | ✅ 日志从 "Disabling unused clocks" 变为 "**Not** disabling unused clocks" |
| init 输出设备兜底 | ✅ 出现 `nuwa-init: output bound`（即使 tty0 不存在也写进了 kmsg） |

**这意味着**：真机上即使屏幕不亮，也能从 dmesg/pstore 拿到 `/init` 的执行痕迹，
而不是像之前那样完全静默。

### 本地迭代效率（实测）

| 改动类型 | 耗时 |
|---|---|
| 改 `.config`（大量驱动） | 14 分钟（3155 个 .o 重编译） |
| **只改 initramfs / init** | **30.9 秒**（重打包 + 重链接） |

所以"改 init → 验证 → 再改"这个循环非常快，可以反复试。


## 第十六轮：QEMU 无法验证 ESP 启动（否定结论，避免重复尝试）

### 尝试

想用 QEMU + AAVMF 验证「4 KiB FAT16 能否被 EDK2 的 FatDxe 挂载」：

```bash
qemu-system-aarch64 -M virt -cpu max -m 2G \
  -drive if=pflash,format=raw,readonly=on,file=AAVMF_CODE.fd \
  -drive if=pflash,format=raw,file=vars.fd \
  -drive file=test4k.img,if=none,id=d0,format=raw \
  -device virtio-blk-pci,drive=d0,logical_block_size=4096,physical_block_size=4096 \
  -boot order=d -nographic
```

（ESP 内含 UEFI Shell 作为 `\EFI\BOOT\BOOTAA64.EFI` + `startup.nsh` 自动执行 `map -r`）

### 结果

固件正常启动（`UEFI firmware 2025.11-3ubuntu7.3`），但**70 秒内没有任何 Shell 输出**。

### 正对照（关键）

用 **512 B FAT32**（标准格式）做完全相同的测试 —— **同样没有输出**。

⇒ **结论：不是 4 KiB 扇区的问题，是 AAVMF 在 `-nographic` 下不会自动从 virtio 磁盘启动
`\EFI\BOOT\BOOTAA64.EFI`**。它的 BDS 依赖 NVRAM 里的启动项，而我们没有预置。

### 为什么真机不受影响

nuwa 的 UniXNU **主动扫描所有 SimpleFileSystem 卷**（`UniXNUConfigLoad` +
`AddFallbackLoaders`），不依赖 BDS 的启动顺序。这是两者的根本差别。

### 附带踩到的 QEMU 参数坑

```
Block format 'raw' does not support the option 'logical_block_size'   ← 应放 -device 上
logical_block_size > physical_block_size not supported                ← 两者都要设
```

### 结论

**4 KiB FAT16 是否能被 UFSDxe + FatDxe 挂载，只能真机验证**。QEMU 这条路已排除，
不再重复尝试。


### 补充：EFI stub 路径也无法用 QEMU 验证

```bash
qemu-system-aarch64 -M virt -cpu max -m 2G \
  -drive if=pflash,format=raw,readonly=on,file=AAVMF_CODE.fd \
  -drive if=pflash,format=raw,file=vars.fd \
  -kernel Image -append "console=ttyAMA0 ..." -nographic
```

结果：只有 `UEFI firmware (version 2025.11-3ubuntu7.3)` 一行，60 秒无后续输出。

⇒ AAVMF 的 BDS 在 `-nographic` 下既不从 virtio 磁盘启动 `\EFI\BOOT\BOOTAA64.EFI`，
也不启动 `-kernel` 指定的镜像。

### QEMU 能验证什么 / 不能验证什么（总结）

| 能验证 | 方法 | 结果 |
|---|---|---|
| 内核可启动 | `-kernel Image`（不经 UEFI） | ✅ 通过 |
| initramfs 内嵌 + `/init` 执行 | 同上，看 `Run /init as init process` | ✅ 通过 |
| 防回收参数生效 | 对比 `Disabling` vs `Not disabling unused clocks` | ✅ 通过 |
| init 输出兜底 | 看 `nuwa-init: output bound` | ✅ 通过 |
| 驱动是否内建 | 看 probe 日志（如 `SPI driver fts`） | ✅ 通过 |

| 不能验证 | 原因 |
|---|---|
| ESP/卷能否被挂载 | AAVMF BDS 不启动我们的 ESP（512B 正对照同样失败） |
| 4 KiB FAT16 兼容性 | 同上，且 virtio 与真机 UFS 驱动不同 |
| EFI stub 加载路径 | AAVMF 不启动 `-kernel` 镜像 |
| 任何 SM8550 硬件行为 | QEMU `-M virt` 无对应硬件 |

**结论**：QEMU 已发挥完它的价值（证明内核与 initramfs 可用），剩余全部必须真机。


## ★ 第十七轮：init 输出彻底修好（关键改进）

### 发现的问题

之前 `exec >/dev/tty0` 的做法在真机上有风险：QEMU 里内核报
`Warning: unable to open an initial console`，`/dev/tty0` 存在但**无任何输出**——
用 `grep -c` 统计，init 的用户态输出**一行都没出现**。

如果真机也这样，屏幕上除了内核日志什么都看不到，等于瞎猜。

### 修正：所有输出走 `/dev/kmsg`

```sh
if [ -w /dev/kmsg ]; then
  exec >/dev/kmsg 2>&1
  echo "nuwa-init: bound to /dev/kmsg"
fi
```

**为什么这样更好**：
- `/dev/kmsg` 写入的内容会进内核日志缓冲
- `console=tty0` 时，内核日志本来就会打到屏幕 → **屏幕上能看到**
- 同时 `dmesg` / `pstore` 也有记录 → **即使屏幕不亮也能事后取**
- 不依赖 `/dev/tty0`、`/dev/console` 是否存在

### 同时改进了 USB gadget 段

| 改进 | 原因 |
|---|---|
| 加 `bcdUSB=0x0200` / `bcdDevice` / `MaxPower=250` | 部分主机需要这些描述符才认设备 |
| 循环等 `usb0` 出现（最多 10 秒，每 0.5 秒查一次） | 原来固定 `sleep 2` 可能不够 |
| UDC 为空时打印 `dwc3|udc|phy.*usb` 的 dmesg | 直接定位 USB 控制器为什么没绑定 |
| `telnetd` 启动失败也报错 | 原来失败是静默的 |

### QEMU 验证结果（输出全部可见）

```
[17.925973] nuwa-init: bound to /dev/kmsg
[17.926935] ==============================================
[18.306968] -- 加载驱动模块 --
[29.000908]    !! usb0 未出现（等待 10 秒超时）
[29.095403]    telnetd 已启动 (192.168.0.1:23)
[29.096066] -- 网络接口 --
[29.226851] === 系统就绪：可 telnet 192.168.0.1 ===
```

QEMU 没有 dwc3，所以 `usb0 未出现` 是**正确行为**——检测逻辑工作正常，
真机上如果 dwc3 绑定成功就会看到 `usb0: inet 192.168.0.1/24`。

### 本地迭代效率（再次确认）

| 改动 | 耗时 |
|---|---|
| 只改 init | **30 秒**（重打包 initramfs + 重链接） |

所有镜像已用这个版本的 init 重建。


## 第十八轮：busybox applet 完整性确认

### 一个差点误判的检查

用 `strings busybox | grep -qx "ip"` 检查 applet，结果 **ip / ln / sh / cat / tr 全部 MISS**，
看起来像 busybox 是精简版。**这是错的**——短字符串在二进制里匹配不可靠。

### 正确的做法：在目标环境里跑 `busybox --list`

在 initramfs 里加自检段：

```sh
echo "-- busybox applet 自检 --"
for a in ip ifconfig telnetd insmod mount mkdir ln sh cat sleep; do
  if /bin/busybox --list 2>/dev/null | /bin/busybox grep -qx "$a"; then
    echo "   OK   $a"
  else
    echo "   MISS $a"
  fi
done
```

QEMU 实测结果：

```
[18.921411]    OK   ip
[18.972821]    OK   ifconfig
[19.026533]    OK   telnetd
[19.049667]    OK   insmod
[19.070030]    OK   mount
[19.093954]    OK   mkdir
[19.225785]    OK   ln
[19.246383]    OK   sh
```

**全部存在** ✓ Ubuntu ports 的 `busybox-static` 是全功能版本。

### 顺带解释了一个"假故障"

之前 QEMU 日志里出现 `!! ip 命令不可用或无网卡`，看起来像 applet 缺失。
实际上 **QEMU 的 `-M virt` 没有网卡**，`ip -4 addr show` 对不存在的接口返回非零。
真机上 `usb0` 出现后 `ip` 会正常工作。

### init 现在的兜底链

| 步骤 | 主路径 | 兜底 |
|---|---|---|
| 输出 | `/dev/kmsg`（屏幕 + dmesg 双可见） | `/dev/tty0` → `/dev/console` → `/dev/ttyAMA0` |
| 网卡配置 | `ip link set` + `ip addr add` | `ifconfig usb0 192.168.0.1 netmask 255.255.255.0 up` |
| 网卡状态 | `ip -4 addr show` | `ifconfig usb0` 的 `inet addr` 行 |
| 诊断 | 失败时打印 `dwc3|udc|phy.*usb` 的 dmesg | — |


## 第十九轮：内核配置完整性审查

### 审查结果

| 子系统 | 配置 | 状态 |
|---|---|---|
| **USB gadget** | `USB_DWC3=y` `USB_DWC3_QCOM=y` `USB_GADGET=y` `USB_F_NCM=y` `USB_CONFIGFS=y` `USB_CONFIGFS_NCM=y` `TYPEC=y` `USB_ROLE_SWITCH=y` | ✅ 全内建 |
| **网络** | `NET=y` `INET=y` `PACKET=y` `IP_PNP=y` | ✅ 全内建 |
| **显示** | `FB_EFI=y`（efifb 内建）；`DRM=m` `DRM_SIMPLEDRM=m` `FB_SIMPLE=m`（模块，但 efifb 已够） | ✅ |
| **触控** | `TOUCHSCREEN_ST_FTS_V521_SPI=y` `INPUT_EVDEV=y` | ✅ |
| **电源键** | `POWER_RESET_QCOM_PON=y` | ✅ |
| **存储** | `BLK_DEV_SD=y` `SCSI_UFSHCD=y` `EXT4_FS=y` | ✅ |
| **UFS 控制器** | `SCSI_UFS_QCOM=m` | ⚠️ **本轮改为 `=y`** |
| **GPIO 按键** | `INPUT_GPIO_KEYS` 未设置 | ⚠️ **本轮改为 `=y`**（音量键） |

### 为什么 UFS 要内建

阶段 1 用自包含 initramfs，UFS 不参与启动。但阶段 2 要挂 rootfs 分区
（`root=PARTLABEL=... rootwait`），届时 UFS 控制器必须在早期可用。
如果它是模块而 initramfs 里没有对应 `.ko`，内核根本找不到根分区 —— 正是经验库说的
"驱动编成 `=m` 但镜像里没有模块目录，功能静默缺失"。

提前改成 `=y` 可以避免阶段 2 踩这个坑。

### 音量键

经验库原文：

> 电源键和音量减通常来自 PMIC PON（`pwrkey`/`resin`），
> **音量加常是 PMIC GPIO 上的 `gpio-keys`**。

`POWER_RESET_QCOM_PON=y` 覆盖 pwrkey/resin，但音量加走 `gpio-keys`，需要
`INPUT_GPIO_KEYS=y` + `KEYBOARD_GPIO=y`。


## 第二十轮：nuwa 的 UEFI 内存映射（关键参考）

来自 `uefi-nuwa/Platforms/Xiaomi/nuwaPkg/Library/MemoryMapLib/MemoryMapLib.c`：

```
UEFI FD            0xA7100000  +0x00300000 (3 MB)
UEFI FD Reserved   0xA7400000  +0x00200000
Info Blk           0xA7601000  +0x00001000
MMU PageTables     0xA7602000  +0x00003000
Log Buffer         0xA7605000  +0x00008000
UEFI Stack         0xA760D000  +0x00040000
SEC Heap           0xA764D000  +0x0008C000
Sched Heap         0xA76D9000  +0x00400000
FV Region          0xA7AD9000  +0x00400000
Kernel             0xA8000000  +0x10000000 (256 MB)   ← 内核保留区
Display Reserved   0xB8000000  +0x02B00000 (43 MB)
DXE Heap           0xBAE00000  +0x0D000000 (208 MB)
```

### 与 NUWA-PORT.md 的对应

> `/chosen` `linux,initrd-start` points into the kernel reservation (0xA8000000 + 256 MB)

即内核与 initrd 都在 `0xA8000000` 起的 256 MB 窗口内。

### 一个需要留意的属性

`Kernel` 区的 ArmAttribute 是 **`WRITE_BACK_XN`**（XN = execute-never，不可执行）。

- 如果内核被直接加载到该区并原地执行 → 会被 MMU 拒绝
- 实际路径是 `LoadImage` → UEFI 把 PE 映像复制到 `EfiLoaderCode`（可执行）→ 再 `StartImage`
- 所以正常不受影响；但若出现"加载成功却立刻挂死"，这里是可疑点之一

### 我们的内核尺寸对照

| 项 | 值 |
|---|---|
| 内核 | 44.25 MB |
| Kernel 保留区 | 256 MB |
| 余量 | 充足 ✓ |

### 完整内存映射的意义

这份表解释了为什么 UEFI 路径下硬件起点与 ABL 不同（经验库第 4 条警告）：
显示保留区在 `0xB8000000`（43 MB），DXE 堆在 `0xBAE00000`（208 MB）——
这些区域在 UEFI 退出后仍被占用，内核的 `/reserved-memory` 必须与之一致，
否则会出现"内核把固件还在用的内存当空闲内存分配"的灾难。


### dts 的 reserved-memory 与 UEFI 映射的差异（重要）

社区 dts（`sm8550-xiaomi-nuwa.dts`）**删除了** `sm8550.dtsi` 原有的 reserved-memory，然后重新定义：

```dts
/delete-node/ &reserved_memory;
...
reserved_memory: reserved-memory { ... }
```

重新定义的 25 个区域里，**没有** UEFI 映射中的这两块：

| UEFI 映射 | 地址 | 大小 | dts 里有吗 |
|---|---|---|---|
| Display Reserved | `0xB8000000` | 43 MB | ❌ 没有 |
| DXE Heap | `0xBAE00000` | 208 MB | ❌ 没有 |

**为什么这不成问题**：

UEFI 路径下，内核的内存布局主要来自 **EFI memory map**（`ExitBootServices` 时获取），
而不是 dtb 的 `/reserved-memory`。UEFI 自己会把 Display Reserved / DXE Heap
标记为 `EfiReservedMemoryType`，内核不会去用。

dtb 的 `reserved-memory` 在这里起**补充**作用（标记 UEFI 不认识的厂商区域，如 `qcom,rmtfs-mem`、
`qcom,cmd-db`、`qcom,smem` 等有 `compatible` 的节点）。

**反过来说**：如果走 ABL 路径（无 EFI memory map），内核就只能靠 dtb，
而 dtb 里缺这两块 → 内核可能把显示保留区和 DXE 堆当空闲内存分配 → 画面花屏或直接崩。
**这也是 UEFI 路径的一个隐性优势。**

### 首启要验证的一项

`cat /proc/device-tree/compatible` 应输出：

```
xiaomi,nuwa
qcom,sm8550
```

如果变成 `qcom,sm8550-mtp` 之类，说明 UEFI 改写了根节点（需按经验库"内核早期恢复根身份"处理）。


## ★ 第二十一轮：第四条路径 —— FAT 放进 vendor ramdisk（不依赖 UFS 驱动）

### 线索来源

读 `ShengBootMemoryDxe.c` 的文件头注释：

> Memory and RAM disk from the device tree the previous stage handed over.
> The previous stage (a Linux-style boot loader) passes the physical address of a flattened
> device tree in x0, which SEC keeps in a HOB. ...
>
> - DRAM that no firmware region claims and no reserved-memory node covers is added to the GCD
>   as system memory, up to a fixed amount;
> - **the initrd the loader placed in memory (`/chosen` `linux,initrd-start/-end`) is published
>   as a read-only block device, so a FAT image in the boot image's ramdisk shows up as a normal
>   volume.**

### 同时确认 BootShim 不做这件事

`BootShim.S` 全文只有 849 字节，逻辑就三步：

```asm
_Start:
  mov   x4, x1
  ldr   x5, =FD_BASE        // 0xA7100000
  cmp   x4, x5
  beq   _Entry              // 已在目标地址就直接跳
  ldr   x6, =FD_SIZE
_CopyLoop:
  ldp   x2, x3, [x4], #16   // 把 FD 复制到 0xA7100000
  stp   x2, x3, [x5], #16
  subs  x6, x6, #16
  b.ne  _CopyLoop
_Entry:
  br    x5
```

**它不设置 `/chosen`**。initrd 的信息来自 ABL 提供的 dtb（SEC 存进 HOB）。

### 于是有了第四条路径

ABL 会把 `vendor_boot` 的 ramdisk 加载到内存并写 `/chosen linux,initrd-start`。
如果这个 ramdisk **本身就是一个 FAT 镜像**，UEFI 会把它发布成只读块设备，
FatDxe 就能挂载，UniXNU 就能读到 `\EFI\UniXNU\unixnu.toml`。

**关键优势：整条链路不经过 UFS 驱动。** 块设备在内存里，与分区表、GPT 类型、
UFSDxe 的 LUN 枚举全都无关。

### 已生成的产物

`other/vendor_boot-initrd-esp.img`（71,004,160 B = 67.7 MiB）

```
magic      : VNDRBOOT  v4  page=4096
ramdisk    : 30,904,915 → 67,108,864（FAT32 卷标 NUWAESP，含内核 44.25 MB）
dtb kept   : 3,885,131（8 个 FDT 变体完整保留）
table      : 108
total      : 67.7 MiB（vendor_boot_a 分区 96 MiB，余量充足）
```

新工具 `tools/mk-vendor-boot-ramdisk.py`（替换 ramdisk，保留 dtb/table/bootconfig）。

刷写：`tools/flash-uefi.ps1 -Initrd`

### 五条路径汇总（按可靠性排序）

| # | 路径 | payload 位置 | 依赖 | 镜像 |
|---|---|---|---|---|
| 1 | **ramdisk 块设备** | vendor_boot ramdisk | 只要 ABL 加载 vendor_boot | `vendor_boot-initrd-esp.img` |
| 2 | boot_b 数据分区 | `boot_b`（4 KiB FAT16） | UFSDxe + PartitionDxe + FatDxe | `payload-bootb*.img` |
| 3 | vendor_boot_a 分区 | `vendor_boot_a`（512 B FAT32） | 同上 | `esp-*.img` |
| 4 | UEFI Shell 手动 | 任意可读卷 | 卷可读 + 输入设备 | `esp-shell.img` |
| 5 | rEFInd | 任意可读卷 | 同上 | `esp-refind.img` |

**路径 1 的最大价值**：它把"UFS 驱动能否工作"这个最大未知项**从关键路径上移除了**。


## ★ 第二十二轮：第四条路径被否定，但发现了更好的东西

### 第四条路径（initrd 块设备）在 nuwa 上不可用

读 `ShengBootMemoryDxe.c` 的主流程：

```c
//
// The payload is published from the UFS boot_b partition, and Fat attaches it
// on its own. Every DRAM access made here (GCD scan for the OEM tag, initrd
// remap) faults on nuwa, so keep this switch off until the memory map is
// understood. Set it to TRUE only when the initrd path is being debugged.
//
WriteBootLog (Dtb);

if (mBringUpTouchMemory) {
  AddMemory ((VOID *)(UINTN)Dtb);
  PublishInitrd ((VOID *)(UINTN)Dtb);
} else {
  ReportStatus ("0");
}
```

`mBringUpTouchMemory` **默认 FALSE**，所以 `PublishInitrd` 不会被调用。
原因写得很明确：**GCD 扫描与 initrd remap 在 nuwa 上都会 fault**。

⇒ 上一轮设想的"把 FAT 放进 ramdisk"这条路，**在官方固件里是关闭的**。
要启用必须改源码 + 先解决内存映射问题，不值得在阶段 1 做。

**结论：官方设计就是 payload 放 UFS 的 `boot_b` 分区**，与 NUWA-PORT.md 一致。

### 但发现了 WriteBootLog —— 一个不依赖 console 的诊断手段

`WriteBootLog` 在 `if` 之前调用（**总是执行**），逻辑：

1. 遍历所有 BlockIo 设备
2. 找 `(LastBlock+1) * BlockSize == 192 MiB` 的分区（`boot_a`/`boot_b` 同尺寸）
3. 读第一块，检查偏移 3 处的 8 字节 **OEM 标签是否等于 `MTOO4043`**
4. 命中后，在**最后一块**写入：

```
NUWABOOT count=<N> dtb=0x<addr> started
```

### 我们的 payload OEM 标签原本不匹配

| 工具 | OEM 标签 |
|---|---|
| `mformat`（mtools 4.0.49） | `MTOO4049` ← 我们原来的 |
| `mkfs.vfat` | `mkfs.fat` |
| **UEFI 期望** | **`MTOO4043`** |

已把 `payload-bootb.img` 和 `payload-bootb-efifb.img` 的 OEM 标签 patch 成 `MTOO4043`，
FAT 校验仍然通过。

### 这个诊断的价值

真机上如果屏幕没输出（最坏情况），可以进 TWRP 读 `boot_b` 最后一块：

```
adb push public/nuwa/tools/read-bootlog.sh /tmp/
adb shell sh /tmp/read-bootlog.sh
```

判读：

| 现象 | 含义 |
|---|---|
| 有 `NUWABOOT count=N` 且 N 递增 | UEFI 走到了交接点，内核被启动过（问题在内核侧） |
| 有该字符串但 count 一直是 1 | 内核启动后没重启（可能卡住） |
| 没有该字符串 | UEFI 没走到 WriteBootLog（更早环节失败） |
| 全零 | boot_b 没被识别为 payload（检查 OEM 标签） |

**这是继 pstore 之后的第二个"事后取证"通道**，而且不依赖内核是否活着。


## ★ 第二十三轮：官方支持状态表（重要验证）

来源：`uefi-nuwa/Status.md`（Project Silicium 维护）

```
## Xiaomi 13 Pro
State: Inactive
Codename: nuwa
Contributors: Robotix, Alfa
```

### UEFI Status

| Feature | State |
|---|---|
| Display | ✅ |
| Internal Storage | ✅ |
| Side Buttons | ✅ |
| USB Host Mode | ❌ |
| **USB Device Mode** | ✅ |
| USB Power Delivery | ❌ |
| **Mass Storage** | ✅ |
| Windows Boot | ❌ |
| **Linux Boot** | ✅ |

### OS Status（Linux）

> [!IMPORTANT]
> Linux Requires: [Mainline Kernel](https://github.com/alfaonyt/nuwa-mainline)

| Feature | State |
|---|---|
| **Display** | ✅ |
| **Internal Storage** | ✅（No UFS Deep Sleep） |
| **Side Buttons** | ✅ |
| GPU | ❌ |
| Speakers | ❌ |
| Microphone | ❌ |
| Camera | ❌ |
| Mobile Data | ❌ |
| Vibration | ❌ |
| 各类传感器 / 指纹 / NFC | ❌ |

### 这份表验证了我们的每一个技术选择

| 我们的选择 | 官方状态 | 结论 |
|---|---|---|
| 走 UEFI 路线 | **Linux Boot ✅** | 社区已验证可行 |
| 用 `alfaonyt/nuwa-mainline` 内核 | 官方明确要求这个内核 | 一致 |
| **nodrm（不启用 msm）** | **GPU ❌** | **完全正确** —— GPU 不可用，只能借用固件画面 |
| NCM USB 设备模式 | **USB Device Mode ✅** | 一致 |
| 不用 USB Host / WinPE | USB Host ❌ / Windows Boot ❌ | 之前判断正确 |
| 不用 UFS 深度睡眠 | 官方特别标注 "No UFS Deep Sleep" | 社区内核已有该补丁（`cc09da1a HACK: Disable UFS deep sleep`） |

### 需要下调期望的部分

**首版范围要按这份表调整**：

| v1 原计划 | 官方状态 | 现实 |
|---|---|---|
| 启动 | ✅ | 可行 |
| 显示 | ✅ | 可行（借用固件画面） |
| 触控 | 表里没列，但 Side Buttons ✅ 说明输入子系统可用 | 待验证 |
| USB 网络 | ✅（USB Device Mode） | 可行 |
| Wi-Fi/BT | 表里没列 | 未知 |
| **音频** | **Speakers ❌ / Microphone ❌** | **官方认为不可用** |

⇒ **音频不应作为 v1 的硬指标**。用户原本的 v1 范围包含音频，但社区状态显示扬声器和麦克风都不工作。
这是需要向用户说明的现实约束。


## 第二十四轮：UniXNU 的启动实现（确认我们的配置正确）

`package/UniXNUPkg/Library/UniXNULib/Boot.c`：

```c
// efi and linux: a Linux kernel with the EFI stub is an EFI image whose
Path = UniXNUResolveImagePath (Entry->Volume, Entry->Path);
Image = NULL;
Status = gBS->LoadImage (FALSE, ImageHandle, Path, NULL, 0, &Image);
...
Status = gBS->StartImage (Image, &ExitDataSize, &ExitData);
```

### 三条确认

| # | 确认 | 对我们的意义 |
|---|---|---|
| 1 | `type = "efi"` 与 `type = "linux"` **走同一条路径** | 不必纠结用哪个；我们的 `efi` 正确 |
| 2 | `LoadImage` 的 `LoadOptions = NULL`、长度 0 | **内核收到空 cmdline** → 必须靠 `CONFIG_CMDLINE` 内建（我们已做） |
| 3 | 路径经 `UniXNUResolveImagePath (Entry->Volume, Entry->Path)` | 绝对路径 `\\EFI\\BOOT\\BOOTAA64.EFI` 可解析 |

### 这排除了一整类怀疑

之前担心过"是不是 entry type 写错"、"是不是 cmdline 没传进去"——
现在确认：**type 怎么写都一样，cmdline 本来就不会传**。所以：

- 内核必须自带 cmdline ✓（`CONFIG_CMDLINE="console=tty0 ignore_loglevel loglevel=7 keep_bootcon clk_ignore_unused pd_ignore_unused"`）
- 内核必须自带 initramfs ✓（`CONFIG_INITRAMFS_SOURCE`）
- 内核必须自己找 dtb ✓（EFI 配置表里的 FdtBlob，由 `DtPlatformDxe` 提供）

### 剩下唯一的未知

**卷能否被 FatDxe 挂载** —— 这是整条链路上唯一还没验证的环节。
其余每一步（BootShim 复制 FD、UEFI 启动、UniXNU 加载配置、LoadImage、内核 EFI stub、initramfs 解压、/init 执行）
都已有代码级或 QEMU 级的证据。


## ★ 第二十五轮：4 KiB FAT16 的 EDK2 兼容性已离线证明

### 源码级依据

`FatPkg/EnhancedFatDxe/Fat.h`：

```c
#define MAX_BLOCK_ALIGNMENT                12    // 2^12 = 4096
#define MIN_BLOCK_ALIGNMENT                9     // 2^9  = 512
#define MAX_SECTORS_PER_CLUSTER_ALIGNMENT  7
```

`FatPkg/EnhancedFatDxe/Init.c` 的 `FatOpenDevice` 检查：

```c
if ((FatBs.FatBsb.ReservedSectors == 0) || (FatBs.FatBsb.NumFats == 0) || (Sectors == 0)) {
  return EFI_UNSUPPORTED;
}
if ((FatBs.FatBsb.SectorSize & (FatBs.FatBsb.SectorSize - 1)) != 0) {   // 必须是 2 的幂
  return EFI_UNSUPPORTED;
}
BlockAlignment = (UINT8)HighBitSet32 (FatBs.FatBsb.SectorSize);
if ((BlockAlignment > MAX_BLOCK_ALIGNMENT) || (BlockAlignment < MIN_BLOCK_ALIGNMENT)) {
  return EFI_UNSUPPORTED;     // 必须在 512..4096 之间
}
if ((FatBs.FatBsb.SectorsPerCluster & (FatBs.FatBsb.SectorsPerCluster - 1)) != 0) {
  return EFI_UNSUPPORTED;
}
```

**关键：`MAX_BLOCK_ALIGNMENT = 12`，也就是 4096 —— 我们的扇区大小正好是允许的上限。**

### 逐项核对我们的 payload

`other/payload-bootb-efifb.img`：

| # | 检查项 | 实际值 | 结果 |
|---|---|---|---|
| 1 | `ReservedSectors != 0` | 1 | PASS |
| 2 | `NumFats != 0` | 2 | PASS |
| 3 | `Sectors != 0` | 49152 | PASS |
| 4 | `SectorSize` 是 2 的幂 | 4096 | PASS |
| 5 | `BlockAlignment` 在 9..12 | 12 | **PASS（正好上限）** |
| 6 | `SectorsPerCluster` 是 2 的幂 | 1 | PASS |
| 7 | `SPCA <= 7` | 0 | PASS |
| 8 | `Media` 规则 | 0xF8 | PASS |
| 9 | Fat16 `RootEntries != 0` | 4096 | PASS |

**九项全过 → 4 KiB FAT16 在 EDK2 FatPkg 层面完全兼容。**

### 这把风险从"未知"降级为"只差一个环节"

| 环节 | 状态 |
|---|---|
| FAT 格式合法性 | ✅ 源码级 + 逐项验证 |
| EDK2 FatPkg 支持 4 KiB | ✅ `MAX_BLOCK_ALIGNMENT=12` |
| 我们的 payload 通过全部检查 | ✅ 九项 PASS |
| **UFSDxe 是否正确暴露 boot_b 的 BlockIo** | ⚠️ **唯一剩余未知** |

UFSDxe 是 `Binaries/nuwa/QcomPkg/Drivers/UFSDxe/UFSDxe.inf`（预编译，无源码），
所以它的行为只能真机观察。但即使它有问题，还有 512 B FAT32 的路径
（`esp-*.img` 刷到 `vendor_boot_a`）可以试 —— 那种格式在所有 UEFI 实现里都是最保险的。


## ★ 第二十六轮：DXE 驱动清单揭示的两件事

### 1. 显示用的是完整高通 DisplayDxe，不是 SimpleFbDxe

`nuwaPkg/Include/DXE.inc`：

```
!if $(USE_CUSTOM_DISPLAY_DRIVER) == 1
  INF Binaries/nuwa/QcomPkg/Drivers/DisplayDxe/DisplayDxe.inf
!else
  INF SiliciumPkg/Drivers/SimpleFbDxe/SimpleFbDxe.inf
!endif
```

`nuwaPkg/nuwa.dsc`：

```
USE_CUSTOM_DISPLAY_DRIVER      = 1
```

⇒ **我们的固件走 DisplayDxe**：完整初始化 DSI/DSC/面板，提供正确的 1440x3200 GOP framebuffer。
这比 SimpleFbDxe 可靠，也解释了为什么 UEFI 界面显示正常。

**对内核的意义**：UEFI 已经把面板点亮并让显示控制器循环扫描一块内存，
内核只要继承这个 framebuffer 就能出图（efifb / simpledrm 都行）。
**但硬件起点是 DisplayDxe 建立的，与 ABL 交接时不同** —— 这正是经验库第 4 条警告的具体内容。

### 2. PIL 被禁用 —— 这解释了音频/传感器为什么不可用

```
// INF Binaries/nuwa/QcomPkg/Drivers/PILDxe/PILDxe.inf   # probe: PIL needs a matching
//     uefipil.cfg entry and panics otherwise; not needed for the menu
// INF Binaries/nuwa/QcomPkg/Drivers/PILProxyDxe/PILProxyDxe.inf
```

**PIL（Peripheral Image Loader）负责加载各子系统固件**（ADSP、CDSP、modem、GPU 等）。
它被注释掉，理由是"需要匹配的 uefipil.cfg，否则会 panic"。

后果与官方状态表**完全对应**：

| 子系统 | 需要 PIL 加载固件 | 官方状态 |
|---|---|---|
| 音频（ADSP） | ✅ 需要 | **Speakers ❌ / Microphone ❌** |
| 传感器 | ✅ 需要 | **全部 ❌** |
| 移动数据（modem） | ✅ 需要 | **Mobile Data ❌** |
| GPU | ✅ 需要 | **GPU ❌** |
| 相机 | ✅ 需要 | **Camera ❌** |

**这不是我们的驱动写错了，而是 UEFI 固件本身就没启用 PIL。**
要让音频工作，需要先解决 `uefilpil.cfg` 的配置问题——这是一个独立的、可能很深的子任务。

### 完整可用的 DXE 驱动（对内核有意义的部分）

| 驱动 | 作用 | 对 Linux 的影响 |
|---|---|---|
| `UFSDxe` | UFS 存储 | 决定 payload 卷能否被读 |
| `DisplayDxe` | 完整显示 | 提供 GOP framebuffer |
| `UsbfnDwc3Dxe` | USB device 控制器 | UEFI 阶段的 USB device |
| `UsbConfigDxe` / `UsbDeviceDxe` / `UsbMsdDxe` | USB 配置与 Mass Storage | U 盘模式 |
| `ButtonsDxe` | 按键 | 音量键/电源键在 UEFI 里可用 |
| `TLMMDxe` / `I2CDxe` / `SPIDxe` / `GpiDxe` | 引脚/I2C/SPI/GPI | UEFI 阶段外设总线 |
| `SPMIDxe` / `RpmhDxe` / `ClockDxe` / `VcsDxe` | PMIC 与时钟 | 电源/时钟初始化 |
| `HALIOMMUDxe` | IOMMU | 影响 DMA |
| `TsensDxe` / `DDRInfoDxe` | 温度/内存信息 | 诊断用 |

**注意**：这些是 UEFI 阶段的驱动，它们建立的硬件状态会被内核继承（或在 `ExitBootServices` 时被内核重置）。


## 第二十七轮：最小诊断镜像已通过 QEMU 验证

### 设计

`tools/init-min`：

```sh
#!/bin/busybox sh
mkdir -p /proc /sys /dev /tmp
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
echo "nuwa-min: start $(cat /proc/uptime)" > /dev/kmsg
sleep 120
echo "nuwa-min: timeout, rebooting" > /dev/kmsg
reboot -f
```

只做三件事：挂载、打一行、超时重启。没有任何可能出错的环节（不碰 configfs、不建 gadget、不启 telnetd）。

### QEMU 验证结果

```
[17.006898] Run /init as init process
[17.383205] nuwa-min: start 9.04 2.33
```

- `/init` 被执行 ✓
- 打印了 uptime ✓
- **没有** `nuwa-init`、`busybox applet` 等完整版特征 ✓（说明确实是精简版）

### 产物

`other/payload-bootb-min.img`（192 MiB，4 KiB FAT16，卷标 NUWAMIN，OEM=MTOO4043）
`other/bootefi-efifb/BOOTAA64-MIN.EFI`（44.25 MiB）

刷写：`tools/flash-uefi.ps1 -Min`

### 它在真机上的判读价值

| 屏幕表现 | 结论 |
|---|---|
| 出现 `nuwa-min: start <uptime>` | **内核 + initramfs + /init 全链路正常** → 问题一定在完整 init 的某个功能里 |
| 有内核日志但无 `nuwa-min` | initramfs 没解开，或 `/init` 没执行 |
| 黑屏有背光 | 内核没起 / 显示没继承 |
| 全黑无反应 | UEFI 根本没加载到内核 |

**这是把"黑屏"这个模糊现象拆成四层的第一把手术刀。**


## 第二十八轮：屏幕旋转（NUWA-PORT 的 Known gaps 命中）

`NUWA-PORT.md` 的 Known gaps 里有一条直接影响我们的 Linux：

> The framebuffer is **rotated 90 degrees** (legacy display orientation / unit scale).

nuwa 的面板是 1440x3200 竖屏，但 UEFI 的 DisplayDxe 提供的 framebuffer 是横向的
（3200x1440）。如果内核直接用它，屏幕上的文字会是躺倒的。

### 修正

cmdline 增加 `fbcon=rotate:1`：

```
console=tty0 ignore_loglevel loglevel=7 keep_bootcon clk_ignore_unused pd_ignore_unused fbcon=rotate:1
```

`fbcon` 的 rotate 取值：0=正常，1=90°，2=180°，3=270°。先用 1。

### 验证

```bash
strings BOOTAA64-EFIFB.EFI | grep "fbcon=rotate"
# 输出：console=tty0 ... fbcon=rotate:1
```

确认 cmdline 已内嵌进内核映像。

### 如果方向不对

真机上如果发现文字是倒的或另一个方向，改这一个数字即可：

| 现象 | 改成 |
|---|---|
| 文字躺倒、顶部在左 | `fbcon=rotate:1`（当前） |
| 文字倒置 | `fbcon=rotate:2` |
| 文字躺倒、顶部在右 | `fbcon=rotate:3` |
| 本来就是正的 | 去掉该参数 |

改完只需重新 `make Image`（30 秒）+ 重建镜像。

### 注意

这只影响 **fbcon（文本控制台）**。以后 GNOME 起来后，Wayland 的旋转由
`/etc/xdg/monitors.xml` 或 mutter 的 transform 控制，与 fbcon 无关。


### 附带发现并修正的一个隐藏问题

检查 CI workflow 时发现**两个 job 的 cmdline 不一致**：

```
job1 (bootefi)      : console=tty0 ignore_loglevel loglevel=7
job2 (bootefi-nodrm): console=tty0 ... keep_bootcon clk_ignore_unused pd_ignore_unused
```

**job1（正常版内核）一直缺少 `clk_ignore_unused pd_ignore_unused`**。
这意味着之前构建的"正常版"内核没有防资源回收保护 —— 如果真机用它，
显示资源可能在 2–3 秒后被回收导致黑屏，而 nodrm 版因为有参数所以不会。

现在两个 job 的 cmdline 已统一为：

```
console=tty0 ignore_loglevel loglevel=7 keep_bootcon clk_ignore_unused pd_ignore_unused fbcon=rotate:1
```

**这也说明为什么之前推荐 nodrm 版是对的**（它一直带着正确的参数）。


## 第二十九轮：PIL 的启用条件已查明

### 其他设备确实启用 PIL

扫描 `uefi-nuwa` 里全部 86 个 `DXE.inc`：

| 设备 | PILDxe / PILProxyDxe |
|---|---|
| Asus i005d | ✅ 启用（PILProxyDxe） |
| LG mh2 | ✅ 启用（PILDxe） |
| Lenovo 9707f | ✅ 启用（PILDxe） |
| Lenovo j706f | ✅ 启用（PILDxe） |
| Motorola caprip | ❌ 注释掉 |
| **Xiaomi nuwa** | ❌ 注释掉 |

⇒ **PIL 本身是可用的**，nuwa 只是被注释掉了。

### nuwa 被注释的原因

```
// INF Binaries/nuwa/QcomPkg/Drivers/PILDxe/PILDxe.inf   # probe: PIL needs a matching
//     uefipil.cfg entry and panics otherwise; not needed for the menu
```

**关键在 "needs a matching uefipil.cfg entry"**。

### uefipil.cfg 不在仓库里

搜索 `uefi-nuwa` 全部文件：没有 `uefipil.cfg`，也没有其他 `.cfg`。

⇒ 它要么在 `Binaries/nuwa/` 的预编译资源里（不在 git 里），
要么需要**从原厂固件分区提取**。

### 这对音频意味着什么

要启用 PIL 需要两步：

1. 取消 `DXE.inc` 里 PILDxe 的注释
2. 提供匹配的 `uefipil.cfg`（描述 ADSP/CDSP/modem 等固件的位置与名称）

**第 2 步是真正的障碍**：需要从原厂设备提取配置，而 nuwa 的固件布局只有高通/小米知道。
猜错会 panic（注释里明说 "panics otherwise"）。

### 结论：音频不在 v1 范围内

| 项 | 状态 |
|---|---|
| PIL 驱动本身 | ✅ 社区其他设备可用 |
| nuwa 的 PIL 配置 | ❌ 缺失，需从原厂提取 |
| 风险 | 配置错误会 panic（不是静默失败） |
| 工作量 | 未知，可能需要反解原厂 UEFI |

**建议**：v1 先把启动 + 显示 + 触控 + USB 网络做通。音频作为 v2 的独立子任务，
前提是先从原厂提取到 `uefipil.cfg`。


## ★ 第三十轮：4 KiB FAT 与 BlockIo 块大小的解耦（最后一个疑虑消除）

### 担心的问题

如果 UFSDxe 报告的 `BlockIo->Media->BlockSize` 是 512，
而我们的 FAT BPB 说 `SectorSize = 4096`，会不会不匹配导致读错？

### 源码答案：不会

`FatPkg/EnhancedFatDxe/DiskCache.c`：

```c
DiskCache[CacheFat].BlockSize  = Volume->BlockIo->Media->BlockSize;
DiskCache[CacheData].BlockSize = Volume->BlockIo->Media->BlockSize;
```

磁盘缓存直接采用 **BlockIo 的块大小**，与 FAT 的 `SectorSize` 无关。

而所有读写偏移都是**字节偏移**：

```c
Bit     = Offset / DiskCache->BlockSize;          // 字节偏移 → BlockIo LBA
LastBit = (Offset + Length - 1) / DiskCache->BlockSize;
```

FAT 的 `SectorSize` 只参与**簇号 ↔ 字节偏移**的换算（`BlockAlignment = HighBitSet32(SectorSize)`），
换算完成后交给 BlockIo 时已经变成字节偏移，再由 BlockIo 自己的块大小折算成 LBA。

### 结论

| BlockIo 块大小 | FAT SectorSize | 能否工作 |
|---|---|---|
| 512 | 512 | ✅ |
| 512 | **4096** | ✅ **字节偏移转换，自动适配** |
| 4096 | 4096 | ✅ |
| 4096 | 512 | ✅ |

**这意味着 4 KiB FAT16 无论 UFSDxe 报什么块大小都能挂载**，
前提只是"能读到分区数据"（即 UFSDxe 正确暴露了 boot_b 的 BlockIo）。

### 风险进一步收窄

| 环节 | 状态 |
|---|---|
| FAT 格式合法性 | ✅ 九项检查全过 |
| EDK2 支持 4 KiB 扇区 | ✅ `MAX_BLOCK_ALIGNMENT=12` |
| **FAT 扇区大小与 BlockIo 块大小解耦** | ✅ **本轮源码确认** |
| UFSDxe 能否读到 boot_b | ⚠️ 唯一剩余未知（预编译二进制，只能真机观察） |

现在剩下的问题纯粹是"UFSDxe 有没有把 boot_b 暴露出来"，
不再是"格式对不对"的问题。


## 第三十一轮：boot_b 的 GPT 类型不影响枚举

### 问题

`boot_b` 的 GPT 类型 GUID 是 Android 的 "boot" 类型，**不是** EFI System Partition。
PartitionDxe 会不会因此跳过它？

### 答案：不会

`MdeModulePkg/Universal/Disk/PartitionDxe/Partition.c`（46 KB）里
**没有任何按分区类型过滤的逻辑**。它的行为是标准的：

1. 遍历 GPT/MBR 分区表
2. 为**每一个**分区创建子 BlockIo 句柄（`PartitionInstallChildHandle`）
3. 在子句柄上挂 DevicePath（含分区号）

FatDxe 随后会尝试在**每个** BlockIo 上解析 FAT 引导扇区，
解析成功的才挂载为文件系统卷。

### 这意味着什么

| 疑问 | 答案 |
|---|---|
| boot_b 类型是 "boot" 不是 ESP，会被跳过吗？ | **不会**，PartitionDxe 不看类型 |
| 需要把 boot_b 的 GPT 类型改成 ESP 吗？ | **不需要** |
| `tools/twrp-set-esp-type.sh` 还有用吗？ | 只在某些固件的 BDS 只从 ESP 类型分区启动时有用；我们的 UniXNU 是主动扫描，用不上 |

### 至此，4 KiB FAT16 路径的每一环都有依据

| 环节 | 依据 | 状态 |
|---|---|---|
| UFSDxe 暴露整个 UFS 磁盘 | `DXE.inc` 里 `INF Binaries/nuwa/QcomPkg/Drivers/UFSDxe/UFSDxe.inf` | ✅ 存在 |
| PartitionDxe 为 boot_b 创建 BlockIo | 源码无类型过滤 | ✅ |
| FatDxe 解析 FAT 引导扇区 | 九项检查全过 | ✅ |
| 4 KiB 扇区被接受 | `MAX_BLOCK_ALIGNMENT=12` | ✅ |
| FAT 扇区与 BlockIo 块大小解耦 | `DiskCache.c` 用 BlockIo 的块大小 | ✅ |
| 卷被 UniXNU 枚举 | `AddFallbackLoaders` 遍历所有 SimpleFileSystem | ✅ |
| 内核被加载执行 | QEMU 端到端验证 | ✅ |

**唯一无法离线确认的只剩一件事**：UFSDxe 这个预编译二进制在 nuwa 上是否真的初始化成功
（它的内部行为无源码可查）。但这是"驱动能不能跑"的问题，不是"格式对不对"的问题。


## 第三十二轮：经验库的九个通用故障模式（对照我们的项目）

`experience/patterns.md` 归纳了九类反复出现的故障模式。逐条对照：

| 模式 | 我们的情况 |
|---|---|
| **A. bootloader 改了你以为没变的东西** | ⚠️ 已识别：compatible 可能被改写；首启要 `cat /proc/device-tree/compatible` 验证 |
| B. 资源没有真正的拥有者 | ⚠️ 相关：`clk_ignore_unused pd_ignore_unused` 就是"没人声明拥有"的资源 |
| C. 时序和生命周期不对 | ⚠️ 相关：DisplayDxe 建立的显示状态与 ABL 不同 |
| **D. 残留状态让结果失真** | ✅ 已规避：payload 用 `dd` 全量覆盖 192 MiB，无尾部残留 |
| E. 测量方法本身错了 | ✅ 已有纪律：空输出判失败、正对照（512B vs 4KiB） |
| F. 底层通过不等于用户能用 | ✅ 已内化：状态词分层（离线通过 ≠ 真机通过） |
| G. 上游或发行版已经修了 | ✅ 用的是社区验证过的 7.0 内核 |
| H. 别人的实现不能整搬 | ✅ 只借 UEFI 引导层，内核用主线 |
| **I. 恢复路径本身不可靠** | ⚠️ **本轮改进** |

### 模式 I 的具体命中与修正

原文：

> **怎么认出来**：计时到了没回去；正常重启卡在关机；设备不可达只能等人按键。
> **通用处理**：恢复路径的每一步都有时限（`sync` 限时、`reboot -f -n`），并在最终组合上实测过。

我们的 init 原来是：

```sh
/bin/busybox sleep 120
/bin/busybox reboot -f
```

`reboot -f` 会先 sync 再重启。如果 USB gadget 或某个块设备在 sync 阶段卡住，
**设备就停在"要重启但没重启"的状态**——既不在 Linux 也不在 fastboot，只能长按电源。

**已改为**：

```sh
/bin/busybox sleep 120
echo "nuwa-init: timeout, rebooting (force, no sync)" > /dev/kmsg
/bin/busybox reboot -f -n 2>/dev/null || /bin/busybox reboot -f
```

`-n` 表示**不 sync**，直接复位。因为我们只读不写，不同步没有数据风险，
但能避免卡在 sync。带 `||` 兜底，万一 busybox 版本不支持 `-n` 仍会执行 `-f`。

### 模式 A 的补充纪律

原文：

> **凡是会被改写的属性都不要用来判断设备。**

具体到我们：

| 不要依赖 | 改用 |
|---|---|
| 根 `compatible` 判断机型 | 用 `qcom,msm-id`/`board-id` 或直接读 `/proc/device-tree/model` 并做兜底 |
| `/proc/cmdline` 判断启动来源 | 用 `/sys/firmware/efi` 是否存在 |
| 槽位属性位判断 A/B | 用 bootloader 自己的 `--set-active` |


## ★ 第三十三轮：发现一个可能直接导致真机黑屏的配置错误

### 线索

`experience/bootloader-and-boot.md` 里有一个标【高频】的坑：

> **内核命令行来自设备树 `/chosen/bootargs`，而且有长度上限，超长部分被静默截断**
> 现象：改镜像头里的 cmdline 不生效；或者命令行末尾的模块黑名单失效，被屏蔽的驱动照样加载。
> 原因：ABL 读设备树的 bootargs 并原地追加几百字节自己的参数。

### 检查我们采集过的运行时设备树

`private/fdt-runtime.dts`（1.6 MB，之前从设备采集）里的 `/chosen`：

```dts
chosen {
    linux,initrd-end = <0x00 0xb7ffe540>;
    linux,initrd-start = <0x00 0xb5fea000>;
    kaslr-seed = <0x00 0x00>;
    bootargs = "console=ttyMSM0,115200n8 kpti=0 ... loglevel=6 ... init=/init
                ... msm_drm.dsi_display0=qcom,mdss_dsi_m2_38_0c_0a_dsc_cmd: ...
                block2mtd.block2mtd=/dev/block/sda16,2097152 ...";
};
```

**bootargs 长达约 1100 字符**，是 ABL 塞进去的。

### 致命点：我们的内核配置

```
CONFIG_CMDLINE_FROM_BOOTLOADER=y
```

这个选项意味着：**内核优先使用 bootloader 传来的 cmdline，忽略 `CONFIG_CMDLINE`**。

而 UniXNU 是 `LoadImage(FALSE, ImageHandle, Path, NULL, 0, &Image)` —— **LoadOptions 为空**，
于是内核退回读设备树的 `/chosen/bootargs`，也就是 **ABL 那 1100 字符**。

**后果**：我们在 `CONFIG_CMDLINE` 里写的所有参数全部不生效：

| 参数 | 本意 | 真机实际 |
|---|---|---|
| `console=tty0` | 输出到屏幕 | ❌ 被 ABL 的 `console=ttyMSM0,115200n8` 取代 |
| `clk_ignore_unused` | 防显示资源被回收 | ❌ 不生效 |
| `pd_ignore_unused` | 同上 | ❌ 不生效 |
| `fbcon=rotate:1` | 屏幕旋转 | ❌ 不生效 |
| `keep_bootcon` | 保留 bootconsole | ❌ 不生效 |
| `loglevel=7` | 详细日志 | ❌ 被 ABL 的 `loglevel=6` 取代 |

**这完全能解释"真机黑屏但 QEMU 正常"** —— QEMU 里没有 dtb bootargs，所以内核用了 `CONFIG_CMDLINE`。

### 修复：必须用 CMDLINE_FORCE（arm64 没有 EXTEND）

**关键发现**：arm64 的 Kconfig choice **只有两项**，没有 `CMDLINE_EXTEND`：

```kconfig
# arch/arm64/Kconfig:2540
choice
    prompt "Kernel command line type"
    depends on CMDLINE != ""
    default CMDLINE_FROM_BOOTLOADER

config CMDLINE_FROM_BOOTLOADER
    bool "Use bootloader kernel arguments if available"

config CMDLINE_FORCE
    bool "Always use the default kernel command string"
endchoice
```

（`CMDLINE_EXTEND` 只存在于 powerpc 和部分架构的 Kconfig 里。）

所以 `--enable CMDLINE_EXTEND` 在 arm64 上是**无效选项**，
`olddefconfig` 会把它丢掉并重新选 default（`FROM_BOOTLOADER`）。
这也解释了第一次修复为什么没生效。

**正确做法**：

```
# CONFIG_CMDLINE_FROM_BOOTLOADER is not set
CONFIG_CMDLINE_FORCE=y
CONFIG_CMDLINE="console=tty0 ignore_loglevel loglevel=7 keep_bootcon clk_ignore_unused pd_ignore_unused fbcon=rotate:1"
```

**注意**：`scripts/config --disable CMDLINE_FROM_BOOTLOADER` 也**不能**可靠工作
（choice 型选项需要同时写 `# ... is not set` 和选中另一项），
必须直接编辑 `.config` 里的那三行。

### FORCE 的代价：丢失 ABL 的有用参数

ABL 的 bootargs 里有一些本来有用的东西：

| ABL 参数 | 作用 | 我们是否需 |
|---|---|---|
| `msm_drm.dsi_display0=qcom,mdss_dsi_m2_38_0c_0a_dsc_cmd:` | 指定面板 | **不需要**（我们禁用 msm） |
| `msm_drm.oled_wp=0bb00c46` | OLED 白点校准 | **不需要**（同上） |
| `rootwait ro init=/init` | 根文件系统与 init | **不需要**（initramfs 自带，默认就是 `/init`） |
| `loglevel=6` | 日志级别 | 我们用自己的 `loglevel=7` |
| `block2mtd...` | MTD 模拟 | **不需要**（甚至有害） |
| `silent_boot.mode=nonsilent` | 原厂启动画面 | 不需要 |

⇒ 阶段 1（自包含 initramfs + efifb）**完全可以丢弃 ABL 的 bootargs**，用 FORCE 更干净。

**如果将来需要 ABL 的某个参数**（例如阶段 2 要用 `msm_drm.dsi_display0` 做原生显示），
届时改成 `FROM_BOOTLOADER` 并把这些参数写进 CONFIG_CMDLINE 里，或者用 UniXNU 的
`[[dt_patch]]` 直接改 dtb 的 `/chosen/bootargs`。

### 长度检查

| 项 | 长度 |
|---|---|
| ABL bootargs | ~1100 字符 |
| 我们的 CONFIG_CMDLINE | 118 字符 |
| 合计 | ~1218 字符 |
| arm64 `COMMAND_LINE_SIZE` | **2048** |

⇒ 能装下，不会被截断。

### 已同步修改

- 本地 `.config`
- CI `build-bootefi.yml` 的两个 job 都加了 `--disable CMDLINE_FROM_BOOTLOADER`

### 这条发现的份量

之前所有 QEMU 验证都是在"没有 dtb bootargs"的条件下做的，所以 `console=tty0`、
`clk_ignore_unused` 都工作。**真机条件下这些参数全被忽略** —— 这是"QEMU 通过但真机黑屏"
最合理的解释之一。如果真机黑屏的原因是这个，那这次修复就直接解决它。


### 验证：FORCE 确实生效

用 **空 `-append`** 跑 QEMU（这样内核不可能从 bootloader 拿到任何参数）：

```bash
qemu-system-aarch64 -M virt -cpu max -m 2G -smp 2 \
  -kernel arch/arm64/boot/Image -append "" -nographic
```

日志：

```
[    0.000000] Kernel command line: console=tty0 console=ttyAMA0 ignore_loglevel loglevel=7 keep_bootcon clk_ignore_unused pd_ignore_unused fbcon=rotate:1
[   17.892494] Run /init as init process
[   18.392655] nuwa-init: bound to /dev/kmsg
```

**`-append` 是空的，内核命令行却是完整的** ⇒ `CONFIG_CMDLINE_FORCE` 确实生效，
不再依赖 bootloader 传参。这是修复有效的硬证据。

### 双 console 策略

cmdline 里放了两个 console：

```
console=tty0 console=ttyAMA0 ...
```

内核的行为正好满足两边需求：

| 环境 | `tty0` | `ttyAMA0` | 实际输出到 |
|---|---|---|---|
| **真机** | 存在 ✓ | 不存在（内核跳过） | **tty0 屏幕** |
| **QEMU** | 不存在（跳过） | 存在 ✓ | **ttyAMA0 串口** |

这样一个 cmdline 同时服务真机和 QEMU 验证，不需要维护两份配置。

### 这条修复的完整链条

```
ABL 往 dtb 的 /chosen/bootargs 塞 1100 字符
    ↓
UniXNU LoadImage(..., NULL, 0, ...) → LoadOptions 为空
    ↓
内核 CMDLINE_FROM_BOOTLOADER=y → 退回读 dtb bootargs
    ↓
CONFIG_CMDLINE 里的 console=tty0 / clk_ignore_unused / fbcon=rotate:1 全部失效
    ↓
真机：无屏幕输出 + 显示资源被回收 → 黑屏
```

修复后：

```
CONFIG_CMDLINE_FORCE=y → 忽略 bootloader 参数，强制用 CONFIG_CMDLINE
    ↓
console=tty0 生效 → 屏幕有输出
clk_ignore_unused 生效 → 显示资源不被回收
fbcon=rotate:1 生效 → 文字方向正确
```


### 配套检查：fbcon 的依赖链是否完整

`fbcon=rotate:1` 要生效，需要整条链都编进内核。逐项核对：

| 配置 | 值 | 作用 |
|---|---|---|
| `CONFIG_FB=y` | ✅ | framebuffer 子系统 |
| `CONFIG_FB_EFI=y` | ✅ | efifb（继承 UEFI 的 framebuffer） |
| `CONFIG_FB_CORE=y` | ✅ | fb 核心 |
| `CONFIG_FB_CFB_FILLRECT` / `COPYAREA` / `IMAGEBLIT` | ✅ | 软件渲染原语 |
| `CONFIG_VT=y` | ✅ | 虚拟终端 |
| `CONFIG_VT_CONSOLE=y` | ✅ | VT 作为 console |
| `CONFIG_FRAMEBUFFER_CONSOLE=y` | ✅ | **fbcon 本体** |
| `CONFIG_FRAMEBUFFER_CONSOLE_DETECT_PRIMARY=y` | ✅ | 自动检测主显示 |

⇒ `fbcon=rotate:1` 有完整的执行环境。

### FORCE 丢弃的 ABL 参数逐项核对

| ABL 参数 | 丢弃后影响 |
|---|---|
| `console=ttyMSM0,115200n8` | 无 —— 我们用 `console=tty0`（屏幕）和 `console=ttyAMA0`（QEMU） |
| `rootwait ro init=/init` | 无 —— initramfs 不需要 root，默认 init 就是 `/init`（QEMU 日志已验证 `Run /init as init process`） |
| `loglevel=6` | 无 —— 我们用 7（更详细） |
| `msm_drm.dsi_display0=...` | 无 —— 我们禁用 `DRM_MSM`，显示走 efifb |
| `msm_drm.oled_wp=0bb00c46` | 无 —— 同上 |
| `qcom_geni_serial.con_enabled=0` | 无 —— 不用 GENI 串口 |
| `block2mtd.block2mtd=/dev/block/sda16` | 无 —— 甚至有害（会把分区当 MTD） |
| `silent_boot.mode=nonsilent` | 无 —— 原厂启动画面控制 |
| `kpti=0` / `kasan=off` 等 | 无 —— 性能/调试调优，我们用默认 |
| `video=vfb:640x400,bpp=32` | 无 —— 虚拟 framebuffer，不需要 |

**结论**：FORCE 丢弃的参数对阶段 1（自包含 initramfs + efifb）全部无关。
