#!/bin/bash
# 从 rootfs tarball 生成可直接刷进分区 / 写进 U 盘的 ext4 镜像
# 用法: mkrootfs-image.sh <rootfs.tar.gz> <output.img> [size，默认 8G]
# 需要 root（loop mount）。在 WSL 里用: wsl.exe -d <distro> -u root bash ...
set -eu
TAR="${1:?用法: mkrootfs-image.sh <rootfs.tar.gz> <output.img> [size]}"
OUT="${2:?缺少输出镜像路径}"
SIZE="${3:-8G}"
MNT=$(mktemp -d)

[ -f "$TAR" ] || { echo "找不到 $TAR"; exit 1; }

echo "[1/5] 创建稀疏文件 $OUT ($SIZE)"
rm -f "$OUT"
truncate -s "$SIZE" "$OUT"

echo "[2/5] mkfs.ext4 -L nuwa-root"
mkfs.ext4 -q -L nuwa-root -F "$OUT"

echo "[3/5] 挂载并解包 rootfs"
mount -o loop "$OUT" "$MNT"
tar --numeric-owner -xzf "$TAR" -C "$MNT"
# 目录权限修正（tarball 里若有异常 root 属主）
chown root:root "$MNT"
mkdir -p "$MNT/dev" "$MNT/proc" "$MNT/sys" "$MNT/tmp" "$MNT/run"
chmod 1777 "$MNT/tmp"
sync

echo "[4/5] 卸载并检查"
umount "$MNT"
rmdir "$MNT"
e2fsck -fn "$OUT" 2>&1 | tail -3

echo "[5/5] 结果"
ls -l "$OUT"
echo "实际占用: $(du -h --apparent-size "$OUT" | cut -f1) (稀疏，du 实占 $(du -h "$OUT" | cut -f1))"
debugfs -R "ls -l /sbin/init" "$OUT" 2>/dev/null
debugfs -R "cat /etc/hostname" "$OUT" 2>/dev/null
sha256sum "$OUT"
