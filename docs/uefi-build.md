# 从零构建 nuwa 的 UEFI 固件（Mu + BootShim）

> 目标：把 `USE_CUSTOM_DISPLAY_DRIVER` 从 1 改成 0，用社区 `SimpleFbDxe` 替换高通 `DisplayDxe`，
> 让内核能拿到标准线性 framebuffer（efifb / earlycon 才有得用）。
>
> 本文记录 2026-10-29 在 WSL (Ubuntu 26.04, x86_64) 上第一次成功构建的全过程，
> 包括踩到的每一个坑。**上游仓库当前状态是坏的，必须打这些补丁才能编过。**

## 0. 结论先行

| 项 | 值 |
|---|---|
| 源码 | `https://github.com/pubglite55/uefi-nuwa` |
| 产物体积 | 1,998,848 B（`Mu-nuwa.img`） |
| 对比：DisplayDxe 版 | 2,127,872 B |
| 差值 | −129,024 B（大驱动换成 9,728 B 的小驱动） |
| SHA256 | `aa29361e23a37532c5e332de9993d53fc796cb6fa278adc24508431755966bcd` |

## 1. 依赖（全部可免 sudo）

```bash
# Python 构建工具
python3 -m pip install --user --break-system-packages \
  edk2-pytool-extensions edk2-pytool-library \
  antlr4-python3-runtime regex pefile coloredlogs

# nasm：EDK2 要通过 NuGet 下载 mu_nasm，而 NuGet 在 Linux 上需要 Mono。
# 不装 Mono，直接手动下载 nupkg 解压：
#   https://pkgs.dev.azure.com/projectmu/mu/_packaging/Basetools-Binary/nuget/v3/flat2/mu_nasm/20016.1.1/mu_nasm.20016.1.1.nupkg
mkdir -p Mu_Basecore/BaseTools/Bin/nasm-1
cd Mu_Basecore/BaseTools/Bin/nasm-1
python3 -c "import zipfile; zipfile.ZipFile('/path/mu_nasm.nupkg').extractall('.')"
for d in mu_nasm/*/; do mv "$d" "$(basename "$d")"; done
rmdir mu_nasm
chmod +x */nasm */ndisasm
```

**`iasl` 不需要**——它的 `scope` 是 `cibuild`，普通构建不检查。

## 2. 源码与子模块

```bash
git clone --depth 1 --recurse-submodules --shallow-submodules \
  https://github.com/pubglite55/uefi-nuwa.git ~/uefi-nuwa
```

子模块清单（`.gitmodules`）：`Binaries`（Device-Binaries，含 UFSDxe 等预编译）、
`Common/Mu`、`Common/Mu_OEM_Sample`、`Mu_Basecore`、`Silicium-ACPI`、`openssl`。

**注意**：`--shallow-submodules` 会让部分文件在 checkout 时变成 0 字节。
本例中 `Mu_Basecore/MdePkg/Include/AArch64/AsmMacroLib.h` 被清空，
导致补丁应用失败。修复：

```bash
cd Mu_Basecore && git checkout -- . && cd ..
```

（其余 56 个 0 字节文件在 git 里本来就是空的，不用管。）

## 3. 三个必须打的补丁

### 3.1 补 `UniXNUPkg`（仓库里根本没有）

`nuwa.dsc` 引用 `UniXNUPkg/Library/UniXNULib/UniXNULib.inf`，但仓库里没这个目录。
它来自 **UniXNU 仓库**：

```bash
curl -L -o UniXNU.zip https://github.com/pubglite55/UniXNU/archive/refs/heads/main.zip
unzip UniXNU.zip
cp -r UniXNU-main/package/UniXNUPkg ~/uefi-nuwa/UniXNUPkg
```

### 3.2 注释 `DarwinBootPkg`（仓库里根本没有，且 Linux 不需要）

`DXE.inc` 和 `nuwa.dsc` 都引用了 `DarwinBootPkg/Driver/DarwinBoot.inf`，
但**整个仓库搜不到这个包**（GitHub 上也没有这个仓库）。

为什么可以安全注释掉：`UniXNUPkg/Include/Protocol/UniXNULoader.h` 写明
"DarwinBoot implements it. **Other loaders can implement the same interface.**"
——UniXNU 通过 protocol 查找 loader，**不硬链接符号**；
而启动 Linux 内核走的是 `LoadImage` + `StartImage`，根本不经过 DarwinBoot
（DarwinBoot 只用于引导 macOS/XNU）。

```bash
sed -i 's|^  INF DarwinBootPkg/Driver/DarwinBoot.inf|  # INF DarwinBootPkg/Driver/DarwinBoot.inf|' \
  Platforms/Xiaomi/nuwaPkg/Include/DXE.inc
sed -i 's|^  DarwinBootPkg/Driver/DarwinBoot.inf|  # DarwinBootPkg/Driver/DarwinBoot.inf|' \
  Platforms/Xiaomi/nuwaPkg/nuwa.dsc
```

### 3.3 绕过 `--update`（要 Mono 验证 NuGet 依赖）

`build_uefi.py` 第 208 行：

```python
for action in ["--setup", "--update"]:
```

`--setup` 成功，`--update` 卡在 "Mono is required to run NuGet"。
即使手动放好 nasm，它仍会校验 hash 然后重下。改成：

```python
for action in ["--setup"]:
```

同时把 `Mu_Basecore/BaseTools/Bin/nasm_ext_dep.yaml` 改名（否则 `--build` 阶段
仍会报 "Dependency 'mu_nasm' is not met!"）：

```bash
mv Mu_Basecore/BaseTools/Bin/nasm_ext_dep.yaml Mu_Basecore/BaseTools/Bin/nasm_ext_dep.yaml.disabled
```

## 4. 切换到 SimpleFbDxe

```bash
sed -i 's/USE_CUSTOM_DISPLAY_DRIVER      = 1/USE_CUSTOM_DISPLAY_DRIVER      = 0/' \
  Platforms/Xiaomi/nuwaPkg/nuwa.dsc
```

`DXE.inc:84-88` 的条件分支：

```
!if $(USE_CUSTOM_DISPLAY_DRIVER) == 1
  INF Binaries/nuwa/QcomPkg/Drivers/DisplayDxe/DisplayDxe.inf
!else
  INF SiliciumPkg/Drivers/SimpleFbDxe/SimpleFbDxe.inf
!endif
```

设为 0 后：DisplayDxe 及其依赖 CPRDxe 都不进 FV，SimpleFbDxe 进 FV。
SimpleFbDxe 的 FILE_GUID 是 `DCFD1E6D-788D-4FFC-8E1B-CA2F75651A92`。

## 5. 构建

```bash
export PATH="$HOME/tools/usr/bin:$HOME/.local/bin:$PATH"
python3 build_uefi.py -d nuwa -r RELEASE
```

产物：

| 路径 | 说明 |
|---|---|
| `Mu-nuwa.img` | 刷入 `boot_a` 的最终镜像 |
| `Build/nuwaPkg/RELEASE_CLANGPDB/FV/SILICIUM_UEFI.fd` | 3 MB 的完整 FV |
| `Build/nuwaPkg/nuwa-kernel` | 中间产物 |

## 6. 不要被这些假错误骗到

```
make: [...SimpleFbDxe.efi] Error 1 (ignored)
```

**170 个模块里有多个报这个，但 `.efi` 都正常生成了**（`SimpleFbDxe.efi` 9,728 B）。
这是 CLANGPDB 工具链在转换 debug 符号（PDB）时的问题，被 make 忽略，不影响固件。

验证方法：`find Build -name "SimpleFbDxe.efi"` 有文件就是好的。

## 7. 验证固件内容（FV 是压缩的，GUID 搜不到）

`[FV.FvMain]` 注释写着 "This FV gets compressed"，所以：

- `strings Mu-nuwa.img | grep SimpleFbDxe` → **0**（正常）
- 按 FILE_GUID 搜二进制 → **0**（正常）

**不能**用这两种方法判断模块是否在固件里。可靠的判断依据：

1. `Build/BUILDLOG_nuwaPkg.txt` 里有 `Building ... SimpleFbDxe.inf [AARCH64]`
2. 产物体积变化（2,127,872 → 1,998,848 B）
3. `find Build -name "*.efi"` 有 157 个

## 8. 待验证的风险

`SimpleFbDxe` 和 `DisplayDxe` 的职责完全不同：

| | DisplayDxe（原来） | SimpleFbDxe（现在） |
|---|---|---|
| 面板初始化 | 完整（DSI/DSC/PMIC/背光） | **不做**，只复用已有 framebuffer |
| GOP 类型 | 可能是 BLT-only | 标准线性 framebuffer |
| UEFI 界面 | 正常 | **待验证** |
| 内核 efifb | 拿不到 | 应该能拿到 |

**风险**：如果 ABL 在交出控制权时已经关闭了显示，SimpleFbDxe 复用的那块 framebuffer
可能无效，导致**连 UEFI 界面都不显示**。所以刷之前必须保留 DisplayDxe 版
（`other/uefi-nuwa/Mu-nuwa.img`）作为回退。


## 9. 三个固件版本（2026-10-29 构建）

| 目录 | 大小 | SHA256 前 16 | 显示驱动 | 用途 |
|---|---|---|---|---|
| `uefi-nuwa/` | 2,127,872 | `5c60f2f021bc75c5` | DisplayDxe | 原版，界面确认可用（回退用） |
| `uefi-nuwa-debug/` | 2,248,704 | `b9b2b0690bf7b86a` | DisplayDxe | DEBUG 版，界面可用 |
| `uefi-nuwa-simplefb/` | 1,998,848 | `aa29361e23a37532` | 仅 SimpleFbDxe | 纯线性 GOP，但面板可能不亮 |
| `uefi-nuwa-dual/` | 2,113,536 | `331608b615e86d6e` | **DisplayDxe + SimpleFbDxe** | **首选** |

### 为什么做"双驱动"版

`DisplayDxe` 和 `SimpleFbDxe` 的职责完全不同：

| | DisplayDxe | SimpleFbDxe |
|---|---|---|
| 面板初始化 | 完整（DSI/DSC/PMIC/背光） | **不做** |
| framebuffer 来源 | 自己初始化 | 复用 `"Display Reserved"` carveout（`0xB8000000`，44 MB） |
| GOP 类型 | 可能 BLT-only | 标准线性 |

只留 `SimpleFbDxe` 的风险：如果 ABL 交出控制权时已关屏，**连 UEFI 界面都没有**。

双驱动版让两者共存，靠内核 EFI stub 的选择逻辑天然分工：

```c
/* drivers/firmware/efi/libstub/gop.c:450 */
if (info->pixel_format == PIXEL_BLT_ONLY || ...)
    continue;                    // DisplayDxe 的 GOP 被跳过
...
if (handle has ConOut) return;   // 否则选第一个可用的
```

- **UEFI 界面**：GraphicsConsoleDxe 用 DisplayDxe 的 BLT 画字 → 界面正常
- **内核 efifb**：跳过 BLT-only，选中 SimpleFbDxe 的线性 GOP → framebuffer 可用

### 必须同时保留 CPRDxe

`CPRDxe` 是 DisplayDxe 的硬依赖（电源轨控制），原来被包在
`!if $(USE_CUSTOM_DISPLAY_DRIVER) == 1` 里。把开关设为 0 后它会一起被排除，
导致 DisplayDxe 启动失败。做双驱动版时**必须把 CPRDxe 也改成无条件**：

```
# CPRDxe is a hard dependency of DisplayDxe (power rail control).
INF Binaries/nuwa/QcomPkg/Drivers/CPRDxe/CPRDxe.inf
INF Binaries/nuwa/QcomPkg/Drivers/DisplayDxe/DisplayDxe.inf
INF SiliciumPkg/Drivers/SimpleFbDxe/SimpleFbDxe.inf
```

## 10. GopInfo：查真实 PixelFormat 的诊断应用

位置：`Platforms/Xiaomi/nuwaPkg/Application/GopInfo/`（9,216 B，UEFI_APPLICATION）

它会打印每个 GOP 的 `MaxMode`、`FrameBufferBase`、`FrameBufferSize`、
`Resolution`、`PixelFormat`、`PixelsPerScanLine`，然后停 60 秒。

关键判断：

| PixelFormat | 名称 | 对 efifb 的意义 |
|---|---|---|
| 0 | `PixelRedGreenBlueReserved8BitPerColor` | ✅ 可用 |
| 1 | `PixelBlueGreenRedReserved8BitPerColor` | ✅ 可用 |
| 2 | `PixelBitMask` | 可能可用 |
| 3 | `PixelBltOnly` | ❌ **拿不到 framebuffer** |

打包进诊断 payload（`payload-bootb-diag.img`），UniXNU 菜单第一项启动它。
**这样能在刷固件之前就确定黑屏到底是 GOP 类型问题还是内核侧问题。**

## 11. QEMU 验证 GopInfo 的尝试与结论（失败）

想用 QEMU + AAVMF 先验证 GopInfo 不崩，结果 **AAVMF 的 BDS 不工作**：

```
UEFI firmware (version 2025.11-3ubuntu7.3 ...)
(qemu 卡住，不再有任何输出)
```

试过：`-bios`、`pflash CODE+VARS`、`virtio-gpu-pci`（QEMU 10.2 无此设备名）、
`ramfb`、`bochs-display`、带 MBR 分区表的 FAT32 镜像、`startup.nsh` 自动执行——
**全部只打印固件版本就停**。

结论：**AAVMF 不适合做 EFI 应用的快速验证环境**，不要在这上面继续花时间。
GopInfo 的正确性靠静态验证（PE 头 `0xAA64` / subsystem 10 / 代码仅用
`LocateHandleBuffer` + `HandleProtocol` + `Print`）保证。

## 12. 恢复 QEMU（免 sudo）

WSL 里的 qemu 曾被清掉，但 `/var/cache/apt/archives/` 里还有 deb：

```bash
mkdir -p ~/tools
dpkg-deb -x /var/cache/apt/archives/qemu-system-arm_*.deb  ~/tools
dpkg-deb -x /var/cache/apt/archives/qemu-system-data_*.deb ~/tools
dpkg-deb -x /var/cache/apt/archives/qemu-efi-aarch64_*.deb ~/tools
export PATH="$HOME/tools/usr/bin:$PATH"
```

这样 QEMU 和 AAVMF 都回来了（`~/tools/usr/bin/qemu-system-aarch64`、
`~/tools/usr/share/AAVMF/`）。


## 13. 为什么不能靠 pstore 抓黑屏时的 panic（2026-10-29 分析，结论：不可行）

思路本来是：内核 panic 时写 ramoops，重启进 Android 后
`cat /sys/fs/pstore/console-ramoops-0` 就能看到日志。

内核配置其实是齐的：

```
CONFIG_PSTORE=y
CONFIG_PSTORE_RAM=y
CONFIG_PSTORE_CONSOLE=y
CONFIG_PSTORE_COMPRESS=y
CONFIG_PSTORE_DEFAULT_KMSG_BYTES=10240
```

但卡在两个地方。

### 13.1 我们 DTS 里没有 ramoops 节点

`sm8550-xiaomi-nuwa.dts` 里搜不到 `ramoops`，所以 pstore 后端不会注册。

### 13.2 Android 的 ramoops 地址不能用

Android 的 `vendor-dtb.dts` 里确实有：

```dts
ramoops_region {
    compatible = "ramoops";
    alloc-ranges = <0x00 0x00 0xffffffff 0xffffffff>;
    mem-type = <0x02>;
};
```

这是**动态分配**（`alloc-ranges`），实际地址由 Android 内核决定，我们猜不到。

而 runtime FDT 里那个固定地址的节点：

```dts
ramoops@0xa7000000 {
    compatible = "ramoops";
    reg = <0x00 0xa7000000 0x00 0x400000>;   // 4 MB
    console-size = <0x200000>;
    pmsg-size = <0x200000>;
};
```

**地址直接和 BootShim 撞车**。看 UEFI 的 memory map：

```
{"FD Reserved",       0xA7000000, 0x00100000, ...}
{"UEFI FD",           0xA7100000, 0x00300000, ...}   ← BootShim 的 FD_BASE/FD_SIZE
{"UEFI FD Reserved",  0xA7400000, 0x00200000, ...}
```

`BootShim.S` 编译参数就是 `-DFD_BASE=0xa7100000 -DFD_SIZE=0x300000`，
即 `0xA7100000`–`0xA7400000`。而 4 MB 的 ramoops 占 `0xA7000000`–`0xA7400000`，
**整段覆盖 BootShim 的 DTB 缓冲区**。

### 13.3 换到安全地址也没用

`UEFI FD Reserved`（`0xA7400000`，2 MB）之后是空的，可以放 ramoops。
但关键问题不在地址安全，而在**谁来读**：

- 我们写进去的 panic 日志，只有**我们自己**（下次启动的 Linux）能读
- Android 的 ramoops 驱动只认它自己 DT 里那个动态分配的地址
- 两块内存不同 → **Android 读不到我们的 pstore**

而当前的问题恰恰是「内核起不来」，所以「下次启动的 Linux」根本不存在。

**结论**：pstore 只能解决「内核起来了但用户态有问题」的场景，
对「内核早期 panic + 无串口 + 屏幕黑」完全无解。

**能用的手段只剩屏幕本身**：
1. `GopInfo.efi` —— 查 GOP 真实类型（不依赖内核）
2. `earlycon=efifb` —— 内核最早阶段直接画字到 framebuffer
3. `SimpleFbDxe` / 双驱动固件 —— 保证 framebuffer 有效

### 13.4 唯一还能补的通道

真机要拿串口，必须拆机接 UART（见 `uart-plan.md`）。在那之前，
**任何「内核早期崩溃」都只能靠屏幕和 USB 枚举状态来推断**。


## 14. UniXNU 自带的 breadcrumb 诊断机制（重要发现，2026-10-29）

读 `UniXNUPkg/Library/UniXNULib/Main.c` 时发现，UniXNU **本来就有**一套
为 nuwa 定制的内核进度记录机制，而且会**直接显示在菜单上**。

### 14.1 它读什么

```c
volatile UINT64 *N = (volatile UINT64 *)(UINTN)0x8d3003000ULL;
if (N[0] == 0x4e4f5445ULL) {          // magic 'NOTE'
    UINT32 StartCkpt = (UINT32)N[2];  // start.s checkpoint
    UINT32 Stages    = (UINT32)N[1];  // arm_init stage mask
    ...
}
```

字段含义：

| 偏移 | 内容 |
|---|---|
| `N[0]` | magic `0x4e4f5445`（"NOTE"） |
| `N[1]` | `arm_init` 阶段位图（`sweet_early_mark`） |
| `N[2]` | `start.s` checkpoint |
| `N[3]` | 内核被进入时的 `SCTLR_EL1` |
| `N[4]` | 物理入口点 |
| `N[5]` | load address |

`N[2]` 的取值是关键：

| 值 | 含义 |
|---|---|
| 0 | 从未进入 `start_first_cpu`（EFI stub 之后就没了） |
| 1 | 进入内核入口 |
| 3 | 读完 boot args |
| 5 | 建好 bootstrap 页表 |
| 6 | MMU 已启用 |

### 14.2 它显示在哪

```c
Print (L"UNIXNU: note %lx %lx %lx %lx  (magic %lx)\n", N[0], N[1], N[2], N[3], 0x4e4f5445ULL);
...
UnicodeSPrint (Ui.Notice, ..., L"last kernel boot reached stage mask 0x%x", KernelStages);
// 或者
UnicodeSPrint (Ui.Notice, ..., L"no kernel stage bars found (kernel died before arm_init)");
UnicodeSPrint (Ui.Info, ..., L"n1 %x ck %x ld %x sc %x ent %x", N[1], N[2], N[5], N[3], N[4]);
```

**也就是说：UEFI 菜单上本来就有这几行**，不需要额外操作就能看到上次内核死在哪。
下次真机测试时**第一件事就是看这几行**。

### 14.3 但我们的内核不会写它

`sweet_early.c` / `NUWA_BREADCRUMB` 是上游的 nuwa 定制补丁，我们的
`~/nuwa/linux` 里**没有**（`find -name "sweet_early*"` 为空）。
所以现在菜单只会显示 `no kernel stage bars found`。

要让它有意义，得把 breadcrumb 写进我们的内核：
- `arch/arm64/kernel/head.S` 的 `start_first_cpu` 开头写 `N[0]=magic, N[2]=1`
- 读完 boot args 写 `N[2]=3`
- 建完页表写 `N[2]=5`
- 开 MMU 后写 `N[2]=6`
- `N[3]/N[4]` 记录进入时的 `SCTLR_EL1` 和入口点

### 14.4 地址疑点（移植前必须确认）

`0x8d3003000` ≈ **35.3 GiB**，而 SM8550 的 DRAM 最多 16 GB，
物理上不可能存在这个地址。

可是 UniXNU **每次启动都读它**（`Print (L"UNIXNU: note ...")`），
而真机上菜单能正常显示——说明这个读操作没有触发异常。

两种可能：
1. 固件的 MMU 把未映射区域指向了某个默认页（读得到垃圾但不崩）
2. 这个地址在 nuwa 上有特殊映射

**在确认可写之前，绝对不能在内核里往这里写**——如果是无效地址，
写操作会立即触发数据中止，比现在的黑屏更糟。

**验证办法（下次真机时）**：看菜单上 `UNIXNU: note` 那行四个值。
- 全是 `0` 且 magic 显示 `4e4f5445` → 地址可读但没人写过
- 出现非零值 → 有人写过，地址有效


## 15. 移植 UniXNU breadcrumb 到内核（已完成，待真机验证）

### 15.1 先解决了地址疑点

`0x8d3003000` ≈ 35.3 GiB，看着超出 DRAM。查 runtime FDT 的 `memory` 节点才发现
**nuwa 的地址空间跨了 4 GB 边界**（`ddr_size = 0x0c` = 12 GB）：

```
0x80000000  + 0x00e00000     (2.0 ~ 2.0 GB)
0x811d0000  + 0x56e30000     (2.0 ~ 3.4 GB)
0xd8140000  + 0x00020000
0xe7cb0000  + 0x18350000     (3.6 ~ 4.0 GB)
0x880000000 + 0x39d00000     (34.0 ~ 34.9 GB)
0x8c0000000 + 0xc0000000     (35.2 ~ 38.2 GB)
0x980000000 + 0x180000000    (38.0 ~ 44.0 GB)
0x8b9f0000  + 0x01e00000     (34.9 ~ 35.5 GB)   ← 31.5 MB, 0x8d3003000 在这里
```

**地址有效**，可以安全写。

### 15.2 head.S 的三个检查点

`arch/arm64/kernel/head.S` 的 `primary_entry` 里插入。选寄存器前先确认
`primary_entry` 只用到 x0/x1/x2/x19/x20/x29，**x22–x28 全空闲**；
且 `record_mmu_state()` 返回时 MMU 已被禁用，可以直接物理寻址。

| 位置 | checkpoint |
|---|---|
| `record_mmu_state` 之后 | **1** — 进入内核入口 |
| `preserve_boot_args` 之后 | **3** — boot args 已保存 |
| `__pi_create_init_idmap` 之后 | **5** — bootstrap 页表已建 |

每处都是这段（只碰 x26/x27/x28，不破坏 x0 返回值和 x19 的 MMU 状态）：

```asm
	movz	x28, #0x0008, lsl #32
	movk	x28, #0xd300, lsl #16
	movk	x28, #0x3000
	movz	x27, #0x4e4f, lsl #16
	movk	x27, #0x5445
	str	x27, [x28]			// N[0] = 'NOTE'
	mov	x26, #<ckpt>
	str	x26, [x28, #16]		// N[2] = checkpoint
```

### 15.3 checkpoint 6 放在 C 代码里

MMU 开启后必须用虚拟地址。放在 `init/main.c` 的 `setup_arch()` 之后
（那时 `memstart_addr` 已设置，`__va()` 才有效）：

```c
	setup_arch(&command_line);

	{
		volatile u64 *nuwa_note = (volatile u64 *)__va(0x8d3003000ULL);
		nuwa_note[2] = 6;
	}
```

编译后是运行时计算（`sub x0, x0, PHYS_OFFSET` + `orr ..., #0xfff0000000000000`），
**所以搜 `0x8d3003000` 常量是找不到的**，别以为没编进去。

### 15.4 判读表（下次真机测试用）

刷 `payload-bootb-bc.img` 到 `boot_b`，重启进 UEFI，看菜单的
`UNIXNU: note <magic> <stages> <ckpt> <sctlr>`：

| `note` 显示 | 内核走到哪 | 排查方向 |
|---|---|---|
| 无此行 / magic ≠ `4e4f5445` | **没进内核入口** | EFI stub、UniXNU 的 LoadImage/StartImage、PE 装载 |
| `4e4f5445 0 1 ...` | 入口后、`preserve_boot_args` 或建页表时挂 | 早期栈、`__pi_create_init_idmap` |
| `4e4f5445 0 3 ...` | 读到 boot args，建页表时挂 | idmap 页表构造 |
| `4e4f5445 0 5 ...` | 页表建好，`__cpu_setup`/开 MMU 时挂 | CPU 特性、TCR/MAIR 配置 |
| `4e4f5445 0 6 ...` | MMU 已开、`setup_arch` 完成 | `start_kernel` 之后（驱动/init） |

### 15.5 一个已知限制

内核 DTS 里加的 `nuwa-note-region` 保留声明**对真机无效**——真机启动时 DT 来自
UEFI 打包的 `sm8550-xiaomi-nuwa.dtb`（`nuwa.fdf` 里 `SECTION RAW`），不是内核自带的 dtb。
要真正保留这块内存，得改 UEFI 那个 dtb 并重编固件。

不过**不影响早期诊断**：breadcrumb 写在 `head.S` 最早期，那时还没分配任何内存。
只有"内核完全启动成功"之后才可能被覆盖——而那种情况本来也不需要诊断。
