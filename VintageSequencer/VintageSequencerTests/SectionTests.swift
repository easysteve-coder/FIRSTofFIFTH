import Testing
import Foundation
import Atomics
@testable import VintageSequencer

// v1.18.23 — Abschnittsschema (Konzept Taktart und Zeit 4.1/4.2, Paket 2): jeder Host-Anker trägt
// Taktart, Ursprung, Aktivierung und Pattern; Takt zählt ab dem Ursprung (Codex KT-01).

private let gap: UInt64 = 20_000_000

private func arm(_ engine: SequencerEngine, pattern: Int, stepCount: Int) {
    let lane = engine.patterns[pattern].tracks[0].lane
    lane.stepCount = stepCount
    lane.steps[0].isActive = true
    lane.steps[0].notes = [60]
}

@Suite(.serialized) struct SectionTests {

    /// Codex-Prüffall: je ein Takt 4/4 → 7/8 → 5/4, Startpulse 0, 96, 180, Ende 300. Downbeats
    /// 0, 4, 7,5 Viertel; fortlaufende Takte; vor/auf/nach jeder Grenze vollständig alt/neu.
    @Test func mixedMetersFromAnchors() {
        let h = HostSync()
        h.beginSession(1)
        let t0: UInt64 = 1_000_000_000
        let per = UInt64(h.ticksPerSecond * 60 / 120 / 24)
        let four = TimeSignature.common, seven = TimeSignature(numerator: 7, denominator: 8)
        let five = TimeSignature(numerator: 5, denominator: 4)
        let binding = HostBinding()
        binding.ticksPerFrame.store((h.ticksPerSecond / 48_000).bitPattern, ordering: .relaxed)
        let (music, _) = h.blocks(binding: binding, advance: { 0 })
        // Host-Blöcke: Taktart und Downbeat aus demselben Anker.
        func blockCheck() {
            binding.renderHost.store(t0 + 120 * per, ordering: .relaxed)
            var tempo = 0.0, num = 0.0, den = 0, beat = 0.0, toNext = 0, downbeat = -1.0
            #expect(music(&tempo, &num, &den, &beat, &toNext, &downbeat))
            #expect(num == 7 && den == 8 && abs(downbeat - 4) < 1e-9 && abs(beat - 5) < 1e-6)
        }
        // Der Ring hält 32 Anker (kein Songplan): abfragen wie im Betrieb, wenige Pulse nach dem
        // Abfragepunkt veröffentlicht.
        var states: [Double: HostSync.State] = [:]
        let queries: [Double] = [95.5, 96, 96.5, 120, 179.5, 180, 299]
        for p in 0..<300 {
            let sec: HostSync.Section
            switch p {
            case ..<96:  sec = .init(meter: four, originPulse: 0, originBar: 0, activation: 1, pattern: 0,
                                     nextPattern: 1, nextSwitchPulse: 96)
            case ..<180: sec = .init(meter: seven, originPulse: 96, originBar: 1, activation: 2, pattern: 1,
                                     nextPattern: 2, nextSwitchPulse: 180)
            default:     sec = .init(meter: five, originPulse: 180, originBar: 2, activation: 3, pattern: 2)
            }
            h.publish(pulse: p, host: t0 + UInt64(p) * per, bpm: 120, section: sec)
            for q in queries where Int(q) + 4 == p || (p == 299 && states[q] == nil) {
                states[q] = h.state(at: t0 + UInt64(q * Double(per)))
            }
            if p == 124 { blockCheck() }
        }
        func at(_ p: Double) -> HostSync.State { states[p]! }
        let a = at(95.5), b = at(96), c = at(96.5)
        #expect(a.numerator == 4 && a.bar == 0 && a.barStart == 0 && a.activation == 1)
        #expect(b.numerator == 7 && b.denominator == 8 && b.bar == 1 && b.barStart == 4 && b.activation == 2)
        #expect(c.numerator == 7 && c.bar == 1 && c.barStart == 4)
        let d = at(179.5), e = at(180), f = at(299)
        #expect(d.numerator == 7 && d.bar == 1)
        #expect(e.numerator == 5 && e.bar == 2 && abs(e.barStart - 7.5) < 1e-9 && e.pattern == 2)
        #expect(f.numerator == 5 && f.bar == 2 && f.nextPattern == -1)
        #expect(a.nextPattern == 1 && a.nextSwitchPulse == 96)
        #expect(TimingInfo.barsUntil(pulse: a.nextSwitchPulse, from: a.pulse, pulsesPerBar: a.pulsesPerBar) == 1)

    }

    /// Stillstand: Taktart des Projekts ab Viertel 0, auch nach einer Sitzung.
    @Test func stoppedUsesProjectMeter() {
        let h = HostSync()
        h.setMeter(TimeSignature(numerator: 3, denominator: 4))
        let idle = h.state(at: 5)
        #expect(idle.numerator == 3 && idle.bar == 0 && !idle.moving)
    }

    /// Song A (1 Takt) → B (2 Takte) → C (1 Takt) in 3/4, im echten Tick: Takte laufen ab dem
    /// Ursprung durch, jede Wechselgrenze erhöht die Aktivierung einmal, Pattern und nächster
    /// Wechsel stehen im selben Anker; Taktanker zählen durch.
    @MainActor @Test func songSectionsInTheTick() throws {
        let engine = SequencerEngine()
        engine.replaceTimeSignature(TimeSignature(numerator: 3, denominator: 4))   // alle Patterns
        for p in 0..<3 { arm(engine, pattern: p, stepCount: 16) }
        engine.replaceSong(Song(scenes: [SongScene(pattern: 0, bars: 1), SongScene(pattern: 1, bars: 2),
                                         SongScene(pattern: 2, bars: 1)], enabled: true, loops: true))
        engine.setClockMode(.external)
        engine.play()
        defer { engine.stop() }
        let sync = engine.rack.hostSync
        let t0 = mach_absolute_time() + 5_000_000_000
        var seen: [Int: HostSync.State] = [:]
        for p in 0...300 {
            engine._rt3aDriveOneExternalTick(at: t0 + UInt64(p) * gap)
            if [0, 71, 72, 143, 144, 215, 216, 287, 288].contains(p) { seen[p] = sync.state(at: t0 + UInt64(p) * gap) }
        }
        func s(_ p: Int) -> HostSync.State { seen[p]! }
        #expect(s(0).pattern == 0 && s(0).activation == 1 && s(0).nextPattern == 1 && s(0).nextSwitchPulse == 72)
        #expect(s(0).numerator == 3 && s(0).bar == 0)
        #expect(s(71).pattern == 0 && s(71).bar == 0)
        #expect(s(72).pattern == 1 && s(72).activation == 2 && s(72).bar == 1 && abs(s(72).barStart - 3) < 1e-9)
        #expect(s(143).bar == 1 && s(144).bar == 2 && s(144).pattern == 1 && s(144).activation == 2,
                "Takt innerhalb von B ohne neue Aktivierung")
        #expect(s(216).pattern == 2 && s(216).activation == 3 && s(216).bar == 3)
        #expect(s(288).pattern == 0 && s(288).activation == 4 && s(288).bar == 4)
        #expect(s(72).nextPattern == 2 && s(72).nextSwitchPulse == 216)
        // Taktanker: Takt 4 auf Puls 288.
        let w = engine.rack.loops.barClock.window()
        let anchor = w.anchor(at: t0 + 288 * gap)
        #expect(anchor.bar == 4 && anchor.host == t0 + 288 * gap)
    }

    /// Ende Spur 1 mitten im Takt (v1.18.24, Konzept 4.2): der alte Takt ist verkürzt, mit dem
    /// Wechsel beginnt ein neuer. Codex-Prüffall: Wechsel auf Puls 30 nach 7/8 → nächster Takt
    /// auf Puls 114, nicht 84.
    @MainActor @Test func midBarSwitchStartsNewBar() throws {
        let engine = SequencerEngine()
        engine.replaceSwitchOnBar(false)
        arm(engine, pattern: 0, stepCount: 5)            // Spur 1: 30 Pulse
        arm(engine, pattern: 1, stepCount: 16)
        engine.switchPattern(1)
        engine.setTimeSignatureUndoable(TimeSignature(numerator: 7, denominator: 8), actionName: "T")
        engine.switchPattern(0)
        #expect(engine.patterns[1].timeSignature.label == "7/8" && engine.timeSignature == .common)
        engine.setClockMode(.external)
        engine.play()
        defer { engine.stop() }
        engine.switchPattern(1)
        let sync = engine.rack.hostSync
        let t0 = mach_absolute_time() + 5_000_000_000
        var st: [Int: HostSync.State] = [:]
        for p in 0...120 {
            engine._rt3aDriveOneExternalTick(at: t0 + UInt64(p) * gap)
            if [29, 30, 113, 114].contains(p) { st[p] = sync.state(at: t0 + UInt64(p) * gap) }
        }
        #expect(st[29]!.pattern == 0 && st[29]!.bar == 0 && st[29]!.nextSwitchPulse == -1)
        #expect(st[30]!.pattern == 1 && st[30]!.activation == 2 && st[30]!.bar == 1 && st[30]!.numerator == 7)
        #expect(abs(st[30]!.barStart - 1.25) < 1e-9)
        #expect(st[113]!.bar == 1 && st[114]!.bar == 2 && abs(st[114]!.barStart - 4.75) < 1e-9)
        let a = engine.rack.loops.barClock.window().anchor(at: t0 + 114 * gap)
        #expect(a.bar == 2 && a.host == t0 + 114 * gap)
    }

    /// Nächster Taktstrich (E3): eine Vormerkung mitten im Takt greift auf Puls 96, auch wenn
    /// Spur 1 vorher endet.
    @MainActor @Test func switchOnNextBarLine() throws {
        let engine = SequencerEngine()
        #expect(engine.switchOnBar, "neue Projekte: nächster Taktstrich")
        arm(engine, pattern: 0, stepCount: 3)            // Spur 1 endet alle 18 Pulse
        arm(engine, pattern: 1, stepCount: 16)
        engine.setClockMode(.external)
        engine.play()
        defer { engine.stop() }
        let sync = engine.rack.hostSync
        let t0 = mach_absolute_time() + 5_000_000_000
        var st: [Int: HostSync.State] = [:]
        for p in 0...100 {
            if p == 10 { engine.switchPattern(1) }
            engine._rt3aDriveOneExternalTick(at: t0 + UInt64(p) * gap)
            if [95, 96].contains(p) { st[p] = sync.state(at: t0 + UInt64(p) * gap) }
        }
        #expect(st[95]!.pattern == 0 && st[95]!.nextPattern == 1)
        #expect(st[96]!.pattern == 1 && st[96]!.bar == 1 && st[96]!.activation == 2)
    }

    /// Song A (4/4, 1 Takt) → B (7/8, 2 Takte) → A: Szenenlängen in der Taktart ihres Patterns,
    /// Plug-ins sehen 7/8 im B-Abschnitt.
    @MainActor @Test func songScenesCountBarsInTheirPatternsMeter() throws {
        let engine = SequencerEngine()
        for p in 0..<2 { arm(engine, pattern: p, stepCount: 16) }
        engine.switchPattern(1)
        engine.setTimeSignatureUndoable(TimeSignature(numerator: 7, denominator: 8), actionName: "T")
        engine.switchPattern(0)
        engine.replaceSong(Song(scenes: [SongScene(pattern: 0, bars: 1), SongScene(pattern: 1, bars: 2)],
                                enabled: true, loops: true))
        engine.setClockMode(.external)
        engine.play()
        defer { engine.stop() }
        let sync = engine.rack.hostSync
        let t0 = mach_absolute_time() + 5_000_000_000
        var st: [Int: HostSync.State] = [:]
        for p in 0...270 {
            engine._rt3aDriveOneExternalTick(at: t0 + UInt64(p) * gap)
            if [96, 179, 180, 263, 264].contains(p) { st[p] = sync.state(at: t0 + UInt64(p) * gap) }
            if p == 100 { engine.publishSnapshot() }     // Main zieht nach, plant weiter
        }
        #expect(st[96]!.pattern == 1 && st[96]!.numerator == 7 && st[96]!.nextSwitchPulse == 264)
        #expect(st[180]!.bar == 2 && st[180]!.pattern == 1, "zweiter 7/8-Takt")
        #expect(st[263]!.pattern == 1 && st[264]!.pattern == 0 && st[264]!.numerator == 4 && st[264]!.bar == 3)
    }

    /// Preset: Taktart je Pattern und Wechselquantisierung; ältere Dateien ohne Pattern-Schlüssel
    /// übernehmen die Projekttaktart, ohne `patternSwitch` „Ende Spur 1".
    @MainActor @Test func presetPerPatternMeter() throws {
        let engine = SequencerEngine()
        engine.switchPattern(2)
        engine.setTimeSignatureUndoable(TimeSignature(numerator: 5, denominator: 4), actionName: "T")
        engine.setSwitchOnBarUndoable(false, actionName: "S")
        let data = try #require(engine.saveData())
        let fresh = SequencerEngine()
        #expect(fresh.loadData(data))
        #expect(fresh.patterns[2].timeSignature.label == "5/4" && fresh.patterns[0].timeSignature == .common)
        #expect(!fresh.switchOnBar)

        // Datei aus v1.18.23: Projekttaktart 3/4, keine Pattern-Schlüssel, kein patternSwitch.
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["timeSignature"] = "3/4"; json["patternSwitch"] = nil
        json["patterns"] = (json["patterns"] as! [[String: Any]]).map { var p = $0; p["timeSignature"] = nil; return p }
        let old = try JSONSerialization.data(withJSONObject: json)
        let third = SequencerEngine()
        #expect(third.loadData(old))
        #expect(third.patterns.allSatisfy { $0.timeSignature.label == "3/4" } && !third.switchOnBar)
    }

    @Test func positionFromBarAndOffset() {
        let seven = TimeSignature(numerator: 7, denominator: 8)
        #expect(TimingInfo.position(bar: 1, quartersIntoBar: 0.75, meter: seven)
                == TimingInfo.Position(bar: 2, beat: 2, division: 2, tick: 1))
        #expect(TimingInfo.barsUntil(pulse: 216, from: 72, pulsesPerBar: 72) == 2)
        #expect(TimingInfo.barsUntil(pulse: 216, from: 150, pulsesPerBar: 72) == 1)
        #expect(TimingInfo.barsUntil(pulse: -1, from: 0, pulsesPerBar: 96) == nil)
    }
}
