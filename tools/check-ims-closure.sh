#!/usr/bin/env bash
# =============================================================================
# check-ims-closure.sh — does every class the MediaTek IMS stack references
#                        actually exist in the build?
#
#     ./tools/check-ims-closure.sh                    # run on the build host
#
# WHY
#   The IMS stack is prebuilt dex lifted off stock firmware. Soong will happily
#   install a dex_import whose references do not resolve -- there is no link step
#   to fail. The build succeeding proves nothing about whether
#   MtkTelephonyComponentFactory can actually load, and a missing class shows up
#   at runtime as a ClassNotFoundException in a logcat nobody is reading, with
#   VoWiFi simply not working.
#
#   So: parse the dex directly. Every type_id in the MediaTek jars and APKs is a
#   type they reference; every class_def across the whole classpath is a type the
#   build provides. Anything referenced and not provided is a hole.
#
# WHY NOT dexdump
#   dexdump prints a human report per class and is minutes-slow across a whole
#   classpath. The two tables this needs are 20 lines of struct parsing.
#
# EXPECTED RESULT
#   Not zero. Some references are genuinely dead code -- stock ships classes for
#   hardware and carriers warhol does not have. The value is the DIFF against the
#   last run: a new name appearing after a rebuild is a regression worth chasing.
#   Known-dead names live in tools/ims-known-missing.txt.
# =============================================================================
set -euo pipefail

SRC="${SRC:-/run/media/local/4TB/warhol-los/src}"
OUT="${OUT:-$SRC/out/target/product/warhol}"
KNOWN="${KNOWN:-$(dirname "$0")/ims-known-missing.txt}"

[ -d "$OUT/system/framework" ] || { echo "no build at $OUT" >&2; exit 1; }

python3 - "$OUT" "$KNOWN" <<'PY'
import sys, os, struct, zipfile, glob

out, known_path = sys.argv[1], sys.argv[2]

def dex_tables(buf):
    """(defined types, referenced types) from one dex, as descriptor strings."""
    if buf[:4] not in (b'dex\n', b'cdex'):
        return set(), set()
    if buf[:4] == b'cdex':
        return set(), set()                      # compact dex: not used in these jars
    (string_ids_size, string_ids_off, type_ids_size, type_ids_off) = struct.unpack_from('<IIII', buf, 56)
    class_defs_size, class_defs_off = struct.unpack_from('<II', buf, 96)

    str_off = struct.unpack_from(f'<{string_ids_size}I', buf, string_ids_off)
    def s(i):
        p = str_off[i]
        # uleb128 length, then MUTF-8 up to NUL
        shift = 0
        while buf[p] & 0x80:
            p += 1; shift += 7
            if shift > 28: break
        p += 1
        e = buf.index(b'\x00', p)
        return buf[p:e].decode('utf-8', 'replace')

    type_desc = [s(i) for i in struct.unpack_from(f'<{type_ids_size}I', buf, type_ids_off)]
    referenced = {t for t in type_desc if t.startswith('L') and t.endswith(';')}
    defined = set()
    for i in range(class_defs_size):
        (class_idx,) = struct.unpack_from('<I', buf, class_defs_off + i*32)
        if class_idx < len(type_desc):
            defined.add(type_desc[class_idx])
    return defined, referenced

def scan(path):
    d, r = set(), set()
    try:
        with zipfile.ZipFile(path) as z:
            for n in z.namelist():
                if n.startswith('classes') and n.endswith('.dex'):
                    dd, rr = dex_tables(z.read(n))
                    d |= dd; r |= rr
    except zipfile.BadZipFile:
        pass
    return d, r

# Everything on the classpath the runtime will actually have.
#
# The installed image is not enough on its own. APEXes ship as .capex/.apex, so
# the classes in core-oj, core-libart, conscrypt, framework-wifi and the rest of
# the mainline modules are not reachable by globbing system/framework. Missing
# them makes ordinary ART classes look unresolved -- an earlier version of this
# script reported sun/misc/Signal as a hole, which it plainly is not.
#
# Soong stages exactly these two sets before dexpreopt, and together they are the
# real boot + mainline classpath:
#     dexpreopt_arm64/dex_bootjars_input/      core-oj, core-libart, framework, ...
#     dexpreopt_arm64/dex_mainlinejars_input/  framework-wifi, framework-connectivity, ...
soong = os.path.join(out.rstrip('/').rsplit('/target/', 1)[0], 'soong')   # <out>/soong
classpath = []
for pat in ('system/framework/*.jar', 'system_ext/framework/*.jar',
            'system/apex/*/javalib/*.jar', 'apex/*/javalib/*.jar'):
    classpath += glob.glob(os.path.join(out, pat))
for pat in ('dexpreopt_*/dex_bootjars_input/*.jar',
            'dexpreopt_*/dex_mainlinejars_input/*.jar'):
    classpath += glob.glob(os.path.join(soong, pat))
# NOT obj/JAVA_LIBRARIES/*_intermediates/javalib.jar. That was the first crude way
# of reaching APEX classes and it is over-broad: it contains every Java library the
# product builds, including static libs that are never on any runtime classpath.
# The dexpreopt staging dirs above are precise, so this glob only adds noise -- and
# it is where a jar from a previous configuration hid after the dexpreopt copy was
# deleted.
classpath = sorted(set(classpath))

# Those staging directories are NOT cleaned when a module leaves the product, so
# they can hand us classes the device will never load. This bit once: a jar built
# on a branch stayed in dex_bootjars_input after switching back, and the report
# quietly counted its classes as provided -- 24 unresolved instead of the true 41.
#
# Modelling the runtime classpath exactly is not worth it (the shipped
# bootclasspath.pb lists only the 19 platform jars; ART and mainline contribute
# theirs from inside each APEX at boot). So make staleness visible instead: list
# every staged jar that is not installed, and let the reader notice a device
# module sitting among the ART ones.
installed = {os.path.basename(j) for j in glob.glob(os.path.join(out, 'system*/framework/*.jar'))}
staged_only = sorted({os.path.basename(j) for j in classpath if '/dexpreopt_' in j} - installed)
# ART and mainline jars are staged-but-not-installed by design, and there are ~40
# of them, so listing all of them buries the one that matters. A jar THIS DEVICE
# TREE builds has a Soong intermediate under .intermediates/device/ -- if such a
# jar is staged and not installed, it is left over from a previous configuration.
# Match on DIRECTORY names, not jar files: Soong names an intermediates directory
# after the module, and that survives someone deleting the stale jar itself --
# which is exactly what happened the first time, quietly disarming this check.
soong_root = os.path.join(soong, '.intermediates', 'device')
ours = set()
for depth in range(1, 7):
    for d in glob.glob(os.path.join(soong_root, *(['*'] * depth))):
        if os.path.isdir(d):
            ours.add(os.path.basename(d) + '.jar')
stale = sorted(set(staged_only) & ours)
if stale:
    print("!!! STALE staged jars from a previous configuration:", ", ".join(stale))
    print("    They are on this classpath but not on the device. Delete them from")
    print("    out/soong/dexpreopt_*/dex_*jars_input/ or the counts below are wrong.")
elif staged_only:
    print(f"staged but not installed: {len(staged_only)} jars — ART + mainline, "
          f"contributed from inside APEXes at boot. Expected.")

provided = set()
for j in classpath:
    d, _ = scan(j)
    provided |= d
print(f"classpath: {len(classpath)} jars, {len(provided)} classes provided")

MTK = ('mediatek-', 'MtkTele', 'ImsService', 'Ims')
targets = [j for j in glob.glob(os.path.join(out, 'system_ext/framework/*.jar'))
           if os.path.basename(j).startswith('mediatek-')]
targets += [a for a in glob.glob(os.path.join(out, 'system_ext/**/*.apk'), recursive=True)
            if any(k in os.path.basename(a) for k in ('Ims', 'Mtk', 'ims'))]
print(f"targets:   {len(targets)} IMS jars/APKs")

own, refs = set(), set()
by_target = {}
for t in targets:
    d, r = scan(t)
    own |= d; refs |= r
    by_target[os.path.basename(t)] = r

missing = sorted(refs - provided - own)
# Array and primitive descriptors are not classes to resolve.
missing = [m for m in missing if not m.startswith('[')]

known = set()
if os.path.exists(known_path):
    known = {l.strip() for l in open(known_path)
             if l.strip() and not l.startswith('#')}

new = [m for m in missing if m not in known]
gone = sorted(known - set(missing))

print(f"referenced: {len(refs)}   unresolved: {len(missing)}   "
      f"known-dead: {len(known)}   NEW: {len(new)}")
# Which jar references it is the whole question. An unresolved class reached only
# from mediatek-services is irrelevant to VoWiFi; one reached from an ims- jar is
# not. Group the report that way rather than as one flat list.
IMS = ('mediatek-ims-base', 'mediatek-ims-common', 'mediatek-ims-extension-plugin',
       'mediatek-telephony-common', 'mediatek-telephony-base')
def who(m):
    return sorted(j for j, r in by_target.items() if m in r)
def ims_reached(m):
    return [j for j in who(m) if any(k in j for k in IMS)]

if new:
    hot  = [m for m in new if ims_reached(m)]
    cold = [m for m in new if not ims_reached(m)]
    if hot:
        print("\n=== NEW, reachable from an IMS jar — these matter ===")
        for m in hot:
            print(f"    {m}\n        from: {', '.join(who(m))}")
    if cold:
        print("\n=== NEW, not reachable from any IMS jar ===")
        for m in cold:
            print(f"    {m}  ({', '.join(who(m))})")
if gone:
    print("\n=== listed as known-dead but now resolve (stale entries) ===")
    for m in gone:
        print("   ", m)
if not new:
    print("\nNo new unresolved references.")
sys.exit(1 if new else 0)
PY
