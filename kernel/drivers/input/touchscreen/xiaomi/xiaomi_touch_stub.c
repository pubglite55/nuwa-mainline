// SPDX-License-Identifier: GPL-2.0
/* 主线存根：CAF 的 xiaomi_touch 框架实现，提供 fts_spi 链接所需的符号。 */
#include <linux/module.h>
#include <linux/kernel.h>
#include "xiaomi_touch.h"
#include <linux/export.h>

int register_xiaomi_touch_client(enum touch_id touch_id,
				 struct xiaomi_touch_interface *interface)
{
	return 0;
}
EXPORT_SYMBOL_GPL(register_xiaomi_touch_client);

int unregister_xiaomi_touch_client(enum touch_id touch_id)
{
	return 0;
}
EXPORT_SYMBOL_GPL(unregister_xiaomi_touch_client);

int notify_oneshot_sensor(enum oneshot_sensor_type sensor_type, int value)
{
	return 0;
}
EXPORT_SYMBOL_GPL(notify_oneshot_sensor);

MODULE_DESCRIPTION("Xiaomi touch framework stub");
MODULE_LICENSE("GPL");
