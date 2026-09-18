#!/usr/bin/env bash
# capture-boot-diagnostics.sh — grab the things that are only visible right after
# a boot, before the kernel ring rotates. RUN THIS FROM THE MACHINE WITH adb,
# started BEFORE the device finishes booting.
#
# Why it exists: two open workstreams both need a boot-time capture and both have
# already been lost once to ring rotation (uptime 7 h => zero scp lines left).
#   * section 6  — why the SCP never comes up (sensors)
#   * section 13a — the COMPLETE SELinux denial set, needed before writing policy
set -u
OUT="${1:-boot-diag-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"
echo "capturing into $OUT"

echo "waiting for device..."
adb wait-for-device
# dmesg FIRST and fast; everything else can wait.
adb shell dmesg                        > "$OUT/dmesg.txt"      2>&1
adb logcat -b all -d                   > "$OUT/logcat-all.txt" 2>&1

# --- section 6: SCP -------------------------------------------------------
grep -aiE 'scp|tinysys|remoteproc|sensor' "$OUT/dmesg.txt" > "$OUT/scp-dmesg.txt" 2>/dev/null
# mtk_ccd remoteproc-ccd is the CAMERA co-processor and works fine - exclude it
# so the real SCP lines are not buried.
grep -aiE 'scp|tinysys' "$OUT/dmesg.txt" | grep -av 'remoteproc-ccd' \
                                       > "$OUT/scp-only.txt"    2>/dev/null
adb shell dumpsys sensorservice         > "$OUT/sensorservice.txt" 2>&1

# --- section 13a: the full denial set ------------------------------------
# Denials appear in dmesg and, separately, in logcat. Take both and merge.
{ grep -a 'avc: *denied' "$OUT/dmesg.txt"
  grep -a 'avc: *denied' "$OUT/logcat-all.txt"; } 2>/dev/null > "$OUT/denials-raw.txt"
# Normalise away the per-event noise so identical denials collapse.
sed -E 's/.*avc: *denied *\{ *([^}]*) \} *for/{ \1 } for/;
        s/ pid=[0-9]+//; s/ comm="[^"]*"//; s/ ino=[0-9]+//;
        s/ dev="[^"]*"//; s/ audit\([0-9.:]*\)://' "$OUT/denials-raw.txt" \
  | sort | uniq -c | sort -rn > "$OUT/denials-unique.txt"

# --- state worth having alongside ----------------------------------------
adb shell getenforce                    > "$OUT/getenforce.txt"  2>&1
adb shell getprop                       > "$OUT/getprop.txt"     2>&1
adb shell dumpsys window displays       > "$OUT/displays.txt"    2>&1
adb shell 'ls -la /dev/block/by-name/'  > "$OUT/partitions.txt"   2>&1

echo "=== summary ==="
printf 'uptime at capture : %s\n' "$(adb shell uptime 2>/dev/null | tr -s ' ')"
printf 'selinux           : %s\n' "$(cat "$OUT/getenforce.txt")"
printf 'security patch    : %s\n' "$(grep -a 'ro.build.version.security_patch' "$OUT/getprop.txt" | head -1)"
printf 'scp lines (real)  : %s\n' "$(wc -l < "$OUT/scp-only.txt")"
printf 'unique denials    : %s\n' "$(wc -l < "$OUT/denials-unique.txt")"
printf 'sensors reported  : %s\n' "$(grep -ac 'Sensor:' "$OUT/sensorservice.txt" 2>/dev/null || echo 0)"
echo
echo "top denials:"; head -12 "$OUT/denials-unique.txt"
echo
echo "scp lines:"; head -20 "$OUT/scp-only.txt"
