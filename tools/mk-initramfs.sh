#!/bin/sh
set -e
cd "$(dirname "$0")/.."
OUT=${OUT_DIR:-out}
BUSYBOX=${BUSYBOX:?set BUSYBOX to an arm64 static busybox binary}
ROOT=$OUT/initramfs-root
rm -rf "$ROOT"
mkdir -p "$ROOT"/bin "$ROOT"/dev "$ROOT"/proc "$ROOT"/sys "$ROOT"/tmp
cp "$BUSYBOX" "$ROOT/bin/busybox"
chmod +x "$ROOT/bin/busybox"
cp tools/init "$ROOT/init"
chmod +x "$ROOT/init"
(cd "$ROOT" && find . | cpio -o -H newc 2>/dev/null | gzip -9) > "$OUT/initramfs.cpio.gz"
ls -l "$OUT/initramfs.cpio.gz"
