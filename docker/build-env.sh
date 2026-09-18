#!/usr/bin/env bash
# =============================================================================
# build-env.sh — LineageOS 23 build environment for warhol on an Apple Silicon Mac.
#
#   ./docker/build-env.sh up      colima (vz + Rosetta) + the linux/amd64 image
#   ./docker/build-env.sh sync    repo init + sync lineage-23.2  (~100 GB, once)
#   ./docker/build-env.sh config  lunch + m nothing; validates the device tree fast
#   ./docker/build-env.sh shell   drop into the container
#   ./docker/build-env.sh build   breakfast + brunch warhol
#   ./docker/build-env.sh df      disk accounting
#   ./docker/build-env.sh down    stop colima
#
# Adapted from the TWRP build environment for this device, which is where the
# non-obvious settings below were learned the hard way (see that tree's
# BUILDING.md).
# =============================================================================
set -euo pipefail

PROFILE=warhol-los
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE=lineage-warhol-build
BRANCH=lineage-23.2

CPUS="${CPUS:-8}"
# 20 GiB is NOT enough — soong_build gets OOM-killed mid-analysis and the log says
# only "Killed". But do not starve the host either: on a 36 GiB Mac, leaving less
# than ~12 GiB free got builds killed from the HOST side (a browser holding several
# GB was enough). 24 + an in-VM swapfile is the balance.
MEM="${MEM:-24}"
DISK="${DISK:-140}"     # sparse; a Lineage tree is larger than TWRP's

dockerenv() { export DOCKER_HOST="unix://$HOME/.colima/$PROFILE/docker.sock"; }

cmd_up() {
    if colima status -p "$PROFILE" >/dev/null 2>&1; then
        echo "colima profile '$PROFILE' already running"
    else
        colima start -p "$PROFILE" --vm-type vz --vz-rosetta \
            --cpu "$CPUS" --memory "$MEM" --disk "$DISK" \
            --mount-type virtiofs --mount "$REPO_ROOT:w"
    fi
    # Let soong_build's analysis peak spill instead of dying.
    colima ssh -p "$PROFILE" -- sudo sh -c '
        if [ ! -f /var/lib/swapfile ]; then
            fallocate -l 16G /var/lib/swapfile 2>/dev/null || \
              dd if=/dev/zero of=/var/lib/swapfile bs=1M count=16384 status=none
            chmod 600 /var/lib/swapfile; mkswap /var/lib/swapfile >/dev/null 2>&1
        fi
        swapon /var/lib/swapfile 2>/dev/null; sysctl -w vm.swappiness=10 >/dev/null' 2>/dev/null || true
    dockerenv
    docker run --rm --platform linux/amd64 ubuntu:22.04 uname -m | grep -q x86_64 \
        && echo "  linux/amd64 via Rosetta: OK" || { echo "  amd64 not working"; exit 1; }
    docker build --platform linux/amd64 -t "$IMAGE" "$REPO_ROOT/docker"
    echo; echo "Ready. Next: ./docker/build-env.sh sync"
}

run() {
    dockerenv
    local TTY=(-i); [ -t 1 ] && TTY=(-it)
    docker run --rm "${TTY[@]}" --platform linux/amd64 \
        -v lineage-src:/aosp -v lineage-ccache:/ccache \
        -v "$REPO_ROOT:/device_tree" \
        -v "$REPO_ROOT/docker/scripts:/scripts:ro" \
        -w /aosp "$IMAGE" bash -lc "$1"
}

cmd_sync() {
    run "
set -e
if [ ! -d .repo ]; then
  repo init --depth=1 -u https://github.com/LineageOS/android.git -b $BRANCH --git-lfs
fi
# -j4, not \$(nproc): the mirrors refuse connections under high concurrency and
# repo reports 'Connection refused' for a scattered handful of projects.
for a in 1 2 3 4; do
  echo \"=== repo sync attempt \$a ===\"
  repo sync -c -j4 --force-sync --no-clone-bundle --no-tags --optimized-fetch --prune && break
  echo '=== retrying in 20s ==='; sleep 20
done
# Fail loudly rather than let a half-synced tree reach the build.
repo sync -c -j4 --no-clone-bundle --no-tags --optimized-fetch >/dev/null 2>&1 || {
  echo '!!! sync STILL incomplete' >&2; exit 1; }
# The device tree is bind-mounted, not symlinked: build/make finds AndroidProducts.mk
# with \`find\`, which does not descend into symlinked directories.
mkdir -p device/xiaomi
echo; echo '=== tree size ==='; du -sh /aosp
"
}

cmd_shell() { run "exec bash"; }

# Config-only check. `lunch` + `m nothing` runs the whole product-config and Soong
# analysis without compiling anything, so device-tree mistakes (readonly PRODUCT_*
# assignments, missing files, bad inherits) surface in a couple of minutes instead
# of part-way through a multi-hour bacon. Run this after every device-tree edit.
cmd_config() {
    dockerenv
    docker rm -f warhol-los-cfg >/dev/null 2>&1 || true
    docker run --rm --name warhol-los-cfg --platform linux/amd64 \
        -v lineage-src:/aosp -v lineage-ccache:/ccache \
        -v "$REPO_ROOT:/aosp/device/xiaomi/warhol" \
        -w /aosp "$IMAGE" bash -lc '
set -e
. build/envsetup.sh
lunch lineage_warhol-bp4a-userdebug
echo "=== LUNCH OK ==="
m nothing
echo "=== CONFIG OK ==="
'
}

cmd_build() {
    dockerenv
    docker rm -f warhol-los-build >/dev/null 2>&1 || true
    docker run --name warhol-los-build --platform linux/amd64 \
        -v lineage-src:/aosp -v lineage-ccache:/ccache \
        -v "$REPO_ROOT:/aosp/device/xiaomi/warhol" \
        -w /aosp "$IMAGE" bash -lc '
set -e
. build/envsetup.sh
lunch lineage_warhol-bp4a-userdebug
# -j4 under Rosetta: at higher parallelism individual clang processes die
# silently (bare FAILED:, no diagnostic, no OOM, and the file compiles by hand).
mka bacon -j4
'
    echo "=== copying the build out ==="
    mkdir -p "$REPO_ROOT/../lineage-out"
    docker cp warhol-los-build:/aosp/out/target/product/warhol/. "$REPO_ROOT/../lineage-out/" 2>/dev/null || true
    docker rm -f warhol-los-build >/dev/null 2>&1 || true
    ls -la "$REPO_ROOT/../lineage-out"/*.zip 2>/dev/null || echo "  (no zip produced)"
}

cmd_df() {
    dockerenv
    echo "=== host ==="; df -h "$HOME" | tail -1
    colima ssh -p "$PROFILE" -- df -h /var/lib/docker 2>/dev/null | tail -1
    echo "host VM image: $(du -sh "$HOME/.colima/_lima/_disks/colima-$PROFILE" 2>/dev/null | cut -f1)"
}

cmd_down() { colima stop -p "$PROFILE"; }

case "${1:-}" in
    up) cmd_up ;; sync) cmd_sync ;; shell) cmd_shell ;;
    build) cmd_build ;; config) cmd_config ;; df) cmd_df ;; down) cmd_down ;;
    *) sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
