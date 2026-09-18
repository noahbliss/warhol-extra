#!/usr/bin/env python3
"""Move warhol to a newer Google GKI kernel of the same KMI generation.

Xiaomi ships Google's certified GKI kernel unmodified, next to about 580 vendor modules
built for one KMI generation. Google keeps publishing fixed builds of that generation, and
those install without touching the vendor modules: only boot_a (the kernel) and
system_dlkm_a (Google's own modules, signed per build) change. This tool does what was done
by hand for r32 -> r38 on 2026-09-18. The procedure is docs/UPDATING.md, "Updating the kernel".

    gki_update.py list                 Google's releases, newest first, the phone's marked
    gki_update.py build <tag>          e.g. 2025-09_r42: download, check, build both images
    gki_update.py build <tag> --check-only   run every check, report all failures, build nothing
    gki_update.py write-dlkm <dir>     from TWRP: write <dir>/system_dlkm_a.img and verify it
    gki_update.py write-dlkm <dir> --rollback   the same with <dir>/rollback/system_dlkm_a.img

`build` reads from the phone (booted into Android, Magisk root over adb) and never writes to
it. It stops with exit 1 when any check fails. Nothing here writes boot_a: that is one
`fastboot flash` the user runs from the bootloader, printed at the end of `build`.
"""
import gzip, hashlib, os, re, shutil, struct, subprocess, sys, time

ROOT = os.environ.get("WARHOL_ROOT", "/run/media/local/4TB/warhol-los-24")
HOST = os.path.join(ROOT, "src/out/host/linux-x86/bin")
GKI = os.environ.get("WARHOL_GKI_DIR", os.path.join(ROOT, "gki"))
BRANCH = "android16-6.12"
PAGE = "https://source.android.com/docs/core/architecture/kernel/gki-android16-6_12-release-builds"
ZIP = "https://dl.google.com/android/gki/gki-certified-boot-{tag}-lz4.zip"
CI = "https://ci.android.com/builds/submitted/{bid}/kernel_aarch64/latest/raw/{name}"
# These reproduce the phone's system_dlkm byte for byte; every build re-proves that first.
EROFS = ["-zlz4hc,9", "-b", "4096", "--mount-point=/system_dlkm", "-T", "1230768000"]
DLKM_FC = "/system_dlkm(/.*)?    u:object_r:system_dlkm_file:s0\n"
SIG_MAGIC = b"~Module signature appended~\n"
DEVNULL = subprocess.DEVNULL


def die(msg):
    print(f"ABORT: {msg}", file=sys.stderr)
    sys.exit(1)


FAILS = []
CHECK_ONLY = False


def fail(msg):
    """A release that must not be installed: stop, or with --check-only note it and go on."""
    if not CHECK_ONLY:
        die(msg)
    print(f"FAIL {msg}")
    FAILS.append(msg)


def run(cmd, **kw):
    kw.setdefault("stdin", DEVNULL)
    return subprocess.run(cmd, check=True, **kw)


def out(cmd):
    return run(cmd, capture_output=True).stdout


def tool(name):
    p = os.path.join(HOST, name)
    if not os.access(p, os.X_OK):
        die(f"{p} missing; it comes from a LineageOS build of this tree")
    return p


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def read(path):
    with open(path, "rb") as f:
        return f.read()


def write(path, data):
    with open(path, "wb") as f:
        f.write(data)


def fetch(url, dest):
    if os.path.exists(dest):
        return dest
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    run(["curl", "-fsSL", "-o", dest + ".part", url])
    os.rename(dest + ".part", dest)
    return dest


# ---- phone ----

def adb_state():
    r = subprocess.run(["adb", "get-state"], stdin=DEVNULL, capture_output=True, text=True)
    return r.stdout.strip()


def dev(cmd):
    """Root shell on the phone: Magisk su in Android, adbd is already root in TWRP."""
    st = adb_state()
    if st == "device":
        return out(["adb", "exec-out", f"su -c '{cmd}'"])
    if st == "recovery":
        return out(["adb", "exec-out", cmd])
    die("no phone on adb")


def pull(cmd, dest):
    write(dest, dev(cmd))
    return dest


# ---- releases ----

def releases():
    page = out(["curl", "-fsSL", PAGE]).decode("utf-8", "replace")
    rel = {}
    for row in re.findall(r"<tr[^>]*>(.*?)</tr>", page, re.S):
        text = re.sub(r"<[^>]+>", " ", row)
        tag = re.search(re.escape(BRANCH) + r"-\d{4}-\d{2}_r\d+", text)
        bid = re.search(r"builds/submitted/(\d+)/kernel_aarch64", row)
        date = re.search(r"\b(20\d\d-\d\d-\d\d)\b", text)
        if tag and bid:
            rel[tag.group(0)] = (date.group(1) if date else "?", int(bid.group(1)))
    if not rel:
        die(f"no releases found on {PAGE}; the page layout changed")
    return rel


KREL = re.compile(r"(\d+\.\d+\.\d+)-android(\d+)-(\d+)-g([0-9a-f]+)-ab(\d+)")


def parse_krel(krel):
    m = KREL.match(krel)
    if not m:
        die(f"cannot parse kernel release '{krel}'")
    return {"ver": m.group(1), "gen": int(m.group(3)), "sha": m.group(4), "bid": int(m.group(5))}


# ---- boot images ----

def unpack_kernel(boot_img, work):
    d = os.path.join(work, "unpack-" + os.path.basename(boot_img))
    shutil.rmtree(d, ignore_errors=True)
    run([tool("unpack_bootimg"), "--boot_img", boot_img, "--out", d], capture_output=True)
    k = read(os.path.join(d, "kernel"))
    if k[:4] == b"\x02\x21\x4c\x18":
        k = out([tool("lz4"), "-dc", os.path.join(d, "kernel")])
    elif k[:2] == b"\x1f\x8b":
        k = gzip.decompress(k)
    m = re.search(rb"Linux version (\S+)", k)
    if not m:
        die(f"no kernel version string in {boot_img}")
    return m.group(1).decode(), k


def ikconfig(image):
    i = image.find(b"IKCFG_ST")
    j = image.find(b"IKCFG_ED", i)
    if i < 0 or j < 0:
        return set()
    return {l for l in gzip.decompress(image[i + 8:j]).decode().splitlines() if "CONFIG_" in l}


def avb_footer(data):
    f = data[-64:]
    if f[:4] != b"AVBf":
        die("no AVB footer")
    _, _, _, orig, voff, vsize = struct.unpack(">4sIIQQQ", f[:36])
    return orig, voff, vsize


def build_boot(new_img, base_img, dest):
    """Google's certified content with the phone's own vbmeta blob, copied verbatim.

    The blob (Xiaomi-signed, props incl. com.android.build.boot.security_patch) no longer
    matches the content. That is what magiskboot does to a patched image, and what the
    phone's Magisk init_boot_a already boots with: vbmeta_a is flags=2, nothing verifies
    it, and whatever the bootloader reads from the footer stays byte-identical.
    """
    new, base = read(new_img), read(base_img)
    n_orig, _, _ = avb_footer(new)
    _, b_voff, b_vsize = avb_footer(base)
    blob = base[b_voff:b_voff + b_vsize]
    if blob[:4] != b"AVB0":
        die("the phone's boot_a has no vbmeta blob where its footer points")
    voff = (n_orig + 4095) // 4096 * 4096
    size = len(base)
    if voff + b_vsize > size - 64:
        die("new boot image does not fit boot_a")
    img = bytearray(size)
    img[:n_orig] = new[:n_orig]
    img[voff:voff + b_vsize] = blob
    foot = bytearray(base[-64:])
    foot[12:36] = struct.pack(">QQQ", n_orig, voff, b_vsize)
    img[-64:] = foot
    write(dest, img)
    props = re.findall(rb"com\.android\.build\.boot\.security_patch\x00?([0-9-]{10})", blob)
    return props[0].decode() if props else "?"


# ---- kernel modules (ELF64 little-endian, relocatable) ----

def elf_sections(data):
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise ValueError("not an ELF64 LE file")
    shoff = struct.unpack_from("<Q", data, 0x28)[0]
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x3A)
    secs = []
    for i in range(shnum):
        name, typ, _, _, off, size, link, _, _, _ = struct.unpack_from("<IIQQQQIIQQ", data, shoff + i * shentsize)
        secs.append({"name": name, "type": typ, "off": off, "size": size, "link": link})
    strtab = secs[shstrndx]["off"]
    for s in secs:
        s["name"] = data[strtab + s["name"]:data.index(b"\0", strtab + s["name"])].decode()
    return secs


def versions(data):
    """__versions: {unsigned long crc; char name[56]} per symbol on 64-bit (6.12)."""
    s = next((x for x in elf_sections(data) if x["name"] == "__versions"), None)
    if not s:
        return {}
    res = {}
    for o in range(s["off"], s["off"] + s["size"], 64):
        crc = struct.unpack_from("<Q", data, o)[0] & 0xFFFFFFFF
        name = data[o + 8:o + 64].split(b"\0")[0].decode()
        if not name:
            raise ValueError("empty symbol name in __versions: record layout not understood")
        res[name] = crc
    return res


def exported_crcs(data):
    """A module's export CRCs: each __crc_<sym> label points at a u32 in __kcrctab."""
    secs = elf_sections(data)
    symtab = next((s for s in secs if s["type"] == 2), None)
    if not symtab:
        return {}
    strs = secs[symtab["link"]]["off"]
    res = {}
    for o in range(symtab["off"], symtab["off"] + symtab["size"], 24):
        st_name, _, _, shndx, value, _ = struct.unpack_from("<IBBHQQ", data, o)
        name = data[strs + st_name:data.index(b"\0", strs + st_name)]
        if not name.startswith(b"__crc_"):
            continue
        if shndx == 0xFFF1:  # SHN_ABS: the value is the CRC
            crc = value & 0xFFFFFFFF
        else:
            crc = struct.unpack_from("<I", data, secs[shndx]["off"] + value)[0]
        res[name[6:].decode()] = crc
    return res


def signer(data):
    """Serial of the key that signed a module, or None when unsigned."""
    if not data.endswith(SIG_MAGIC):
        return None
    siglen = struct.unpack(">I", data[-len(SIG_MAGIC) - 4:-len(SIG_MAGIC)])[0]
    sig = data[-len(SIG_MAGIC) - 12 - siglen:-len(SIG_MAGIC) - 12]
    p = subprocess.run(["openssl", "cms", "-inform", "DER", "-cmsout", "-print"],
                       input=sig, capture_output=True)
    m = re.search(rb"serialNumber:\s*(\S+)", p.stdout)
    return m.group(1).decode() if m else "unparsed"


def symvers(path):
    res = {}
    for line in open(path):
        f = line.split("\t")
        if len(f) >= 2:
            res[f[1]] = int(f[0], 16)
    return res


def check_imports(vendor, exports):
    """Every vendor-module import with a recorded CRC, checked against the GKI exports."""
    n, bad, unresolved = 0, [], set()
    for path in vendor:
        for sym, crc in versions(read(path)).items():
            n += 1
            if sym not in exports:
                unresolved.add(sym)
            elif exports[sym] != crc:
                bad.append(f"{os.path.basename(path)}:{sym}")
    return n, bad, unresolved


# ---- vendor_boot ramdisk (newc cpio) ----

def cpio_files(data, prefix):
    o, res = 0, {}
    while True:
        h = data[o:o + 110]
        if h[:6] != b"070701":
            die("vendor ramdisk is not a newc cpio")
        f = [int(h[6 + 8 * i:14 + 8 * i], 16) for i in range(13)]
        namesize, filesize, mode = f[11], f[6], f[1]
        name = data[o + 110:o + 110 + namesize - 1].decode()
        doff = (o + 110 + namesize + 3) & ~3
        if name == "TRAILER!!!":
            return res
        if name.startswith(prefix) and mode & 0o170000 == 0o100000:
            res[name] = data[doff:doff + filesize]
        o = (doff + filesize + 3) & ~3


def vendor_boot_modules(img, work):
    d = os.path.join(work, "vendor_boot")
    shutil.rmtree(d, ignore_errors=True)
    run([tool("unpack_bootimg"), "--boot_img", img, "--out", d], capture_output=True)
    mods, lists = {}, {}
    for frag in sorted(os.listdir(d)):
        if not frag.startswith("vendor_ramdisk") or not frag[-2:].isdigit():
            continue
        raw = read(os.path.join(d, frag))
        if raw[:4] == b"\x02\x21\x4c\x18":
            raw = out([tool("lz4"), "-dc", os.path.join(d, frag)])
        elif raw[:2] == b"\x1f\x8b":
            raw = gzip.decompress(raw)
        for name, body in cpio_files(raw, "lib/modules/").items():
            base = os.path.basename(name)
            if base.endswith(".ko"):
                p = os.path.join(d, "ko", base)
                os.makedirs(os.path.dirname(p), exist_ok=True)
                write(p, body)
                mods[base] = p
            elif base.startswith("modules.load"):
                lists[f"vendor_boot {frag} {base}"] = body.decode().split()
    return mods, lists


# ---- system_dlkm ----

def avb_info(img):
    info = out([tool("avbtool"), "info_image", "--image", img]).decode()
    get = lambda k: re.search(rf"{k}:\s*(\S+)", info).group(1)
    props = re.findall(r"Prop: (\S+) -> '(.*)'", info)
    return {"salt": get("Salt"), "roots": get("FEC num roots"), "name": get("Partition Name"),
            "orig": int(get("Original image size")), "props": props}


def erofs_uuid(img):
    s = out([tool("dump.erofs"), "-s", img]).decode()
    return re.search(r"Filesystem UUID:\s*(\S+)", s).group(1)


def depmod(ko_dir, names, work):
    """What build/make/core/Makefile does for a module partition, reproduced."""
    stage = os.path.join(work, "depmod")
    shutil.rmtree(stage, ignore_errors=True)
    m = os.path.join(stage, "lib/modules/0.0/system_dlkm/lib/modules")
    os.makedirs(m)
    for n in names:
        shutil.copy2(os.path.join(ko_dir, n), m)
    run([shutil.which("depmod") or "/usr/sbin/depmod", "-b", stage, "0.0"], stderr=DEVNULL)
    res = {}
    for f in ("modules.dep", "modules.alias", "modules.softdep"):
        t = open(os.path.join(stage, "lib/modules/0.0", f)).read()
        if f == "modules.dep":
            t = re.sub(r"([^: \n]*lib/modules/[^: \n]*)", r"/\1", t)
        res[f] = t
    return res


def mkfs_dlkm(tree, dest, uuid, part_size, avb, work):
    fc = os.path.join(work, "system_dlkm_file_contexts")
    write(fc, DLKM_FC.encode())
    if os.path.exists(dest):
        os.remove(dest)
    run([tool("mkfs.erofs")] + EROFS + [f"--file-contexts={fc}", "-U", uuid, dest, tree],
        capture_output=True)
    cmd = [tool("avbtool"), "add_hashtree_footer", "--image", dest, "--partition_size", str(part_size),
           "--partition_name", avb["name"], "--hash_algorithm", "sha256", "--algorithm", "NONE",
           "--salt", avb["salt"], "--fec_num_roots", avb["roots"]]
    for k, v in avb["props"]:
        cmd += ["--prop", f"{k}:{v}"]
    run(cmd, env=dict(os.environ, PATH=HOST + ":" + os.environ["PATH"]), capture_output=True)


def same_except_avbtool_version(a, b):
    """True when two footered images differ only in the vbmeta release string."""
    if len(a) != len(b):
        return False
    _, voff, _ = avb_footer(a)
    lo, hi = voff + 128, voff + 176  # AvbVBMetaImageHeader.release_string[48]
    return a[:lo] == b[:lo] and a[hi:] == b[hi:]


# ---- commands ----

def cmd_list():
    rel = releases()
    line_of = lambda tag: tag[len(BRANCH) + 1:len(BRANCH) + 8]  # "2025-09"
    newest = lambda: sorted(rel.items(), key=lambda kv: (kv[1][0], kv[1][1]), reverse=True)
    cur = parse_krel(dev("uname -r").decode().strip()) if adb_state() in ("device", "recovery") else None
    cur_tag = next((t for t, (_, b) in newest() if cur and b == cur["bid"]), None)
    if cur_tag:
        line = line_of(cur_tag)
        print(f"phone: {cur_tag} (ab{cur['bid']}, KMI generation {cur['gen']})\n"
              f"its release line, {line} (only these are drop-in):")
        mine = [(t, d, b) for t, (d, b) in newest() if line_of(t) == line]
        for t, d, b in mine[:6]:
            mark = "  <- phone" if b == cur["bid"] else "  NEWER: candidate" if b > cur["bid"] else ""
            print(f"  {d}  {t[len(BRANCH) + 1:]:12} ab{b}{mark}")
        if not any(b > cur["bid"] for _, _, b in mine):
            print("  nothing newer on this line")
    elif cur:
        print(f"phone: ab{cur['bid']} (KMI generation {cur['gen']}) is not on {PAGE}")
    seen = set()
    print("other release lines, newest of each (a later line is normally a later KMI generation;"
          "\n`build <tag> --check-only` proves it either way):")
    for t, (d, b) in newest():
        if line_of(t) not in seen and not (cur_tag and line_of(t) == line_of(cur_tag)):
            seen.add(line_of(t))
            print(f"  {d}  {t[len(BRANCH) + 1:]:12} ab{b}")


def cmd_build(tag, allow_older=False):
    tag = tag if tag.startswith(BRANCH) else f"{BRANCH}-{tag}"
    short = tag[len(BRANCH) + 1:]
    outdir = os.path.join(GKI, "builds", short)
    work = os.path.join(GKI, "work", short)
    if os.path.exists(outdir) and not CHECK_ONLY:
        die(f"{outdir} exists; move it away to rebuild")
    if adb_state() != "device":
        die("boot the phone into Android with adb connected (build reads the live partitions)")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    rel = releases()
    if tag not in rel:
        die(f"{tag} is not on {PAGE}")
    date, bid = rel[tag]
    print(f"== {tag} ({date}, ab{bid})")

    # new kernel
    z = fetch(ZIP.format(tag=tag), os.path.join(GKI, "dl", os.path.basename(ZIP.format(tag=tag))))
    run(["unzip", "-o", "-q", z, "boot-6.12-lz4.img", "-d", work])
    new_boot = os.path.join(work, "boot-6.12-lz4.img")
    new_krel, new_image = unpack_kernel(new_boot, work)
    new = parse_krel(new_krel)

    # the phone as it is now
    ph = os.path.join(work, "phone")
    os.makedirs(ph)
    base_krel = dev("uname -r").decode().strip()
    base = parse_krel(base_krel)
    print(f"   phone {base_krel}\n   new   {new_krel}")
    if new["bid"] != bid:
        die(f"the certified image is ab{new['bid']}, the page says ab{bid}")
    if new["gen"] != base["gen"]:
        fail(f"KMI generation {new['gen']} != the phone's {base['gen']}: Xiaomi's vendor modules "
            "would not load. Only releases of the phone's own line are drop-in.")
    if new["bid"] < base["bid"] and not allow_older:
        fail("that release is older than the phone's kernel (use the saved rollback instead)")
    if new["bid"] == base["bid"]:
        print("   (same build as the phone: this run only proves the recipe)")
    boot_a = pull("cat /dev/block/by-name/boot_a", os.path.join(ph, "boot_a.img"))
    dlkm_a = pull("cat /dev/block/mapper/system_dlkm_a", os.path.join(ph, "system_dlkm_a.img"))
    vboot = pull("cat /dev/block/by-name/vendor_boot_a", os.path.join(ph, "vendor_boot_a.img"))
    dlkm_size = int(dev("blockdev --getsize64 /dev/block/mapper/system_dlkm_a").decode())
    k, base_image = unpack_kernel(boot_a, work)
    if k != base_krel:
        die(f"boot_a holds {k}, but the running kernel is {base_krel}")
    vd = os.path.join(ph, "vendor_dlkm")
    os.makedirs(vd)
    write(os.path.join(work, "vendor_dlkm.tar"), dev("tar -cf - -C /vendor_dlkm/lib/modules ."))
    run(["tar", "-xf", os.path.join(work, "vendor_dlkm.tar"), "-C", vd])
    vb_mods, lists = vendor_boot_modules(vboot, work)
    vendor = sorted(vb_mods.values()) + sorted(glob_ko(vd))
    lists["vendor_dlkm modules.load"] = open(os.path.join(vd, "modules.load")).read().split()
    print(f"   vendor modules: {len(vb_mods)} in vendor_boot, {len(vendor) - len(vb_mods)} in vendor_dlkm")

    # 1. the recipe still reproduces the phone's system_dlkm
    base_tree = os.path.join(work, "system_dlkm.base")
    run([tool("fsck.erofs"), f"--extract={base_tree}", dlkm_a], capture_output=True)
    bmods = os.path.join(base_tree, "lib/modules")
    base_names = sorted(n for n in os.listdir(bmods) if n.endswith(".ko"))
    avb = avb_info(dlkm_a)
    uuid = erofs_uuid(dlkm_a)
    meta = depmod(bmods, base_names, work)
    for f, t in meta.items():
        if open(os.path.join(bmods, f)).read() != t:
            die(f"depmod no longer reproduces the phone's {f}")
    probe = os.path.join(work, "system_dlkm.reproduced.img")
    mkfs_dlkm(base_tree, probe, uuid, dlkm_size, avb, work)
    if not same_except_avbtool_version(read(probe), read(dlkm_a)):
        die("mkfs.erofs/avbtool no longer reproduce the phone's system_dlkm; the recipe needs rework")
    print("OK  recipe reproduces the phone's system_dlkm_a byte for byte")

    # 2. new modules
    ci = os.path.join(GKI, "ci", str(bid))
    fetch(CI.format(bid=bid, name="vmlinux.symvers"), os.path.join(ci, "vmlinux.symvers"))
    arch = fetch(CI.format(bid=bid, name="system_dlkm_staging_archive.tar.gz"),
                 os.path.join(ci, "system_dlkm_staging_archive.tar.gz"))
    bci = os.path.join(GKI, "ci", str(base["bid"]))
    fetch(CI.format(bid=base["bid"], name="vmlinux.symvers"), os.path.join(bci, "vmlinux.symvers"))
    stage = os.path.join(work, "staging")
    os.makedirs(stage)
    run(["tar", "-xzf", arch, "-C", stage, "./flatten/lib/modules"])
    nmods = os.path.join(stage, "flatten/lib/modules")
    new_names = set(n for n in os.listdir(nmods) if n.endswith(".ko"))
    keep = [n for n in base_names if n in new_names]
    dropped = [n for n in base_names if n not in new_names]
    added = sorted(new_names - set(base_names))
    for n in keep:
        if parse_krel(re.search(rb"vermagic=([^\s\0]+)", read(os.path.join(nmods, n))).group(1).decode())["bid"] != bid:
            die(f"{n} in the staging archive is not from ab{bid}")
    print(f"OK  {len(keep)} of the phone's {len(base_names)} system_dlkm modules exist in the new build")
    if dropped:
        print(f"    dropped by Google, left out: {' '.join(dropped)}")
    if added:
        other = [n for n in added if "test" not in n and "kunit" not in n]
        print(f"    {len(added)} modules of Google's build are not in Xiaomi's selection and stay out"
              + (f" ({len(added) - len(other)} are tests): {' '.join(other)}" if other else ""))

    # 3. vendor imports against the old and the new exports
    def exports(sv, mdir, names):
        e = symvers(sv)
        for n in names:
            e.update(exported_crcs(read(os.path.join(mdir, n))))
        return e
    n0, bad0, unres0 = check_imports(vendor, exports(os.path.join(bci, "vmlinux.symvers"), bmods, base_names))
    n1, bad1, unres1 = check_imports(vendor, exports(os.path.join(ci, "vmlinux.symvers"), nmods, keep))
    if n0 < 10000 or bad0:
        die(f"control failed: {n0} imports, {len(bad0)} mismatches against the RUNNING kernel. "
            "The phone loads these modules today, so this is a bug in the check, not the release.")
    lost = sorted(unres1 - unres0)
    if bad1 or lost:
        fail(f"{len(bad1)} CRC mismatches in {len(set(b.split(':')[0] for b in bad1))} vendor "
             f"modules, {len(lost)} symbols no longer exported, e.g. {(bad1 + lost)[:6]}")
    else:
        print(f"OK  {n1} vendor-module imports: 0 CRC mismatches (control on the running kernel: 0), "
          f"none lost; {len(unres1)} vendor-to-vendor symbols not checked here")

    # 4. vendor modules signed with the running GKI key become unsigned under the new kernel
    gki_key = signer(read(os.path.join(bmods, base_names[0])))
    problems = []
    for name, lst in lists.items():
        for m in lst:
            p = vb_mods.get(m) if name.startswith("vendor_boot") else os.path.join(vd, m)
            if p and os.path.exists(p) and signer(read(p)) == gki_key:
                problems.append(f"{m} ({name})")
    if any("vendor_boot" in p for p in problems):
        fail(f"GKI-signed modules in a first-stage list; first-stage init would FATAL: {problems}. "
            "Trim them from vendor_boot first (docs/UPDATING.md, 'Updating the kernel').")
    for p in problems:
        print(f"WARN {p} is signed with the running GKI key and will not load (second stage)")
    if not any("vendor_boot" in p for p in problems):
        print("OK  no first-stage module list names a module signed with the running GKI key")

    # 5. what else changed
    oc, nc = ikconfig(base_image), ikconfig(new_image)
    diff = sorted(("- " + l) for l in oc - nc) + sorted(("+ " + l) for l in nc - oc)
    print(f"    kernel config: {len(diff)} changed line(s)" + "".join("\n      " + d for d in diff[:40]))

    if CHECK_ONLY:
        print(f"\n{len(FAILS)} check(s) failed" if FAILS else "\nall checks pass; nothing was built")
        sys.exit(1 if FAILS else 0)

    # 6. build
    os.makedirs(os.path.join(outdir, "rollback"))
    tree = os.path.join(work, "system_dlkm.new")
    shutil.copytree(base_tree, tree)
    tmods = os.path.join(tree, "lib/modules")
    for n in base_names:
        os.remove(os.path.join(tmods, n))
    for n in keep:
        shutil.copy2(os.path.join(nmods, n), tmods)
    for f, t in depmod(tmods, keep, work).items():
        write(os.path.join(tmods, f), t.encode())
    load = [m for m in open(os.path.join(bmods, "modules.load")).read().split() if m in keep]
    write(os.path.join(tmods, "modules.load"), ("\n".join(load) + "\n").encode())
    mkfs_dlkm(tree, os.path.join(outdir, "system_dlkm_a.img"), uuid, dlkm_size, avb, work)
    spl = build_boot(new_boot, boot_a, os.path.join(outdir, "boot_a.img"))
    k, _ = unpack_kernel(os.path.join(outdir, "boot_a.img"), work)
    if k != new_krel:
        die("the assembled boot_a does not carry the new kernel")
    shutil.copy2(boot_a, os.path.join(outdir, "rollback", "boot_a.img"))
    shutil.copy2(dlkm_a, os.path.join(outdir, "rollback", "system_dlkm_a.img"))
    files = ["boot_a.img", "system_dlkm_a.img", "rollback/boot_a.img", "rollback/system_dlkm_a.img"]
    write(os.path.join(outdir, "SHA256SUMS"),
          "".join(f"{sha256(os.path.join(outdir, f))}  {f}\n" for f in files).encode())
    readme = f"""{tag} ({date}, ab{bid}) for warhol, built {time.strftime('%Y-%m-%d', time.gmtime())}
new kernel:      {new_krel}
replaces:        {base_krel}
boot patch level kept at {spl} (the phone's own vbmeta blob, verbatim)
system_dlkm:     {len(keep)} modules{'; dropped: ' + ' '.join(dropped) if dropped else ''}

1. Phone into fastboot with the key combo, then:
     fastboot flash boot_a {outdir}/boot_a.img
2. Key combo into TWRP. It runs on the new kernel, so it coming up is the first test. Then:
     python3 {os.path.abspath(__file__)} write-dlkm {outdir}
3. adb reboot, unlock with the PIN, then:
     bash {os.path.join(os.path.dirname(os.path.abspath(__file__)), 'postflash_check.sh')}
Rollback: fastboot flash boot_a {outdir}/rollback/boot_a.img, then key combo into TWRP and
          python3 {os.path.abspath(__file__)} write-dlkm {outdir} --rollback
"""
    write(os.path.join(outdir, "README.txt"), readme.encode())
    print("\n" + open(os.path.join(outdir, "SHA256SUMS")).read() + "\n" + readme)


def glob_ko(d):
    return [os.path.join(d, n) for n in os.listdir(d) if n.endswith(".ko")]


def cmd_write_dlkm(d, rollback=False):
    """system_dlkm must carry the modules of the kernel in boot_a: both from one directory."""
    sub = "rollback/" if rollback else ""
    img = os.path.join(d, sub + "system_dlkm_a.img")
    sums = {l.split()[1]: l.split()[0] for l in open(os.path.join(d, "SHA256SUMS")) if l.strip()}
    for f in (sub + "boot_a.img", sub + "system_dlkm_a.img"):
        if sha256(os.path.join(d, f)) != sums[f]:
            die(f"{f} does not match SHA256SUMS")
    if adb_state() != "recovery":
        die("the phone is not in TWRP")
    readme = open(os.path.join(d, "README.txt")).read()
    want = re.search(r"replaces:\s+(\S+)" if rollback else r"new kernel:\s+(\S+)", readme).group(1)
    if dev("getprop ro.boot.slot_suffix").decode().strip() != "_a":
        die("current slot is not _a")
    if dev("uname -r").decode().strip() != want:
        die(f"TWRP is not running {want}: flash {sub}boot_a.img from fastboot first, then enter TWRP")
    if dev("sha256sum /dev/block/by-name/boot_a").split()[0].decode() != sums[sub + "boot_a.img"]:
        die(f"boot_a on the phone is not {sub}boot_a.img from {d}")
    node = "/dev/block/mapper/system_dlkm_a"
    if dev("grep -c system_dlkm /proc/mounts || true").decode().strip() not in ("", "0"):
        die("system_dlkm is mounted")
    size = os.path.getsize(img)
    if int(dev(f"blockdev --getsize64 {node}").decode()) != size:
        die("partition size differs from the image")
    if dev(f"blockdev --getro {node}").decode().strip() != "0":
        die(f"{node} is read-only")
    run(["adb", "push", img, "/tmp/system_dlkm_a.img"], capture_output=True)
    if dev("sha256sum /tmp/system_dlkm_a.img").split()[0].decode() != sums[sub + "system_dlkm_a.img"]:
        die("the copy pushed to the phone is corrupt")
    print(f"writing system_dlkm_a: {size} bytes -> {node}")
    dev(f"dd if=/tmp/system_dlkm_a.img of={node} bs=1M conv=fsync; sync; "
        "echo 3 > /proc/sys/vm/drop_caches; rm /tmp/system_dlkm_a.img")
    got = dev(f"sha256sum {node}").split()[0].decode()
    if got != sums[sub + "system_dlkm_a.img"]:
        print(f"MISMATCH: device {got}; run this again before rebooting"
              + ("" if rollback else ", or roll back (docs/UPDATING.md)"))
        sys.exit(2)
    print(f"VERIFIED system_dlkm_a {got[:16]}")
    n = dev(f"mkdir -p /tmp/gki_sdt && mount -t erofs -o ro {node} /tmp/gki_sdt && "
            "ls /tmp/gki_sdt/lib/modules | grep -c ko$; umount /tmp/gki_sdt").decode().split()
    print(f"    mounts, {n[0] if n else '?'} modules")
    bcb = dev("dd if=/dev/block/by-name/misc bs=32 count=1 2>/dev/null")
    print("    misc is clear: `adb reboot` goes to Android" if not bcb.strip(b"\0") else
          f"    misc holds {bcb.strip(bytes(1))!r}: the next boot lands in TWRP again "
          "(docs/UPDATING.md, Troubleshooting)")


def main():
    a = sys.argv[1:]
    if a[:1] == ["list"]:
        cmd_list()
    elif a[:1] == ["build"] and len(a) >= 2:
        global CHECK_ONLY
        CHECK_ONLY = "--check-only" in a
        cmd_build(a[1], allow_older="--allow-older" in a)
    elif a[:1] == ["write-dlkm"] and len(a) >= 2:
        cmd_write_dlkm(a[1], rollback="--rollback" in a)
    else:
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
