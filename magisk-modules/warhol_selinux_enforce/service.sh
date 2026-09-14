#!/system/bin/sh
# warhol_selinux_enforce (service): safety net + bootloop-counter reset.
# The real early flip happens in post-fs-data.sh; here we make sure we are enforcing
# and, once the boot fully completes, clear the bootloop fail counter.
MODDIR=${0%/*}

[ -f /data/adb/no_enforce ] && exit 0

# Ensure rules are live and we are enforcing even if post-fs-data was skipped.
[ -f "$MODDIR/sepolicy.rule" ] && magiskpolicy --live --apply "$MODDIR/sepolicy.rule" 2>/dev/null
setenforce 1

# A completed boot means enforcing did not wedge us: clear the fail counter.
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
rm -f /data/adb/warhol_enforce_fails
log -t warhol_selinux_enforce "service: boot_completed, enforcing=$(getenforce), fail-counter cleared"
