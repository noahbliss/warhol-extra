#!/usr/bin/env python3
"""Re-apply the debuggability scaffolding to freshly built images.

The build emits ro.secure=1 / ro.debuggable=0 / ro.adb.secure=1 even at userdebug,
because the release config signs with release-keys. It is **ro.secure=0** that grants
`adb root`, not ro.debuggable -- the phone can report ro.debuggable=0 while `adb root`
works. Magisk root is unaffected either way; this is only about adbd.

Same-length byte substitutions, so the ext4 layout is untouched and the images stay
flashable as-is. Newline-anchored so we hit system/build.prop and NOT
system/etc/init/tradeinmode.rc, whose "property:ro.debuggable=0" trigger runs
"stop adbd" -- patching that would kill adb instead of enabling root.

Ported from the 23.2 tree, which is the only place it existed; the 24.0 tree never had
it, so every 24.0 flash silently shipped ro.secure=1. Same class of gap as
warhol-los24-lost-patches.

Writes patched copies to $WARHOL_ROOT/tmp/flash -- flash from there, not from out/.
"""
import hashlib
import os
import shutil
import sys

ROOT = os.environ.get("WARHOL_ROOT", "/run/media/local/4TB/warhol-los-24")
SRC = os.path.join(ROOT, "src", "out", "target", "product", "warhol")
DST = os.path.join(ROOT, "tmp", "flash")
os.makedirs(DST, exist_ok=True)

JOBS = {
    "system.img": [(b"\nro.secure=1\n",     b"\nro.secure=0\n"),
                   (b"\nro.debuggable=0\n", b"\nro.debuggable=1\n")],
    "system_ext.img": [(b"\nro.adb.secure=1\n", b"\nro.adb.secure=0\n")],
    "product.img": [],
}

rc = 0
for name, subs in JOBS.items():
    s, d = os.path.join(SRC, name), os.path.join(DST, name)
    if not os.path.isfile(s):
        print("  !! missing %s -- ABORT" % s)
        rc = 1
        continue
    shutil.copyfile(s, d)
    data = bytearray(open(d, "rb").read())
    before = len(data)
    for old, new in subs:
        assert len(old) == len(new), (old, new)
        n = data.count(old)
        if n != 1:
            print("  !! %s: expected exactly 1 of %r, found %d -- ABORT" % (name, old, n))
            rc = 1
            continue
        data[:] = data.replace(old, new)
        print("  %s: %r -> %r  (1 occurrence)" % (name, old.strip(), new.strip()))
    assert len(data) == before, "length changed!"
    if name == "system.img":
        guard = data.count(b"property:ro.debuggable=0")
        print("  %s: tradeinmode.rc trigger still intact: %d occurrence(s)" % (name, guard))
        if guard != 1:
            print("  !! guard failed -- ABORT")
            rc = 1
    open(d, "wb").write(bytes(data))
    print("  %s: %d bytes  sha256 %s" % (name, len(data), hashlib.sha256(bytes(data)).hexdigest()))
    print()
sys.exit(rc)
