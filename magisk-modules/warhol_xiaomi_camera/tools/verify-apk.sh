#!/bin/sh
# Sanity-check a MiuiCamera APK before it goes into the module.
# Run on the build host; needs aapt2 from the LineageOS tree
# (out/host/linux-x86/bin/aapt2). Falls back to structural checks only.

set -e
APK="$1"
[ -f "$APK" ] || { echo "verify-apk: no such file: $APK"; exit 1; }

SIZE=$(stat -c %s "$APK" 2>/dev/null || stat -f %z "$APK")
if [ "$SIZE" -lt 10000000 ]; then
    echo "verify-apk: FAIL - $APK is only ${SIZE} bytes (placeholder?)"
    exit 1
fi

AAPT2="${AAPT2:-}"
if [ -z "$AAPT2" ]; then
    for c in /run/media/local/4TB/warhol-los-24/src/out/host/linux-x86/bin/aapt2; do
        [ -x "$c" ] && AAPT2="$c"
    done
fi

if [ -n "$AAPT2" ]; then
    BADPATH="$(mktemp -d)/bad.apk"
    # aapt2 needs an apk, not a bare manifest; if given a directory with an
    # unpacked manifest, the caller passed the wrong thing.
    if [ -d "$APK" ]; then
        echo "verify-apk: FAIL - $APK is a directory; pass the .apk"
        exit 1
    fi
    BADPKG=$("$AAPT2" dump badging "$APK" 2>/dev/null | sed -n "s/^package: *name='\([^']*\)'.*versionCode=\([0-9]*\) .*/\1 \2/p" | head -1)
    NAME=${BADPKG%% *}
    VCODE=${BADPKG##* }
    if [ "$NAME" != "com.android.camera" ]; then
        echo "verify-apk: FAIL - package is '${NAME}', expected com.android.camera"
        exit 1
    fi
    echo "verify-apk: OK - $APK"
    echo "  package:     $NAME"
    echo "  versionCode: $VCODE (analysis was against 630087901 / 6.3.008790.1)"
    echo "  size:        $SIZE bytes"
else
    echo "verify-apk: aapt2 not found, structural check only:"
    echo "  size $SIZE bytes - OK"
fi
