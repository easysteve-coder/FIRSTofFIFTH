import Foundation
import Combine

// MARK: - CC Remote Control

extension SequencerEngine {

    /// Verarbeitet eingehende CC-Nachrichten für Pattern-Switch und Track-Mute.
    /// Wird via midi.onCC aus dem Main-Thread aufgerufen.
    func handleIncomingCC(_ number: Int, _ value: Int) {
        // Pattern switch via CC
        if patternSwitchCC >= 0, number == patternSwitchCC {
            let idx = min(value / 32, 3)   // 0-31=A, 32-63=B, 64-95=C, 96-127=D
            switchPattern(idx)
        }
        // Track mute toggle via CC
        for (i, ccNum) in trackMuteCCs.enumerated() {
            guard ccNum >= 0, number == ccNum else { continue }
            guard i < currentPattern.tracks.count else { continue }
            let td = currentPattern.tracks[i]
            ModelWriter().apply(.setMuted(trackID: td.id, old: td.isMuted, new: value >= 64),
                                to: td, undoManager: nil)
        }
    }
}

// MARK: - MIDI Learn

extension SequencerEngine {

    func setLearnTarget(track: Int, step: Int) {
        guard learnMode else { return }
        learnTarget = (track, step)
    }

    /// Verarbeitet eingehende Note-On-Nachrichten im MIDI-Learn-Modus.
    /// Wird via midi.onNoteOn aus dem Main-Thread aufgerufen.
    func handleLearnNoteOn(_ note: Int) {
        guard learnMode, let target = learnTarget else { return }
        // Das Learn-Ziel ist positionsbasiert; nach Strukturänderungen wird es gelöscht.
        // Der Guard fängt jeden verbleibenden veralteten Index ab.
        let tracks = currentPattern.tracks
        guard tracks.indices.contains(target.track),
              tracks[target.track].lane.steps.indices.contains(target.step) else {
            learnTarget = nil
            return
        }
        // Wie jede andere Step-Bearbeitung: nur das sichtbare Pattern, über ModelWriter, mit Undo.
        let td  = tracks[target.track]
        let old = td.lane.steps
        var steps = old
        steps[target.step].note = td.quantizedNote(note)   // Quantize to track's scale if active
        let s = Str(UserDefaults.standard.string(forKey: "appLanguage") ?? "en")
        ModelWriter().apply(.setSteps(trackID: td.id, oldSteps: old, newSteps: steps,
                                      actionName: s.undoLearnNote),
                            to: td, undoManager: undoManager)
        // Advance to next step automatically
        let nextStep = target.step + 1
        if nextStep < td.lane.stepCount {
            learnTarget = (target.track, nextStep)
        } else {
            learnTarget = nil
            learnMode  = false
        }
    }
}

// MARK: - Randomize

extension SequencerEngine {

    /// Würfelt die sichtbaren Steps neu. Läuft über ModelWriter; das Undo hält Vor- und
    /// Nachzustand fest (Redo würfelt nicht neu).
    func randomize(track td: TrackData, lockNotes: Bool = false) {
        if td.lane.isPad { randomizePadChords(track: td); return }
        let lane = td.lane
        let old  = lane.steps
        var steps = old
        for i in 0..<min(lane.stepCount, steps.count) {
            steps[i].isActive    = Bool.random()
            if !lockNotes {
                steps[i].note    = Int.random(in: 36...84)
            }
            steps[i].velocity    = Int.random(in: 60...120)
            steps[i].gate        = Double.random(in: 0.2...0.9)
            steps[i].probability = [1.0, 1.0, 1.0, 0.75, 0.5].randomElement()!
            // Step-Lane-Purify P1 (v1.10.0): kein Per-Step-CC-Randomize mehr.
            // CC-Randomize gehört in die eigene CC-Lane.
        }
        let s = Str(UserDefaults.standard.string(forKey: "appLanguage") ?? "en")
        ModelWriter().apply(.setSteps(trackID: td.id, oldSteps: old, newSteps: steps,
                                      actionName: s.undoRandomize),
                            to: td, undoManager: undoManager)
    }
}

// MARK: - Pad-Akkorde

extension SequencerEngine {

    /// UserDefaults-Schlüssel der RND-Wahl für Pad-Spuren: Quelle (`PadChordSource`) und
    /// optional eine feste Folge (`ChordProgressionFamily.id`, leer = zufällige Folge).
    static let padChordSourceKey = "padChordSource"
    static let padChordFamilyKey = "padChordFamily"

    /// Würfelt Akkorde für eine Pad-Spur: eine Folge aus Lizzio/Callipari oder leitereigen
    /// (Einstellung im RND-Menü), transponiert auf den Grundton der Spur, mit Stimmführung.
    /// Ein Undo-Schritt über ModelWriter; Redo würfelt nicht neu.
    func randomizePadChords(track td: TrackData) {
        let defaults = UserDefaults.standard
        let source = PadChordSource(rawValue: defaults.string(forKey: Self.padChordSourceKey) ?? "")
            ?? .books
        let lane = td.lane
        let count = min(lane.stepCount, lane.steps.count)
        var rng = SystemRandomNumberGenerator()
        let chords: [ChordSymbol]
        switch source {
        case .books:
            let fixed = PadChords.family(id: defaults.string(forKey: Self.padChordFamilyKey) ?? "")
            let family = fixed ?? PadChords.families.randomElement(using: &rng)!
            chords = PadChords.progression(family, count: count, using: &rng)
        case .free:
            chords = PadChords.freeProgression(scaleIndex: td.scaleIndex, count: count, using: &rng)
        }
        let voiced = PadChords.voice(chords, tonic: td.scaleRoot)
        let old = lane.steps
        var steps = old
        for i in 0..<count {
            steps[i].isActive    = true
            steps[i].isHold      = false
            steps[i].isDrone     = false
            steps[i].notes       = voiced[i]
            steps[i].velocity    = Int.random(in: 80...100)
            steps[i].gate        = 1.0
            steps[i].probability = 1.0
            steps[i].ratchet     = .x1
        }
        let s = Str(defaults.string(forKey: "appLanguage") ?? "en")
        ModelWriter().apply(.setSteps(trackID: td.id, oldSteps: old, newSteps: steps,
                                      actionName: s.undoRandomize),
                            to: td, undoManager: undoManager)
    }
}

// MARK: - Note Preview (Pitch Drag)

extension SequencerEngine {

    /// Spielt Noten als Vorschau — stoppt vorherige Preview-Noten automatisch.
    /// `route`: −1 = externe MIDI-Ausgabe, sonst Slot eines gehosteten Instruments.
    func previewPlay(notes: [Int], channel: Int, velocity: Int = 90, route: Int = -1) {
        stopPreview()
        previewChannel = channel
        previewRoute   = route
        previewEpoch   = route < 0 ? 0 : rack.queue(route).occupancyEpoch
        previewNotes   = notes
        let ch = UInt8((channel - 1) & 0x0F)
        for n in notes {
            if route < 0 { midi.noteOn(channel: channel, note: n, velocity: velocity) }
            else { rack.sendFromMain(route: route, 0x90 | ch, UInt8(n & 0x7F), UInt8(velocity & 0x7F)) }
        }
    }

    /// Stoppt alle aktuell laufenden Preview-Noten.
    func stopPreview() {
        let ch = UInt8((previewChannel - 1) & 0x0F)
        for n in previewNotes {
            if previewRoute < 0 { midi.noteOff(channel: previewChannel, note: n) }
            else { rack.sendFromMain(route: previewRoute, epoch: previewEpoch, 0x80 | ch, UInt8(n & 0x7F), 0) }
        }
        previewNotes = []
    }
}
