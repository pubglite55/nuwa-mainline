#!/usr/bin/env python3
"""把内核 Image / dtb 打包成 ABL 可刷的 boot / vendor_boot 镜像。

用法:
  mk-flash-images.py --image Image --dtb nuwa.dtb --out-dir out
产物:
  out/boot.img            v4 内核镜像（含 Image）
  out/vendor_boot-probe.img  原厂 vendor_boot 结构 + 首 FDT 替换 + 探针 ramdisk
  out/vendor_boot-full.img   同上，但用完整 initramfs
"""
import argparse, os, struct

PAGE = 4096

def align(n):
    return (n + PAGE - 1) // PAGE * PAGE

def pad(b):
    return b + b"\0" * (align(len(b)) - len(b))

def mk_vendor_boot(src, fdt, ramdisk, out):
    data = open(src, "rb").read()
    hdr = bytearray(data[:PAGE])
    assert data[:8] == b"VNDRBOOT", "not vendor_boot"
    ver, page = struct.unpack_from("<2I", hdr, 8)
    assert ver == 4, f"vendor_boot v{ver}"
    vr = struct.unpack_from("<I", hdr, 24)[0]
    hs = struct.unpack_from("<I", hdr, 2096)[0]
    ds = struct.unpack_from("<I", hdr, 2100)[0]
    ts = struct.unpack_from("<I", hdr, 2112)[0]
    bs = struct.unpack_from("<I", hdr, 2136)[0]
    ro = align(hs); do = align(ro + vr); to = align(do + ds); bo = align(to + ts)
    table = data[to:to + ts]
    bootconfig = data[bo:bo + bs]
    orig = data[do:do + ds]
    first = struct.unpack(">I", orig[4:8])[0]
    new_dtb = open(fdt, "rb").read() + orig[first:]
    new_rd = open(ramdisk, "rb").read()
    struct.pack_into("<I", hdr, 24, len(new_rd))
    struct.pack_into("<I", hdr, 2100, len(new_dtb))
    body = pad(bytes(hdr)) + pad(new_rd) + pad(new_dtb) + pad(table) + pad(bootconfig)
    open(out, "wb").write(body)
    print(f"{out}: {len(body)} bytes (kernel dtb {len(new_dtb)})")

def mk_boot(image, out):
    k = open(image, "rb").read()
    hdr = bytearray(PAGE)
    hdr[0:8] = b"ANDROID!"
    struct.pack_into("<I", hdr, 8, len(k))      # kernel_size
    struct.pack_into("<I", hdr, 12, 0)          # kernel_addr
    struct.pack_into("<I", hdr, 16, 0)          # ramdisk_size
    struct.pack_into("<I", hdr, 20, 0)          # ramdisk_addr
    struct.pack_into("<I", hdr, 36, 4096)       # page_size
    struct.pack_into("<I", hdr, 40, 5)          # header_version
    body = bytes(hdr) + pad(k)
    open(out, "wb").write(body)
    print(f"{out}: {len(body)} bytes (kernel {len(k)})")

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", required=True)
    ap.add_argument("--dtb", required=True)
    ap.add_argument("--src-vendor-boot", required=True)
    ap.add_argument("--probe-ramdisk", required=True)
    ap.add_argument("--full-ramdisk", required=True)
    ap.add_argument("--out-dir", required=True)
    a = ap.parse_args()
    os.makedirs(a.out_dir, exist_ok=True)
    mk_boot(a.image, os.path.join(a.out_dir, "boot.img"))
    mk_vendor_boot(a.src_vendor_boot, a.dtb, a.probe_ramdisk, os.path.join(a.out_dir, "vendor_boot-probe.img"))
    mk_vendor_boot(a.src_vendor_boot, a.dtb, a.full_ramdisk, os.path.join(a.out_dir, "vendor_boot-full.img"))
