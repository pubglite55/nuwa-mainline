// SPDX-License-Identifier: GPL-2.0-only
/*
 * Panel driver for Xiaomi 13 Pro (nuwa) — panel m2_38_0c_0a_dsc_cmd
 * 1440x3200, 120Hz LTPO, DSC, cmd mode.
 *
 * 参数来源：原厂运行时设备树节点 qcom,mdss_dsi_m2_38_0c_0a_dsc_cmd
 * 证据存档：private/dts-panel-m2-38.txt
 *
 * 状态：骨架。初始化序列（dsi 命令）待从原厂 dts 逐条迁移。
 */

#include <linux/backlight.h>
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/regulator/consumer.h>
#include <linux/units.h>

#include <drm/display/drm_dsc.h>
#include <drm/drm_mipi_dsi.h>
#include <drm/drm_modes.h>
#include <drm/drm_panel.h>

struct nuwa_panel {
	struct drm_panel panel;
	struct mipi_dsi_device *dsi;
	struct gpio_desc *reset_gpio;
	struct regulator_bulk_data supplies[3];
	bool prepared;
};

/* 原厂 dts：hfp 32 / hbp 32 / hpw 16 / vfp 24 / vbp 24 / vpw 8 */
static const struct drm_display_mode nuwa_60hz_mode = {
	.clock = 0, /* TODO: 由 DSI 驱动按 DSC 参数计算 */
	.hdisplay = 1440,
	.hsync_start = 1440 + 32,
	.hsync_end = 1440 + 32 + 16,
	.htotal = 1440 + 32 + 16 + 32,
	.vdisplay = 3200,
	.vsync_start = 3200 + 24,
	.vsync_end = 3200 + 24 + 8,
	.vtotal = 3200 + 24 + 8 + 24,
	.type = DRM_MODE_TYPE_DRIVER | DRM_MODE_TYPE_PREFERRED,
};

static int nuwa_panel_prepare(struct drm_panel *panel)
{
	struct nuwa_panel *ctx = container_of(panel, struct nuwa_panel, panel);
	int ret;

	if (ctx->prepared)
		return 0;

	ret = regulator_bulk_enable(ARRAY_SIZE(ctx->supplies), ctx->supplies);
	if (ret)
		return ret;

	/* 原厂：reset-sequence = <0 1 1 5> */
	gpiod_set_value_cansleep(ctx->reset_gpio, 1);
	usleep_range(1000, 2000);
	gpiod_set_value_cansleep(ctx->reset_gpio, 0);
	usleep_range(1000, 2000);
	gpiod_set_value_cansleep(ctx->reset_gpio, 1);
	usleep_range(5000, 6000);

	ctx->prepared = true;
	return 0;
}

static int nuwa_panel_unprepare(struct drm_panel *panel)
{
	struct nuwa_panel *ctx = container_of(panel, struct nuwa_panel, panel);

	if (!ctx->prepared)
		return 0;

	gpiod_set_value_cansleep(ctx->reset_gpio, 0);
	regulator_bulk_disable(ARRAY_SIZE(ctx->supplies), ctx->supplies);
	ctx->prepared = false;
	return 0;
}

static int nuwa_panel_get_modes(struct drm_panel *panel,
				struct drm_connector *connector)
{
	struct drm_display_mode *mode;

	mode = drm_mode_duplicate(connector->dev, &nuwa_60hz_mode);
	if (!mode)
		return -ENOMEM;
	drm_mode_set_name(mode);
	drm_mode_probed_add(connector, mode);
	return 1;
}

static int nuwa_panel_get_timings(struct drm_panel *panel,
				  unsigned int num_timings,
				  struct display_timing *timings)
{
	return 0;
}

static const struct drm_panel_funcs nuwa_panel_funcs = {
	.prepare = nuwa_panel_prepare,
	.unprepare = nuwa_panel_unprepare,
	.get_modes = nuwa_panel_get_modes,
	.get_timings = nuwa_panel_get_timings,
};

static int nuwa_panel_probe(struct mipi_dsi_device *dsi)
{
	struct device *dev = &dsi->dev;
	struct nuwa_panel *ctx;
	int ret;

	ctx = devm_kzalloc(dev, sizeof(*ctx), GFP_KERNEL);
	if (!ctx)
		return -ENOMEM;

	ctx->supplies[0].supply = "vci";
	ctx->supplies[1].supply = "vdd";
	ctx->supplies[2].supply = "vddio";

	ret = devm_regulator_bulk_get(dev, ARRAY_SIZE(ctx->supplies), ctx->supplies);
	if (ret)
		return ret;

	ctx->reset_gpio = devm_gpiod_get_optional(dev, "reset", GPIOD_OUT_LOW);
	if (IS_ERR(ctx->reset_gpio))
		return PTR_ERR(ctx->reset_gpio);

	ctx->dsi = dsi;
	ctx->dsi->mode_flags = MIPI_DSI_MODE_VIDEO | MIPI_DSI_MODE_NO_EOT_PACKET;
	ctx->dsi->format = MIPI_DSI_FMT_RGB888;

	drm_panel_init(&ctx->panel, dev, &nuwa_panel_funcs, DRM_MODE_CONNECTOR_DSI);
	drm_panel_add(&ctx->panel);
	dev_set_drvdata(dev, ctx);
	return 0;
}

static void nuwa_panel_remove(struct mipi_dsi_device *dsi)
{
	struct nuwa_panel *ctx = dev_get_drvdata(&dsi->dev);

	drm_panel_remove(&ctx->panel);
}

static const struct of_device_id nuwa_panel_of_match[] = {
	{ .compatible = "xiaomi,nuwa-m2-panel" },
	{ }
};
MODULE_DEVICE_TABLE(of, nuwa_panel_of_match);

static struct mipi_dsi_driver nuwa_panel_driver = {
	.driver = {
		.name = "panel-xiaomi-nuwa-m2",
		.of_match_table = nuwa_panel_of_match,
	},
	.probe = nuwa_panel_probe,
	.remove = nuwa_panel_remove,
};
module_mipi_dsi_driver(nuwa_panel_driver);

MODULE_DESCRIPTION("Xiaomi 13 Pro (nuwa) m2_38_0c_0a panel");
MODULE_LICENSE("GPL");
