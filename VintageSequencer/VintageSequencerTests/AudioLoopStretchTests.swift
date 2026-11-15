import Testing
import Foundation
@testable import VintageSequencer

// v1.18.13 — Zeitdehnung der Audio-Loops (Stephan: „Tempoänderung sollte audiospuren verlangsamen
// ohne tonhöhe zu ändern"). Simuliert Tick (Taktanker + Musikposition) und Ausgangs-Render.

private let sr = 48_000.0
private let tps = AudioLoopCore.hostTicksPerSecond

/// Ein Loop-Kern mit eigenem Takt und eigener Musikposition; `play` treibt Tick und Render.
final class Rig {
    let clock = BarClock()
    let sync = HostSync()
    let core: AudioLoopCore
    let st: AudioLoopStorage
    let h0: UInt64 = 1_000_000_000_000
    private var pulse = 0
    private var pulseHost: Double
    /// Host-Zeit des nächsten Blocks; `play` setzt dort fort.
    private(set) var nowHost: Double
    private(set) var barHosts: [UInt64] = []

    init(bars: Int = 1, recordedBPM: Double = 120, fill: (Int) -> Float) throws {
        core = AudioLoopCore(barClock: clock, musical: sync)
        core.prefault()
        st = try #require(AudioLoopStorage(bars: bars, sampleRate: sr, bpm: recordedBPM))
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: st.frames); defer { buf.deallocate() }
        for i in 0..<st.frames { buf[i] = fill(i) }
        st.left.write(from: buf, at: 0, count: st.frames)
        st.right.write(from: buf, at: 0, count: st.frames)
        core.bind(st)
        core.configure(AudioLoopSettings(), latencyFrames: 0, sampleRate: sr)
        pulseHost = Double(h0)
        nowHost = Double(h0)
        clock.beginSession()
        sync.beginSession(1)
        core.markActive(tickTime: h0, spanTicks: UInt64(3600 * tps), epoch: core.occupancyEpoch)
    }

    /// Spielt `seconds` mit Tempo `bpm(t)` (t in Sekunden ab Start), Blöcke zu `block` Frames.
    func play(seconds: Double, block: Int = 512, bpm: (Double) -> Double) -> [Float] {
        let l = UnsafeMutablePointer<Float>.allocate(capacity: block), r = UnsafeMutablePointer<Float>.allocate(capacity: block)
        defer { l.deallocate(); r.deallocate() }
        var out: [Float] = []
        out.reserveCapacity(Int(seconds * sr) + block)
        var host = nowHost
        let end = nowHost + seconds * tps
        defer { nowHost = host }
        while host < end {
            // Tick läuft voraus (wie der Vorlauf im Programm): Pulse bis 50 ms nach Blockende.
            while pulseHost < host + Double(block) / sr * tps + 0.05 * tps {
                let t = (pulseHost - Double(h0)) / tps
                let tempo = bpm(t)
                let h = UInt64(pulseHost)
                if pulse % 96 == 0 { clock.publish(bar: pulse / 96, host: h); barHosts.append(h) }
                sync.publish(pulse: pulse, host: h, bpm: tempo)
                pulse += 1
                pulseHost += 60 / tempo / 24 * tps
            }
            core.renderOutput(host: UInt64(host), frames: block, sampleRate: sr, l: l, r: r)
            out.append(contentsOf: UnsafeBufferPointer(start: l, count: block))
            host += Double(block) / sr * tps
        }
        return out
    }
}

extension Rig {
    /// Vorberechnung für `bpm` (4/4) wie die Loop-Steuerung sie bindet.
    @discardableResult
    func bindPrerender(bpm: Double) throws -> AudioLoopStorage {
        let bf = try #require(AudioLoopCore.prerenderBarFrames(st, bpm: bpm, quartersPerBar: 4))
        let p = try #require(AudioLoopCore.makePrerender(st, barFrames: bf))
        p.prerenderSource = AudioLoopCore.identity(st)
        p.prerenderVersion = core.materialVersion
        core.bindRendered(p)
        return p
    }
}

/// RMS je Fenster (Hüllkurve).
private func envelope(_ x: ArraySlice<Float>, window: Int) -> [Double] {
    stride(from: x.startIndex, to: x.endIndex - window, by: window).map { i in
        sqrt(x[i..<(i + window)].reduce(0) { $0 + Double($1 * $1) } / Double(window))
    }
}

/// Anstiegsflanken über `threshold` (Index), mit Totzeit.
private func onsets(_ x: [Float], threshold: Float = 0.25, dead: Int = 4800) -> [Int] {
    var out: [Int] = [], i = 1
    while i < x.count {
        if abs(x[i]) > threshold && abs(x[i - 1]) <= threshold { out.append(i); i += dead } else { i += 1 }
    }
    return out
}

@Suite(.serialized) struct AudioLoopStretchTests {

    /// Aufnahmetempo: samplegenauer Weg wie bisher, keine Zeitdehnung.
    @Test func sameTempoStaysSampleExact() throws {
        let rig = try Rig { i in Float(i % 1000) / 1000 }
        let out = rig.play(seconds: 3, bpm: { _ in 120 })
        #expect(!rig.core.isStretching && rig.core.stretchSeeks == 0)
        for i in stride(from: 1000, to: 90_000, by: 997) { #expect(out[i] == Float(i % 1000) / 1000) }
    }

    /// Langsamer (100 statt 120 BPM): Tonhöhe bleibt (480 Hz), läuft durch ohne Neuaufsetzen.
    @Test(arguments: [100.0, 140.0])
    func slowerOrFasterKeepsPitch(bpm: Double) throws {
        let rig = try Rig { i in Float(0.5 * sin(2 * .pi * 480 * Double(i) / sr)) }
        let out = rig.play(seconds: 8, bpm: { _ in bpm })
        #expect(rig.core.isStretching)
        #expect(rig.core.stretchSeeks == 1, "ein Aufsetzen am Anfang, danach durchgehend")
        let steady = Array(out[Int(0.5 * sr)...])
        var zc = 0
        for i in 1..<steady.count where steady[i - 1] <= 0 && steady[i] > 0 { zc += 1 }
        let freq = Double(zc) * sr / Double(steady.count)
        #expect(abs(freq - 480) < 2, "Tonhöhe \(freq) Hz")
        // Loop-Naht: der 1-Takt-Loop läuft mehrfach um, nirgends ein Sprung.
        var maxStep: Float = 0
        for i in 1..<steady.count { maxStep = max(maxStep, abs(steady[i] - steady[i - 1])) }
        #expect(maxStep < 0.06, "größter Sprung \(maxStep) (Sinus: ≤ 0,032)")
    }

    /// Klick auf jedem Taktbeginn: bei 100 BPM liegt er auf jedem Taktanker (keine Drift über
    /// 12 Takte), auch über eine Tempo-Rampe 100 → 150 BPM.
    @Test(arguments: [false, true])
    func clicksStayOnTheBar(ramp: Bool) throws {
        let rig = try Rig(bars: 2) { i in (i % 96_000) < 48 ? 0.9 : 0 }
        let tempo: (Double) -> Double = ramp ? { t in 100 + min(50, t * 2) } : { _ in 100 }
        let out = rig.play(seconds: 28, bpm: tempo)
        let found = onsets(out)
        #expect(rig.core.stretchSeeks == 1, "Neuaufsetzer: \(rig.core.stretchSeeks)")
        var checked = 0
        for host in rig.barHosts.dropFirst() {
            let ideal = Int(Double(host - rig.h0) / tps * sr)
            guard ideal + 4800 < out.count else { break }
            let near = found.min { abs($0 - ideal) < abs($1 - ideal) }
            let error = near.map { Double($0 - ideal) / sr * 1000 } ?? .infinity
            #expect(abs(error) < 2, "Takt bei \(Double(ideal) / sr) s: Abweichung \(error) ms")
            checked += 1
        }
        #expect(checked >= 11)
    }

    // MARK: Vorberechnung (v1.18.15)

    /// Vorberechnung passt zum Tempo: samplegenauer Weg, kein Stretcher, Tonhöhe und Naht sauber.
    @Test func prerenderPlaysWithoutRealtimeStretch() throws {
        let rig = try Rig { i in Float(0.5 * sin(2 * .pi * 480 * Double(i) / sr)) }
        let p = try rig.bindPrerender(bpm: 100)
        #expect(p.barFrames == 115_200)
        let out = rig.play(seconds: 8, bpm: { _ in 100 })
        #expect(rig.core.isPlayingPrerender && !rig.core.isStretching)
        #expect(rig.core.stretchSeeks == 0)
        let steady = Array(out[Int(0.5 * sr)...])
        var zc = 0
        for i in 1..<steady.count where steady[i - 1] <= 0 && steady[i] > 0 { zc += 1 }
        let freq = Double(zc) * sr / Double(steady.count)
        #expect(abs(freq - 480) < 2, "Tonhöhe \(freq) Hz")
        var maxStep: Float = 0
        for i in 1..<steady.count { maxStep = max(maxStep, abs(steady[i] - steady[i - 1])) }
        #expect(maxStep < 0.06, "größter Sprung \(maxStep) (Loop-Naht der Vorberechnung)")
    }

    /// Klick auf jedem Taktbeginn auch aus der Vorberechnung (12 Takte, keine Drift).
    @Test func prerenderClicksStayOnTheBar() throws {
        let rig = try Rig(bars: 2) { i in (i % 96_000) < 48 ? 0.9 : 0 }
        try rig.bindPrerender(bpm: 100)
        let out = rig.play(seconds: 28, bpm: { _ in 100 })
        let found = onsets(out)
        var checked = 0
        for host in rig.barHosts.dropFirst() {
            let ideal = Int(Double(host - rig.h0) / tps * sr)
            guard ideal + 4800 < out.count else { break }
            let near = found.min { abs($0 - ideal) < abs($1 - ideal) }
            let error = near.map { Double($0 - ideal) / sr * 1000 } ?? .infinity
            #expect(abs(error) < 2, "Takt bei \(Double(ideal) / sr) s: Abweichung \(error) ms")
            checked += 1
        }
        #expect(checked >= 11 && rig.core.stretchSeeks == 0)
    }

    /// Echtzeit gegen Offline: gleiches Material, gleiches Tempo — Hüllkurven decken sich,
    /// Pegel gleich (±1 dB), Klicks an denselben Stellen.
    @Test(arguments: [90.0, 150.0])
    func realtimeMatchesOffline(bpm: Double) throws {
        // Tonale Fläche mit Akzenten: 220/330/495 Hz, Achtel-Akzente.
        let fill: (Int) -> Float = { i in
            let t = Double(i) / sr
            let env = 0.4 + 0.6 * exp(-((t.truncatingRemainder(dividingBy: 0.25)) * 12))
            return Float(env * (0.3 * sin(2 * .pi * 220 * t) + 0.2 * sin(2 * .pi * 330 * t) + 0.1 * sin(2 * .pi * 495 * t)))
        }
        let rt = try Rig(bars: 2, fill: fill)
        let a = rt.play(seconds: 12, bpm: { _ in bpm })
        #expect(rt.core.isStretching && !rt.core.isPlayingPrerender)
        let off = try Rig(bars: 2, fill: fill)
        try off.bindPrerender(bpm: bpm)
        let b = off.play(seconds: 12, bpm: { _ in bpm })
        #expect(off.core.isPlayingPrerender && off.core.stretchSeeks == 0)
        let from = Int(1.0 * sr), to = min(a.count, b.count)
        let ea = envelope(a[from..<to], window: 2400), eb = envelope(b[from..<to], window: 2400)
        let ma = ea.reduce(0, +) / Double(ea.count), mb = eb.reduce(0, +) / Double(eb.count)
        var num = 0.0, da = 0.0, db = 0.0
        for (x, y) in zip(ea, eb) { num += (x - ma) * (y - mb); da += (x - ma) * (x - ma); db += (y - mb) * (y - mb) }
        let corr = num / sqrt(da * db)
        let levelDB = 20 * log10(ma / mb)
        #expect(corr > 0.95, "Hüllkurven-Korrelation \(corr)")
        #expect(abs(levelDB) < 1, "Pegel Echtzeit − Offline \(levelDB) dB")
    }

    /// Tempowechsel im Lauf: Echtzeit übernimmt; zurück im Vorberechnungstempo wird auf einer
    /// Taktgrenze getauscht.
    @Test func tempoChangeFallsBackAndSwapsOnBar() throws {
        let rig = try Rig { i in Float(0.5 * sin(2 * .pi * 480 * Double(i) / sr)) }
        try rig.bindPrerender(bpm: 100)
        let tempo: (Double) -> Double = { t in t < 4 || t >= 8 ? 100 : 110 }
        let out = rig.play(seconds: 16, bpm: tempo)
        #expect(rig.core.stretchSeeks >= 1, "110 BPM: Echtzeitdehnung")
        #expect(rig.core.isPlayingPrerender, "danach wieder Vorberechnung")
        let swap = rig.core.lastPrerenderSwapHost
        #expect(rig.barHosts.contains(swap), "Tausch auf einem Taktanker")
        let i = Int(Double(swap - rig.h0) / tps * sr)
        var maxStep: Float = 0
        for k in max(1, i - 512)..<min(out.count, i + 512) { maxStep = max(maxStep, abs(out[k] - out[k - 1])) }
        #expect(maxStep < 0.08, "Sprung am Tausch \(maxStep)")
    }

    /// Codex R15-01/03: Tausch über Blockgrenzen und auf Frame 0. Gleichsignal (DC) in Material
    /// und Vorberechnung: die Summe beider Rampen muss über den ganzen Übergang 1 bleiben, egal
    /// wie Taktgrenze und Block zueinander liegen.
    @Test(arguments: [32, 64, 128, 256, 512, 1000])
    func crossfadeSumsToOneAcrossBlocks(block: Int) throws {
        let rig = try Rig { _ in 0.5 }
        let p = try rig.bindPrerender(bpm: 100)
        // Vorberechnung auf anderem Gleichwert: der Übergang muss monoton zwischen beiden Pegeln
        // laufen (kein Loch) und volle 128 Frames dauern, auch über Blockgrenzen.
        let level: Float = 0.25
        let dc = [Float](repeating: level, count: p.frames)
        dc.withUnsafeBufferPointer { p.left.write(from: $0.baseAddress!, at: 0, count: p.frames); p.right.write(from: $0.baseAddress!, at: 0, count: p.frames) }
        let out = rig.play(seconds: 10, block: block, bpm: { t in t < 3 ? 110 : 100 })
        #expect(rig.core.isPlayingPrerender, "Block \(block): Vorberechnung übernommen")
        let swap = rig.core.lastPrerenderSwapHost
        #expect(rig.barHosts.contains(swap), "Block \(block): Tausch auf einem Taktanker")
        let i = Int((Double(swap - rig.h0) / tps * sr).rounded(.up))
        let before = out[(i - 600)..<(i - 200)].reduce(0, +) / 400
        var holes: Float = 0
        for k in (i - 2)..<(i + 300) { holes = max(holes, level - 0.002 - out[k], out[k] - before - 0.02) }
        #expect(holes <= 0, "Block \(block): Übergang verlässt den Bereich um \(holes) (vorher \(before))")
        #expect(out[i + 100] > level + 0.02, "Block \(block): bei 100 Frames noch in der Überblendung (\(out[i + 100]))")
        #expect(out[i + 140] == level, "Block \(block): nach 128 Frames nur Vorberechnung (\(out[i + 140]))")
    }

    /// Taktgrenzen genau auf Frame 0: Block = Taktlänge/Teiler, Anker blockbündig.
    @Test func boundaryOnFrameZeroIsTaken() throws {
        let rig = try Rig { _ in 0.5 }
        // 100 BPM: Takt = 115 200 Frames = 225 × 512 — jede Taktgrenze fällt auf einen Blockanfang.
        _ = rig.play(seconds: 3, block: 512, bpm: { _ in 100 })
        #expect(rig.core.isStretching, "erst Echtzeit")
        try rig.bindPrerender(bpm: 100)
        _ = rig.play(seconds: 6, block: 512, bpm: { _ in 100 })
        #expect(rig.core.isPlayingPrerender, "blockbündige Grenze übernommen")
        let swap = rig.core.lastPrerenderSwapHost
        #expect(rig.barHosts.contains(swap))
        let frame = Double(swap - rig.h0) / tps * sr
        #expect(abs(frame - (frame / 512).rounded() * 512) < 0.5, "Grenze auf Frame 0 eines Blocks (\(frame))")
        #expect(abs(frame - 4.8 * sr) < 1, "erste Grenze nach dem Binden (Takt 2 bei 4,8 s), \(frame / sr) s")
    }

    /// Codex R15-01 (Rand): Fenster schließt mitten in der Überblendung (Stumm/Songende) —
    /// danach kein Loop-Signal, aus keinem der beiden Wege.
    @Test func windowClosesDuringCrossfade() throws {
        let rig = try Rig { _ in 0.5 }
        _ = rig.play(seconds: 3, block: 512, bpm: { _ in 100 })
        try rig.bindPrerender(bpm: 100)
        // Erste Grenze nach dem Binden: Takt 2 bei 4,8 s; Fenster 64 Frames danach zu.
        let boundary = rig.h0 + UInt64(4.8 * tps)
        let close = boundary + UInt64(64.0 / sr * tps)
        rig.core.closeWindow(at: close)
        let start = Int(((rig.nowHost - Double(rig.h0)) / tps * sr).rounded())
        let out = rig.play(seconds: 3, block: 512, bpm: { _ in 100 })
        let iClose = Int((Double(close - rig.h0) / tps * sr).rounded(.up)) - start
        #expect(out[(iClose - 100)..<iClose].contains { $0 != 0 }, "vor dem Schließen klingt es")
        #expect(out[(iClose + 1)...].allSatisfy { $0 == 0 }, "nach dem Schließen still")
    }

    /// Codex R15-02: gemessener Spitzenbedarf der Vorberechnung (phys_footprint, längster
    /// zulässiger Loop) liegt unter dem reservierten Arbeitsspeicher plus Ergebnis.
    /// Messung, nicht Teil des Volllaufs: `phys_footprint` gilt für den ganzen Prozess, parallel
    /// laufende Tests belegen mit. Einzeln starten mit Datei `fof-measure` im Container-tmp.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: NSTemporaryDirectory() + "fof-measure"), "nur einzeln (fof-measure)"))
    func prerenderPeakFootprintWithinReservation() throws {
        // 120 s bei 48 kHz: 16 Takte à 7,5 s (32 BPM); gedehnt auf 34 BPM (≈ 113 s).
        let st = try #require(AudioLoopStorage(bars: 16, sampleRate: sr, bpm: 32))
        let n = st.frames
        let buf = (0..<n).map { Float(0.3 * sin(2 * .pi * 220 * Double($0) / sr)) }
        buf.withUnsafeBufferPointer { st.left.write(from: $0.baseAddress!, at: 0, count: n); st.right.write(from: $0.baseAddress!, at: 0, count: n) }
        let bf = try #require(AudioLoopCore.prerenderBarFrames(st, bpm: 34, quartersPerBar: 4))
        let m = bf * st.bars
        func footprint() -> Int {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
            }
            return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
        }
        final class Peak: @unchecked Sendable { var v = 0; var run = true }
        let peak = Peak()
        let base = footprint()
        let sampler = Thread { while peak.run { peak.v = max(peak.v, footprint()); usleep(500) } }
        sampler.start()
        let out = AudioLoopCore.makePrerender(st, barFrames: bf)
        peak.run = false
        Thread.sleep(forTimeInterval: 0.01)
        #expect(out != nil)
        let delta = peak.v - base
        let reserved = 32 * (n + m) + (16 << 20) + AudioLoopStorage.bytes(frames: m)
        #expect(delta <= reserved, "Spitze \(delta >> 20) MB, reserviert \(reserved >> 20) MB")
        try "prerender peak \(delta >> 20) MB reserved \(reserved >> 20) MB (n \(n), m \(m))\n"
            .write(toFile: NSTemporaryDirectory() + "prerender-peak.txt", atomically: true, encoding: .utf8)
    }

    /// Veraltete Vorberechnung (anderer Materialstand, neues Material) bleibt ungenutzt.
    @Test func stalePrerenderIgnored() throws {
        let rig = try Rig { i in Float(0.5 * sin(2 * .pi * 480 * Double(i) / sr)) }
        let p = try rig.bindPrerender(bpm: 100)
        p.prerenderVersion = rig.core.materialVersion - 1
        _ = rig.play(seconds: 2, bpm: { _ in 100 })
        #expect(!rig.core.isPlayingPrerender && rig.core.isStretching)
        // Neues Material löst die Vorberechnung.
        let fresh = try #require(rig.st.copy())
        rig.core.bind(fresh)
        #expect(rig.core.rendered == nil)
        #expect(AudioLoopCore.prerenderBarFrames(rig.st, bpm: 120, quartersPerBar: 4) == nil, "Aufnahmetempo: keine")
    }

    /// Andere Taktart als bei der Aufnahme: ein Materialtakt wird auf den jetzigen Takt gedehnt.
    @Test func meterChangeStretchesBarToBar() throws {
        let rig = try Rig { i in i < 48 ? 0.9 : 0 }
        rig.sync.beginSession(1, meter: TimeSignature(numerator: 3, denominator: 4))
        // 3/4 bei 120 BPM: Takt = 72 Pulse. Der Rig publiziert Anker alle 96 — hier nur Position.
        let out = rig.play(seconds: 6, bpm: { _ in 120 })
        #expect(rig.core.isStretching)
        let found = onsets(out)
        // Klicks alle 1,5 s (3 Viertel bei 120 BPM).
        let gaps = zip(found.dropFirst(), found).map { Double($0 - $1) / sr }
        #expect(gaps.count >= 2 && gaps.allSatisfy { abs($0 - 1.5) < 0.006 }, "Abstände \(gaps)")
    }
}

@MainActor func settleController(_ c: AudioLoopController) async throws {
    let deadline = Date().addingTimeInterval(60)
    try await Task.sleep(nanoseconds: 50_000_000)
    while c.prerenderBusy, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
}

// v1.18.15 — Steuerung der Vorberechnung: nur im Stillstand, folgt Tempo und Material.
private final class StubHost: AudioLoopHost {
    let id = UUID()
    var loopChannels: [(id: UUID, settings: AudioLoopSettings)] { [(id, AudioLoopSettings())] }
    var loopSampleRate: Double? { sr }
    var loopOutputRunning: Bool { false }
    var loopOutputLatencyFrames: Int { 0 }
    func loopConfigured(_ id: UUID, _ settings: AudioLoopSettings) {}
    func loopSettingsMeasured(_ settings: AudioLoopSettings, for id: UUID) {}
    func loopProjectChanged() {}
}

@MainActor @Suite(.serialized) struct AudioLoopPrerenderControlTests {

    private func settle(_ c: AudioLoopController) async throws {
        // Großzügig: im Volllauf belegen parallele Messungen Main zeitweise für Sekunden.
        let deadline = Date().addingTimeInterval(60)
        try await Task.sleep(nanoseconds: 50_000_000)
        while c.prerenderBusy, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
    }

    @Test func idleTempoChangeRendersAndRunningDoesNot() async throws {
        let host = StubHost()
        let c = AudioLoopController(count: 1)
        c.host = host
        c.occupy(slot: 0, epoch: 1, loop: (host.id, AudioLoopSettings()))
        let st = try #require(AudioLoopStorage(bars: 1, sampleRate: sr, bpm: 120))
        let buf = (0..<st.frames).map { Float(0.5 * sin(2 * .pi * 480 * Double($0) / sr)) }
        buf.withUnsafeBufferPointer { st.left.write(from: $0.baseAddress!, at: 0, count: st.frames); st.right.write(from: $0.baseAddress!, at: 0, count: st.frames) }
        c.put(st, for: host.id)
        let core = try #require(c.core(for: host.id))

        c.setStretchTarget(bpm: 120, quartersPerBar: 4)
        try await settle(c)
        #expect(core.rendered == nil, "Aufnahmetempo: keine Vorberechnung")

        c.setStretchTarget(bpm: 100, quartersPerBar: 4)
        try await settle(c)
        let r = try #require(core.rendered, "busy \(c.prerenderBusy) starts \(c.prerenderStarts) live \(AudioLoopStorage.liveBytes >> 20) MiB fits \(AudioLoopStorage.fits(frames: 115_200)) quiet \(core.isQuiescent) material \(core.hasMaterial)")
        #expect(r.barFrames == 115_200 && r.prerenderSource == AudioLoopCore.identity(st))
        #expect(r.prerenderVersion == core.materialVersion)

        c.setStretchTarget(bpm: 100, quartersPerBar: 3)   // 3/4
        try await settle(c)
        #expect(core.rendered?.barFrames == 86_400)

        c.transportStarted()
        c.setStretchTarget(bpm: 80, quartersPerBar: 3)
        try await settle(c)
        #expect(core.rendered?.barFrames == 86_400, "im Lauf keine neue Vorberechnung")
        c.transportStopped(at: mach_absolute_time())
        try await settle(c)
        #expect(core.rendered?.barFrames == 108_000, "nach dem Stopp nachgezogen")

        c.setStretchTarget(bpm: 120, quartersPerBar: 4)
        try await settle(c)
        #expect(core.rendered == nil, "zurück im Aufnahmetempo: gelöst")
        c.vacate(host.id, slot: 0, epoch: 2)
    }

    /// Codex R15-04: startet der Transport, während der Job rechnet, wird sein Ergebnis nicht
    /// übernommen (es könnte teilweise überschriebenes Material gelesen haben).
    @Test func transportDuringJobDiscardsResult() async throws {
        let host = StubHost()
        let c = AudioLoopController(count: 1)
        c.host = host
        c.occupy(slot: 0, epoch: 1, loop: (host.id, AudioLoopSettings()))
        let st = try #require(AudioLoopStorage(bars: 1, sampleRate: sr, bpm: 120))
        let buf = (0..<st.frames).map { Float(0.5 * sin(2 * .pi * 480 * Double($0) / sr)) }
        buf.withUnsafeBufferPointer { st.left.write(from: $0.baseAddress!, at: 0, count: st.frames); st.right.write(from: $0.baseAddress!, at: 0, count: st.frames) }
        c.put(st, for: host.id)
        let core = try #require(c.core(for: host.id))
        #expect(core.hasMaterial)
        let entered = DispatchSemaphore(value: 0), go = DispatchSemaphore(value: 0)
        c._prerenderHold = { entered.signal(); go.wait() }
        c.setStretchTarget(bpm: 100, quartersPerBar: 4)
        // Warten, bis der Job läuft (Main bleibt frei: Abfrage mit Task.sleep).
        let deadline = Date().addingTimeInterval(60)
        while entered.wait(timeout: .now()) == .timedOut, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        defer { go.signal() }   // Job nie dauerhaft blockieren
        c.transportStarted()
        c._prerenderHold = nil
        go.signal()
        try await settle(c)
        #expect(core.rendered == nil, "Ergebnis eines Jobs mit Transportstart verworfen")
        c.transportStopped(at: mach_absolute_time())
        try await settle(c)
        #expect(core.rendered?.barFrames == 115_200, "nach dem Stopp neu berechnet")
        c.vacate(host.id, slot: 0, epoch: 2)
    }

    /// Codex R15-02 (Rest): Zulassung im Initialisierer ist atomar — acht parallele Anleger knapp
    /// am Budget, nur einer bekommt Speicher; Freigaben stimmen danach.
    @Test func parallelStoragesCannotOvershootBudget() {
        let one = AudioLoopStorage.bytes(frames: AudioLoopStorage.barFrames(bpm: 120, sampleRate: sr))
        let free = AudioLoopSettings.maxProjectBytes - AudioLoopStorage.liveBytes
        let filler = free - one - one / 2           // Platz für genau einen
        #expect(AudioLoopStorage.reserve(bytes: filler))
        defer { AudioLoopStorage.release(bytes: filler) }
        final class Box: @unchecked Sendable { let lock = NSLock(); var made: [AudioLoopStorage] = [] }
        let box = Box()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            if let s = AudioLoopStorage(bars: 1, sampleRate: sr, bpm: 120) { box.lock.lock(); box.made.append(s); box.lock.unlock() }
        }
        #expect(box.made.count == 1, "zugelassen: \(box.made.count)")
        #expect(AudioLoopStorage.liveBytes <= AudioLoopSettings.maxProjectBytes)
        let before = AudioLoopStorage.liveBytes
        box.made.removeAll()
        #expect(before - AudioLoopStorage.liveBytes == one, "Freigabe beim Abbau")
    }

    /// Codex R15-04 (EXT): Aufnahme startet auf dem MIDI-Thread, Main erfährt nichts
    /// (`transportStarted` wird nie gerufen). Schreibt sie während des Jobs, gilt das Ergebnis nicht.
    @Test @MainActor func recordingWithoutMainTransportDiscardsResult() async throws {
        let host = StubHost()
        let c = AudioLoopController(count: 1)
        c.host = host
        c.occupy(slot: 0, epoch: 1, loop: (host.id, AudioLoopSettings()))
        let st = try #require(AudioLoopStorage(bars: 1, sampleRate: sr, bpm: 120))
        let buf = (0..<st.frames).map { Float(0.5 * sin(2 * .pi * 480 * Double($0) / sr)) }
        buf.withUnsafeBufferPointer { st.left.write(from: $0.baseAddress!, at: 0, count: st.frames); st.right.write(from: $0.baseAddress!, at: 0, count: st.frames) }
        c.put(st, for: host.id)
        let core = try #require(c.core(for: host.id))
        core.configure(AudioLoopSettings(), latencyFrames: 0, sampleRate: sr)
        let entered = DispatchSemaphore(value: 0), go = DispatchSemaphore(value: 0)
        c._prerenderHold = { entered.signal(); go.wait() }
        c.setStretchTarget(bpm: 100, quartersPerBar: 4)
        let deadline = Date().addingTimeInterval(60)
        while entered.wait(timeout: .now()) == .timedOut, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        defer { go.signal() }
        // Eingang wie bei EXT: Taktanker vom Tick, Aufnahme scharf, ein Durchlauf, wieder Ruhe.
        let writes0 = core.writeGeneration
        let barTicks = UInt64(2.0 * tps), h0: UInt64 = 2_000_000_000
        c.barClock.beginSession()
        for b in 0..<4 { c.barClock.publish(bar: b, host: h0 + UInt64(b) * barTicks) }
        let ib = UnsafeMutablePointer<Float>.allocate(capacity: 480); defer { ib.deallocate() }
        ib.update(repeating: 0.25, count: 480)
        let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 1); defer { ptrs.deallocate() }
        ptrs[0] = ib
        core.setRecording(true)
        var hst = h0
        while hst < h0 + 3 * barTicks {
            if hst > h0 + barTicks + barTicks / 2 { core.setRecording(false) }
            core.consumeInput(host: hst, frames: 480, sampleRate: sr, channels: ptrs, channelCount: 1)
            hst += UInt64(480.0 / sr * tps)
        }
        c.barClock.stop(at: hst)
        core.consumeInput(host: hst, frames: 480, sampleRate: sr, channels: ptrs, channelCount: 1)
        #expect(core.writeGeneration > writes0, "Aufnahme durfte schreiben")
        #expect(core.isQuiescent, "danach wieder Ruhe")
        c._prerenderHold = nil
        go.signal()
        try await settleController(c)
        // Der verworfene Job plant neu: das Ergebnis darf nur zum neuen Stand gehören.
        if let r = core.rendered { #expect(r.prerenderVersion == core.materialVersion) }
        c.vacate(host.id, slot: 0, epoch: 2)
    }

    @Test func scratchBudgetIsReservedAtomically() {
        #expect(!AudioLoopStorage.reserve(bytes: AudioLoopSettings.maxProjectBytes + 1))
        let before = AudioLoopStorage.liveBytes
        #expect(AudioLoopStorage.reserve(bytes: 4096))
        #expect(AudioLoopStorage.liveBytes - before == 4096)
        AudioLoopStorage.release(bytes: 4096)
        #expect(AudioLoopStorage.liveBytes == before)
    }
}
