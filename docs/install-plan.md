# nuwa Linux 安装规划（社区流程对照）

> 来源：`Project-Silicium/Guides → General/OS/Arch-Linux`（社区官方流程，虽然标"过时"，但分区/引导思路仍适用）

## 社区的分区方案

在 TWRP 里用 parted 操作 `/dev/block/sda`：

```
(parted) print                        # 找到 userdata 的 Number / Start / End
(parted) rm <userdata>                # 注意：会清空 Android 数据
(parted) mkpart userdata ext4 <Start> <End/2>          # 缩小一半
(parted) mkpart esp fat32 <End/2> <End/2+512MB>        # ESP 512MB
(parted) mkpart arch ext4 <End/2+512MB> <End>          # root 剩余
(parted) set <esp-number> esp on      # ← 这一步就是设置 GPT 类型为 ESP
(parted) quit
```

格式化：

```sh
mkfs.fat -F32 -s1 /dev/block/by-name/esp
mke2fs -t ext4 /dev/block/by-name/arch
mke2fs -t ext4 /dev/block/by-name/userdata
```

## 社区推荐的 ESP 尺寸

| 分区 | 类型 | 建议大小 |
|---|---|---|
| ESP | fat32 | **512 MB – 1 GB** |
| root | ext4 | 剩余空间 |

> 我们当前用的是 `vendor_boot_a`（96 MB）放 64 MB 的 ESP —— **只够放内核，装不下系统**。
> 真正部署 Ubuntu 时必须按上表重新分区。

## 引导器方案对比

| 方案 | 做法 | 我们的情况 |
|---|---|---|
| rEFInd（社区推荐） | `refind_aa64.efi` → `EFI/boot/bootaa64.efi`，配 `refind_linux.conf` | 备用 |
| UniXNU（nuwa UEFI 内置） | `EFI/UniXNU/unixnu.toml` 或 fallback 扫 `EFI/BOOT/BOOTAA64.EFI` | **主用** |
| 自包含内核 | 内核 + 内嵌 initramfs，直接作 EFI 应用 | **当前验证用** |

rEFInd 配置示例（社区）：

```
"Boot with UUID"   "rw root=UUID=<root-part-uuid> acpi=force"
```

`acpi=force` 是因为当时主线 DT 启动不工作，强制走 ACPI；nuwa 有主线 DT，**不需要**。

## 我们的分阶段路线

### 阶段 1（当前）：验证启动链路

- ESP 放 `vendor_boot_a`（96 MB），只装 49 MB 自包含内核
- 目标：UEFI 能读到卷 → 内核启动 → 屏幕出 init 日志 → `usb0` 起来

### 阶段 2：部署 Ubuntu rootfs

1. TWRP + parted 按社区方案分区（userdata 缩小 → esp 512MB + root 剩余）
2. Mass Storage 暴露给 PC
3. PC 上解包 Ubuntu base rootfs 到 root 分区
4. ESP 放内核 + initramfs（或直接用 root 分区的 `/boot`）
5. 配 UniXNU 的 `unixnu.toml`：`root=UUID=... rootwait`

### 阶段 3：桌面与双系统

- GNOME 桌面
- HyperOS 保留在缩小后的 userdata + 原 boot 分区（ABL 仍可启动 Android）
- 通过 UEFI 菜单或 fastboot 切换

## 风险提示（社区原文）

> Deleting userdata will wipe all your data in Android!

缩小 userdata 前必须备份。我们的 `backup/nuwa-backup/` 已含关键分区，但 **userdata 内的用户数据不在其中**。


## 阶段 2 的根文件系统已就位

`other/ubuntu-base-26.04-arm64.tar.gz`

| 项 | 值 |
|---|---|
| 大小 | 35,094,845 B（33.5 MiB） |
| SHA256 | `b2b46a37324ea1954e93f293fe6d7c2241daf2fc298c4022e6e4caceeed74cab` |
| 文件数 | 6,564 |
| 架构验证 | `usr/lib/aarch64-linux-gnu/`、`usr/bin/bash` 均在 |
| 来源 | `https://cdimage.ubuntu.com/ubuntu-base/releases/26.04/release/` |

### 为什么用 base 而不是预装 GNOME 的镜像

| 方案 | 优点 | 缺点 |
|---|---|---|
| **ubuntu-base（已下载）** | 小（33 MiB）、干净、可控 | 需要 chroot 装 GNOME（几百个包） |
| 官方桌面镜像 | GNOME 已装 | 2–4 GiB，含大量无关驱动 |

base + chroot 安装的好处：可以精确控制装哪些包，避免把 x86 桌面镜像里的无用组件带进来。

### 安装步骤（阶段 2，需要设备在线）

1. 在 Linux 上把 rootfs 解压到 ext4 分区
2. chroot 进去装 `ubuntu-desktop-minimal`、`network-manager`、`gnome-shell`
3. 按 `references/ubuntu.md` 的分层结构做包拆分
4. 内核 cmdline 改成 `root=PARTLABEL=nuwa-root rootwait`

**注意**：这一步需要 UFS 驱动工作（`SCSI_UFS_QCOM=y` 已内建）。
如果阶段 1 发现 UFSDxe 有问题，阶段 2 也要相应调整。


### ubuntu-base 的实际内容（本地验证）

在 WSL 里解压实测：

| 项 | 结果 |
|---|---|
| 解压 | ✅ 退出码 0 |
| `usr/bin/bash` | ✅ |
| `usr/bin/apt` | ✅ |
| `etc/os-release` | ✅ **Ubuntu 26.04 LTS (Resolute Raccoon)** |
| `usr/lib/aarch64-linux-gnu/libc.so.6` | ✅ |
| **`lib/systemd/systemd`** | ❌ **缺失** |
| 解压后体积 | 117 MB |

### 这意味着什么

`ubuntu-base` 是**最小系统**，只有 bash、apt、coreutils 这些。**没有 systemd、没有 udev、没有桌面**。

所以阶段 2 不能"解压完就直接启动"——那样启动后没有 init 会 panic。有两条路：

**路线 A：先用 init=/bin/bash 启动，再补装**
```
cmdline: root=PARTLABEL=nuwa-root rootwait init=/bin/bash
```
进去后 `apt install systemd-sysv`，然后改回正常 init。

**路线 B：安装时就 chroot 补装（推荐）**
```sh
mount --bind /dev  $MNTPOINT/dev
mount -t proc proc $MNTPOINT/proc
mount -t sysfs sysfs $MNTPOINT/sys
chroot $MNTPOINT /bin/bash
# chroot 内：
apt update
apt install -y systemd-sysv udev kmod
apt install -y ubuntu-desktop-minimal network-manager
```

**路线 B 更好**：一次装完，第一次启动就是可用的 GNOME 系统。

### 另一种选择：用预装 GNOME 的镜像

如果不想在 chroot 里装几百个包，可以改用 Ubuntu 官方的 arm64 桌面镜像（2–4 GiB），
解压后直接有 GNOME。代价是镜像大、含大量无关驱动。

**当前决策**：先用 base + chroot（可控、小），如果 chroot 装包遇到问题再换桌面镜像。
