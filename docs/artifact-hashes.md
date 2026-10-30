# 产物哈希清单

> 生成时间：2026-10-28 06:42（含 fbcon=rotate:1）

用途：刷机前核对，确认刷入的正是验证过的那一份。

| 文件 | MiB | SHA256 |
|---|---|---|
| esp-efifb.img | 64 | 73459c7336bc9cbec8c8aad0d4d698b5cab5fb375213bcda9be6814f49e81f52 |
| esp-nuwa-nodrm.img | 64 | 5675123ea3cbfac9f050c513569cb9efe0e06514f8cee47666124b42968178e8 |
| esp-nuwa.img | 64 | 3a2ba90bb309f1c83321102b0b5f3d4a3c8d2a5b726474e2d8401ca14e1b4382 |
| esp-refind.img | 64 | 947e2818b0a2c6c36cc693215d6decd1c43ceb5bc1e1883a8482318f709d14e5 |
| esp-shell.img | 64 | 3d478d78ef1d2aaa4facb7d590cac5494d27538504a631c016fd433dddff703a |
| payload-bootb-efifb.img | 192 | df93824e6fd5cf994658a281e32a9508d72569411452d8ab16608e3c23a82da3 |
| payload-bootb-min.img | 192 | dea60a65473f19376246250509d719dec79423052504f6904ca1f7273124b15c |
| payload-bootb.img | 192 | d378fccd5bbd9572a1eb403bdb7ed5942a73f5630312a460de7293b64476fad8 |
| vendor_boot-initrd-esp.img | 67.71 | 32b19e8293d7fede9667ff44881e26873af303aef64813e25a9e5e4a8f7340f0 |
| uefi-nuwa\Mu-nuwa.img | 2.03 | 5c60f2f021bc75c51e059d032d103312b55c613142846374000f192ea32a563a |
| uefi-nuwa-debug\Mu-nuwa.img | 2.14 | b9b2b0690bf7b86afe1caabdb9cb78b208e696550219ca69721ffd2af6d3ed41 |
| bootefi\BOOTAA64.EFI | 47.05 | d32848630e6aa5b7e38b0d5cb815da20abf71d1b1612a5ef359a81a1e579f3b7 |
| bootefi-nodrm\BOOTAA64-NODRM.EFI | 45.62 | 7c65cdbd7291a1297d2f6da9ed57601071e5fecffbe478b360f5c0c43a62520d |
| bootefi-efifb\BOOTAA64-EFIFB.EFI | 42.2 | 43352ff045147aa67aebe887470c3e8ccd6ae5463bf28ef5c4b0d3635651ba97 |
| bootefi-efifb\BOOTAA64-MIN.EFI | 42.2 | 9feea3f58b891a9cc6ea0348035dd7954ad630d135fae5ddbeb905fb9743832f |

## ABL 直启路线（2026-10-30）

| 文件 | 大小(MiB) | sha256 |
|---|---|---|
| other\abl-nuwa-drm-v9.img | 17.03 | ef0e57013381758c9b73adbcccf5638b33639d72b49a31b8ba686bc6bd0c8e75 |
| other\abl-nuwa-drm-v8.img | 17.03 | 81dc0cf51c60b57a3d42ed05f95f0b6b714c1fd968148e8755b3fc21e5824e10 |
| other\abl-nuwa-drm-v7.img | 17.03 | 4b3845d53e4e12307f402ae39e27da3377d7f6f0dc80b8a8f93fdf6c9afb091f |
| backup\nuwa-backup\recovery.official.img（原厂 recovery，来自固件包） | 100.00 | 4bc16c42d75afc4959bd659e2d2973daf4709f36df8e08aa3a4459f1f9a7340e |
| backup\nuwa-backup\boot_a.img（原厂 boot，已回刷验证） | 192.00 | fe3a4be28cf1899e4dbcf596115bbf5f1f7dfc34c3a7e662dcd0eb0940c96fcb |
| WSL: rootfs\ubuntu-26.04-arm64-nuwa-rootfs.tar.gz | 140.38 | b4d101132e9e5aff764d146a42eb18cc550773a04e621d39b086e46164b795d7 |
| WSL: rootfs\nuwa-rootfs-8g.img（6 GiB 稀疏） | 6144.00 | ecc7db29f1422aece1655636171609f73783f308f5c28f20484767cf5a8fa957 |

> 注：`recovery_a` 的**设备 dd 备份仍未做**（擦数据前设备在 fastboot，无法 dd）。
> 回退依赖原厂包里的 `recovery.official.img`；下次进 Android 后应补一份设备 dd 备份并比对哈希。
