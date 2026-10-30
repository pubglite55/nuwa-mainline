# Linux 根文件系统放哪：分区现状与可选方案

> 最后更新：2026-10-30。数据来自 `backup/nuwa-backup/gpt-sda-head.bin`（UFS 逻辑块 **4096 字节**）实测解析。
> 结论先行：**主盘没有空闲空间**，`userdata` 占了 12 GB 之后到盘尾的全部 224 GB。
> 所以「装 Ubuntu」这件事有一个必须先由用户拍板的决策，见 §3。

## 1. 实测 GPT（lun0，32 个条目）

| LBA 起 | LBA 止 | 大小 | 名称 |
|---|---|---|---|
| 6 | 127 | 0.5 MiB | switch / ssd / dbg / bk01..bk04（小分区合并看） |
| 128 | 1023 | 3.5 MiB | keystore / frp / countrycode |
| 1024 | 2047 | 4 MiB | misc |
| 2048 | 16383 | 56 MiB | bk05 / logfs / ffu / devinfo / oops |
| 16384 | 49151 | 128 MiB | metadata 64M + persist 64M |
| 49152 | 96767 | 186 MiB | mtdblk / crash_history / minidump |
| 96768 | 173567 | **300 MiB** | **rawdump** |
| 173568 | 181311 | 30 MiB | bk010 / vbmeta_system_a,b / mem |
| 181312 | 194623 | 52 MiB | opconfig / mbnconfig |
| 194624 | 227391 | **128 MiB** | **rescue** |
| 227392 | 751679 | **2048 MiB** | **cust** |
| 751680 | 3110975 | **9216 MiB** | **super**（Android 动态分区） |
| 3110976 | 61850618 | **229451.7 MiB ≈ 224 GiB** | **userdata** |

盘总大小：61,850,623 个 4096 字节块 ≈ **236 GiB**。`first_usable=6`、`last_usable=61850618`，
**首尾之间没有任何未分配空洞**。

其他 lun（只在 sdb/sdc/sdd 里）：`xbl_a/b`、`xbl_config_a/b`、`multiimgqti`、`apdp`、`ALIGN_TO_128K_1`、
`cdt`、`ddr`、`bk31/bk32` —— 都是引导链小分区，不能用。

## 2. 为什么不能「随便找个地方塞」

| 候选 | 装得下吗 | 问题 |
|---|---|---|
| `recovery_b`（100 MB） | ❌ | 已被列为 Linux 内核备用槽 |
| `rescue`（128 MB） | ❌ | 太小 |
| `rawdump` + `minidump` + `crash_history`（454 MB） | ❌ | 太小（只能放 initramfs 级系统） |
| `cust`（2 GB） | 🔸 勉强 | 极小系统可以，**GNOME 装不下**；且会丢 OEM 定制内容 |
| `super`（9 GB） | ❌ | Android 动态分区，动它等于破坏 Android 系统 |
| `userdata` 里的镜像文件 | ❌ | **userdata 是 FBE 加密的**，Linux 侧没有密钥，读不到 |
| 外接 USB-C 盘 | ✅ | 需要 USB 主机模式（当前 DTS 强制 `dr_mode = "peripheral"`） |
| 切一块 `userdata` 出来 | ✅ | 要改 GPT + 缩文件系统，**属不可逆操作，必须先问用户** |

## 3. 三个可选方案（需要用户决策）

### 方案 A：缩 `userdata`，新建 `linux` 分区（fuxi 就是这么干的）

- 优点：性能最好，和 Android 完全隔离，最接近「日常可用」。
- 代价：需要动 GPT 和 `userdata`，**用户数据要先行备份或接受丢失**；f2fs 缩容支持有限，
  实操上通常是「备份 → 重建 userdata + linux → 还原」。
- 需要用户明确同意（项目规则里「动 GPT / userdata 必须先问」）。

### 方案 B：外接 USB-C 盘当 rootfs

- 优点：**零风险**，不动任何分区；盘可以插拔，Android 完全不受影响。
- 代价：要先让 USB 走主机模式。当前 `&usb_1` 为了 USB 网络被固定成 `dr_mode = "peripheral"`，
  需要改回 `otg` 并把 `UCSI_PMIC_GLINK`（现在 `=m`）改成 `=y` 才能自动切换角色。
  另外功耗与稳定性要实测。

### 方案 C：先用小系统验证，再决定

- 把 `cust`（2 GB）或 `rawdump`（300 MB）临时当 rootfs，跑一个纯命令行 + Phosh 之外的最小桌面，
  用来验证「内核 → 用户空间 → 桌面」整条链，再回来做 A 或 B 的决策。
- 优点：不需要用户让出 userdata；缺点：不是最终形态。

## 4. 建议顺序

1. **先点亮屏幕**（`other/abl-nuwa-drm-v7.img` 刷 `recovery_a`），确认显示 + 触控 + USB 网络 —— 不涉及任何分区改动。
2. 用 initramfs 里的 telnet（`192.168.0.1:23`）验证内核态功能（Wi-Fi 固件、音频、充电）。
3. 再向用户提方案 A / B 的选择题，得到明确同意后才动分区。

## 5. 切到方案 B 时要做的最小改动（备查）

```
&usb_1 {
	/* 从 peripheral 改成 otg，让角色切换驱动接管 */
	dr_mode = "otg";
	phys = <&usb_1_hsphy>, <&usb_1_qmpphy>;
	phy-names = "usb2-phy", "usb3-phy";
};
```

配置侧：`CONFIG_UCSI_PMIC_GLINK=y`、`CONFIG_TYPEC_UCSI=y`（已是 y）、`CONFIG_USB_XHCI_HCD=y`（已是 y）。
注意：一旦切成 `otg`，**USB NCM 调试通道就不再是默认的**，需要靠角色切换才能拿到 gadget ——
所以这条改动要等显示/串口备用通道确认可用之后再做。

## 6. 已准备好的 rootfs 产物（2026-10-30）

用 Ubuntu 官方预构建的 **cloud minimal root**（自带 systemd/sshd，不需要 chroot 或 qemu-user）为底座，
已针对 nuwa 配好并打包。全部在 WSL 的 `/home/l1872/nuwa/rootfs/`：

| 文件 | 大小 | sha256 |
|---|---|---|
| `ubuntu-26.04-arm64-nuwa-rootfs.tar.gz` | 147,198,806 | `b4d101132e9e5aff764d146a42eb18cc550773a04e621d39b086e46164b795d7` |
| `nuwa-rootfs-8g.img`（6 GB 版，已验证） | 6,442,450,944（稀疏，实占 536 MB） | `ecc7db29f1422aece1655636171609f73783f308f5c28f20484767cf5a8fa957` |
| `ubuntu-26.04-minimal-cloudimg-arm64-root.tar.xz` | 98,718,844 | 官方原件 |

### 里面已经配好什么

| 项 | 值 |
|---|---|
| 发行版 | Ubuntu 26.04.1 LTS (resolute) arm64 |
| 主机名 | `nuwa` |
| `/etc/fstab` | `LABEL=nuwa-root / ext4 defaults,noatime 0 1` + tmpfs /tmp |
| root 密码 | `nuwa`（开发机，SSH 也允许密码登录） |
| tty1 | 自动登录 root（屏幕就是 tty1，方便现场调试） |
| SSH | `PermitRootLogin yes`、`PasswordAuthentication yes` |
| USB 网络 | netplan：`usb0` 固定 `192.168.0.1/24`（switch_root 后仍可 ssh） |
| cloud-init | **已禁用**（没有 metadata 服务，留着只会等/乱改配置） |
| machine-id | 已清空，首次启动生成 |

验证过：`e2fsck -fn` 干净；`debugfs` 读回 `/etc/hostname` = `nuwa`；`/sbin/init` → `../lib/systemd/systemd`。

### 想换大小就重新生成

```bash
# 在 WSL 里以 root 跑（需要 loop mount）
wsl.exe -d Ubuntu-26.04 -u root bash public/nuwa/tools/mkrootfs-image.sh \
  /home/l1872/nuwa/rootfs/ubuntu-26.04-arm64-nuwa-rootfs.tar.gz \
  /home/l1872/nuwa/rootfs/nuwa-rootfs-16g.img 16G
```

### 写到哪（等方案定了再做）

```bash
# 方案 B：整盘 U 盘（设备名自己确认，别抄）
sudo dd if=nuwa-rootfs-8g.img of=/dev/sdX bs=4M status=progress conv=fsync

# 方案 A：写进新建的 linux 分区
sudo dd if=nuwa-rootfs-8g.img of=/dev/block/by-name/linux bs=4M status=progress conv=fsync
```

### 还缺什么

- **桌面环境**：现在只有命令行。GNOME 建议**上机后**再装（`apt install ubuntu-desktop`），
  在 QEMU 里装要几小时且容易踩坑；设备原生速度最快。
- **Wi-Fi/蓝牙/音频固件**：从原厂 `/vendor/firmware`、`/odm/firmware` 取，阶段 6。
- 内核模块不需要：当前配置把这些驱动都内建了（见 `handoff.md` 的 P2 清单）。
