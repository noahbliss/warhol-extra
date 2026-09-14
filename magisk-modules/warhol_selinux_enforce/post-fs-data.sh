#!/system/bin/sh
# warhol_selinux_enforce (post-fs-data): flip to Enforcing EARLY, before zygote/
# system_server start, instead of ~20s after boot_completed. The bootconfig ships
# androidboot.selinux=permissive (inherited from the eng vendor_boot), so the kernel
# comes up permissive; we enforce as soon as Magisk hands us post-fs-data.
MODDIR=${0%/*}

# Runtime kill-switch: `touch /data/adb/no_enforce` keeps this boot permissive.
[ -f /data/adb/no_enforce ] && exit 0

# Bootloop self-heal: post-fs-data bumps this counter every boot; a fully completed
# boot clears it in service.sh. If enforcing wedges the boot, the counter is never
# cleared, and after 2 failed attempts we auto-disable (sticky) and stay permissive.
FAILF=/data/adb/warhol_enforce_fails
fails=$(cat "$FAILF" 2>/dev/null || echo 0)
case "$fails" in ''|*[!0-9]*) fails=0 ;; esac
if [ "$fails" -ge 2 ]; then
    : > /data/adb/no_enforce
    log -t warhol_selinux_enforce "AUTO-DISABLED after $fails failed enforcing boots; staying permissive. To retry: rm /data/adb/no_enforce /data/adb/warhol_enforce_fails"
    exit 0
fi
echo $((fails + 1)) > "$FAILF"

# sepolicy.rule is already merged by magiskinit at early boot; re-apply live as a
# belt-and-suspenders in one pass, then enforce.
[ -f "$MODDIR/sepolicy.rule" ] && magiskpolicy --live --apply "$MODDIR/sepolicy.rule" 2>/dev/null
setenforce 1
log -t warhol_selinux_enforce "post-fs-data: setenforce 1 -> $(getenforce) (attempt $((fails + 1)))"
