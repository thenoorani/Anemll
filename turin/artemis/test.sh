#!/usr/bin/env bash
# Setup 2: correctness gate. Runs the benchmark session once (also the discarded warm-up) and requires
# every turn's greedy tokens to equal the 4k baseline's (ref-replies.txt).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/common.sh"
check_wired
out="$(mktemp)"
THERMAL_START=0 RESULTS="$(mktemp)" "$APP/run.sh" session > "$out" 2>&1 || { tail -20 "$out"; exit 1; }
python3 -I "$HERE/gate.py" "$HERE/ref-replies.txt" "$out"
