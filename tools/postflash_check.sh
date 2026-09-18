#!/bin/bash
# Read-only regression check after flashing a warhol ROM (system/system_ext/product).
# Run on awe with the phone attached and booted:  bash $B/tmp/postflash_check.sh
S() { adb shell "$@" </dev/null 2>/dev/null | tr -d '\r'; }
ok=0; bad=0
# chk NAME PASS(0/1) DETAIL -- always pass a quoted, non-empty second argument
chk() { if [ "$2" = 1 ]; then echo "PASS  $1  ($3)"; ok=$((ok+1)); else echo "FAIL  $1  ($3)"; bad=$((bad+1)); fi; }
t() { "$@" && echo 1 || echo 0; }
v=$(S getprop ro.lineage.version); chk "build" "$(t [ -n "$v" ])" "$v, SPL $(S getprop ro.build.version.security_patch)"
e=$(S getenforce); chk "SELinux" "$(t [ "$e" = Enforcing ])" "$e"
r=$(S su -c id | grep -c 'uid=0'); chk "Magisk root" "$(t [ "$r" = 1 ])" "su -c id"
n=$(S dumpsys sensorservice | sed -n 's/^Total \([0-9]*\) h\/w sensors.*/\1/p' | head -1); chk "sensors" "$(t [ "${n:-0}" -ge 40 ])" "${n:-?} h/w (expect 48)"
ss=$(S dumpsys telephony.registry | grep -c '^    mServiceState={mVoiceRegState=0(IN_SERVICE)'); chk "voice in service" "$(t [ "$ss" -ge 1 ])" "$ss of 2 SIMs"
NAI=$(S dumpsys connectivity | grep 'NetworkAgentInfo{')
d=$(echo "$NAI" | grep -c 'MOBILE.*Capabilities: INTERNET\|MOBILE.*INTERNET&'); chk "mobile data" "$(t [ "$d" -ge 1 ])" "$d internet agent(s)"
w=$(echo "$NAI" | grep -c 'WIFI.*IS_VALIDATED'); chk "wifi" "$(t [ "$w" -ge 1 ])" "$w validated"
ims=$(echo "$NAI" | grep -c 'Capabilities: IMS'); chk "IMS" "$(t [ "$ims" -ge 1 ])" "$ims IMS agent(s)"
md=$(S ls -l /dev/mi_display/disp_feature | grep -c 'graphics'); chk "FOD ueventd node" "$(t [ "$md" = 1 ])" "/dev/mi_display/disp_feature root:graphics"
ue=$(S grep -c system_ext/etc/ueventd.rc /system/etc/ueventd.rc); chk "ueventd imports system_ext" "$(t [ "$ue" = 1 ])" "/system/etc/ueventd.rc"
mods=$(S su -c 'ls /data/adb/modules' | tr '\n' ' '); chk "Magisk modules" "$(t [ -n "$mods" ])" "$mods"
co=$(S dumpsys platform_compat | grep 296558535 | grep -c 'messaging=false'); chk "Messages FGS compat override" "$(t [ "$co" = 1 ])" "per-app override present"
mc=$(S logcat -d -b crash | grep -c 'Process: com.google.android.apps.messaging'); chk "Messages no crash this boot" "$(t [ "$mc" = 0 ])" "$mc crash(es)"
lc=$(S logcat -d -b crash | grep -c 'Process: com.android.launcher3'); chk "launcher no crash" "$(t [ "$lc" = 0 ])" "$lc"
su=$(S logcat -d -b crash | grep -c 'Process: com.android.systemui'); chk "SystemUI no crash" "$(t [ "$su" = 0 ])" "$su"
oe=$(S pm path im.angry.openeuicc | head -1); chk "OpenEUICC installed" "$(t [ -n "$oe" ])" "$oe"
ld=$(S dumpsys activity com.android.launcher3/.uioverrides.QuickstepLauncher | grep -m1 'workspacePadding.bottom' | awk '{print $2}')
echo "INFO  launcher workspacePadding.bottom = $ld (36px with the advanced-grid dock off; was 219px before the fix)"
echo "---- $ok pass, $bad fail. Still needs the user: FOD unlock, face unlock, a call, camera, eSIM."
