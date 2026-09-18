#!/usr/bin/env bash
# Emits one line per meaningful change in the remote build pipeline.
# Coverage matters more than tidiness here: a crashed pipeline, an unreachable
# host and a finished build must all produce output, because silence is
# indistinguishable from "still working".
HOST="${WARHOL_HOST:?set WARHOL_HOST=user@build-host}"
PROBE=/run/media/local/4TB/warhol-los/probe.sh
prev_key=""; fails=0; gone=0

while true; do
    line=$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST" "$PROBE" 2>/dev/null) || line=""
    if [ -z "$line" ]; then
        fails=$((fails+1))
        [ "$fails" = 3 ] && echo "WATCH: build host unreachable (3 consecutive probe failures)"
        sleep 60; continue
    fi
    fails=0

    stage=$(sed -n 's/.*stage=\([^ ]*\).*/\1/p' <<<"$line")
    state=$(sed -n 's/.*state=\([^ ]*\).*/\1/p' <<<"$line")
    alive=$(sed -n 's/.*alive=\([^ ]*\).*/\1/p' <<<"$line")
    pct=$(sed -n 's/.*progress=\([0-9]*\)%.*/\1/p' <<<"$line")
    tree=$(sed -n 's/.*treeMB=\([0-9]*\).*/\1/p' <<<"$line")

    # Bucket the noisy fields so progress reports arrive every ~5% / ~20 GB
    # instead of every poll.
    pb=""; [ -n "$pct" ] && pb=$(( pct / 5 ))
    tb=$(( ${tree:-0} / 20000 ))
    # attempt is part of the key on purpose: three build attempts failed in a row
    # once and produced no notification, because only stage/state/progress were
    # compared and all three stayed the same. A retry is exactly the kind of thing
    # a watcher exists to surface.
    attempt=$(sed -n 's/.*attempt=\([0-9]*\).*/\1/p' <<<"$line")
    key="$stage/$state/$alive/$attempt/$pb/$tb"
    if [ "$key" != "$prev_key" ]; then
        echo "$line"
        prev_key="$key"
    fi

    case "$state" in
        SUCCESS|failed_deterministic|failed_exhausted)
            echo "WATCH: TERMINAL -- $line"; exit 0 ;;
    esac

    # A dead pipeline process with a running status is a crash, not progress.
    if [ "$alive" = "no" ] && [ "$state" = "running" ]; then
        gone=$((gone+1))
        if [ "$gone" -ge 2 ]; then
            echo "WATCH: pipeline process GONE while state=running -- $line"; exit 1
        fi
    else
        gone=0
    fi
    sleep 60
done
