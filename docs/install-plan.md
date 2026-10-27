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
