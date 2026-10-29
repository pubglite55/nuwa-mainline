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
