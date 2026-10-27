#!/sbin/sh
# 把 Ubuntu base rootfs 安装到指定分区
#
# 用法（TWRP 内）：
#   adb push other/ubuntu-base-26.04-arm64.tar.gz /tmp/
#   adb push public/nuwa/tools/install-rootfs.sh /tmp/
#   adb shell sh /tmp/install-rootfs.sh /dev/block/sdaXX
#
# 或在已启动的 Linux 里：
#   sudo sh install-rootfs.sh /dev/sdXN
#
# 警告：会格式化目标分区。

set -e

TARGET="$1"
ROOTFS="/tmp/ubuntu-base-26.04-arm64.tar.gz"
MNTPOINT="/mnt/nuwa-root"

if [ -z "$TARGET" ]; then
  echo "用法: $0 <分区设备>"
  echo "例:   $0 /dev/block/sda25"
  exit 1
fi

if [ ! -b "$TARGET" ]; then
  echo "!! $TARGET 不是块设备"
  exit 1
fi

if [ ! -f "$ROOTFS" ]; then
  echo "!! 找不到 $ROOTFS"
  echo "   先 adb push other/ubuntu-base-26.04-arm64.tar.gz /tmp/"
  exit 1
fi

echo "=============================================="
echo " 安装 Ubuntu rootfs 到 $TARGET"
echo "=============================================="
echo ""
echo "!! 这会格式化 $TARGET，5 秒后开始，Ctrl+C 取消"
sleep 5

echo "[1/7] 格式化 ext4 ..."
mkfs.ext4 -F -L nuwa-root "$TARGET"

echo "[2/7] 挂载 ..."
mkdir -p "$MNTPOINT"
mount "$TARGET" "$MNTPOINT"

echo "[3/7] 解压 rootfs（6564 个文件，需要几分钟）..."
tar xzf "$ROOTFS" -C "$MNTPOINT"

echo "[4/7] 生成 fstab ..."
cat > "$MNTPOINT/etc/fstab" <<'EOF'
# <file system>  <mount point>  <type>  <options>          <dump> <pass>
PARTLABEL=nuwa-root  /            ext4    errors=remount-ro  0      1
proc                 /proc        proc    defaults           0      0
sysfs                /sys         sysfs   defaults           0      0
devtmpfs             /dev         devtmpfs mode=0755,nosuid 0     0
EOF

echo "[5/7] 设置 hostname ..."
echo "nuwa" > "$MNTPOINT/etc/hostname"
cat > "$MNTPOINT/etc/hosts" <<'EOF'
127.0.0.1  localhost
127.0.1.1  nuwa
EOF

echo "[6/7] 复制内核模块（如果当前系统有）..."
if [ -d /lib/modules ]; then
  mkdir -p "$MNTPOINT/lib/modules"
  cp -a /lib/modules/* "$MNTPOINT/lib/modules/" 2>/dev/null || true
  echo "   已复制 $(ls /lib/modules 2>/dev/null | wc -l) 个模块目录"
else
  echo "   (无 /lib/modules，跳过 —— 内核全内建时不需要)"
fi

echo "[7/7] 卸载 ..."
sync
umount "$MNTPOINT"

echo ""
echo "=============================================="
echo " 完成。分区标签: nuwa-root"
echo "=============================================="
echo ""
echo "下一步："
echo "  1. 启动参数加 root=PARTLABEL=nuwa-root rootwait"
echo "  2. 首次启动后 chroot 进去装 GNOME："
echo "     apt update && apt install -y ubuntu-desktop-minimal network-manager"
