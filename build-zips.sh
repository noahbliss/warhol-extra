#!/usr/bin/env bash
# Package each module under magisk-modules/ into a flashable zip in ./out/.
# Install with `magisk --install-module <zip>`, or extract the module dir
# straight into /data/adb/modules/<id>/ (root:root, dirs 0755, files 0644)
# and reboot -- the latter avoids Magisk's modules_update finalize step.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
out="$here/out"
mkdir -p "$out"
for mod in "$here"/magisk-modules/*/; do
    id="$(basename "$mod")"
    [ -f "$mod/module.prop" ] || continue
    zip="$out/$id.zip"
    rm -f "$zip"
    ( cd "$mod" && zip -qr9 "$zip" . -x '.*' )
    echo "built $zip"
done
