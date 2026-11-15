import Foundation

// MARK: - ModelCommand

/// Discrete, undoable model mutations produced by interaction sessions.
///
/// Each command carries **both** old and new values so that:
///   - Live drag:   `apply(new)` with `undoManager = nil`
///   - Commit:      `apply(new)` + `registerUndo(old)` in one place (ModelWriter)
///   - Cancel:      `apply(old)` with `undoManager = nil` (no net change)
///
/// **Ownership:** Commands are produced by session types (HandleDragSession,
/// RatioDragSession, …) and consumed exclusively by ModelWriter.
/// No other code in the interaction layer writes the Track properties
/// covered by this enum.
enum ModelCommand {

    /// Change the step count of a track.
    case setStepCount(trackID: UUID, old: Int, new: Int)

    /// Change the step-length ratio (numerator/denominator) of a track.
    case setRatio(trackID: UUID, oldNum: Int, oldDen: Int, newNum: Int, newDen: Int)
    /// Ganze Längenangabe (v1.18.31): Zähler/Nenner, „Gruppe" und Gruppen der Spur — für
    /// „Gruppe" an/aus, Gruppen ändern und eigene Brüche. Ein Undo-Schritt.
    case setLength(trackID: UUID, old: LaneData.LengthState, new: LaneData.LengthState)

    /// Change the notes of a single step (live pitch drag update).
    ///
    /// `oldNotes` is stored for the undo block (registered only when
    /// `undoManager != nil`, i.e. at commit — not during live drag events).
    case setPitchNotes(trackID: UUID, stepIndex: Int, oldNotes: [Int], newNotes: [Int])

    /// Replace the full steps array of a track (pitch drag commit/cancel,
    /// step swap commit, or any bulk step mutation).
    ///
    /// `actionName` is passed through to `NSUndoManager.setActionName`.
    /// Pass any string for cancel invocations — the action name is ignored
    /// when `undoManager == nil`.
    case setSteps(trackID: UUID, oldSteps: [Step], newSteps: [Step], actionName: String)

    // MARK: - Track Metadata Mutations (Pre-Lane Slice E)
    //
    // Ergänzt für alle View→Track-Schreibzugriffe außerhalb von Drag-Interaktionen.
    // Jeder Case trägt old + new, damit ModelWriter ggf. Undo registrieren kann.
    // Ob Undo registriert wird, entscheidet der Aufrufer über undoManager (nil = kein Undo).
    // Slice E-Regel: was heute Undo hat, behält es; was keins hat, bleibt ohne.

    /// Track umbenennen — Undo wird vom Aufrufer registriert (focus-blur commit).
    case setName(trackID: UUID, old: String, new: String)

    /// Mute-Zustand ändern — heute ohne Undo, bleibt ohne.
    case setMuted(trackID: UUID, old: Bool, new: Bool)

    /// Solo-Zustand ändern — heute ohne Undo, bleibt ohne.
    case setSolo(trackID: UUID, old: Bool, new: Bool)

    /// Playback-Richtung ändern — heute ohne Undo, bleibt ohne.
    case setDirection(trackID: UUID, old: PlayDirection, new: PlayDirection)

    /// MIDI-Channel ändern — heute ohne Undo, bleibt ohne.
    case setMIDIChannel(trackID: UUID, old: Int, new: Int)

    /// Bearbeitungsmodus Melodie/Drums ändern (v1.12.23) — mit Undo.
    case setDrumMode(trackID: UUID, old: Bool, new: Bool)

    /// Ausgang der Spur ändern: nil = externe MIDI-Ausgabe, sonst Instrumentenkanal
    /// (v1.13.0) — mit Undo.
    case setInstrument(trackID: UUID, old: UUID?, new: UUID?)

    /// Timing-Offset (Feel) ändern — heute ohne Undo, bleibt ohne.
    case setTimingOffset(trackID: UUID, old: Double, new: Double)

    /// Tonart-Root ändern — heute ohne Undo, bleibt ohne.
    case setScaleRoot(trackID: UUID, old: Int, new: Int)

    /// Tonart-Modus-Index ändern — heute ohne Undo, bleibt ohne.
    case setScaleIndex(trackID: UUID, old: Int, new: Int)

    /// Track-Farbindex ändern (Track-Farben-Slice v1.12.0) — mit Undo.
    /// `newIndex` zeigt in `VintageTheme.trackColors`; Auflösung zu `Color`
    /// passiert ausschließlich im Theme-Resolver. Lanes haben keine eigene
    /// Farbe, daher gibt es auch kein Lane-Äquivalent zu diesem Kommando.
    case setTrackColorIndex(trackID: UUID, old: Int, new: Int)
    /// Spurfarbe als Paar Palette/eigene Farbe (v1.18.25): Palettenwahl setzt `custom` nil,
    /// Farbrad setzt "#RRGGBB". Ein Undo-Schritt.
    case setTrackColor(trackID: UUID, oldIndex: Int, oldCustom: String?, newIndex: Int, newCustom: String?)

    // MARK: - CC-Lane Mutations (CC-Lane Slice 1)
    //
    // Reine CC-Lanes speichern Pro-Step-CC-Werte, CC-Nummer, Label und Mute
    // in der Lane (nicht im Track). Diese Kommandos mutieren `td.lane`.

    /// Einzelnen CC-Wert eines Steps auf einer CC-Lane setzen (live Knob-Drag-Update).
    case setCCLaneValue(trackID: UUID, index: Int, old: Int, new: Int)

    /// Gesamtes ccValues-Array ersetzen (Draw-Commit, Randomize, Reset).
    case setCCLaneValues(trackID: UUID, oldValues: [Int], newValues: [Int], actionName: String)

    /// CC-Nummer einer CC-Lane ändern.
    case setCCLaneNumber(trackID: UUID, old: Int, new: Int)

    /// Ziel einer CC-Lane im gehosteten Instrument ändern (nil = MIDI-CC) — mit Undo (v1.13.9).
    case setCCLaneParameter(trackID: UUID, old: ParameterRef?, new: ParameterRef?)

    /// Label einer CC-Lane ändern (focus-blur commit).
    case setCCLaneLabel(trackID: UUID, old: String, new: String)

    /// Mute-Zustand einer CC-Lane ändern.
    case setCCLaneMuted(trackID: UUID, old: Bool, new: Bool)

    /// Fester Ton einer Step-Lane (v1.13.16): alle Steps spielen diese Note (nil = aus).
    case setFixedNotes(trackID: UUID, old: [Int]?, new: [Int]?)

    /// Breite langer Steps in Normalbreiten, 0 = automatisch (v1.13.19 für Pads, v1.18.29 alle).
    case setStepWidth(trackID: UUID, old: Int, new: Int)

    /// RND-Töne der Spur (v1.18.29): Einzeltöne/Akkorde/gemischt, nil = Einzeltöne.
    case setRndMode(trackID: UUID, old: RandomNoteMode?, new: RandomNoteMode?)

    // MARK: - Metadata

    /// User-visible undo action name shown in the macOS Edit menu.
    var undoActionName: String {
        switch self {
        case .setStepCount:                  return "Step Count"
        case .setRatio:                      return "Step Ratio"
        case .setLength:                     return "Step Ratio"
        case .setPitchNotes:                 return "Pitch Drag"
        case .setSteps(_, _, _, let n):     return n
        case .setName:                       return "Rename Track"
        case .setMuted:                      return "Mute"
        case .setSolo:                       return "Solo"
        case .setDirection:                  return "Direction"
        case .setMIDIChannel:                return "MIDI Channel"
        case .setDrumMode:                   return "Track Mode"
        case .setInstrument:                 return "Track Output"
        case .setTimingOffset:               return "Feel"
        case .setScaleRoot:                  return "Scale Root"
        case .setScaleIndex:                 return "Scale Mode"
        case .setTrackColorIndex, .setTrackColor: return "Change Track Color"
        case .setCCLaneValue:                return "CC Value"
        case .setCCLaneValues(_, _, _, let n): return n
        case .setCCLaneNumber:               return "CC Number"
        case .setCCLaneParameter:            return "CC Target"
        case .setCCLaneLabel:                return "CC Label"
        case .setCCLaneMuted:                return "CC Mute"
        case .setFixedNotes:                 return "Fixed Notes"
        case .setStepWidth:                  return "Step Width"
        case .setRndMode:                    return "RND Notes"
        }
    }
}
