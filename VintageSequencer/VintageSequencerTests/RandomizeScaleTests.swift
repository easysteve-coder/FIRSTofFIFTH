import Testing
import Foundation
@testable import VintageSequencer

// v1.18.8 — RND auf Einzelton-Spuren würfelt bei eingestellter Skala nur leitereigene Töne.

@MainActor @Suite(.serialized) struct RandomizeScaleTests {

    @Test func singleNotesStayInScale() {
        let engine = SequencerEngine()
        let td = engine.currentPattern.tracks[0]
        td.scaleIndex = 2          // Minor
        td.scaleRoot  = 9          // A
        td.lane.rndMode = nil      // Einzeltöne (je Spur seit v1.18.29)
        for _ in 0..<20 {
            engine.randomize(track: td)
            for s in td.lane.steps {
                for n in s.notes { #expect(td.noteInScale(n), "Ton \(n) nicht in A-Moll") }
            }
        }
        // Alle Stufen kommen vor (gleich verteilt, nicht auf wenige Töne quantisiert).
        let pcs = Set(SequencerEngine.singleNotePool(td).map { $0 % 12 })
        #expect(pcs == Set([9, 11, 0, 2, 4, 5, 7]))
    }

    @Test func chromaticWithoutScale() {
        let td = TrackData(name: "T")
        #expect(SequencerEngine.singleNotePool(td) == Array(36...84))
    }
}
