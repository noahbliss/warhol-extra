#!/usr/bin/env bash
# =============================================================================
# pipeline.sh — run sync -> config -> build to completion, unattended.
#
# Each stage is idempotent and retried. The point is that nobody has to babysit
# this: it either reaches a flashable zip or it stops on a real error, and either
# way STATUS says which, so a watcher can tell "still working" from "finished" from
# "broken" without reading logs.
#
# Retry policy: retry a failed stage, EXCEPT when the same target fails twice in a
# row -- that is deterministic and retrying only burns another Soong analysis.
# =============================================================================
set -uo pipefail

P=/run/media/local/4TB/warhol-los
STATUS=$P/out/STATUS
LOG=$P/out/pipeline.log
MAXTRIES=8

mkdir -p "$P/out"
say() { printf '%s\n' "$*" >>"$LOG"; }
setst() { printf '%s\n' "$*" >"$STATUS"; }

stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

run_stage() {           # run_stage <name> <max_tries>
    local name="$1" tries="$2" prev_fail="" prev_sig="" i rc fail sig
    for i in $(seq 1 "$tries"); do
        setst "stage=$name state=running attempt=$i since=$(stamp)"
        say "=== $name attempt $i $(stamp) ==="
        # Remember where this attempt starts. Scanning the WHOLE log for errors
        # matches stale ones from earlier attempts -- that is how a build.prop
        # failure got misreported as the previous attempt's metalava OOM, and sent
        # the diagnosis chasing memory instead of a bad makefile key.
        local start_line; start_line=$(wc -l <"$LOG")
        "$P/remote-build.sh" "$name" >>"$LOG" 2>&1
        rc=$?
        if [ $rc -eq 0 ]; then
            setst "stage=$name state=ok attempt=$i at=$(stamp)"
            say "=== $name OK ==="
            return 0
        fi
        fail=$(tail -n +$((start_line+1)) "$LOG" | grep -aE '^FAILED:' | tail -1)
        # Compare the ERROR too, not just the failing path. Three build attempts
        # once died on three different metalava targets from one root cause (a
        # podman 2048-PID cap surfacing as OutOfMemoryError), and a same-path
        # check saw three unrelated flakes. The error signature catches the class.
        sig=$(tail -n +$((start_line+1)) "$LOG" \
              | grep -aoE "isn't a valid prop override|OutOfMemoryError[^\"]*|pthread_create failed[^ ]*|error: [^ ]+|Segmentation fault|No space left on device" \
              | tail -1 | cut -c1-80)
        say "=== $name attempt $i failed rc=$rc: ${fail:-<no FAILED line>} ==="
        [ -n "$sig" ] && say "    signature: $sig"
        if [ -n "$sig" ] && [ "$sig" = "$prev_sig" ]; then
            setst "stage=$name state=failed_deterministic attempt=$i at=$(stamp) signature=${sig}"
            say "=== same error signature twice; real error, stopping ==="
            return 1
        fi
        prev_sig="$sig"
        if [ -n "$fail" ] && [ "$fail" = "$prev_fail" ]; then
            setst "stage=$name state=failed_deterministic attempt=$i at=$(stamp) detail=${fail:0:160}"
            say "=== same target failed twice; real error, stopping ==="
            return 1
        fi
        prev_fail="$fail"
        setst "stage=$name state=retrying attempt=$i at=$(stamp) detail=${fail:0:160}"
        sleep 20
    done
    setst "stage=$name state=failed_exhausted at=$(stamp)"
    return 1
}

run_stage sync   4 || exit 1
run_stage config 2 || exit 1
run_stage build  $MAXTRIES || exit 1

ZIP=$(ls -1 "$P/src/out/target/product/warhol/"*.zip 2>/dev/null | head -1)
setst "stage=done state=SUCCESS at=$(stamp) zip=${ZIP:-none}"
say "=== PIPELINE COMPLETE: ${ZIP:-no zip found} ==="
