#!/usr/bin/env python3
"""Pack a staging tree into a TWRP-flashable zip.

Usage: make_zip.py <staging_dir> <output_zip>

Entries are deflated; META-INF/com/google/android/update-binary is stored
with unix mode 0755 (TWRP runs it as `sh update-binary ...`, so the bit is
conventional rather than load-bearing), everything else 0644.
"""
import os
import sys
import time
import zipfile

stage, out = sys.argv[1], sys.argv[2]
UPDATE_BINARY = "META-INF/com/google/android/update-binary"

if os.path.exists(out):
    os.remove(out)

count = 0
with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
    for root, dirs, files in os.walk(stage):
        dirs.sort()
        for name in sorted(files):
            full = os.path.join(root, name)
            rel = os.path.relpath(full, stage)
            mode = 0o100755 if rel == UPDATE_BINARY else 0o100644
            zi = zipfile.ZipInfo(rel, date_time=time.localtime(os.stat(full).st_mtime)[:6])
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = mode << 16
            with open(full, "rb") as fh:
                zf.writestr(zi, fh.read())
            count += 1

print(f"{out}: wrote {count} entries")
