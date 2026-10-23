#!/usr/bin/env python3
"""用新的 FDT 替换 vendor_boot 里的第一个设备树，保留其余变体。

用法: mk-vendor-boot.py <原厂 vendor_boot.img> <新 fdt.dtb> <输出.img>
"""
import struct
import sys

def align(n, page):
    return (n + page - 1) // page * page

def main(src, fdt_path, out_path):
    data = open(src, "rb").read()
    hdr = bytearray(data[:4096])
    assert bytes(hdr[:8]) == b"VNDRBOOT", "not a vendor_boot image"
    version, page = struct.unpack_from("<2I", hdr, 8)
    vramdisk_size = struct.unpack_from("<I", hdr, 24)[0]
    header_size = struct.unpack_from("<I", hdr, 2096)[0]
    dtb_size = struct.unpack_from("<I", hdr, 2100)[0]
    table_size = struct.unpack_from("<I", hdr, 2112)[0]
    bootconfig_size = struct.unpack_from("<I", hdr, 2136)[0]
    assert version == 4, f"vendor_boot v{version} not supported"

    ramdisk_off = align(header_size, page)
    dtb_off = align(ramdisk_off + vramdisk_size, page)
    table_off = align(dtb_off + dtb_size, page)
    bootconfig_off = align(table_off + table_size, page)

    ramdisk = data[ramdisk_off:ramdisk_off + vramdisk_size]
    orig_dtb = data[dtb_off:dtb_off + dtb_size]
    table = data[table_off:table_off + table_size]
    bootconfig = data[bootconfig_off:bootconfig_off + bootconfig_size]

    first_size = struct.unpack(">I", orig_dtb[4:8])[0]
    new_fdt = open(fdt_path, "rb").read()
    seg = new_fdt + orig_dtb[first_size:]

    struct.pack_into("<I", hdr, 2100, len(seg))

    def pad(b):
        return b + b"\0" * (align(len(b), page) - len(b))

    out = pad(bytes(hdr)) + pad(ramdisk) + pad(seg) + pad(table) + pad(bootconfig)
    open(out_path, "wb").write(out)
    print(f"wrote {out_path} ({len(out)} bytes, fdt {len(new_fdt)}, kept {dtb_size - first_size} bytes of variants)")

if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
