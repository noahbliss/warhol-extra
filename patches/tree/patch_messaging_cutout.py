#!/usr/bin/env python3
"""Let Messaging draw into the display cutout in landscape.

warhol's cutout sits on a short edge, so in landscape it lands on the left or
right. Messaging declares targetSdkVersion="34", below the Android 15
edge-to-edge cutoff, so its windows default to
LAYOUT_IN_DISPLAY_CUTOUT_MODE_DEFAULT: the app is inset away from the cutout
edge and that gap renders as a ~125 px black bar. SystemUI uses shortEdges and
spans it, so the status bar runs across the black strip -- the mismatch is what
makes it obvious.

shortEdges is what the rest of this tree uses (LineageParts, Recorder,
Launcher3 values-v29). Applied to BugleBaseTheme so every Bugle theme
descending from it inherits it.

Idempotent. packages/apps/Messaging is a synced project, so repo sync reverts
this.
"""
import os
import re
import sys

ROOT = os.environ.get("WARHOL_ROOT", "/run/media/local/4TB/warhol-los-24")
PATH = os.path.join(ROOT, "src", "packages", "apps", "Messaging",
                    "res", "values", "styles.xml")
MARKER = "windowLayoutInDisplayCutoutMode"
ITEM = '        <item name="android:windowLayoutInDisplayCutoutMode">shortEdges</item>\n'

if not os.path.isfile(PATH):
    sys.exit("missing %s" % PATH)

with open(PATH) as f:
    src = f.read()

if MARKER in src:
    print("already patched: Messaging cutout mode")
    sys.exit(0)

# BugleBaseTheme's opening tag followed by its run of <item> lines; insert
# after the last one so the file keeps its existing ordering.
m = re.search(r'(    <style name="BugleBaseTheme"[^>]*>\n)((?:        <item[^\n]*\n)*)', src)
if not m:
    sys.exit("anchor not found: BugleBaseTheme style block")

src = src[:m.end(2)] + ITEM + src[m.end(2):]
with open(PATH, "w") as f:
    f.write(src)
print("patched: Messaging windowLayoutInDisplayCutoutMode=shortEdges")
