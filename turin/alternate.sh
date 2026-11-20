#!/usr/bin/env bash
# Headroom study: run labelled conditions alternately (A B A B ...) on the iPhone, one warm-up run first.
# usage: alternate.sh NAME ROUNDS "LABEL_A:ENV..." "LABEL_B:ENV..." [...]
#   e.g. alternate.sh t2 4 "ctx4k:MODEL_DIR=bundle" "ctx1k:MODEL_DIR=bundle-1k"
# Common env (TURNS, TURN_IN, TURN_OUT, UI, COMPUTE, ...) comes from the caller.
# A condition may set RUNNER=metal to use the llama.cpp Metal app instead of AneBench.
# Each run's timeline (jsonl), summary json and log land in results/NAME/; index.tsv lists them.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ANE_RUN="$HERE/../ios-app/run.sh"
METAL_DIR="$HERE/../../llama.cpp"
NAME="$1"; ROUNDS="$2"; shift 2
OUT="$HERE/results/$NAME"; mkdir -p "$OUT"
IDX="$OUT/index.tsv"
[[ -f "$IDX" ]] || printf 'ts\tround\tlabel\trc\twired\tthermal_before\tresults\tlog\n' > "$IDX"

wired() { xcrun devicectl device info details --device "${DEVICE_ID:-C3AD8B4D-6ACE-58DD-BFD7-036A64A40BAC}" 2>/dev/null | awk '/transportType:/ {print $NF}'; }

run_one() {  # round label envspec
    local round="$1" label="$2" spec="$3" ts log res runner=ane w
    ts="$(date +%Y%m%d-%H%M%S)"
    log="$OUT/$round-$label-$ts.log"; res="$OUT/$round-$label-$ts.json"
    w="$(wired)"
    if [[ "$w" != wired ]]; then echo "ARTEMIS_ERROR transport is '$w', not wired" | tee "$log"; printf '%s\t%s\t%s\t%s\t%s\t\t%s\t%s\n' "$ts" "$round" "$label" 99 "$w" "$res" "$log" >> "$IDX"; return 1; fi
    case " $spec " in *" RUNNER=metal "*) runner=metal ;; esac
    echo "$(date +%T) start $round $label ($spec)"
    if [[ $runner == metal ]]; then
        (cd "$METAL_DIR" && env $spec RESULTS="$res" scripts/artemis-ios/run.sh session) > "$log" 2>&1
    else
        env $spec RESULTS="$res" "$ANE_RUN" session > "$log" 2>&1
    fi
    local rc=$?
    printf '%s\t%s\t%s\t%s\t%s\t\t%s\t%s\n' "$ts" "$round" "$label" "$rc" "$w" "$res" "$log" >> "$IDX"
    echo "$(date +%T) end $round $label rc=$rc $(grep -oE 'tg_tps[^ ]*|session_s=[0-9.]+' "$log" | tr '\n' ' ')"
}

# warm-up: first condition once, discarded
first="$1"; run_one warmup "${first%%:*}" "${first#*:}"
for ((r = 1; r <= ROUNDS; r++)); do
    for c in "$@"; do run_one "r$r" "${c%%:*}" "${c#*:}"; done
done
echo ALLDONE
