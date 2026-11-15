import Foundation
import Combine

// MARK: - CC Remote Control

extension SequencerEngine {

    /// Verarbeitet eingehende CC-Nachrichten für Pattern-Switch und Track-Mute.
    /// Wird via midi.onCC aus dem Main-Thread aufgerufen.
    func handleIncomingCC(_ number: Int, _ value: Int) {
        // Pattern switch via CC
        if patternSwitchCC >= 0, number == patternSwitchCC {
            let idx = min(value / 8, Pattern.slotNames.count - 1)   // 0–7=A, 8–15=B … 120–127=P (v1.14.0)
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
    ///
    /// Töne nach `RandomNoteMode` (v1.16.2): Einzeltöne zufällig im Bereich C2–C6; Akkorde
    /// aus derselben Quelle wie Pad-Spuren (Bücher-Folge oder leitereigen, mit Stimmführung);
    /// gemischt je Step Akkord oder einer seiner Töne. Drum-Spuren würfeln nur Einzeltöne.
    func randomize(track td: TrackData, lockNotes: Bool = false) {
        let mode = td.isDrum ? .single : (td.lane.rndMode ?? .single)
        // Lange Steps (v1.18.29, vorher Pad-Spuren): jeder Step klingt, legato, Folge.
        if td.lane.isLongStep, !td.isDrum { randomizePadChords(track: td, mode: mode); return }
        let lane = td.lane
        let old  = lane.steps
        var steps = old
        let count = min(lane.stepCount, steps.count)
        let chords = (lockNotes || mode == .single) ? [] : rolledChords(for: td, count: count)
        let pool = Self.singleNotePool(td)
        for i in 0..<count {
            steps[i].isActive    = Bool.random()
            if !lockNotes {
                steps[i].notes   = Self.notes(mode: mode, chord: chords.indices.contains(i) ? chords[i] : nil,
                                              pool: pool)
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

    /// Töne eines Steps nach Modus; `chord` ist der gewürfelte Akkord dieses Steps, `pool`
    /// die erlaubten Einzeltöne.
    static func notes(mode: RandomNoteMode, chord: [Int]?, pool: [Int] = Array(36...84)) -> [Int] {
        switch (mode, chord) {
        case (.chords, let c?) where !c.isEmpty: return c
        case (.mixed, let c?) where !c.isEmpty:  return Bool.random() ? c : [c.randomElement()!]
        default:                                 return [pool.randomElement() ?? 60]
        }
    }

    /// Einzeltöne für RND: C2–C6, bei eingestellter Skala nur leitereigene Töne (Grundton der
    /// Spur). Gleich verteilt über die Töne der Leiter — nicht nachträglich quantisiert, das
    /// würde einzelne Stufen bevorzugen.
    static func singleNotePool(_ td: TrackData) -> [Int] {
        let all = Array(36...84)
        guard td.scaleIndex > 0 else { return all }
        let inScale = all.filter(td.noteInScale)
        return inScale.isEmpty ? all : inScale
    }
}

// MARK: - Pad-Akkorde

extension SequencerEngine {

    /// UserDefaults-Schlüssel der RND-Wahl für Pad-Spuren: Quelle (`PadChordSource`) und
    /// optional eine feste Folge (`ChordProgressionFamily.id`, leer = zufällige Folge).
    static let padChordSourceKey = "padChordSource"
    static let padChordFamilyKey = "padChordFamily"

    /// Akkordfolge für `count` Steps aus der im RND-Menü gewählten Quelle, transponiert auf
    /// den Grundton der Spur, mit Stimmführung.
    func rolledChords(for td: TrackData, count: Int) -> [[Int]] {
        let defaults = UserDefaults.standard
        let source = PadChordSource(rawValue: defaults.string(forKey: Self.padChordSourceKey) ?? "")
            ?? .books
        var rng = SystemRandomNumberGenerator()
        return Self.rolledChords(scaleIndex: td.scaleIndex, scaleRoot: td.scaleRoot, count: count,
                                 source: source,
                                 fixedFamily: PadChords.family(id: defaults.string(forKey: Self.padChordFamilyKey) ?? ""),
                                 using: &rng)
    }

    /// Kern von `rolledChords` (testbar). Bei eingestellter Skala (v1.18.14) liegt jeder Akkord
    /// ganz in ihr: aus den Büchern nur Folgen, die vollständig passen (die fest gewählte, sonst
    /// eine passende); passt keine, leitereigen.
    static func rolledChords<R: RandomNumberGenerator>(scaleIndex: Int, scaleRoot: Int, count: Int,
                                                       source: PadChordSource,
                                                       fixedFamily: ChordProgressionFamily?,
                                                       using rng: inout R) -> [[Int]] {
        let restrict = scaleIndex > 0 && TrackData.scales.indices.contains(scaleIndex)
        let scale = restrict ? Set(TrackData.scales[scaleIndex].intervals) : nil
        var chords: [ChordSymbol] = []
        if source == .books {
            var pool = fixedFamily.map { [$0] } ?? PadChords.families
            if let scale {
                pool = pool.filter { PadChords.fits($0, scale: scale) }
                if pool.isEmpty { pool = PadChords.families.filter { PadChords.fits($0, scale: scale) } }
            }
            if let family = pool.randomElement(using: &rng) {
                chords = PadChords.progression(family, count: count, using: &rng)
            }
        }
        if chords.isEmpty {
            chords = PadChords.freeProgression(scaleIndex: scaleIndex, count: count, restrict: restrict, using: &rng)
        }
        return PadChords.voice(chords, tonic: scaleRoot)
    }

    /// Würfelt Akkorde für eine Pad-Spur: eine Folge aus Lizzio/Callipari oder leitereigen
    /// (Einstellung im RND-Menü), transponiert auf den Grundton der Spur, mit Stimmführung.
    /// Ein Undo-Schritt über ModelWriter; Redo würfelt nicht neu.
    func randomizePadChords(track td: TrackData, mode: RandomNoteMode = .chords) {
        let lane = td.lane
        let count = min(lane.stepCount, lane.steps.count)
        let voiced = rolledChords(for: td, count: count)
        let old = lane.steps
        var steps = old
        for i in 0..<count {
            steps[i].isActive    = true
            steps[i].isHold      = false
            steps[i].isDrone     = false
            // Einzelton auf Pad-Spuren: ein Ton des Akkords dieses Steps (bleibt in der Folge).
            steps[i].notes       = mode == .single ? [voiced[i].randomElement() ?? 60]
                                 : Self.notes(mode: mode, chord: voiced[i])
            steps[i].velocity    = Int.random(in: 80...100)
            steps[i].gate        = 1.0
            steps[i].probability = 1.0
            steps[i].ratchet     = .x1
        }
        let s = Str(UserDefaults.standard.string(forKey: "appLanguage") ?? "en")
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
