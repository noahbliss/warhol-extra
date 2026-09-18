#!/bin/sh
# Rebuild warhol-modules-pack.zip from the module zips in the module kit.
#
# To add a module later (e.g. MiuiCamera, MindTheGapps): add its zip to the
# MODULE_ZIPS list below (path to the Magisk module zip), then run:
#   sh warhol-modules-pack-src/build.sh
# The <id> used inside modules/ is read from each zip's own module.prop.

set -e

KIT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$KIT/warhol-modules-pack-src"
STAGE="$SRC/staging"
OUT="$KIT/warhol-modules-pack.zip"

# WARNING: staging modules into /data/adb before the first boot boot-loops warhol (the
# first boot's encryption policy needs /data/adb empty). See README.md next to this
# file; docs/REINSTALL.md installs modules after the first boot instead.
# Original intent: stage all Magisk modules into /data/adb/modules before first
# boot (survives a /data wipe; needs no Magisk app). Google is NEVER baked -- see
# the module-staging / gapps-systemless notes. Trebuchet's advanced grid is an optional
# feature that is never baked into the base ROM, so its module is staged here; rebuild
# it with `remote-build.sh advgrid-module <ver>` whenever upstream Launcher3 moves, and
# point the entry below at the new zip.
MODULE_ZIPS="$KIT/adwaita_font.zip $KIT/MindTheGapps-17.0.0-arm64-20260828_065753-magisk.zip $KIT/warhol_xiaomi_camera.zip $KIT/trebuchet_advgrid_v9.zip"

rm -rf "$STAGE"
mkdir -p "$STAGE/META-INF/com/google/android" "$STAGE/modules"
cp "$SRC/installer/update-binary" "$STAGE/META-INF/com/google/android/update-binary"
cp "$SRC/installer/updater-script" "$STAGE/META-INF/com/google/android/updater-script"

for modzip in $MODULE_ZIPS; do
    [ -f "$modzip" ] || { echo "ERROR: module zip not found: $modzip" >&2; exit 1; }
    id=$(unzip -p "$modzip" module.prop | sed -n 's/^id=//p' | head -n 1)
    [ -n "$id" ] || { echo "ERROR: no id= in $modzip module.prop" >&2; exit 1; }
    echo "+ staging module '$id' from $(basename "$modzip")"
    unzip -q -o "$modzip" -d "$STAGE/modules/$id"
done

python3 "$SRC/make_zip.py" "$STAGE" "$OUT"
echo "wrote $OUT"
