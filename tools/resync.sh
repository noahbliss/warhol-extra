#!/bin/bash
# Bring an existing warhol tree up to date with upstream LineageOS on the SAME branch.
# This replaces `remote-build.sh sync`, which is only safe for a brand-new tree.
#
#     bash resync.sh --check    report what a resync would do; changes nothing
#     bash resync.sh            snapshot, stash, sync, re-pin (or: remote-build.sh resync)
#     bash resync.sh --snapshot           only write rollback/<stamp>/project-heads.txt
#     bash resync.sh --restore <file>     check every project out at the HEAD in that file
#
# What it does, in order:
#   1. Snapshot every project's HEAD to rollback/<stamp>/project-heads.txt. To roll the
#      tree back: resync.sh --restore rollback/<stamp>/project-heads.txt
#   2. Stash every dirty project, submodules first (repo refuses to check out over local
#      changes). patch_tree's edits are what make projects dirty. They are not lost: the
#      next build re-applies them from warhol-extra/patches/tree. The stashes are kept as
#      warhol-pre-resync-<stamp> in case something was edited by hand.
#   3. repo sync, retried. It runs inside the build container, the only place repo and
#      git-lfs exist; on the host the chromium-webview LFS prebuilts falsely look modified.
#   4. Pin OpenEUICC back to the revision the eSIM patches were validated on
#      (WARHOL_OPENEUICC_PIN). The local manifest follows its master branch.
# It never touches .repo/local_manifests, and it refuses to run while Launcher3 has the
# advanced-grid branch checked out (repo would try to rebase that branch).
set -euo pipefail
P="${WARHOL_ROOT:-/run/media/local/4TB/warhol-los-24}"
REL="${WARHOL_RELEASE:-cp2a}"
AG_BRANCH="${WARHOL_ADVGRID_BRANCH:-lineage-24.0}"
PIN="${WARHOL_OPENEUICC_PIN:-9a537a2}"
IMAGE=lineage-warhol-build
MODE="${1:-sync}"
case "$MODE" in sync|--check|--snapshot) ;; --restore) HEADS="${2:?usage: resync.sh --restore <project-heads.txt>}" ;;
    *) echo "usage: resync.sh [--check | --snapshot | --restore <project-heads.txt>]" >&2; exit 1 ;; esac
CHECK=0; [ "$MODE" = --check ] && CHECK=1
STAMP=$(date +%Y%m%d-%H%M)
die() { echo "ABORT: $*" >&2; exit 1; }
export CONTAINERS_STORAGE_CONF="$P/containers/storage.conf" TMPDIR="$P/tmp"

mountpoint -q /run/media/local/4TB || die "4TB is not mounted"
[ -d "$P/src/.repo" ] || die "no tree at $P/src (a first sync is remote-build.sh sync)"
grep -q sepolicy_vndr "$P/src/.repo/local_manifests/"*.xml \
    || die "the local manifest lacks device/mediatek/sepolicy_vndr; a sync would delete it"
[ $CHECK = 1 ] || ! pgrep -f 'soong_ui|mka bacon' >/dev/null || die "a build is running"

run_inner() {   # run $P/tmp/resync-inner.sh in the build container
    podman run --rm -i --pids-limit=0 --ulimit nofile=65536:65536 \
        -e CHECK=$CHECK -e MSG="warhol-pre-resync-$STAMP" -e PIN="$PIN" \
        -v "$P/src:/aosp" -v "$P/device/xiaomi/warhol:/aosp/device/xiaomi/warhol" -v "$P/tmp:/tmp" \
        -w /aosp "$IMAGE" bash -l /tmp/resync-inner.sh </dev/null
}

if [ "$MODE" = --restore ]; then
    [ -f "$HEADS" ] && head -1 "$HEADS" | grep -q '^# manifests ' || die "$HEADS is not a project-heads.txt"
    cp "$HEADS" "$P/tmp/restore-heads.txt"
    cat > "$P/tmp/resync-inner.sh" <<'INNER'
set -u
cd /aosp
bad=0; n=0
# Projects first, then submodules: a parent checkout can move its submodule gitlinks.
for pass in project submodule; do
    while read -r sha kind path; do
        { [ "$pass" = submodule ] && [ "$kind" = submodule ]; } || \
        { [ "$pass" = project ] && [ "$kind" != submodule ]; } || continue
        [ -e "$path/.git" ] || { echo "!!! missing $path"; bad=$((bad+1)); continue; }
        git -C "$path" checkout -q --detach "$sha" 2>/dev/null && n=$((n+1)) \
            || { echo "!!! cannot check out $sha in $path"; bad=$((bad+1)); }
    done < <(grep -v '^#' /tmp/restore-heads.txt)
done
echo "=== restored $n, $bad failed"
[ $bad = 0 ]
INNER
    run_inner && rc=0 || rc=$?
    echo "=== local edits from before the resync are in 'git stash list' as warhol-pre-resync-*"
    exit $rc
fi

L3="$P/src/packages/apps/Launcher3"
git -C "$L3" symbolic-ref -q HEAD >/dev/null \
    && die "Launcher3 has branch $(git -C "$L3" symbolic-ref --short HEAD) checked out; detach it at upstream first"
grep -q ADV_GRID_ENABLED "$L3/src/com/android/launcher3/LauncherPrefs.kt" \
    && die "Launcher3 HEAD contains the advanced-grid feature; check out the upstream revision first"
OLD_L3=$(git -C "$L3" rev-parse HEAD)
SPL_FILE="$P/src/vendor/lineage/release/flag_values/$REL/RELEASE_PLATFORM_SECURITY_PATCH.textproto"
spl() { sed -n 's/.*string_value: *"\([0-9-]*\)".*/\1/p' "$SPL_FILE" 2>/dev/null; }
OLD_SPL=$(spl)

if [ $CHECK = 0 ]; then
    R="$P/rollback/$STAMP"; mkdir -p "$R"
    echo "=== snapshot -> $R/project-heads.txt"
    {
        echo "# manifests $(git -C "$P/src/.repo/manifests" rev-parse HEAD)"
        while read -r p; do
            h=$(git -C "$P/src/$p" rev-parse HEAD 2>/dev/null) || continue
            b=$(git -C "$P/src/$p" symbolic-ref -q --short HEAD 2>/dev/null || echo detached)
            echo "$h $b $p"
        done < "$P/src/.repo/project.list"
        git -C "$P/src/packages/apps/OpenEUICC" submodule status --recursive 2>/dev/null \
            | awk '{sub(/^[-+ U]/, "", $1); print $1, "submodule", "packages/apps/OpenEUICC/" $2}'
    } > "$R/project-heads.txt"
    cp -p "$P/src/.repo/local_manifests/"*.xml "$R/"
    echo "    $(grep -vc '^#' "$R/project-heads.txt") projects recorded"
    [ "$MODE" = --snapshot ] && exit 0
fi

# Runs in the container. Settings arrive through the environment, so no quoting games.
cat > "$P/tmp/resync-inner.sh" <<'INNER'
set -u
cd /aosp
echo "=== dirty projects"
n=0
while read -r p; do
    [ -e "$p/.git" ] || continue
    [ -n "$(git -C "$p" status --porcelain 2>/dev/null)" ] || continue
    n=$((n+1)); echo "    $p"
    [ "$CHECK" = 1 ] && continue
    if [ -f "$p/.gitmodules" ]; then
        git -C "$p" submodule foreach --quiet --recursive \
            'if [ -n "$(git status --porcelain)" ]; then git stash push --include-untracked -q -m "$MSG" && echo "      stashed submodule $displaypath"; fi' \
            || { echo "!!! submodule stash failed in $p"; exit 1; }
    fi
    if [ -n "$(git -C "$p" status --porcelain)" ]; then
        git -C "$p" stash push --include-untracked -q -m "$MSG" || { echo "!!! stash failed: $p"; exit 1; }
        echo "      stashed"
    fi
done < .repo/project.list
echo "    $n dirty"
echo "=== OpenEUICC at $(git -C packages/apps/OpenEUICC rev-parse --short HEAD), pin $PIN"
[ "$CHECK" = 1 ] && exit 0
for a in 1 2 3 4; do
    echo "=== repo sync attempt $a  $(date)"
    repo sync -c -j8 --force-sync --no-clone-bundle --no-tags --optimized-fetch --prune && { echo "=== SYNC OK"; break; }
    [ $a = 4 ] && { echo "!!! repo sync failed 4 times"; exit 1; }
    echo "=== retrying in 20s"; sleep 20
done
echo "=== pin OpenEUICC to $PIN"
git -C packages/apps/OpenEUICC checkout -q --detach "$PIN" || exit 1
git -C packages/apps/OpenEUICC submodule update --init --recursive || exit 1
git -C packages/apps/OpenEUICC submodule status --recursive
INNER

run_inner

if [ $CHECK = 1 ]; then
    echo "=== Launcher3 at ${OLD_L3:0:10} (detached, no feature), SPL in tree $OLD_SPL"
    echo "=== check only: nothing was changed"
    exit 0
fi
NEW_L3=$(git -C "$L3" rev-parse HEAD)
echo
echo "=== resync done"
echo "    manifests  $(git -C "$P/src/.repo/manifests" log -1 --format='%h %cd' --date=short)"
echo "    SPL        $OLD_SPL -> $(spl)"
echo "    Launcher3  ${OLD_L3:0:10} -> ${NEW_L3:0:10}"
echo "    rollback   $R/project-heads.txt"
if [ "$OLD_L3" != "$NEW_L3" ]; then
    echo
    echo "Launcher3 moved. Rebase the advanced-grid branch, then rebuild its module:"
    echo "    git -C $L3 rebase --onto ${NEW_L3:0:10} ${OLD_L3:0:10} $AG_BRANCH"
    echo "    git -C $L3 checkout -q --detach ${NEW_L3:0:10}"
fi
