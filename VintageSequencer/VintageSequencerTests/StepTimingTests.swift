import Testing
import Foundation
@testable import VintageSequencer

// Stephan (15.11.2026): „Wenn ich 16el Noten wähle, bekomme ich tatsächlich was? Bei 120 bpm
// müssten 16el schneller sein." Messung mit der echten INT-Clock: Abstand der Note-On-Zeitstempel.
@MainActor @Suite(.serialized) struct StepTimingTests {
    private final class Log: @unchecked Sendable {
        let lock = NSLock(); var ts: [UInt64] = []
        func add(_ t: UInt64) { lock.lock(); ts.append(t); lock.unlock() }
    }

    @Test(arguments: [(1, 1, 125.0), (1, 2, 62.5), (2, 1, 250.0), (2, 3, 83.333)])
    func stepSpacingAt120(num: Int, den: Int, expectedMs: Double) async throws {
        let engine = SequencerEngine()
        engine.bpm = 120
        let lane = engine.patterns[0].tracks[0].lane
        lane.stepCount = 16
        lane.stepLengthNumerator = num; lane.stepLengthDenominator = den
        for i in 0..<16 { lane.steps[i].isActive = true; lane.steps[i].notes = [60]; lane.steps[i].probability = 1 }
        for t in engine.patterns[0].tracks.dropFirst() { for i in t.lane.steps.indices { t.lane.steps[i].isActive = false } }
        let log = Log()
        engine.midi._testSendObserver = { b0, _, b2, _, ts in if b0 & 0xF0 == 0x90, b2 > 0 { log.add(ts) } }
        engine.publishSnapshot()
        engine.play()
        try await Task.sleep(nanoseconds: 1_600_000_000)
        engine.stop()
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        let ms = { (d: UInt64) in Double(d) * Double(tb.numer) / Double(tb.denom) / 1_000_000 }
        let ts = log.ts.sorted()
        let gaps = zip(ts.dropFirst(), ts).map { ms($0 - $1) }
        #expect(gaps.count >= 5)
        let mean = gaps.reduce(0, +) / Double(max(1, gaps.count))
        #expect(abs(mean - expectedMs) < 0.5, "\(num):\(den) Abstand \(mean) ms, erwartet \(expectedMs)")
        try "\(num):\(den) mean \(mean) ms n \(gaps.count) min \(gaps.min() ?? 0) max \(gaps.max() ?? 0)\n"
            .write(toFile: NSTemporaryDirectory() + "sixteenth-\(num)-\(den).txt", atomically: true, encoding: .utf8)
    }
}
