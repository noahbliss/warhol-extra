#!/bin/bash
# Check the patch_tree output in a build log against patch_tree.expected. A missing line
# means a warhol fix silently did not apply -- the failure mode that once shipped a ROM
# with eSIM dead. Meaningful for the first build after a resync (see patch_tree.expected).
#     bash patch_report.sh <build log>
set -u
L="${1:?usage: patch_report.sh <build log>}"
E="$(dirname "$0")/patch_tree.expected"
# Known and harmless: upstream already contains or no longer needs these.
BENIGN='ScalingWorkspaceRevealAnim pattern not found|dynamic_modem_shutdown is not declared|device tree not bind-mounted'
got=$(sed -n 's/^patched: //p' "$L")
miss=0
while IFS= read -r want; do
    case "$want" in ''|'#'*) continue ;; esac
    if grep -qF -- "$want" <<<"$got"; then echo "ok       $want"
    else echo "MISSING  $want"; miss=$((miss+1)); fi
done < "$E"
extra=""
while IFS= read -r g; do
    [ -n "$g" ] || continue
    hit=0
    while IFS= read -r w; do
        case "$w" in ''|'#'*) continue ;; esac
        [[ "$g" == *"$w"* ]] && { hit=1; break; }
    done < "$E"
    [ $hit = 1 ] || extra+="  $g"$'\n'
done <<<"$got"
[ -n "$extra" ] && printf -- '--- patched but not in the list (add it if it is new):\n%s' "$extra"
warn=$(grep -E '^(WARNING|ERROR|note)' "$L" | grep -Ev "$BENIGN")
[ -n "$warn" ] && { echo "--- warnings to read:"; echo "$warn" | sed 's/^/  /'; }
echo "---- $miss missing"
[ "$miss" = 0 ]
