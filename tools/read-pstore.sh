#!/bin/sh
# 从 TWRP 读取 pstore 里的内核日志
ADB=${ADB:-C:/Android/platform-tools/adb.exe}
SERIAL=${SERIAL:-3705933}
"$ADB" -s "$SERIAL" shell 'ls -l /sys/fs/pstore 2>/dev/null; for f in /sys/fs/pstore/*; do echo "===== $f"; cat "$f" 2>/dev/null; done' 2>&1
