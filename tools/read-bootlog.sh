#!/sbin/sh
# 读取 UEFI 写入 boot_b 最后一块的启动日志（WriteBootLog）
# 在 TWRP 里执行：adb shell sh /tmp/read-bootlog.sh
#
# 原理：uefi-nuwa 的 ShengBootMemoryDxe 每次启动都会在 payload 卷的最后一块
# 写入 "NUWABOOT count=N dtb=0x... started"。
#   - count 递增 → 内核确实被启动了（UEFI 走到了交接点）
#   - count 不变 → UEFI 没走到那一步（更早的环节有问题）

set -e
DISK=/dev/block/sda

PART=$(sgdisk -p $DISK 2>/dev/null | awk '/boot_b/ {print $1}')
if [ -z "$PART" ]; then echo "!! 未找到 boot_b"; exit 1; fi

START=$(sgdisk -i $PART $DISK | awk -F': ' '/First sector/ {print $2}')
SECTORS=$(sgdisk -i $PART $DISK | awk -F': ' '/Partition size/ {print $2}')
echo "boot_b = 分区 $PART, 起始扇区 $START, 扇区数 $SECTORS"

# 最后一块（512 字节）
LAST=$((START + SECTORS - 1))
echo "读取最后一块（扇区 $LAST）..."
dd if=$DISK bs=512 skip=$LAST count=1 2>/dev/null | hexdump -C | head -12

echo ""
echo "=== 解析 ==="
dd if=$DISK bs=512 skip=$LAST count=1 2>/dev/null | strings | head -5

echo ""
echo "判读："
echo "  出现 'NUWABOOT count=N' → UEFI 走到交接点，count 越大说明重启次数越多"
echo "  没有该字符串 → UEFI 未走到 WriteBootLog（更早环节失败）"
echo "  全零 → boot_b 未被识别为 payload（检查 OEM 标签是否为 MTOO4043）"
