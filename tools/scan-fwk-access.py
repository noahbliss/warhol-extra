#!/usr/bin/env python3
"""
scan-fwk-access.py -- predict IllegalAccessError/NoClassDefFoundError between
MediaTek's prebuilt jars and our AOSP/LineageOS framework, statically.

WHY THIS EXISTS
    MediaTek's telephony/IMS blobs were compiled against MediaTek's own patched
    framework. Where our framework declares a member package-private or private
    that theirs exposed, the blob throws the instant that code path runs:

        java.lang.IllegalAccessError: Field
          'com.android.internal.telephony.SmsStorageMonitor.mCi' is inaccessible
          to class 'com.mediatek.internal.telephony.MtkSmsStorageMonitor'

    Finding those one boot at a time is hopeless -- there are over a thousand.
    This resolves every field/method REFERENCE made from a MediaTek class up the
    superclass chain, reads the resolved declaration's real access flags out of
    the built dex, and reports the ones that cannot legally be reached.

USAGE (from the top of the build tree, after a build)
    P=out/target/product/warhol
    CONS=$(ls $P/system_ext/framework/mediatek-*.jar $P/system_ext/priv-app/*/*.apk | paste -sd, -)
    PROV=$(ls $P/system/framework/*.jar $P/system_ext/framework/*.jar | paste -sd, -)
    python3 device/xiaomi/warhol/tools/scan-fwk-access.py "$CONS" "$PROV"

    Needs out/host/linux-x86/bin/dexdump, so run it after a build. Takes a few
    minutes: it disassembles every consumer dex (~5.5M references).

READING THE OUTPUT
    "INACCESSIBLE MEMBERS" is a hard list: each entry is a guaranteed throw if the
    path executes. "UNRESOLVED" is a missing class or member -- cross-check against
    tools/ims-known-missing.txt, and do NOT trust that file's "dead" claims without
    a call-site dump (TelephonyBaseUtilsStub was listed as dead and was fatal).

    A member reported PROTECTED is fine and is not listed: we only resolve through
    the superclass chain, so protected access is legal by construction.

RESULT ON 2026-09-10
    1022 inaccessible members across 281 class pairs. 13 of the 14 components in
    overlay/packages/services/Telephony/res/xml/telephony_injection.xml are
    affected (131 members); only SmsUsageMonitor is clean. That is what killed the
    inject-MediaTek's-factory plan -- see docs/TELEPHONY.md.
"""
import os, re, subprocess, sys, zipfile, tempfile, shutil
from collections import defaultdict

DEXDUMP = os.environ.get("DEXDUMP", "out/host/linux-x86/bin/dexdump")

RE_CLASS  = re.compile(r"^  Class descriptor  : '(.+)'")
RE_SUPER  = re.compile(r"^  Superclass        : '(.+)'")
RE_SECT   = re.compile(r"^  (Static fields|Instance fields|Direct methods|Virtual methods)")
RE_MEMNO  = re.compile(r"^    #\d+\s+: \(in (.+)\)")
RE_NAME   = re.compile(r"^      name          : '(.*)'")
RE_TYPE   = re.compile(r"^      type          : '(.*)'")
RE_ACCESS = re.compile(r"^      access        : 0x([0-9a-f]+) \((.*)\)")
RE_FREF   = re.compile(r"\b(?:iget|iput|sget|sput)[a-z-]*\s+.*?,\s*L([^;]+);\.([^:]+):([^ ]+)")
RE_MREF   = re.compile(r"\binvoke-[a-z/]+(?:/range)?\s+\{[^}]*\},\s*L([^;]+);\.([^:]+):(\([^)]*\)[^ ]*)")

def dexes(jar, tmp):
    out = []
    try:
        z = zipfile.ZipFile(jar)
    except Exception:
        return out
    with z:
        for n in z.namelist():
            if re.fullmatch(r"classes\d*\.dex", n):
                d = os.path.join(tmp, os.path.basename(jar) + "." + n)
                with open(d, "wb") as f:
                    f.write(z.read(n))
                out.append(d)
    return out

def parse(dexpath, with_code):
    cmd = [DEXDUMP] + (["-d"] if with_code else []) + [dexpath]
    p = subprocess.run(cmd, capture_output=True, text=True, errors="replace")
    classes, refs = {}, []
    cur = None; sect = None; nm = ty = None
    for line in p.stdout.splitlines():
        m = RE_CLASS.match(line)
        if m:
            cur = m.group(1)
            if cur.startswith("L") and cur.endswith(";"):
                cur = cur[1:-1]
            classes.setdefault(cur, {"super": None, "fields": {}, "methods": {}})
            sect = None; nm = ty = None
            continue
        if cur is None:
            continue
        m = RE_SUPER.match(line)
        if m:
            sup = m.group(1)
            if sup.startswith("L") and sup.endswith(";"):
                sup = sup[1:-1]
            classes[cur]["super"] = sup; continue
        m = RE_SECT.match(line)
        if m:
            sect = m.group(1); nm = ty = None; continue
        if RE_MEMNO.match(line):
            nm = ty = None; continue
        m = RE_NAME.match(line)
        if m:
            nm = m.group(1); continue
        m = RE_TYPE.match(line)
        if m:
            ty = m.group(1); continue
        m = RE_ACCESS.match(line)
        if m and nm is not None and ty is not None and sect:
            flags = m.group(2)
            key = (nm, ty)
            if "fields" in sect:
                classes[cur]["fields"][key] = flags
            else:
                classes[cur]["methods"][key] = flags
            nm = ty = None
            continue
        if with_code:
            m = RE_FREF.search(line)
            if m:
                refs.append((cur, "field", m.group(1), m.group(2), m.group(3))); continue
            m = RE_MREF.search(line)
            if m:
                refs.append((cur, "method", m.group(1), m.group(2), m.group(3)))
    return classes, refs

def pkg(cls):
    return cls.rsplit("/", 1)[0] if "/" in cls else ""

def main():
    consumers = sys.argv[1].split(",")
    providers = sys.argv[2].split(",")
    tmp = tempfile.mkdtemp()
    allclasses = {}
    allrefs = []
    try:
        for jar in providers + consumers:
            if not os.path.exists(jar):
                continue
            want_code = jar in consumers
            for d in dexes(jar, tmp):
                c, r = parse(d, want_code)
                for k, v in c.items():
                    if k not in allclasses:
                        allclasses[k] = v
                    else:
                        allclasses[k]["fields"].update(v["fields"])
                        allclasses[k]["methods"].update(v["methods"])
                        if not allclasses[k]["super"]:
                            allclasses[k]["super"] = v["super"]
                allrefs.extend(r)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    sys.stderr.write("classes=%d refs=%d\n" % (len(allclasses), len(allrefs)))

    def resolve(cls, key, kind):
        seen = set()
        c = cls
        while c and c not in seen:
            seen.add(c)
            info = allclasses.get(c)
            if not info:
                return None
            if key in info[kind]:
                return c, info[kind][key]
            c = info["super"]
        return None

    bad = defaultdict(set)
    unresolved = defaultdict(set)
    for refcls, kind, rc, name, sig in allrefs:
        if not refcls.startswith(("com/mediatek", "com/xiaomi", "android/telephony/Mtk")):
            continue
        bucket = "fields" if kind == "field" else "methods"
        got = resolve(rc, (name, sig), bucket)
        if got is None:
            if rc.startswith(("com/android/", "android/")):
                unresolved[rc].add("%s %s:%s" % (kind, name, sig))
            continue
        owner, flags = got
        if pkg(owner) == pkg(refcls):
            continue
        if "PUBLIC" in flags or "PROTECTED" in flags:
            continue
        bad["%s -> %s" % (refcls, owner)].add("%s %s:%s  [%s]" % (kind, name, sig, flags))

    print("=" * 78)
    print("INACCESSIBLE MEMBERS (package-private/private, different package)")
    print("=" * 78)
    if not bad:
        print("  none")
    for k in sorted(bad):
        print("\n* " + k)
        for v in sorted(bad[k]):
            print("    " + v)
    print()
    print("=" * 78)
    print("UNRESOLVED references into AOSP namespaces (missing class/member)")
    print("=" * 78)
    if not unresolved:
        print("  none")
    for k in sorted(unresolved):
        print("\n* L%s;" % k)
        for v in sorted(unresolved[k]):
            print("    " + v)

main()
