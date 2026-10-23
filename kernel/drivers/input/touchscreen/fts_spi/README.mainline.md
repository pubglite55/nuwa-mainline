# FTS 触控驱动（mainline 移植）

来源：LineageOS CAF 内核 `drivers/input/touchscreen/fts_spi/`（FocalTech V521 SPI）。

## 移植改动

| 位置 | 改动 |
|---|---|
| `Kconfig` | `depends on I2C` → `depends on SPI`（原厂笔误） |
| `fts_lib/*.c` | `#include <stdarg.h>` → `<linux/stdarg.h>` |
| `fts_lib/ftsIO.c` | `spi_device->master` → `->controller` |
| `fts_lib/ftsTest.c` | `strlcpy` → `strscpy` |
| `fts.c` | 补 `<linux/vmalloc.h>`、`<linux/pinctrl/consumer.h>` |
| `fts.c` | `class_create(THIS_MODULE, x)` → `class_create(x)` |
| `fts.c` | `spi_driver.remove` 用 `fts_remove_void` 包装（mainline void 签名） |
| `include/linux/xiaomi_touch.h` | 新增存根：`enum touch_mode` + `TOUCH_MODE_*` 别名 |
| `include/linux/of_gpio.h` | 新增存根：把 `of_get_named_gpio*` 映射到 gpiod API |

## 编译验证

```sh
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- drivers/input/touchscreen/fts_spi/
# 0 errors，生成 11 个 .o
```

## 集成到内核树

1. 复制 `fts_spi/` 到内核 `drivers/input/touchscreen/`
2. `drivers/input/touchscreen/Makefile` 加 `obj-$(CONFIG_TOUCHSCREEN_ST_FTS_V521_SPI) += fts_spi/`
3. `drivers/input/touchscreen/Kconfig` 加 `source "drivers/input/touchscreen/fts_spi/Kconfig"`
4. 存根头复制到 `include/linux/`
5. 设备树节点：`fts@0`（SPI0.0，compatible "st,spi"，GPIO 25 IRQ / 24 reset，x/y 14400/32000）

## 待办

- [ ] 核对 `enum touch_mode` 真实数值（存根为占位）
- [ ] of_gpio 存根未透传 ACTIVE_LOW 标志，按需修正极性
- [ ] 真机验证：中断、上报、手势、FOD
