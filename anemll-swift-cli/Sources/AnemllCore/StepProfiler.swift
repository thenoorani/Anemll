import Foundation

/// Turin bench (headroom study, test 1): per-step wall-clock timing of single-token decode and
/// batch prefill. Each `begin` opens one record (one decode call or one prefill batch); `mark`
/// charges the time since the previous mark to a named step. Disabled unless `enabled` is set.
public final class StepProfiler: @unchecked Sendable {
    public static let shared = StepProfiler()
    public var enabled = false

    public struct Record: Sendable {
        public let kind: String              // "decode" | "prefill"
        public let tokens: Int               // tokens covered by this record (1, or the batch size)
        public var steps: [String: UInt64]   // ns per step
        public var totalNs: UInt64
    }

    private let lock = NSLock()
    private var records: [Record] = []
    private var current: Record?
    private var start: UInt64 = 0
    private var last: UInt64 = 0

    @inline(__always) private func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    public func begin(_ kind: String, tokens: Int) {
        guard enabled else { return }
        let t = now()
        lock.lock(); defer { lock.unlock() }
        current = Record(kind: kind, tokens: tokens, steps: [:], totalNs: 0)
        start = t; last = t
    }

    public func mark(_ step: String) {
        guard enabled else { return }
        let t = now()
        lock.lock(); defer { lock.unlock() }
        guard current != nil else { return }
        current!.steps[step, default: 0] += t - last
        last = t
    }

    public func end() {
        guard enabled else { return }
        let t = now()
        lock.lock(); defer { lock.unlock() }
        guard var r = current else { return }
        if t > last { r.steps["other", default: 0] += t - last }
        r.totalNs = t - start
        records.append(r)
        current = nil
    }

    public func reset() { lock.lock(); records.removeAll(); current = nil; lock.unlock() }
    public func snapshot() -> [Record] { lock.lock(); defer { lock.unlock() }; return records }
}
