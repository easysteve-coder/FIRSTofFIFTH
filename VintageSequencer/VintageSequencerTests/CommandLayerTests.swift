import Testing
import Foundation
import AppKit
import Combine
@testable import VintageSequencer

// v1.12.18 — Command-Schicht mit Identität: Strukturoperationen, Undo, Preset-IO,
// Subscriptions, MIDI-Learn. Jeder Test bildet einen zuvor fehlerhaften Ablauf ab.

/// Undo-Manager ohne Event-Gruppierung: jede Aktion ist ein eigener Undo-Schritt.
private func makeUndoManager() -> UndoManager {
    let um = UndoManager()
    um.groupsByEvent = false
    return um
}
private func action(_ um: UndoManager, _ body: () -> Void) {
    um.beginUndoGrouping(); body(); um.endUndoGrouping()
}
private func makeEngine() -> (SequencerEngine, UndoManager) {
    let engine = SequencerEngine()
    let um = makeUndoManager()
    engine.undoManager = um
    return (engine, um)
}

@Suite(.serialized) struct CommandLayerSubscriptionTests {

    /// @Published emittiert im willSet — der neue Track jedes Patterns muss trotzdem abonniert sein.
    @Test func newTrackIsSubscribedInEveryPattern() {
        let (engine, _) = makeEngine()
        engine.addTrack()
        for (i, p) in engine.patterns.enumerated() {
            engine.hasUnsavedChanges = false
            p.tracks.last!.lane.changed.send()
            #expect(engine.hasUnsavedChanges, "Pattern \(i): Edit am neuen Track setzt kein Dirty-Flag")
        }
    }

    @Test func bpmChangeDuringPlaybackPublishesNewValue() {
        let (engine, _) = makeEngine()
        engine.play()
        engine.setBPM(60.0)
        let published = engine._rt1PublishedBundle()?.bpm
        engine.stop()
        #expect(published == 60.0)
    }
}

@Suite(.serialized) struct CommandLayerStructureUndoTests {

    @Test func deleteUndoRestoresSameInstanceAndOlderUndoStillWorks() {
        let (engine, um) = makeEngine()
        let td = engine.currentPattern.tracks[1]
        let original = td.lane.steps[0].isActive
        var edited = td.lane.steps
        edited[0].isActive = !original
        action(um) {
            ModelWriter().apply(.setSteps(trackID: td.id, oldSteps: td.lane.steps, newSteps: edited,
                                          actionName: "Edit"), to: td, undoManager: um)
        }
        action(um) { engine.removeTrackUndoable(at: 1, actionName: "Delete") }
        #expect(!engine.currentPattern.tracks.contains { $0 === td })

        um.undo()   // Delete rückgängig
        #expect(engine.currentPattern.tracks[1] === td, "Undo muss dieselbe Instanz wieder einsetzen")
        um.undo()   // Step-Edit rückgängig — zielt auf die Lane derselben Instanz
        #expect(engine.currentPattern.tracks[1].lane.steps[0].isActive == original)

        um.redo(); um.redo()
        #expect(!engine.currentPattern.tracks.contains { $0 === td })
    }

    @Test func addUndoRedoKeepsInstanceAndCount() {
        let (engine, um) = makeEngine()
        let before = engine.patterns.map { $0.tracks.count }
        action(um) { engine.addTrackUndoable(kind: .step, actionName: "Add") }
        let added = engine.currentPattern.tracks.last!
        um.undo()
        #expect(engine.patterns.map { $0.tracks.count } == before)
        um.redo()
        #expect(engine.currentPattern.tracks.last === added)
    }

    /// Patterns mit unterschiedlicher Track-Zahl: Undo setzt jeden Track in SEIN Pattern zurück.
    @Test func removeUndoWithDifferentTrackCountsPerPattern() {
        let (engine, um) = makeEngine()
        // Pattern B auf 2 Tracks kürzen (direkt, ohne Undo) → Index 3 existiert dort nicht.
        engine.patterns[1].tracks.removeLast(2)
        let expected = engine.patterns.map { $0.tracks.map(\.id) }
        action(um) { engine.removeTrackUndoable(at: 3, actionName: "Delete") }
        #expect(engine.patterns[1].tracks.count == 2, "Pattern ohne diesen Index bleibt unberührt")
        um.undo()
        #expect(engine.patterns.map { $0.tracks.map(\.id) } == expected)
    }

    @Test func removeNeverEmptiesAPattern() {
        let (engine, _) = makeEngine()
        engine.patterns[2].tracks.removeLast(3)   // Pattern C: 1 Track
        engine.removeTrack(at: 0)
        #expect(engine.patterns[2].tracks.count == 1)
        #expect(engine.patterns[0].tracks.count == 3)
    }

    @Test func structureChangeClearsLearnTarget() {
        let (engine, _) = makeEngine()
        engine.learnMode = true
        engine.setLearnTarget(track: 3, step: 0)
        engine.removeTrack(at: 3)
        engine.handleLearnNoteOn(64)   // darf nicht auf einen gelöschten Index zugreifen
        #expect(engine.learnTarget == nil)
    }
}

@Suite(.serialized) struct CommandLayerPatternPasteTests {

    @Test func pasteCreatesFreshIdentitiesMarksDirtyAndIsUndoable() {
        let (engine, um) = makeEngine()
        let sourceIDs = Set(engine.currentPattern.tracks.map(\.id))
        engine.copyCurrentPattern()
        engine.switchPattern(1)
        let oldB = engine.currentPattern
        engine.hasUnsavedChanges = false
        action(um) { engine.pasteToCurrentPattern() }

        let pastedIDs = Set(engine.currentPattern.tracks.map(\.id))
        #expect(pastedIDs.isDisjoint(with: sourceIDs), "Paste darf keine Track-UUIDs der Quelle übernehmen")
        #expect(engine.hasUnsavedChanges)
        // ViewModel bindet an die Instanz, die das Pattern wirklich trägt.
        let td = engine.currentPattern.tracks[0]
        #expect(engine.viewModel(for: td).data === td)

        um.undo()
        #expect(engine.currentPattern === oldB)
    }

    @Test func pasteDuringPlaybackKeepsDisplayInSync() {
        let (engine, _) = makeEngine()
        engine.addTrack()                 // alle Patterns: 5 Tracks
        engine.copyCurrentPattern()
        engine.patterns[0].tracks.removeLast(2)   // aktuelles Pattern: 3 Tracks
        engine.play()
        engine.pasteToCurrentPattern()    // 5 Tracks ins laufende Pattern
        let displayCount = engine.playbackDisplay.steps.count
        let snapshotCount = engine._rt1PublishedBundle()?.snapshot.tracks.count
        engine.stop()
        #expect(displayCount == 5)
        #expect(snapshotCount == 5)
    }
}

@Suite(.serialized) struct CommandLayerPresetIOTests {

    @Test func reloadingSameDataRebindsViewModelsAndClearsUndo() throws {
        let (engine, um) = makeEngine()
        let data = try #require(engine.saveData())
        let oldTD = engine.currentPattern.tracks[0]
        let oldVM = engine.viewModel(for: oldTD)
        action(um) { engine.removeTrackUndoable(at: 3, actionName: "Delete") }
        #expect(um.canUndo)

        #expect(engine.loadData(data))
        let newTD = engine.currentPattern.tracks[0]
        #expect(newTD.id == oldTD.id && newTD !== oldTD, "Vorbedingung: gleiche UUID, neue Instanz")
        let newVM = engine.viewModel(for: newTD)
        #expect(newVM !== oldVM && newVM.data === newTD)
        #expect(!um.canUndo, "Undo-Einträge des alten Projekts dürfen das neue nicht verändern")
    }

    @Test func fewerThanSixteenPatternsArePaddedAndIndexStaysValid() throws {
        let (engine, _) = makeEngine()
        let two = try JSONEncoder().encode(
            PresetManager.PresetFile(bpm: 100, swing: 50, patterns: [Pattern(name: "A"), Pattern(name: "B")]))
        engine.switchPattern(12)
        #expect(engine.loadData(two))
        #expect(engine.patterns.count == Pattern.slotNames.count)
        #expect(engine.patterns.indices.contains(engine.currentPatternIndex))
        _ = engine.currentPattern   // darf nicht trappen
    }

    @Test func emptyPatternListIsRejectedWithoutTouchingTheProject() throws {
        let (engine, _) = makeEngine()
        let before = engine.patterns.map(\.id)
        let empty = try JSONEncoder().encode(PresetManager.PresetFile(bpm: 100, swing: 50, patterns: []))
        #expect(!engine.loadData(empty))
        #expect(engine.patterns.map(\.id) == before)
    }

    @Test func decodeFailureNamesTheMissingKey() {
        let (engine, _) = makeEngine()
        let json = #"{"bpm":120,"swing":50,"patterns":[{"name":"A","tracks":[{"name":"T"}]}]}"#
        #expect(!engine.loadData(Data(json.utf8)))
        let msg = engine.lastErrorMessage ?? ""
        #expect(msg.contains("missing key"), "Meldung: \(msg)")
    }
}

@Suite(.serialized) struct CommandLayerEditTests {

    @Test func learnWritesOnlyCurrentPatternAndIsUndoable() {
        let (engine, um) = makeEngine()
        let other = engine.patterns[1].tracks[0].lane.steps[0].note
        let before = engine.currentPattern.tracks[0].lane.steps[0].note
        let learned = before == 72 ? 74 : 72
        engine.learnMode = true
        engine.setLearnTarget(track: 0, step: 0)
        action(um) { engine.handleLearnNoteOn(learned) }
        #expect(engine.currentPattern.tracks[0].lane.steps[0].note == learned)
        #expect(engine.patterns[1].tracks[0].lane.steps[0].note == other)
        um.undo()
        #expect(engine.currentPattern.tracks[0].lane.steps[0].note == before)
    }

    @Test func pasteStepsIsUndoableAndIgnoresInvalidIndices() {
        let (engine, um) = makeEngine()
        let td = engine.currentPattern.tracks[0]
        var src = Step(); src.isActive = true; src.notes = [77]
        engine.stepClipboard = [src]
        let before = td.lane.steps[2].notes
        action(um) { engine.pasteSteps(to: td, at: [2, 9999]) }
        #expect(td.lane.steps[2].notes == [77])
        um.undo()
        #expect(td.lane.steps[2].notes == before)
    }

    @Test func randomizeUndoRedoIsStable() {
        let (engine, um) = makeEngine()
        let td = engine.currentPattern.tracks[0]
        let before = td.lane.steps.map(\.notes)
        action(um) { engine.randomize(track: td) }
        let after = td.lane.steps.map(\.notes)
        um.undo()
        #expect(td.lane.steps.map(\.notes) == before)
        um.redo()
        #expect(td.lane.steps.map(\.notes) == after, "Redo darf nicht neu würfeln")
    }
}
