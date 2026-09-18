#!/usr/bin/env bash
# =============================================================================
# prune-tree.sh — reclaim disk in the synced AOSP tree.
#
#     ./docker/prune-tree.sh              show what would be freed
#     ./docker/prune-tree.sh --go         actually delete
#     ./docker/prune-tree.sh --go --aggressive
#     ./docker/prune-tree.sh --go --drop-git    the big one, see below
#
# WHY: a shallow twrp-14.1 sync lands at ~53 GB on this machine, and the Mac only
# has ~59 GiB free for the VM disk to grow into. out/ needs another 10-20 GB.
# Without pruning the build runs the disk to zero mid-link.
#
# ORDER MATTERS: run this AFTER `sync`, never before. `repo sync` checks projects
# out clean, so anything deleted here comes straight back on the next sync.
# Re-run this after any future sync.
#
# What gets removed, and why it is safe for a recovery-only target:
#
#   prebuilts/clang/host/linux-x86/clang-*   all but the version Soong actually
#                                            selects (read live from
#                                            build/soong/cc/config/global.go) and
#                                            clang-stable. AOSP ships five older
#                                            toolchains for other branches; this
#                                            build compiles with exactly one, and
#                                            TARGET_NO_KERNEL means we never build
#                                            a kernel with an older one either.
#
#   prebuilts/abi-dumps                      (--drop-abi-dumps) reference ABI dumps
#                                            consumed by header-abi-diff. This was
#                                            safe to drop for the TWRP recovery
#                                            target, which never ran those checks.
#                                            A full LineageOS build is a different
#                                            question -- VNDK is gone in Android 16,
#                                            but nothing here has PROVEN the checks
#                                            never run. So it is behind its own flag
#                                            now, not --aggressive. Try a build
#                                            without it first; 4 GB is not the win
#                                            that --drop-git is.
#
#   prebuilts/**/darwin-x86                  macOS host toolchains. We build in a
#                                            linux/amd64 container. (--aggressive.)
#
#   .repo/project-objects                    (--drop-git) BY FAR the biggest win.
#         Measured on this tree: 57 GB of git objects backing a 29 GB working
#         tree. A build reads checked-out FILES; it never reads git history.
#         Deleting this leaves every working tree intact and fully buildable.
#
#         THE TRADE: `repo sync` can no longer work incrementally — a later sync
#         re-clones from scratch. Do this once the tree is complete and you are
#         in build-iterate mode. Verify completeness first:
#             repo sync -c -j4 --no-clone-bundle --no-tags   # must come back clean
# =============================================================================
set -euo pipefail

PROFILE=warhol-los
GO=0; AGGRESSIVE=0; DROPGIT=0; DROPABI=0
for a in "$@"; do
    case "$a" in
        --go) GO=1 ;;
        --aggressive) AGGRESSIVE=1 ;;
        --drop-git) DROPGIT=1 ;;
        --drop-abi-dumps) DROPABI=1 ;;
        *) echo "unknown flag: $a" >&2; exit 1 ;;
    esac
done

export DOCKER_HOST="unix://$HOME/.colima/$PROFILE/docker.sock"
IMAGE=lineage-warhol-build

docker run --rm -i --platform linux/amd64 -v lineage-src:/aosp -w /aosp "$IMAGE" \
    bash -s -- "$GO" "$AGGRESSIVE" "$DROPGIT" "$DROPABI" <<'INNER'
set -euo pipefail
GO="$1"; AGGRESSIVE="$2"; DROPGIT="$3"; DROPABI="$4"
total=0

plan() {   # plan <path> <reason>
    [ -e "$1" ] || return 0
    local sz; sz=$(du -sm "$1" 2>/dev/null | cut -f1)
    total=$((total + sz))
    printf '  %6s MB  %-58s %s\n' "$sz" "$1" "$2"
    [ "$GO" = 1 ] && rm -rf "$1"
    return 0
}

echo "=== clang toolchains ==="
# The build pins clang versions in MORE THAN ONE PLACE. Reading only
# ClangDefaultVersion is how this script broke a build at 12%:
#
#   build/soong/cc/config/global.go:  ClangDefaultVersion = "clang-r563880c"
#   build/soong/rust/bindgen.go:      bindgenClangVersion = "clang-r563880"
#
# bindgen needs libclang.so out of ITS pin, which is a different directory from the
# one the C++ compiler uses, so 18,000 targets built fine and then bindgen died with
#   Unable to find libclang: couldn't find any valid shared libraries ...
#
# So: derive the keep-set from every version the build actually names -- Go
# assignments anywhere under build/soong, plus the release-config flag values --
# not from one variable.
KEEP_DEFAULT=$(grep -m1 'ClangDefaultVersion *=' build/soong/cc/config/global.go | sed 's/.*"\(.*\)".*/\1/')
{
    echo "$KEEP_DEFAULT"
    echo "clang-stable"
    # Go assignments: `foo = "clang-rNNNNNN"`. Skip comment lines, which mention
    # old versions purely as history.
    grep -rhE '^[^/]*=[[:space:]]*"clang-r[0-9]+[a-z]?"' build/soong --include=*.go 2>/dev/null \
        | grep -oE 'clang-r[0-9]+[a-z]?'
    # Release configs can override the compiler version per release.
    grep -rhoE 'clang-r[0-9]+[a-z]?' build/release/flag_values/*/RELEASE_BUILD_CLANG_VERSION.textproto 2>/dev/null
} | sort -u > /tmp/clang_keep.txt

echo "  keeping the versions the build actually names:"
sed 's/^/    /' /tmp/clang_keep.txt
for d in prebuilts/clang/host/linux-x86/clang-*; do
    b=$(basename "$d")
    grep -qx "$b" /tmp/clang_keep.txt && continue
    plan "$d" "unreferenced toolchain"
done

# If a pin names a toolchain that is already gone -- e.g. this script deleted it
# under the old, wrong keep-set -- retarget the pin at a version we do have rather
# than re-downloading ~4 GB. Respins of one release (r563880 vs r563880c) share a
# libclang ABI, so this is safe for bindgen's header parsing.
if [ "$GO" = 1 ]; then
    while read -r want; do
        [ -d "prebuilts/clang/host/linux-x86/$want" ] && continue
        [ "$want" = "clang-stable" ] && continue
        echo "  !! $want is pinned but missing; retargeting pins to $KEEP_DEFAULT"
        grep -rlE "\"$want\"" build/soong --include=*.go 2>/dev/null | while read -r f; do
            sed -i "s/\"$want\"/\"$KEEP_DEFAULT\"/g" "$f"
            echo "     patched $f"
        done
    done < /tmp/clang_keep.txt
fi

# prebuilts/clang/host/linux-x86/Android.bp carries a Trusty-only dirgroup that
# enumerates clang versions BY NAME. Soong stats every directory in a dirgroup
# during analysis, so deleting a toolchain listed there fails the build before it
# compiles anything:
#
#   error: module "trusty_dirgroup_prebuilts_clang_host_linux-x86":
#          prebuilts/clang/host/linux-x86/clang-r547379: no such file or directory
#
# The dirgroup is visible only to //trusty/vendor/google/aosp/scripts and is used
# to build Trusty, the TEE OS, which this target does not build. So drop the
# now-missing entries from the list rather than keeping 7.5 GB of toolchain for a
# component we never build. (repo sync restores the file; re-run this after.)
if [ "$GO" = 1 ] && [ -f prebuilts/clang/host/linux-x86/Android.bp ]; then
    python3 - <<'PYEOF'
import os, re
p = "prebuilts/clang/host/linux-x86/Android.bp"
base = os.path.dirname(p)
src = open(p).read()

def fix(m):
    body = m.group(2)
    kept = [d for d in re.findall(r'"([^"]+)"', body)
            if os.path.isdir(os.path.join(base, d))]
    NL = chr(10)
    inner = "".join('        "%s",' % d + NL for d in kept)
    return "%sdirs: [" % m.group(1) + NL + inner + "    ]"

out = re.sub(r'(dirgroup \{[^}]*?)dirs: \[(.*?)\]', fix, src, flags=re.S)
if out != src:
    open(p, "w").write(out)
    print("  patched dirgroup in %s to drop pruned toolchains" % p)
PYEOF
fi

if [ "$AGGRESSIVE" = 1 ]; then
    echo "=== aggressive ==="
    : # abi-dumps is NOT removed here -- see --drop-abi-dumps below.
    # NOT prebuilts/misc/darwin-x86: it is ~1 MB and prebuilts/misc/Android.bp's
    # license module references prebuilts/misc/darwin-x86/yasm/COPYING, so deleting
    # it fails the build with
    #   module "prebuilts_misc_license": module source path ... does not exist
    # The darwin trees worth removing are jdk/build-tools/clang-tools (hundreds of MB).
    while IFS= read -r d; do
        case "$d" in prebuilts/misc/darwin-x86) continue ;; esac
        plan "$d" "macOS host toolchain"
    done < <(find prebuilts -maxdepth 4 -type d -name 'darwin-x86' 2>/dev/null)
fi

if [ "$DROPABI" = 1 ]; then
    echo "=== abi reference dumps ==="
    plan prebuilts/abi-dumps "ABI reference dumps consumed by header-abi-diff"
fi

if [ "$DROPGIT" = 1 ]; then
    echo "=== git object store ==="
    plan .repo/project-objects "git history; a build never reads it (one-way: future syncs re-clone)"
    plan .repo/TRACE_FILE "repo trace log"
fi

echo
if [ "$GO" = 1 ]; then
    echo "FREED ~${total} MB"
    echo "NOTE: prebuilts/clang and friends are now dirty working trees. That is"
    echo "      expected. A future 'repo sync' restores them — re-run this after."
else
    echo "WOULD FREE ~${total} MB   (re-run with --go to do it)"
fi
echo
echo "=== tree size now ==="; du -sh /aosp
INNER

# Deleting inside the guest does NOT shrink the VM's disk file on the host — the
# sparse file keeps every block it ever touched. fstrim hands the freed blocks
# back. Measured: 81 GB -> 43 GB host-side, i.e. 39 GiB returned, from a prune
# that had already "freed" the space inside the guest.
if [ "$GO" = 1 ]; then
    echo "=== fstrim (returns freed blocks to the host disk image) ==="
    before=$(du -sm "$HOME/.colima/_lima/_disks/colima-$PROFILE" 2>/dev/null | cut -f1)
    colima ssh -p "$PROFILE" -- sudo fstrim -v /var/lib/docker 2>&1 | tail -2
    after=$(du -sm "$HOME/.colima/_lima/_disks/colima-$PROFILE" 2>/dev/null | cut -f1)
    [ -n "$before" ] && [ -n "$after" ] && echo "  host disk image: ${before} MB -> ${after} MB"
    df -h "$HOME" | tail -1
fi
