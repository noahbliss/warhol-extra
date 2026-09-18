#!/usr/bin/env python3
"""Bake OpenEUICC ES10x MSS default 63 -> 255 ("High Efficiency").

warhol's internal eUICC is MEP-A1. lpac chunks every ES10x command to the MSS and
chains the pieces as STORE DATA. At the default MSS of 63 ("Most Compatible", meant
for *removable* eUICCs) the profile-install BPP splits its first block -- the whole
179-byte initialiseSecureChannelRequest -- across three segments, and THIS card
answers the first non-final block with a signed ProfileInstallationResult error and
6A88s the rest, so every download fails. At 255 ("High Efficiency") block 0 goes as a
single APDU and the install succeeds (verified on device 2026-09-12).

Until now that fix lived only as a per-user OpenEUICC developer-menu setting stored in
/data (es10x_mss=255), which a factory reset or an OpenEUICC data-clear would lose.
This changes the compiled-in default so a fresh install / post-wipe device is already
correct. 255 is lpac's ES10X_MSS_MAX_VALUE (main.c), so it is in range.

Idempotent: re-running is a no-op. app-common is a synced project, so repo sync
reverts this and patch_tree re-applies it every build.
"""
import os, sys

ROOT = os.environ.get("WARHOL_ROOT", "/run/media/local/4TB/warhol-los-24")
F = os.path.join(
    ROOT,
    "src/packages/apps/OpenEUICC/app-common/src/main/java/im/angry/openeuicc/util/PreferenceUtils.kt",
)
OLD = "bindFlow(PreferenceKeys.ES10X_MSS, 63)"
NEW = "bindFlow(PreferenceKeys.ES10X_MSS, 255)"

if not os.path.isfile(F):
    sys.exit("patch_esim_mss: not found: %s" % F)

s = open(F, encoding="utf-8").read()

if NEW in s:
    print("patch_esim_mss: already 255 (no-op)")
    sys.exit(0)

n = s.count(OLD)
if n != 1:
    sys.exit(
        "patch_esim_mss: expected exactly one %r, found %d -- upstream default may have "
        "changed; inspect PreferenceUtils.kt line ~104 before editing" % (OLD, n)
    )

s = s.replace(OLD, NEW)
open(F, "w", encoding="utf-8").write(s)

# verify
chk = open(F, encoding="utf-8").read()
assert NEW in chk and OLD not in chk, "patch_esim_mss: post-write verification failed"
print("patch_esim_mss: ES10x MSS default 63 -> 255 in PreferenceUtils.kt")
