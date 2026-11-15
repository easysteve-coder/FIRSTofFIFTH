import Testing
import Foundation
import CoreMIDI
@testable import VintageSequencer

// v1.14.0 — Song-Lane: Szenenfolge über allen Patterns, Wechsel auf der Taktgrenze im
// Tick-Thread, Songende, 16 Patterns, Presetschlüssel `song`.

private final class OnLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(note: UInt8, ts: MIDITimeStamp)] = []
    func add(_ n: UInt8, _ ts: MIDITimeStamp) { lock.lock(); items.append((n, ts)); lock.unlock() }
    var all: [(note: UInt8, ts: MIDITimeStamp)] { lock.lock(); defer { lock.unlock() }; return items }
}

private func attachOnLog(_ engine: SequencerEngine) -> OnLog {
    let log = OnLog()
    engine.midi._testSendObserver = { b0, b1, b2, _, ts in
        if b0 & 0xF0 == 0x90, b2 > 0 { log.add(b1, ts) }
    }
    return log
}

private func arm(_ engine: SequencerEngine, pattern: Int, note: Int, stepCount: Int) {
    let lane = engine.patterns[pattern].tracks[0].lane
    lane.stepCount = stepCount
    lane.steps[0].isActive = true
    lane.steps[0].notes = [note]
    lane.steps[0].probability = 1.0
}

private let gap: UInt64 = 20_000_000

@Suite(.serialized) struct SongTests {

    // MARK: Modell

    @Test func runMergesScenesOfThePlayingPatternAndWraps() {
        var song = Song(scenes: [SongScene(pattern: 0, bars: 2), SongScene(pattern: 0, bars: 1),
                                 SongScene(pattern: 1, bars: 4), SongScene(pattern: 0, bars: 1)],
                        enabled: true, loops: true)
        #expect(song.run(from: 0, playing: 0) == (3, .scene(2)))
        #expect(song.run(from: 2, playing: 1) == (4, .scene(3)))
        // Loop: Szene 3 (A) läuft über das Ende in Szene 0 und 1 (A) weiter.
        #expect(song.run(from: 3, playing: 0) == (4, .scene(2)))
        song.loops = false
        #expect(song.run(from: 3, playing: 0) == (1, .end))
        let same = Song(scenes: [SongScene(pattern: 2, bars: 1), SongScene(pattern: 2, bars: 2)],
                        enabled: true, loops: true)
        #expect(same.run(from: 0, playing: 2) == (3, .never))
        // Szene während des Laufs auf ein anderes Pattern umgestellt: nach einer Runde dorthin.
        #expect(same.run(from: 0, playing: 5) == (1, .scene(1)))
    }

    @Test func sixteenPatternSlotsAndClamping() {
        #expect(Pattern.slotNames.count == 16)
        #expect(Pattern.slotNames.first == "A" && Pattern.slotNames.last == "P")
        #expect(SequencerEngine().patterns.map(\.name) == Pattern.slotNames)
        var song = Song(scenes: [SongScene(pattern: 40, bars: 500), SongScene(pattern: -3, bars: 0)])
        song.clamp(patternCount: 16)
        #expect(song.scenes.map(\.pattern) == [15, 0] && song.scenes.map(\.bars) == [64, 1])
    }

    // MARK: Preset

    @MainActor @Test func songRoundTripsAndOldPresetsLoadWithoutSong() throws {
        let engine = SequencerEngine()
        let song = Song(scenes: [SongScene(pattern: 0, bars: 4), SongScene(pattern: 9, bars: 8)],
                        enabled: true, loops: false)
        engine.replaceSong(song)
        let data = try #require(engine.saveData())
        #expect(String(decoding: data, as: UTF8.self).contains("\"song\""))

        let other = SequencerEngine()
        #expect(other.loadData(data))
        #expect(other.song == song)
        #expect(other.patterns.count == 16)

        // Datei aus v1.13.x: vier Patterns, kein Song.
        let old = try JSONEncoder().encode(PresetManager.PresetFile(
            bpm: 100, swing: 50, patterns: ["A", "B", "C", "D"].map { Pattern(name: $0) }))
        #expect(other.loadData(old))
        #expect(other.song == Song() && other.patterns.count == 16)
        #expect(other.patterns.map(\.name) == Pattern.slotNames)

        // Leerer Song wird nicht geschrieben.
        #expect(!String(decoding: try #require(other.saveData()), as: UTF8.self).contains("\"song\""))
    }

    @MainActor @Test func songEditsAreUndoable() {
        let engine = SequencerEngine()
        let um = UndoManager(); engine.undoManager = um
        var s = engine.song
        s.scenes.append(SongScene(pattern: 3, bars: 2))
        engine.setSongUndoable(s, actionName: "Song")
        #expect(engine.song.scenes.count == 1)
        #expect(engine.songState.song.scenes.first?.pattern == 3)
        um.undo()
        #expect(engine.song.scenes.isEmpty)
        um.redo()
        #expect(engine.song.scenes.first?.bars == 2)
    }

    // MARK: Wiedergabe

    /// Song A (1 Takt) → B (1 Takt), Loop. Track 0 von A hat 3 Steps (18 Pulse) — sein Ende
    /// fällt NICHT auf den Takt. Der Wechsel kommt trotzdem exakt auf Puls 96 (Taktgrenze),
    /// ohne Main dazwischen; nach B (Puls 192) wieder A.
    @MainActor @Test func scenesSwitchExactlyOnTheBarLine() throws {
        let engine = SequencerEngine()
        arm(engine, pattern: 0, note: 60, stepCount: 3)
        arm(engine, pattern: 1, note: 72, stepCount: 16)
        engine.replaceSong(Song(scenes: [SongScene(pattern: 0, bars: 1), SongScene(pattern: 1, bars: 1)],
                                enabled: true, loops: true))
        engine.switchPattern(1)   // Song beginnt trotzdem mit Szene 1 (A)
        let log = attachOnLog(engine)
        engine.setClockMode(.external)
        engine.play()
        defer { engine.stop() }
        #expect(engine.currentPatternIndex == 0)
        #expect(engine.queuedPatternIndex == 1)
        #expect(engine._rt1PublishedBundle()?.switchAtPulse == 96)
        #expect(engine.songState.playingScene == 0)

        let t0 = mach_absolute_time() + 5_000_000_000
        for p in 0..<96 { engine._rt3aDriveOneExternalTick(at: t0 + UInt64(p) * gap) }
        #expect(log.all.map(\.note) == [60, 60, 60, 60, 60, 60], "A: Pulse 0, 18, … 90")
        engine._rt3aDriveOneExternalTick(at: t0 + 96 * gap)
        #expect(log.all.last?.note == 72)
        #expect(log.all.last?.ts == t0 + 96 * gap, "B beginnt exakt auf dem Taktstrich")

        // Main zieht nach und merkt den Rückweg zu A auf Puls 192 vor.
        engine.publishSnapshot()
        #expect(engine.currentPatternIndex == 1)
        #expect(engine.songState.playingScene == 1)
        #expect(engine.queuedPatternIndex == 0)
        #expect(engine._rt1PublishedBundle()?.switchAtPulse == 192)

        // Manuelle Patternwahl ist im laufenden Song wirkungslos.
        engine.switchPattern(5)
        #expect(engine.queuedPatternIndex == 0)

        for p in 97...192 { engine._rt3aDriveOneExternalTick(at: t0 + UInt64(p) * gap) }
        #expect(log.all.last?.note == 60)
        #expect(log.all.last?.ts == t0 + 192 * gap)
        #expect(log.all.filter { $0.note == 72 }.count == 1)
    }

    /// A → B → C → A (je 1 Takt, Loop) über vier Grenzen, ohne dass Main nachzieht
    /// (Codex H3): jeder Wechsel liegt exakt auf dem Taktstrich, das zurückkehrende A beginnt
    /// frisch. Danach zieht Main in einem Schritt nach.
    @MainActor @Test func songAdvancesSeveralScenesWithoutMain() throws {
        let engine = SequencerEngine()
        arm(engine, pattern: 0, note: 60, stepCount: 16)
        arm(engine, pattern: 1, note: 62, stepCount: 16)
        arm(engine, pattern: 2, note: 64, stepCount: 3)   // Track-0-Ende nicht auf dem Takt
        engine.replaceSong(Song(scenes: [SongScene(pattern: 0, bars: 1), SongScene(pattern: 1, bars: 1),
                                         SongScene(pattern: 2, bars: 1)], enabled: true, loops: true))
        let log = attachOnLog(engine)
        engine.setClockMode(.external)
        engine.play()
        defer { engine.stop() }
        let b = engine._rt1PublishedBundle()
        #expect(b?.planCount ?? 0 >= 3, "mehrere Wechsel vorausgeplant")
        let t0 = mach_absolute_time() + 5_000_000_000
        for p in 0...(4 * 96) { engine._rt3aDriveOneExternalTick(at: t0 + UInt64(p) * gap) }
        let firsts = [0, 96, 192, 288, 384].map { bar in log.all.first { $0.ts == t0 + UInt64(bar) * gap }?.note }
        #expect(firsts == [60, 62, 64, 60, 62], "A, B, C, A, B jeweils auf dem Taktstrich")
        #expect(log.all.filter { $0.note == 64 }.count == 6, "C: Pulse 0, 18, … 90 seines Takts")
        // Main zieht nach: aktuelles Pattern = B (fünfte Aktivierung), Szene 2.
        engine.publishSnapshot()
        #expect(engine.currentPatternIndex == 1)
        #expect(engine.songState.playingScene == 1)
        #expect(engine.queuedPatternIndex == 2)
        #expect(engine._rt1PublishedBundle()?.switchAtPulse == 480)
    }

    /// Song ohne Loop: ab dem Ende schlägt der Tick-Thread nichts mehr an.
    @MainActor @Test func songWithoutLoopFallsSilentAtTheEnd() throws {
        let engine = SequencerEngine()
        arm(engine, pattern: 0, note: 60, stepCount: 4)   // 24 Pulse je Durchlauf
        engine.replaceSong(Song(scenes: [SongScene(pattern: 0, bars: 1)], enabled: true, loops: false))
        let log = attachOnLog(engine)
        engine.setClockMode(.external)
        engine.play()
        defer { engine.stop() }
        #expect(engine._rt1PublishedBundle()?.stopAtPulse == 96)
        #expect(engine.queuedPatternIndex == nil)
        let t0 = mach_absolute_time() + 5_000_000_000
        for p in 0..<140 { engine._rt3aDriveOneExternalTick(at: t0 + UInt64(p) * gap) }
        #expect(log.all.count == 4, "Pulse 0, 24, 48, 72 — danach Stille")
        #expect(log.all.allSatisfy { $0.ts < t0 + 96 * gap })
    }

    /// Song aus: Wiedergabe wie bisher, Wechsel an der Track-1-Grenze.
    @MainActor @Test func songOffKeepsTrackOneBoundary() {
        let engine = SequencerEngine()
        engine.replaceSong(Song(scenes: [SongScene(pattern: 2, bars: 1)], enabled: false))
        engine.setClockMode(.external)
        engine.play()
        defer { engine.stop() }
        #expect(engine.currentPatternIndex == 0)
        engine.switchPattern(3)
        #expect(engine.queuedPatternIndex == 3)
        #expect(engine._rt1PublishedBundle()?.switchAtPulse == -1)
        #expect(engine._rt1PublishedBundle()?.stopAtPulse == -1)
    }
}
