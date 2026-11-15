import Testing
import Foundation
@testable import VintageSequencer

// v1.15.2 — Codex T5: Gerätetakt ≠ Hostuhr. Aufnahme und Wiedergabe folgen der Host-Zeit
// mit einem fortlaufenden Index (Hysterese ±1 Frame): Drift wird als einzelner Schritt
// ausgeglichen, nie als doppelt addierter oder leerer Frame. Mithören regelt den Füllstand.

private let sr = 1000.0
private let tps = AudioLoopCore.hostTicksPerSecond
private let tpf = tps / sr
private let barTicks = UInt64(2.0 * tps)          // 120 BPM, 1 Takt = 2 s = 2000 Frames

@Suite(.serialized) struct AudioLoopDriftTests {

    // MARK: LockedIndex

    @Test func lockedIndexStepsOncePerAccumulatedFrameOfDrift() {
        var lock = LockedIndex()
        var prev = -1, skips = 0, repeats = 0
        for i in 0..<20_000 {
            let s = lock.next(ideal: 10.3 + Double(i) * 1.001, total: 100_000)
            if prev >= 0 {
                let d = s.pos - prev
                #expect(d == 1 || d == 2, "nur +1 oder ein Ausgleichsschritt")
                if d == 2 { skips += 1 }
                if s.kind == .repeated { repeats += 1 }
            }
            prev = s.pos
        }
        #expect((18...21).contains(skips), "20 000 × 0,001 ≈ 20 Ausgleichsschritte, nicht mehr")
        #expect(repeats == 0)
    }

    @Test func lockedIndexIgnoresTimestampJitterBelowOneFrame() {
        var lock = LockedIndex()
        var prev = -1
        for i in 0..<10_000 {
            let jitter = 0.45 * sin(Double(i) * 0.7)
            let s = lock.next(ideal: 100.5 + Double(i) + jitter, total: 50_000)
            if prev >= 0 { #expect(s.pos == prev + 1) }
            prev = s.pos
        }
        #expect(lock.slips == 0)
    }

    @Test func lockedIndexWrapsAndResyncsOnJumps() {
        var lock = LockedIndex()
        _ = lock.next(ideal: 98.2, total: 100)
        #expect(lock.next(ideal: 99.2, total: 100).pos == 99)
        #expect(lock.next(ideal: 0.2, total: 100).pos == 0, "Loopende → Anfang ohne Sprung")
        let j = lock.next(ideal: 40.7, total: 100)
        #expect(j.pos == 40 && j.kind == .resync)
    }

    // MARK: Aufnahme

    /// Eingangsgerät langsamer/schneller als die Hostuhr: ein voller Durchlauf ergibt überall
    /// genau einen Pegel — keine doppelt addierten, keine leeren Frames.
    @Test(arguments: [1.002, 0.998])
    func recordingUnderDriftHasNoDoublesOrHoles(rate: Double) throws {
        let clock = BarClock(); clock.beginSession()
        let core = AudioLoopCore(barClock: clock)
        let st = try #require(AudioLoopStorage(bars: 1, sampleRate: sr, bpm: 120))
        core.bind(st)
        core.configure(AudioLoopSettings(), latencyFrames: 0, sampleRate: sr)
        let h0: UInt64 = 1_000_000_000
        for b in 0..<4 { clock.publish(bar: b, host: h0 + UInt64(b) * barTicks) }
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: 100); defer { buf.deallocate() }
        buf.update(repeating: 0.5, count: 100)
        let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 1)
        defer { ptrs.deallocate() }
        ptrs[0] = buf
        var host = h0
        func feed(untilSeconds s: Double) {
            while host < h0 + UInt64(s * tps) {
                core.consumeInput(host: host, frames: 100, sampleRate: sr, rateScalar: rate,
                                  channels: ptrs, channelCount: 1)
                host += UInt64(100 * tpf * rate)
            }
        }
        core.setRecording(true)
        feed(untilSeconds: 3.0)                 // Takt 0 scharf, Takt 1 halb aufgenommen
        #expect(core.state == .recording)
        core.setRecording(false)                // endet am Loopanfang (Takt 2)
        feed(untilSeconds: 4.5)
        #expect(core.state == .idle)
        #expect(core.driftSlips > 0, "Drift wurde ausgeglichen")
        // Ein-/Ausblenden (+1: der erste Frame liegt je nach Phase auf Index 0 oder 1).
        let f = AudioLoopCore.fadeFrames + 1
        var bad: [Int] = []
        for i in f..<(st.frames - f) where abs(st.left[i] - 0.5) > 1e-6 { bad.append(i) }
        #expect(bad.isEmpty, "Frames ≠ 0,5: \(bad.prefix(8))")
    }

    // MARK: Wiedergabe

    /// Ausgabegerät mit Drift, Blöcke à 100 Frames: das Material läuft fortlaufend (Schritte
    /// 0/1/2 nur als seltener Ausgleich), ohne Hin-und-her an Blockgrenzen.
    @Test(arguments: [1.0, 1.002, 0.998])
    func playbackUnderDriftIsContinuous(rate: Double) throws {
        let clock = BarClock(); clock.beginSession()
        let core = AudioLoopCore(barClock: clock)
        let st = try #require(AudioLoopStorage(bars: 2, sampleRate: sr, bpm: 120))
        for i in 0..<st.frames { st.left[i] = Float(i); st.right[i] = 0 }
        core.bind(st)
        let h0: UInt64 = 5_000_000_000
        for b in 0..<4 { clock.publish(bar: b, host: h0 + UInt64(b) * barTicks) }
        core.markActive(tickTime: h0, spanTicks: 10 * barTicks, epoch: core.occupancyEpoch)
        let l = UnsafeMutablePointer<Float>.allocate(capacity: 100); defer { l.deallocate() }
        let r = UnsafeMutablePointer<Float>.allocate(capacity: 100); defer { r.deallocate() }
        // Blockstart absichtlich nicht auf dem Sample-Raster (Drittel-Tick-Versatz).
        var host = h0 + UInt64(tpf / 3)
        var out: [Float] = []
        while out.count < 3_600 {
            core.renderOutput(host: host, frames: 100, sampleRate: sr, rateScalar: rate, l: l, r: r)
            out.append(contentsOf: UnsafeBufferPointer(start: l, count: 100))
            host += UInt64(100 * tpf * rate)
        }
        var steps: [Int: Int] = [:]
        for i in 1..<out.count { steps[Int(out[i] - out[i - 1]), default: 0] += 1 }
        let odd = steps.filter { $0.key != 1 }.values.reduce(0, +)
        #expect(Set(steps.keys).isSubset(of: [0, 1, 2]), "Schritte: \(steps)")
        if rate == 1.0 { #expect(odd == 0, "ohne Drift keine Ausgleichsschritte") }
        else { #expect((3...12).contains(odd), "≈ 3600 × 0,002 = 7 Ausgleichsschritte, nicht \(odd)") }
    }

    // MARK: Mithören

    /// Eingang liefert dauerhaft etwas mehr als der Ausgang abholt: der Füllstand bleibt
    /// begrenzt, korrigiert wird in Einzelframes.
    @Test func monitorFillLevelIsRegulated() throws {
        let clock = BarClock()
        let core = AudioLoopCore(barClock: clock)
        var s = AudioLoopSettings(); s.monitor = true
        core.configure(s, latencyFrames: 0, sampleRate: sr)
        let inBuf = UnsafeMutablePointer<Float>.allocate(capacity: 101); defer { inBuf.deallocate() }
        inBuf.update(repeating: 0.25, count: 101)
        let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 1)
        defer { ptrs.deallocate() }
        ptrs[0] = inBuf
        let l = UnsafeMutablePointer<Float>.allocate(capacity: 100); defer { l.deallocate() }
        let r = UnsafeMutablePointer<Float>.allocate(capacity: 100); defer { r.deallocate() }
        // Vorlauf: 300 Frames im Ring.
        for _ in 0..<3 { core.consumeInput(host: 1, frames: 100, sampleRate: sr, channels: ptrs, channelCount: 1) }
        var maxFill = 0
        for k in 0..<3_000 {
            // Eingang 0,1 % schneller: jeder zehnte Block hat 101 statt 100 Frames.
            core.consumeInput(host: 1, frames: k % 10 == 0 ? 101 : 100, sampleRate: sr,
                              channels: ptrs, channelCount: 1)
            core.renderOutput(host: 0, frames: 100, sampleRate: sr, l: l, r: r)
            #expect(l[50] == 0.25)
            if k > AudioLoopCore.monitorSettleBlocks { maxFill = max(maxFill, core.ring.fill / 2) }
        }
        #expect(core.monitorSlips > 0)
        #expect(maxFill < 300 + 2 * Int(AudioLoopCore.monitorHysteresisFrames) + 101,
                "Füllstand bleibt beim Sollwert (\(maxFill))")
    }

    // MARK: Latenzmessung (T4/M1)

    /// Der Klick geht in den nächsten Ausgangsblock; gemessen wird vom Ausgangs- zum
    /// Eingangszeitstempel des ersten Frames über der Schwelle — Eingang vor dem Senden zählt nicht.
    @Test func loopbackProbeMeasuresBetweenDeviceTimestamps() {
        let core = AudioLoopCore(barClock: BarClock())
        var s = AudioLoopSettings(); s.inputChannel = 0
        core.configure(s, latencyFrames: 0, sampleRate: sr)
        let l = UnsafeMutablePointer<Float>.allocate(capacity: 64); defer { l.deallocate() }
        let r = UnsafeMutablePointer<Float>.allocate(capacity: 64); defer { r.deallocate() }
        let inBuf = UnsafeMutablePointer<Float>.allocate(capacity: 64); defer { inBuf.deallocate() }
        let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 1)
        defer { ptrs.deallocate() }
        ptrs[0] = inBuf

        core.startLatencyProbe()
        #expect(core.isProbing)
        let out: UInt64 = 7_000_000_000
        // Eingang vor dem Senden mit Pegel: kein Treffer.
        inBuf.update(repeating: 0.9, count: 64)
        core.consumeInput(host: out - 1_000, frames: 64, sampleRate: sr, channels: ptrs, channelCount: 1)
        #expect(core.latencyProbeTicks == nil)
        core.renderOutput(host: out, frames: 64, sampleRate: sr, l: l, r: r)
        #expect(l[0] > 0.5 && l[4] == 0, "Klick auf den ersten Frames")
        inBuf.update(repeating: 0, count: 64); inBuf[10] = 0.5
        let back = out + UInt64(0.0123 * tps)
        core.consumeInput(host: back, frames: 64, sampleRate: sr, channels: ptrs, channelCount: 1)
        let ticks = try? #require(core.latencyProbeTicks)
        #expect(ticks == back + UInt64(10 * tpf) - out)
        #expect(!core.isProbing)
    }
}
