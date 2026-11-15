import Testing
import Foundation
@testable import VintageSequencer

// v1.15.2 — Nachweise zur Codex-Nachprüfung von v1.15.1 (R1, R2, R6, R7, R8) und zu den
// offenen Timing-Befunden T2 (gemeinsame Verspätungsregel) und T8 (negativer Spuroffset).

private final class NoteLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(note: UInt8, ts: UInt64)] = []
    func add(_ n: UInt8, _ ts: UInt64) { lock.lock(); items.append((n, ts)); lock.unlock() }
    var all: [(note: UInt8, ts: UInt64)] { lock.lock(); defer { lock.unlock() }; return items }
    func clear() { lock.lock(); items.removeAll(); lock.unlock() }
}

private func attachLog(_ engine: SequencerEngine) -> NoteLog {
    let log = NoteLog()
    engine.midi._testSendObserver = { b0, b1, b2, _, ts in
        if b0 & 0xF0 == 0x90, b2 > 0 { log.add(b1, ts) }
    }
    return log
}

/// Track 0 des Patterns: 16 Steps, nur Step 0 aktiv mit `note`.
private func arm(_ engine: SequencerEngine, pattern: Int, note: Int, allSteps: Bool = false) {
    let lane = engine.patterns[pattern].tracks[0].lane
    lane.stepCount = 16
    for i in 0..<16 {
        lane.steps[i].isActive = allSteps || i == 0
        lane.steps[i].notes = [note]
        lane.steps[i].probability = 1.0
    }
}

private let gap: UInt64 = 20_000_000
private func future() -> UInt64 { mach_absolute_time() + 5_000_000_000 }

@Suite(.serialized) struct TransportPlanTests {

    // MARK: R1

    /// Externer Start, nachdem der Tick-Thread ohne Main schon 1, 2 bzw. 8 Songwechsel
    /// vollzogen hat: die neue Sitzung beginnt trotzdem bei Szene 1, Puls 0, Takt 0.
    @MainActor @Test(arguments: [1, 2, 8])
    func externalStartAfterUnacknowledgedSwitchesBeginsAtPulseZero(switches: Int) throws {
        let engine = SequencerEngine()
        arm(engine, pattern: 0, note: 60); arm(engine, pattern: 1, note: 62); arm(engine, pattern: 2, note: 64)
        engine.replaceSong(Song(scenes: [SongScene(pattern: 0, bars: 1), SongScene(pattern: 1, bars: 1),
                                         SongScene(pattern: 2, bars: 1)], enabled: true, loops: true))
        let log = attachLog(engine)
        engine.setClockMode(.external)
        engine.play()
        defer { engine.stop() }
        let t0 = future()
        for p in 0...(96 * switches + 10) { engine._rt3aDriveOneExternalTick(at: t0 + UInt64(p) * gap) }
        #expect(log.all.count == switches + 1, "vor dem Neustart: \(switches) Wechsel ohne Main")
        log.clear()
        engine.midi.onStart?()
        let t1 = t0 + UInt64(96 * switches + 50) * gap
        engine._rt3aDriveOneExternalTick(at: t1)
        #expect(log.all.first?.note == 60, "Szene 1 (A) auf dem ersten Tick")
        #expect(log.all.first?.ts == t1)
        #expect(engine.rack.barClock.window().anchor(at: t1).bar == 0)
        #expect(engine.rack.barClock.window().anchor(at: t1).host == t1)
        #expect(engine.currentPatternIndex == 0)
    }

    // MARK: R2

    /// Songende in der Zukunft: Main hält erst zum Endpuls an (für MIDI, AU und Loops), die
    /// Anschläge davor bleiben unberührt.
    @MainActor @Test func songEndStopsAllPathsAtTheScheduledTime() throws {
        let engine = SequencerEngine()
        arm(engine, pattern: 0, note: 60, allSteps: true)
        engine.replaceSong(Song(scenes: [SongScene(pattern: 0, bars: 1)], enabled: true, loops: false))
        let log = attachLog(engine)
        engine.setClockMode(.external)
        engine.play()
        let t0 = future()
        for p in 0...96 { engine._rt3aDriveOneExternalTick(at: t0 + UInt64(p) * gap) }
        let end = t0 + 96 * gap
        #expect(log.all.count == 16, "alle 16 Steps vor dem Ende gespielt")
        #expect(log.all.allSatisfy { $0.ts < end })
        engine._stopIfSongEnded(now: end - 1)
        #expect(engine.isPlaying, "vor dem Endpuls kein Stopp (kein Flush, keine vorgezogenen Offs)")
        #expect(engine._pendingSongStopHost == end)
        engine._stopIfSongEnded(now: end)
        #expect(!engine.isPlaying, "auf dem Endpuls angehalten")
        #expect(!engine.rack.barClock.window().anchor(at: end).isValid)
        #expect(engine.rack.barClock.window().anchor(at: end - 1).isValid)
    }

    // MARK: V16-1 (v1.16.1)

    /// Songende, während Main 250 ms bzw. 1 s nicht reagiert: der Tick beendet MIDI selbst auf
    /// dem Endpuls — Offs aller klingenden Noten (auch eines über das Ende gehaltenen Gates)
    /// spätestens dort, 0xFC genau einmal direkt danach, kein Anschlag ab dem Ende. Main hält
    /// danach nur an und sendet für das Songende kein zweites 0xFC.
    @MainActor @Test(arguments: [250, 1000])
    func songEndFinishesMIDIWithoutMain(stallMs: Int) throws {
        let engine = SequencerEngine()
        arm(engine, pattern: 0, note: 60, allSteps: true)
        let lane = engine.patterns[0].tracks[0].lane
        lane.steps[15].notes = [72]
        lane.steps[15].isDrone = true      // Off läge weit hinter dem Ende (16,5 Steps)
        engine.bpm = 20                    // Steps lang gegenüber dem Tick-Raster des Tests
        engine.replaceSong(Song(scenes: [SongScene(pattern: 0, bars: 1)], enabled: true, loops: false))
        final class Log: @unchecked Sendable {
            let lock = NSLock(); var items: [(b0: UInt8, b1: UInt8, b2: UInt8, ts: UInt64)] = []
            func add(_ e: (UInt8, UInt8, UInt8, UInt64)) { lock.lock(); items.append(e); lock.unlock() }
            var all: [(b0: UInt8, b1: UInt8, b2: UInt8, ts: UInt64)] { lock.lock(); defer { lock.unlock() }; return items }
        }
        let log = Log()
        engine.midi._testSendObserver = { b0, b1, b2, _, ts in log.add((b0, b1, b2, ts)) }
        engine.setClockMode(.external)
        engine.play()
        let t0 = future()
        let end = t0 + 96 * gap
        // Main bleibt währenddessen aus (Tests treiben den Tick synchron): Ende plus Stall-Dauer.
        let extra = UInt64(stallMs) * 1_000_000 / gap + 1
        for p in 0...(96 + Int(extra)) { engine._rt3aDriveOneExternalTick(at: t0 + UInt64(p) * gap) }
        let ons  = log.all.filter { $0.b0 & 0xF0 == 0x90 && $0.b2 > 0 }
        let offs = log.all.filter { $0.b0 & 0xF0 == 0x80 || ($0.b0 & 0xF0 == 0x90 && $0.b2 == 0) }
        let stops = log.all.filter { $0.b0 == 0xFC }
        #expect(ons.count == 16 && ons.allSatisfy { $0.ts < end }, "kein Anschlag ab dem Ende")
        #expect(offs.contains { $0.b1 == 72 && $0.ts == end }, "gehaltene Note endet auf dem Endpuls: \(offs.filter { $0.b1 == 72 }.map { Int64($0.ts) - Int64(end) }) ons72 \(ons.filter { $0.b1 == 72 }.map { Int64($0.ts) - Int64(end) })")
        #expect(offs.allSatisfy { $0.ts <= end }, "kein Off hinter dem Ende")
        #expect(stops.count == 1 && stops.first?.ts == end + 1, "0xFC einmal, direkt nach dem Ende")
        #expect(engine._songEndStopCount == 1)
        #expect(engine._noteBookPendingOff(channel: engine.patterns[0].tracks[0].midiChannel, note: 72) == 0)
        // Main kommt nach dem Stall: hält an, ohne erneut 0xFC zu senden.
        engine._stopIfSongEnded(now: end + UInt64(stallMs) * 1_000_000)
        #expect(!engine.isPlaying)
        #expect(log.all.filter { $0.b0 == 0xFC }.count == 1, "kein zweites 0xFC von Main")
        #expect(log.all.filter { $0.b0 & 0xF0 == 0x90 && $0.b2 > 0 }.count == 16, "keine zusätzlichen Anschläge")
    }

    /// Benutzer-Stopp bleibt sofort: Flush und 0xFC von Main, kein Songende-Abschluss im Tick.
    @MainActor @Test func userStopStillFlushesAndStops() throws {
        let engine = SequencerEngine()
        arm(engine, pattern: 0, note: 60, allSteps: true)
        var stops = 0
        engine.midi._testSendObserver = { b0, _, _, _, _ in if b0 == 0xFC { stops += 1 } }
        engine.setClockMode(.external)
        engine.play()
        let t0 = future()
        for p in 0...20 { engine._rt3aDriveOneExternalTick(at: t0 + UInt64(p) * gap) }
        engine.stop()
        #expect(engine._songEndStopCount == 0)
        #expect(stops == 0, "Main-Stop läuft über midi.stop() (nicht über den RT-Sendekern)")
    }

    // MARK: R6

    /// Manuelle Vormerkung A→B; der Tick wechselt nach B, Main ersetzt die Vormerkung (C),
    /// ohne den Wechsel gesehen zu haben. Der Tick spielt B weiter (nicht C), Main ordnet den
    /// Wechsel danach richtig B zu; C bleibt vorgemerkt.
    @MainActor @Test func replacedQueueDoesNotRelabelTheSwitchTheTickMade() throws {
        let engine = SequencerEngine()
        arm(engine, pattern: 0, note: 60, allSteps: true)
        arm(engine, pattern: 1, note: 62, allSteps: true)
        arm(engine, pattern: 2, note: 64, allSteps: true)
        let log = attachLog(engine)
        engine.setClockMode(.external)
        engine.play()
        defer { engine.stop() }
        engine.switchPattern(1)
        #expect(engine.queuedPatternIndex == 1)
        let t0 = future()
        for p in 0...96 { engine._rt3aDriveOneExternalTick(at: t0 + UInt64(p) * gap) }   // Wechsel auf Puls 96
        #expect(log.all.last?.note == 62, "Tick hat nach B gewechselt")
        // Main ersetzt die Vormerkung und veröffentlicht, ohne den Wechsel gesehen zu haben
        // (Tick-Wechsel genau zwischen Abgleich und Veröffentlichung).
        engine.queuedPatternIndex = 2
        engine._skipReconcileOnce = true
        engine.publishSnapshot()
        log.clear()
        for p in 97...108 { engine._rt3aDriveOneExternalTick(at: t0 + UInt64(p) * gap) }
        #expect(!log.all.isEmpty && log.all.allSatisfy { $0.note == 62 }, "B spielt weiter, nicht C")
        engine.publishSnapshot()
        #expect(engine.currentPatternIndex == 1, "Main ordnet den Wechsel B zu")
        #expect(engine.queuedPatternIndex == 2, "spätere Vormerkung C bleibt stehen")
        #expect(engine._planConflicts == 0)
    }

    // MARK: R7

    /// Mehr Grenzen ohne Main, als der Horizont fasst: erschöpfter Horizont wird gezählt, das
    /// Pattern spielt weiter; nach dem Nachziehen geht der Song weiter.
    @MainActor @Test func horizonExhaustionIsDetectedAndRecovers() throws {
        let engine = SequencerEngine()
        arm(engine, pattern: 0, note: 60); arm(engine, pattern: 1, note: 62)
        engine.replaceSong(Song(scenes: [SongScene(pattern: 0, bars: 1), SongScene(pattern: 1, bars: 1)],
                                enabled: true, loops: true))
        let log = attachLog(engine)
        engine.setClockMode(.external)
        engine.play()
        defer { engine.stop() }
        let bars = SequencerEngine.songHorizon + 3
        let t0 = future()
        for p in 0..<(96 * bars) { engine._rt3aDriveOneExternalTick(at: t0 + UInt64(p) * gap) }
        let firsts = log.all.map(\.note)
        #expect(Array(firsts.prefix(SequencerEngine.songHorizon + 1))
                == (0...SequencerEngine.songHorizon).map { $0 % 2 == 0 ? 60 : 62 }, "Plan exakt abgespielt")
        #expect(engine._horizonUnderruns >= 1, "Erschöpfung erkannt")
        engine.publishSnapshot()
        #expect(engine.queuedPatternIndex != nil, "Main plant weiter")
    }

    // MARK: EXT-Start ohne Main

    /// Im Stopp ist die Sitzung vorbereitet; 0xFA schaltet sie auf dem MIDI-Thread scharf.
    /// Der erste 0xF8 — noch bevor Main den Start verarbeitet — spielt Szene 1 auf Puls 0.
    @MainActor @Test func externalStartIsArmedOnTheMIDIThread() throws {
        let engine = SequencerEngine()
        arm(engine, pattern: 2, note: 64)
        engine.replaceSong(Song(scenes: [SongScene(pattern: 2, bars: 1)], enabled: true, loops: true))
        let log = attachLog(engine)
        engine.setClockMode(.external)
        defer { engine.stop() }
        #expect(engine._extArmed)
        #expect(engine.currentPatternIndex == 2, "Song-Beginn vorbereitet")
        engine.midi.onStartRT?()                       // 0xFA auf dem MIDI-Thread
        let t = future()
        engine.midi.onClockPulse?(t)                   // erster 0xF8, Main hat noch nichts getan
        #expect(log.all.first?.note == 64)
        #expect(log.all.first?.ts == t + engine._extLookaheadMach)
        #expect(engine.rack.barClock.window().anchor(at: log.all.first!.ts).bar == 0)
        #expect(!engine.isPlaying)
        engine.midi.onStart?()                         // Main zieht nach, ohne neue Sitzung
        #expect(engine.isPlaying)
        engine.midi.onClockPulse?(t + 20_000_000)
        #expect(engine.rack.barClock.window().anchor(at: t + 30_000_000 + engine._extLookaheadMach).host
                == t + engine._extLookaheadMach, "Takt 0 der Sitzung bleibt (kein Neustart)")
    }

    // MARK: R8 / T3

    @MainActor @Test func clockLeadsCoverOvershootAndOutputBuffer() {
        let engine = SequencerEngine()
        engine.setClockMode(.external)
        let pulse = SequencerEngine.nanosToMachTime(UInt64(60.0 / (engine.bpm * 24) * 1_000_000_000))
        #expect(engine._extLookaheadMach >= pulse + SequencerEngine.nanosToMachTime(10_000_000),
                "EXT: Pulsintervall (Overshoot) + 10 ms + Puffer")
        #expect(engine._clockExtraLeadNs > 0, "INT: zusätzlicher Vorlauf für den Ausgabepuffer")
        let before = engine._extLookaheadMach
        engine.bpm = 60
        #expect(engine._extLookaheadMach > before, "langsameres Tempo → längeres Pulsintervall im Vorlauf")
    }

    // MARK: T2

    /// Verspäteter Tick: Note und Taktanker werden um dieselbe Verschiebung später geplant;
    /// kein Weg bekommt einen eigenen Ersatzzeitpunkt.
    @MainActor @Test func lateTickShiftsNotesAndAnchorsTogether() throws {
        let engine = SequencerEngine()
        arm(engine, pattern: 0, note: 60)
        let log = attachLog(engine)
        engine.setClockMode(.external)
        engine.play()
        defer { engine.stop() }
        let late = mach_absolute_time() - SequencerEngine.nanosToMachTime(50_000_000)
        engine._rt3aDriveOneExternalTick(at: late)
        let note = try #require(log.all.first)
        #expect(note.ts > late)
        #expect(engine.rack.barClock.window().anchor(at: note.ts).host == note.ts,
                "Anker auf derselben verschobenen Zeit wie die Note")
        #expect(engine._lateTicks == 1)
    }

    // MARK: T8

    /// Negativer Spuroffset zieht die Note vor (vorher auf 0 begrenzt).
    @MainActor @Test func negativeTrackOffsetPlaysEarlier() throws {
        let engine = SequencerEngine()
        arm(engine, pattern: 0, note: 60)
        engine.patterns[0].tracks[0].timingOffset = -0.005
        let log = attachLog(engine)
        engine.setClockMode(.external)
        engine.play()
        defer { engine.stop() }
        #expect(engine._clockExtraLeadNs >= 5_000_000, "INT-Vorlauf enthält die Reserve")
        let t0 = future()
        engine._rt3aDriveOneExternalTick(at: t0)
        let ts = try #require(log.all.first?.ts)
        let expected = t0 - SequencerEngine.nanosToMachTime(5_000_000)
        #expect(ts <= expected + 1 && ts + 1 >= expected, "5 ms früher")
    }

    // MARK: V16-3 (v1.16.1)

    /// EXT mit größtem zulässigem negativen Offset (−50 ms), Puls in Echtzeit über den
    /// MIDI-Callback: die Note liegt genau 50 ms vor der Tick-Zeit und wird nicht begrenzt.
    @MainActor @Test func externalClockCoversTheFullNegativeOffsetRange() throws {
        let engine = SequencerEngine()
        arm(engine, pattern: 0, note: 60)
        engine.patterns[0].tracks[0].timingOffset = -TrackData.maxTimingOffset
        let log = attachLog(engine)
        engine.setClockMode(.external)
        engine.play()
        defer { engine.stop() }
        let lead = engine._extLookaheadMach
        #expect(lead >= SequencerEngine.nanosToMachTime(60_000_000), "Vorlauf ≥ 10 ms + 50 ms Reserve")
        let clampsBefore = engine._clampCountNotes
        let packet = mach_absolute_time()
        engine.midi.onClockPulse?(packet)
        let ts = try #require(log.all.first?.ts)
        let expected = packet + lead - SequencerEngine.nanosToMachTime(50_000_000)
        #expect(ts <= expected + 1 && ts + 1 >= expected, "genau 50 ms vor der Tick-Zeit")
        #expect(engine._clampCountNotes == clampsBefore, "kein Einzelboden")
    }

    /// Größere Offsets aus einer Datei werden auf ±50 ms begrenzt.
    @Test func decodedTimingOffsetIsClampedToTheSupportedRange() throws {
        let td = TrackData(name: "T")
        td.timingOffset = -0.2
        let back = try JSONDecoder().decode(TrackData.self, from: JSONEncoder().encode(td))
        #expect(back.timingOffset == -TrackData.maxTimingOffset)
    }
}
