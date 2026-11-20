#!/usr/bin/env bash
# Setup 1: link the model store, build AneBench against this checkout's AnemllCore, install on the iPhone.
set -euo pipefail
source "$(dirname "$0")/common.sh"
ln -sfn "$MODEL_STORE" "$REPO/turin/models"
check_wired
"$APP/run.sh" build
