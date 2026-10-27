#!/sbin/sh
# TWRP 备用方案：把 vendor_boot_a 的 GPT 类型改为 EFI System Partition
# 目的：让 UEFI 的 FAT 驱动必定挂载该分区（若默认不挂载）
# 恢复：用脚本末尾打印的原类型改回

DISK=/dev/block/sda
PART=$(sgdisk -p $DISK | awk '/vendor_boot_a/ {print $1}')
if [ -z "$PART" ]; then echo "未找到 vendor_boot_a"; exit 1; fi

ORIG=$(sgdisk -i $PART $DISK | grep -i "Partition GUID code" | awk '{print $4}')
echo "vendor_boot_a = partition $PART"
echo "原类型 GUID = $ORIG"
echo "$PART $ORIG" > /tmp/vb_orig_type.txt

echo "改为 ESP 类型 ..."
sgdisk --typecode=$PART:C12A7328-F81F-11D2-BA4B-00A0C93EC93B $DISK
sgdisk -i $PART $DISK | grep -i "Partition GUID code"
echo ""
echo "改回命令（如需恢复）："
echo "  sgdisk --typecode=$PART:$ORIG $DISK"
