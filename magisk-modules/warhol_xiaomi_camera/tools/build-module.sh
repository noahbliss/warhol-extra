#!/bin/sh
# Build the Magisk module zip from the module source tree.
# Portable: needs only python3 (zip is not installed on the build host).
#
# Usage: build-module.sh [path-to-miuicamera.apk]
#   If an APK path is given and it passes checks, it is copied into
#   system/priv-app/MiuiCamera/MiuiCamera.apk before zipping.

set -e
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC="$HERE/.."
APK_DST="$SRC/system/priv-app/MiuiCamera/MiuiCamera.apk"
OUT_ZIP="${1:+}"
OUT_ZIP="$(dirname "$SRC")/miuicamera-ws2-$(date +%Y%m%d).zip"

if [ -n "$1" ]; then
    "$HERE/verify-apk.sh" "$1"
    cp "$1" "$APK_DST"
    echo "Copied $(basename "$1") into the module tree."
fi

"$HERE/verify-apk.sh" "$APK_DST" || {
    echo ""
    echo "The bundled APK is still the placeholder (or invalid)."
    echo "Build continues so you can inspect the zip, but flashing it will"
    echo "abort in Magisk by design (customize.sh)."
}

cd "$SRC"
rm -f "$OUT_ZIP"
python3 - "$OUT_ZIP" <<'EOF'
import os, sys, zipfile
out = sys.argv[1]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for root, dirs, files in os.walk("."):
        dirs[:] = [d for d in dirs if d not in (".git", "__pycache__")]
        for f in sorted(files):
            p = os.path.join(root, f)
            z.write(p, os.path.relpath(p, "."))
print("wrote", out)
EOF

echo "sha256:"
sha256sum "$OUT_ZIP" 2>/dev/null || shasum -a 256 "$OUT_ZIP"
