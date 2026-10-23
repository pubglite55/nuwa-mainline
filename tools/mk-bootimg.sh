#!/bin/sh
set -e
cd "$(dirname "$0")/.."
KERNEL=${KERNEL:-kernel/linux/arch/arm64/boot/Image}
DTB=${DTB:-kernel/linux/arch/arm64/boot/dts/qcom/nuwa.dtb}
RAMDISK=${RAMDISK:-out/initramfs.cpio.gz}
OUT=${OUT_DIR:-out}
mkdir -p "$OUT"
mkbootimg \
  --kernel "$KERNEL" \
  --ramdisk "$RAMDISK" \
  --dtb "$DTB" \
  --base 0x0 \
  --kernel_offset 0x80008000 \
  --ramdisk_offset 0x01000000 \
  --dtb_offset 0x01f00000 \
  --tags_offset 0x00000100 \
  --pagesize 4096 \
  --header_version 2 \
  --cmdline "console=ttyMSM0,115200n8 panic=30 loglevel=8" \
  --output "$OUT/boot-ram.img"
ls -l "$OUT/boot-ram.img"
