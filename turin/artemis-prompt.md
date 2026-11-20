# Artemis: faster Qwen3-1.7B inference on the iPhone 16 Neural Engine

Use the Artemis skills (start with `artemis`) to run this as a Discovery run on my Mac runner with the
iPhone 16 on USB.

## Goal

Make multi-turn chat faster on the Neural Engine (ANEMLL / Core ML): decode tokens per second first,
time to first token second, with output unchanged.

## One requirement on the design

The model must ship as ONE packed file that holds several context sizes sharing one copy of the
weights (a coremltools multi-function .mlpackage, which deduplicates identical weights), with the
runtime moving up to a bigger size as the conversation grows. Background: the Neural Engine needs
fixed shapes, so a model compiled for 4,096 tokens pays for all 4,096 KV slots on every decode step.
Measured: a 1k-context model decodes at 37.3 tok/s vs 14.4 for 4k on the same short chat, with
identical output. Everything else (sizes, switching, runtime code, CPU-side work) is open.

## What exists

- ANEMLL 0.3.5 clone: `ane/src/Anemll` (Git). Swift runtime: `anemll-swift-cli/Sources/AnemllCore`,
  with uncommitted local changes (`startPos` on `runPrefill`, `inferComputeUnits` and `splitFFNDir` in
  `ModelLoader.Configuration`, `StepProfiler.swift`).
- Conversion: `anemll/utils/convert_model.sh`; activate `ane/venv` first. HF weights `ane/hf/Qwen3-1.7B`.
  Settings: `--batch 64 --lut2 4 --lut3 6 --chunk auto`. About 30 minutes per conversion: cache outputs.
- iOS app: `ane/ios-app` (not in Git). `./run.sh build`, then `./run.sh session`. Env: TURNS, TURN_IN,
  TURN_OUT, THERMAL_START, COMPUTE, UI, PROFILE (per-step timing), MODEL_DIR. Writes a results JSON.

## Benchmark

One measurement = one 10-turn session: TURNS=10 TURN_IN=256 TURN_OUT=150 UI=0 COMPUTE=ane
THERMAL_START=0. Baseline and candidate measured the same number of times (at least 3), alternated,
first run after idle discarded.

- Primary: `tg_tps`, higher is better (baseline 14.45 tok/s).
- Secondary: `ttft_ms_p50`, lower is better (baseline 810 ms).
- Guards: `mem_peak_mb` and app bundle size no more than 20% above baseline (about 495 MB, 1.5 GB).

## Correctness gate

Greedy decoding must reproduce the baseline 4k model's tokens exactly on every turn. Extend the app to
print every turn's generated tokens (today only turn 0's first 48, as `reply0`) and fail any candidate
that differs.

## Practical rules

- Phone on the USB cable, unlocked, Auto-Lock = Never, Low Power Mode off; `xcrun devicectl device info
  details` must show `transportType: wired` before each batch.
- Free signing (team 63CZA36J6Z) expires every 7 days. If launch is denied, ask me to Trust the
  developer on the phone; if xcodebuild says "No Accounts", ask me to add my Apple ID in Xcode. Never
  enter credentials.
- macOS /bin/bash is 3.2. The agent's shell may be zsh, which does not word-split `$var`.
- "Connection invalidated" CoreDevice drops kill a run: retry it, never count it.
- Don't commit or push anything without asking me.
