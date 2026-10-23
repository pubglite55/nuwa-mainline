# nuwa 面板参数（从运行时设备树提取）

- 面板节点：`qcom,mdss_dsi_m2_38_0c_0a_dsc_cmd`（cmdline: `msm_drm.dsi_display0`）
- 分辨率：1440 x 3200（hactive 0x5a0, vactive 0xc80）
- 刷新率模式：120Hz（默认）/ 60 / 40 / 30 / 24；LTPO ddic idle/auto/qsync
- DSC：启用（cmd 面板 + DSC）

## 时序（60Hz 模式样例）

| 参数 | 值 |
|---|---|
| h-front-porch | 32 (0x20) |
| h-back-porch | 32 (0x20) |
| h-pulse-width | 16 (0x10) |
| v-front-porch | 24 (0x18) |
| v-back-porch | 24 (0x18) |
| v-pulse-width | 8 (0x08) |
| 时钟 | DSI clk 1.36 GHz（dmesg 实测） |

## 复位时序

`qcom,mdss-dsi-reset-sequence = <0 1 1 5>`

## 电源

- 三路：vci / vddd / vddio（`dsi_panel_pwr_supply_M2`）
- 亮度：`bl_ctrl_dcs`，max-level 0xfff

## 证据

完整节点存档：`private/dts-panel-m2-38.txt`（251 行，含 DSC、HBM/亮度命令序列）
