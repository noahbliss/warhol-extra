#!/bin/bash
# Flash system, system_ext, product to slot _a from TWRP, one partition at a time, each
# verified with an on-device sha256 before the next is written. Never touches anything else.
#     bash $B/tmp/flash_three.sh <dir with the three .img files + SHA256SUMS>
set -u
D="${1:?usage: flash_three.sh <image dir>}"
A() { adb "$@" </dev/null 2>/dev/null | tr -d '\r'; }
die() { echo "ABORT: $*"; exit 1; }
( cd "$D" && sha256sum -c --quiet SHA256SUMS ) || die "images in $D do not match SHA256SUMS"
[ "$(A get-state)" = recovery ] || die "phone is not in recovery"
slot=$(A shell getprop ro.boot.slot_suffix); [ "$slot" = _a ] || die "current slot is '$slot', not _a"
mnt=$(A shell mount | grep -E 'mapper/(system|system_ext|product)')
[ -z "$mnt" ] || die "dynamic partitions are mounted: $mnt"
for p in system system_ext product; do
    img="$D/$p.img"; dev=/dev/block/mapper/${p}_a
    size=$(stat -c %s "$img"); want=$(awk -v f=$p.img '$2==f {print $1}' "$D/SHA256SUMS")
    psz=$(A shell blockdev --getsize64 $dev); ro=$(A shell blockdev --getro $dev)
    [ -n "$psz" ] && [ "$size" -le "$psz" ] || die "$p: image $size > partition '$psz'"
    [ "$ro" = 0 ] || die "$p: $dev is read-only ($ro)"
    echo "writing $p: $size bytes -> $dev ($psz)"
    adb shell "dd of=$dev bs=1M conv=fsync" < "$img" 2>&1 | tr -d '\r' | tail -1
    got=$(A shell "head -c $size $dev | sha256sum" | awk '{print $1}')
    [ "$got" = "$want" ] || { echo "MISMATCH $p: device $got, image $want"; exit 2; }
    echo "VERIFIED $p ${got:0:16}"
done
echo ALL_VERIFIED
