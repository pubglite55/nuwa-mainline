#!/usr/bin/env python3
"""用新的 ramdisk 替换 vendor_boot 里的 vendor ramdisk，保留设备树/table/bootconfig。

背景：nuwa 的 UEFI 里 ShengBootMemoryDxe 会把 /chosen linux,initrd-start 指向的内存
发布成只读块设备，所以把 FAT 镜像放进 vendor ramdisk，UEFI 就能把它当普通卷挂载 ——
这条路径完全不依赖 UFS 驱动。

用法: mk-vendor-boot-ramdisk.py <原厂 vendor_boot.img> <新 ramdisk> <输出.img>
"""
import struct
import sys

PAGE = 4096


def align(n, page=PAGE):
    return (n + page - 1) // page * page


def pad(b, page=PAGE):
    return b + b"\0" * (align(len(b), page) - len(b))


def main(src, ramdisk_path, out_path):
    data = open(src, "rb").read()
    hdr = bytearray(data[:PAGE])
    assert bytes(hdr[:8]) == b"VNDRBOOT", "not a vendor_boot image"
    version, page = struct.unpack_from("<2I", hdr, 8)
    assert version == 4, f"vendor_boot v{version} not supported"

    vramdisk_size = struct.unpack_from("<I", hdr, 24)[0]
    header_size = struct.unpack_from("<I", hdr, 2096)[0]
    dtb_size = struct.unpack_from("<I", hdr, 2100)[0]
    table_size = struct.unpack_from("<I", hdr, 2112)[0]
    bootconfig_size = struct.unpack_from("<I", hdr, 2136)[0]

    ramdisk_off = align(header_size, page)
    dtb_off = align(ramdisk_off + vramdisk_size, page)
    table_off = align(dtb_off + dtb_size, page)
    bootconfig_off = align(table_off + table_size, page)

    dtb = data[dtb_off:dtb_off + dtb_size]
    table = data[table_off:table_off + table_size]
    bootconfig = data[bootconfig_off:bootconfig_off + bootconfig_size]

    new_ramdisk = open(ramdisk_path, "rb").read()
    struct.pack_into("<I", hdr, 24, len(new_ramdisk))

    out = pad(bytes(hdr)) + pad(new_ramdisk) + pad(dtb) + pad(table) + pad(bootconfig)
    open(out_path, "wb").write(out)
    print(f"wrote {out_path}")
    print(f"  ramdisk: {vramdisk_size} -> {len(new_ramdisk)} bytes")
    print(f"  dtb kept: {dtb_size} bytes, table: {table_size}, bootconfig: {bootconfig_size}")
    print(f"  total: {len(out)} bytes ({len(out)/1048576:.1f} MiB)")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print(__doc__)
        sys.exit(1)
    main(sys.argv[1], sys.argv[2], sys.argv[3])
