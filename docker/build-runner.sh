#!/usr/bin/env bash
# =============================================================================
# build-runner.sh — a build loop that survives the night.
#
#     ./docker/build-runner.sh            start it (detached; returns immediately)
#     ./docker/build-runner.sh status     what is it doing
#     ./docker/build-runner.sh stop       kill the loop and the container
#
# WHY THIS EXISTS: `mka bacon` is a 150,000-target, many-hour build on this host,
# and two separate things kill it part-way:
#
#   1. Rosetta segfaults host tools at random. Confirmed spurious: an aprotoc that
#      died mid-build then compiled the same .proto 5/5 times by hand.
#   2. Under macOS memory pressure, background tasks get culled -- including a
#      trivial polling loop, so footprint is not the criterion. When the monitoring
#      client dies the build keeps running but nothing is watching it, and a real
#      failure then sits unnoticed for hours.
#
# So: run detached via setsid+nohup so it is a plain OS process rather than a
# managed background task, retry automatically, and leave a status file behind.
#
# RETRY POLICY: a failure is retried, EXCEPT when the same target fails twice in a
# row -- that is a real error and retrying it just burns another Soong/Kati run.
# Because out/ lives in the docker volume, a retry resumes where it stopped and
# costs only the ~20 minute re-analysis, never the compiled objects.
# =============================================================================
set -uo pipefail

PROFILE=warhol-los
IMAGE=lineage-warhol-build
CONTAINER=warhol-los-build
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTDIR=/Users/local/git/android/out
LOG="$OUTDIR/los-build-run.log"
STATUS="$OUTDIR/los-build-status.txt"
PIDFILE="$OUTDIR/los-build-runner.pid"
MAXTRIES=12
export DOCKER_HOST="unix://$HOME/.colima/$PROFILE/docker.sock"

case "${1:-start}" in
status)
    echo "--- status ---"; cat "$STATUS" 2>/dev/null || echo "(none)"
    echo "--- runner ---"
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "runner alive (pid $(cat "$PIDFILE"))"
    else
        echo "runner not running"
    fi
    echo "--- container ---"
    docker ps -a --filter "name=$CONTAINER" --format '{{.Status}}' 2>/dev/null || true
    echo "--- last progress ---"
    grep -a -oE '^\[ *[0-9]+% [0-9]+/[0-9]+\]' "$LOG" 2>/dev/null | tail -1
    grep -a -E '^FAILED:|failed to build some targets|build completed successfully' "$LOG" 2>/dev/null | tail -3
    exit 0 ;;
stop)
    [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null && echo "runner stopped"
    docker rm -f "$CONTAINER" >/dev/null 2>&1 && echo "container removed"
    rm -f "$PIDFILE"
    exit 0 ;;
_loop) ;;   # internal
start)
    mkdir -p "$OUTDIR"
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "already running (pid $(cat "$PIDFILE"))"; exit 0
    fi
    # Detach from this shell AND from the agent harness so the loop is an ordinary
    # orphaned process rather than a managed task. macOS has no setsid, so use the
    # portable trick: background inside a subshell that then exits, which reparents
    # the child to init. The loop writes its own pid to PIDFILE.
    rm -f "$PIDFILE"
    ( nohup "$0" _loop >>"$LOG" 2>&1 & )
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ -s "$PIDFILE" ] && break
        sleep 1
    done
    if [ -s "$PIDFILE" ]; then
        echo "runner started (pid $(cat "$PIDFILE")) -- ./docker/build-runner.sh status"
    else
        echo "runner FAILED to start; see $LOG" >&2; exit 1
    fi
    exit 0 ;;
*)
    echo "usage: $0 [start|status|stop]" >&2; exit 1 ;;
esac

# ── the loop ─────────────────────────────────────────────────────────────────
echo $$ > "$PIDFILE"
prev_fail=""
for try in $(seq 1 $MAXTRIES); do
    echo "=== attempt $try  $(date) ===" >>"$LOG"
    printf 'state=running attempt=%s started=%s\n' "$try" "$(date)" >"$STATUS"

    # If a container is already running (e.g. a previous monitoring client was
    # killed but the build itself survived), adopt it rather than starting a
    # second build over the same out/ tree.
    if [ "$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null)" = "running" ]; then
        echo "  adopting the running container" >>"$LOG"
    else
        docker rm -f "$CONTAINER" >/dev/null 2>&1
        docker run -d --name "$CONTAINER" --platform linux/amd64 \
            -v lineage-src:/aosp -v lineage-ccache:/ccache \
            -v "$REPO_ROOT:/aosp/device/xiaomi/warhol" \
            -w /aosp "$IMAGE" bash -lc '
set -e
. build/envsetup.sh
lunch lineage_warhol-bp4a-userdebug
mka bacon -j4
' >>"$LOG" 2>&1
    fi

    # Stream progress into the log without holding a big client process.
    docker logs -f "$CONTAINER" 2>&1 | tr '\r' '\n' >>"$LOG" &
    tailpid=$!
    rc=$(docker wait "$CONTAINER" 2>/dev/null || echo 1)
    kill $tailpid 2>/dev/null

    if [ "$rc" = "0" ]; then
        printf 'state=SUCCESS attempt=%s finished=%s\n' "$try" "$(date)" >"$STATUS"
        echo "=== BUILD SUCCEEDED on attempt $try ===" >>"$LOG"
        mkdir -p "$REPO_ROOT/../lineage-out"
        docker cp "$CONTAINER:/aosp/out/target/product/warhol/." "$REPO_ROOT/../lineage-out/" >>"$LOG" 2>&1
        echo "artifacts copied to $REPO_ROOT/../lineage-out" >>"$LOG"
        break
    fi

    fail=$(docker logs "$CONTAINER" 2>&1 | tr '\r' '\n' | grep -a '^FAILED:' | tail -1)
    echo "  attempt $try failed rc=$rc: ${fail:-<no FAILED line>}" >>"$LOG"

    if [ -n "$fail" ] && [ "$fail" = "$prev_fail" ]; then
        printf 'state=FAILED_DETERMINISTIC attempt=%s target=%s\n' "$try" "$fail" >"$STATUS"
        echo "=== same target failed twice; this is a real error, stopping ===" >>"$LOG"
        break
    fi
    prev_fail="$fail"
    printf 'state=retrying attempt=%s last_fail=%s\n' "$try" "${fail:-unknown}" >"$STATUS"
    sleep 20
done
rm -f "$PIDFILE"
