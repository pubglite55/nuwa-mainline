# ABL 直启路线（fuxi 移植法）

> 最后更新：2026-10-30
> 参考实现：[ilovecnxx/xiaomi13-fuxi-linux-build](https://github.com/ilovecnxx/fuxi-linux-build)、
> [xiaomi13-fuxi-linux-ubuntu26.10-kernel7.3](https://github.com/ilovecnxx/xiaomi13-fuxi-linux-ubuntu26.10-kernel7.3)
> 关联：[uefi-route.md](uefi-route.md)（旧路线）、[tech-debt.md](tech-debt.md) TD-11

## 一句话

不再经过自制 UEFI。把主线内核打包成 **Android boot.img（header v1）**，
kernel 字段放 `Image.gz + 厂商 DTB`，写进 **`recovery_a`** 分区；
ABL 在 recovery 引导模式下会直接加载它并跳转，内核用**编进内核的主线 DTB**
（`CONFIG_NUWA_FORCE_BUILTIN_DTB`）覆盖 ABL 传进来的 DTB。

## 为什么放弃 Mu UEFI

同一块 SM8550 的 fuxi 移植已经在真机上跑通桌面，它同样**没有**用 Mu UEFI。
回头看 Mu UEFI 路线上那几个死结，全部只在 UEFI 里存在：

| 死结 | 现象 | ABL 路线为何没有 |
|---|---|---|
| GOP 只有 BLT、stride = 0 | `efifb` 在 `!lfb_linelength` 处直接放弃 → 黑屏 | 不需要 UEFI framebuffer，画面由 MSM/DPU 自己出 |
| simple-framebuffer 只继承一次 | 内核接管后资源被回收 → 2–3 秒后黑屏 | 不存在「继承画面」这一步 |
| UFS 在 UEFI 下走自己的 BlockIo | 4 KiB 逻辑块 + FAT 卷兼容问题、启动卷枚举不稳 | 内核用自己的 UFS 驱动，直接认分区 |
| PIL 被注释掉 | ADSP/GPU/相机全部不上电 | PIL 是 UEFI 的事；完整 Android 固件链在 ABL 后面，全部保留 |
| 需要维护 EDK2 分支 | 每次改显示都要重编固件 | 只改内核，产物是一个 17 MB 的 boot.img |

代价：**多占一个分区**（`recovery_a`），以及必须带一个「诱饵 DTB」（见下）。

## 分区账

`fastboot getvar all` 存档（`.fastboot-getvar.txt`）确认：

| 分区 | 大小 | 类型 | 用途 |
|---|---|---|---|
| `recovery_a` | `0x6400000` = 100 MB | raw | **Linux 内核（本路线）** |
| `recovery_b` | `0x6400000` = 100 MB | raw | 备用槽，未使用 |
| `boot_a` | 192 MiB | raw | 保留原厂 HyperOS（**不动**） |
| `vendor_boot_a` | 96 MiB | raw | **硬约束：不允许动** |

当前活动槽是 `_a`，所以 recovery 引导读 `recovery_a`。

> ⚠️ `recovery_a` **不在现有备份集里**（`backup/nuwa-backup/` 27 项里没有 recovery）。
> 第一次刷写前必须先在 Android 里 dd 出原镜像并校验，否则丢的是恢复模式的唯一副本。

## 恢复模式怎么进

| 场景 | 操作 |
|---|---|
| 关机 | 按住 **音量上 + 电源** 开机 |
| Android 里 | `adb reboot recovery` |
| fastboot 里 | `fastboot reboot recovery` |
| 回 Android | 内核 `reboot -f`，或长按电源约 20 秒强制断电后正常开机 |

## boot.img 的构造

```
boot.img (header v1)
├── kernel  = Image.gz  +  厂商 DTB（诱饵）     ← 两段直接拼接
├── ramdisk = 空                                ← initramfs 编进内核（CONFIG_INITRAMFS_SOURCE）
└── cmdline = 与内核 CONFIG_CMDLINE 相同的字符串（仅记录，不生效）
```

### 为什么要「诱饵 DTB」

ABL 会**自己**按 `msm-id`/`board-id` 选 DTB，并把 `dtbo` 分区的 overlay 叠上去，
然后把结果传给内核。实测（fuxi，2026-10-27）：**把主线 DTB 放进 kernel 字段，ABL 回
`Booting OKAY` 之后黑屏卡死**；放厂商 DTB 才正常跳转。

所以：kernel 字段里放一份**厂商 DTB 当诱饵**让 ABL 满意，内核再用
`CONFIG_NUWA_FORCE_BUILTIN_DTB` 把 `__fdt_pointer` 指回自己内建的那份。

nuwa 的诱饵来自 `other/uefi-nuwa-v7/Mu-nuwa.img` 内偏移 `1179568` 处那个 FDT
（930,579 字节，`model = "Qualcomm Technologies, Inc. 8550 nuwa"`、
`qcom,msm-id = <0x207 0x20000>`、`qcom,board-id = <0x10008 0x0>`）。
它就是 Mu 固件里的 `FdtBlob_compat`，也就是**今天 ABL 已经接受的那份**。
已提取为 `private/nuwa-bait.dtb`。

### 内建 DTB 机制（4 处改动）

| 文件 | 改动 |
|---|---|
| `arch/arm64/Kconfig` | 新增 `config NUWA_FORCE_BUILTIN_DTB` |
| `arch/arm64/include/asm/setup.h` | 声明 `extern const unsigned char nuwa_dtb[]` |
| `arch/arm64/kernel/setup.c` | `early_ioremap_init()` 之后：`__fdt_pointer = __pa_symbol((unsigned long)nuwa_dtb);` |
| `arch/arm64/kernel/nuwa_dtb.S` | `.incbin` 把 `sm8550-xiaomi-nuwa.dtb` 塞进 `.rodata` |
| `arch/arm64/kernel/Makefile` | `obj-$(CONFIG_NUWA_FORCE_BUILTIN_DTB) += nuwa_dtb.o` 加 `-DNUWA_DTB_FILE=...` 加 .dtb 依赖 |

注意 `CONFIG_CMDLINE_FORCE=y` 时 cmdline 来自 `CONFIG_CMDLINE`，
**不是**内建 DTB 的 `/chosen/bootargs`（两者内容故意写成一样，避免混淆）。

### 打包命令（WSL）

```bash
cd ~/nuwa/linux
rm -f usr/initramfs_data.cpio usr/initramfs_data.cpio.gz
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
     NUWA_DTB=sm8550-xiaomi-nuwa Image.gz -j$(nproc)

cat arch/arm64/boot/Image.gz /path/to/nuwa-bait.dtb > /tmp/kernel-dtb
: > /tmp/ramdisk
mkbootimg --header_version 1 --os_version 13.0.0 --os_patch_level 2022-11 \
  --kernel /tmp/kernel-dtb --ramdisk /tmp/ramdisk \
  --base 0x0 --kernel_offset 0x00000000 --ramdisk_offset 0x01000000 --tags_offset 0x00000100 \
  --pagesize 4096 \
  --cmdline 'console=tty0 console=ttyAMA0,115200 earlycon loglevel=7 ignore_loglevel clk_ignore_unused pd_ignore_unused iommu.passthrough=1' \
  -o abl-nuwa-drm.img
```

校验（回读镜像头）：

```bash
unpack_bootimg --boot_img abl-nuwa-drm.img --out /tmp/ub
# kernel_size 应等于 Image.gz + 930579；header v1；page size 4096
```

## 显示链（与 fuxi 的差异）

| 项 | fuxi（1080×2400） | nuwa（1440×3200） |
|---|---|---|
| 面板 | `xiaomi,fuxi` | `samsung,amb673cp01-m2` |
| lane 速率 | 1,100,000,000 | **1,360,000,000**（厂商 `panel-clockrate = 0x510ff400`） |
| DSC | 1.1 / 8 bpc / 540×40 / 2 slice | **1.2 / 10 bpc / 720×25 / 2 slice** |
| 水平 porch（前后/脉宽） | 124 / 124 / 32 | **32 / 32 / 16** |
| 垂直 porch（前后/脉宽） | 128 / 24 / 132 | **24 / 24 / 8** |
| 模式标志 | NON_CONTINUOUS 加 ALL_SLICES_IN_PKT | 同 |

lane 速率必须显式告诉 DSI host：主线 `dsi_calc_pclk()` 不会考虑 DSC 压缩，
算出的 byte clock 与面板实际要求不符。做法是给 `struct mipi_dsi_device` 加
`unsigned long hs_rate` 字段（上游 fuxi 也是这么补的，共 3 处），
面板驱动填 1.36 GHz，`dsi_host_attach()` 拷进 `msm_host->hs_rate`。

## 已知风险与坑

1. **ABL 一次失败启动后，同一个 fastboot 会话会拒绝后续镜像** → 先 `fastboot reboot bootloader`。
2. 诱饵 DTB 失效（ABL 回 `Booting OKAY` 后卡住）→ 说明不该用 Mu 的 FdtBlob，
   改从原厂 `recovery_a` 或 `dtbo` 里取真厂商 DTB。
3. 黑屏但内核活着 → 靠 `console=tty0` 加 initramfs 的 `/dev/kmsg` 输出、USB NCM telnetd
   （`192.168.0.1:23`）判断走到哪一层。
4. cmdline **不要加** `console=ttyGS0`（/dev/console 变成 USB 串口，主机不读会写满阻塞）。
5. 内核起来后 300 秒自动 `reboot -f` 回 Android，避免「黑屏且无法退出」。
