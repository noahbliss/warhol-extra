#!/usr/bin/env python3
"""Add working US Mobile (Light Speed / T-Mobile) APNs for PLMN 310240.

LineageOS' vendor/apn ships only US Mobile's LEGACY entry for this PLMN:

    <apn mcc="310" mnc="240" carrier="US Mobile" apn="pwg"
         mvno_match_data="6901" mvno_type="gid"
         protocol="IPV4V6" roaming_protocol="IP"
         type="default,supl,mms" />

Three things make that unusable on a current Light Speed line roaming abroad:
  * "pwg" is US Mobile's legacy GSM APN; Light Speed uses "wholesale".
  * the gid mvno match means it often does not match at all, which is what
    produces the repeated NO_SUITABLE_DATA_PROFILE in DataNetworkController.
  * roaming_protocol="IP" forces IPv4-only off-network.

Measured on warhol roaming in UA (verified 2026-09-12): with "pwg" the network
answers PDP activation with ESM cause 33 SERVICE_OPTION_NOT_SUBSCRIBED, which in
turn rejects the LTE attach with EMM cause 19 (ESM failure) and drops the UE to
3G. With the entry below, SETUP_DATA_CALL returns cause=NONE on EUTRAN and data
works. Both the APN name and roaming_protocol were changed together, so this is
verified as a combination, not attributed to either alone.

There is also no ims/xcap APN for 310240 (310260 has one), so the IMS PDN can
never be brought up on this PLMN; that entry is added too.
"""
import os, sys, re

MARKER = "US Mobile Light Speed"
ROOT = os.environ.get("WARHOL_ROOT", "/run/media/local/4TB/warhol-los-24")
PATH = os.path.join(ROOT, "src", "vendor", "apn", "US.xml")

NEW = '''    <apn
        mcc="310"
        mnc="240"
        carrier="US Mobile Light Speed"
        apn="wholesale"
        mmsc="http://wholesale.mmsmvno.com/mms/wapenc"
        protocol="IPV4V6"
        roaming_protocol="IPV4V6"
        type="default,supl,mms"
    />
    <apn
        mcc="310"
        mnc="240"
        carrier="US Mobile IMS"
        apn="ims"
        protocol="IPV4V6"
        roaming_protocol="IPV4V6"
        type="ims,xcap"
    />
'''

def main():
    if not os.path.exists(PATH):
        print("apns: %s missing -- skipped" % PATH); return 0
    src = open(PATH, encoding="utf-8").read()
    if MARKER in src:
        print("already patched: US Mobile 310240 APNs"); return 0

    # anchor: the legacy pwg entry for 310240, insert ours immediately before it
    # so ours is matched first (the provider preserves file order).
    m = re.search(r'    <apn\n        mcc="310"\n        mnc="240"\n'
                  r'        carrier="US Mobile"\n        apn="pwg"\n',
                  src)
    if not m:
        print("apns: anchor (310240 US Mobile pwg) not found -- NOT patched",
              file=sys.stderr)
        return 1
    src = src[:m.start()] + NEW + src[m.start():]
    open(PATH, "w", encoding="utf-8").write(src)
    print("patched: US Mobile 310240 APNs (wholesale + ims)")
    return 0

sys.exit(main())
