#!/bin/bash
# Archive a finished build: copy the flashable images out of tmp/flash into builds/<name>/
# with SHA256SUMS and a README that records what went into them. Flash from the archive,
# never from tmp/flash, so a later build cannot swap the images underneath a flash; the
# archive of the build you replace is your rollback.
#     bash save_build.sh <name>        e.g. 20261215-q4      (or: remote-build.sh save-build)
set -euo pipefail
N="${1:?usage: save_build.sh <name, e.g. 20261215-q4>}"
P="${WARHOL_ROOT:-/run/media/local/4TB/warhol-los-24}"
WX="${WARHOL_EXTRA:-$P/warhol-extra}"
S="$P/tmp/flash"; D="$P/builds/$N"; OUT="$P/src/out/target/product/warhol"
DEBUGFS=/usr/sbin/debugfs
die() { echo "ABORT: $*" >&2; exit 1; }
[ ! -e "$D" ] || die "$D already exists"
for i in system system_ext product; do
    [ -f "$S/$i.img" ] || die "$S/$i.img missing; run remote-build.sh build"
    # tmp/flash is written by patch_debuggable after a successful build. Older than out/
    # means the last build failed after writing out/, or never reached that step.
    [ ! "$OUT/$i.img" -nt "$S/$i.img" ] || die "$S/$i.img is older than $OUT/$i.img; the last build did not finish"
done
prop() { "$DEBUGFS" -R "cat $2" "$S/$1.img" 2>/dev/null | sed -n "s/^$3=//p" | head -1; }
secure=$(prop system /system/build.prop ro.secure)
[ "$secure" = 0 ] || die "system.img has ro.secure=$secure; patch_debuggable did not run (no adb root)"
spl=$(prop product /etc/build.prop ro.build.version.security_patch)
ver=$(prop product /etc/build.prop ro.lineage.version)
fp=$(prop system /system/build.prop ro.system.build.fingerprint)
utc=$(prop system /system/build.prop ro.build.date.utc)
# install_keys falls back to test keys when $P/keys is missing, and says so only in the log.
# A test-key build flashed over this /data breaks every platform-signed app.
case "$fp" in */release-keys) ;; *) die "fingerprint '$fp' is not release-keys: built without our signing keys" ;; esac
head_of() { git -C "$1" log -1 --format='%h %s' 2>/dev/null; }
dirty_of() { [ -z "$(git -C "$1" status --porcelain --untracked-files=no 2>/dev/null)" ] || echo " (UNCOMMITTED CHANGES)"; }

mkdir -p "$D"
cp -p "$S/system.img" "$S/system_ext.img" "$S/product.img" "$D/"
( cd "$D" && sha256sum system.img system_ext.img product.img > SHA256SUMS )
# The rollback is whatever the phone runs now: match its build time against the archive.
prev=""
now=$(adb shell getprop ro.build.date.utc </dev/null 2>/dev/null | tr -d '\r')
if [ -n "$now" ]; then
    for b in "$P"/builds/*/; do
        [ "$(basename "$b")" = "$N" ] && continue
        [ -f "$b/system.img" ] || continue
        [ "$("$DEBUGFS" -R 'cat /system/build.prop' "$b/system.img" 2>/dev/null | sed -n 's/^ro.build.date.utc=//p')" = "$now" ] \
            && prev="$P/builds/$(basename "$b") (on the phone at save time)"
    done
    [ -n "$prev" ] || prev="(the phone runs a build that is not in $P/builds; archive it before flashing)"
    [ "$now" = "$utc" ] && prev="(the phone already runs this build)"
else
    prev="(phone not attached at save time: use the builds/ directory that is on the phone before you flash)"
fi
cat > "$D/README" <<README
warhol $ver, saved $(date '+%F %H:%M') by save_build.sh
security patch $spl
fingerprint   $fp

source
  manifests     $(git -C "$P/src/.repo/manifests" log -1 --format='%h %cd' --date=short)
  device tree   $(head_of "$P/device/xiaomi/warhol")$(dirty_of "$P/device/xiaomi/warhol")
  warhol-extra  $(head_of "$WX")$(dirty_of "$WX")
  Launcher3     $(git -C "$P/src/packages/apps/Launcher3" rev-parse --short HEAD) (upstream; the advanced grid is in the trebuchet_advgrid module)
  OpenEUICC     $(git -C "$P/src/packages/apps/OpenEUICC" rev-parse --short HEAD)

images (debuggable props already patched)
$(sed 's/^/  /' "$D/SHA256SUMS")

flash (phone in TWRP, from awe):  bash $WX/tools/flash_three.sh $D
check first:                      bash $WX/tools/policy_check.sh $D
after boot and unlock:            bash $WX/tools/postflash_check.sh
rollback:                         $prev
                                  flash it the same way; same LineageOS branch only (docs/UPDATING.md)
README
cat "$D/README"
