# nuwa UEFI 路线 — 故障排查决策树

> 每一步都给出「现象 → 判据 → 行动」，避免盲猜。

## 0. 刷写前检查

```powershell
& "C:\Android\platform-tools\fastboot.exe" devices    # 必须看到 3705933 fastboot
```

设备不在 fastboot → 长按电源 15 秒，再按住音量下 + 电源。

## 1. 刷完 UEFI 后，屏幕无任何反应（黑屏无背光）

| 判据 | 含义 | 行动 |
|---|---|---|
| 主机也看不到 `VID_18D1` | UEFI 没跑起来 | 确认 `boot_a` 刷的是 `Mu-nuwa.img`（2.13 MB，`ANDROID!` 头）；重刷 |
| 主机能看到 `VID_18D1` | UEFI 在跑，只是屏幕没亮 | 用 `esp-shell.img` 测链路；查 `DisplayDxe` 是否匹配面板 |

## 2. UEFI 界面出现，但没有我们的启动项

屏幕只有 `Return to firmware` / `Restart` / `Power off`（**内置菜单**）→ 说明**没读到 unixnu.toml，也没扫到 BOOTAA64.EFI**。

按顺序尝试：

### 2a. 先验证 FAT 挂载是否成立

刷 `esp-shell.img`（内含 UEFI Shell 作为 `\EFI\BOOT\BOOTAA64.EFI`）：

- **出现 Shell 提示符** → FAT 挂载没问题，问题在菜单/配置 → 进 2b
- **仍无反应** → FAT 没被挂载 → 进 2c

进 Shell 后手动确认：
```
Shell> map -r
Shell> fs0:
Shell> ls
```
能列出 `\EFI\BOOT\BOOTAA64.EFI` 就说明卷可读。

### 2b. FAT 正常但菜单不显示

- 检查 ESP 里 `\EFI\UniXNU\unixnu.toml` 是否存在、路径是否 `\\EFI\\BOOT\\BOOTAA64.EFI`
- 刷 **UEFI DEBUG 版**，屏幕上会打印 `config: loaded ...` 或扫描到的卷标签（`NUNIXNU`）
- 若 DEBUG 版显示扫到了 `NUNIXNU` 却仍无项 → 配置语法问题（用 `unixnu.com/zh/reference/boot-configuration` 对照）

### 2c. FAT 没被挂载

- TWRP 里跑 `tools/twrp-set-esp-type.sh`：把 `vendor_boot_a` 的 GPT 类型改成 **EFI System Partition**（脚本会自动打印恢复命令）
- 或换分区：把 ESP 刷到 `boot_b`（201 MB，当前槽位未使用）
- 极端情况：刷 UEFI DEBUG 版，看 UFSDxe 是否报错

## 3. 有启动项，选中后黑屏

- 换 `esp-nuwa-nodrm.img`（禁用 `DRM_MSM`，用 `simpledrm` 直接继承 UEFI framebuffer）
- nodrm 版有输出 → 说明是 msm 驱动抢占了 framebuffer，后续再修 msm/panel
- nodrm 版也黑屏 → 内核在极早期挂了（内存/GIC/时钟），需要 UART

## 4. 内核日志出现，但停在某处

屏幕会显示（自包含内核 + `console=tty0`）：

```
==============================================
  nuwa initramfs  |  mainline kernel + UEFI
==============================================
```

| 停在 | 含义 | 行动 |
|---|---|---|
| 内核启动日志之前 | EFI stub 失败（dtb 缺失/不兼容） | 检查 UEFI 的 FdtBlob 是否正常；换 nodrm 版 |
| 到 `-- 加载驱动模块 --` 卡住 | 某模块 insmod 挂死 | 从 init 里逐个注释模块定位 |
| 到 `-- USB gadget --` 显示 `udc: <none>` | DWC3 未绑定 | 检查 dtb 里 `usb_1`/`dwc3` 节点；确认 PHY 驱动 |
| 显示 `telnetd 已启动` | ✅ 成功 | 主机跑 `tools/pc-ncm-connect.ps1` |

## 5. 内核起来了，主机没看到 NCM 网卡

```powershell
Get-NetAdapter | Where-Object { $_.InterfaceDescription -match "NCM|RNDIS" }
```

- 完全没有 → 设备侧 `usb0` 没建（看屏幕 `udc:` 与 `usb0:` 行）
- 有但状态 Down → 手动 `Enable-NetAdapter`
- Windows 缺驱动 → 设备管理器里看是否有未知设备；CDC-NCM 在 Win10+ 自带

## 6. 恢复 Android（任何阶段）

```powershell
.\tools\device-recover.ps1
```

刷回 `boot_a` / `init_boot_a` / `vendor_boot_a`（均已在 `backup/nuwa-backup/`，含 vendor_boot 100 MB 原厂镜像）+ `set_active a`。

若改过 GPT 类型：`.\tools\device-recover.ps1 -RestoreGpt`（用 `gpt-sda-head.bin`）。
