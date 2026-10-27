#!/bin/bash
# 生成 ESP 镜像（双保险：EFI/BOOT/BOOTAA64.EFI 兜底 + EFI/UniXNU/unixnu.toml 配置）
set -e
OUT="${1:-/mnt/c/Users/L1872/Documents/nuwa ubt/other/esp-nuwa.img}"
BOOTEFI="${2:-/mnt/c/Users/L1872/Documents/nuwa ubt/other/bootefi/BOOTAA64.EFI}"
KERNEL="${3:-/mnt/c/Users/L1872/Documents/nuwa ubt/other/community-kernel/Image}"
DTB="${4:-/mnt/c/Users/L1872/Documents/nuwa ubt/other/community-kernel/dts/qcom/sm8550-xiaomi-nuwa.dtb}"
INITRD="${5:-/mnt/c/Users/L1872/Documents/nuwa ubt/public/nuwa/out/initramfs.cpio.gz}"

rm -f "$OUT"
dd if=/dev/zero of="$OUT" bs=1M count=64 status=none
mkfs.vfat -F 32 -n NUNIXNU "$OUT" > /dev/null
export MTOOLS_SKIP_CHECK=1

for d in ::/EFI ::/EFI/BOOT ::/EFI/UniXNU ::/Linux; do mmd -i "$OUT" "$d"; done

[ -f "$BOOTEFI" ] && mcopy -i "$OUT" "$BOOTEFI" ::/EFI/BOOT/BOOTAA64.EFI && echo "BOOTAA64.EFI: $(stat -c%s "$BOOTEFI") bytes"
[ -f "$KERNEL" ] && mcopy -i "$OUT" "$KERNEL" ::/Linux/Image
[ -f "$DTB" ] && mcopy -i "$OUT" "$DTB" ::/Linux/nuwa.dtb
[ -f "$INITRD" ] && mcopy -i "$OUT" "$INITRD" ::/Linux/initramfs.cpio.gz

cat > /tmp/unixnu.toml <<'EOF'
version = 1

[boot]
timeout = 8
default = "linux"

[ui]
title = "nuwa"

[[entry]]
id = "linux"
title = "Ubuntu Linux (mainline)"
type = "linux"
path = "Linux/Image"
initrd = "Linux/initramfs.cpio.gz"
dtb = "Linux/nuwa.dtb"
args = "console=tty0 ignore_loglevel"

[entry.chosen]
bootargs = "console=tty0 ignore_loglevel"

[[entry]]
id = "reset"
title = "Restart"
type = "action"
action = "reset"
EOF
mcopy -i "$OUT" /tmp/unixnu.toml ::/EFI/UniXNU/unixnu.toml

echo "=== 内容 ==="
mdir -i "$OUT" -/ ::/EFI/BOOT
mdir -i "$OUT" -/ ::/EFI/UniXNU
mdir -i "$OUT" -/ ::/Linux
ls -l "$OUT"
