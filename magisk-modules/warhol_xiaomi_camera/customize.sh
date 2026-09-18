#!/system/bin/sh
# Magisk install-time script for the MiuiCamera module.
#
# Ships MiuiCamera as a PRIVILEGED system app (/system/priv-app) plus a
# privapp-permissions allowlist, so the MIUI computational (MIVI) pipeline can
# obtain SYSTEM_CAMERA and finalize full-res captures. Refuses to install while
# the bundled APK is still the placeholder, so a half-built module can never
# silently land on the phone.

SKIPUNZIP=0

PLACEHOLDER_MSG="This zip ships a PLACEHOLDER MiuiCamera.apk.
Put the real stock MiuiCamera.apk (6.3.008790.1, package com.android.camera) at:
  module tree: system/priv-app/MiuiCamera/MiuiCamera.apk
then rebuild the zip with tools/build-module.sh and flash again.
See README.md in the module source tree."

ui_print() { echo "$1"; }

# --- 1. The APK must be real -------------------------------------------------
APK="$MODPATH/system/priv-app/MiuiCamera/MiuiCamera.apk"
if [ ! -f "$APK" ]; then
    ui_print "! $APK missing"
    ui_print "! $PLACEHOLDER_MSG"
    abort
fi
SIZE=$(stat -c %s "$APK" 2>/dev/null || wc -c < "$APK")
if [ "$SIZE" -lt 10000000 ]; then
    ui_print "! MiuiCamera.apk is only ${SIZE} bytes (placeholder?)"
    ui_print "! $PLACEHOLDER_MSG"
    abort
fi

unzip -l "$APK" resources.arsc >/dev/null 2>&1 || {
    ui_print "! MiuiCamera.apk has no resources.arsc (not a complete APK)"
    abort
}
unzip -l "$APK" classes.dex >/dev/null 2>&1 || {
    ui_print "! MiuiCamera.apk has no classes.dex"
    abort
}
unzip -l "$APK" "lib/arm64-v8a/*" >/dev/null 2>&1 || {
    ui_print "! WARNING: no lib/arm64-v8a in APK (native camera stack missing?)"
}

# --- 2. The privapp allowlist MUST be present -------------------------------
# ro.control_privapp_permissions=enforce on warhol: a priv-app missing any
# requested privileged permission from its allowlist HALTS the boot.
ALLOW="$MODPATH/system/etc/permissions/privapp-permissions-com.android.camera.xml"
if [ ! -f "$ALLOW" ]; then
    ui_print "! Missing privapp-permissions allowlist: $ALLOW"
    ui_print "! Refusing: a priv-app without its allowlist bootloops under enforce."
    abort
fi

# --- 3. Environment sanity ---------------------------------------------------
if [ "$API" -lt 29 ]; then
    ui_print "! This module targets Android 10+ (minSdk of the app is 29); refusing."
    abort
fi

# --- 4. Guard against a same-named package ----------------------------------
PMNAME=$(pm path com.android.camera 2>/dev/null | head -1)
if [ -n "$PMNAME" ]; then
    case "$PMNAME" in
        *MiuiCamera*) : ;;   # our own previous install: fine, it will be replaced
        *) ui_print "! Another package already owns com.android.camera:"
           ui_print "!   $PMNAME"
           ui_print "! Refusing to shadow it. Uninstall that first."
           abort ;;
    esac
fi

ui_print "- Installing stock MiuiCamera as /system/priv-app/MiuiCamera (PRIVILEGED)"
ui_print "- privapp-permissions allowlist (11 perms incl SYSTEM_CAMERA) -> /system/etc/permissions/"
ui_print "- Hidden-API whitelist for com.android.camera -> /system/etc/sysconfig/"
ui_print "- Default runtime-permission grants -> /system/etc/default-permissions/"
ui_print "! Privileged status is REQUIRED for full-res MIVI captures: SYSTEM_CAMERA"
ui_print "! gates the virtual MockCamera that receives the finished full-res image."
ui_print "! This adds a second 'Camera' launcher entry and matches the standard"
ui_print "! camera intents; it does NOT force itself as the default IMAGE_CAPTURE handler."
ui_print "- Reboot required (package scan + SystemConfig both run at boot)."
