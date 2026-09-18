#!/usr/bin/env bash
# =============================================================================
# gapps-to-magisk.sh — repack a MindTheGapps recovery zip as a Magisk module.
#
#     ./tools/gapps-to-magisk.sh MindTheGapps-17.0.0-arm64-20260828_065753.zip
#     ./tools/gapps-to-magisk.sh <zip> out/MindTheGapps-magisk.zip
#
# WHY THIS EXISTS INSTEAD OF "just unzip the payload into a module":
#
# Baking GApps into the ROM means growing product from 768 MiB to ~2 GiB, which
# means rewriting warhol's super and flashing it from the bootloader. On a device
# that has already been bricked once that is the single riskiest operation in the
# plan, and it buys nothing: GApps file placement has no effect on any Play
# Integrity verdict (the verdicts turn on bootloader state, fingerprint and
# keybox attestation, none of which can see where Phonesky.apk lives). So we
# magic-mount instead. The module is ~776 MiB in /data, which is free.
#
# Three things stop a naive unzip from working, and this script fixes each:
#
#   1. THE APEX. Since Android 17 MindTheGapps ships GmsCore as a product APEX
#      (product/apex/com.google.android.gmssystem.prodvic.apex, 140 MiB) rather
#      than a priv-app. Magisk's magic mount skips apex paths entirely — verified
#      on warhol: with the apex in the module, /product/apex did not even exist
#      after boot and com.google.android.gms was simply absent. apexd also cannot
#      be handed a brand-new package at runtime; it only updates APEXes that were
#      preinstalled on the read-only image.
#      The fix: the apex payload is a plain EROFS image holding exactly
#      priv-app/PrebuiltGmsCoreVic@<ver>/PrebuiltGmsCoreVic.apk plus two XMLs
#      keyed on the ordinary package name com.google.android.gms. Unpack it and
#      lay those out as a normal product priv-app and they behave identically.
#
#   2. gapps.rc. The zip drops product/etc/init/gapps.rc to set two properties.
#      init parses every *.rc long before Magisk mounts anything, so a
#      module-supplied rc is never read. Emitted as system.prop instead, which
#      Magisk applies with resetprop in post-fs-data.
#
#   3. update-binary side effects. MindTheGapps' installer is otherwise a pure
#      file copy, but it deletes product/priv-app/VelvetTitan on everything that
#      is not a Pixel Tablet (396 MiB of dead weight), and builds an addon.d
#      script that only matters for surviving an OTA on a baked install.
#
# Requires fsck.erofs (erofs-utils) on the host to open the apex payload.
# =============================================================================
set -euo pipefail

ZIP="${1:-}"
[ -n "$ZIP" ] && [ -f "$ZIP" ] || { sed -n '3,44p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
ZIP="$(cd "$(dirname "$ZIP")" && pwd)/$(basename "$ZIP")"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${2:-$ROOT/out/$(basename "${ZIP%.zip}")-magisk.zip}"
mkdir -p "$(dirname "$OUT")"

WS="$(mktemp -d)"; trap 'rm -rf "$WS"' EXIT
M="$WS/module"

say() { printf '  %s\n' "$*"; }

# --- identify the package -----------------------------------------------------
unzip -o -q "$ZIP" build.prop -d "$WS" || { echo "ERROR: no build.prop — is this a MindTheGapps zip?" >&2; exit 1; }
ARCH=$(sed -n 's/^arch=//p'         "$WS/build.prop")
SDK=$(sed  -n 's/^version=//p'      "$WS/build.prop")
NICE=$(sed -n 's/^version_nice=//p' "$WS/build.prop")
STAMP=$(basename "${ZIP%.zip}"); STAMP="${STAMP##*-}"
[ "$ARCH" = "arm64" ] || { echo "ERROR: warhol is arm64, this package is $ARCH" >&2; exit 1; }
echo "MindTheGapps $NICE (SDK $SDK, $ARCH), build $STAMP"
echo "  sha256 $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo

# --- 3. the payload, minus what update-binary would have thrown away ----------
mkdir -p "$M"
unzip -q "$ZIP" 'system/*' -d "$M"
rm -rf "$M/system/product/priv-app/VelvetTitan"   # tangorpro-only; 396 MiB
rm -rf "$M/system/addon.d"                        # OTA survival, meaningless for a module
say "unpacked payload, dropped VelvetTitan and addon.d"

# --- 1. the apex ---------------------------------------------------------------
APEX=$(find "$M/system/product/apex" -name '*.apex' 2>/dev/null | head -1 || true)
if [ -n "$APEX" ]; then
    command -v fsck.erofs >/dev/null || { echo "ERROR: need fsck.erofs to open $(basename "$APEX")" >&2; exit 1; }
    A="$WS/apex"; mkdir -p "$A/payload"
    unzip -o -q "$APEX" apex_payload.img -d "$A"
    # apex payloads have been ext4 historically; refuse rather than guess
    magic=$(dd if="$A/apex_payload.img" bs=1 skip=1024 count=4 2>/dev/null | xxd -p)
    [ "$magic" = "e2e1f5e0" ] || { echo "ERROR: apex payload is not EROFS (magic $magic) — extend this script" >&2; exit 1; }
    fsck.erofs --extract="$A/payload" --overwrite "$A/apex_payload.img" >/dev/null

    # priv-app/<Name>@<version>/<Name>.apk  ->  product/priv-app/<Name>/<Name>.apk
    for d in "$A"/payload/priv-app/*/; do
        name="$(basename "$d")"; name="${name%%@*}"
        mkdir -p "$M/system/product/priv-app/$name"
        cp "$d"*.apk "$M/system/product/priv-app/$name/"
        say "apex -> product/priv-app/$name ($(du -h "$d"*.apk | cut -f1))"
    done
    # its allowlist and preinstall config are keyed on com.google.android.gms,
    # not on an apex path, so they work verbatim beside the apk
    for sub in permissions sysconfig; do
        [ -d "$A/payload/etc/$sub" ] || continue
        mkdir -p "$M/system/product/etc/$sub"
        cp "$A/payload/etc/$sub/"* "$M/system/product/etc/$sub/"
        say "apex -> product/etc/$sub/$(ls "$A/payload/etc/$sub" | tr '\n' ' ')"
    done

    rm -rf "$M/system/product/apex"
    # this only tells Play it may push apex updates through the vendor codepath,
    # which cannot work once the package is an ordinary apk
    rm -f "$M/system/product/etc/sysconfig/allowed_apex_"*.xml
    say "removed product/apex and its allowed_apex sysconfig"
else
    say "no apex in this package (pre-Android-17 layout)"
fi

# --- 2. gapps.rc -> system.prop ------------------------------------------------
RC="$M/system/product/etc/init/gapps.rc"
if [ -f "$RC" ]; then
    # -E: BSD sed's basic regex has no \+, and this script runs on the Mac too
    sed -nE 's/^[[:space:]]*setprop[[:space:]]+([^[:space:]]+)[[:space:]]+(.*)$/\1=\2/p' "$RC" > "$M/system.prop"
    rm -rf "$M/system/product/etc/init"
    say "gapps.rc -> system.prop: $(tr '\n' ' ' < "$M/system.prop")"
fi

# --- module metadata -----------------------------------------------------------
cat > "$M/module.prop" <<EOF
id=MindTheGapps
name=MindTheGapps $NICE $ARCH (systemless)
version=$STAMP
versionCode=$(echo "$STAMP" | tr -cd '0-9' | cut -c1-8)
author=MindTheGapps, repacked by tools/gapps-to-magisk.sh
description=Google apps for Android $NICE, magic-mounted instead of baked into product. GmsCore is lifted out of the GMS system APEX, which Magisk cannot mount, and shipped as an ordinary product priv-app.
EOF

# --- flashable zip -------------------------------------------------------------
# Magisk's own installer runs when META-INF/.../update-binary is the stock
# module_installer.sh; without it the module can still be installed by hand:
#   adb push <tar> /data/local/tmp && tar -xf ... -C /data/adb/modules/MindTheGapps
( cd "$M" && zip -qr1 "$OUT" . )
echo
echo "module payload : $(du -sh "$M" | cut -f1)"
echo "wrote          : $OUT ($(du -h "$OUT" | cut -f1))"
echo
echo "Install with the Magisk app (Modules -> Install from storage), then reboot."
echo "Magisk sets 0755/0644 root:root u:object_r:system_file:s0 on module files,"
echo "which is exactly what MindTheGapps' own update-binary applies."
