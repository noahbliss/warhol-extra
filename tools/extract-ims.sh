#!/usr/bin/env bash
# =============================================================================
# extract-ims.sh — pull MediaTek's IMS stack out of a stock firmware package and
#                  lay it out as vendor/xiaomi/warhol/ prebuilts.
#
#     ./tools/extract-ims.sh /path/to/warhol_global_images_OS3.0.x_16.0 [outdir]
#
# WHY: warhol uses VoLTE/VoWiFi, and MediaTek's IMS implementation lives on
# system_ext -- a partition this build replaces. See docs/TELEPHONY.md for the
# full analysis and for why this is expected to work at all (short version: the
# jars are built against AOSP telephony internals, and AOSP's own
# TelephonyComponentFactory has an injection hook that LineageOS's com.android.phone
# already calls).
#
# WHY NOT COMMITTED BINARIES: everything this produces is proprietary MediaTek and
# Xiaomi code. It is not ours to redistribute. The output directory is gitignored;
# regenerate it locally from firmware for your own device.
#
# Get firmware matching the build you intend to run. Mixing IMS jars from one
# release with a vendor partition from another is not expected to work.
# =============================================================================
set -euo pipefail

FW="${1:-}"
[ -n "$FW" ] && [ -d "$FW/images" ] || { sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${2:-$ROOT/../vendor/xiaomi/warhol}"
TOOLS="$ROOT/tools"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

command -v python3   >/dev/null || { echo "ERROR: python3 not installed" >&2; exit 1; }
command -v fsck.erofs >/dev/null || { echo "ERROR: erofs-utils not installed (brew install erofs-utils)" >&2; exit 1; }

# ── The component set ────────────────────────────────────────────────────────
# Boot jars. These eight are on the stock BOOTCLASSPATH and must also land in our
# PRODUCT_BOOT_JARS, otherwise the classes exist on disk and nothing can load them.
# NOTE: mediatek-framework is deliberately ABSENT, though stock has it on
# BOOTCLASSPATH. It carries com.mediatek.aee.ExceptionLogImpl, whose superclass
# com.mediatek.aee.ExceptionLog is defined in MediaTek's PATCHED framework.jar /
# services.jar -- files we replace with AOSP's. hiddenapi walks the class
# hierarchy of every boot jar and aborts the build on the dangling reference:
#
#   hiddenapi: Superclass/interface Lcom/mediatek/aee/ExceptionLog; of class
#   Lcom/mediatek/aee/ExceptionLogImpl; from mediatek-framework.jar was not found
#
# Verified no shippable jar defines that class, so it cannot be satisfied. It is
# also not needed: mediatek-framework defines boostfwk, networkpolicymanager,
# view, gnssdebugreport and location classes, and NONE of the seven IMS jars nor
# any of ImsService/MtkTelephonyAssist/MtkGbaService reference any of them.
# Checked, not assumed. If something later turns out to need it, the fix is a stub
# providing com.mediatek.aee.ExceptionLog, not shipping the jar as-is.
BOOT_JARS=(
    mediatek-common
    mediatek-telephony-base
    mediatek-telephony-common
    mediatek-telecom-common
    mediatek-ims-base
    mediatek-ims-common
    mediatek-carrier-config-manager
)
# Not boot jars, but part of the stack.
PLAIN_JARS=( mediatek-services mediatek-ims-extension-plugin )

# APKs. mediatek-res is the shared resource package (android package "com.mediatek")
# that the others resolve resources against; without it they fail at inflate time.
APPS=( "app/mediatek-res/mediatek-res.apk" )
PRIV_APPS=(
    "priv-app/ImsService/ImsService.apk"
    "priv-app/MtkTelephonyAssist/MtkTelephonyAssist.apk"
    "priv-app/MtkGbaService/MtkGbaService.apk"
)

# Native libs: the transitive DT_NEEDED closure, restricted to system_ext.
#
# The seed set is not guesswork. It is libimsma* (the media path, which only loads
# during an actual call) UNION the MediaTek libraries the live com.mediatek.ims
# process actually has mapped at idle, read from /proc/<pid>/maps on the device.
# Static analysis alone missed video telephony and the MMS HAL entirely; the
# runtime map alone missed the call-path media stack. Both were needed.
#
# One trap worth recording: diffing the IMS process's maps against another app's
# is NOT a valid way to trim this. Libraries loaded by both are still real IMS
# dependencies -- they merely happen to be MIUI zygote preloads too, and on
# LineageOS nothing else would provide them.
#
# Everything outside system_ext (libbinder, libgui, libstagefright, libmedia_omx,
# libion, ...) comes from our own build; all of it was verified present in the
# built output, except libhidltransport, which device.mk adds to PRODUCT_PACKAGES.
LIBS=(
    libcomutils.so libimsma.so libimsma_adapt.so libimsma_rtp.so
    libimsma_socketwrapper.so libsignal.so libsink.so libsource.so
    libvcodec_cap.so libvcodec_capenc.so libvt_avsync.so
    libaudioutilmtk.so libmtk_vt_wrapper.so libxlog.so
    vendor.mediatek.hardware.mms@1.0.so vendor.mediatek.hardware.mms@1.1.so
    vendor.mediatek.hardware.mms@1.2.so vendor.mediatek.hardware.mms@1.3.so
    vendor.mediatek.hardware.videotelephony-V1-ndk.so
    vendor.mediatek.hardware.videotelephony@1.0.so
    vendor.xiaomi.hardware.mediaeventgatherservice-V1-ndk.so
)

ETC=(
    "etc/sysconfig/com.mediatek.ims.config.xml"
    "etc/permissions/system-ext-permissions-mediatek.xml"
)

echo "=== unpacking super.img ==="
python3 "$TOOLS/simg2img.py" "$FW/images/super.img" "$WORK/super.raw" >/dev/null
python3 "$TOOLS/lpunpack.py" "$WORK/super.raw" "$WORK/parts" system_ext_a >/dev/null
rm -f "$WORK/super.raw"
fsck.erofs --extract="$WORK/se" --no-preserve --overwrite "$WORK/parts/system_ext_a.img" >/dev/null 2>&1
rm -rf "$WORK/parts"

P="$OUT/proprietary/system_ext"
rm -rf "$OUT/proprietary"
mkdir -p "$P/framework" "$P/lib64" "$P/etc/sysconfig" "$P/etc/permissions" \
         "$P/app/mediatek-res" "$P/priv-app"

copy() {  # copy <relative path under system_ext>
    local src="$WORK/se/$1" dst="$P/$1"
    [ -f "$src" ] || { echo "  !! MISSING $1" >&2; return 1; }
    mkdir -p "$(dirname "$dst")"; cp "$src" "$dst"; echo "  $1"
}

echo "=== jars ==="
for j in "${BOOT_JARS[@]}" "${PLAIN_JARS[@]}"; do copy "framework/$j.jar"; done
echo "=== apps ==="
for a in "${APPS[@]}" "${PRIV_APPS[@]}"; do copy "$a"; done
echo "=== native ==="
for l in "${LIBS[@]}"; do copy "lib64/$l"; done
echo "=== etc ==="
for e in "${ETC[@]}"; do copy "$e"; done

# ── Generate the soong + make glue ───────────────────────────────────────────
echo "=== generating Android.bp / warhol-vendor.mk ==="
python3 - "$OUT" "${BOOT_JARS[*]}" "${PLAIN_JARS[*]}" "${LIBS[*]}" <<'PYEOF'
import os, sys
out, boot_jars, plain_jars, libs = sys.argv[1], sys.argv[2].split(), sys.argv[3].split(), sys.argv[4].split()
NL = chr(10)

bp = ["// Generated by tools/extract-ims.sh -- do not edit by hand.",
      "// Proprietary MediaTek IMS stack, extracted from stock firmware.",
      "//",
      "// This lives in its own Soong namespace on purpose. hardware/mediatek defines a",
      "// module ALSO called \"mediatek-common\" (a one-class stub), and Soong parses every",
      "// Android.bp in the tree and rejects duplicate module names -- whether or not both",
      "// are reachable from the product. The namespace lets ours coexist. It only works",
      "// if warhol-vendor.mk\'s PRODUCT_SOONG_NAMESPACES entry is in effect.",
      "", 'soong_namespace {', '}', ""]

# dex_import, NOT java_import. These jars came off a device build and contain
# classes.dex with no .class files at all (verified: all ten). java_import expects
# Java bytecode it can dex itself, so a boot classpath entry backed by one fails:
#
#   error: frameworks/base/boot/Android.bp: module "platform-bootclasspath":
#          module mediatek-common{os:android,arch:common} does not provide a dex jar
#
# dex_import is documented as "imports a .jar file containing classes.dex files"
# and embeds dexpreopter, which is what a boot jar needs.
for j in boot_jars + plain_jars:
    bp += [
        "dex_import {",
        '    name: "%s",' % j,
        '    jars: ["proprietary/system_ext/framework/%s.jar"],' % j,
        "    system_ext_specific: true,",
        # Putting these on PRODUCT_BOOT_JARS makes them dependencies of
        # platform-bootclasspath, which lands them in the dependency graph of
        # aosp_shared_system_image -- a GSI target we neither build nor ship:
        #   error: module "aosp_shared_system_image": includes non-generic modules:
        #          "prebuilt_mediatek-common" from "platform-bootclasspath"
        # build/soong/filesystem/filesystem.go exempts modules whose
        # UseGenericConfig() is true. For a pure prebuilt that is simply accurate:
        # the module is a file, its build actions do not vary by device, and it
        # never calls DeviceName() or DeviceProduct().
        "    use_generic_config: true,",
        "}", "",
    ]

# Module names get a _warhol suffix, with stem restoring the real filename.
# Soong pairs a prebuilt to a source module BY NAME and then casts, so a collision
# with an unrelated module of the same name is a panic, not an error:
#   libsink (ours, cc) vs libsink (a Rust crate in external/rust/beto-rust):
#   internal error: ... interface conversion: android.Module is *rust.Module,
#   not *cc.Module
# Only libsink collides today, but this tree is re-synced monthly and any new
# AOSP module could take one of these names. The suffix makes that impossible;
# stem keeps the installed file, and therefore the SONAME match, unchanged.
for l in libs:
    bp += [
        "cc_prebuilt_library_shared {",
        '    name: "%s_warhol",' % l[:-3],
        '    stem: "%s",' % l[:-3],
        '    srcs: ["proprietary/system_ext/lib64/%s"],' % l,
        '    compile_multilib: "64",',
        "    system_ext_specific: true,",
        '    strip: { none: true },',
        '    check_elf_files: false,',
        # NO 'prefer: true' here. prefer only makes sense when a source module of
        # the same name exists; for a pure prebuilt it makes Soong's
        # prebuilt_select mutator panic on a nil dependency:
        #   internal error: panic in VisitDirectDeps(module "libsink" ...)
        #   for dependency <nil> in bottom up mutator "prebuilt_select"
        "}", "",
    ]

for name, path, priv in [
    ("MtkImsService", "priv-app/ImsService/ImsService.apk", True),
    ("MtkTelephonyAssist", "priv-app/MtkTelephonyAssist/MtkTelephonyAssist.apk", True),
    ("MtkGbaService", "priv-app/MtkGbaService/MtkGbaService.apk", True),
    ("mediatek-res", "app/mediatek-res/mediatek-res.apk", False),
]:
    bp += [
        "android_app_import {",
        '    name: "%s",' % name,
        '    apk: "proprietary/system_ext/%s",' % path,
        "    presigned: true,",
        # Required by build/soong/scripts/check_prebuilt_presigned_apk.py:
        #   Prebuilt, presigned apks with targetSdkVersion >= 30 (or a codename
        #   targetSdkVersion) must set preprocessed: true
        # It also stops Soong re-zipping the apk, which would break the existing
        # signature -- exactly what we want for a vendor-signed prebuilt.
        "    preprocessed: true,",
        "    dex_preopt: { enabled: false },",
    ]
    if priv: bp.append("    privileged: true,")
    bp += ["    system_ext_specific: true,", "}", ""]

open(os.path.join(out, "Android.bp"), "w").write(NL.join(bp) + NL)

mk = [
    "# Generated by tools/extract-ims.sh -- do not edit by hand.",
    "#",
    "# Inherit this from device.mk to add MediaTek's IMS stack. See docs/TELEPHONY.md.",
    "#",
    "# Do NOT inherit hardware/mediatek/frameworks/mediatek-frameworks.mk alongside this.",
    "# It builds its own one-class 'mediatek-common'; stock's is the superset and is what",
    "# the other MediaTek jars were compiled against.",
    "#",
    "# Soong parses every Android.bp in the tree and rejects duplicate module names, so",
    "# hardware/mediatek's 'mediatek-common' would collide with ours even unreferenced.",
    "# The prebuilts therefore sit in their own namespace, which must be registered:",
    "PRODUCT_SOONG_NAMESPACES += vendor/xiaomi/warhol",
    "",
    "PRODUCT_PACKAGES += \\",
]
pkgs = boot_jars + plain_jars + [l[:-3] + "_warhol" for l in libs] + \
       ["MtkImsService", "MtkTelephonyAssist", "MtkGbaService", "mediatek-res"]
mk += ["    %s \\" % p for p in pkgs[:-1]] + ["    %s" % pkgs[-1], ""]

mk += [
    "PRODUCT_COPY_FILES += \\",
    "    $(LOCAL_PATH)/proprietary/system_ext/etc/sysconfig/com.mediatek.ims.config.xml:$(TARGET_COPY_OUT_SYSTEM_EXT)/etc/sysconfig/com.mediatek.ims.config.xml \\",
    "    $(LOCAL_PATH)/proprietary/system_ext/etc/permissions/system-ext-permissions-mediatek.xml:$(TARGET_COPY_OUT_SYSTEM_EXT)/etc/permissions/system-ext-permissions-mediatek.xml",
    "",
    "# These eight are on the stock BOOTCLASSPATH. BOOTCLASSPATH is generated from",
    "# PRODUCT_BOOT_JARS into /system/etc/classpaths/bootclasspath.pb, a file we build,",
    "# so if they are not listed here nothing can load them no matter where they sit.",
    "#",
    "# UNVERIFIED: prebuilt jars on the boot classpath under ART's boot image is the",
    "# fiddly part of this whole exercise. If the build objects, that is where to look.",
    "PRODUCT_BOOT_JARS += \\",
]
# Entries MUST carry the "system_ext:" prefix. A bare name defaults to the
# platform partition, and the generated /system/etc/classpaths/bootclasspath.pb
# then points at /system/framework/<jar> while the jar actually installs to
# /system_ext/framework/<jar>. The build succeeds and IMS is silently dead,
# because ART cannot find the jars at the path BOOTCLASSPATH names.
# build/soong/java/dexpreopt_bootjars.go: "prefix system_ext: will use the
# /system_ext path".
mk += ["    system_ext:%s \\" % j for j in boot_jars[:-1]] + ["    system_ext:%s" % boot_jars[-1], ""]
open(os.path.join(out, "warhol-vendor.mk"), "w").write(NL.join(mk) + NL)
print("  wrote Android.bp and warhol-vendor.mk")
PYEOF

echo
echo "=== done ==="
echo "  $OUT"
du -sh "$OUT" 2>/dev/null || true
echo
echo "This is NOT wired into the build yet, deliberately. Get a booting build with"
echo "stock LineageOS telephony first, then add:"
echo "    \$(call inherit-product, vendor/xiaomi/warhol/warhol-vendor.mk)"
echo "plus the com.android.phone RRO described in docs/TELEPHONY.md."
