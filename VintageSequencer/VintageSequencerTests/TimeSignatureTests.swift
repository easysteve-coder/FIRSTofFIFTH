import Testing
import Foundation
import AudioToolbox
import Atomics
@testable import VintageSequencer

// v1.18.12 — Taktart des Projekts (Stephan: „Fehlende Taktart stört mich am meisten."): Takte im
// Song, Taktanker der Loops, Loop-Länge, Plug-in-Takt und Pad-Längen folgen ihr.

private final class NoteLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(note: UInt8, ts: UInt64)] = []
    func add(_ n: UInt8, _ ts: UInt64) { lock.lock(); items.append((n, ts)); lock.unlock() }
    var all: [(note: UInt8, ts: UInt64)] { lock.lock(); defer { lock.unlock() }; return items }
}

@Suite(.serialized) struct TimeSignatureTests {

    @Test func barArithmetic() {
        let cases: [(TimeSignature, Int, Int, Double)] = [
            (.common, 96, 16, 4), (.init(numerator: 3, denominator: 4), 72, 12, 3),
            (.init(numerator: 7, denominator: 8), 84, 14, 3.5), (.init(numerator: 6, denominator: 8), 72, 12, 3),
            (.init(numerator: 5, denominator: 4), 120, 20, 5), (.init(numerator: 15, denominator: 16), 90, 15, 3.75),
        ]
        for (m, ppb, sixteenths, quarters) in cases {
            #expect(m.pulsesPerBar == ppb && m.sixteenthsPerBar == sixteenths && m.quartersPerBar == quarters, "\(m.label)")
        }
        let allValid = TimeSignature.choices.allSatisfy { $0.isValid }
        #expect(allValid)
        #expect(TimeSignature(numerator: 9, denominator: 5).clamped == .common)
        #expect(TimeSignature(numerator: 0, denominator: 4).clamped == .common)
    }

    @Test func padLengthsFollowMeter() {
        #expect(TimeSignature.common.padSixteenths == [4, 8, 12, 16, 32, 48, 64, 128])
        #expect(TimeSignature(numerator: 3, denominator: 4).padSixteenths == [4, 8, 12, 24, 36, 48, 96])
        #expect(TimeSignature(numerator: 7, denominator: 8).padSixteenths == [2, 4, 6, 14, 28, 42, 56, 112])
        let three = TimeSignature(numerator: 3, denominator: 4)
        #expect(TimeSignature.common.convert(sixteenths: 32, to: three) == 24)   // 2 Takte bleiben 2 Takte
        #expect(TimeSignature.common.convert(sixteenths: 8, to: three) == 8)     // 2 Schläge bleiben 2 Schläge
        #expect(TimeSignature.common.convert(sixteenths: 6, to: three) == 6)     // weder noch: unverändert
        let de = Str("de")
        #expect(de.stepLength(num: 24, den: 1, meter: three) == "2 T")
        #expect(de.stepLength(num: 16, den: 1, meter: three) == "1 T 1 Sl.")
    }

    @Test func presetCodingIsAdditive() throws {
        let enc = PresetManager()
        let plain = try #require(enc.encode(bpm: 120, swing: 50, patterns: Pattern.defaultSlots()))
        let top = try #require(JSONSerialization.jsonObject(with: plain) as? [String: Any])
        #expect(top["timeSignature"] == nil, "Projekttaktart 4/4 wird nicht geschrieben")
        #expect((top["patterns"] as? [[String: Any]])?.first?["timeSignature"] as? String == "4/4",
                "seit v1.18.24 trägt jedes Pattern seine Taktart")
        let seven = TimeSignature(numerator: 7, denominator: 8)
        let data = try #require(enc.encode(bpm: 120, swing: 50, patterns: Pattern.defaultSlots(), timeSignature: seven))
        #expect((String(data: data, encoding: .utf8) ?? "").contains("\"timeSignature\":\"7\\/8\""))
        guard case .success(.modern(let file)) = enc.decode(data) else { Issue.record("decode"); return }
        #expect(file.timeSignature == seven)
        // Ungültige Angabe: Projekt lädt trotzdem, mit 4/4.
        let bad = try #require(String(data: data, encoding: .utf8)?.replacingOccurrences(of: "7\\/8", with: "9\\/5").data(using: .utf8))
        guard case .success(.modern(let f2)) = enc.decode(bad) else { Issue.record("decode bad"); return }
        #expect(f2.timeSignature == .common)
    }

    @MainActor @Test func engineRoundTripAndPadConversionWithUndo() throws {
        let engine = SequencerEngine()
        let um = UndoManager(); engine.undoManager = um
        let pad = engine.patterns[0].tracks[0].lane
        pad.stepLengthNumerator = 32; pad.stepLengthDenominator = 1  // 2 Takte
        let other = engine.patterns[1].tracks[0].lane
        other.stepLengthNumerator = 6; other.stepLengthDenominator = 1  // keine Schläge in 3/4? 6/16
        let three = TimeSignature(numerator: 3, denominator: 4)
        engine.setTimeSignatureUndoable(three, actionName: "T")
        #expect(engine.timeSignature == three)
        #expect(pad.stepLengthNumerator == 24 && other.stepLengthNumerator == 6)
        #expect(engine.rack.hostSync.meter == (3, 4))
        um.undo()
        #expect(engine.timeSignature == .common && pad.stepLengthNumerator == 32)
        um.redo()
        #expect(engine.timeSignature == three && pad.stepLengthNumerator == 24)

        let data = try #require(engine.saveData())
        let fresh = SequencerEngine()
        #expect(fresh.loadData(data))
        #expect(fresh.timeSignature == three)
        #expect(fresh.patterns[0].tracks[0].lane.stepLengthNumerator == 24)
        #expect(fresh.rack.hostSync.meter == (3, 4))
    }

    /// Seit v1.18.24 (E2): während der Wiedergabe für das laufende Pattern vorgemerkt, beim Stop
    /// übernommen (mit Undo).
    @MainActor @Test func pendingWhilePlayingAppliesOnStop() {
        let engine = SequencerEngine()
        let um = UndoManager(); engine.undoManager = um
        engine.setClockMode(.external)
        engine.play()
        let five = TimeSignature(numerator: 5, denominator: 4)
        engine.setTimeSignatureUndoable(five, actionName: "T")
        #expect(engine.timeSignature == .common && engine.patterns[0].timeSignature == .common)
        #expect(engine.transportState.pendingTimeSignature == five)
        engine.stop()
        #expect(engine.patterns[0].timeSignature == five && engine.timeSignature == five)
        #expect(engine.transportState.pendingTimeSignature == nil)
        um.undo()
        #expect(engine.patterns[0].timeSignature == .common)
    }

    /// Song in 7/8: der Wechsel fällt auf Puls 84, der Taktanker zählt dort Takt 1.
    @MainActor @Test func songSwitchAndBarAnchorUseMeter() throws {
        let engine = SequencerEngine()
        for (p, note) in [(0, 60), (1, 62)] {
            let lane = engine.patterns[p].tracks[0].lane
            lane.stepCount = 16
            for i in 0..<16 { lane.steps[i].isActive = i == 0; lane.steps[i].notes = [note]; lane.steps[i].probability = 1 }
        }
        engine.replaceTimeSignature(TimeSignature(numerator: 7, denominator: 8))
        engine.replaceSong(Song(scenes: [SongScene(pattern: 0, bars: 1), SongScene(pattern: 1, bars: 1)],
                                enabled: true, loops: true))
        let log = NoteLog()
        engine.midi._testSendObserver = { b0, b1, b2, _, ts in if b0 & 0xF0 == 0x90, b2 > 0 { log.add(b1, ts) } }
        engine.setClockMode(.external)
        engine.play()
        defer { engine.stop() }
        let gap: UInt64 = 20_000_000
        let t0 = mach_absolute_time() + 5_000_000_000
        for p in 0...90 { engine._rt3aDriveOneExternalTick(at: t0 + UInt64(p) * gap) }
        let second = try #require(log.all.first { $0.note == 62 })
        #expect(second.ts == t0 + 84 * gap, "Wechsel auf dem 7/8-Taktstrich")
        let anchor = engine.rack.barClock.window().anchor(at: t0 + 84 * gap)
        #expect(anchor.bar == 1 && anchor.host == t0 + 84 * gap)
    }

    /// Plug-ins sehen Zähler, Nenner und den Taktbeginn in Vierteln.
    @Test func hostBlocksReportMeter() {
        let sync = HostSync()
        let binding = HostBinding()
        let tps = sync.ticksPerSecond
        binding.ticksPerFrame.store((tps / 48_000).bitPattern, ordering: .relaxed)
        let (music, _) = sync.blocks(binding: binding, advance: { 0 })
        let t0 = UInt64(200 * tps)
        sync.beginSession(1, meter: TimeSignature(numerator: 7, denominator: 8))
        sync.publish(pulse: 0, host: t0, bpm: 120)
        binding.renderHost.store(t0 + UInt64(2.0 * tps), ordering: .relaxed)   // 4 Viertel
        var tempo = 0.0, num = 0.0, den = 0, beat = 0.0, toNext = 0, downbeat = -1.0
        #expect(music(&tempo, &num, &den, &beat, &toNext, &downbeat))
        #expect(num == 7 && den == 8)
        #expect(abs(beat - 4) < 1e-6 && abs(downbeat - 3.5) < 1e-9, "Takt 2 beginnt bei 3,5 Vierteln")
    }

    @Test func loopBarFramesFollowMeter() {
        #expect(AudioLoopStorage.barFrames(bpm: 120, sampleRate: 48_000) == 96_000)
        #expect(AudioLoopStorage.barFrames(bpm: 120, sampleRate: 48_000, quarters: 3.5) == 84_000)
        #expect(AudioLoopStorage.barFrames(bpm: 120, sampleRate: 48_000, quarters: 0) == 0)
    }

    @Test func plannerUsesPulsesPerBar() {
        var p = SongPlanner()
        p.beginRun(scene: 0, pulse: 0)
        let song = Song(scenes: [SongScene(pattern: 0, bars: 2), SongScene(pattern: 1, bars: 1)], enabled: true, loops: true)
        let ok = p.schedule(song: song, playing: 0, patternCount: 16, maxDistinct: 4, pulsesPerBar: { _ in 72 })
        #expect(ok)
        #expect(p.plan.first?.pulse == 144)
    }
}
