#!/usr/bin/env python3
"""Stop a long-edge display cutout from indenting the landscape status bar.

warhol's cutout is a hole in the middle of the natural TOP edge (portrait). Rotated to
landscape it lands in the middle of the LEFT edge: bounding rect (0, 600, 125, 680) while
the landscape status bar is (0, 0, 2772, 84). They are 516 px apart and never overlap.

But shareShortEdge() does not test a real intersection -- it extends the cutout rect along
the bar's long axis first:

    return sbRect.intersects(cutoutRect.left, 0, cutoutRect.right, currentHeight)

so (0,0,2772,84) vs (0,0,125,1280) "intersects", touchesLeftEdge(ROTATION_NONE) is
`left <= 0` which is true, and leftMargin becomes max(125, minLeft) = 125. Measured
result: left content inset 150 px vs right 84 px -- a visible 66 px asymmetry, with the
clock pushed inward while the battery hugs the edge.

That extension is meant to catch a cutout sharing a SHORT edge with the bar (corner
notches, where letter-boxing matters). With config_fillMainBuiltInDisplayCutout=true the
bar spans the whole edge and there is no letter-boxing, so only a cutout that genuinely
overlaps the bar should contribute a side margin. Require a real intersection.

Portrait is unaffected: there the cutout (600,45,680,125) really does intersect the bar
(0,0,1280,125), and neither touchesLeftEdge (left<=0) nor touchesRightEdge (right>=width)
holds for a centered notch, so it contributes no side margin either way -- which is why
portrait already measured symmetric (79 px vs 84 px, i.e. glyph bearing only).

Idempotent: re-running is a no-op.
"""
import sys

P = ("/run/media/local/4TB/warhol-los-24/src/frameworks/base/packages/SystemUI/src/"
     "com/android/systemui/statusbar/layout/StatusBarContentInsetsProvider.kt")

MARKER = "warhol: require a REAL intersection"

OLD = """private fun shareShortEdge(
    sbRect: Rect,
    cutoutRect: Rect,
    currentWidth: Int,
    currentHeight: Int,
): Boolean {
    if (currentWidth < currentHeight) {
        // Check top/bottom edges by extending the width of the display cutout rect and checking
        // for intersections
        return sbRect.intersects(0, cutoutRect.top, currentWidth, cutoutRect.bottom)
    } else if (currentWidth > currentHeight) {
        // Short edge is the height, extend that one this time
        return sbRect.intersects(cutoutRect.left, 0, cutoutRect.right, currentHeight)
    }

    return false
}"""

NEW = """private fun shareShortEdge(
    sbRect: Rect,
    cutoutRect: Rect,
    currentWidth: Int,
    currentHeight: Int,
): Boolean {
    // warhol: require a REAL intersection with the status bar, not an edge-extended one.
    //
    // Extending the cutout along the bar's long axis (the original behavior, kept below
    // for the genuinely ambiguous square case) makes a hole in the MIDDLE of a long edge
    // look as though it shares a short edge with the bar. On this device the portrait
    // top-center hole becomes a left-edge hole in landscape at y=600..680, while the
    // landscape bar is y=0..84; the extended test matched, touchesLeftEdge() was true
    // because the rect starts at x=0, and the bar picked up a spurious 125 px left
    // margin. That showed up as the clock sitting 66 px further from the edge than the
    // battery.
    //
    // The extension exists to catch cutouts sharing a SHORT edge with the bar, where
    // letter-boxing would otherwise matter. With config_fillMainBuiltInDisplayCutout the
    // bar spans the entire edge and nothing is letter-boxed, so a cutout only deserves a
    // side margin when it actually overlaps the bar.
    if (currentWidth != currentHeight) {
        return sbRect.intersects(
            cutoutRect.left,
            cutoutRect.top,
            cutoutRect.right,
            cutoutRect.bottom,
        )
    }

    return false
}"""

s = open(P, encoding="utf-8").read()

if MARKER in s:
    print("already patched")
    sys.exit(0)

if s.count(OLD) != 1:
    print("ABORT: shareShortEdge anchor matched %d times, expected 1" % s.count(OLD))
    sys.exit(1)

open(P, "w", encoding="utf-8").write(s.replace(OLD, NEW, 1))
print("patched StatusBarContentInsetsProvider.kt: shareShortEdge now requires a real intersection")
