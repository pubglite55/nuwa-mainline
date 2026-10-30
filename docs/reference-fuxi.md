# 参考项目要点：xiaomi13-fuxi（SM8550 同代）

> 来源：<https://github.com/ilovecnxx/xiaomi13-fuxi-linux-ubuntu26.10-kernel7.3>，2026-10-30 通读。
> fuxi = 小米 13（SM8550），与 nuwa 同代，路线与本项目一致（ABL 直启 + boot.img v1 + 内建 DTB）。

## 1. 打包参数（与我们逐字相同，可放心沿用）

```
mkbootimg --header_version 1 --os_version 13.0.0 --os_patch_level 2022-11 \
  --kernel <Image.gz + 厂商 DTB 诱饵> --ramdisk <空> \
  --base 0x0 --kernel_offset 0x00000000 --ramdisk_offset 0x01000000 \
  --tags_offset 0x00000100 --pagesize 4096 --cmdline "${CMDLINE:0:500}"
```

- **诱饵 DTB 必须有**：ABL 会把 `dtbo` 的 overlay 叠到 DTB 上，叠主线 DTB 会卡死；
  他们用「立即 PSCI 复位的最小桩内核」验证过：附主线 DTB 卡住、附厂商 DTB 19 秒回 Android。
- cmdline 走内建 DTB 的 `/chosen/bootargs`（他们不用 `CMDLINE_FORCE`，我们用，两者都能工作）。

## 2. 方法论：先最小内核，再按变体加子系统

| 变体 | 内容 |
|---|---|
| `-min` | 只到「进用户空间 + USB 串口」 |
| `-disp` | 加 DRM_MSM + 面板驱动 |
| `-audio` | 加 ALSA/ASoC/AudioReach/CS35L41 |
| `-usbc` | 加 UCSI + FSA4480 + dwc3 双角色 + xHCI |

他们的 `fuxi-build-abl.sh` 有三条硬规矩，值得照搬：

1. **`flock` 锁同一棵内核树** —— 两个构建同时改 `.config` 会互相破坏（我们 2026-10-30 就踩了：
   v12 编译失败、`SM_DISPCC_8550` 被改回 `=m`）。
2. **`-e` 的选项必须验证真的变成 `=y`**，`olddefconfig` 会静默丢掉依赖不满足的项。
3. 构建结束后恢复主配置，并把「本次真正使用的 .config / .dtb」随镜像一起存证。

## 3. 他们踩过的坑（直接适用于 nuwa）

| 坑 | 结论 |
|---|---|
| `pstore/ramoops` 跨复位留证 | **不可用**：本机复位会清 DDR，实测失败 → 不要指望 pstore 抓早期日志 |
| `console=ttyGS0` | **绝对不能加**：`/dev/console` 变成 USB 串口，主机不读就写满阻塞 |
| ABL 一次失败启动后 | 同一 fastboot 会话拒绝后续镜像 → 先 `fastboot reboot bootloader` |
| `&mdss` 与 DRM_MSM | 他们有一版是「DTS 里启用 mdss 但不编 DRM_MSM、并去掉 iommus」，让 mmss_noc/gem_noc/MMCX 的 sync_state 挂起、保留 bootloader 投票 |
| 屏幕 console | 帧缓冲物理地址在 linear map 内时 `ioremap()` 会 WARN 返回 NULL，必须 `phys_to_virt()` + `dcache_clean_poc()` |
| initramfs | 缺 `/proc /sys /dev /tmp` 目录会让 `/init` 挂载失败 → `Attempted to kill init` panic |
| Gunyah 看门狗 | 32–40 秒可能强制复位（`qcom,gh-watchdog`）；PING 是否有效未严格证实 |

## 4. 与 nuwa 的差异（不能照抄的部分）

- 无线：fuxi = WCN7850/ath12k，nuwa = WCN6856/ath11k；
- 面板：fuxi 1080×2400，nuwa 1440×3200 DSC；
- 触控：fuxi 用自写 `st-ftm5.c`，nuwa 用厂商 `fts_spi`；
- 槽位：fuxi 日常在 b 槽（`recovery_b`），nuwa 在 a 槽（`recovery_a`）。
