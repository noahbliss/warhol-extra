#!/bin/bash
# Compile the split SELinux policy exactly as init will at the next boot: the platform,
# system_ext and product CIL from a new build's images, plus the vendor and odm CIL that
# are on the phone now. warhol has no usable precompiled policy (the stock one in /odm
# never matches our system), so init compiles this at every boot. If it fails to compile,
# init cannot load a policy and the phone boot-loops, so run this before every flash.
#
#     bash policy_check.sh <build dir>     phone booted and attached (reads its vendor side)
#     WARHOL_VENDOR_SELINUX=<dir> bash policy_check.sh <build dir>     offline, from a saved
#         copy (the pulled vendor side is kept in <build dir>/vendor-selinux/ after a run)
#
# It first compiles the phone's CURRENT system policy as a control. That one is known to
# boot, so control PASS + new FAIL is a real regression in the build, while a failing
# control means the vendor-side copy or this tool is at fault. Exit 0 pass, 1 fail, 2 both.
set -u
D="${1:?usage: policy_check.sh <dir with system.img, system_ext.img, product.img>}"
P="${WARHOL_ROOT:-/run/media/local/4TB/warhol-los-24}"
SECILC="$P/src/out/host/linux-x86/bin/secilc"
DEBUGFS=/usr/sbin/debugfs
die() { echo "ABORT: $*" >&2; exit 1; }
A() { adb "$@" </dev/null 2>/dev/null | tr -d '\r'; }
[ -x "$SECILC" ] || die "$SECILC missing (build the tree once)"
for i in system system_ext product; do [ -f "$D/$i.img" ] || die "$D/$i.img missing"; done
W=$(mktemp -d "$P/tmp/policy_check.XXXXXX"); trap 'rm -rf "$W"' EXIT

online=0; [ "$(A get-state)" = device ] && online=1
V="${WARHOL_VENDOR_SELINUX:-}"
if [ -z "$V" ]; then
    [ $online = 1 ] || die "phone not attached and booted; set WARHOL_VENDOR_SELINUX to a saved copy"
    V="$D/vendor-selinux"; rm -rf "$V"; mkdir -p "$V"
    for f in plat_sepolicy_vers.txt genfs_labels_version.txt plat_pub_versioned.cil vendor_sepolicy.cil; do
        adb exec-out cat /vendor/etc/selinux/$f </dev/null > "$V/$f"
    done
    adb exec-out cat /odm/etc/selinux/odm_sepolicy.cil </dev/null > "$V/odm_sepolicy.cil"
    A shell cat /sys/fs/selinux/policyvers > "$V/policyvers"
    A shell getprop ro.vendor.build.fingerprint > "$V/vendor_fingerprint"
fi
for f in plat_sepolicy_vers.txt plat_pub_versioned.cil vendor_sepolicy.cil policyvers; do
    [ -s "$V/$f" ] || die "$V/$f missing or empty"
done
VER=$(tr -d '\r\n ' < "$V/plat_sepolicy_vers.txt")
PV=$(tr -d '\r\n ' < "$V/policyvers")
GV=$(tr -d '\r\n ' < "$V/genfs_labels_version.txt" 2>/dev/null)
echo "vendor mapping $VER, genfs labels ${GV:-none}, kernel policy version $PV, vendor cil $(grep -c '^(allow' "$V/vendor_sepolicy.cil") allow rules"

# fetch ROOT REL_PATH OUT: copy one file of a policy set into OUT (no output if absent).
# ROOT is an ext4 image (read with debugfs) or "phone:" (read over adb).
fetch() {
    case "$1" in
    phone:) [ "$(A shell "[ -f '$2' ] && echo y")" = y ] && adb exec-out cat "$2" </dev/null > "$3" ;;
    *) "$DEBUGFS" -R "dump $2 $3" "$1" >/dev/null 2>&1 ;;
    esac
    [ -s "$3" ] || rm -f "$3"
}

# compile NAME SYSTEM_ROOT SYSTEM_EXT_ROOT SYSTEM_EXT_PREFIX PRODUCT_ROOT PRODUCT_PREFIX
# Arguments go to secilc in init's order. The prefix is where the partition sits under its
# root: "/system_ext" on the phone, "" inside system_ext.img. system.img is system-as-root,
# so /system/etc/selinux is the same path in both.
compile() {
    local o="$W/${1%% *}"; mkdir -p "$o"
    fetch "$2" /system/etc/selinux/plat_sepolicy.cil "$o/plat.cil"
    fetch "$2" /system/etc/selinux/mapping/$VER.cil "$o/plat_map.cil"
    fetch "$2" /system/etc/selinux/mapping/$VER.compat.cil "$o/plat_compat.cil"
    fetch "$3" "$4"/etc/selinux/system_ext_sepolicy.cil "$o/se.cil"
    fetch "$3" "$4"/etc/selinux/mapping/$VER.cil "$o/se_map.cil"
    fetch "$3" "$4"/etc/selinux/mapping/$VER.compat.cil "$o/se_compat.cil"
    fetch "$5" "$6"/etc/selinux/product_sepolicy.cil "$o/pr.cil"
    fetch "$5" "$6"/etc/selinux/mapping/$VER.cil "$o/pr_map.cil"
    [ -n "$GV" ] && fetch "$2" /system/etc/selinux/plat_sepolicy_genfs_$GV.cil "$o/genfs.cil"
    [ -f "$o/plat.cil" ] && [ -f "$o/plat_map.cil" ] || { echo "FAIL  $1: no plat_sepolicy.cil or mapping/$VER.cil"; return 1; }
    [ -n "$GV" ] && [ "$GV" -ge 202504 ] && [ ! -f "$o/genfs.cil" ] && {
        echo "FAIL  $1: plat_sepolicy_genfs_$GV.cil missing (init treats that as an error)"; return 1; }
    local args=("$o/plat.cil" "$o/plat_map.cil")
    for f in plat_compat se se_map se_compat pr pr_map; do [ -f "$o/$f.cil" ] && args+=("$o/$f.cil"); done
    args+=("$V/plat_pub_versioned.cil" "$V/vendor_sepolicy.cil")
    [ -s "$V/odm_sepolicy.cil" ] && args+=("$V/odm_sepolicy.cil")
    [ -f "$o/genfs.cil" ] && args+=("$o/genfs.cil")
    if "$SECILC" -m -M true -G -N -c "$PV" "${args[@]}" -o "$o/policy" -f /dev/null > "$o/log" 2>&1; then
        echo "PASS  $1: compiled, $(stat -c %s "$o/policy") bytes, ${#args[@]} cil files"
    else
        echo "FAIL  $1: secilc rejected it:"; sed 's/^/        /' "$o/log" | tail -20; return 1
    fi
}

rc=0
if [ $online = 1 ]; then
    compile "control (the phone's current system)" phone: phone: /system_ext phone: /product || rc=2
else
    echo "SKIP  control: phone not attached"
fi
compile "new build ($(basename "$D"))" "$D/system.img" "$D/system_ext.img" "" "$D/product.img" "" || { [ $rc = 0 ] && rc=1; }
[ $rc = 2 ] && echo "The control failed too, and the phone boots with that policy today, so the fault is in
the vendor-side copy or in this tool, not in the new build. Do not trust either result."
exit $rc
