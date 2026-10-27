# 技术债表

> 依据 `references/discipline.md` §2：为了尽快跑通可以先用临时做法，但**每一个都要登记**，
> 之后集中还。规则：加临时做法和登记技术债在同一个提交里完成。
>
> 最后更新：2026-10-28

## 未还

### TD-01 借用固件画面（simpledrm / efifb），未做原生 DPU/DSI 接管

| 项 | 内容 |
|---|---|
| 临时做法 | 内核用 `FB_EFI=y`（efifb）或 `DRM_SIMPLEDRM`，继承 UEFI 的 DisplayDxe 已经点亮的 framebuffer |
| 位置 | 内核 `.config`（`bootefi-efifb` 用 `FB_EFI`，`bootefi-nodrm` 用 `DRM_SIMPLEDRM`）；`DRM_MSM` 关闭 |
| 为什么暂时需要 | 原生接管需要 panel driver（`samsung,amb673cp01-m2`）+ DSC 参数 + DPU，工作量大；借用画面能在 1–2 天内看到内核日志 |
| 正确做法 | `msm` 做成 `=m`，启动时不加载，调试通道起来后手动 `modprobe`，逐步接管 DPU/DSI/panel |
| 影响与风险 | 无亮度控制、无熄屏、无刷新率控制；GNOME 连接器显示 "Unknown"；**依赖 UEFI 不放掉 framebuffer** |
| 去掉条件 | 原生 panel + DPU 驱动能点亮并支持背光/熄屏后，切到 `DRM_MSM` |
| 关联文档 | `uefi-route.md` §显示路线、`panel-params.md` |

### TD-02 `clk_ignore_unused pd_ignore_unused` 防资源回收

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

| 项 | 内容 |
|---|---|
| 临时做法 | cmdline 加 `fbcon=rotate:1`，把 fbcon 文本控制台旋转 90° |
| 位置 | 内核 `CONFIG_CMDLINE` |
| 为什么暂时需要 | UEFI 的 framebuffer 是横向 3200×1440，面板是竖屏 1440×3200，不旋转文字会躺倒 |
| 正确做法 | 原生 panel 驱动会正确设置 `panel orientation`，由 DRM/合成器处理旋转 |
| 影响与风险 | 只影响 fbcon，GNOME 起来后由 `/etc/xdg/monitors.xml` 控制，两者可能不一致 |
| 去掉条件 | TD-01 完成后 |
| 关联文档 | `uefi-route.md` §第二十八轮 |

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

---

## 已还

（暂无）

---

## 按影响排序的还款优先级

| 优先级 | 技术债 | 理由 |
|---|---|---|
| 1 | TD-01 原生显示接管 | 解锁亮度/熄屏/刷新率，且是 TD-02/TD-03 的前提 |
| 2 | TD-02 去掉防回收参数 | 全局开关掩盖问题，长期会误导 |
| 3 | TD-05 确认 4KiB FAT | 影响启动链路稳定性 |
| 4 | TD-03 旋转 | 随 TD-01 一起解决 |
| 5 | TD-04 OEM 标签 | 只影响诊断能力 |
| 6 | TD-07 无线/音频 | 独立子任务，工作量最大 |
| 7 | TD-06 reboot 同步 | 产品化阶段才需要 |
