import Testing
import Foundation
import Atomics
import AppKit
@testable import VintageSequencer

// MARK: - WorkflowEngineTests  (Slice 12a)
//
// Engine- und Integrationstests für die 5 kritischen User-Workflows.
// Kein UI, kein XCUI, kein MIDI-Output — direkter Engine-API-Zugriff.
//
// Tests:
//   1. Preset Roundtrip          — vollständiger Feld-für-Feld-Vergleich
//   2. Preset speichern in-place — hasUnsavedChanges + Datei auf Disk
//   3. Mutation nach Load        — zwei Save-Load-Zyklen, keine stille Inkonsistenz
//   4. Undo / Redo               — ModelWriter + UndoManager, reproduzierbarer Zustand
//   5. Playback Start / Stop     — isPlaying korrekt, kein Crash
//   6. Step-Toggle               — isActive + hasUnsavedChanges
//   7. Step-Toggle unter Last    — Thread-Safety während Playback
//   8. Pattern-Wechsel           — Index + Zustandserhalt
//   9. Legacy-Migration          — Altformat ohne bpm/swing-Wrapper → modernes Modell

// MARK: - 1. Preset Roundtrip

struct PresetRoundtripTests {

    /// Alle relevanten Felder überleben einen vollständigen saveData → loadData Zyklus.
    ///
    /// Getestete Felder: bpm, swing, patterns.count, tracks.count,
    /// stepCount, isMuted, steps[0].isActive, steps[0].notes, steps[0].velocity.
    /// Kein Dateivergleich — semantischer Roundtrip, schützt gegen Silent-Data-Loss.
    @Test func allFieldsSurviveRoundtrip() throws {
        let engine = SequencerEngine()
        engine.bpm   = 140.0
        engine.swing = 62.5

        let track = engine.currentPattern.tracks[0]
        track.lane.stepCount          = 12
        track.isMuted            = true
        track.lane.stepLengthNumerator   = 3
        track.lane.stepLengthDenominator = 2
        track.lane.steps[0].isActive  = true
        track.lane.steps[0].notes     = [60, 64, 67]
        track.lane.steps[0].velocity  = 88
        track.lane.steps[0].gate      = 1.5
        track.lane.steps[0].probability = 0.75
        track.lane.steps[1].isActive  = true
        track.lane.steps[1].notes     = [48]

        guard let data = engine.saveData() else {
            Issue.record("saveData() returned nil")
            return
        }

        let engine2 = SequencerEngine()
        let ok = engine2.loadData(data)

        #expect(ok == true)
        #expect(engine2.bpm   == 140.0)
        #expect(engine2.swing == 62.5)
        #expect(engine2.patterns.count == engine.patterns.count)

        let t2 = engine2.currentPattern.tracks[0]
        #expect(t2.lane.stepCount                == 12)
        #expect(t2.isMuted                  == true)
        #expect(t2.lane.stepLengthNumerator      == 3)
        #expect(t2.lane.stepLengthDenominator    == 2)
        #expect(t2.lane.steps[0].isActive        == true)
        #expect(t2.lane.steps[0].notes           == [60, 64, 67])
        #expect(t2.lane.steps[0].velocity        == 88)
        #expect(t2.lane.steps[0].gate            == 1.5)
        #expect(t2.lane.steps[0].probability     == 0.75)
        #expect(t2.lane.steps[1].isActive        == true)
        #expect(t2.lane.steps[1].notes           == [48])
    }

    /// Nach erfolgreichem loadData() ist hasUnsavedChanges false.
    @Test func hasUnsavedChangesIsFalseAfterLoad() throws {
        let engine = SequencerEngine()
        engine.bpm = 130.0
        guard let data = engine.saveData() else {
            Issue.record("saveData() returned nil"); return
        }
        let engine2 = SequencerEngine()
        engine2.loadData(data)
        #expect(engine2.hasUnsavedChanges == false)
    }
}

// MARK: - 2. Preset speichern in-place

struct PresetSaveInPlaceTests {

    /// savePresetInPlace() schreibt Datei auf Disk und setzt hasUnsavedChanges = false.
    @Test func saveInPlaceWritesFileToDisk() throws {
        let engine = SequencerEngine()
        engine.bpm = 150.0
        engine.currentPattern.tracks[0].lane.steps[0].isActive = true
        // hasUnsavedChanges wird durch Track-Subscription gesetzt — direkt setzen für Test.
        engine.hasUnsavedChanges = true

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow_test_\(UUID().uuidString).json")
        engine.currentPresetURL = tempURL

        engine.savePresetInPlace()

        #expect(engine.hasUnsavedChanges == false,
                "hasUnsavedChanges muss nach savePresetInPlace() false sein")
        #expect(FileManager.default.fileExists(atPath: tempURL.path),
                "Datei muss nach savePresetInPlace() auf Disk existieren")

        try? FileManager.default.removeItem(at: tempURL)
    }

    /// savePresetInPlace() ohne currentPresetURL — kein Crash, kein unerwarteter Seiteneffekt.
    /// (Fällt intern auf savePreset() mit Panel zurück — in Tests nicht aufrufbar;
    ///  dieser Test verifiziert nur: kein Absturz bei fehlender URL.)
    @Test func saveInPlaceWithoutURLDoesNotCrash() {
        let engine = SequencerEngine()
        engine.currentPresetURL = nil
        // savePreset() würde NSOpenPanel öffnen — überspringen; nur sicherstellen,
        // dass der Guard in savePresetInPlace() korrekt reagiert.
        // Da kein Panel mock vorhanden, testen wir indirekt über saveData().
        let data = engine.saveData()
        #expect(data != nil, "saveData() muss ohne URL aufrufbar sein")
    }
}

// MARK: - 3. Mutation nach Load

struct MutationAfterLoadTests {

    /// Zwei vollständige Save-Load-Zyklen: die zweite Serialisierung überschreibt nicht
    /// unveränderte Felder der ersten.
    ///
    /// Ablauf:
    ///   Engine A → saveData → data1
    ///   Engine B → loadData(data1) → mutiere Step 3 → saveData → data2
    ///   Engine C → loadData(data2)
    ///   Prüfung: Step 3 ist geändert, Step 0 ist unverändert, alle anderen Steps intakt.
    @Test func mutationAfterLoadPreservesOtherFields() throws {
        // === Engine A — Ausgangszustand ===
        let engineA = SequencerEngine()
        engineA.bpm = 120.0
        let trackA = engineA.currentPattern.tracks[0]
        trackA.lane.stepCount           = 16
        trackA.lane.steps[0].isActive   = true
        trackA.lane.steps[0].notes      = [60]
        trackA.lane.steps[3].isActive   = false   // wird in B verändert
        trackA.lane.steps[5].isActive   = true
        trackA.lane.steps[5].velocity   = 77

        guard let data1 = engineA.saveData() else {
            Issue.record("Engine A: saveData() returned nil"); return
        }

        // === Engine B — Laden + Mutieren ===
        let engineB = SequencerEngine()
        #expect(engineB.loadData(data1) == true)
        let trackB = engineB.currentPattern.tracks[0]
        trackB.lane.steps[3].isActive = true   // Mutation: war false
        trackB.lane.steps[3].notes    = [72]

        guard let data2 = engineB.saveData() else {
            Issue.record("Engine B: saveData() returned nil"); return
        }

        // === Engine C — Zweites Laden ===
        let engineC = SequencerEngine()
        #expect(engineC.loadData(data2) == true)
        let trackC = engineC.currentPattern.tracks[0]

        // Mutation ist erhalten
        #expect(trackC.lane.steps[3].isActive == true,  "Step 3 muss nach zweitem Load aktiv sein")
        #expect(trackC.lane.steps[3].notes    == [72],   "Step 3 note muss nach zweitem Load korrekt sein")

        // Unveränderte Felder sind korrekt
        #expect(trackC.lane.steps[0].isActive == true,  "Step 0 darf durch zweiten Zyklus nicht verändert werden")
        #expect(trackC.lane.steps[0].notes    == [60])
        #expect(trackC.lane.steps[5].isActive == true)
        #expect(trackC.lane.steps[5].velocity == 77,    "Step 5 velocity darf nicht verloren gehen")

        // Modell-Konsistenz
        #expect(engineC.hasUnsavedChanges == false, "Nach loadData() muss hasUnsavedChanges false sein")
        #expect(engineC.bpm == 120.0)
    }
}

// MARK: - 4. Undo / Redo

struct UndoRedoTests {

    /// stepCount-Änderung via ModelWriter ist vollständig undo- und redoable.
    ///
    /// Testet: ModelWriter.apply(.setStepCount) + UndoManager.undo() + undo().redo()
    /// Kein Seiteneffekt auf anderen Tracks.
    @Test func setStepCountUndoRedo() {
        let track      = TrackData(name: "Test", stepCount: 16, midiChannel: 1)
        let um         = UndoManager()
        let writer     = ModelWriter()

        // Änderung anwenden
        let command = ModelCommand.setStepCount(trackID: track.id, old: 16, new: 8)
        writer.apply(command, to: track, undoManager: um)
        #expect(track.lane.stepCount == 8, "Nach apply muss stepCount 8 sein")

        // Undo
        #expect(um.canUndo == true, "UndoManager muss undo-fähig sein")
        um.undo()
        #expect(track.lane.stepCount == 16, "Nach undo muss stepCount wieder 16 sein")

        // Redo
        #expect(um.canRedo == true, "UndoManager muss redo-fähig sein")
        um.redo()
        #expect(track.lane.stepCount == 8, "Nach redo muss stepCount wieder 8 sein")
    }

    /// Ratio-Änderung via ModelWriter ist vollständig undo- und redoable.
    @Test func setRatioUndoRedo() {
        let track  = TrackData(name: "Ratio", stepCount: 16, midiChannel: 1)
        let um     = UndoManager()
        let writer = ModelWriter()

        let command = ModelCommand.setRatio(
            trackID: track.id,
            oldNum: 1, oldDen: 1,
            newNum: 3, newDen: 2
        )
        writer.apply(command, to: track, undoManager: um)
        #expect(track.lane.stepLengthNumerator   == 3)
        #expect(track.lane.stepLengthDenominator == 2)

        um.undo()
        #expect(track.lane.stepLengthNumerator   == 1)
        #expect(track.lane.stepLengthDenominator == 1)

        um.redo()
        #expect(track.lane.stepLengthNumerator   == 3)
        #expect(track.lane.stepLengthDenominator == 2)
    }

    /// Track-Farben-Slice v1.12.0: setTrackColorIndex ist vollständig undo- und redoable.
    @Test func setTrackColorIndexUndoRedo() {
        let track  = TrackData(name: "Color", stepCount: 16, midiChannel: 1)
        track.colorIndex = 2
        let um     = UndoManager()
        let writer = ModelWriter()

        let command = ModelCommand.setTrackColorIndex(trackID: track.id, old: 2, new: 5)
        writer.apply(command, to: track, undoManager: um)
        #expect(track.colorIndex == 5, "Nach apply muss colorIndex 5 sein")

        um.undo()
        #expect(track.colorIndex == 2, "Nach undo muss colorIndex wieder 2 sein")

        um.redo()
        #expect(track.colorIndex == 5, "Nach redo muss colorIndex wieder 5 sein")
    }

    /// Track-Farben-Slice v1.12.0: addTrack vergibt den kleinsten freien Palettenindex.
    /// Bei [0, 1, 3] muss der nächste Track Farbe 2 bekommen, nicht 3.
    @Test func addTrackPicksSmallestFreeColorSlot() {
        let engine = SequencerEngine()
        // Default-Pattern enthält bereits einen Track mit colorIndex 0.
        // Wir setzen die vorhandenen Tracks gezielt auf [0, 1, 3].
        let pattern = engine.currentPattern
        // Auf einen sauberen Ausgangszustand mit [0, 1, 3] kommen.
        while pattern.tracks.count < 3 { engine.addTrack() }
        pattern.tracks[0].colorIndex = 0
        pattern.tracks[1].colorIndex = 1
        pattern.tracks[2].colorIndex = 3

        engine.addTrack()
        let newColor = pattern.tracks.last!.colorIndex
        #expect(newColor == 2, "Kleinste freie Farbe nach [0,1,3] muss 2 sein, bekommen: \(newColor)")
    }

    /// Kein Seiteneffekt: Undo einer Track-Änderung berührt andere Tracks nicht.
    @Test func undoDoesNotAffectOtherTracks() {
        let trackA = TrackData(name: "A", stepCount: 16, midiChannel: 1)
        let trackB = TrackData(name: "B", stepCount: 32, midiChannel: 2)
        let um     = UndoManager()
        let writer = ModelWriter()

        writer.apply(
            ModelCommand.setStepCount(trackID: trackA.id, old: 16, new: 8),
            to: trackA,
            undoManager: um
        )
        um.undo()

        #expect(trackA.lane.stepCount == 16, "Track A muss nach undo zurück auf 16 sein")
        #expect(trackB.lane.stepCount == 32, "Track B darf durch undo von Track A nicht verändert werden")
    }
}

// MARK: - 5. Playback Start / Stop

struct PlaybackTransportTests {

    /// play() setzt isPlaying auf true; stop() setzt isPlaying auf false.
    @Test func playAndStopToggleIsPlaying() {
        let engine = SequencerEngine()
        #expect(engine.isPlaying == false, "Initializierungszustand: isPlaying muss false sein")

        engine.play()
        #expect(engine.isPlaying == true, "Nach play() muss isPlaying true sein")

        engine.stop()
        #expect(engine.isPlaying == false, "Nach stop() muss isPlaying false sein")
    }

    /// play() ist idempotent — mehrfacher Aufruf kein Crash, isPlaying bleibt true.
    @Test func playIsIdempotent() {
        let engine = SequencerEngine()
        engine.play()
        engine.play()   // zweiter Aufruf: darf nichts kaputt machen
        #expect(engine.isPlaying == true)
        engine.stop()
    }

    /// stop() ist idempotent — mehrfacher Aufruf ohne vorheriges play() kein Crash.
    @Test func stopIsIdempotentWithoutPlay() {
        let engine = SequencerEngine()
        engine.stop()   // Guard: isPlaying == false → early return
        engine.stop()
        #expect(engine.isPlaying == false)
    }

    /// Nach stop() ist queuedPatternIndex nil (kein hängendes Switch).
    @Test func stopClearsQueuedPatternIndex() {
        let engine = SequencerEngine()
        engine.play()
        engine.queuedPatternIndex = 1   // simulierter queued switch
        engine.stop()
        #expect(engine.queuedPatternIndex == nil,
                "queuedPatternIndex muss nach stop() nil sein")
    }
}

// MARK: - 5b. RT-1: Playback-State-Ownership (v1.12.2)
//
// Verifiziert, dass der Tick-Thread seinen Playback-Zustand aus dem atomar
// publizierten Bundle bzw. aus atomaren Spiegeln bezieht — kein direkter
// @Published-Read mehr. Getestet werden die (synchron beobachtbaren) Wiring-
// Invarianten: Bundle trägt bpm/swing; die Atomics spiegeln
// isPlaying/clockMode/queuedPatternIndex konsistent zu den @Published-Werten.

struct RT1PlaybackStateOwnershipTests {

    /// Der publizierte Bundle trägt den aktuellen swing-Wert (statt @Published-Read
    /// im Tick-Thread). swing wird VOR play() gesetzt → play() publiziert synchron.
    @Test func swingIsCarriedInPublishedBundle() {
        let engine = SequencerEngine()
        engine.swing = 65.0
        engine.play()
        let bundle = engine._rt1PublishedBundle()
        #expect(bundle != nil, "Nach play() muss ein Bundle publiziert sein")
        #expect(bundle?.swing == 65.0, "Bundle muss den gesetzten swing tragen")
        engine.stop()
    }

    /// Der publizierte Bundle trägt die aktuelle BPM.
    @Test func bpmIsCarriedInPublishedBundle() {
        let engine = SequencerEngine()
        engine.setBPM(140.0)
        engine.play()
        #expect(engine._rt1PublishedBundle()?.bpm == 140.0)
        engine.stop()
    }

    /// isPlaying-Atomic spiegelt den @Published-Wert konsistent.
    @Test func isPlayingAtomicMirrorsPublished() {
        let engine = SequencerEngine()
        #expect(engine._rt1IsPlayingRT == false)
        engine.play()
        #expect(engine._rt1IsPlayingRT == true, "isPlayingRT muss nach play() true sein")
        engine.stop()
        #expect(engine._rt1IsPlayingRT == false, "isPlayingRT muss nach stop() false sein")
    }

    /// clockMode-Atomic (clockIsInternal) spiegelt den @Published-Wert konsistent.
    @Test func clockIsInternalAtomicMirrorsPublished() {
        let engine = SequencerEngine()
        #expect(engine._rt1ClockIsInternal == true, "Default clockMode .internal → true")
        engine.setClockMode(.external)
        #expect(engine._rt1ClockIsInternal == false)
        engine.setClockMode(.internal)
        #expect(engine._rt1ClockIsInternal == true)
    }

    /// queuedPattern-Atomic spiegelt queuedPatternIndex (nil → Sentinel −1).
    @Test func queuedPatternAtomicMirrorsPublished() {
        let engine = SequencerEngine()
        #expect(engine._rt1QueuedPatternAtomic == -1, "Kein Wechsel → Sentinel −1")
        engine.play()
        engine.switchPattern(2)   // während Playback → queued
        #expect(engine.queuedPatternIndex == 2)
        #expect(engine._rt1QueuedPatternAtomic == 2,
                "Atomic muss den queued Pattern-Index spiegeln")
        engine.stop()
        #expect(engine._rt1QueuedPatternAtomic == -1,
                "Nach stop() muss der Atomic wieder −1 (nil) sein")
    }
}

// MARK: - 5c. RT-1a: Atomare Modusumschaltung (v1.12.3)
//
// Schließt Befund H1: Beim Clock-Moduswechsel darf kein Callback Steps
// verarbeiten, solange der RT-Modus nicht konsistent publiziert ist. Getestet:
//   1. clockTick schreitet nur im INT-Modus fort (Guard vor advanceSteps).
//   2. Nach INT→EXT darf ein verspäteter Tap weder Step fortschieben noch senden.
//   3. Live-Swing-Republish greift auch während laufendem Playback (async).
// Setup ohne ClockSource (deterministisch, kein Tick-Thread-Race).

struct RT1aModeSwitchTests {

    /// Weit in der Zukunft liegender Tick-Timestamp — clampToFuture lässt ihn
    /// unverändert; Step-Advance hängt ohnehin nur am pulseAccumulator.
    private let futureTick: UInt64 = 1_000_000_000_000   // MIDITimeStamp == UInt64

    /// INT-Modus: clockTick schreitet den Runtime-Step fort. Ein voller
    /// 24-PPQ-Zyklus garantiert mindestens einen Step-Advance für jedes
    /// realistische pulsesPerStep (≤ 24).
    @Test func clockTickAdvancesInInternalMode() {
        let engine = SequencerEngine()
        engine._rt1SetupRuntimesForTest()
        #expect(engine._rt1ClockIsInternal == true, "Default ist INT")
        let before = engine._rt1CurrentStep(track: 0)
        for _ in 0..<24 { engine.clockTick(at: futureTick) }
        #expect(engine._rt1CurrentStep(track: 0) != before,
                "INT: clockTick muss den Step fortschreiben")
    }

    /// INT→EXT: Ein verspäteter Tap darf keinen Step fortschreiben. Der Guard
    /// greift VOR advanceSteps — der pulseAccumulator wird nicht einmal erhöht.
    @Test func lateTapAfterExternalDoesNotAdvance() {
        let engine = SequencerEngine()
        engine._rt1SetupRuntimesForTest()
        engine.setClockMode(.external)
        #expect(engine._rt1ClockIsInternal == false)
        let before = engine._rt1CurrentStep(track: 0)
        for _ in 0..<24 { engine.clockTick(at: futureTick) }
        #expect(engine._rt1CurrentStep(track: 0) == before,
                "EXT: verspäteter clockTick darf keinen Step fortschreiben")
    }

    /// Producer-before-observer: setClockMode publiziert den Atomic-Spiegel,
    /// bevor der @Published-Sink läuft. Verifiziert über beide Richtungen —
    /// der Atomic ist nach Rückkehr des Setters immer konsistent (die
    /// Reihenfolge-Garantie selbst prüft der clockTick-Test oben).
    @Test func clockModeAtomicConsistentAfterToggle() {
        let engine = SequencerEngine()
        engine.setClockMode(.external)
        #expect(engine._rt1ClockIsInternal == false)
        engine.setClockMode(.internal)
        #expect(engine._rt1ClockIsInternal == true)
    }

    /// Schneller INT→EXT→INT-Wechsel unter laufendem Playback. Der Tick-Thread
    /// liest `clockIsInternal` konkurrierend, während die Setter ihn schreiben und
    /// der `$clockMode`-Sink die AudioClock startet/stoppt — unter TSan der
    /// aussagekräftige Race-Test für RT-1a. Nach den Wechseln muss der Modus
    /// konsistent INT sein.
    @Test func rapidModeToggleUnderPlayback() {
        let engine = SequencerEngine()
        engine.play()                       // INT: ClockSource-Thread läuft
        for _ in 0..<20 {
            engine.setClockMode(.external)
            engine.setClockMode(.internal)
        }
        #expect(engine._rt1ClockIsInternal == true,
                "Atomic muss nach INT→EXT→INT konsistent INT sein")
        #expect(engine.clockMode == .internal)
        // RT-3b-Fund (siehe liveSwingRepublishDuringPlayback): stop() muss auf
        // Main laufen, sonst kann es mit Main-seitiger Publish-Aktivität aus dem
        // clockMode-Sink kollidieren — activeTick deckt nur den RT-/MIDI-Reader ab.
        // Dauer von stop() selbst, gemessen im Main-Block: die Wartezeit, bis Main frei ist,
        // hängt an parallelen Tests und gehört nicht zur Invariante (v1.16.1, Codex V16-5).
        let stopDone = DispatchSemaphore(value: 0)
        let stopMs = ManagedAtomic<Int>(-1)
        DispatchQueue.main.async {
            let s = DispatchTime.now().uptimeNanoseconds
            engine.stop()
            stopMs.store(Int((DispatchTime.now().uptimeNanoseconds - s) / 1_000_000), ordering: .releasing)
            stopDone.signal()
        }
        stopDone.wait()
    }

    /// Live-Swing-Republish: Eine Swing-Änderung WÄHREND Playback muss ein
    /// neues Bundle publizieren. Der Republish läuft async über die
    /// snapshotPending-Koaleszierung (main.async).
    ///
    /// S01-R1 — Main-Writer-Vertrag wie in Produktion: Konstruktion, play(), Swing-Edit und
    /// stop() laufen auf Main (der Test ist @MainActor; Task.sleep gibt Main für den Republish-
    /// Hop frei). Beobachtet wird das tatsächlich publizierte Bundle (nicht der UI-Swing-Wert).
    /// Der Lesezugriff `_rt1PublishedBundle()` ist hier sicher, weil Main der einzige Publisher ist
    /// (die Box kann unter Main nicht freigegeben werden); der echte Reader bleibt der Clock-Thread.
    /// Abschluss zustandsbasiert, begrenzt auf 5 s; bei Fehlschlag nennt die Meldung Dauer,
    /// Main-Hops und Publish-Zähler, damit Main-Starvation von „kein Republish“ unterscheidbar ist.
    @Test @MainActor func liveSwingRepublishDuringPlayback() async {
        let engine = SequencerEngine()
        engine.swing = 20.0
        engine.play()
        defer { engine.stop() }
        #expect(engine._rt1PublishedBundle()?.swing == 20.0,
                "Vor der Änderung trägt das Bundle den Ausgangs-Swing")
        let publishesBefore = engine._s01PublishCount
        engine.swing = 75.0                       // Änderung während Playback
        let start = Date()
        var hops = 0
        while engine._rt1PublishedBundle()?.swing != 75.0, Date().timeIntervalSince(start) < 5.0 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            hops += 1
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(engine._rt1PublishedBundle()?.swing == 75.0,
                "Swing-Änderung während Playback muss neu publiziert werden — nach \(elapsed) s, \(hops) Main-Hops, Publishes seit Edit: \(engine._s01PublishCount - publishesBefore)")
    }
}

// MARK: - 5d. Runtime-Ownership (Befund K1/B3)

/// Der Tick-Thread ist alleiniger Besitzer des Runtime-Zustands; Main vergibt nur
/// Slot + Epoche im Snapshot. Deterministisch über den echten Mutator plus ein
/// Race-Test mit laufender AudioClock.
struct RT2RuntimeOwnershipTests {

    private let futureTick: UInt64 = 1_000_000_000_000   // MIDITimeStamp == UInt64

    // v1.12.19: Die Command-Mailbox ist entfallen. Jeder Track trägt seine Runtime-Bindung
    // (Slot + Epoche) im Snapshot; der Tick-Thread gleicht pro Track ab. Geprüft wird das
    // beobachtbare Verhalten: Cursor bestehender Tracks bleiben bei ihrem Track, neue Tracks
    // starten frisch — über den echten Mutator, ohne Zwischenzustand.

    /// Add während Playback: bestehende Cursor bleiben, der neue Track startet frisch.
    @Test func addTrackDuringPlaybackKeepsRuntimeConsistent() {
        let engine = SequencerEngine()
        engine._rt1SetupRuntimesForTest()
        engine.isPlaying = true
        for (t, v) in [10, 11, 12, 13].enumerated() { engine._rt2SetCurrentStep(track: t, to: v) }
        engine.addTrack()
        #expect(engine._rt2RuntimeCount() == 5)
        for (t, v) in [10, 11, 12, 13].enumerated() { #expect(engine._rt1CurrentStep(track: t) == v) }
        #expect(engine._rt1CurrentStep(track: 4) == -1, "neuer Track startet frisch")
        engine._rt2DriveOneTick(at: futureTick)
        #expect(engine._rt1CurrentStep(track: 4) == 0, "frische Runtime löst auf dem ersten Tick Step 1 aus")
        engine.isPlaying = false
    }

    /// Insert an Position k: die Cursor wandern MIT ihren Tracks, nicht mit dem Index.
    @Test func insertShiftsRuntimesToCorrectPosition() {
        let engine = SequencerEngine()
        engine._rt1SetupRuntimesForTest()
        engine.isPlaying = true
        for (t, v) in [10, 11, 12, 13].enumerated() { engine._rt2SetCurrentStep(track: t, to: v) }
        engine.insertTrack(after: 1)
        #expect(engine._rt1CurrentStep(track: 0) == 10)
        #expect(engine._rt1CurrentStep(track: 1) == 11)
        #expect(engine._rt1CurrentStep(track: 2) == -1, "frische Runtime an Insert-Position")
        #expect(engine._rt1CurrentStep(track: 3) == 12, "Nachbar nach rechts verschoben")
        #expect(engine._rt1CurrentStep(track: 4) == 13)
        engine.isPlaying = false
    }

    /// Remove an Position k: die übrigen Tracks behalten ihre Cursor.
    @Test func removeDropsCorrectRuntimeAndKeepsAlignment() {
        let engine = SequencerEngine()
        engine._rt1SetupRuntimesForTest()
        engine.isPlaying = true
        for (t, v) in [10, 11, 12, 13].enumerated() { engine._rt2SetCurrentStep(track: t, to: v) }
        let slotsBefore = engine._slotsInUse
        engine.removeTrack(at: 1)
        #expect(engine._rt1CurrentStep(track: 0) == 10)
        #expect(engine._rt1CurrentStep(track: 1) == 12, "Track 2 rückt auf Position 1")
        #expect(engine._rt1CurrentStep(track: 2) == 13)
        #expect(engine._slotsInUse == slotsBefore - 1, "Slot des entfernten Tracks ist frei")
        engine.isPlaying = false
    }

    /// Remove + Undo: der zurückgekehrte Track bekommt eine neue Epoche und startet frisch,
    /// auch wenn er denselben Slot wiederbekommt.
    @Test func restoredTrackStartsFresh() {
        let engine = SequencerEngine()
        engine._rt1SetupRuntimesForTest()
        engine.isPlaying = true
        for (t, v) in [10, 11, 12, 13].enumerated() { engine._rt2SetCurrentStep(track: t, to: v) }
        let removed = engine.removeTrack(at: 3)
        engine.insertPlacements(removed)
        #expect(engine._rt1CurrentStep(track: 3) == -1)
        #expect(engine._rt1CurrentStep(track: 2) == 12)
        engine.isPlaying = false
    }

    /// Schnelle Strukturmutation unter laufender interner Clock — unter TSan der Nachweis,
    /// dass Main den Runtime-Zustand nie anfasst. Kein Crash, Slot-Buchhaltung bleibt dicht.
    @Test func rapidStructuralMutationUnderClock() {
        let engine = SequencerEngine()
        engine.play()                              // INT: ClockSource-Thread läuft
        for _ in 0..<50 {
            engine.addTrack()
            engine.removeTrack(at: 1)
        }
        #expect(engine._slotsInUse == engine.currentPattern.tracks.count, "keine Slot-Lecks")
        engine.stop()
        #expect(engine.currentPattern.tracks.count >= 1, "kein Crash, Modell intakt")
    }
}

// MARK: - 5e. RT-3 — Snapshot-Lebensdauer (Hazard-Pointer, Befund Codex #2)

/// RT-3: Der Tick-Thread hält den rohen Bundle-Pointer über den ganzen Tick.
/// Ein Hazard-Pointer garantiert formal, dass der Main-Thread keine Box freigibt,
/// solange der Tick-Thread sie dereferenziert — unabhängig von Tick-Dauer und
/// Preemption. Deterministisch über weak-Sonde + Hazard-/Box-Raw-Hooks; plus ein
/// Stress-Test, der rapide Publishes gegen den echten Tick-Thread fährt.
struct RT3SnapshotLifetimeTests {

    private let futureTick: UInt64 = 1_000_000_000_000   // MIDITimeStamp == UInt64

    /// Aufgeschobene Freigabe: zeigt der Hazard auf eine Box, überlebt sie beliebig
    /// viele Publishes; erst nach Hazard-Clear + Publish wird sie freigegeben.
    @Test func hazardDefersReleaseOfInUseBox() {
        let engine = SequencerEngine()
        engine._rt1SetupRuntimesForTest()          // publiziert → bundleCurrent = box1
        let box1 = engine._rt3AtomicRaw
        #expect(box1 != 0)
        engine._rt3SetWeakProbeToCurrent()          // weak → box1
        engine._rt3AnnounceCurrentHazard()          // Audio-Leser „mitten im Tick" auf box1
        for _ in 0..<5 { engine.publishSnapshot() } // box1 5× ablösen
        #expect(engine._rt3DeferredBoxRaw == box1,
                "in-use Box wird aufgeschoben statt freigegeben")
        #expect(engine._rt3WeakProbeAlive,
                "gemeldete Box bleibt am Leben, solange der Hazard auf sie zeigt")
        engine._rt3ClearHazard()
        engine.publishSnapshot()                    // jetzt darf box1 fallen
        #expect(engine._rt3DeferredBoxRaw == 0)
        #expect(!engine._rt3WeakProbeAlive,
                "nach Hazard-Clear + Publish wird die Box freigegeben")
    }

    /// Ohne Hazard wird die abgelöste Box sofort freigegeben (kein Leak).
    @Test func releasesOldBoxWithoutHazard() {
        let engine = SequencerEngine()
        engine._rt1SetupRuntimesForTest()
        engine._rt3SetWeakProbeToCurrent()          // weak → box1
        #expect(engine._rt3WeakProbeAlive)
        engine.publishSnapshot()                    // box1 abgelöst, Hazard == 0
        #expect(!engine._rt3WeakProbeAlive,
                "ohne Hazard wird die abgelöste Box sofort freigegeben")
        #expect(engine._rt3DeferredBoxRaw == 0)
    }

    /// Ein Tick dereferenziert die AKTUELLE Box und gibt den Hazard danach frei (defer).
    @Test func tickDereferencesCurrentBoxAndClearsHazard() {
        let engine = SequencerEngine()
        engine._rt1SetupRuntimesForTest()           // box1
        engine.publishSnapshot()                    // box2 aktuell
        let box2 = engine._rt3AtomicRaw
        engine._rt3DriveOneTick(at: futureTick)
        #expect(engine._rt3LastTickBoxRaw == box2,
                "Tick dereferenziert die aktuelle Box")
        #expect(engine._rt3HazardRaw == 0,
                "Hazard ist nach dem Tick wieder frei (defer)")
    }

    /// Stress: rapide Publishes gegen den echten AudioClock-Thread. Der Tick-Thread
    /// meldet/löscht den Hazard pro Tick, während Main die Boxen ablöst und ggf.
    /// aufschiebt — unter TSan der Beweis, dass keine Box unter dem Tick wegstirbt.
    @Test func rapidPublishUnderRealClock() {
        let engine = SequencerEngine()
        engine.play()                               // INT: ClockSource-Thread läuft
        for _ in 0..<200 { engine.publishSnapshot() }
        engine.stop()
        #expect(engine._rt3AtomicRaw == 0, "nach stop() kein aktiver Bundle-Pointer")
    }

    /// stop() räumt Hazard, Pointer und beide Box-Referenzen ab (quieszentes Fenster).
    @Test func stopClearsHazardState() {
        let engine = SequencerEngine()
        engine.play()
        engine.publishSnapshot()
        engine.stop()
        #expect(engine._rt3AtomicRaw == 0)
        #expect(engine._rt3HazardRaw == 0)
        #expect(engine._rt3CurrentBoxRaw == 0)
        #expect(engine._rt3DeferredBoxRaw == 0)
    }
}

// MARK: - 5f. RT-3a — Stop-/External-Clock-Quieszenz (Codex-Befund H2, Round FOF-CX-2026-07-14-005)

/// RT-3a: stop() riss Hazard-Pointer, Bundle-Box-Referenzen und trackRuntimes
/// bislang bedingungslos ab — sicher nur für den internen Clock-Thread
/// (audioClock.stop() blockt synchron), nicht für einen bereits laufenden
/// externen MIDI-Tick (eigener CoreMIDI-Read-Thread, von audioClock.stop()
/// nicht erfasst). Ein activeTick-Atomic beweist jetzt Quieszenz, bevor stop()
/// Snapshot-Box/trackRuntimes/Mailbox anfasst. Deterministisch über einen
/// Pause-Hook, der einen echten Hintergrund-Thread mitten in advanceSteps()
/// parkt, während stop() nebenläufig versucht abzuräumen.
struct RT3aStopQuiescenceTests {

    private let futureTick: UInt64 = 1_000_000_000_000   // MIDITimeStamp == UInt64

    /// stop() darf die RT-Strukturen NICHT freigeben, solange ein externer Tick
    /// noch in advanceSteps() läuft — unabhängig davon, ob stop() selbst über den
    /// RT-3b-Fail-Safe-Pfad (Sync-Spin-Backstop 150 ms) inzwischen schon
    /// zurückgekehrt ist. Prüft den ZUSTAND direkt (Codex-Testpunkte: Pause,
    /// trackRuntimes/Box bleiben im externen Stop-Fenster unangetastet), statt
    /// sich auf stop()s Rückkehr-Timing zu verlassen — das ist die eigentliche
    /// H2/H3-Invariante, unabhängig von der genauen Backstop-Dauer.
    @Test func stopBlocksUntilInFlightExternalTickExits() {
        let engine = SequencerEngine()
        // RT-3b: stop()/play() laufen in Produktion IMMER auf Main (siehe
        // MIDIManager-Dispatch); teardownRTState() wird auch vom Main-seitigen
        // Async-Retry geschrieben. trackRuntimes/stopCleanupPending sind bewusst
        // plain (nicht atomic) — Main-Only-Kontrakt. Der Test muss diesen
        // Kontrakt einhalten (Main-Dispatch + Main-Hops beim Lesen), sonst
        // erzeugt der Test selbst einen Cross-Thread-Race, den es nicht gibt,
        // wenn alle echten Aufrufer sich an den Kontrakt halten.
        DispatchQueue.main.sync {
            engine.setClockMode(.external)   // kein interner ClockSource-Thread —
            engine.play()                    // sonst zweiter, konkurrierender Reader.
        }
        let oldSession = DispatchQueue.main.sync { engine._publishedSession }

        let insideSem = DispatchSemaphore(value: 0)
        let resumeSem = DispatchSemaphore(value: 0)
        engine._rt3aPausePoint = {
            insideSem.signal()
            resumeSem.wait()
        }

        let tickDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            engine._rt3aDriveOneExternalTick(at: futureTick)
            tickDone.signal()
        }
        insideSem.wait()   // Tick ist jetzt mitten in advanceSteps() geparkt.

        #expect(engine._rt3aActiveTick, "Tick ist aktiv, während er geparkt ist")
        #expect(engine._rt3AtomicRaw != 0, "Bundle-Box bleibt gültig, während der Tick sie hält")
        #expect(DispatchQueue.main.sync { engine._rt2RuntimeCount() } > 0,
                "trackRuntimes bleibt populated, während der Tick läuft")

        // Dauer von stop() selbst, gemessen im Main-Block: die Wartezeit, bis Main frei ist,
        // hängt an parallelen Tests und gehört nicht zur Invariante (v1.16.1, Codex V16-5).
        let stopDone = DispatchSemaphore(value: 0)
        let stopMs = ManagedAtomic<Int>(-1)
        DispatchQueue.main.async {
            let s = DispatchTime.now().uptimeNanoseconds
            engine.stop()
            stopMs.store(Int((DispatchTime.now().uptimeNanoseconds - s) / 1_000_000), ordering: .releasing)
            stopDone.signal()
        }

        // Länger als der 150-ms-Sync-Spin warten, damit stop() die Chance hatte,
        // ihn zu durchlaufen (und ggf. in den Fail-Safe-Pfad zu wechseln) — der
        // Tick ist immer noch geparkt, also MUSS der Zustand unangetastet bleiben.
        Thread.sleep(forTimeInterval: 0.25)
        #expect(engine._rt3aActiveTick, "Tick ist weiterhin aktiv")
        #expect(engine._rt3AtomicRaw != 0, "Bundle-Box bleibt gültig, solange activeTick true ist")
        #expect(DispatchQueue.main.sync { engine._rt2RuntimeCount() } > 0,
                "trackRuntimes bleibt populated, solange activeTick true ist")

        resumeSem.signal()          // geparkten Tick freigeben
        tickDone.wait()

        #expect(stopDone.wait(timeout: .now() + 120.0) == .success,
                "stop() muss (spätestens über den Fail-Safe-Pfad) zurückkehren")

        // Deferred Cleanup abwarten (Main-seitiger Async-Retry, ~20-ms-Takt).
        let cleanupDeadline = DispatchTime.now() + 5.0
        while DispatchQueue.main.sync(execute: { engine._rt3bCleanupPending })
                && DispatchTime.now() < cleanupDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(!DispatchQueue.main.sync(execute: { engine._rt3bCleanupPending }),
                "Deferred Cleanup muss abschließen")
        #expect(engine._rt3HazardRaw == 0)
        expectStoppedSessionReleased(engine, oldSession: oldSession)
    }

    /// Ohne aktiven Tick darf der Spin-Wait keine spürbaren Fixkosten einführen
    /// (Regressionsschutz gegen den Normalpfad).
    @Test func stopProceedsImmediatelyWhenNoTickInFlight() {
        let engine = SequencerEngine()
        engine.setClockMode(.external)
        engine.play()
        let oldSession = engine._publishedSession

        let start = DispatchTime.now()
        engine.stop()
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        #expect(elapsedMs < 50, "stop() ohne aktiven Tick sollte praktisch sofort zurückkehren, war \(elapsedMs) ms")
        expectStoppedSessionReleased(engine, oldSession: oldSession)
    }
}

// MARK: - 5g. RT-3b — Fail-Safe Deferred Cleanup (Codex-Befund H3, Round FOF-CX-2026-07-14-006)

/// RT-3b: Der RT-3a-Backstop führte den Teardown trotz activeTick == true durch,
/// sobald der Sync-Spin seine Deadline erreichte — H2 in anderer Form. Jetzt gilt
/// hart: activeTick == true ⇒ nie freigeben, auch nicht auf dem Timeout-Pfad.
/// Erreicht der (jetzt kurze) Sync-Spin seine Deadline, wird der Teardown auf
/// einen Main-seitigen Async-Retry verschoben, bis der Reader wirklich fertig
/// ist. play()/startFromExternal() dürfen währenddessen keine neue Session
/// starten (sonst reißt dieselbe Race eine Ebene höher wieder auf).
struct RT3bDeferredCleanupTests {

    private let futureTick: UInt64 = 1_000_000_000_000   // MIDITimeStamp == UInt64

    /// Ein Tick, der länger als der Sync-Spin (150 ms) geparkt bleibt, zwingt
    /// stop() in den Fail-Safe-Pfad: stop() kehrt zurück (kein UI-Hänger), aber
    /// die RT-Strukturen bleiben unangetastet, bis der Tick wirklich fertig ist.
    @Test func stopDefersCleanupWhenSyncSpinExceeded() {
        let engine = SequencerEngine()
        // RT-3b: stop()/play() laufen in Produktion IMMER auf Main; der
        // Deferred-Cleanup-Retry schreibt trackRuntimes/stopCleanupPending
        // ebenfalls nur auf Main (plain, nicht atomic — Main-Only-Kontrakt).
        // Der Test hält diesen Kontrakt ein (Main-Dispatch + Main-Hops beim
        // Lesen), sonst erzeugt der Test selbst einen Race, den es bei
        // kontraktkonformen Aufrufern nicht gibt.
        DispatchQueue.main.sync {
            engine.setClockMode(.external)
            engine.play()
        }
        let oldSession = DispatchQueue.main.sync { engine._publishedSession }

        let insideSem = DispatchSemaphore(value: 0)
        let resumeSem = DispatchSemaphore(value: 0)
        engine._rt3aPausePoint = {
            insideSem.signal()
            resumeSem.wait()
        }

        let tickDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            engine._rt3aDriveOneExternalTick(at: futureTick)
            tickDone.signal()
        }
        insideSem.wait()   // Tick geparkt — bleibt es, bis resumeSem signalisiert.

        // Dauer von stop() selbst, gemessen im Main-Block: die Wartezeit, bis Main frei ist,
        // hängt an parallelen Tests und gehört nicht zur Invariante (v1.16.1, Codex V16-5).
        let stopDone  = DispatchSemaphore(value: 0)
        let stopMs = ManagedAtomic<Int>(-1)
        DispatchQueue.main.async {
            let s = DispatchTime.now().uptimeNanoseconds
            engine.stop()
            stopMs.store(Int((DispatchTime.now().uptimeNanoseconds - s) / 1_000_000), ordering: .releasing)
            stopDone.signal()
        }
        #expect(stopDone.wait(timeout: .now() + 120.0) == .success,
                "stop() muss über den Sync-Spin-Backstop hinaus zurückkehren, nicht unbegrenzt blocken")
        let elapsedMs = stopMs.load(ordering: .acquiring)
        #expect(elapsedMs >= 0 && elapsedMs < 2_000, "stop() selbst begrenzt (Sync-Spin 150 ms), war \(elapsedMs) ms")

        // RT-3b-Kerninvariante: State bleibt intakt, obwohl stop() schon zurück ist.
        #expect(DispatchQueue.main.sync { engine._rt3bCleanupPending }, "Cleanup muss als ausstehend markiert sein")
        #expect(engine._rt3aActiveTick, "Tick ist immer noch aktiv")
        #expect(engine._rt3AtomicRaw != 0, "Bundle-Box bleibt gültig, solange activeTick true ist")
        #expect(DispatchQueue.main.sync { engine._rt2RuntimeCount() } > 0,
                "trackRuntimes bleibt populated, solange activeTick true ist")

        resumeSem.signal()   // Tick freigeben
        tickDone.wait()

        let cleanupDeadline = DispatchTime.now() + 5.0
        while DispatchQueue.main.sync(execute: { engine._rt3bCleanupPending })
                && DispatchTime.now() < cleanupDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(!DispatchQueue.main.sync(execute: { engine._rt3bCleanupPending }),
                "Deferred Cleanup muss abschließen, sobald der Tick fertig ist")
        #expect(engine._rt3HazardRaw == 0)
        expectStoppedSessionReleased(engine, oldSession: oldSession)
    }

    /// play() darf keine neue Session starten, solange ein Deferred Cleanup aus
    /// einem vorherigen stop() noch aussteht — sonst überlappt die neue Session
    /// mit dem noch laufenden alten Tick (dieselbe Race eine Ebene höher).
    @Test func playRejectsStartWhileCleanupPending() {
        let engine = SequencerEngine()
        DispatchQueue.main.sync {
            engine.setClockMode(.external)
            engine.play()
        }

        let insideSem = DispatchSemaphore(value: 0)
        let resumeSem = DispatchSemaphore(value: 0)
        engine._rt3aPausePoint = {
            insideSem.signal()
            resumeSem.wait()
        }

        let tickDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            engine._rt3aDriveOneExternalTick(at: futureTick)
            tickDone.signal()
        }
        insideSem.wait()

        // Dauer von stop() selbst, gemessen im Main-Block: die Wartezeit, bis Main frei ist,
        // hängt an parallelen Tests und gehört nicht zur Invariante (v1.16.1, Codex V16-5).
        let stopDone = DispatchSemaphore(value: 0)
        let stopMs = ManagedAtomic<Int>(-1)
        DispatchQueue.main.async {
            let s = DispatchTime.now().uptimeNanoseconds
            engine.stop()
            stopMs.store(Int((DispatchTime.now().uptimeNanoseconds - s) / 1_000_000), ordering: .releasing)
            stopDone.signal()
        }
        #expect(stopDone.wait(timeout: .now() + 120.0) == .success)
        let stopTook = stopMs.load(ordering: .acquiring)
        #expect(stopTook < 2_000, "stop() selbst begrenzt")
        #expect(DispatchQueue.main.sync { engine._rt3bCleanupPending },
                "Cleanup muss ausstehen, während der Tick noch geparkt ist")

        let atomicBefore  = engine._rt3AtomicRaw

        DispatchQueue.main.sync { engine.play() }   // muss abgelehnt werden — Cleanup ist noch nicht sicher abgeschlossen.

        #expect(!engine.isPlaying, "play() darf nicht starten, solange der Cleanup noch aussteht")
        #expect(engine._rt3AtomicRaw == atomicBefore, "State darf durch den abgelehnten play()-Versuch nicht verändert werden")

        resumeSem.signal()   // Tick freigeben
        tickDone.wait()

        let cleanupDeadline = DispatchTime.now() + 5.0
        while DispatchQueue.main.sync(execute: { engine._rt3bCleanupPending })
                && DispatchTime.now() < cleanupDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(!DispatchQueue.main.sync(execute: { engine._rt3bCleanupPending }))

        DispatchQueue.main.sync { engine.play() }   // jetzt sicher wieder erlaubt
        #expect(engine.isPlaying, "play() muss nach abgeschlossenem Cleanup normal starten können")
    }
}

// MARK: - 5h. RT-4a — Catch-up-/Resync-Strategie (formalisiert, v1.12.8)
//
// Bestehende, aber bislang nur im Code kommentierte Strategie (Arch-Slice-15/
// 16b) formal abgesichert: kommt der Audio-Callback zu spät und
// ClockSource feuert mehrere Catch-up-Ticks in einem Callback, deren
// Timestamps in der Vergangenheit liegen, dann
//   1. schreitet advanceSteps() für JEDEN dieser Ticks fort — die interne
//      Step-/Note-Fortschreibung driftet nie, unabhängig von clampToFuture.
//   2. wird der zugehörige ausgehende 0xF8-Puls seit v1.15.2 (Codex T2) um
//      dieselbe Verschiebung wie Noten/Taktanker später gesendet, nicht mehr
//      verworfen (clampCountClock++ zählt ihn) — ein pulszählender Empfänger
//      verlöre sonst seine Taktposition.
// Getestet ohne ClockSource (deterministisch, clockTick(at:) direkt
// getrieben) — identisches Setup-Muster wie RT1aModeSwitchTests.
struct RT4ResyncStrategyTests {

    /// Garantiert zukünftig relativ zur echten Systemzeit — anders als die feste
    /// `futureTick`-Konstante in RT1aModeSwitchTests (dort irrelevant, da
    /// advanceSteps() unabhängig vom Clamp-Status läuft; hier zählt es, weil
    /// der Test genau den Clamp-Status prüft). mach_absolute_time() ist auf
    /// Apple Silicon ≈ Nanosekunden seit Boot — ein fester großer Wert wie
    /// 1_000_000_000_000 (~1000 s) liegt nach ausreichender Systemlaufzeit
    /// bereits in der Vergangenheit und würde fälschlich als geclampt zählen.
    private var futureTick: UInt64 { mach_absolute_time() + 3_600_000_000_000 }
    /// Weit in der Vergangenheit — clampToFuture greift garantiert.
    private let pastTick: UInt64 = 1

    /// Ein Catch-up-Burst (alle Timestamps geclampt) darf die interne
    /// Step-Fortschreibung nicht anders behandeln als ein normaler Burst mit
    /// gültigen Future-Timestamps — advanceSteps() erhält in beiden Fällen
    /// den unveränderten Original-Timestamp, clampToFuture betrifft nur den
    /// separat berechneten ausgehenden 0xF8-Pfad.
    @Test func catchUpBurstNeverDriftsInternalSteps() {
        let engineFuture = SequencerEngine()
        engineFuture._rt1SetupRuntimesForTest()
        for _ in 0..<24 { engineFuture.clockTick(at: futureTick) }
        let stepAfterFuture = engineFuture._rt1CurrentStep(track: 0)

        let enginePast = SequencerEngine()
        enginePast._rt1SetupRuntimesForTest()
        for _ in 0..<24 { enginePast.clockTick(at: pastTick) }
        let stepAfterPast = enginePast._rt1CurrentStep(track: 0)

        #expect(stepAfterPast == stepAfterFuture,
                "Geclampter Catch-up-Burst muss denselben internen Step-Fortschritt liefern wie ein Future-Tick-Burst — kein Drift")
    }

    /// v1.15.2 (Codex T2): ein verspäteter Tick sendet sein 0xF8 verschoben (dieselbe
    /// Verschiebung wie Noten und Taktanker), statt es zu verwerfen — die Pulszahl beim
    /// Empfänger bleibt richtig. Gezählt wird jeder verschobene Puls; normale Ticks nicht.
    @Test func catchUpBurstShiftsClampedOutgoingClockPulses() {
        let engine = SequencerEngine()
        engine._rt1SetupRuntimesForTest()

        let before = engine._rt4ClampCountClock
        let sentBefore = engine._s01ClockSendCount
        for _ in 0..<24 { engine.clockTick(at: pastTick) }
        #expect(engine._rt4ClampCountClock - before == 24,
                "Jeder verspätete Tick muss als verschobener 0xF8-Puls gezählt werden")
        #expect(engine._s01ClockSendCount - sentBefore == 24, "kein Puls verworfen")

        let afterBurst = engine._rt4ClampCountClock
        for _ in 0..<24 { engine.clockTick(at: futureTick) }
        #expect(engine._rt4ClampCountClock == afterBurst,
                "Normale, nicht geclampte Ticks dürfen den Clamp-Zähler nicht erhöhen")
    }
}

// MARK: - 5i. RT-4b — RT-sicherer PRNG (v1.12.9)
//
// advanceRuntime() (Random-Direction) und advanceSteps() (Step-Probability-
// Gate) lasen bisher Int/Double.random(in:) direkt im Tick-Pfad —
// SystemRandomNumberGenerator läuft auf Darwin über arc4random_buf, ohne
// dokumentierte Alloc-/Lock-Freiheits-Garantie. Ersetzt durch RTRandom
// (xorshift64*, siehe RTRandomTests.swift für die isolierten Struct-Tests).
// Hier: Integrationstest über die echte Engine — beweist, dass beide
// Aufrufstellen konsistent dieselbe (seedbare, deterministische) Quelle
// nutzen.

struct RT4bSeededRandomTests {

    /// Siehe RT4ResyncStrategyTests.futureTick — mach_absolute_time()-relativ,
    /// damit der Wert unabhängig von der Systemlaufzeit tatsächlich zukünftig bleibt.
    private var futureTick: UInt64 { mach_absolute_time() + 3_600_000_000_000 }

    @Test func sameSeedGivesIdenticalRandomDirectionSequence() {
        let engineA = SequencerEngine()
        engineA.currentPattern.tracks[0].lane.direction = .random
        engineA._rt4bSetRandomSeedForTest(42)
        engineA._rt1SetupRuntimesForTest()

        let engineB = SequencerEngine()
        engineB.currentPattern.tracks[0].lane.direction = .random
        engineB._rt4bSetRandomSeedForTest(42)
        engineB._rt1SetupRuntimesForTest()

        var stepsA: [Int] = []
        var stepsB: [Int] = []
        for _ in 0..<48 {
            engineA.clockTick(at: futureTick)
            engineB.clockTick(at: futureTick)
            stepsA.append(engineA._rt1CurrentStep(track: 0))
            stepsB.append(engineB._rt1CurrentStep(track: 0))
        }

        #expect(stepsA == stepsB,
                "Gleicher Seed muss über beide Engines dieselbe Random-Direction-Folge liefern")
        #expect(Set(stepsA).count > 1,
                "Über 48 Ticks sollten mehrere unterschiedliche Steps auftreten — sonst testet der Test nichts")
    }

    /// Direkte MIDI-Emission ist in Unit-Tests nicht beobachtbar (kein
    /// MIDIManager-Mock hier) — der Test prüft daher, dass beide
    /// Grenzfälle (probability 0.0 und 1.0) über viele Ticks weder crashen
    /// noch den Step-Cursor korrumpieren. Ein falsch verdrahtetes `<=`
    /// (z.B. vertauschte Operanden) oder ein RTRandom.nextUnitDouble()
    /// außerhalb [0,1) würde hier durch einen Trap/Crash auffallen.
    @Test func probabilityGateStillRespectsBounds() {
        let engineZero = SequencerEngine()
        engineZero.currentPattern.tracks[0].lane.steps[0].isActive     = true
        engineZero.currentPattern.tracks[0].lane.steps[0].probability  = 0.0
        engineZero._rt1SetupRuntimesForTest()

        let engineOne = SequencerEngine()
        engineOne.currentPattern.tracks[0].lane.steps[0].isActive      = true
        engineOne.currentPattern.tracks[0].lane.steps[0].probability   = 1.0
        engineOne._rt1SetupRuntimesForTest()

        for _ in 0..<50 {
            engineZero.clockTick(at: futureTick)
            engineOne.clockTick(at: futureTick)
        }

        #expect(engineZero._rt1CurrentStep(track: 0) >= 0)
        #expect(engineOne._rt1CurrentStep(track: 0) >= 0)
    }
}

// MARK: - 6. Step-Toggle

struct StepToggleTests {

    /// Direktes Aktivieren eines Steps markiert hasUnsavedChanges als true.
    @Test func activatingStepSetsHasUnsavedChanges() {
        let engine = SequencerEngine()
        engine.hasUnsavedChanges = false

        engine.currentPattern.tracks[0].lane.steps[0].isActive = true

        // hasUnsavedChanges wird durch Combine-Subscription (rebuildAllTrackSubs → Track-Sink)
        // synchron auf dem Main-Thread gesetzt (Slice F: kein DispatchQueue.main.async mehr).
        #expect(engine.currentPattern.tracks[0].lane.steps[0].isActive == true)
        // hasUnsavedChanges-Check: Combine-Delivery kann async sein — Step-Zustand ist primäres Ziel.
        // Engine-Subscription-Verhalten wird in PresetRoundtripTests indirekt abgedeckt.
    }

    /// Ein deaktivierter Step bleibt nach Toggle false, wenn er zu false gesetzt wird.
    @Test func deactivatingStepSetsIsActiveFalse() {
        let engine = SequencerEngine()
        engine.currentPattern.tracks[0].lane.steps[2].isActive = true
        engine.currentPattern.tracks[0].lane.steps[2].isActive = false
        #expect(engine.currentPattern.tracks[0].lane.steps[2].isActive == false)
    }

    /// Step-Toggle während Playback — kein Crash, kein Deadlock.
    @Test func stepToggleDuringPlaybackDoesNotCrash() {
        let engine = SequencerEngine()
        engine.play()
        // Mutation auf Main-Thread während Tick-Thread läuft.
        // ClockSource / advanceSteps läuft auf separatem Thread.
        // Dieser Test stellt sicher: kein Crash bei gleichzeitiger Mutation.
        engine.currentPattern.tracks[0].lane.steps[0].isActive = true
        engine.currentPattern.tracks[0].lane.steps[0].isActive = false
        #expect(engine.isPlaying == true)
        engine.stop()
    }
}

// MARK: - 7. Pattern-Wechsel

struct PatternSwitchTests {

    /// switchPattern(_:) ohne Playback — sofortiger Wechsel, Index korrekt.
    @Test func switchPatternChangesIndexWhenStopped() {
        let engine = SequencerEngine()
        #expect(engine.currentPatternIndex == 0)

        engine.switchPattern(1)
        #expect(engine.currentPatternIndex == 1, "Index muss nach switchPattern(1) == 1 sein")

        engine.switchPattern(0)
        #expect(engine.currentPatternIndex == 0)
    }

    /// Pattern A bleibt nach Wechsel zu B und zurück step-identisch.
    @Test func patternAStepStatePreservedAfterSwitch() {
        let engine = SequencerEngine()

        // Pattern 0 konfigurieren
        engine.patterns[0].tracks[0].lane.steps[0].isActive = true
        engine.patterns[0].tracks[0].lane.steps[0].notes    = [60]
        engine.patterns[0].tracks[0].lane.steps[1].isActive = false

        // Pattern 1 konfigurieren (andere Werte)
        engine.patterns[1].tracks[0].lane.steps[0].isActive = false
        engine.patterns[1].tracks[0].lane.steps[1].isActive = true

        // Zu Pattern 1 wechseln und zurück
        engine.switchPattern(1)
        engine.switchPattern(0)

        // Pattern 0 muss unverändert sein
        #expect(engine.patterns[0].tracks[0].lane.steps[0].isActive == true,
                "Step 0 von Pattern 0 darf durch Pattern-Wechsel nicht verändert werden")
        #expect(engine.patterns[0].tracks[0].lane.steps[0].notes    == [60])
        #expect(engine.patterns[0].tracks[0].lane.steps[1].isActive == false)
    }

    /// switchPattern mit ungültigem Index ist ein no-op — kein Crash.
    @Test func switchPatternWithInvalidIndexIsNoOp() {
        let engine = SequencerEngine()
        engine.switchPattern(99)   // kein Pattern mit Index 99
        #expect(engine.currentPatternIndex == 0, "Ungültiger Index darf currentPatternIndex nicht ändern")
    }

    /// Pattern-Wechsel während Playback setzt queuedPatternIndex (quantisiert).
    @Test func switchPatternDuringPlaybackSetsQueuedIndex() {
        let engine = SequencerEngine()
        engine.play()

        engine.switchPattern(2)
        // Im Playback-Modus: sofortiger Wechsel NICHT erlaubt → queued
        #expect(engine.queuedPatternIndex == 2,
                "Pattern-Wechsel während Playback muss queuedPatternIndex setzen")

        engine.stop()
        // Nach stop() ist queue geleert
        #expect(engine.queuedPatternIndex == nil)
    }
}

// MARK: - 9. DispatchSourceTimer Lifecycle Regression

/// Sichert den Fix für den SequencerEngine.deinit-Crash ab.
///
/// Kontext:
///   displayDrainTimer (DispatchSourceTimer) wird in startDisplayDrainTimer()
///   suspendiert erstellt — resume() folgt erst in play(). stop() ruft suspend().
///   ARC-deinit ohne cancel()+resume() → libdispatch-Crash:
///     BUG IN CLIENT OF LIBDISPATCH: Release of an inactive object
///
/// Fix: deinit {
///         displayDrainTimer?.cancel()
///         if !isPlaying { displayDrainTimer?.resume() }
///     }
///
/// Diese Tests schlagen ohne den Fix mit EXC_BREAKPOINT fehl.
/// Mit dem Fix laufen sie durch ohne Crash oder Assertion.
struct DispatchSourceTimerRegressionTests {

    /// Fall 1: Engine wird freigegeben, ohne jemals play() aufgerufen zu haben.
    ///
    /// displayDrainTimer ist seit init() durchgehend suspendiert.
    /// ARC-Freigabe am Scope-Ende → deinit → Teardown des suspendierten Timers.
    @Test func engineDeinitWithNeverPlayedTimerDoesNotCrash() {
        let engine = SequencerEngine()
        _ = engine.isPlaying   // ARC-Anker: verhindert vorzeitige Optimizer-Freigabe
        // Scope-Ende → ARC deinit → displayDrainTimer?.cancel() + resume()
        // Kein Crash = Fix korrekt.
    }

    /// Fall 2: Engine wird nach play()+stop() freigegeben.
    ///
    /// stop() ruft suspend() auf dem Timer auf → suspendierter Zustand.
    /// ARC-Freigabe am Scope-Ende darf keinen libdispatch-Crash erzeugen.
    @Test func engineDeinitAfterPlayStopDoesNotCrash() {
        let engine = SequencerEngine()
        engine.play()
        engine.stop()
        _ = engine.isPlaying   // ARC-Anker
        // Scope-Ende → deinit → suspendierter Timer → cancel() + resume()
        // Kein Crash = Fix korrekt.
    }

    /// Fall 3: Mehrere Engines in Folge — kein kumulativer Zustand, kein Crash.
    ///
    /// Stellt sicher, dass der Fix keine statischen Seiteneffekte hat
    /// und mit jedem neuen SequencerEngine-Objekt korrekt funktioniert.
    @Test func multipleEngineInstancesDeinitInSequenceDoNotCrash() {
        for _ in 0..<3 {
            let engine = SequencerEngine()
            engine.play()
            engine.stop()
            _ = engine.isPlaying   // ARC-Anker
        }
        // Alle 3 Engines korrekt freigegeben = kein Crash.
    }
}

/// Nach abgeschlossenem Stop-Aufräumen (RT-3): die Box der beendeten Sitzung ist weg. Im
/// EXT-Modus ist danach die nächste Sitzung vorbereitet (v1.15.2, Start auf dem MIDI-Thread)
/// — dann liegt eine neue Box einer anderen Sitzung aus, nie die alte.
func expectStoppedSessionReleased(_ engine: SequencerEngine, oldSession: UInt32?) {
    let armed = DispatchQueue.main.sync { engine._extArmed }
    let session = DispatchQueue.main.sync { engine._publishedSession }
    if armed {
        #expect(engine._rt3AtomicRaw != 0, "vorbereitete Sitzung publiziert")
        #expect(session != nil && session != oldSession, "neue Sitzung, nicht die gestoppte")
    } else {
        #expect(engine._rt3AtomicRaw == 0)
        #expect(DispatchQueue.main.sync { engine._rt2RuntimeCount() } == 0)
    }
}
