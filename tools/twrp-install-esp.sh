#!/sbin/sh
# nuwa ESP 安装脚本（TWRP 内执行）
# 用法：adb push esp-nuwa.img /tmp/ && adb push twrp-install-esp.sh /tmp/ && adb shell sh /tmp/twrp-install-esp.sh [--set-esp-type]
#
# 作用：
#   1) 把 ESP 镜像写入 vendor_boot_a
#   2) 可选：把 vendor_boot_a 的 GPT 类型改为 EFI System Partition
#   3) 打印验证信息

set -e
setenforce 0 2>/dev/null || true

DISK=/dev/block/sda
IMG=/tmp/esp-nuwa.img
SETTYPE=0
[ "$1" = "--set-esp-type" ] && SETTYPE=1

echo "=== 设备信息 ==="
sgdisk -p $DISK | head -5

PART=$(sgdisk -p $DISK | awk '/vendor_boot_a/ {print $1}')
if [ -z "$PART" ]; then echo "!! 未找到 vendor_boot_a"; exit 1; fi
START=$(sgdisk -i $PART $DISK | awk -F': ' '/First sector/ {print $2}')
SECTORS=$(sgdisk -i $PART $DISK | awk -F': ' '/Partition size/ {print $2}')
echo "vendor_boot_a = 分区 $PART, 起始扇区 $START, 扇区数 $SECTORS"

if [ ! -f "$IMG" ]; then echo "!! 缺少 $IMG（先 adb push）"; exit 1; fi
IMGSZ=$(wc -c < "$IMG")
PARTSZ=$((SECTORS * 512))
echo "镜像 $IMGSZ 字节 / 分区 $PARTSZ 字节"
if [ "$IMGSZ" -gt "$PARTSZ" ]; then echo "!! 镜像大于分区"; exit 1; fi

if [ "$SETTYPE" = "1" ]; then
  ORIG=$(sgdisk -i $PART $DISK | grep -i "Partition GUID code" | awk '{print $4}')
  echo "原类型 GUID: $ORIG"
  echo "$PART $ORIG" > /tmp/vb_orig_type.txt
  echo "改为 ESP 类型 ..."
  sgdisk --typecode=$PART:C12A7328-F81F-11D2-BA4B-00A0C93EC93B $DISK
  sgdisk -i $PART $DISK | grep -i "Partition GUID code"
fi

echo "=== 写入 ESP 镜像 ==="
dd if="$IMG" of=$DISK bs=512 seek=$START conv=notrunc 2>&1 | tail -3
sync

echo "=== 验证 FAT ==="
mkdir -p /tmp/espcheck
mount -t vfat $(ls /dev/block/platform/*/by-name/vendor_boot_a 2>/dev/null || echo /dev/block/sda$PART) /tmp/espcheck 2>/dev/null || true
if mountpoint -q /tmp/espcheck 2>/dev/null || [ -f /tmp/espcheck/EFI/BOOT/BOOTAA64.EFI ]; then
  echo "ESP 挂载成功："
  ls -l /tmp/espcheck/EFI/BOOT/ /tmp/espcheck/EFI/UniXNU/ 2>/dev/null
  umount /tmp/espcheck 2>/dev/null || true
else
  echo "(无法在 TWRP 内挂载验证，属正常)"
fi

echo ""
echo "=== 完成 ==="
echo "重启到 UEFI：reboot"
if [ "$SETTYPE" = "1" ]; then
  echo "恢复分区类型命令："
  cat /tmp/vb_orig_type.txt
fi
