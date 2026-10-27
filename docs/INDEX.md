# nuwa 项目索引

> 最后更新：2026-10-28

## 一句话状态

主线 Linux 移植走 **UEFI 路线**（ABL 路线因 dtb 强校验 + 无 console 已放弃）。
所有离线产物已就绪并逐项验证，**等待真机验证启动链路**。

## 文档地图

| 文档 | 内容 | 什么时候看 |
|---|---|---|
| [status.md](status.md) | 当前状态快照 | 每次接手先看 |
| [next-steps.md](next-steps.md) | **设备回来后按什么顺序做什么**（4 个分支） | 设备在线时 |
| [uefi-route.md](uefi-route.md) | UEFI 路线完整原理、14 轮验证记录 | 想理解为什么这么做 |
| [troubleshooting.md](troubleshooting.md) | 故障排查决策树（6 类现象 → 判据 → 行动） | 出问题时 |
| [install-plan.md](install-plan.md) | 三阶段路线（验证 → 部署 Ubuntu → 桌面/双系统） | 规划后续 |
| [panel-params.md](panel-params.md) | 面板参数 | 做原生显示接管时 |
| [peripherals.md](peripherals.md) | 外设对照 | 做外设时 |

## 产物清单（other/）

### 启动镜像

| 文件 | 大小 | 内容 | 刷到 |
|---|---|---|---|
| `uefi-nuwa/Mu-nuwa.img` | 2.13 MB | UEFI 固件 RELEASE | `boot_a` |
| `uefi-nuwa-debug/Mu-nuwa.img` | 2.25 MB | UEFI DEBUG（屏幕打印卷扫描） | `boot_a` |
| **`payload-bootb.img`** | 192 MiB | **4 KiB FAT16**，卷标 NUWAESP，nodrm 内核 | `boot_b` |
| `esp-nuwa.img` | 64 MB | 512 B FAT32，正常版内核 49.3 MB | `vendor_boot_a` |
| `esp-nuwa-nodrm.img` | 64 MB | 512 B FAT32，nodrm 内核 47.8 MB | `vendor_boot_a` |
| `esp-shell.img` | 64 MB | UEFI Shell + nodrm 内核 | `vendor_boot_a` |
| `esp-refind.img` | 64 MB | rEFInd 0.14.0.2 (aa64) + nodrm 内核 | `vendor_boot_a` |

### 内核源码/产物

| 路径 | 说明 |
|---|---|
| `bootefi/BOOTAA64.EFI` | 正常版内核（DRM_MSM=y，49.3 MB） |
| `bootefi-nodrm/BOOTAA64-NODRM.EFI` | nodrm 版（simpledrm/efifb，47.8 MB） |
| `community-kernel/` | 社区 7.0 内核原始产物 |

### 备份（backup/nuwa-backup/）

`boot_a/b`、`init_boot_a/b`、`vendor_boot_a`、`vbmeta_a/b`、`dtbo_a/b`、`persist`、
`modemst1/2`、`fsg`、`gpt-sd[a-d]-head/backup` 等 27 项。

## 工具（public/nuwa/tools/）

| 脚本 | 用途 |
|---|---|
| `flash-uefi.ps1` | **统一刷写入口**：`-BootB` / `-Mode shell` / `-Nodrm` / `-Debug` |
| `device-recover.ps1` | 一键恢复原厂 Android（三件套 + slot + 可选 GPT） |
| `run-test.ps1` | 上机编排：检查→刷机→采集 USB 事件→判定→输出 JSON |
| `pc-ncm-connect.ps1` | PC 端配 NCM 网卡并连 telnet |
| `twrp-install-esp.sh` | TWRP 内写 ESP 到分区 + 可选改 GPT 类型为 ESP |
| `twrp-set-esp-type.sh` | TWRP 内只改 GPT 类型 |
| `mk-esp.sh` | 生成 ESP 镜像 |
| `init` | initramfs 的 /init（输出到 tty0、USB NCM、telnetd、120 秒重启） |

## 关键约束（血泪教训）

| 约束 | 后果 |
|---|---|
| UFS 逻辑块是 **4 KiB** | 512 B 扇区的 FAT32 挂不上；必须 `mformat -M 4096` |
| `boot_b` 只能当**数据分区**，不能当可启动槽 | ABL 的 B 槽固件链可能是旧的 |
| `vbmeta_a` 必须 **flags=0x3** | 否则 ABL 拒绝启动 `boot_a` |
| 启动/显示/输入依赖必须 **`=y` 内建** | 模块缺失会**静默**失效（无报错） |
| 借用固件画面要防**资源回收** | `clk_ignore_unused pd_ignore_unused` 仅作诊断 |
| `fastboot flash:raw` 会包 boot header | Fat 无法解析，必须用 `dd` 或普通 `flash` |

## 当前唯一阻塞

**设备不在线**。所有能离线验证的都已验证；剩余三项必须真机：

1. UEFI 是否挂载 4 KiB FAT16 的 `boot_b`
2. `console=tty0` 是否真有输出
3. `usb0` 能否建立

## 下一步（设备在线后）

```powershell
.\tools\flash-uefi.ps1 -BootB
```

然后按 [next-steps.md](next-steps.md) 的 4 个分支处理。
