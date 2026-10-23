#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

LINUX=${LINUX_DIR:-linux}
OUT=${OUT_DIR:-out}
JOBS=${JOBS:-$(nproc)}

if [ ! -d "$LINUX" ]; then
  git clone --depth 1 ${LINUX_URL:-https://github.com/torvalds/linux.git} "$LINUX"
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
make -C "$LINUX" O="$(pwd)/$OUT" defconfig
make -C "$LINUX" O="$(pwd)/$OUT" -j"$JOBS" Image dtbs

echo "== ccache stats =="
ccache -s | sed -n '1,12p'
