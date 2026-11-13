import Testing
import Foundation
@testable import VintageSequencer

// MARK: - Track Codable Roundtrip

struct TrackCodableTests {

    /// Vollständiger Encode → Decode Roundtrip für alle relevanten Track-Properties.
    /// Sichert: alle Felder, die in CodingKeys stehen, überleben einen JSON-Zyklus.
    @Test func roundtrip() throws {
        let original = TrackData(name: "Bass", stepCount: 8, midiChannel: 3)
        original.lane.direction              = .reverse
        original.isMuted                = true
        original.isSolo                 = true       // C2: war früher nicht gespeichert
        original.isExpanded             = true       // C2: war früher nicht gespeichert
        original.timingOffset           = 0.02
        original.scaleRoot              = 5
        original.scaleIndex             = 2
        original.colorIndex             = 4          // Track-Farben-Slice v1.12.0
        original.lane.stepLengthNumerator    = 3
        original.lane.stepLengthDenominator  = 2

        original.lane.steps[0].isActive    = true
        original.lane.steps[0].notes       = [60, 64, 67]   // Akkord
        original.lane.steps[0].velocity    = 80
        original.lane.steps[0].gate        = 0.75
        original.lane.steps[0].probability = 0.5
        original.lane.steps[0].ratchet     = .x2

        let data    = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TrackData.self, from: data)

        #expect(decoded.name                  == original.name)
        #expect(decoded.lane.stepCount             == original.lane.stepCount)
        #expect(decoded.midiChannel           == original.midiChannel)
        #expect(decoded.lane.direction             == original.lane.direction)
        #expect(decoded.isMuted               == original.isMuted)
        #expect(decoded.isSolo                == original.isSolo)
        #expect(decoded.isExpanded            == original.isExpanded)
        #expect(decoded.timingOffset          == original.timingOffset)
        #expect(decoded.scaleRoot             == original.scaleRoot)
        #expect(decoded.scaleIndex            == original.scaleIndex)
        #expect(decoded.colorIndex            == original.colorIndex)
        #expect(decoded.lane.stepLengthNumerator   == original.lane.stepLengthNumerator)
        #expect(decoded.lane.stepLengthDenominator == original.lane.stepLengthDenominator)

        // Step-Inhalte
        #expect(decoded.lane.steps[0].isActive    == original.lane.steps[0].isActive)
        #expect(decoded.lane.steps[0].notes       == original.lane.steps[0].notes)
        #expect(decoded.lane.steps[0].velocity    == original.lane.steps[0].velocity)
        #expect(decoded.lane.steps[0].gate        == original.lane.steps[0].gate)
        #expect(decoded.lane.steps[0].probability == original.lane.steps[0].probability)
        #expect(decoded.lane.steps[0].ratchet     == original.lane.steps[0].ratchet)
    }

    /// Decoded tracks müssen immer genau 64 Steps haben (B4: Padding in init(from:)).
    @Test func decodedTrackHas64Steps() throws {
        let track = TrackData(name: "T", stepCount: 4, midiChannel: 1)
        let data  = try JSONEncoder().encode(track)
        let decoded = try JSONDecoder().decode(TrackData.self, from: data)
        #expect(decoded.lane.steps.count == 64)
    }
}

// MARK: - Drum-Modus (v1.12.23)

struct TrackDrumModeTests {

    private func jsonWithoutDrumKey(channel: Int) throws -> Data {
        let track = TrackData(name: "T", stepCount: 4, midiChannel: channel)
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(track)) as! [String: Any]
        obj.removeValue(forKey: "isDrum")
        return try JSONSerialization.data(withJSONObject: obj)
    }

    /// Presets bis v1.12.22 kennen den Key nicht: dort gilt weiter „Kanal 10 = Drum-Spur".
    @Test func missingKeyFallsBackToChannelTen() throws {
        #expect(try JSONDecoder().decode(TrackData.self, from: jsonWithoutDrumKey(channel: 10)).isDrum == true)
        #expect(try JSONDecoder().decode(TrackData.self, from: jsonWithoutDrumKey(channel: 3)).isDrum == false)
    }

    /// Der gespeicherte Modus ist unabhängig vom Kanal und überlebt Speichern/Laden und Kopie.
    @Test func explicitModeRoundTripsIndependentlyOfChannel() throws {
        let melodicOnTen = TrackData(name: "A", stepCount: 4, midiChannel: 10)
        let drumOnThree  = TrackData(name: "B", stepCount: 4, midiChannel: 3)
        drumOnThree.isDrum = true
        let a = try JSONDecoder().decode(TrackData.self, from: JSONEncoder().encode(melodicOnTen))
        let b = try JSONDecoder().decode(TrackData.self, from: JSONEncoder().encode(drumOnThree))
        #expect(a.isDrum == false)
        #expect(b.isDrum == true)
        #expect(drumOnThree.freshCopy().isDrum == true)
    }

    @Test func drumModeChangeIsUndoable() {
        let track = TrackData(name: "T", stepCount: 4, midiChannel: 1)
        let um = UndoManager()
        ModelWriter().apply(.setDrumMode(trackID: track.id, old: false, new: true), to: track, undoManager: um)
        #expect(track.isDrum == true)
        um.undo()
        #expect(track.isDrum == false)
        um.redo()
        #expect(track.isDrum == true)
    }
}

// MARK: - Clamp Validation (B4)

struct TrackClampTests {

    /// Werte außerhalb gültiger Bereiche werden durch clampToValidRanges() auf gültige Grenzen gebracht.
    @Test func outOfRangeValuesAreClamped() {
        let track          = TrackData(name: "Clamp", stepCount: 4, midiChannel: 1)
        track.midiChannel  = 99       // > 16 → 16
        track.lane.stepCount    = 0        // < 1   → 1
        track.timingOffset = 1.0      // > 0.05 → 0.05
        track.scaleRoot    = 15       // > 11  → 11
        track.scaleIndex   = 99       // > max → clamped to scales.count - 1

        track.lane.steps[0].velocity    = 200    // > 127 → 127
        track.lane.steps[0].gate        = -1.0   // < 0.001 → 0.001
        track.lane.steps[0].probability = 2.0    // > 1.0 → 1.0
        track.lane.steps[0].notes       = [200, -5, 60]  // out-of-range notes

        track.clampToValidRanges()

        #expect(track.midiChannel        == 16)
        #expect(track.lane.stepCount          >= 1)
        #expect(track.timingOffset       <= 0.05)
        #expect(track.scaleRoot          == 11)
        #expect(track.scaleIndex         <= TrackData.scales.count - 1)

        #expect(track.lane.steps[0].velocity    == 127)
        #expect(track.lane.steps[0].gate        >= 0.001)
        #expect(track.lane.steps[0].probability == 1.0)
        #expect(track.lane.steps[0].notes.allSatisfy { $0 >= 0 && $0 <= 127 })
    }

    /// Gültige Werte werden durch clampToValidRanges() nicht verändert.
    @Test func validValuesAreUnchangedByClamp() {
        let track          = TrackData(name: "Valid", stepCount: 16, midiChannel: 1)
        track.timingOffset = 0.01
        track.scaleRoot    = 0
        track.scaleIndex   = 1

        track.lane.steps[0].velocity    = 100
        track.lane.steps[0].gate        = 0.5
        track.lane.steps[0].probability = 0.75
        track.lane.steps[0].notes       = [60, 64]

        track.clampToValidRanges()

        #expect(track.midiChannel        == 1)
        #expect(track.timingOffset       == 0.01)
        #expect(track.lane.steps[0].velocity    == 100)
        #expect(track.lane.steps[0].gate        == 0.5)
        #expect(track.lane.steps[0].probability == 0.75)
        #expect(track.lane.steps[0].notes       == [60, 64])
    }

    /// Leere notes-Arrays werden durch clampToValidRanges() mit [60] aufgefüllt.
    @Test func emptyNotesArrayIsFilledWithDefault() {
        let track         = TrackData(name: "Empty", stepCount: 1, midiChannel: 1)
        track.lane.steps[0].notes = []

        track.clampToValidRanges()

        #expect(track.lane.steps[0].notes == [60], "Leeres notes-Array muss mit [60] aufgefüllt werden")
    }
}

// MARK: - loadData Error Handling (B3)

struct SequencerEngineLoadDataTests {

    /// Ungültiges JSON → loadData gibt false zurück und setzt lastErrorMessage (B3).
    @Test func invalidJSONReturnsFalseAndSetsErrorMessage() {
        let engine  = SequencerEngine()
        let badData = "this is not json at all".data(using: .utf8)!

        let result = engine.loadData(badData)

        #expect(result                   == false)
        #expect(engine.lastErrorMessage  != nil)
    }

    /// Leere Daten → loadData gibt false zurück.
    @Test func emptyDataReturnsFalse() {
        let engine = SequencerEngine()
        let result = engine.loadData(Data())

        #expect(result == false)
    }

    /// Gültiger Preset-Roundtrip via saveData() → loadData() → Felder intakt.
    @Test func saveDataAndLoadDataRoundtrip() throws {
        let engine = SequencerEngine()
        // Werte setzen
        engine.bpm   = 140.0
        engine.swing = 60.0
        engine.currentPattern.tracks[0].midiChannel   = 5
        engine.currentPattern.tracks[0].lane.stepCount = 8

        guard let data = engine.saveData() else {
            Issue.record("saveData() sollte nicht nil zurückgeben")
            return
        }

        // Frische Engine laden
        let engine2 = SequencerEngine()
        let ok = engine2.loadData(data)

        #expect(ok                                              == true)
        #expect(engine2.bpm                                     == 140.0)
        #expect(engine2.swing                                   == 60.0)
        #expect(engine2.currentPattern.tracks[0].midiChannel    == 5)
        #expect(engine2.currentPattern.tracks[0].lane.stepCount == 8)
    }
}
