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
| 触控 | `fts@0`（`st,spi`，SPI0.0，GPIO 25/24） | 需移植 CAF `fts_spi` 驱动（39 文件） |
| 面板 | `qcom,mdss_dsi_m2_38_0c_0a_dsc_cmd` | 需自写 panel driver（参数见 panel-params.md） |

## 取证位置

- `private/fdt-runtime.dts` — 完整运行时树
- `private/dts-touch-fts.txt` — 触控节点
- `private/dts-panel-m2-38.txt` — 面板节点
- `.dmesg-full.log` — Android 侧驱动行为（kiwi_v2/CS35L41/FTS 日志）
