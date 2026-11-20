# Shared by build.sh / test.sh / bench.sh. Model store lives outside Git on the runner.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="$REPO/turin/ios-app"
MODEL_STORE="${MODEL_STORE:-/Users/victornoorani/Projects/Turin_Tech/ane/models}"
DEVICE_ID="${DEVICE_ID:-C3AD8B4D-6ACE-58DD-BFD7-036A64A40BAC}"
export DEVICE_ID
# the session the benchmark and gate both use
export TURNS=10 TURN_IN=256 TURN_OUT=150 UI=0 COMPUTE=ane PROFILE=0 MODEL_DIR="${MODEL_DIR:-bundle}"
check_wired() {
    local t; t="$(xcrun devicectl device info details --device "$DEVICE_ID" 2>/dev/null | awk '/transportType:/ {print $NF}')"
    [[ "$t" == wired ]] || { echo "ARTEMIS_ERROR iPhone transport is '$t', not wired (plug in the USB cable)"; exit 1; }
}
