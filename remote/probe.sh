#!/usr/bin/env bash
# One compact line describing the whole pipeline. Consumed by the watcher.
P=/run/media/local/4TB/warhol-los
st=$(cat "$P/out/STATUS" 2>/dev/null || echo "stage=none state=unstarted")
pct=$(grep -aoE "^\[ *[0-9]+% [0-9]+/[0-9]+\]" "$P/out/pipeline.log" 2>/dev/null | tail -1 | tr -d "[]" | tr -s " ")
tree=$(du -sm "$P/src" 2>/dev/null | cut -f1)
free=$(df -m /run/media/local/4TB 2>/dev/null | awk "NR==2{print \$4}")
alive=no; pgrep -f "pipeline.sh" >/dev/null 2>&1 && alive=yes
echo "$st | progress=${pct:-none} | treeMB=${tree:-0} | free4tbMB=${free:-0} | alive=$alive"
