# nuwa 外设节点与主线驱动对照

来源：运行时设备树 `private/fdt-runtime.dts`（ABL 叠加后的最终树）

| 外设 | 原厂节点 / compatible | 主线驱动方向 |
|---|---|---|
| Wi-Fi | `/soc/qcom,cnss-qca-converged`（`qcom,cnss-qca-converged`） | ath11k_pci + qcom,cnss-qca-wcn6855 风格 DT；BDF 从原厂固件分区取 |
| 蓝牙 | `/soc/bt-qca-converged`（`qcom,bt-qca-converged`，子节点 `bt_kiwi`/`bt_qca6490`） | btqca + hci_qca（serdev），固件 nvm/rampatch |
| 音频功放 | `cs35l41@40`、`cs35l41@42`（I2C，2 个） | `cs35l41-i2c` 主线驱动可直接复用 |
| 音频编解码 | `wcd938x` 相关节点、`lpass_audio` | wcd938x 主线已支持 |
| Type-C / 角色 | `/soc/qcom,pmic_glink/qcom,ucsi`（`qcom,ucsi-glink`） | pmic-glink + ucsi + nb7vpq904m mux |
| USB2 中继 | `pm8550b_eusb2_repeater`（dtbo 注入） | phy-qcom-eusb2-repeater（主线） |
| 触控 | `fts@0`（`st,spi`，SPI0.0，GPIO 25/24） | ✅ **主线已有**：`drivers/input/touchscreen/stmfts.c` + `fts_spi/`，`CONFIG_TOUCHSCREEN_ST_FTS_V521_SPI=y` 已内建 |
| 面板 | `qcom,mdss_dsi_m2_38_0c_0a_dsc_cmd` | ❌ **主线无驱动**（`find drivers/gpu/drm/panel -name "*amb673*"` 无结果），需自写（参数见 panel-params.md） |

## 取证位置

- `private/fdt-runtime.dts` — 完整运行时树
- `private/dts-touch-fts.txt` — 触控节点
- `private/dts-panel-m2-38.txt` — 面板节点
- `.dmesg-full.log` — Android 侧驱动行为（kiwi_v2/CS35L41/FTS 日志）


## 2026-10-28 核对结果

| 外设 | 主线是否有驱动 | 依据 |
|---|---|---|
| 触控 FTS | ✅ **有** | `drivers/input/touchscreen/stmfts.c`、`fts_spi/`；`CONFIG_TOUCHSCREEN_ST_FTS_V521_SPI=y` |
| 面板 amb673cp01 | ❌ **无** | `find drivers/gpu/drm/panel -name "*amb673*"` 无结果 |
| CS35L41 功放 | ✅ 有（`snd-soc-cs35l41-i2c`） | 已内建，但 ADSP 不上电所以用不了 |
| ath11k / hci_qca | ✅ 有 | 需固件与 DT 配合 |

**注意**：CI workflow 里的 `--enable DRM_PANEL_SAMSUNG_AMB673CP01_M2` 是**无效选项**
（驱动不存在，`scripts/config` 静默忽略）。它无害，但不要以为面板驱动已就绪。

**更正说明**：本文档早期版本写"触控需移植 CAF `fts_spi` 驱动（39 文件）"，
这是错的——主线已有现成驱动。这条更正来自 2026-10-28 的源码核对。
