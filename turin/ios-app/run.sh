#!/usr/bin/env bash
# Drive the Core ML / Neural Engine session benchmark (AneBench) on a USB-connected iPhone.
# Mirrors llama.cpp/scripts/artemis-ios/run.sh and scores turns with its session_report.py.
#
# usage: run.sh build     build and install the app (bundles ../models/bundle; turin/models links to the runner model store)
#        run.sh session   one session; metrics to RESULTS, timeline and chart in results/
#
# env: DEVELOPMENT_TEAM, RESULTS, DEVICE_ID; passed to the app: TURNS TURN_IN TURN_OUT
#      THERMAL_START COOL_TIMEOUT_S UI UI_LOAD COMPUTE (ane|gpu|all); UI_DROP_CAP (default 15)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TT_DIR="${TT_DIR:-/Users/victornoorani/Projects/Turin_Tech}"
REPORT="$TT_DIR/llama.cpp/scripts/artemis-ios/session_report.py"
RESULTS="${RESULTS:-$PWD/artemis_results.json}"
BUNDLE_ID=com.victornoorani.anebench
DEVICE_ID="${DEVICE_ID:-$(xcrun devicectl list devices 2>/dev/null | grep iPhone | grep -E 'available|connected' | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -1 || true)}"
: "${DEVICE_ID:?no available iPhone found}"
mkdir -p "$HERE/results"
STAMP="$(date +%Y%m%d-%H%M%S)"

build() {
    local log="$HERE/results/build-$STAMP.log" udid
    udid="$(xcrun devicectl device info details --device "$DEVICE_ID" 2>/dev/null | awk '/udid:/ {print $NF}')"
    (cd "$HERE" && xcodebuild build \
        -project AneBench.xcodeproj -scheme AneBench -configuration Release \
        -destination "id=$udid" -derivedDataPath "$HERE/.build" \
        -allowProvisioningUpdates DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-63CZA36J6Z}") \
        > "$log" 2>&1 || { grep -E "error:" "$log" | head -20 || true; echo "build failed: $log" >&2; return 1; }
    xcrun devicectl device install app --device "$DEVICE_ID" \
        "$HERE/.build/Build/Products/Release-iphoneos/AneBench.app" >> "$log" 2>&1 \
        || { tail -20 "$log"; echo "install failed: $log" >&2; return 1; }
    echo "installed AneBench"
}

launch() {
    local log="$HERE/results/$1-$STAMP.log" v
    local -a vars=()
    for v in TURNS TURN_IN TURN_OUT THERMAL_START COOL_TIMEOUT_S UI UI_LOAD COMPUTE PROFILE MODEL_DIR SPLIT_FFN SPLIT_DIR; do
        [[ -n "${!v:-}" ]] && vars+=("DEVICECTL_CHILD_$v=${!v}")
    done
    env ${vars[@]+"${vars[@]}"} \
        xcrun devicectl device process launch --device "$DEVICE_ID" --console --terminate-existing \
        "$BUNDLE_ID" > "$log" 2>&1 || true
    if grep -q 'reason: Locked' "$log"; then
        echo "ARTEMIS_ERROR iPhone is locked; unlock it (and set Auto-Lock to Never while benchmarking)"
        return 1
    fi
    grep -E '^ARTEMIS_(INFO|METRIC|ERROR|TURN)' "$log" || { tail -20 "$log"; echo "no output from app, full log: $log" >&2; return 1; }
    ! grep -q '^ARTEMIS_ERROR' "$log"
}

session() {
    rm -f "$RESULTS"
    local out timeline="$HERE/results/session-${COMPUTE:-ane}-$STAMP.jsonl"
    out="$(launch session)" || { printf '%s\n' "$out" | grep -v '^ARTEMIS_TURN'; return 1; }
    printf '%s\n' "$out" | grep -v '^ARTEMIS_TURN'
    printf '%s\n' "$out" | sed -n 's/^ARTEMIS_TURN //p' > "$timeline"
    local -a ui_args=(--ui-drop-cap "${UI_DROP_CAP:-15}")
    [[ "${UI:-1}" == 0 ]] && ui_args=(--no-ui)
    python3 -I "$REPORT" "$timeline" --results "$RESULTS" "${ui_args[@]}" \
        --title "Qwen3-1.7B Core ML (${COMPUTE:-ane}) · ${TURNS:-10}-turn conversation"
}

case "${1:-}" in
    build) build ;;
    session) session ;;
    *) sed -n '2,9p' "$0"; exit 2 ;;
esac
