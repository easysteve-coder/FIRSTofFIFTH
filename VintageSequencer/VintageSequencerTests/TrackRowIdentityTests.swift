import Testing
import Foundation
@testable import VintageSequencer

// v1.18.6 — Zeilenidentität über Patterns (Codex A17-12): Strukturbefehle wirken über
// `TrackData.row`, nicht über die Zeilennummer. Optionaler Presetschlüssel `row`.

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
private func rows(_ p: Pattern) -> [UUID] { p.tracks.map(\.row) }

@MainActor @Suite(.serialized) struct TrackRowIdentityTests {

    @Test func newProjectSharesRowsByNumber() {
        let (engine, _) = makeEngine()
        let a = rows(engine.patterns[0])
        #expect(Set(a).count == a.count)
        for p in engine.patterns { #expect(rows(p) == a) }
    }

    /// Pattern B in anderer Reihenfolge: dieselbe Zeile wird verschoben, nicht dieselbe Nummer.
    @Test func moveFollowsRowNotNumber() {
        let (engine, um) = makeEngine()
        let r = rows(engine.patterns[0])                     // [r0, r1, r2, r3]
        let b = engine.patterns[1]
        b.tracks = [b.tracks[2], b.tracks[0], b.tracks[3], b.tracks[1]]   // [r2, r0, r3, r1]
        let bBefore = b.tracks.map(ObjectIdentifier.init)
        action(um) { engine.moveTrackUndoable(from: 0, to: 2, actionName: "Move") }   // A: r1 r2 r0 r3
        #expect(rows(engine.patterns[0]) == [r[1], r[2], r[0], r[3]])
        // B: r0 kommt vor r3 (nächste Zeile darunter in A).
        #expect(rows(b) == [r[2], r[0], r[3], r[1]])
        // r0 stand dort schon vor r3 → B unverändert, kein Eintrag.
        #expect(b.tracks.map(ObjectIdentifier.init) == bBefore)
        um.undo()
        #expect(rows(engine.patterns[0]) == r)
    }

    @Test func moveLeavesPatternsWithoutTheRow() {
        let (engine, _) = makeEngine()
        let r = rows(engine.patterns[0])
        let b = engine.patterns[1]
        b.tracks.removeFirst()                                // B hat r0 nicht
        let bBefore = rows(b)
        engine.moveTrack(from: 0, to: 3)
        #expect(rows(engine.patterns[0]) == [r[1], r[2], r[3], r[0]])
        #expect(rows(b) == bBefore)
    }

    @Test func removeAndCollapseByRow() {
        let (engine, um) = makeEngine()
        let r = rows(engine.patterns[0])
        let b = engine.patterns[1]
        b.tracks = [b.tracks[1], b.tracks[0], b.tracks[2], b.tracks[3]]   // [r1, r0, r2, r3]
        action(um) { engine.setTrackCollapsedUndoable(at: 0, true, actionName: "Fold") }
        #expect(b.tracks[1].isCollapsed && !b.tracks[0].isCollapsed)
        action(um) { engine.removeTrackUndoable(at: 0, actionName: "Remove") }
        #expect(rows(engine.patterns[0]) == [r[1], r[2], r[3]])
        #expect(rows(b) == [r[1], r[2], r[3]])
        um.undo()
        #expect(rows(b) == [r[1], r[0], r[2], r[3]])
    }

    @Test func duplicateMakesOneNewRow() {
        let (engine, _) = makeEngine()
        let r = rows(engine.patterns[0])
        let b = engine.patterns[1]
        b.tracks = [b.tracks[1], b.tracks[0], b.tracks[2], b.tracks[3]]
        engine.duplicateTrack(at: 0)
        let new = engine.patterns[0].tracks[1].row
        #expect(!r.contains(new))
        #expect(rows(b) == [r[1], r[0], new, r[2], r[3]])
        for p in engine.patterns where p !== b { #expect(rows(p) == [r[0], new] + r.dropFirst()) }
        #expect(engine.tracks(inRow: new).count == engine.patterns.count)
    }

    @Test func insertAfterRowAndAddShareOneRow() {
        let (engine, _) = makeEngine()
        let b = engine.patterns[1]
        b.tracks = [b.tracks[1], b.tracks[0], b.tracks[2], b.tracks[3]]
        let anchor = engine.patterns[0].tracks[0].row
        engine.insertTrack(after: 0, kind: .step)
        let new = engine.patterns[0].tracks[1].row
        #expect(b.tracks[2].row == new && b.tracks[1].row == anchor)
        engine.addTrack(kind: .step)
        let added = Set(engine.patterns.map { $0.tracks.last!.row })
        #expect(added.count == 1)
    }

    /// Ältere Datei ohne `row`: Zeilen nach Nummer; Speichern und Laden erhält sie.
    @Test func legacyFileGetsRowsAndRoundTrips() throws {
        let (engine, _) = makeEngine()
        let src = [Pattern(name: "A"), Pattern(name: "B", trackCount: 3)]
        var json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(PresetManager.PresetFile(bpm: 120, swing: 50, patterns: src))) as! [String: Any]
        var pats = json["patterns"] as! [[String: Any]]
        for i in pats.indices {
            var tracks = pats[i]["tracks"] as! [[String: Any]]
            for k in tracks.indices { tracks[k]["row"] = nil }
            pats[i]["tracks"] = tracks
        }
        json["patterns"] = pats
        #expect(engine.loadData(try JSONSerialization.data(withJSONObject: json)))
        let a = rows(engine.patterns[0])
        #expect(Set(a).count == 4)
        #expect(rows(engine.patterns[1]) == Array(a.prefix(3)))
        #expect(rows(engine.patterns[5]) == a)                   // aufgefüllter Platz
        let saved = try #require(engine.presetManager.encode(bpm: 120, swing: 50, patterns: engine.patterns))
        let (other, _) = makeEngine()
        #expect(other.loadData(saved))
        #expect(other.patterns.map(rows) == engine.patterns.map(rows))
    }

    /// Pattern einfügen behält die Zeilen der Quelle (gleiches Dokument).
    @Test func pastedPatternKeepsRows() {
        let (engine, _) = makeEngine()
        let r = rows(engine.currentPattern)
        engine.copyCurrentPattern()
        engine.currentPatternIndex = 2
        engine.pasteToCurrentPattern()
        #expect(rows(engine.patterns[2]) == r)
        #expect(Set(engine.patterns[2].tracks.map(\.id)).isDisjoint(with: engine.patterns[0].tracks.map(\.id)))
    }
}
