#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

SUITE=${SUITE:-resolute}
ARCH=${ARCH:-arm64}
MIRROR=${MIRROR:-http://ports.ubuntu.com/ubuntu-ports}
OUT=${OUT_DIR:-out}

mkdir -p "$OUT"

if ! command -v mmdebstrap >/dev/null 2>&1; then
  echo "需要 mmdebstrap（apt install mmdebstrap）" >&2
  exit 1
fi

# Ubuntu 26.04 GNOME 基础根文件系统（原生 arm64 构建）
mmdebstrap \
  --arch="$ARCH" \
  --variant=important \
  --components=main,universe,restricted \
  --include=systemd,systemd-sysv,initramfs-tools,ca-certificates,openssh-server,network-manager,ubuntu-desktop-minimal,linux-firmware \
  "$SUITE" "$OUT/rootfs.tar" "$MIRROR"

zstd -T0 -19 -f "$OUT/rootfs.tar" -o "$OUT/rootfs.tar.zst"
rm -f "$OUT/rootfs.tar"
ls -lh "$OUT"
