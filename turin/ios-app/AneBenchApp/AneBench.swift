import Foundation
import UIKit
import CoreML
import AnemllCore

// Core ML / Neural Engine version of the llama.cpp session benchmark (scripts/artemis-ios in the
// llama.cpp fork). Same workload, same telemetry: TURNS turns, each prefilling TURN_IN tokens of
// text.txt (pre-tokenized into tokens.json with the HF Qwen3 tokenizer), then generating TURN_OUT
// tokens greedily and feeding them back, with the 60 Hz Metal UI load running. The KV cache is
// kept between turns (runPrefill startPos patch), as llama.cpp does.
//
// COMPUTE=ane (default, CPU + Neural Engine) | gpu (CPU + GPU) | all
//         | hybrid (prefill on the Neural Engine, single-token decode FFN on the GPU, shared KV state)
// One "ARTEMIS_TURN {json}" line per turn, so run.sh's session_report.py scores it unchanged.

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        application.isIdleTimerDisabled = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        if envInt("UI", 1) != 0 {
            window = UILoad.install(iters: envInt("UI_LOAD", 16))
        }
        let battery = UIDevice.current.batteryState
        Task.detached(priority: .userInitiated) {
            let ok = await AneRunner(battery: battery).run()
            fflush(stdout)
            exit(ok ? 0 : 1)
        }
        return true
    }
}

let env = ProcessInfo.processInfo.environment
func envInt(_ key: String, _ def: Int) -> Int { Int(env[key] ?? "") ?? def }
func envDouble(_ key: String, _ def: Double) -> Double { Double(env[key] ?? "") ?? def }
func info(_ msg: String) { print("ARTEMIS_INFO \(msg)") }
func thermalLevel() -> Int { ProcessInfo.processInfo.thermalState.rawValue }

func quantile(_ xs: [Double], _ q: Double) -> Double {
    let s = xs.sorted()
    let pos = q * Double(s.count - 1)
    let lo = Int(pos.rounded(.down)), hi = Int(pos.rounded(.up))
    return s[lo] + (s[hi] - s[lo]) * (pos - Double(lo))
}

struct BenchError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

struct AneRunner {
    let battery: UIDevice.BatteryState

    func run() async -> Bool {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let compute = env["COMPUTE"] ?? "ane"
        info("mode=session runtime=coreml compute=\(compute) battery_state=\(battery.rawValue) low_power=\(lowPower) thermal=\(thermalLevel())")
        do {
            guard battery == .charging || battery == .full else { throw BenchError("refusing to benchmark on battery") }
            guard !lowPower else { throw BenchError("refusing to benchmark in Low Power Mode") }
            guard let tokURL = Bundle.main.url(forResource: "tokens", withExtension: "json") else {
                throw BenchError("tokens.json missing from app bundle")
            }
            let tokens = try JSONDecoder().decode([Int].self, from: Data(contentsOf: tokURL))
            guard let meta = findMeta() else { throw BenchError("no model folder with meta.yaml in app bundle") }

            let config = try YAMLConfig.load(from: meta)
            // hybrid: prefill (and embeddings, LM head) on the Neural Engine, single-token FFN on the GPU
            let units: MLComputeUnits = compute == "gpu" ? .cpuAndGPU : compute == "all" ? .all : .cpuAndNeuralEngine
            let inferUnits: MLComputeUnits? = compute == "hybrid" ? .cpuAndGPU : nil
            let l0 = Date()
            // SPLIT_FFN=1: single-function infer / prefill models from bundle-split, loaded with functionName = nil
            let splitDir = envInt("SPLIT_FFN", 0) != 0 ? Bundle.main.resourceURL?.appendingPathComponent(env["SPLIT_DIR"] ?? "bundle-split").path : nil
            info("split_ffn=\(splitDir != nil)")
            let models = try await ModelLoader().loadModel(
                from: config, configuration: .init(computeUnits: units, inferComputeUnits: inferUnits, splitFFNDir: splitDir))
            let im = try InferenceManager(
                models: models, contextLength: config.contextLength, batchSize: config.batchSize,
                splitLMHead: config.splitLMHead, v110: config.configVersion == "0.1.1",
                argmaxInModel: config.argmaxInModel, slidingWindow: config.slidingWindow,
                updateMaskPrefill: config.updateMaskPrefill, prefillDynamicSlice: config.prefillDynamicSlice,
                modelPrefix: config.modelPrefix, vocabSize: config.vocabSize,
                lmHeadChunkSizes: config.lmHeadChunkSizes)
            info("model_dir=\(URL(fileURLWithPath: meta).deletingLastPathComponent().lastPathComponent)")
            info(String(format: "load_s=%.1f context=%d batch=%d text_tokens=%d", Date().timeIntervalSince(l0),
                        config.contextLength, config.batchSize, tokens.count))
            try await session(im, tokens, contextLength: config.contextLength)
            return true
        } catch {
            print("ARTEMIS_ERROR \(error)")
            return false
        }
    }

    func findMeta() -> String? {
        // MODEL_DIR picks one bundled model folder (bundle = 4k context, bundle-1k = 1k context)
        if let name = env["MODEL_DIR"], let root = Bundle.main.resourceURL {
            let m = root.appendingPathComponent(name).appendingPathComponent("meta.yaml")
            return FileManager.default.fileExists(atPath: m.path) ? m.path : nil
        }
        guard let root = Bundle.main.resourceURL,
              let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        for dir in items {
            let m = dir.appendingPathComponent("meta.yaml")
            if FileManager.default.fileExists(atPath: m.path) { return m.path }
        }
        return nil
    }

    func session(_ im: InferenceManager, _ tokens: [Int], contextLength: Int) async throws {
        let turns = envInt("TURNS", 10), tin = envInt("TURN_IN", 256), tout = envInt("TURN_OUT", 150)
        let thermalStart = envInt("THERMAL_START", 1), coolTimeout = envDouble("COOL_TIMEOUT_S", 900)
        guard tokens.count >= turns * tin else { throw BenchError("text too short for \(turns) turns") }
        guard turns * (tin + tout) < contextLength - 2 else {
            throw BenchError("session needs \(turns * (tin + tout)) tokens; model context is \(contextLength)")
        }
        func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

        // warmup outside the session: first predictions compile/load the ANE programs
        im.initState()
        var warm = Array(tokens[0..<(tin + 1)])
        _ = try await im.runPrefill(on: &warm, contextPos: tin)
        _ = try await im.generateNextToken(for: warm[tin - 1], currentPos: tin, temperature: 0)
        _ = try await im.generateNextToken(for: warm[tin], currentPos: tin + 1, temperature: 0)

        let w0 = now()
        while thermalLevel() > thermalStart {
            if now() - w0 > coolTimeout { throw BenchError("phone did not cool to thermal level \(thermalStart) within \(Int(coolTimeout))s") }
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        info(String(format: "cool_wait_s=%.0f", now() - w0))
        if let ui = UILoad.shared {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            _ = ui.drain()
            try await Task.sleep(nanoseconds: 10_000_000_000)
            let idle = ui.drain()
            info(String(format: "ui_idle frames=%d dropped=%d p99_ms=%.1f", idle.frames, idle.dropped, idle.p99ms))
        }

        im.initState()
        let profile = envInt("PROFILE", 0) != 0
        StepProfiler.shared.enabled = profile
        StepProfiler.shared.reset()
        var ctx: [Int] = []   // every token in the KV cache, in order
        let t0 = now()
        for t in 0..<turns {
            _ = UILoad.shared?.drain()
            let start = now(), depth = ctx.count
            ctx += tokens[(t * tin)..<((t + 1) * tin)]
            _ = try await im.runPrefill(on: &ctx, contextPos: ctx.count, startPos: depth)
            // logits for the last prompt token (re-runs that one position; llama.cpp gets them from the batch)
            var tok = try await im.generateNextToken(for: ctx[ctx.count - 1], currentPos: ctx.count, temperature: 0)
            let ttft = now() - start
            var reply = [tok]
            let g0 = now()
            for _ in 1..<tout {
                ctx.append(tok)
                tok = try await im.generateNextToken(for: tok, currentPos: ctx.count, temperature: 0)
                reply.append(tok)
            }
            ctx.append(tok)  // the reply's last token joins the context
            _ = try await im.generateNextToken(for: tok, currentPos: ctx.count, temperature: 0)
            let gen = now() - g0
            if t == 0 { info("reply0=" + reply.prefix(48).map(String.init).joined(separator: ",")) }
            // correctness gate: every turn's full greedy reply
            info("reply_turn\(t)=" + reply.map(String.init).joined(separator: ","))
            let ui = UILoad.shared?.drain()
            let battery = await MainActor.run { UIDevice.current.batteryLevel }
            let row: [String: Double] = [
                "t_s": start - t0, "conv": 0, "turn": Double(t), "depth": Double(depth),
                "ttft_ms": ttft * 1000, "prefill_tps": Double(tin) / ttft, "tg_tps": Double(tout) / gen,
                "thermal": Double(thermalLevel()), "mem_mb": footprintMB(), "battery": Double(battery),
                "ui_frames": Double(ui?.frames ?? 0), "ui_dropped": Double(ui?.dropped ?? 0),
                "ui_p99_ms": ui?.p99ms ?? 0,
            ]
            let json = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            print("ARTEMIS_TURN " + String(decoding: json, as: UTF8.self))
            fflush(stdout)
        }
        info(String(format: "session_s=%.1f conversations=1", now() - t0))
        if profile { reportProfile() }
    }

    /// Test 1: median per-token time per step, Core ML predictions (*_predict) vs everything else.
    func reportProfile() {
        let recs = StepProfiler.shared.snapshot()
        for kind in ["decode", "prefill"] {
            let rs = recs.filter { $0.kind == kind }
            guard !rs.isEmpty else { continue }
            let steps = Set(rs.flatMap { $0.steps.keys }).sorted()
            func perTok(_ r: StepProfiler.Record, _ ns: UInt64) -> Double { Double(ns) / 1e6 / Double(r.tokens) }
            var parts: [String] = []
            for st in steps {
                let xs = rs.map { perTok($0, $0.steps[st] ?? 0) }
                parts.append(String(format: "%@=%.3f", st, quantile(xs, 0.5)))
            }
            let tot = rs.map { perTok($0, $0.totalNs) }
            let pred = rs.map { r in perTok(r, r.steps.filter { $0.key.hasSuffix("_predict") }.values.reduce(0, +)) }
            let share = rs.map { r -> Double in
                let p = r.steps.filter { $0.key.hasSuffix("_predict") }.values.reduce(0, +)
                return 100 * Double(r.totalNs - p) / Double(r.totalNs)
            }
            info(String(format: "profile kind=%@ n=%d ms_per_token median: total=%.3f predict=%.3f overhead=%.3f overhead_pct p10/p50/p90=%.1f/%.1f/%.1f steps: %@",
                        kind, rs.count, quantile(tot, 0.5), quantile(pred, 0.5), quantile(tot, 0.5) - quantile(pred, 0.5),
                        quantile(share, 0.1), quantile(share, 0.5), quantile(share, 0.9), parts.joined(separator: " ")))
        }
    }
}
