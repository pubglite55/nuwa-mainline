# nuwa 主线移植 — 当前状态

更新时间：2026-10-30
**本文件是唯一的进度来源。** 操作步骤见 [next-steps.md](next-steps.md)，技术债见 [tech-debt.md](tech-debt.md)。

## 2026-10-31 08:10 关键突破：**屏幕已点亮**，剩下是 DSC 解码问题

#### 一、v49 三阶段 TE 自检（一次启动给出完整链条）

```
after-rails  edges=24  last=1     ← 面板活着，TE 60Hz 在跳
after-reset  edges=0   last=0     ← 复位把面板打回睡眠
after-init   edges=0   last=0     ← 复位后唤醒失败
```

#### 二、v48：**用户目视确认出现滚动文字 + 花屏**

配置为「不复位 + 完整初始化」。⇒ **面板、DSI 链路、帧传输全部打通**，
剩下的只是“画面内容解码不对”。

#### 三、DSC 花屏的根因链（源码级）

1. `drm_dsc_compute_rc_parameters()` 第一行：
   `slice_bits = 8 * vdsc_cfg->slice_chunk_size * vdsc_cfg->slice_height;`
2. 我们的 panel 驱动**从未设置 `slice_chunk_size`**（值为 0）
3. ⇒ RC 参数计算失败（实测日志 `NUWA_PPS_OVERRIDE rc compute failed`）
4. ⇒ `rc_range_params` / `rc_buf_thresh` / `initial_xmit_delay` 全为 0
5. ⇒ DPU 的 `DSC_CHUNK_SIZE` 等寄存器被写成 0，硬件按“每片 0 字节”切 DSC
6. ⇒ 面板解出来的就是花屏

补齐字段（照 `panel-ilitek-ili9882t.c` 这个能工作的 DSC 面板）：
`slice_chunk_size=720`、`mux_word_size=DSC_MUX_WORD_SIZE_8_10_BPC`、
`line_buf_depth=bpc`、`rc_model_size/rc_edge_factor/rc_tgt_offset_*` 常量、
`rc_buf_thresh[14]` 规范序列。

#### 四、PPS 逐字节对比（客观证据，不需要人眼）

`bytes_diff=8/128`，差异集中在 RC 参数与 `convert_rgb`：

```
厂商: 120000ab 30800c80 ... 02000286 0020029e 000a000d 0456030d
我们: 120000aa 20800c80 ... 02000268 00f802be 0001000c 0400030d
```

两边都是 **8bpp、block-pred=1**；厂商 `line_buf_depth=11`、`convert_rgb=1`，
我们是 10 和 0；其余差异是 RC 参数（`initial_xmit_delay` 512/646 等）。

#### 五、v58（当前最佳）：解析厂商 PPS 灌入 dsc_config

`CONFIG_NUWA_PPS_PARSE`：在 `send_seq` 遇到厂商 `0x9E` 时，把 128 字节 PPS 解成
`drm_dsc_config` 的 RC 字段（同时原样发送厂商 PPS），实现与厂商逐字段一致。
实测：`NUWA_PPS_PARSE ok xmit=512 dec=646 bpp=128 bpc=10 lbd=11 conv=1`（仅 1 次，正确）

| 项 | 值 |
|---|---|
| TE(gpio86) | 11 高 / 9 低（跳变） |
| CRTC | vblank 30fps，帧数 325，无 underrun |
| encoder | vsync 1823，frame_done 超时 0 |
| DSC | 与厂商 PPS 逐字段一致 |

产物：`other/abl-nuwa-disp-v58-ppsparse2.img` 12,853,248 B `8b469195…`

#### 六、v58 当前运行状态（设备上正跑着）

```
fb0        = ff ff ff ff   (纯白)
backlight  = 4095          (满)
crtc       = vblank 29fps, total_framecount 4339, underrun 0
enc        = vsync 计数增长, frame_done 超时 0
TE(gpio86) = 跳变
```

⇒ 从 Linux 侧看一切正常。**是否真的显示白屏，等用户目视确认。**

另：内核未启用电池驱动，`/sys/class/power_supply/` 为空，
因此无法用“白屏 vs 黑屏的功耗差”做客观判据。

#### 七、踩过的坑

- 解析块最初没加 `dtype==LONG_WRITE && plen==129 && payload[0]==0x9e` 限定，
  对每个长写包都执行，把随机数据当 PPS，DSC 配置被破坏 → 面板停 TE → vblank 超时
- 通过串口发含引号的命令（如 `tr "\000"`）会被 PowerShell 转义吞掉，
  shell 卡在续行 `>`，只能断电重启恢复——后续一律写脚本文件再执行

## 功能状态表（只用规范状态词）

规范词：**待调研** / **有源码线索** / **离线通过** / **真机启动** / **真机通过** / **真机失败**

| 功能 | 状态 | 依据 |
|---|---|---|
| UEFI 固件启动 | **真机通过** | 屏幕有界面，USB 枚举出 VID_18D1 |
| 内核 EFI stub 加载 | **真机启动** | 真机屏幕出现内核输出后黑屏，init 计时器生效 |
| initramfs + /init 执行 | **真机启动** | 真机：300 秒后自动重启，证明 `/init` 跑完 |
| 内核 cmdline 生效 | **离线通过** | 空 `-append` 下仍有完整 cmdline（FORCE 验证） |
| 4 KiB FAT16 挂载 | **有源码线索** | EDK2 九项检查全过，但 UFSDxe 行为未知 |
| 显示（efifb，UEFI 路线） | **真机失败** | 启动早期有输出，随后黑屏（见 §2026-10-29） |
| 显示（原生 MSM DSI + panel 驱动，ABL 路线） | **真机失败（但已点亮）** | v48 用户目视：出现滚动文字 + 花屏 ⇒ 面板/DSI/帧传输已通；剩余为 DSC 解码参数问题，见 §2026-10-31 08:10 |
| ABL 直启（recovery_a 放 boot.img v1） | **真机失败** | 写入成功（`Sending/Writing OKAY`）也能启动，但卡第一屏且无任何 USB 枚举；疑似内建 DTB 的 memory size=0，见 §2026-10-30 真机首刷 |
| 触控（FTS） | **待调研** | 驱动已内建，需真机验证事件 |
| USB 网络（NCM） | **待调研** | init 逻辑完整，需真机验证 usb0 |
| Wi-Fi / BT | **待调研** | 固件未准备 |
| 音频 | **真机失败（预期）** | UEFI 的 PIL 被禁用，ADSP 不上电 |
| 传感器 / GPU / 相机 | **真机失败（预期）** | 同上 |

## 一句话状态

**ABL 直启路线已在真机上走通「刷入 + 启动」两步，但内核卡在第一屏**（见 §2026-10-30 真机首刷）。
最可能的原因是内建 DTB 里 `/memory@a0000000` 的 size 为 0 —— 主线 DTS 指望 bootloader 填，
而我们用 `CONFIG_NUWA_FORCE_BUILTIN_DTB` 把 bootloader 那份换掉了。修复方向明确：把真实 DRAM 布局写进 DTS。

> 历史说明：Mu UEFI 路线已冻结为回退方案（[abl-direct-boot.md](abl-direct-boot.md)）。

内核、设备树、面板驱动、DSC 参数全部离线就绪并通过交叉核对，产物 `other/abl-nuwa-drm-v4.img`
（17.85 MB，sha256 `c97ff6f7…`）。**当前唯一阻塞是设备不在线**：需要先备份 `recovery_a`，再刷入。

## 2026-10-30 路线切换：ABL 直启 + 原生 MSM 显示

依据是同一 SoC（SM8550）的 fuxi 移植：它在真机上跑通了 Phosh 桌面（原生 MSM DSI 120 Hz、
WiFi、双 CS35L41 音频），而它**完全没有用 Mu UEFI**。做法是 `XBL → 高通 UEFI → ABL → 直接加载
Android boot.img（header v1）`，内核字段是 `Image.gz + 厂商 DTB`，initramfs 编进内核。

完整原理与分区账见 [abl-direct-boot.md](abl-direct-boot.md)。

### 内核改动（本机 `~/nuwa/linux`，7.3.0 @ 734bef548）

| 文件 | 改动 |
|---|---|
| `arch/arm64/Kconfig` / `include/asm/setup.h` / `kernel/setup.c` | 新增 `CONFIG_NUWA_FORCE_BUILTIN_DTB`：`__fdt_pointer` 指向内建 DTB |
| `arch/arm64/kernel/nuwa_dtb.S` + `Makefile` | `.incbin` 嵌入 `sm8550-xiaomi-nuwa.dtb` |
| `include/drm/drm_mipi_dsi.h` + `msm/dsi/dsi_host.c` | 新增 `hs_rate` 字段并在 `dsi_calc_pclk()` 覆盖 byte clock |
| `drivers/gpu/drm/panel/panel-nuwa-m2.c` | 按 fuxi 模式重写（prepare/unprepare、DSC、背光） |
| `drivers/input/touchscreen/fts_spi` | 补 `panel_event_notifier` 兼容桩（TD-09） |
| `sm8550-xiaomi-nuwa.dts` | 删 simple-framebuffer/`nuwa_fb_mem`、写正式 bootargs、修 reset 极性 |

### 参数核对（离线、逐项对齐厂商）

| 项 | 厂商值 | 我们的值 | 结论 |
|---|---|---|---|
| `panel-clockrate` | `0x510ff400` = 1,359,996,928 | `hs_rate = 1360000000` | ✅ |
| 水平 porch（前/后/脉宽） | 32 / 32 / 16 | 32 / 32 / 16 | ✅ |
| 垂直 porch（前/后/脉宽） | 24 / 24 / 8 | 24 / 24 / 8 | ✅ |
| 分辨率 / 刷新率 | 1440×3200 @ 60 | 1440×3200 @ 60 | ✅ |
| reset GPIO | `platform-reset-gpio = <&tlmm 133 0>`（ACTIVE_HIGH） | `GPIO_ACTIVE_HIGH` | ✅（原为 LOW，已修） |
| DSC PPS 首条命令 | DCS `0x9e` + 128 字节 | 序列原样携带 | ✅ |
| DSC 版本 / bpc / bpp | 1.2 / 10 / 8.0 | 1.2 / 10 / 8<<4 | ✅ |
| pic / slice | 1440×3200，720×25，2 片 | 同 | ✅ |
| `line_buf_depth` | 0xB = 11 | 主线自动 `bpc+1 = 11` | ✅ |
| `convert_rgb` / `block_pred` | 1 / 1 | 主线强制 1 / 驱动置 1 | ✅ |
| `rc_buf_thresh` | 14,28,…,126 | 主线表同 | ✅ |
| `slice_chunk_size` | 720 | 主线 `720*128/(8*16) = 720` | ✅ |
| `rc_model_size` / `initial_offset` | 8192 / 6144 | 主线常量同 | ✅ |
| 每行包数（`pkt_per_line`） | 2 slice / 2 slice-per-pkt = 1 | `DSC_ALL_SLICES_IN_PKT` → 1 | ✅ |
| `eol_byte_num` | (720×2) % 3 = 0 | 同 | ✅ |
| `first_line_bpg_offset` | 13 | 主线 12 | ⚠️ 差异（TD-10） |
| RC range max_qp（个别档） | 8/14/15/16/17 | 4/15/16/17/19 | ⚠️ 差异（TD-10） |

PPS 是用内核 `drm_dsc_pps_payload_pack()` 的字节序逐字段解码的，不是猜的。

### 本次修掉的三个真 bug

1. **reset 极性写反**：DTS 写 `GPIO_ACTIVE_LOW`，驱动 `set(0)→set(1)` 会把面板一直按在复位态。
   厂商 `platform-reset-gpio` 的 flags 是 `0x00`（ACTIVE_HIGH），已改为 `GPIO_ACTIVE_HIGH`。
2. **初始化序列的延时没生效**：`send_seq()` 里原本是个空语句（`if (...) ;`），
   导致 `0x11`（sleep out）之后要求的 120 ms 被跳过。已改为 `msleep(seq[i + 4])`。
3. **显示时钟控制器是模块**：`CONFIG_SM_DISPCC_8550=m`。initramfs 环境里没有模块可加载，
   `mdss` 拿不到 `dispcc` 的时钟就会 probe defer 到底 —— 静默黑屏。已改为 `=y`，
   并用 `nm vmlinux` 确认 `dispcc_sm8550_driver_init` 是内建 initcall。

另外补上了厂商的关机序列（`0x28` + 20 ms，`0x10` + 100 ms），放在 `unprepare()` 里，
否则面板断电后会残留自发光、下次初始化也可能失败。

4. **触控属性名对不上**：厂商 `fts_spi` 驱动的 `parse_dt()` 读的是**单数**属性
   `fts,irq-gpio` / `fts,reset-gpio`，并要求 `fts,reset-gpio-enable` 才去申请 reset；
   而 DTS（抄自原厂 dtbo）只有**复数**写法 `fts,irq-gpios` / `fts,reset-gpios`。
   后果是 `irq_gpio = -EINVAL` → `gpio_to_irq(-22)` → `request_threaded_irq` 失败 → 触控 probe 直接挂。
   已在 DTS 里两套并存补上单数属性。

### 触控 DTS 属性完备性核对

用脚本把驱动 `parse_dt()` 读取的 24 个属性与 DTS 提供的对照：修完之后必需项全部齐备，
剩下 13 个缺失项都是可选项（`fts,fod-*`、`fts,support-*`、`fts,swap-*`、`fts,avdd-gpio`、`panel`），
驱动读到 -EINVAL 只打日志不失败。SPI 侧依赖也确认：`SPI/SPI_MASTER/SPI_QCOM_GENI/QCOM_GENI_SE` 全部 `=y`。

> ⚠️ 已知的下一处静默陷阱：`CONFIG_I2C_QCOM_GENI=m`。它不影响显示与触控，
> 但音频阶段要挂 CS35L41（I2C）时必须改成 `=y`，否则 I2C 总线根本不存在。

### 产物

| 文件 | 大小 | sha256 |
|---|---|---|
| **`other/abl-nuwa-drm-v9.img`** | **17,858,560** | **`ef0e57013381758c9b73adbcccf5638b33639d72b49a31b8ba686bc6bd0c8e75`（当前，刷这个）** |
| `other/abl-nuwa-drm-v8.img` | 17,858,560 | `81dc0cf5…`（init 的 rootfs 探测漏了裸盘） |
| `other/abl-nuwa-drm-v7.img` | 17,854,464 | `4b3845d5…`（没有 switch_root 能力） |
| `other/abl-nuwa-drm-v6.img` | 17,858,560 | `d7ba3eff…`（缺触控属性名修复） |
| `other/abl-nuwa-drm-v4.img` | 17,854,464 | `c97ff6f7eb79bfc3def4686c26637d8b8732f45eeec2b6ae27161e2ec5b9d339`（dispcc 仍是模块） |
| `other/abl-nuwa-drm-v5.img` | 17,854,464 | `91f2d68f2a34aba6d950cacf5ec2120b4fc4d0dadc24798c28780ebdf5d17445`（dispcc 已内建，缺 off 序列） |
| `other/abl-nuwa-drm-v3.img` | 17,854,464 | `8af2181d887ab6defcdca48fff6f85366c4c01dd819c15a5a4a9813b6929ff27`（旧 initramfs） |


### 离线核对第二轮（2026-10-30 补）

| 检查项 | 结果 | 说明 |
|---|---|---|
| DSC 尺寸合法性 | ✅ | `msm_dsi_host_check_dsc()`：1440 % 720 = 0、3200 % 25 = 0 → `MODE_OK` |
| DSC 参数填充时机 | ✅ | `dsi_populate_dsc_params()` 在 `dsi_timing_setup()`（modeset 时）调用，`pic_width/height` 用 mode 覆盖 |
| 命令模式包数 | ✅ | `pkt_per_line = 2/2 = 1`，`eol_byte_num = 1440 % 3 = 0` |
| LPM 传递 | ✅ | `drm_mipi_dsi.c:457` 自动加 `MIPI_DSI_MSG_USE_LPM`；`dsi_host.c:2200` 据此设 TX 低功耗 |
| USB gadget 前提 | ✅ | DTB：`usb@a600000` = okay、`phy@88e3000`（HS phy）= okay；`dr_mode = "peripheral"` |
| initramfs 工具 | ✅ | busybox 是 **aarch64 静态**二进制，`ip/telnetd/dd/insmod/mount/grep/...` 全在 |
| 面板驱动结构 | ✅ | `prepare_prev_first = true`、`GPIOD_ASIS`、`hs_rate`、`mode_flags`、`devm_*` 全按 fuxi 模式 |
| 诱饵 DTB 完整性 | ✅ | 镜像 kernel 字段尾部逐字节等于 `private/nuwa-bait.dtb`（930,579 B） |

> 唯一没设的是 `mode.type` 里的 `DRM_MODE_TYPE_PREFERRED`。面板只报一个模式，connector 必然选它，
> 所以不影响点亮；等以后加多刷新率时再补。

### 2026-10-30 QEMU 端到端验证：内核 → initramfs → rootfs → systemd 全链跑通

设备不在手，但用户空间这半条链可以在 QEMU 上真跑。做法：

1. 临时关掉 `CONFIG_NUWA_FORCE_BUILTIN_DTB`（否则内核强制用 nuwa 内建 DTB，QEMU virt 起不来），
   单独构建一个 `Image`，构建后立刻把 `.config` 还原；
2. `qemu-system-aarch64 -M virt -cpu max -m 2048 -smp 2 -kernel Image \
   -drive file=nuwa-rootfs-8g.img,if=virtio,format=raw -nographic`；
3. 内核自带的 initramfs（`ir-root`）扫描块设备 → 找到 ext4 + `/etc/os-release` → `switch_root`。

实测日志（`qemu-boot4.log`，670 行）：

```
[    1.565980] nuwa-init: bound to /dev/kmsg
[   12.080237]    found rootfs on /dev/vda: PRETTY_NAME="Ubuntu 26.04.1 LTS" NAME="Ubuntu"
[   12.112893] nuwa-init: switch_root -> /dev/vda
[   13.176922] systemd[1]: systemd 259.9-0ubuntu0.1 running in system mode
[   13.177921] systemd[1]: Detected architecture arm64.
[   13.232234] systemd[1]: Hostname set to <nuwa>.
Welcome to Ubuntu 26.04.1 LTS!
Reached target getty.target - Login Prompts.
Ubuntu 26.04.1 LTS nuwa ttyAMA0
nuwa login:
```

同一份日志里 SSH 也起来了：

```
Listening on ssh.socket - OpenBSD Secure Shell server socket.
Finished sshd-keygen.service - Generate sshd host keys on first boot.
```

结论：**initramfs 的 switch_root 逻辑、rootfs 的 fstab/hostname/systemd/sshd 全部可用**，
唯一没在 QEMU 里验证的是 nuwa 专有硬件（UFS 上真实的 `linux` 分区、MSM 显示、触控）。

顺带修掉一个真 bug：init 里原来按 `/dev/vd*[0-9]*`（分区名）匹配，**裸盘 `/dev/vda` 匹配不到**，
已改成整盘与分区都试。

## 2026-10-30 真机首刷 ABL 直启（v9）：卡第一屏，USB 完全不枚举

### 做了什么

| 步骤 | 结果 |
|---|---|
| `fastboot flash recovery_a abl-nuwa-drm-v9.img` | `Sending 17440 KB OKAY` / `Writing OKAY` |
| `fastboot reboot recovery` | `Rebooting into recovery OKAY` |
| 观察 30 秒 | **没有任何 USB 枚举**：既没有我们的 `1D6B:0104`，也没有 `18D1`（fastboot/adb），也没有 `05C6`（EDL） |
| 屏幕 | 卡在第一屏 |

### 已回退 / 已按要求执行的操作

| 操作 | 状态 |
|---|---|
| `fastboot flash recovery_a backup/nuwa-backup/recovery.official.img`（原厂 recovery） | OKAY |
| `fastboot flash boot_a / boot_b backup/nuwa-backup/boot_a.img`（原厂 boot，用户要求） | 均 OKAY |
| `fastboot erase userdata` + `fastboot erase metadata`（用户要求清数据） | 均 OKAY |
| 之后再次刷入 v9 复现同一现象 | 一致：卡第一屏、无 USB |

### 根因：尚未确定（第一个假设已被排除）

内建 DTB 的 `/memory@a0000000` 是：

```
reg = <0 0xa0000000 0 0>;      /* 尾部 size = 0 */
```

主线 `sm8550-xiaomi-nuwa.dts` 里这行的注释写得很清楚：**“We expect the bootloader to fill in the size”**。
走 UEFI 路线时是 UEFI stub / ABL 填的；而 `CONFIG_NUWA_FORCE_BUILTIN_DTB=y` 之后，
内核**丢弃** ABL 传进来（已被 ABL 补好 memory）的 DTB，改用我们自己 `.incbin` 的那份 —— 于是拿到 0 字节 RAM，
`setup_arch` 阶段就死，连 USB 都来不及初始化。

> 带着**完整的 11.68 GiB / 9 bank 布局**（从原厂 dtbo 抄来的，含 `ddr_size`、`ebuff` 等属性）；
> 那个 size=0 的 `memory@a0000000` 只是 `sm8550.dtsi` 里多出来的冗余节点，加 0 字节 bank 不会让内核没内存。
> 实测确认：设备上 `/proc/device-tree/memory/reg` 共 144 字节 = 9 个 bank、合计 11962 MiB，
> 与我们 DTS 里那份一致。所以**卡第一屏不是内存问题**，真正原因待查。

### 现在的调试手段：pstore / ramoops

真机上没有任何输出通道（无串口、USB 起不来），所以改用 **ramoops 留证**：

| 项 | 值（取自设备 `/proc/device-tree/reserved-memory/ramoops@0xa7000000`） |
|---|---|
| 地址/大小 | `0xa7000000` / 4 MiB |
| `console-size` | 2 MiB（`PSTORE_CONSOLE` 把内核控制台输出写进去） |
| `pmsg-size` | 2 MiB |

做法：在板级 DTS 的 `&reserved_memory` 里加同址同尺寸的 `ramoops@a7000000`，
cmdline 追加 `panic=10 panic_on_rcu_stall=1`。这样即使屏幕不亮、USB 不枚举，
panic 或控制台输出也会留在那块内存里；设备随后重启回 Android，Android 内核读同一块内存，
就能从 `/sys/fs/pstore/console-ramoops-*` 取出**上一次启动的内核日志**。

### 下一步

1. 刷 v11（带 ramoops 与 panic 参数），启动后等它自己回到 Android；
2. `adb shell su -c 'ls -l /sys/fs/pstore'`，读 `console-ramoops-*` 看内核最后停在哪；
3. 若 pstore 也为空，说明内核死在 console 初始化之前，需要转串口或其它手段。

### 旧的假设记录（保留，但已排除）

~~内建 DTB 的 `/memory@a0000000` size=0 导致 0 RAM~~ —— 当时的推理看着成立，实测被推翻，留作教训。

### 下一步（明确、可离线完成）

1. 取到 nuwa 真实 DRAM 布局：设备上 `adb shell su -c 'cat /proc/device-tree/memory@*/reg | xxd'`，
   或从原厂 `boot_a.img` 里取出带 memory 的 DTB 读 `reg`。
2. 把真实 `base/size` 写进 `sm8550-xiaomi-nuwa.dts` 的 `memory@a0000000`（多 bank 就多写几个节点）。
3. 重建 v10 再刷。若仍然卡第一屏，下一个怀疑点是 UFS probe 或 `reserved-memory` 与真实布局冲突。

### 附带结论

- `recovery_a` 的刷写在 ABL 上**确实可行**（写进去了、也尝试启动了），路线本身没被否定；
- 卡死时设备**不会**自己回 Android（300 秒自动重启的逻辑还没跑到 init），需要长按电源强制关机；
- 强制关机后按“音量下 + 电源”能稳定回到 fastboot，恢复通路可用。

### 2026-10-30 深夜 真机诊断第二轮（v11 + ramoops）

#### 新证据

| 发现 | 含义 |
|---|---|
| 原厂 `recovery.img` = **header v4、`kernel_size = 0`、ramdisk 80 MB、signature 4096** | 原厂 recovery 是「只有 ramdisk、没有内核」的 GKI 风格镜像；ABL 的 recovery 路径极可能从 `boot_a` 取内核 |
| fuxi 参考项目的 `mkbootimg` 参数与我们**逐字相同**（v1、`--base 0x0`、同 offsets、`os 13.0.0/2022-11`） | 打包参数不是问题，问题在内核本身 |
| fuxi 的镜像只有 10.3 MB，且**先做 `-min` 最小内核**打通 text console + USB，再逐个加子系统 | 我们的 17 MB 大配置里有大量内建驱动，很可能在早期就卡死 |
| v11（带 ramoops + `panic=10 panic_on_rcu_stall=1`）启动后 2 分钟无任何 USB、也没有 panic 重启；回 Android 后 `/sys/fs/pstore` **为空** | 内核死在 pstore 初始化之前（或 ramoops 缺 `no-map` 被覆盖）→ 早期死亡 |

#### 当前策略（对齐参考项目）

1. **先做最小内核**：`qcom_defconfig` 为底，只留 PINCTRL_SM8550 / SM_GCC_8550 / RPMH 稳压器 / DWC3 + NCM gadget + 内建 initramfs，
   显式关掉 UFS、DRM_MSM、SND、I2C_GENI、ATH11K、PCI、MMC —— 目标是「能起来 + USB 能枚举 + telnet 能连」。
2. 通道打通后，按 UFS → 显示 → 触控 → USB 网络 → 无线 → 音频 的顺序逐个加回，每加一项刷一次。
3. ramoops 同时补 `no-map`，作为每次失败的留证手段。

#### 已生成的镜像

| 文件 | 说明 |
|---|---|
| `other/abl-nuwa-drm-v10.img` | 清理了 `sm8550.dtsi` 里 size=0 的冗余 memory 节点（非根因） |
| `other/abl-nuwa-drm-v11.img` | v10 + ramoops 预留 + `panic=10`（真机仍无输出、pstore 空） |
| `other/abl-nuwa-min-v1.img` | **最小内核**首测镜像（构建中） |

### 2026-10-30 深夜 第三轮：通读 fuxi 仓库 + 找到 USB 不枚举的真凶

#### 真凶：`CONFIG_PHY_SNPS_EUSB2=m`

`usb_1_hsphy`（compatible `qcom,sm8550-snps-eusb2-phy`）的驱动是 `drivers/phy/phy-snps-eusb2.c`，
对应 `CONFIG_PHY_SNPS_EUSB2`。它之前是 **`=m`**，而 initramfs 环境不加载模块 → PHY 永不 probe
→ dwc3 等不到 PHY，一直 defer → **没有 UDC、没有 gadget、没有任何 USB 枚举**。
这与症状完全吻合：卡第一屏、`1D6B`/`18D1`/`05C6` 全都没有。

已改为 `=y`（同时确认 `PHY_QCOM_EUSB2_REPEATER`、`PHY_QCOM_QMP_USB` 也是 `y`）。
这是本项目第 **四** 次踩「关键依赖停在 `=m`」：`QCOM_OCMEM`、`SM_DISPCC_8550`、`DRM_MSM`、现在的 `PHY_SNPS_EUSB2`。

#### 并行构建事故（已修）

我在同一棵内核树里同时跑了「最小内核」和「v12」两个构建，两边互相改 `.config`：
v12 编译失败（`kernel/bpf/core.o` 等报错），而且 `SM_DISPCC_8550` 被改回了 `=m`。
fuxi 的脚本用 `flock` 防这个，已照学：构建脚本里加 `exec 9>.nuwa-build.lock; flock -n 9`。
另外 `make mrproper` 会删掉 `.config`，之后又用备份覆盖回了坏配置 —— 重建前必须先确认 13 个关键项都是 `y` 再开编译。

#### 从 fuxi 仓库学到的要点

整理成 [reference-fuxi.md](reference-fuxi.md)。最要紧的三条：

1. 打包参数与我们**逐字相同** → 打包不是问题；
2. 他们先做 `-min` 最小内核打通「进用户空间 + USB 串口」，再按变体加子系统；
3. **pstore/ramoops 在他们机器上跨复位不可持久**（复位清 DDR，实测失败）—— 解释了我们的 pstore 为空，
   以后不要把 pstore 当早期日志通道。

#### 待验证

`other/abl-nuwa-drm-v13.img`（USB PHY 内建 + 完整显示/UFS/触控）正在构建；刷入后如果 USB 枚举出 `1D6B:0104`，
就能 `telnet 192.168.0.1` 拿到 dmesg，从而第一次看到真机上的真实日志。

### 2026-10-30 深夜 第四轮：完全照 fuxi 重建（结论：是早期死亡，不是 USB）

#### 关键否证：内核没有跑到用户空间

v14（USB 三处修复 + 新 init，含 180 秒安全重启）刷入引导后，**3.5 分钟没有回到 Android**。
如果内核跑到了 `/init`，180 秒的 `reboot -f` 一定会把它送回 Android。所以：

> **内核死在 `init` 之前**，卡第一屏不是「没屏没网」，是根本没起来。USB 那几条是必须修的真 bug，但不是根因。

#### 按 fuxi 的做法重建

1. 完整克隆参考仓库（79 MB），读 `source/BUILD-INFO.md`、`source/kernel.config`、
   `scripts/fuxi-build-abl.sh`、`source/initramfs/init`、`source/linux-untracked/.../sm8550-xiaomi-fuxi-min.dts`；
2. 发现他们的内核**可启动配置**里有 `CONFIG_USB_DWC3_GADGET=y`（我们整符号缺失）、
   `&usb_1` 显式 `/delete-property/ usb-role-switch;`（我们没删）——两条都是 dwc3 拿不到 peripheral 角色的原因；
3. init 按他们骨架重写：`busybox --install -s`、ACM `/dev/ttyGS0` 主通道 + NCM/telnetd 备用、
   等 30 秒 deferred probe、**没 USB 时把 `devices_deferred` 与 dmesg 错误打到屏幕上**、180 秒安全网；
4. **直接用他们的 `kernel.config` 当底座**构建最小镜像：`other/abl-nuwa-min-v15.img`（9,916,416 B，
   sha256 `fcb477b8…`），与他们的 10,379,264 B 同一量级；显示驱动先关（对齐他们 `-min` 变体）。

#### 踩到的构建坑（已修）

- `make Image.gz` 时如果 DTB 文件还不存在，`nuwa_dtb.o` 找不到跨目录规则 → `No rule to make target`。
  **必须先 `make qcom/sm8550-xiaomi-nuwa.dtb`，再 `make Image.gz`**。
- 同一棵内核树不能并发构建（会互改 `.config`），脚本已加 `flock`。

#### 待办

1. 设备手动进 fastboot → 刷 `abl-nuwa-min-v15.img` → 看是否出现 ACM (`/dev/ttyGS0` / Windows COM) 或 NCM；
2. 若最小镜像能起来，就按 fuxi 的变体顺序把显示/UFS/触控逐个加回；
3. 若最小镜像也不行，则问题在 DTB/打包/ABL 交接层面，下一步用他们的「立即复位桩内核」法验证 ABL 是否真的跳到我们的代码。

### 2026-10-30 深夜 第五轮：最小内核同样起不来 → 转用「复位桩」定位

#### 结果

- `other/abl-nuwa-min-v15.img`（**以 fuxi 的 kernel.config 为底座**，9,916,416 B）刷入后同样无任何 USB，
  且 180 秒安全重启没有发生 → **连最小内核都没进用户空间**。
  这条把嫌疑从「我们的配置太杂」排除掉了：问题在**内核代码之前的环节**（镜像 / DTB / ABL 交接）。
- 已按 fuxi 的方法做好**复位桩镜像** `other/abl-nuwa-stub-v16.img`（9,912,320 B，sha256 `51fd84bb…`）：
  新增 `CONFIG_NUWA_STUB_RESET`，在 `setup_arch()` 第一行直接 `arm_smccc_smc(0x84000009)`（PSCI SYSTEM_RESET）。
  判据：刷入后**几秒内自己回到 Android** ⇒ ABL 确实跳到我们的代码；**永远卡第一屏** ⇒ 问题在镜像/DTB/ABL 层。

#### 顺带完成的取证

| 项 | 结果 |
|---|---|
| 原厂 `boot_a.img` / `recovery.official.img` 里的 FDT | **0 个**（GKI 风格，boot 只有内核、recovery 只有 ramdisk） |
| `dtbo_a.img` 里的 FDT | **57 个 overlay** |
| `vendor_boot_a.img` 里的厂商 DTB | **8 个**：msm-id 依次为 `0x25c / 0x258 / 0x207 / 0x207 / 0x25b / 0x259 / 0x218 / 0x218` |
| 我们在用的诱饵 `private/nuwa-bait.dtb` | model `8550 nuwa`、`msm-id = 207/218 (20000)`、`board-id = 10008 0`、930,579 B —— 与设备侧匹配，**大概率是对的**（`Kalama` 即 SM8550，207 是它的 msm-id） |
| 我们板级 DTS 的 `qcom,msm-id` | `<0x25c 0x20000>` —— 这个值抄自 fuxi，与设备实际（207）**不一致**；只影响 ABL 选 DTB，我们内置 DTB 不经 ABL，暂不影响 |

#### 参考仓库更新（v0.4.0，2026-10-30）

新增 `hardware/本机硬件配置.md`、`hardware/配件供应商差异.md`，以及省电深化（熄屏电流 117→28.5 mA）、WiFi 5 GHz、蜂窝诊断。
**启动链路部分没有变化**：仍是 boot.img v1 + 厂商诱饵 DTB + `CONFIG_FUXI_FORCE_BUILTIN_DTB`，当前镜像 `s2idle2`（`7.3.0+ #207`）。

#### 阻塞

设备在 v15min 引导后挂死（无 USB），需要人工**长按电源 20 秒**再按「音量下 + 电源」进 fastboot，
才能刷入复位桩验证 ABL 交接。

### 2026-10-30 深夜 第六轮：分级复位桩锁定故障段（重大进展）

#### 方法

新增 `CONFIG_NUWA_STUB_STAGE`（0–9），在启动路径上埋点，命中即在原地发 PSCI `SYSTEM_RESET`：
被复位 ⇒ 这一段跑通了；不复位 ⇒ 卡在这一段之后。用 `fastboot boot`（不写分区）迭代，复位后自动回 Android。

#### 结果

| stage | 埋点位置 | 结果 |
|---|---|---|
| 1 | `setup_arch()` 第一行 | ✓（先证 ABL 确实跳到我们的代码：无限重启） |
| 2 | `setup_arch()` 结尾（`smp_build_mpidr_hash` 后） | ✓ 复位成功 |
| 3 | `mm_core_init()` 之后 | ✓ |
| 4 | `smp_init()` 之后 | ✓ |
| 5 | `run_init_process()` 之前（`async_synchronize_full()` 之后） | ✗ **卡住** |

结论：**内存、MM、SMP 全部正常**，卡在 `kernel_init_freeable()` → `async_synchronize_full()` 这一段，
也就是「initramfs 解包 / `/dev/console` / 等异步 probe」之间。
`async_synchronize_full()` 会一直等所有异步 probe 收尾，**任何一个驱动卡住都会让它永远不返回** ——
这也同时解释了为什么 USB、显示都没起来：`/init` 根本没被执行。

#### 下一步

在 `kernel_init_freeable()` 内继续细分：stage 6 入口、7 initramfs 解包后、8 `console_on_rootfs` 后、9 `async_synchronize_full` 后。
找出到底是解包卡住、还是某个异步 probe 卡住。

### 2026-10-30 深夜 第七轮：分级结果与关键推论（rdinit 没传到内核）

#### 分级复位桩完整结果

| stage | 埋点 | 结果 |
|---|---|---|
| 1 | `setup_arch()` 第一行 | ✓ |
| 2 | `setup_arch()` 结尾 | ✓ |
| 3 | `mm_core_init()` 后 | ✓ |
| 4 | `smp_init()` 后 | ✓ |
| 6 | `kernel_init_freeable()` 入口 | ✓ |
| 7 | `wait_for_initramfs()` 后（initramfs 解包完成） | ✓ |
| 8 | `console_on_rootfs()` 后 | ✓ |
| 9 | `async_synchronize_full()` 后 | ✓ |
| **5** | `run_init_process(ramdisk_execute_command)` 之前 | ✗ **钩子没执行** |

注意 stage 5 的第一版是假阳性：`nuwa_stub_reset` 标了 `__init`，而 stage 5 在 `free_initmem()` 之后，
踩了 fuxi 文档里记的 use-after-free 假死坑。去掉 `__init` 重测仍然不执行 ⇒ **不是假阳性**。

#### 关键推论：`rdinit=/init` 没有进到内核

stage 5 的埋点在 `if (ramdisk_execute_command) { ... }` 块内部；钩子没执行 ⇒ **`ramdisk_execute_command` 为 NULL** ⇒
ABL 传给内核的 cmdline 里**没有 `rdinit=/init`**（我们用 `CONFIG_CMDLINE_FROM_BOOTLOADER=y`，完全依赖 ABL 传参）。

于是 `kernel_init` 按回退列表找 init：`/sbin/init` → `/etc/init` → `/bin/init` → `/bin/sh`。
我们 initramfs 里只有 busybox，`/bin/sh` 会被当成 init 跑起来，而它没有控制台可用 ⇒ **就那么挂着**：
没有 USB（我们的 `/init` 从没执行，gadget 没建）、不会 300 秒重启（安全网也没执行）、屏幕停在第一屏。
这与真机现象完全吻合。

#### 修复方向（正在验证）

不再依赖 ABL 传参：`CONFIG_CMDLINE_FORCE=y` + `CMDLINE="console=tty0 loglevel=8 rdinit=/init"`，
构建 `other/abl-nuwa-rdinit-v17.img`。若 USB 出现（`1D6B:0104` / ACM / NCM），说明整条链就通了。

### 2026-10-30 深夜 第八轮：★ 真机打通（USB shell + UFS + 显示栈全部起来）

#### 突破点：legacy `g_cdc` 抢占 UDC

`CONFIG_USB_CDC_COMPOSITE=y`（`drivers/usb/gadget/legacy/cdc2.c`，身份 `0525:A4AA`「CDC Composite: ECM + ACM」）
是内置的 legacy gadget，**在内核初始化时就抢占了 UDC**：

- 它自我申报成 `0525:A4AA`，而 Windows 没有 ECM 驱动 → 显示为「驱动安装失败」的错误设备；
- 我们的 configfs gadget（`1d6b:0104` NCM+ACM）因此绑不上 → 看起来像「USB 完全没反应」。

关掉 `CONFIG_USB_CDC_COMPOSITE` 后，`other/abl-nuwa-v18.img` 一次点亮：

| 项 | 实测 |
|---|---|
| 枚举 | `VID_1D6B&PID_0104` → **UsbNcm Host Device + USB 串行设备 (COM5)** |
| 内核 | `Linux (none) 7.3.0+ #17 SMP PREEMPT aarch64`（启动到 `/init` 仅 **1.09 s**） |
| cmdline | `console=tty0 loglevel=8 rdinit=/init`（`CONFIG_CMDLINE_FORCE=y`，不再依赖 ABL 传参） |
| gadget | `GADGET_BOUND a600000.usb` → `usb0 = 192.168.0.1/24 UP` |
| 服务 | `TELNETD up on 192.168.0.1:23` + ACM 上的交互 shell |
| UFS | 四个 LUN 全部枚举：`sda`(+32 分区) `sdb`(+5) `sdc`(+5) `sdd`(+5) **`sde`(+76)** `sdf`(+6) |

#### 显示栈（v19）

同一套修复 + 打开 DRM/DSI/panel：`other/abl-nuwa-disp-v19.img`（10,440,704 B，`92b10123…`）

| 检查项 | 结果 |
|---|---|
| `/sys/class/drm` | `card0`、`card0-DSI-1`、`card0-Writeback-1`、`renderD128` |
| `card0-DSI-1/status` | **connected** |
| `card0-DSI-1/enabled` | **enabled** |
| `card0-DSI-1/modes` | **1440x3200** |
| 背光 `ae94000.dsi.0` | max 4095 / brightness **4095** / actual **4095** |
| dmesg | `msm_dpu ae01000.display-controller: bound ae94000.dsi`、`msm-dsi: lane rate 1360000000 Hz, byte clock 170000000 Hz`（与厂商参数一致） |
| `/dev/fb0` | 存在 |

#### 调试通道（终于有了）

`COM5`（115200）上就是真机的 root shell；`telnet 192.168.0.1` 也可以。后续所有外设调试都靠它。

#### 教训（已写进 troubleshooting 的思路）

**不能只按 `VID_1D6B` 判断「USB 没起来」**：先用 `Get-PnpDevice` 列出所有在位 USB（含无驱动的错误设备），
否则会把「枚举了但没驱动」误判成「完全没枚举」。

### 2026-10-30 深夜 第九轮：显示链路已编程但面板无应答

#### 已确认的现象链（v19 / v20）

| 检查 | 结果 | 判断 |
|---|---|---|
| `/sys/class/drm` | `card0`、`card0-DSI-1` | DRM 起来了 |
| `card0-DSI-1` status/enabled/modes | connected / enabled / 1440x3200 | 连接器与模式设置成功 |
| `crtc[103]: crtc-0` | `enable=1 active=1 plane_mask=1` | 管线完整打开 |
| `msm_dpu` | `bound ae94000.dsi`，`lane rate 1360000000 Hz` | PHY 参数正确 |
| 背光 `ae94000.dsi.0` | brightness/actual = 4095 | 软件状态已拉满 |
| fbcon | 已绑定，`fb0` 1440x3200x32 | 控制台有画布 |
| **面板 DCS 回读**（v20 加的调试） | `id=000000 (r=0,0,0)`、`get_power_mode` = **-61 (ENODATA)** | **面板不应答** |
| PM8550 GPIO11（`display_avdd` 的使能脚） | `in low`（其余 vddio/vci/vddd = `out high`） | AVDD 没打开 |
| `regulator_summary` 里面板四路 | 都 `enabled`，但 **0mA** | 软件“开了”，实际没供电 |

结论：**DSI 主机侧一切正常，问题在面板侧的供电/复位**。面板不应答 ⇒ 界面电源（VDDI/VCI）或复位没到位。

#### 待办

1. 从 **Android 活的厂商 DT** 读 `panel@0` 的真实 supply 与 reset（本机写的 `display_avdd` 5.5V 是从别处照搬的，
   厂商整树里根本没有 5.5V 稳压器节点）；
2. 按真值改 DTB：正确的 LDO / GPIO 与极性；
3. 再跑 v21，看 DCS 回读是否变成有效 ID（`0x38 0x0c 0x0a` 之类）。

### 2026-10-30 深夜 第十轮：面板供电的三个 DTS bug（v21/v22）

对着 **厂商基树/板级 dtbo** 逐项核对，查出三个真问题：

| # | 问题 | 厂商真值 | 我们的错 | 后果 |
|---|---|---|---|---|
| 1 | 面板供电路数 | `dsi_panel_pwr_supply_M2` 只有 **vddio(1.8V) / vddd(1.5V) / vci(3.0V)** | 多加了不存在的一路 `avdd`（PM8550 GPIO11 5.5V，该脚永远 `in low`） | 白占且误导 |
| 2 | `vddd` 引脚 | `display_panel_vddd: gpio = <&tlmm 0x42>` = **GPIO 66** | 写成 **GPIO 42** | vddd 从未真正打开 |
| 3 | **同名节点合并** | 每个稳压器节点名都不同（`display_panel_vddio` …） | 五个稳压器都叫 `gpio-regulator`，DT 里同名兄弟节点**被合并** | 最终只剩一个节点、`regulator-name` = 最后一个 `camera_ultra_avdd_ldo`，显示四路电源全部失效 |

第 3 条是最隐蔽的：`ls /proc/device-tree | grep -c regulator` 只有 2 个，`cat gpio-regulator/regulator-name` 返回
`camera_ultra_avdd_ldo` —— 显示供电的 label 都指向同一个（错误的）节点。

修正后（v22）：`gpio66 / gpio126 / gpio127 / gpio133` 全部 `out high`，DSI 时钟 `1.36 GHz VCO / 170 MHz byte / 226.67 MHz pixel` 全在跑，
`dsi_isr` 有中断，`crtc-0 enable=1 active=1`，背光 4095 —— 但**面板 DCS 回读仍返回 `id=000000` / `get_power_mode=-61 (ENODATA)`**。

#### 结论

主机侧（DRM/DSI/DPU/时钟/供电/复位）已经全部就绪，问题收敛到 **面板协议层**：
或初始化序列内容与我们解析的 blob 不一致，或该面板的读通道需要 HS 模式。下一步实验方向已明确。

### 2026-10-31 凌晨 第十一轮：主线显示到顶，转向 Lineage 参照

#### 已排除（v23–v26）

| 假设 | 做法 | 结果 |
|---|---|---|
| 大初始化序列解析错 | 与厂商 `qcom,mdss-dsi-on-command` 逐字节比对 | **977 字节完全一致** |
| 序列把我们搞死 | 最小初始化（只 0x11 + 0x29） | 面板仍不回话 |
| 上电时序 | 按厂商 vddio+1ms → vddd+1ms → vci+10ms 逐路上电 | 仍不回话 |
| LP 命令读不到 | 改 HS 模式读 | 仍 `-61 ENODATA` |
| 时钟 lane 常开 | 加 `MIPI_DSI_CLOCK_NON_CONTINUOUS` | 仍不回话 |
| DSI 接错 | 厂商树确认 `dsi-ctrl-num=0 / dsi-phy-num=0` | 我们用的就是 DSI0 ✓ |

已确认正常的：供电三路 GPIO（66/126/127）、复位 133、DSI 时钟（1.36 GHz VCO / 170 MHz byte / 226.67 MHz pixel）、
crtc active、背光 4095、fbcon 画布、`fb0/blank=0`。

#### 拿到的 Lineage 参照

- `LineageOS/android_kernel_xiaomi_sm8550-devicetrees` → `/home/l1872/nuwa/sm8550-devicetrees`
  - `qcom/display/display/dsi-panel-m2-38-0c-0a-dsc-cmd.dtsi`（本机面板官方定义）
  - `qcom/display/display/nuwa-sde-display-mtp.dtsi`（供电表、reset gpio 133、`bl_ctrl_dcs` + inverted dbv）
  - **`qcom,display-topology = <2 2 1>`**（2 mixer + 2 DSC + 1 intf，双 DSC）
- LineageOS 构建产物（`other/lineage/`）：`boot.img` 192 MB、`vendor_boot.img` 96 MB
  - 内核 = **Android GKI 5.15.220**（`#1 SMP PREEMPT`，clang 22）
  - **显示不在内核里**：`strings kernel | grep msm_drm` = 0，模块在 vendor_ramdisk/vendor_dlkm 中
  - `vendor_boot` 内含 8.1 MB 的 dtb 与 12.7 MB 的 `vendor_ramdisk00`（LZ4）

#### 待决策

- 路线 A：从 Lineage 内核源码构建（把 `DRM_MSM` 等做成内建），最可控，但需要克隆 + clang 工具链 + 编译
- 路线 B：直接用 Lineage 的 5.15 GKI 内核 + 从 2.2 GB ROM 里提取 `vendor_dlkm` 模块，在 initramfs 里 insmod

### 2026-10-31 凌晨 第十二轮：Lineage 内核路线与 ABL 载入限制

#### 新发现：`fastboot boot` 有 RAM 载入上限

- 主线镜像（≈10 MB）走 `fastboot boot` 一直正常；
- Lineage 内核 23–49 MB 的镜像 `fastboot boot` 直接报
  `Failed to load/authenticate boot image: Load Error`；
- 但**同样的镜像 `fastboot flash recovery_a` 能正常写入**。

⇒ 结论：**大镜像必须走分区（recovery_a）而不能走 RAM 启动**。以后选路线时按这个来。

（另：56 MB 那版曾打印 `Booting OKAY`，但那只是 ACK，随后设备自己退回 fastboot —— 不能用它当作「载入成功」的证据。）

#### Lineage 5.15 GKI 内核首测

镜像 L3 = `gzip(Lineage kernel 22.1 MB)` + 诱饵 DTB(930 KB) + 我们的 ramdisk(1.0 MB)，写入 `recovery_a` 后 `reboot recovery`：
**无 USB 枚举、无 COM 口，设备落回 fastboot** ⇒ 该内核没能起来（其显示/USB 都是模块，缺 `vendor_dlkm`）。

已回刷原厂 `recovery.official.img` 并确认设备回到 Android（`adb devices` = device）。

#### 并行推进（子代理）

- 路线 A：从 `LineageOS/android_kernel_xiaomi_sm8550` 自建内核（显示/USB 内建）
- 路线 B：下载 2.2 GB ROM → 提取 `vendor_dlkm.img` → 得到 5.15.220 配套模块，塞进 ramdisk 里 insmod

initramfs 的 `/init` 已升级：会读 `/lib/modules/$(uname -r)/nuwa-load.list` 或 `modules.dep` 按序 insmod（内建内核自动跳过）。

### 2026-10-31 凌晨 第十三轮：与 fuxi 逐项对比 + Lineage 路线取证受阻

#### fuxi（同代 SM8550，主线显示已通）对比结论

| 项 | fuxi | 我们（nuwa） | 判断 |
|---|---|---|---|
| 复位脚 | `<&tlmm 133 GPIO_ACTIVE_LOW>`，驱动 `direction_output(1)`→`set(0)`，物理：低 1ms → **高** 10ms | `GPIO_ACTIVE_HIGH`，驱动 `set(0)`→`set(1)`，物理：低 1ms → **高** 10ms | **完全一致，不是问题** |
| `&mdss` iommus | `<&apps_smmu 0x1c00 0x2>` | 基树自带，编译后 DTB 里确实是 `3c 1c00 2` | **一致** |
| `mdss_dsi0_out` | `data-lanes = <0 1 2 3>` | 同 | 一致 |
| DSI 标志 | `CLOCK_NON_CONTINUOUS + DSC_ALL_SLICES_IN_PKT`，lanes=4 | 同 | 一致 |
| 面板 | `xiaomi,fuxi-m3-38-0c-0a`（1080×2400，8bpc） | `samsung,amb673cp01-m2`（1440×3200，10bpc） | 面板本身不同 |

结论：**主线侧的显示配置与 fuxi 没有实质差异**，面板仍不回 DCS 读（`-61 ENODATA`），
说明问题不在这些可对比的 DT/驱动参数上（已排除 6+1 项），继续在主线里盲调性价比很低。

#### Lineage 路线（B）的进展与障碍

- 已确认 **Lineage 5.15 内核 + 我们的 initramfs 确实会执行**：用「3 秒后主动 panic」的探针镜像，
  设备表现为**一开机就重启**（ABL 反复重试 recovery），这正是探针生效的证据。
- 但 **pstore 拿不到日志**：本机崩溃日志走 `block2mtd=/dev/block/sda16` + `mtdoops`（见 Android cmdline），
  不是 ramoops，所以 `/sys/fs/pstore` 为空。
- 加载全部 49 个模块（显示+USB）→ **内核崩溃重启循环**；只加载 14 个 USB 模块 → 不崩但 USB 不枚举。
  需要日志才能定位，因此改用**分区落盘**：L9 镜像会加载 USB+UFS 模块，把 insmod 结果与 dmesg 写进
  `crash_history`(sda20)，然后自动关机。
- 分区标签已取全：`cust -> sda30`（2 GB）、`crash_history -> sda20`、`dbg -> sda3` 等。

### 2026-10-31 00:30 第十四轮：vddd 引脚修正回 GPIO 42（正解但要害不在这里）

#### 重要更正

本机 **活设备树**（Android `/sys/firmware/fdt` 导出，938,828 B）里：

| 电源轨 | 厂商活 DT | 我们的值 |
|---|---|---|
| vddio | `gpio = <&tlmm 0x7e>` = 126 | 126 ✓ |
| vci | `gpio = <&tlmm 0x7f>` = 127 | 127 ✓ |
| **vddd** | **`gpio = <&tlmm 0x2a>` = 42** | v21 起被改成 66 ✗ |

v21 里“42→66”的依据是 `dtbo-32`（**另一个 hwid 变体**的 overlay，`gpio = 0x42`）。
本机实测应为 **42**，已改回（v27）。

注意历史：v19/v20 虽然写的是 42，但当时**稳压器同名合并 bug 未修**，42 并不是被我们的 vddd 驱动的；
v22 修好合并 bug 时引脚已经是 66。所以「vddd=42 + 合并 bug 已修」这个组合直到 v27 才第一次被测到。

#### v27 结果（唯一变量：vddd 42）

- `gpio42 : out high`（我们的 vddd 真正驱动了它）
- `gpio66 : in low`（现在没人用了）
- 面板回读：**仍 `id=000000` / `get_power_mode = -61 ENODATA`**

#### 结论

**三路供电引脚全对、全高电平、复位已释放（gpio133 out high）、DSI 时钟全在跑（1.36G/170M/226.67M）、
`prepare_prev_first=true`、DCS 包类型按 blob 保留、iommus/data-lanes/TE(gpio86) 均与厂商一致 —— 面板依然不应答。**

⇒ “配置层”的假设已全部排除。剩余可能是 **DSI 物理链路层**（mainline `sm8550-dsi-phy-4nm` 对该 PHY 的实际编程）
或**面板侧**（上电时序/内部状态机）。下一步应转向：读 DSI 错误计数器/中断，以及用 TE(gpio86) 边沿判定面板是否活着。

### 2026-10-31 01:40 第十五轮：**面板是活的**——接管把 TE 停掉了

> ⚠️ 证据等级更正（用户 2026-10-31 明确）：**v29–v32 这四版没有目视确认屏幕状态**
> （v29 软复位+20ms、v30 复位前读取、v31 TE=timer0、v32 借用画面构建失败），
> 这几版的“画面”结论只来自 dmesg，未经人眼。
> **v19–v28 已由用户目视确认（均为黑屏）**；v33（借用画面 + 写彩噪）目视仍全黑。

#### 一、厂商 debugfs 黄金快照（首次采集）

Android 侧挂载 debugfs 后可读 `qcom,mdss_dsi_m2_38_0c_0a_dsc_cmd`：

```
CTRL_ENGINE = ON / VIDEO_ENGINE = OFF / COMMAND_ENGINE = ON
BYTE_CLK = 170000000, PIXEL_CLK = 226666666, ESC_CLK = 19200000
```

与我们的 170 MHz byte / 226.67 MHz pixel **完全一致**。

#### 二、面板参数逐项对照（活设备树 vs 我们的驱动）

| 项 | 厂商值 | 我们 | 判定 |
|---|---|---|---|
| 面板型号 | `M2_PANEL_PA` (`0x4d3200380c00`) | `samsung,amb673cp01-m2` | ✓ |
| DSI 控制器/PHY | `dsi-ctrl-num=0`, `dsi-phy-num=0` | 只用 dsi0/phy0 | ✓ **单 DSI，不是双 DSI** |
| 拓扑 | `<2 2 1>`（2 mixer, 2 DSC, 1 intf） | 同 | ✓ |
| clockrate | `0x510ff400` = 1.36 GHz | 同 | ✓ |
| porch | h 32/32/16, v 24/24/8 | 同 | ✓ |
| 分辨率 | 1440×3200 | 同 | ✓ |
| DSC | 720×25×2, 8bpp, 10bpc, v1.2, block-pred | 同 | ✓ |
| reset-sequence | `<0 1 1 5>` | 低1ms→高10ms | ✓ |
| 背光 | min 4 / max 4095 | 同 | ✓ |
| TE | `platform-te-gpio = <tlmm 86>`，`te-pin-select=1` | gpio86 `mdp_vsync` | ✓ |
| 供电 | vci 3.0 / vddio 1.8 / **vddd 1.5** | 同（vddd 引脚本轮修正为 **GPIO 42**） | ✓ |

→ **配置层已无任何可对比的差异**。之前“双 DSI”的猜测被 `dsi-ctrl-num=0` 否定。

#### 三、DCS 读不可用作存活判据

在 **复位之前**（此时面板仍由 bootloader 初始化、屏幕上还是 logo）读 `0x0A`，
依然返回 `-61 ENODATA`。⇒ 主线 msm 的 DCS 读路径本身不通，不能用它判断面板死活。

#### 四、⚠️ 关键实验：关掉 mdss 后 TE 会跳变

v33 里把 `&mdss { status = "disabled"; }`（完全不接管 DPU/DSI），然后采样 `gpio86`：

```
10 次 `: in  hig`  /  10 次 `: in  low`     ← TE 在正常翻转
dmesg | grep -c msm_dpu  →  0            ← 确认我们没接管
```

对比之前接管时：**40 次采样恒为 `low`**。

**结论：面板是活的、已上电、已初始化、处于 display-on；是“我们的接管”把它停掉的。**

#### 五、借用固件画面（v32→v33）

- v32 失败：`0xb8000000` 当时是普通 System RAM，`__ioremap_prot` 告警，simpledrm 起不来
- v33 修复：把 `0xb8000000`(45 MB) 声明为 `no-map` 保留区 → `simpledrm 1.0.0 for b8000000.framebuffer`，
  `/dev/fb0` = 1440×3200 stride 5760 ✓
- 但写入彩噪后用户目视 **仍全黑** ⇒ bootloader 在交接时已停止扫描，
  “借用画面”这条路在本机 **不成立**（与 fuxi 不同）

#### 六、下一步（无需用户目视也能验证）

有了 TE 这个客观信号，可以完全不靠眼睛做二分：

1. **mdss 开、但面板驱动不做 reset/init**（只 attach + display on）：若 TE 继续跳 → 是我们的 reset/init 序列把面板弄停；若 TE 立刻停 → 是 DPU 接管动作本身
2. 按 1 的结论再二分：只关 reset / 只关 init / 只关 DPU 上电
3. 判据统一用：`TE(gpio86)` 是否翻转 + `encoder-0/status` 的 `frame_done_cnt` 是否增长

### 2026-10-31 02:15 第十六轮：TE 二分定位到「复位后唤醒」

#### 一、用 TE(gpio86) 作客观判据的二分结果

| 驱动对面板做了什么 | TE | 结论 |
|---|---|---|
| 完全不接管（mdss 关） | 10高/10低 | 面板本来活着 |
| 只上电（不复位不初始化，mdss 开） | 跳变 | **上电无害** |
| 上电 + 复位 | 恒低 | 复位把面板打回睡眠（动作有效） |
| 上电 + 完整初始化（**不复位**） | 跳变 | **初始化序列无害，DSI 写在通** |
| 上电 + 复位 + 完整初始化 | 恒低 | 复位后唤不醒 |
| 复位后等 120ms / 500ms | 恒低 | 非等待时间问题 |
| 复位极性翻转 | 恒低 | 非极性 |
| 复位后用 HS 发命令 | 恒低 | 非 LP/HS |
| 时钟 lane 常开 | 恒低 | 非非连续时钟 |
| 最小唤醒 0x11/0x35/0x29 | 恒低 | 复位后命令到不了面板 |

#### 二、概念纠正

`encoder-0/status` 的 `frame_done_cnt` 实际是 **frame_done_timeout_cnt（超时次数）**，
`0` = 零超时，不是「没有帧」。DPU 全程健康：无 underrun、无 vblank 超时、vsync 正常。

#### 三、当前最佳候选 v45

`other/abl-nuwa-disp-v45-noreset-white.img`（12,853,248 B，sha256 `5d64af65…`）

- 配置：**不复位** + 完整厂商初始化序列 + init 里画纯白 + 背光拉满
- 实测：`NUWA_WHITE written`、fb0 首字节 `ff ff ff ff`、TE 9高/11低（面板活着）
- 待用户目视：屏幕是否纯白
- 测试方式：`private\try-v45.ps1`（纯 RAM 启动，不写分区）

#### 四、下一步

1. v45 出白屏 → 显示通路成立，接着做 fbcon/桌面
2. v45 仍黑 → 帧没到面板，查 DSI 命令 DMA 发送与 PHY 输出
3. 「复位后唤不醒」单独攻：对照厂商 `mdss_dsi_panel_reset()` 的完整时序

### 2026-10-31 02:30 第十七轮：与 fuxi 驱动逐行对比 + 两个待测候选

#### 一、与能工作的 fuxi 面板驱动逐行对比结果

| 项 | fuxi（工作） | 我们 | 判定 |
|---|---|---|---|
| 上电顺序 | 逐路上电 + post_on 延时 | 同 | ✓ |
| 复位前 | `gpiod_direction_output(reset, 1)` → 1ms → `set_value(0)` → 10ms | **直接 `set_value(0)`**（未显式设方向，`GPIOD_ASIS`） | ⚠️ 差异 |
| 物理电平 | ACTIVE_LOW：先低(1ms)后高 | ACTIVE_HIGH：先低后高 | ✓ 等价 |
| 初始化前 | `mode_flags \|= MIPI_DSI_MODE_LPM` | `LPM \| CLOCK_NON_CONTINUOUS` | 近似 |
| `prepare_prev_first` | true | true | ✓ |
| 命令发送 | 逐条 DCS helper | 按 blob type 字节分发 | ✓ 等价 |
| DSC/PPS | 驱动打包 PPS | 厂商 blob 内嵌 PPS | ✓ |

→ 唯一实质差异：**fuxi 显式把复位脚配成输出**，我们依赖 `gpiod_set_value` 的副作用。

#### 二、两个待测候选（设备关机中，未上机）

| 候选 | 改动 | 镜像 |
|---|---|---|
| **v46** | 复位**前**先发厂商关机序列（`0x28`→20ms→`0x10`→100ms），再复位再初始化（模仿厂商有序关机） | `other/abl-nuwa-disp-v46-offfirst.img` 12,853,248 B `9eda3363…` |
| **v47** | 复位前 `gpiod_direction_output(reset, 1)` + 1ms（照抄 fuxi） | `other/abl-nuwa-disp-v47-dirout.img` 12,853,248 B `9f8f8eee…` |

测试脚本：`private/test-v46.ps1`（同法可测 v47，改 `$img` 一行）。
判据：`TE(gpio86)` 是否恢复跳变。

### 2026-10-31 02:45 第十八轮：确认 DSI 命令确实发出去了

源码级排查（`drivers/gpu/drm/msm/dsi/dsi_host.c`）：

- `dsi_host_transfer()`：`if (!msm_host->power_on) return -EINVAL;`
  → 我们的写入全部返回 0，**说明 DSI host 已 power_on**
- `dsi_cmd_dma_tx()`：单 DSI 情况下 `msm_dsi_manager_cmd_xfer_trigger()` 返回 true，
  随后 `wait_for_completion_timeout(200ms)` 等 `CMD_DMA_DONE` 中断，超时会返回 `-ETIMEDOUT`
  → 我们从未收到超时，**说明命令 DMA 完成、数据真的发到 lane 上了**

⇒ 结论：**LP 写路径是通的，命令确实发送并被控制器确认完成**。
故障因此收敛为“面板收到了但不执行/不响应”。

结合第十七轮：复位后所有命令都不生效；不复位时同一套命令无害。
最可能的原因是**复位把面板置入一个需要特殊唤醒序列的状态**，
而不是 DSI 发送链路的问题。

#### 待测候选（设备关机中）

- **v46** `other/abl-nuwa-disp-v46-offfirst.img` `9eda3363…`：复位前先发厂商关机序列
- **v47** `other/abl-nuwa-disp-v47-dirout.img` `9f8f8eee…`：复位前显式 `gpiod_direction_output`
- **v45** `other/abl-nuwa-disp-v45-noreset-white.img` `5d64af65…`：不复位 + 画纯白（最可能出画面）

### 2026-10-31 02:40 第十九轮：v48 寄存器自检就绪

新增 `CONFIG_NUWA_REGDUMP`：在 `dsi_host_transfer()` 每次传输后打印控制器状态，
上机即可看清面板到底有没有 ACK：

```
NUWA_DSI t=<type> len=<n> ret=<r> ackerr=<ACK_ERR_STATUS> tmo=<TIMEOUT_STATUS>
         dln0=<DLN0_PHY_ERR> st0=<STATUS0> fifo=<FIFO_STATUS> lswap=<LANE_SWAP_CTRL>
```

- `ackerr` 非 0 ⇒ 面板 NACK / 不应答（链路或面板问题）
- `tmo` 非 0 ⇒ 传输超时
- `dln0` 非 0 ⇒ lane0 PHY 层错误
- `lswap` 用来确认 lane 顺序（厂商 `lane_map_0123`，与默认一致）

产物：`other/abl-nuwa-disp-v48-regdump.img` 12,853,248 B `c18e0d1f…`，脚本 `private/test-v48.ps1`。

注：主线没有 DSI 的 debugfs，DPU 侧有 `crtc-0/crc` 可做帧内容校验。

### 2026-10-31 02:50 第二十轮：v49 一次启动出全阶段矩阵（设备关机，未上机）

#### 分阶段 TE 采样的实现

利用 SM8550 TLMM 布局（每引脚块 `0x1000`，输入寄存器在块内偏移 `0x4`，bit0 = 电平）：

```c
readl(0x0f100000 + 0x4 + 0x1000 * 86) & 0x1    /* gpio86 (TE) 电平 */
```

在 `prepare()` 的三个阶段各采 200 ms（2000 次 × 100 µs）数边沿：

```
NUWA_TE_STAGE after-rails  edges=? last=?
NUWA_TE_STAGE after-reset  edges=? last=?
NUWA_TE_STAGE after-init   edges=? last=?
```

判读：`after-init` 有边沿 ⇒ 面板被成功唤醒；无边沿 ⇒ 复位后唤醒失败，转查 `ackerr`。

产物：`other/abl-nuwa-disp-v49-stageprobe.img` 12,853,248 B `919c6271…`，脚本 `private/test-v49.ps1`。

#### 待上机候选清单（全部已构建）

| 版本 | 作用 | 判据 |
|---|---|---|
| v49 `919c6271…` | 三阶段 TE 自检 | 一次定性 |
| v48 `c18e0d1f…` | DSI 寄存器自检 | `ackerr` 面板是否 ACK |
| v46 `9eda3363…` | 复位前有序关机 | TE 是否恢复 |
| v47 `9f8f8eee…` | 复位前显式 direction_output | TE 是否恢复 |
| v45 `5d64af65…` | 不复位 + 画纯白 | 人眼看白屏 |

一键脚本：`private/run-matrix.ps1`（依次跑 v48/v46/v47/v45 并汇总到 `private/matrix-report.txt`）。

#### 阻塞

**设备处于关机状态，无法远程开机**（`adb`/`fastboot`/COM 全部不可见）。
所有后续结论都必须上机，需人工按电源键开机。

## 2026-10-29 突破：内核首次真机启动

### 根因一：breadcrumb 写了一个不存在的物理地址

此前所有「内核没起来」的现象，根因是一行调试代码：

    SYM_CODE_START(primary_entry)
        bl      record_mmu_state
        /* NUWA_BREADCRUMB (checkpoint 1) */
        movz    x28, #0x0008, lsl #32
        movk    x28, #0xd300, lsl #16
        movk    x28, #0x3000          // x28 = 0x8d3003000 约 37.9 GB
        str     x27, [x28]            // <- data abort，内核死在第一条指令

0x8d3003000 = **37.9 GB**，远超本机 RAM（十几 GB）。MMU 关闭时写这个地址直接
data abort。UniXNU 读到的 n1 FFF7FFFF / ck 5C57DFBF 全是总线返回的垃圾值，
所以「kernel died before arm_init」其实是**被自己的调试代码杀掉的**。

DT 里我们自己加的 nuwa-note-region@8b9f0000（0x8_8b9f0000）也与该地址不符。

### 处置

移除全部 4 处 breadcrumb（head.S 三处、init/main.c 一处）后重新编译，
内核**正常启动并执行到 initramfs**：屏幕出现 Linux 输出，随后黑屏，
300 秒（原 120 秒）后自动重启 —— 证明 /init 完整执行。

### 根因二：UniXNU 的日志永远看不见

UniXNULog() 只写 DebugLib 和 SerialIo，**从不输出到屏幕**。
所以 boot: LoadImage ... %r 这类关键错误一直写进看不见的地方。
现在已改为：内核 initramfs 把诊断摘要写入 ESP，UniXNU 读出来显示在菜单底部。

| 文件 | 内容 |
|---|---|
| \nuwa-log.txt | 完整 dmesg + 显示 / USB / backlight 状态 |
| \nuwa-summary.txt | 3 行摘要，显示在 UniXNU 菜单底部 |

### 当前剩余问题

**显示在启动后期黑屏**。内核早期有输出（efifb / earlycon 工作），之后画面消失。
候选原因：fbcon 被 DRM 接管后 unregister、背光被关、或 panel 断电。
诊断依赖 nuwa-summary.txt 里的 bl= / drm= 字段。


### 2026-10-30 夜间：显示与 UFS 的配置缺口（设备离线，静态分析）

| 缺口 | 影响 | 处置 |
|---|---|---|
| `CONFIG_SYSFB_SIMPLEFB` 未启用 | 即使 DT 有 simple-framebuffer 节点也不会创建 fb 设备 | 改为 `=y` |
| `CONFIG_FB_SIMPLE=m` | simplefb 是模块，initramfs 无模块 | 改为 `=y` |
| DT 缺 simple-framebuffer 节点 | 内核不知道固件在扫哪块内存 | 两侧 DTS/dtb 都加 |
| `CONFIG_PHY_QCOM_QMP_UFS=m` | UFS PHY 是模块，UFS 不 probe | 改为 `=y` |
| cmdline 无 iommu.passthrough | UFS 的 iommus 走 SMMU，未映射会 DMA fault | 加 `iommu.passthrough=1` |
| gop.c 跳过 BLT-only GOP | Qualcomm DisplayDxe 是 BLT-only，efifb 不注册 | base/size 非 0 时接受 |

simple-framebuffer 节点参数：`reg = <0xb8000000 0x1194000>`、1440x3200、
stride 5760、format a8r8g8b8。来源是 DTS chosen 里遗留的注释
`earlycon=simplefb,0xb8000000,1440,3200`，与 SimpleFbDxe 的 Display Reserved 区域一致。

**纠正一条此前的误判**：nuwa DTS 里 `&ufs_mem_hc` / `&ufs_mem_phy` 配置一直是完整的
（含 `status = "okay"`、reset-gpio 210、三路电源），此前判断「缺 ufshc 节点」是 grep
关键字写成了 `&ufshc` 而实际节点名是 `&ufs_mem_hc`。

**v4 补了关键一环**：simplefb probe 会调用 `request_mem_region()`，对 System RAM
区域必然失败，因此 framebuffer 必须先从 RAM 中剔除。已在两侧 DTS/dtb 的
`reserved-memory` 里加 `framebuffer@b8000000`（reg `0x0 0xb8000000 0x0 0x1194000`，
不带 `no-map`，保留可 ioremap 且 linear mapping 仍有效）。

**v5 再修一处**：SimpleFbDxe 用的是 `PixelBlueGreenRedReserved8BitPerColor`（BGRA），
simplefb 的 `format` 因此从 `a8r8g8b8` 改为 `b8g8r8a8`，否则红蓝互换。

v5 产物：`other/uefi-nuwa-v5/Mu-nuwa.img`（2de1733e…）、
`other/payload-bootb-v5.img`（8359201f…，内核自 v3 起未变，改动全在 dtb）。

已验证的 dtb 参数：width 0x5a0(1440)、height 0xc80(3200)、stride 0x1680(5760)、
format b8g8r8a8；chosen 与 reserved-memory 两处 framebuffer@b8000000 节点都在。

另外确认：`CONFIG_FRAMEBUFFER_CONSOLE=y` 且 `FRAMEBUFFER_CONSOLE_ROTATION=y`，
fbcon 侧没有缺口；所有 backlight/LED 驱动都是 `=m`（不加载），因此内核不会关背光，
屏幕亮度保持 UEFI 状态。

**v6 加了一条兜底通道**：关掉 `CONFIG_STRICT_DEVMEM`，init 在 `/dev/fb0` 不存在时
直接用 `dd` 写 `/dev/mem` 偏移 `0xB8000000`。这条路径不依赖任何显示驱动，
只要物理 framebuffer 可写，屏幕就会出现噪点——用来把「framebuffer 不可写」和
「驱动没注册」这两种情况区分开。

v6 组合：`boot_a` 用 `other/uefi-nuwa-v5/Mu-nuwa.img`（2de1733e…，dtb 已是 b8g8r8a8）、
`boot_b` 用 `other/payload-bootb-v6.img`（内核 a283ff18…）。

**三项排除性验证**（都是好消息，消除了风险）：

| 检查 | 结果 | 意义 |
|---|---|---|
| `CONFIG_DRM_MSM` | `# is not set`，无 `msm.ko`，System.map 无 `msm_dpu` | MSM 绝不会 probe，simplefb 可独占显示，不会被抢硬件 |
| busybox applet | Ubuntu `busybox-static` 1.37.0，标准 applet 齐全 | init 里 `dd`/`tr`/`cut`/`wc`/`ip` 都可用（本机是 x86_64 跑不了 aarch64 busybox，只能间接确认） |
| 原厂 ufshc 节点 | 与主线 `sm8550.dtsi` 基本一致，唯一差异是原厂多了 `qcom,ice`（可选加密引擎） | UFS 不 probe 不是 DT 缺属性导致的，需要设备 dmesg 才能继续 |
| UFS 静态依赖链 | `INTERCONNECT_QCOM_SM8550=y`、`INTERCONNECT_QCOM_BCM_VOTER=y`、`QCOM_GDSC=y`、`QCOM_RPMH/PD=y`、`COMMAND_DB=y`、`SCSI_UFS_QCOM=y`、`PHY_QCOM_QMP_UFS=y` 全部内建 | 配置层面已无可查，UFS 问题只能是运行时（时钟/PHY/SMMU），必须靠设备 dmesg |

**副作用提示**：MSM 不编也意味着原生显示接管（DPU+DSI）完全没有编译进去，
将来做 panel driver 时要先把 `CONFIG_DRM_MSM=m` 打开并按模块方式调试。

### 2026-10-30 凌晨：拿到完整的面板配置（原生接管的钥匙）

在 GitHub 上找到了 nuwa 的原厂设备树源码，已存进 `public/nuwa/resources/`：

| 文件 | 大小 | 内容 |
|---|---|---|
| `panel-m2-38-0c-0a.dtsi` | 142 KB | **面板完整配置，含 14 段 `mdss-dsi-on-command` 初始化序列** |
| `nuwa-sde-display-mtp.dtsi` | 5.8 KB | 面板供电、背光、reset-gpio 绑定 |
| `nuwa-sm8550.dtsi` | 12 KB | nuwa 板级基础 dtsi |

来源：`LineageOS/android_kernel_xiaomi_sm8550-devicetrees`，分支 `lineage-24.0`，
路径 `qcom/display/display/`。

提取到的关键参数：

```
panel-name      xiaomi 38 0c 0a cmd mode dsc dsi panel
resolution      1440 x 3200
DSC version     0x12 (1.2), slice-width 720, bits-per-pixel 8
framerate       60 Hz / 120 Hz 两档 timing
clockrate       1,360,000,000 Hz
reset-gpio      tlmm 133（与主线 DTS 一致）
backlight       bl_ctrl_dcs（DCS 命令控制，不是独立背光芯片）
```

**这条信息改变了两件事**：

1. 背光是 **DCS 控制**的，没有独立背光芯片。所以 `bl_ctrl_dcs` 那条 DCS 命令必须发，
   否则面板不上背光。之前 summary 里 `bl=none` 是正常的（没有 backlight class 设备）。
2. 原生接管不再是「从零写驱动」——初始化序列、时序、DSC 参数全部现成，
   可以照着 `panel-samsung-*` 的框架改编，工作量从「一到两周」降到「几天」。

**初始化序列已解析**（`public/nuwa/tools/parse-panel-dtsi.py`）：

```
第一段 on-command：977 字节 → 74 条 DCS 命令
  [0] type=0x39 len=129  0x9e ...   DSC PPS（压缩参数）
  [1] type=0x15 len=2    0x9d 0x01  DSC 使能
  [2] type=0x05 len=2    0x11 0x00  Sleep Out
  [3] type=0x15 len=2    0x35 0x00  Set Tear On
  [4] type=0x39 len=5    0x2a ...   Set Column Address
  [5] type=0x39 len=5    0x2b ...   Set Page Address
```

Qualcomm 的 `mdss-dsi-on-command` 是专有打包格式（type/last/vc/ack/wait/len/payload），
转换工具已能正确拆解，可直接生成 `mipi_dsi_dcs_write_seq()` 调用。
注意 dtsi 里有 14 段 on-command，分属不同 timing（60Hz/120Hz 各一套），写驱动时要按
`dsi_panel` 的多 timing 机制分开处理。

### 2026-10-30 凌晨：simplefb 的两个关键校正

读 `drivers/video/fbdev/simplefb.c` 源码后校正了两处此前的判断：

**校正一：格式名写错了。** `SIMPLEFB_FORMATS` 宏（`include/linux/platform_data/simplefb.h`）
只认这 11 个名字：

```
r5g6b5 r5g5b5a1 x1r5g5b5 a1r5g5b5 r8g8b8 x8r8g8b8
a8r8g8b8 x8b8g8r8 a8b8g8r8 x2r10g10b10 a2r10g10b10
```

**没有 `b8g8r8a8`**。v5 里写的 `b8g8r8a8` 会让 `simplefb_parse_dt()` 返回
`Invalid format value` 而 probe 直接失败。BGRA 的正确名字是 **`a8b8g8r8`**，已改。

**校正二：`request_mem_region` 失败不是致命的。** 源码里失败只 `dev_warn` 然后
沿用原 resource 继续 `ioremap_wc`。所以 reserved-memory 不是硬性前提，但保留它更稳妥
（能避免内核把这块 RAM 分配出去）。

另外确认：DT 没有 `clocks`/`regulators` 不会导致 probe 失败
（`simplefb_clocks_get()` 在 `of_clk_get_parent_count()==0` 时直接返回 0）。
真正会让 probe 失败的是 `devm_aperture_acquire_for_platform_device()`——
它和 efifb 互斥：efifb 成功则 simplefb 让位，efifb 失败则 simplefb 接管，两者互补。

v7 产物：`other/uefi-nuwa-v7/Mu-nuwa.img`（ae3b848c…，format 已修正）、
`other/payload-bootb-v7.img`（内核 a283ff18…，与 v6 相同）。
最终 dtb 参数：1440x3200 / stride 5760 / `a8b8g8r8`。

### 为什么「早期有画面、之后黑屏」——机制已确认

`efifb_probe()` 里有一行硬性门槛：

```c
if (!si->lfb_linelength)
        return -ENODEV;
```

efi stub 面对 BLT-only GOP 时拿不到 stride（`lfb_linelength` 为 0），于是 efifb
**直接放弃注册**。而 `earlycon=efifb` 只需要 `lfb_base`/`lfb_width`/`lfb_height`/`lfb_depth`，
不要求 linelength，所以启动早期仍然能往 framebuffer 写字。

这完整解释了现象：earlycon 画出内核日志 → 内核接管后 earlycon 退场 → 没有 efifb、
没有 fbcon → 画面停住变黑。同时也确认 **aperture 是空闲的**
（`devm_aperture_acquire_for_platform_device()` 没被 efifb 占），simplefb 可以顺利接管。

这也修正了最早的一个推断：不是「GOP 完全不可用」，而是「GOP 可用但缺 stride 字段，
导致 efifb 的门槛过不去」。所以 v7 让 simplefb 用 DT 里写死的 stride 5760 补上这个缺口，
方向是对的。

### UFS 静态分析收尾（结论：配置无懈可击，只剩运行时）

逐项核对完最后两个疑点，都与原厂一致：

| 项 | 原厂 | 主线 | 结论 |
|---|---|---|---|
| `phy@1d80000` clocks | ref / ref_aux / qref 三个 | `RPMH_CXO_CLK` / `GCC_UFS_PHY_PHY_AUX_CLK` / `TCSR_UFS_CLKREF_EN` | 一致 |
| `ufs_mem_phy` power-domain | `<gcc 0x05>` | `UFS_MEM_PHY_GDSC` = **5** | 一致 |
| `ufshc` power-domain | `<gcc 0x04>` | `UFS_PHY_GDSC` = **4** | 一致 |

至此 UFS 的静态面全部核对完毕：驱动配置、DT 节点、时钟、电源域、interconnect、
分区表支持、PHY 全部正确。**问题只能是运行时**——PHY 校准、时钟实际频率、
SMMU 映射、或 4 KiB 逻辑块下的 GPT 解析。这些都必须靠设备 dmesg 判断，
而 dmesg 又依赖显示先通。所以当前唯一有效的下一步仍然是：让屏幕亮起来。

### 2026-10-30 凌晨：初始化序列转成 C 代码

面板 dtsi 里有 7 个 timing（60/120/40/30/24/120/120 Hz），每个各带一套完整
`mdss-dsi-on-command`（977~1046 字节）。已全部转成 C 数组：

```
public/nuwa/resources/panel-amb673cp01-sequences.h   43 KB  630 行
  seq_60hz_0   seq_120hz_0   seq_40hz_0   seq_30hz_0
  seq_24hz_0   seq_120hz_1   seq_120hz_2
```

生成器：`public/nuwa/tools/gen-panel-seq.py`（可重复运行，dtsi 更新后重生成）。

**注意**：这三套 120 Hz 序列内容不同（1016~1046 字节），对应不同的 DSC 压缩比或
timing 变体。写驱动时必须按 `dsi_panel` 的 timing 索引正确对应，不能随便挑一套。
数组保持 Qualcomm 打包格式（type/last/vc/ack/wait/len/payload），在 probe 时
解析后逐条 `mipi_dsi_dcs_write_seq()` 发送。

### 2026-10-30 凌晨：panel driver 骨架编译通过

发现 `drivers/gpu/drm/panel/panel-nuwa-m2.c` 已存在（旧骨架，167 行，
`CONFIG_DRM_PANEL_NUWA_M2=m` 已启用），但它从未工作过，原因有五个：

| 问题 | 后果 |
|---|---|
| `compatible = "xiaomi,nuwa-m2-panel"` | DTS 里是 `samsung,amb673cp01-m2`，**永远不匹配** |
| 没有初始化序列 | 面板不上电 |
| `mode_flags = MIPI_DSI_MODE_VIDEO` | 这块屏是 **command mode**，标志写反了 |
| 没有 `dsi->dsc` 配置 | DSC 压缩不生效 |
| 没有 `mipi_dsi_attach()` | 根本没接到 DSI host |

已用新版本整体覆盖（保留文件名以复用已有 Kconfig/Makefile），并修正：

- `of_match` 同时匹配 `samsung,amb673cp01-m2` 和 `xiaomi,nuwa-m2-panel`
- `mode_flags` 改为 `CLOCK_NON_CONTINUOUS | VIDEO_NO_HFP | VIDEO_NO_HBP | VIDEO_NO_HSA | NO_EOT_PACKET`
- DSC 1.2：slice 720x25、`bits_per_component=10`、`bits_per_pixel=8<<4`、`block_pred_enable`
- 加入 `amb673cp01_send_seq()`：解析 Qualcomm 打包格式并逐条下发
- `mipi_dsi_attach()` / `detach()` 补齐
- 60Hz 时序从 dtsi 提取（hfp32/hbp32/hpw16/vfp24/vbp24/vpw8）

**编译验证通过**：`panel-nuwa-m2.o`（54 KB），符号 `amb673cp01_probe`、
`amb673cp01_of_match` 均存在。

**仍是骨架，未在真机验证**。三个已知待办：

1. 多 timing 切换：目前只发 60Hz 序列，120/40/30/24Hz 未接
2. 背光：`bl_ctrl_dcs` 需要在 enable 时下发 DCS 背光命令
3. `CONFIG_DRM_MSM` 必须打开（当前 `# is not set`），否则 panel 驱动没有 host 可挂

**待验证**：刷 v3 后按 1 启动，看屏幕是否持续有日志（不再黑屏），
以及 init 能否挂载 ESP 写出 nuwa-log.txt。
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
