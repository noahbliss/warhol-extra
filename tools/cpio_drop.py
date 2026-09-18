#!/usr/bin/env python3
"""Drop modules from one modules.load* list inside a vendor ramdisk (newc cpio).

    cpio_drop.py <in.cpio> <out.cpio> <list path in the archive> <module.ko>...

Only that one list changes; every other byte of the archive is copied as it was, so an
unpacked vendor_boot fragment can be edited and repacked without disturbing the rest.
docs/UPDATING.md ("Updating the kernel") has the unpack and repack commands around it.
The archive is walked entry by entry: "TRAILER!!!" also occurs inside binaries in the
ramdisk, and finding the end by searching for it once cut the archive short.
"""
import sys


def main():
    if len(sys.argv) < 5:
        print(__doc__)
        sys.exit(1)
    src = open(sys.argv[1], "rb").read()
    dst, target, drop = sys.argv[2], sys.argv[3], set(sys.argv[4:])
    o, out, hit, removed = 0, bytearray(), 0, []
    while True:
        h = src[o:o + 110]
        if h[:6] != b"070701":
            sys.exit(f"ABORT: no newc cpio header at offset {o}")
        f = [int(h[6 + 8 * i:14 + 8 * i], 16) for i in range(13)]
        namesize, filesize = f[11], f[6]
        name = src[o + 110:o + 110 + namesize - 1].decode()
        doff = (o + 110 + namesize + 3) & ~3
        end = (doff + filesize + 3) & ~3
        if name == target:
            lines = src[doff:doff + filesize].decode().splitlines(True)
            keep = [l for l in lines if l.strip() not in drop]
            removed = [l.strip() for l in lines if l.strip() in drop]
            new = "".join(keep).encode()
            hdr = bytearray(h)
            hdr[54:62] = b"%08X" % len(new)  # c_filesize
            out += bytes(hdr) + src[o + 110:doff] + new + b"\0" * ((-len(new)) % 4)
            hit += 1
        else:
            out += src[o:end]
        if name == "TRAILER!!!":
            break
        o = end
    if hit != 1:
        sys.exit(f"ABORT: {target} found {hit} times")
    if any(src[end:]):
        sys.exit("ABORT: data after the trailer; this is not a single cpio archive")
    out += b"\0" * ((-len(out)) % 512)
    open(dst, "wb").write(out)
    missing = sorted(drop - set(removed))
    print(f"{target}: removed {' '.join(removed) or 'nothing'}"
          + (f"; not listed: {' '.join(missing)}" if missing else ""))


if __name__ == "__main__":
    main()
