# SystemUI: status-bar clocks clip their own text

Split out of the warhol port for upstream submission. Carries no git identity —
submit under your own.

    BASE_COMMIT   35ad1f68539dce0857d25154dacb1116100737e9
    Target        LineageOS/android_frameworks_base  (packages/SystemUI)

Not AOSP: `right_clock_layout`, `clock_right` and `clock_center` are LineageOS
additions.

## The bug

`clock_right` (in `res/layout/system_icons.xml`) and `clock_center` (in
`res/layout/status_bar.xml`) declare an **exact** height of
`@dimen/status_bar_system_icons_height`. That dimension sizes *icons*, and it is
smaller than the line height of the clocks' own 14sp text
(`TextAppearance.StatusBar.Default` -> `@dimen/status_bar_clock_size` = 14sp).

With `gravity="center_vertical"`, the overflow is split top and bottom and the
parent clips it: the clock renders visibly lower than the icons beside it, with
the bottoms of the digits sheared flat.

Measured on a 1280x2772 / 480dpi device via `uiautomator dump`:

    right_clock_layout  bounds=[1075,22][1196,61]   <- 39px box
    clock_right         bounds=[1075,22][1196,61]   <- same 39px box
    battery             bounds=[1044,22][1067,61]   <- same band; an icon, so it fits

39 px of box for text needing ~49 px at 14sp with density 3.0.

## The fix

The **left** clock in `status_bar.xml` already does the right thing:

    android:layout_height="wrap_content"
    android:minHeight="@dimen/status_bar_system_icons_height"

The patch applies that same pair to `clock_right` and `clock_center`, so all three
clocks are consistent. `wrap_content` lets the view be as tall as its text needs;
`minHeight` preserves the old floor so nothing gets shorter than before and the
icon row keeps its alignment.

This is parent-height independent, which matters: `keyguard_status_bar.xml` also
includes `@layout/system_icons`, so the lock-screen status bar has its own
`clock_right`. One layout fix covers both status bars.

## Proposed commit message

    SystemUI: Let the status bar clocks be as tall as their text

    clock_right and clock_center take an exact height of
    status_bar_system_icons_height. That dimen sizes icons and is shorter
    than the line height of the clocks' own 14sp text, so center_vertical
    splits the overflow and the parent clips it -- the clock renders low
    with the bottoms of the digits cut off.

    The left clock already uses wrap_content with minHeight set to the same
    dimen. Do the same for the other two so all three agree, keeping the
    old height as a floor.

## Reproducing without this device

Any device whose `status_bar_icon_size_sp` resolves smaller than the clock's line
height will show it. Set the clock position to right (Settings > System > Status
bar > Clock), then compare the clock's baseline with the battery icon beside it,
or read the bounds out of `adb shell uiautomator dump`. The lock-screen status bar
shows it too, and does so regardless of the clock-position setting.

## Verified upstream state — 2026-09-11

**`lineage-24.0` already carries exactly this fix.** Commit
`b353d2d5e4a3524461813cb0ebd1c0865e15907a` ("SystemUI: Clock position
customization", 2026-07-18) re-landed the feature with
`android:layout_height="wrap_content"` plus `android:minHeight` on both
`clock_right` (`system_icons.xml`) and `clock_center` (`status_bar.xml`) — the
same pair this patch applies. Only the dimen differs: 24.0 uses
`@dimen/status_bar_icon_container_height`; `lineage-23.2` has no such dimen, so
keep `@dimen/status_bar_system_icons_height` here. Cite that commit in the
review — "make 23.2 match 24.0" is the whole argument and needs no design
defense.

**Still broken at `lineage-23.2` HEAD** (re-read today): `clock_right` carries
`android:layout_height="@dimen/status_bar_system_icons_height"` and no
`minHeight`. The patch applies.

**Where to submit.** Host `review.lineageos.org`, project
`LineageOS/android_frameworks_base` (confirmed ACTIVE via the Gerrit projects
query), branch `lineage-23.2`:

    scp -p -P 29418 <LOS_USER>@review.lineageos.org:hooks/commit-msg .git/hooks/commit-msg
    chmod +x .git/hooks/commit-msg

    git push ssh://<LOS_USER>@review.lineageos.org:29418/LineageOS/android_frameworks_base \
        HEAD:refs/for/lineage-23.2

No CLA. `frameworks/base`'s `PREUPLOAD.cfg` runs clang-format, `bpfmt`, `ktfmt`,
google-java-format, checkstyle, two hiddenapi hooks and `ktlint` — none of which
look at layout XML, so this patch has no formatter exposure, and there is no
commit-message hook. Not AOSP: neither view exists there.
