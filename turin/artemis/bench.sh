#!/usr/bin/env bash
# Benchmark: one 10-turn session from thermal state 0; writes artemis_results.json at the repo root
# (tg_tps, ttft_ms_p50, prefill_tps, mem_peak_mb, thermal_max, ...). Re-checks correctness.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/common.sh"
check_wired
out="$(mktemp)"
THERMAL_START=0 RESULTS="$REPO/artemis_results.json" "$APP/run.sh" session > "$out" 2>&1 || { tail -20 "$out"; exit 1; }
grep -vE '^ARTEMIS_INFO reply' "$out"
python3 -I "$HERE/gate.py" "$HERE/ref-replies.txt" "$out" || { rm -f "$REPO/artemis_results.json"; exit 1; }
