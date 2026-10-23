#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

LINUX=${LINUX_DIR:-linux}
OUT=${OUT_DIR:-out}
case "$LINUX" in /*) ;; *) LINUX="$(pwd)/$LINUX" ;; esac
case "$OUT" in /*) ;; *) OUT="$(pwd)/$OUT" ;; esac
JOBS=${JOBS:-$(nproc)}

if [ ! -d "$LINUX" ]; then
  git clone --depth 1 ${LINUX_URL:-https://github.com/torvalds/linux.git} "$LINUX"
fi

# ---- 集成 nuwa 定制（设备树 / FTS 触控 / 存根头） ----
DTS_SRC=dts/nuwa.dts
if [ -f "$DTS_SRC" ]; then
  cp "$DTS_SRC" "$LINUX/arch/arm64/boot/dts/qcom/nuwa.dts"
  MK="$LINUX/arch/arm64/boot/dts/qcom/Makefile"
  grep -q 'nuwa.dtb' "$MK" || echo 'dtb-$(CONFIG_ARCH_QCOM) += nuwa.dtb' >> "$MK"
  grep -q 'DTC_FLAGS_nuwa' "$MK" || echo 'DTC_FLAGS_nuwa := -@' >> "$MK"
fi

if [ -d drivers/input/touchscreen/fts_spi ]; then
  rm -rf "$LINUX/drivers/input/touchscreen/fts_spi"
  cp -r drivers/input/touchscreen/fts_spi "$LINUX/drivers/input/touchscreen/"
  TMK="$LINUX/drivers/input/touchscreen/Makefile"
  TKC="$LINUX/drivers/input/touchscreen/Kconfig"
  grep -q 'fts_spi/' "$TMK" || echo 'obj-$(CONFIG_TOUCHSCREEN_ST_FTS_V521_SPI) += fts_spi/' >> "$TMK"
  grep -q 'fts_spi/Kconfig' "$TKC" || echo 'source "drivers/input/touchscreen/fts_spi/Kconfig"' >> "$TKC"
  [ -f include/linux/xiaomi_touch.h ] && cp include/linux/xiaomi_touch.h "$LINUX/include/linux/"
  [ -d drivers/input/touchscreen/xiaomi ] && mkdir -p "$LINUX/drivers/input/touchscreen/xiaomi" && cp drivers/input/touchscreen/xiaomi/* "$LINUX/drivers/input/touchscreen/xiaomi/"
  grep -q 'xiaomi_touch_stub' "$TMK" || echo 'obj-y += xiaomi/xiaomi_touch_stub.o' >> "$TMK"
  [ -f include/linux/of_gpio.h ] && cp include/linux/of_gpio.h "$LINUX/include/linux/"
fi

if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
  export ARCH=arm64
  export CROSS_COMPILE=aarch64-linux-gnu-
  export CC="ccache ${CROSS_COMPILE}gcc"
else
  export ARCH=arm64
  export CC="ccache gcc"
fi
export KBUILD_BUILD_TIMESTAMP="Thu Jan  1 00:00:00 UTC 1970"
export KBUILD_BUILD_USER=nuwa
export KBUILD_BUILD_HOST=nuwa-build

mkdir -p "$OUT"
make -C "$LINUX" O="$OUT" defconfig

# ---- nuwa 需要的驱动/特性（内建，便于 initramfs 使用） ----
bash "$LINUX/scripts/config" --file "$OUT/.config" \
  --enable USB_GADGET --enable USB_CONFIGFS --enable USB_F_NCM --enable USB_CONFIGFS_NCM \
  --enable USB_ROLE_SWITCH --enable TYPEC --enable TYPEC_UCSI --enable TYPEC_QCOM_PMIC \
  --enable PHY_QCOM_QMP --enable PHY_QCOM_QMP_USB --enable PHY_QCOM_QMP_COMBO \
  --enable PHY_QCOM_QUSB2 --enable PHY_QCOM_EUSB2_REPEATER --enable PHY_QCOM_SNPS_FEMTO_V2 \
  --enable PSTORE_RAM --enable PSTORE_CONSOLE --enable PSTORE_PMSG \
  --enable TOUCHSCREEN_ST_FTS_V521_SPI \
  --enable ATH11K --enable ATH11K_PCI --enable BT_QCA --enable BT_HCIUART_QCA
make -C "$LINUX" O="$OUT" olddefconfig

make -C "$LINUX" O="$OUT" -j"$JOBS" Image dtbs

echo "== ccache stats =="
ccache -s | sed -n '1,12p'
