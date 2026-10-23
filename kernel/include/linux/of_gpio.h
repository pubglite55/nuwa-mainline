/* SPDX-License-Identifier: GPL-2.0 */
/* 兼容存根：主线已移除 linux/of_gpio.h，用 gpiod API 提供 of_get_named_gpio* */
#ifndef __LINUX_OF_GPIO_H
#define __LINUX_OF_GPIO_H

#include <linux/of.h>
#include <linux/gpio/consumer.h>
#include <linux/gpio/driver.h>

enum of_gpio_flags {
	OF_GPIO_ACTIVE_LOW = 0x1,
	OF_GPIO_SINGLE_ENDED = 0x2,
	OF_GPIO_OPEN_DRAIN = 0x4,
	OF_GPIO_TRANSITORY = 0x8,
	OF_GPIO_PULL_UP = 0x10,
	OF_GPIO_PULL_DOWN = 0x20,
};

static inline int of_get_named_gpio_flags(const struct device_node *np,
					  const char *propname, int index,
					  enum of_gpio_flags *flags)
{
	struct gpio_desc *desc;

	desc = fwnode_gpiod_get_index(of_fwnode_handle((struct device_node *)np),
				      propname, index, GPIOD_ASIS, NULL);
	if (IS_ERR(desc))
		return PTR_ERR(desc);
	if (flags)
		*flags = 0;
	return desc_to_gpio(desc);
}

static inline int of_get_named_gpio(const struct device_node *np,
				    const char *propname, int index)
{
	return of_get_named_gpio_flags(np, propname, index, NULL);
}

#endif
