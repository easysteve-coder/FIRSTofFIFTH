import Testing
import Foundation
@testable import VintageSequencer

// v1.18.33 — Stephan: „die Snare höre ich nicht, weil da der MIDI Kanal auf 5 stand. Das sollte
// eigentlich keine Rolle spielen, wenn AU ausgewählt ist." Gemessen am Vintage Kit: die Sperrgruppe
// der Hi-Hat schnitt nicht ab, wenn offene und geschlossene Hi-Hat auf Spuren mit verschiedenen
// Kanälen lagen (Note-Off auf dem Kanal der neuen Note). Instrumente spielen daher immer Kanal 1.

@MainActor @Suite struct OutputChannelTests {

    @Test func instrumentAlwaysPlaysChannelOne() {
        let td = TrackData(name: "Snare", midiChannel: 5)
        #expect(td.outputChannel(route: -1) == 5, "externes MIDI: Spurkanal")
        #expect(td.outputChannel(route: 0) == 1)
        #expect(td.outputChannel(route: 7) == 1)
        td.midiChannel = 99
        #expect(td.outputChannel(route: -1) == 16, "begrenzt")
    }

    @Test func midiSubmenuSetsOutputAndChannel() {
        let engine = SequencerEngine()
        let td = engine.currentPattern.tracks[0]
        let ch = UUID()
        td.output = .instrument(ch)
        engine.setMIDIOutput(of: td, channel: 7)
        #expect(td.output == .midi)
        #expect(td.midiChannel == 7)
        engine.setMIDIOutput(of: td, channel: 7)
        #expect(td.output == .midi && td.midiChannel == 7, "zweimal dasselbe ändert nichts")
    }
}
