# UART 调试通道方案（备选）

## 为什么需要

主线内核在设备上的启动过程看不到任何输出（USB 未起、无显示驱动、pstore 依赖 ramoops 落盘）。UART 是最可靠的调试通道。

## 需要的工具

- USB-TTL（CP2102/CH340，3.3V）
- 细烙铁 + 助焊膏（测试点在主板上，需要拆后盖）
- 一条细线（飞线）

## 步骤（未执行，需要用户参与）

1. 拆后盖，找到主板 UART 测试点（小米 13 Pro 常见位于主板边缘，标注 TX/RX/GND）
2. 焊 3 根线到 TX/RX/GND（3.3V，不接 VCC）
3. USB-TTL 接主机，用 PuTTY/minicom 打开串口 115200 8N1
4. 内核 cmdline 加 `console=ttyMSM0,115200n8 earlycon=msm_geni_serial,0xaf0000`
   —— 地址以 `private/fdt-runtime.dts` 里 `uart7`（`serial0`）为准
5. 上电，观察内核日志

## 备选：pstore

如果 UART 不方便，可尝试：
1. 保持当前卡米标状态
2. 长按电源进 TWRP
3. 执行 `tools/read-pstore.sh`（读 /sys/fs/pstore）
4. 若 ramoops 有效，能看到内核启动日志的尾部

## 判定

- UART 有输出：直接看到卡在哪一级（内存/GIC/时钟/UFS/init）
- pstore 有内容：同 UART 的日志价值
