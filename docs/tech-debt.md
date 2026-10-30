# 技术债表

> 依据 `references/discipline.md` §2：为了尽快跑通可以先用临时做法，但**每一个都要登记**，
> 之后集中还。规则：加临时做法和登记技术债在同一个提交里完成。
>
> 最后更新：2026-10-30

## 未还

### TD-02 `clk_ignore_unused pd_ignore_unused` 防资源回收

> ⚠️ **2026-10-28 重要更正**：这两个参数在发现 `CONFIG_CMDLINE_FROM_BOOTLOADER=y` 之前
> **从未真正生效过**（被 ABL 的 dtb bootargs 覆盖）。修复后（`CMDLINE_FORCE=y`）才真正生效。
> 详见 `uefi-route.md` §第三十三轮。

| 项 | 内容 |
|---|---|
| 临时做法 | cmdline 加 `clk_ignore_unused pd_ignore_unused`，阻止内核回收"没人用"的时钟和电源域 |
| 位置 | 内核 `CONFIG_CMDLINE`（`build-bootefi.yml` 与本地 `.config` 都带） |
| 为什么暂时需要 | UEFI 的 DisplayDxe 建立了显示时钟/电源域，但内核侧还没有驱动声明使用它们，内核会当作无用资源关掉 → 画面在 2–3 秒后消失（QEMU 已验证回收确实发生：`Disabling unused clocks`） |
| 正确做法 | 原生显示驱动接管后，由驱动正确声明时钟/电源域的使用关系 |
| 影响与风险 | **全局关闭资源回收**，会掩盖其他驱动的时钟/电源问题，且增加待机功耗 |
| 去掉条件 | TD-01 完成后，用正常 cmdline 启动并确认画面稳定 ≥ 5 分钟 |
| 关联文档 | `uefi-route.md` §第十五轮 |

### TD-03 `fbcon=rotate:1` 屏幕旋转

> ⚠️ **同上**：修复 `CMDLINE_FORCE` 之前从未生效。

| 项 | 内容 |
|---|---|
| 临时做法 | cmdline 加 `fbcon=rotate:1`，把 fbcon 文本控制台旋转 90° |
| 位置 | 内核 `CONFIG_CMDLINE` |
| 为什么暂时需要 | UEFI 的 framebuffer 是横向 3200×1440，面板是竖屏 1440×3200，不旋转文字会躺倒 |
| 正确做法 | 原生 panel 驱动会正确设置 `panel orientation`，由 DRM/合成器处理旋转 |
| 影响与风险 | 只影响 fbcon，GNOME 起来后由 `/etc/xdg/monitors.xml` 控制，两者可能不一致 |
| 去掉条件 | TD-01 完成后 |
| 关联文档 | `uefi-route.md` §第二十八轮 |

### TD-08 内核 cmdline 依赖 `CMDLINE_FORCE`（放弃 bootloader 参数）

| 项 | 内容 |
|---|---|
| 临时做法 | `CONFIG_CMDLINE_FORCE=y`，完全忽略 ABL 往 dtb 塞的 1100 字符 bootargs |
| 位置 | 内核 `.config`；CI `build-bootefi.yml` |
| 为什么暂时需要 | ABL 的 bootargs 会覆盖我们的 `CONFIG_CMDLINE`（arm64 没有 `CMDLINE_EXTEND`，只有 FORCE 和 FROM_BOOTLOADER） |
| 正确做法 | 长期看，阶段 2 若需要 `msm_drm.dsi_display0` 等 ABL 参数，应改用 UniXNU 的 `[[dt_patch]]` 精确修改 dtb 的 `/chosen/bootargs`，而不是全盘 FORCE |
| 影响与风险 | 丢失 ABL 的所有调优参数（`kpti=0`、`kasan=off`、`loglevel=6` 等）；当前阶段 1 不受影响 |
| 去掉条件 | 阶段 2 需要 ABL 参数时，改用 dt_patch |
| 关联文档 | `uefi-route.md` §第三十三轮 |

### TD-04 OEM 标签手工 patch 成 `MTOO4043`

| 项 | 内容 |
|---|---|
| 临时做法 | 生成 FAT 后用 Python 把偏移 3 处的 8 字节改成 `MTOO4043` |
| 位置 | 所有镜像生成脚本（`mk-*.sh` 里的 `fix_oem` 函数） |
| 为什么暂时需要 | UEFI 的 `WriteBootLog` 靠这个标签识别 payload 卷，mtools 4.0.49 写的是 `MTOO4049` |
| 正确做法 | 上游 uefi-nuwa 改为不依赖硬编码 OEM 标签（例如同时接受 `MTOO*` 前缀），或生成脚本里用 mtools 的 `-N` 参数指定 |
| 影响与风险 | 换 mtools 版本或换生成工具时会再次不匹配，导致 `WriteBootLog` 静默失效（诊断能力丢失，不影响启动） |
| 去掉条件 | uefi-nuwa 放宽标签匹配，或 mtools 支持指定 OEM |
| 关联文档 | `uefi-route.md` §第二十二轮、`troubleshooting.md` §12 |

### TD-05 4 KiB 扇区 FAT16（而非通用的 512 B）

| 项 | 内容 |
|---|---|
| 临时做法 | payload 用 `mformat -M 4096` 生成 4096 字节扇区的 FAT16 |
| 位置 | `payload-bootb*.img` |
| 为什么暂时需要 | UFS 逻辑块是 4096（`board.toml: lba_bytes = 4096`），512 B 扇区的 FAT32 在真机上"卷未挂载" |
| 正确做法 | 这不是"债"，而是**正确做法** —— 但需要真机确认后才能从"待验证"转为"已验证" |
| 影响与风险 | 若 UFSDxe 报告的块大小与预期不同，仍可能挂不上（有 512 B 退路） |
| 去掉条件 | 真机确认 4 KiB FAT16 能挂载后，本条从技术债移到"已验证" |
| 关联文档 | `uefi-route.md` §第二十五/三十轮 |

### TD-06 init 用 `reboot -f -n`（不同步直接复位）

| 项 | 内容 |
|---|---|
| 临时做法 | 超时重启用 `reboot -f -n`，跳过 sync |
| 位置 | `tools/init` 结尾 |
| 为什么暂时需要 | 经验库模式 I：`reboot -f` 若卡在 sync，设备会停在"要重启但没重启"，只能长按电源 |
| 正确做法 | 产品阶段应改为正常 sync + reboot，并确保 sync 有超时保护 |
| 影响与风险 | 不同步可能丢未落盘数据（当前只读场景无影响） |
| 去掉条件 | 确认块设备和 USB gadget 的 sync 不会卡住后 |
| 关联文档 | `uefi-route.md` §第三十二轮 |

### TD-07 无线/音频/传感器未启用

| 项 | 内容 |
|---|---|
| 临时做法 | 不启用。首版不含这些功能 |
| 位置 | 无（未实现） |
| 为什么暂时需要 | 音频/传感器/移动数据依赖 UEFI 的 PIL 驱动，而 nuwa 的 PIL 被注释掉且缺 `uefipil.cfg` |
| 正确做法 | 从原厂固件提取 `uefipil.cfg`，取消 `DXE.inc` 里 PILDxe 的注释，验证 ADSP 上电 |
| 影响与风险 | 无音频、无传感器、无移动数据、无 GPU 加速 |
| 去掉条件 | 拿到 `uefipil.cfg` 并验证 PIL 不 panic |
| 关联文档 | `uefi-route.md` §第二十六/二十九轮 |

### TD-09 触控驱动的 panel_event_notifier 是空桩

| 项 | 内容 |
|---|---|
| 临时做法 | 新增 `include/linux/soc/qcom/panel_event_notifier.h`，只提供类型与空实现，`register()` 返回一个假 cookie |
| 位置 | `drivers/input/touchscreen/fts_spi/fts.c` 依赖的厂商 API；桩文件是新增的 |
| 为什么暂时需要 | FTS 触控驱动用高通下游的 panel 事件回调做熄屏挂起/亮屏恢复，主线没有这套 API；缺头文件直接编不过 |
| 正确做法 | 由 panel 驱动在 `drm_panel_funcs` 里直接通知触控驱动，或接主线 DRM 的 panel notifier（若上游有） |
| 影响与风险 | 触控探测、固件下载、上报全部正常；**熄屏时控制器不会被挂起**，息屏功耗偏高 |
| 去掉条件 | 显示链稳定后，把 panel 的 blank/unblank 事件接到触控驱动 |
| 关联文档 | `abl-direct-boot.md`、`status.md` §2026-10-30 |

### TD-10 DSC 速率控制参数与厂商 PPS 有细微差异

| 项 | 内容 |
|---|---|
| 临时做法 | 面板驱动只填 DSC 的结构性字段（版本、尺寸、slice、bpc、bpp、block_pred），其余交给主线 `msm` 的 `dsi_populate_dsc_params()` 算 |
| 位置 | `drivers/gpu/drm/panel/panel-nuwa-m2.c`；`drivers/gpu/drm/msm/dsi/dsi_host.c`；`drivers/gpu/drm/display/drm_dsc_helper.c` |
| 为什么暂时需要 | `dsi_populate_dsc_params()` 会**无条件覆盖**面板驱动给的 RC 参数，驱动层无法指定 |
| 正确做法 | 若真机出现压缩伪影，给 `dsi_populate_dsc_params()` 加一张按 bpp/bpc 覆盖的表，用厂商 PPS 的数值 |
| 影响与风险 | 结构性字段全部一致（已逐字段解码核对），只有 `first_line_bpg_offset`（厂商 13 vs 主线 12）和个别 `rc_range max_qp` 不同 → 编码器与面板解码器的速率模型略有偏差，可能表现为局部噪点/色带 |
| 去掉条件 | 真机确认画面无误后关闭；有伪影则补表 |
| 关联文档 | `abl-direct-boot.md` §显示链、`status.md` §2026-10-30 参数核对表 |

### TD-11 kernel 字段里塞「诱饵」厂商 DTB，内核实际用内建 DTB

| 项 | 内容 |
|---|---|
| 临时做法 | boot.img 的 kernel 字段 = `Image.gz + 厂商 DTB`；内核用 `CONFIG_NUWA_FORCE_BUILTIN_DTB` 把 `__fdt_pointer` 指回内建的 `sm8550-xiaomi-nuwa.dtb` |
| 位置 | `arch/arm64/{Kconfig,include/asm/setup.h,kernel/setup.c,kernel/nuwa_dtb.S,kernel/Makefile}`；诱饵为 `private/nuwa-bait.dtb`（取自 `Mu-nuwa.img` 的 FdtBlob） |
| 为什么暂时需要 | ABL 会按 `msm-id`/`board-id` 自己选 DTB 并叠 dtbo overlay；叠到主线 DTB 上会「Booting OKAY 后卡死」（fuxi 已实测） |
| 正确做法 | 让主线 DTB 自己带上 ABL 认得的 `qcom,msm-id`/`qcom,board-id`，并验证 dtbo overlay 不破坏它 |
| 影响与风险 | 内核完全忽略 ABL 传的 DTB（含其 bootargs）；镜像里多 930 KB 无用数据；诱饵 DTB 一旦被 ABL 拒绝就黑屏 |
| 去掉条件 | 验证「主线 DTB + 正确 id + dtbo overlay」能正常跳转后撤销 |
| 关联文档 | `abl-direct-boot.md` §为什么要「诱饵 DTB」 |

### TD-12 面板四路供电被设成 always-on，熄屏/休眠无法真正断电

| 项 | 内容 |
|---|---|
| 临时做法 | `display_avdd` / `display_vci` / `display_vddio` / `display_vddd` 都带 `regulator-boot-on` + `regulator-always-on` |
| 位置 | `arch/arm64/boot/dts/qcom/sm8550-xiaomi-nuwa.dts` |
| 为什么暂时需要 | 首次点亮前不想同时改「供电所有权」和「显示链路」两个变量；先保持上电现状，确认面板能亮 |
| 正确做法 | 去掉 `always-on`（保留 `boot-on`），让 `panel-nuwa-m2` 的 `regulator_bulk_enable/disable` 真正掌握上电时序 |
| 影响与风险 | `unprepare()` 里的断电变成空操作；熄屏后仍有静态功耗；休眠功耗会明显偏高 |
| 去掉条件 | 屏幕点亮且 `unprepare` 路径验证过（能正常关屏再亮屏） |
| 关联文档 | `abl-direct-boot.md`、`rootfs-plan.md` |

---

## 已还

### TD-01 借用固件画面（simpledrm / efifb），未做原生 DPU/DSI 接管 —— **已还（2026-10-30）**

| 项 | 内容 |
|---|---|
| 临时做法 | 内核用 `FB_EFI=y`（efifb）或 `DRM_SIMPLEDRM`，继承 UEFI 的 DisplayDxe 已经点亮的 framebuffer |
| 位置 | 内核 `.config`（`bootefi-efifb` 用 `FB_EFI`，`bootefi-nodrm` 用 `DRM_SIMPLEDRM`）；`DRM_MSM` 关闭 |
| 为什么暂时需要 | 原生接管需要 panel driver（`samsung,amb673cp01-m2`）+ DSC 参数 + DPU，工作量大；借用画面能在 1–2 天内看到内核日志 |
| 正确做法 | `msm` 做成 `=m`，启动时不加载，调试通道起来后手动 `modprobe`，逐步接管 DPU/DSI/panel |
| 影响与风险 | 无亮度控制、无熄屏、无刷新率控制；GNOME 连接器显示 "Unknown"；**依赖 UEFI 不放掉 framebuffer** |
| 去掉条件 | 原生 panel + DPU 驱动能点亮并支持背光/熄屏后，切到 `DRM_MSM` |
| 关联文档 | `uefi-route.md` §显示路线、`panel-params.md` |
| **还款方式** | 换到 ABL 直启后，原生 `msm` + `panel-nuwa-m2` 驱动接管显示，不再借用固件画面；见 `abl-direct-boot.md` |
| **残留** | 真机尚未点亮，UEFI 路线的 efifb 镜像仍保留作回退 |

---

## 按影响排序的还款优先级

| 优先级 | 技术债 | 理由 |
|---|---|---|
| 1 | TD-11 诱饵 DTB | 决定能否启动，且掩盖了 DTB 传递的真实语义 |
| 2 | TD-10 DSC 速率参数 | 直接影响画质，出伪影时必须还 |
| 1.5 | TD-08 改用 dt_patch | 阶段 2 需要 ABL 显示参数时必做 |
| 3 | TD-09 触控 panel 事件 | 影响息屏功耗，不影响功能 |
| 2 | TD-02 去掉防回收参数 | 全局开关掩盖问题，长期会误导 |
| 3 | TD-05 确认 4KiB FAT | 影响启动链路稳定性 |
| 4 | TD-03 旋转 | 随 TD-01 一起解决 |
| 5 | TD-04 OEM 标签 | 只影响诊断能力 |
| 6 | TD-07 无线/音频 | 独立子任务，工作量最大 |
| 7 | TD-06 reboot 同步 | 产品化阶段才需要 |

## 排查记录：黑屏前的配置审查（2026-10-29，结论：配置层无明显问题）

真机黑屏 + USB 不枚举，在等 breadcrumb 结果期间做了一轮系统性配置审查，
把"配置错了"这个可能性排除掉。

| 检查项 | 结果 | 说明 |
|---|---|---|
| UFS 控制器 | ✅ `status = "okay"` | `&ufs_mem_hc` / `&ufs_mem_phy` 都启用，电源轨完整（vcc/vccq/vdd-hba/vdda-phy/vdda-pll） |
| arm64 errata | ✅ 20+ 项已启用 | `ARM64_ERRATUM_826319/819472/.../2067961` 都在 |
| GIC | ✅ 完整 | `ARM_GIC` + `ARM_GIC_V3` + `ARM_GIC_V3_ITS` + `ARM_GIC_V5` |
| VA/PA 位宽 | ✅ 合理 | `VA_BITS=52`/`PA_BITS=52`，但 `__cpu_setup` 用 `VA_BITS_MIN`(48) 初始化 TCR，运行时按硬件能力调整 |
| TLB range / BTI / MTE / SVE | ✅ 硬件支持 | SM8550 是 ARMv9，这些特性都有 |
| PSCI | ✅ 存在 | DT 里 `enable-method = "psci"`（3 个 cluster 都有） |
| KASLR | ✅ 已禁用 | DT `kaslr-seed = <0x00 0x00>` |
| initrd | ✅ 用内嵌的 | toml 没配 `initrd` 字段 → UniXNU 不发布 LoadFile2 initrd → 内核用内嵌 initramfs |
| cmdline 优先级 | ✅ 可控 | `CONFIG_CMDLINE_FORCE=y` 会跳过 DT 里 ABL 留下的 `console=ttyMSM0,115200n8` |

### 三个 UEFI 侧 errata 与内核的关系

UEFI 编译参数里有：

```
-D HAS_ACTLR_EL1_UNIMPLEMENTED_ERRATA=1
-D HAS_AMCNTENSET0_EL0_UNIMPLEMENTED_ERRATA=1
-D HAS_GIC_V3_WITHOUT_IRM_FLAG_SUPPORT_ERRATA=1
```

内核里没有对应的 `CONFIG_ARM64_ERRATUM_*`，但**不影响启动**：

- `ACTLR_EL1` 未实现 → 内核启动路径不碰它（只有 cache/预取控制用）
- `AMCNTENSET0_EL0` 未实现 → 只影响 perf 计数器
- `GIC_V3_WITHOUT_IRM` → 影响中断亲和路由，不影响早期启动

### 结论

配置层面找不到能解释"黑屏 + USB 不枚举"的问题。
**必须靠 breadcrumb 确定内核实际死在哪一层**，见 `uefi-build.md` 第 15 节的判读表。
