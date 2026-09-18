#!/bin/bash
# Is a warhol ROM update due? Read-only: compares the security patch level (SPL) on the
# phone, in the local tree, and on upstream LineageOS, and says whether LineageOS has
# opened a newer branch (which is where security fixes go next).
#     bash update_check.sh           (or: remote-build.sh update-check)
set -u
P="${WARHOL_ROOT:-/run/media/local/4TB/warhol-los-24}"
BRANCH="${WARHOL_BRANCH:-lineage-24.0}"
REL="${WARHOL_RELEASE:-cp2a}"
FLAG="release/flag_values/$REL/RELEASE_PLATFORM_SECURITY_PATCH.textproto"
RAW=https://raw.githubusercontent.com/LineageOS/android_vendor_lineage
spl() { sed -n 's/.*string_value: *"\([0-9-]*\)".*/\1/p'; }
row() { printf '  %-30s %s\n' "$1" "$2"; }
A() { adb "$@" </dev/null 2>/dev/null | tr -d '\r'; }

echo "== phone"
if [ "$(A get-state)" = device ]; then
    row "build" "$(A shell getprop ro.lineage.version)"
    phone_spl=$(A shell getprop ro.build.version.security_patch)
    row "system SPL (updated by a ROM)" "$phone_spl"
    row "vendor SPL (stock Xiaomi)" "$(A shell getprop ro.vendor.build.security_patch)"
    row "kernel (stock GKI)" "$(A shell uname -r)"
else
    phone_spl=""; echo "  (not attached)"
fi

echo "== local tree ($P/src, $BRANCH, $REL)"
tree_spl=$(spl < "$P/src/vendor/lineage/$FLAG" 2>/dev/null)
row "SPL" "${tree_spl:-unknown}"
row "manifests" "$(git -C "$P/src/.repo/manifests" log -1 --format='%h %cd' --date=short 2>/dev/null)"
row "last synced" "$(date -r "$P/src/.repo/.repo_fetchtimes.json" +%F 2>/dev/null || echo unknown)"

echo "== upstream LineageOS"
up_spl=$(curl -sf "$RAW/$BRANCH/$FLAG" | spl)
row "$BRANCH SPL" "${up_spl:-unreachable}"
newest=$(git ls-remote --heads https://github.com/LineageOS/android 2>/dev/null \
    | sed -n 's#.*refs/heads/\(lineage-[0-9][0-9]*\.[0-9][0-9]*\)$#\1#p' | sort -V | tail -1)
row "newest branch" "${newest:-unreachable}"
if [ -n "$newest" ] && [ "$newest" != "$BRANCH" ]; then
    rels=$(curl -sf "https://api.github.com/repos/LineageOS/android_vendor_lineage/contents/release/release_configs?ref=$newest" \
        | sed -n 's/.*"name": *"\([^"]*\)\.textproto".*/\1/p' | tr '\n' ' ')
    row "$newest release config" "${rels:-unknown}"
    new_spl=$(for r in $rels; do curl -sf "$RAW/$newest/release/flag_values/$r/RELEASE_PLATFORM_SECURITY_PATCH.textproto" | spl; done | sort | tail -1)
    row "$newest SPL" "${new_spl:-unknown}"
fi

echo "== verdict"
if [ -n "$newest" ] && [ "$newest" != "$BRANCH" ]; then
    echo "  LineageOS has moved to $newest. Fixes stop landing on $BRANCH, so this update is a"
    echo "  BRANCH BUMP: follow 'Moving to a new LineageOS branch' in docs/UPDATING.md."
elif [ -n "$up_spl" ] && [ -n "$phone_spl" ] && [[ "$up_spl" > "$phone_spl" ]]; then
    echo "  Update available: upstream $BRANCH is at $up_spl, the phone is at $phone_spl."
    echo "  Follow 'Routine update' in docs/UPDATING.md."
elif [ -n "$up_spl" ] && [ -n "$phone_spl" ]; then
    echo "  Up to date: the phone ($phone_spl) matches upstream $BRANCH ($up_spl)."
else
    echo "  Incomplete: attach the phone and check network access, then rerun."
fi
