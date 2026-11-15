import Testing
import Foundation
import Combine
import CoreGraphics
@testable import VintageSequencer

// v1.17.3 — Spurzeilen: verschieben und einklappen in allen Patterns (mit Undo),
// optionaler Presetschlüssel `collapsed`, Kanalgrenze 64.

private func makeEngine() -> (SequencerEngine, UndoManager) {
    let engine = SequencerEngine()
    let um = UndoManager()
    um.groupsByEvent = false
    engine.undoManager = um
    return (engine, um)
}
private func action(_ um: UndoManager, _ body: () -> Void) {
    um.beginUndoGrouping(); body(); um.endUndoGrouping()
}

@MainActor @Suite(.serialized) struct TrackRowLayoutTests {

    /// Verschieben wirkt in jedem Pattern gleich und bewahrt die Instanzen; Undo stellt
    /// die Reihenfolge wieder her, Redo wiederholt sie.
    @Test func moveTrackAppliesToAllPatternsAndUndoes() {
        let (engine, um) = makeEngine()
        let before = engine.patterns.map { $0.tracks.map(\.id) }
        #expect(before[0].count >= 3)
        action(um) { engine.moveTrackUndoable(from: 0, to: 2, actionName: "Move") }
        for (p, ids) in zip(engine.patterns, before) where ids.count >= 3 {
            #expect(p.tracks.map(\.id) == [ids[1], ids[2], ids[0]] + ids.dropFirst(3))
        }
        #expect(engine.hasUnsavedChanges)
        um.undo()
        #expect(engine.patterns.map { $0.tracks.map(\.id) } == before)
        um.redo()
        #expect(engine.patterns[0].tracks.map(\.id).prefix(3) == [before[0][1], before[0][2], before[0][0]])
    }

    /// Ablegen auf eine Zielspur (Ziehen im Spurkopf) und ungültige Ziele.
    @Test func moveOntoTargetAndRejectsInvalid() {
        let (engine, um) = makeEngine()
        let ids = engine.currentPattern.tracks.map(\.id)
        action(um) { engine.moveTrackUndoable(id: ids[2], onto: ids[0], actionName: "Move") }
        #expect(engine.currentPattern.tracks.map(\.id).prefix(3) == [ids[2], ids[0], ids[1]])
        #expect(!engine.moveTrack(from: 0, to: 0))
        #expect(!engine.moveTrack(from: 0, to: ids.count))
        #expect(!engine.moveTrack(from: -1, to: 0))
    }

    /// Ziehen in eine Lücke: Lücke g liegt über Zeile g; die Lücken direkt über und unter der
    /// gezogenen Zeile bewegen nichts (dort erscheint keine Einfügelinie).
    @Test func gapDestination() {
        #expect(SequencerEngine.moveDestination(from: 0, gap: 0, count: 4) == nil)
        #expect(SequencerEngine.moveDestination(from: 0, gap: 1, count: 4) == nil)
        #expect(SequencerEngine.moveDestination(from: 0, gap: 2, count: 4) == 1)
        #expect(SequencerEngine.moveDestination(from: 0, gap: 4, count: 4) == 3)
        #expect(SequencerEngine.moveDestination(from: 3, gap: 0, count: 4) == 0)
        #expect(SequencerEngine.moveDestination(from: 2, gap: 1, count: 4) == 1)
        #expect(SequencerEngine.moveDestination(from: 0, gap: 5, count: 4) == nil)
        let (engine, um) = makeEngine()
        let ids = engine.currentPattern.tracks.map(\.id)
        action(um) { engine.moveTrackUndoable(id: ids[0], toGap: ids.count, actionName: "Move") }
        #expect(engine.currentPattern.tracks.last?.id == ids[0])
    }

    /// Einklappen gilt für die Zeile in allen Patterns, mit Undo; Kopien übernehmen es.
    @Test func collapseAppliesToAllPatternsAndUndoes() {
        let (engine, um) = makeEngine()
        action(um) { engine.setTrackCollapsedUndoable(at: 1, true, actionName: "Collapse") }
        #expect(engine.patterns.allSatisfy { $0.tracks.count < 2 || $0.tracks[1].isCollapsed })
        #expect(!engine.currentPattern.tracks[0].isCollapsed)
        #expect(engine.currentPattern.tracks[1].freshCopy().isCollapsed)
        um.undo()
        #expect(engine.patterns.allSatisfy { $0.tracks.count < 2 || !$0.tracks[1].isCollapsed })
    }

    /// A17-05: Undo eines Verschiebens ist exakt invers, auch wenn Patterns unterschiedlich
    /// lang sind (A: 4 Spuren, B: 2; 0→3 verschiebt in B nach 1).
    @Test func moveUndoIsInverseWithUnequalPatterns() {
        let (engine, um) = makeEngine()
        while engine.patterns[0].tracks.count < 4 { engine.addTrackUndoable(kind: .step, actionName: "Add") }
        engine.patterns[1].tracks = Array(engine.patterns[1].tracks.prefix(2))
        let before = engine.patterns.map { $0.tracks.map(ObjectIdentifier.init) }
        action(um) { engine.moveTrackUndoable(from: 0, to: 3, actionName: "Move") }
        let b = before[1]
        #expect(engine.patterns[1].tracks.map(ObjectIdentifier.init) == [b[1], b[0]])
        um.undo()
        #expect(engine.patterns.map { $0.tracks.map(ObjectIdentifier.init) } == before)
        um.redo()
        #expect(engine.patterns[1].tracks.map(ObjectIdentifier.init) == [b[1], b[0]])
    }

    /// A17-07: ein Verschieben über alle Patterns baut die Abos genau einmal neu auf.
    @Test func moveRebuildsSubscriptionsOnce() {
        let (engine, um) = makeEngine()
        let n0 = engine._subscriptionRebuilds
        action(um) { engine.moveTrackUndoable(from: 0, to: 1, actionName: "Move") }
        #expect(engine._subscriptionRebuilds - n0 == 1, "\(engine.patterns.count) Patterns, ein Neuaufbau")
        let n1 = engine._subscriptionRebuilds
        action(um) { engine.addTrackUndoable(kind: .step, actionName: "Add") }
        #expect(engine._subscriptionRebuilds - n1 == 1)
    }

    /// A17-06: Undo des Einklappens stellt den Vorzustand jeder Instanz her — eine in einem
    /// anderen Pattern schon eingeklappte Zeile bleibt eingeklappt.
    @Test func collapseUndoRestoresEachInstance() {
        let (engine, um) = makeEngine()
        engine.patterns[1].tracks[1].isCollapsed = true
        action(um) { engine.setTrackCollapsedUndoable(at: 1, true, actionName: "Collapse") }
        um.undo()
        #expect(!engine.patterns[0].tracks[1].isCollapsed)
        #expect(engine.patterns[1].tracks[1].isCollapsed, "Vorzustand bleibt")
    }

    /// A17-08: Einklappen ist Ansicht — kein `changed` (Snapshot), nur `viewChanged`.
    @Test func collapseSendsOnlyViewSignal() {
        let (engine, um) = makeEngine()
        let td = engine.currentPattern.tracks[0]
        var model = 0, view = 0
        let a = td.changed.sink { model += 1 }, b = td.viewChanged.sink { view += 1 }
        action(um) { engine.setTrackCollapsedUndoable(at: 0, true, actionName: "Collapse") }
        #expect(model == 0 && view == 1 && engine.hasUnsavedChanges)
        _ = (a, b)
    }

    /// Ziehgeste (v1.17.10): Zielzeile aus den Zeilenmitten, Lücke durch Versatz der Zeilen
    /// zwischen alter und neuer Position, Ergebnis beim Loslassen; kurz gezogen = keine Bewegung.
    @Test func dragStateComputesTargetAndShifts() {
        let ids = (0..<4).map { _ in UUID() }
        let drag = TrackDragState()
        for (i, id) in ids.enumerated() { drag.frames[id] = CGRect(x: 0, y: CGFloat(i) * 108, width: 100, height: 100) }
        drag.update(id: ids[0], order: ids, y: 50, translation: 0)
        #expect(drag.draggedID == ids[0] && drag.shifts.isEmpty)
        drag.update(id: ids[0], order: ids, y: 280, translation: 230)  // über Mitte von 1 und 2
        #expect(drag.shifts[ids[1]] == -108 && drag.shifts[ids[2]] == -108 && drag.shifts[ids[3]] == nil)
        let move = drag.finish()
        #expect(move?.from == 0 && move?.to == 2 && drag.draggedID == nil && drag.shifts.isEmpty)
        drag.update(id: ids[3], order: ids, y: 10, translation: -320)   // nach ganz oben
        #expect(drag.shifts[ids[0]] == 108 && drag.shifts[ids[2]] == 108)
        #expect(drag.finish()?.to == 0)
        drag.update(id: ids[1], order: ids, y: 160, translation: 2)
        #expect(drag.finish() == nil, "an Ort und Stelle: keine Bewegung")
    }

    /// Loslassen (v1.17.11): die Zeile gleitet in die Lücke (Versatz = Summe der übersprungenen
    /// Zeilen samt Abstand), danach genau eine Übernahme und Zurücksetzen.
    @Test func dragSettlesIntoGapThenCommitsOnce() async throws {
        let ids = (0..<4).map { _ in UUID() }
        let drag = TrackDragState()
        for (i, id) in ids.enumerated() { drag.frames[id] = CGRect(x: 0, y: CGFloat(i) * 108, width: 100, height: 100) }
        drag.update(id: ids[0], order: ids, y: 50, translation: 0)
        drag.update(id: ids[0], order: ids, y: 280, translation: 230)
        var commits: [(Int, Int)] = []
        drag.settle { commits.append(($0, $1)) }
        #expect(drag.translation == 216, "zwei Zeilen à 100 + 8")
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(commits.count == 1 && commits.first?.0 == 0 && commits.first?.1 == 2)
        #expect(drag.draggedID == nil && drag.translation == 0 && drag.shifts.isEmpty)
    }

    /// `collapsed` ist optional: nur geschrieben, wenn gesetzt; fehlend = ausgeklappt.
    @Test func collapsedKeyIsOptional() throws {
        let td = TrackData(name: "T", midiChannel: 1)
        let plain = try JSONEncoder().encode(td)
        #expect(!(String(data: plain, encoding: .utf8) ?? "").contains("\"collapsed\""))
        #expect(try !JSONDecoder().decode(TrackData.self, from: plain).isCollapsed)
        td.isCollapsed = true
        let set = try JSONEncoder().encode(td)
        #expect((String(data: set, encoding: .utf8) ?? "").contains("\"collapsed\":true"))
        #expect(try JSONDecoder().decode(TrackData.self, from: set).isCollapsed)
    }

    /// 64 Kanäle; Effekt-Warteschlangen sind kleiner als die der Instrumente.
    @Test func channelLimitAndQueueSizes() {
        #expect(InstrumentRack.maxChannels == 64)
        #expect(NoteOutput.portCount == 65)
        let q = AUEventQueue(ringCapacity: 256, pendingCapacity: 128)
        #expect(q.pendingCapacity == 128)
        q.setActive(true)
        var accepted = 0
        for i in 0..<300 where q.pushFromMain(0x90, UInt8(i % 128), 1, at: 1) { accepted += 1 }
        #expect(accepted == 256)
        #expect(AUEventQueue().pendingCapacity == AUEventQueue.pendingCapacity)
    }
}
