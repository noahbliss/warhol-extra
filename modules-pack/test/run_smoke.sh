#!/bin/sh
# Local smoke test for the pack installer. Never touches /data on this box:
# all /data and /dev/tmp paths are redirected into this test/ dir via sed.
T=$(cd "$(dirname "$0")" && pwd)
KIT=$(cd "$T/../.." && pwd)
ZIPF="$KIT/warhol-modules-pack.zip"
FAKE="$T/fake_root"

sed -e "s|/dev/tmp|$FAKE/scratch|g" -e "s|/data|$FAKE|g" \
    "$T/../installer/update-binary" > "$T/update-binary.test"

rm -rf "$FAKE"
mkdir -p "$FAKE"

echo "== run 1 =="
sh "$T/update-binary.test" 3 1 "$ZIPF"
echo "exit=$?"
echo "== run 2 (idempotency) =="
sh "$T/update-binary.test" 3 1 "$ZIPF"
echo "exit=$?"

echo "== staged tree with perms =="
find "$FAKE/adb/modules" -exec ls -ld {} +
echo "== staged module.prop =="
cat "$FAKE/adb/modules/warhol_adwaita_font/module.prop"
echo "== markers (expect none) =="
ls "$FAKE/adb/modules/warhol_adwaita_font/disable" \
   "$FAKE/adb/modules/warhol_adwaita_font/remove" \
   "$FAKE/adb/modules/warhol_adwaita_font/update" 2>/dev/null || echo "none - good"

echo "== failure path: missing zip =="
sh "$T/update-binary.test" 3 1 "$T/nonexistent.zip" || echo "exit=$? (nonzero expected)"
