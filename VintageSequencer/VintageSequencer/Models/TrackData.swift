import Foundation
import Combine

// MARK: - Scale definitions

struct ScaleDefinition {
    let name:      String
    let shortName: String
    let intervals: [Int]   // semitones from root, 0-based
}

// MARK: - Play direction

enum PlayDirection: String, CaseIterable, Codable {
    case forward  = "FWD"
    case reverse  = "REV"
    case pingPong = "P-P"
    case random   = "RND"
}

// MARK: - TrackData
//
// Container-Modell — trägt Routing, CC-Setup, Mute/Solo, Scale, Timing-Offset,
// UI-State. Der Sequenzkern (Steps, Ratio, Direction, StepCount) liegt in
// `lane: LaneData`, zu dem eine verbindliche 1:1-Beziehung besteht
// (ENGINEERING.md — Lane-Modell v1).
//
// Plain class, NICHT ObservableObject. Container- und Lane-Signale laufen
// unabhängig: Container-Feldmutationen → `trackData.changed.send()`;
// Sequenz-Feldmutationen → `lane.changed.send()`. Keine Kreuz-Propagation.
//
// ModelWriter bleibt kanonischer Pfad für undo-fähige Mutationen — Writer
// entscheidet anhand des Kommandos, ob er auf `td` oder `td.lane` schreibt.
final class TrackData: Identifiable {

    // MARK: - Scale library (shared)

    static let scales: [ScaleDefinition] = [
        ScaleDefinition(name: "Chromatic",      shortName: "—",    intervals: [0,1,2,3,4,5,6,7,8,9,10,11]),
        ScaleDefinition(name: "Major",          shortName: "MAJ",  intervals: [0,2,4,5,7,9,11]),
        ScaleDefinition(name: "Minor",          shortName: "MIN",  intervals: [0,2,3,5,7,8,10]),
        ScaleDefinition(name: "Dorian",         shortName: "DOR",  intervals: [0,2,3,5,7,9,10]),
        ScaleDefinition(name: "Phrygian",       shortName: "PHR",  intervals: [0,1,3,5,7,8,10]),
        ScaleDefinition(name: "Lydian",         shortName: "LYD",  intervals: [0,2,4,6,7,9,11]),
        ScaleDefinition(name: "Mixolydian",     shortName: "MIX",  intervals: [0,2,4,5,7,9,10]),
        ScaleDefinition(name: "Harm. Minor",    shortName: "HRM",  intervals: [0,2,3,5,7,8,11]),
        ScaleDefinition(name: "Penta Major",    shortName: "PM+",  intervals: [0,2,4,7,9]),
        ScaleDefinition(name: "Penta Minor",    shortName: "PM-",  intervals: [0,3,5,7,10]),
        ScaleDefinition(name: "Blues",          shortName: "BLU",  intervals: [0,3,5,6,7,10]),
        ScaleDefinition(name: "Whole Tone",     shortName: "WHL",  intervals: [0,2,4,6,8,10]),
    ]
    static let noteNames = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]

    /// Precomputed scale-quantization lookup table.
    /// `quantTable[scaleIndex][root][note]` → nearest in-scale MIDI note (0–127).
    static let quantTable: [[[Int]]] = {
        let scaleCount = scales.count
        var table = [[[Int]]](
            repeating: [[Int]](
                repeating: [Int](repeating: 0, count: 128),
                count: 12
            ),
            count: scaleCount
        )
        for si in 0..<scaleCount {
            let intervals = scales[si].intervals
            var inScale = [Bool](repeating: false, count: 12)
            for iv in intervals { inScale[iv] = true }
            for root in 0..<12 {
                for note in 0..<128 {
                    var best = note
                    var bestDist = Int.max
                    for candidate in 0..<128 {
                        let semitone = ((candidate % 12) - root + 12) % 12
                        if inScale[semitone] {
                            let dist = abs(candidate - note)
                            if dist < bestDist { bestDist = dist; best = candidate }
                        }
                    }
                    table[si][root][note] = best
                }
            }
        }
        return table
    }()

    /// All valid step-length ratios, ascending by num/den.
    static let sortedRatios: [(num: Int, den: Int)] = [
        (1,2), (4,7), (2,3), (3,4), (4,5), (8,9), (1,1),
        (9,8), (5,4), (4,3), (3,2), (7,4), (2,1)
    ]

    /// Steplängen der Pad-Lane (Vielfache einer 16tel): Viertel, Halbe, punktierte Halbe,
    /// 1, 2, 3, 4 und 8 Takte (4/4).
    static let padRatios: [(num: Int, den: Int)] = [
        (4,1), (8,1), (12,1), (16,1), (32,1), (48,1), (64,1), (128,1)
    ]

    /// Anzeige einer Steplänge: Pad-Werte in Takten bzw. Notenwerten, sonst „n/d“.
    static func ratioLabel(num: Int, den: Int) -> String {
        guard den == 1, num >= 4 else { return "\(num)/\(den)" }
        switch num {
        case 4:  return "1/4"
        case 8:  return "1/2"
        case 12: return "3/4"
        default: return num % 16 == 0 ? "\(num / 16) T" : "\(num)/16"
        }
    }

    // MARK: - Change notification (NOT Codable)

    /// Fires synchronously on the Main Thread after any container-field mutation.
    /// TrackViewModel subscribes and forwards to its `objectWillChange`.
    let changed = PassthroughSubject<Void, Never>()

    // MARK: - Identity

    let id: UUID

    // MARK: - Sequence (1:1)

    /// The single LaneData that carries this track's sequence kernel.
    /// Non-optional, stable for the lifetime of the TrackData instance.
    let lane: LaneData

    // MARK: - Container fields

    var name:        String        = "Track"
    var midiChannel: Int           = 1
    /// Bearbeitungsmodus der Spur: Drum-Namen und Drum-Auswahl statt Klaviatur/Akkorden.
    /// Seit v1.12.23 eigener Zustand; vorher implizit „MIDI-Kanal 10". Reine
    /// Darstellungs-/Bearbeitungsfrage — der Tick-Pfad liest das Feld nicht.
    var isDrum:        Bool          = false
    /// Ausgang der Spur (v1.13.0): nil = externe MIDI-Ausgabe (CoreMIDI), sonst die ID
    /// eines Instrumentenkanals im `InstrumentRack`. Mehrere Spuren dürfen denselben Kanal
    /// spielen. Zeigt die ID auf keinen vorhandenen Kanal, gilt externe MIDI-Ausgabe.
    var instrumentID:  UUID?         = nil
    var isMuted:       Bool          = false
    var isSolo:        Bool          = false
    var isExpanded:    Bool          = false
    /// Timing offset in seconds: negative = ahead (pushed), positive = behind (laid back)
    var timingOffset:  Double        = 0.0
    var scaleRoot:     Int           = 0    // 0=C … 11=B
    var scaleIndex:    Int           = 0    // 0=Chromatic (off)
    /// Persistenter Index in `VintageTheme.trackColors` (v1.9.1, Slice A).
    /// An die Track-Identität gebunden — bleibt beim Löschen/Einfügen anderer
    /// Tracks stabil. Wird bei Track-Erzeugung gesetzt.
    var colorIndex:    Int           = 0

    // MARK: - Init

    init(name: String,
         stepCount: Int = 16,
         midiChannel: Int = 1,
         id: UUID = UUID(),
         colorIndex: Int = 0,
         lane: LaneData? = nil) {
        self.id          = id
        self.name        = name
        self.midiChannel = midiChannel
        self.colorIndex  = colorIndex
        self.lane        = lane ?? LaneData(stepCount: stepCount)
    }

    // MARK: - Duplication

    /// Returns a structurally identical copy with **fresh UUIDs** for both
    /// Track and Lane. Required so vmCache and SwiftUI ForEach see distinct
    /// identities after a duplicate operation.
    func freshCopy() -> TrackData {
        let laneCopy = LaneData(stepCount: lane.stepCount, kind: lane.kind)
        laneCopy.steps                 = lane.steps
        laneCopy.direction             = lane.direction
        laneCopy.stepLengthNumerator   = lane.stepLengthNumerator
        laneCopy.isPad                 = lane.isPad
        laneCopy.fixedNote             = lane.fixedNote
        laneCopy.stepLengthDenominator = lane.stepLengthDenominator
        // CC-Lane payload (CC-Lane Slice 1): für .step sind diese Felder leer/default
        // und werden trotzdem übernommen — kein Schaden, kein Seiteneffekt.
        laneCopy.ccValues  = lane.ccValues
        laneCopy.ccNumber  = lane.ccNumber
        laneCopy.ccLabel   = lane.ccLabel
        laneCopy.ccIsMuted = lane.ccIsMuted
        laneCopy.ccParameter = lane.ccParameter

        let copy = TrackData(
            name:        name,
            stepCount:   lane.stepCount,
            midiChannel: midiChannel,
            lane:        laneCopy
        )
        copy.isMuted      = isMuted
        copy.isSolo       = isSolo
        copy.isDrum       = isDrum
        copy.instrumentID = instrumentID
        copy.isExpanded   = isExpanded
        copy.timingOffset = timingOffset
        copy.scaleRoot    = scaleRoot
        copy.scaleIndex   = scaleIndex
        copy.colorIndex   = colorIndex
        return copy
    }

    // MARK: - Scale helpers

    func noteInScale(_ note: Int) -> Bool {
        guard scaleIndex > 0 else { return true }
        let semitone = ((note % 12) - scaleRoot + 12) % 12
        return TrackData.scales[scaleIndex].intervals.contains(semitone)
    }

    /// Returns the closest in-scale MIDI note to the given note.
    func quantizedNote(_ note: Int) -> Int {
        guard scaleIndex > 0 else { return note }
        return TrackData.quantTable[scaleIndex][scaleRoot][max(0, min(127, note))]
    }
}

// MARK: - Codable

extension TrackData: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, midiChannel, lane
        case isMuted, isSolo, isExpanded, timingOffset, scaleRoot, scaleIndex
        case colorIndex, isDrum, instrumentID
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,           forKey: .id)
        try c.encode(name,         forKey: .name)
        try c.encode(midiChannel,  forKey: .midiChannel)
        try c.encode(lane,         forKey: .lane)
        try c.encode(isMuted,      forKey: .isMuted)
        try c.encode(isSolo,       forKey: .isSolo)
        try c.encode(isExpanded,   forKey: .isExpanded)
        try c.encode(timingOffset, forKey: .timingOffset)
        try c.encode(scaleRoot,    forKey: .scaleRoot)
        try c.encode(scaleIndex,   forKey: .scaleIndex)
        try c.encode(colorIndex,   forKey: .colorIndex)
        try c.encode(isDrum,       forKey: .isDrum)
        try c.encodeIfPresent(instrumentID, forKey: .instrumentID)
    }

    convenience init(from decoder: Decoder) throws {
        let c        = try decoder.container(keyedBy: CodingKeys.self)
        let id       = try c.decode(UUID.self,     forKey: .id)
        let name     = try c.decode(String.self,   forKey: .name)
        let channel  = try c.decode(Int.self,      forKey: .midiChannel)
        let lane     = try c.decode(LaneData.self, forKey: .lane)
        self.init(name: name, midiChannel: channel, id: id, lane: lane)
        self.isMuted      = try c.decode(Bool.self,   forKey: .isMuted)
        self.isSolo       = try c.decode(Bool.self,   forKey: .isSolo)
        self.isExpanded   = try c.decode(Bool.self,   forKey: .isExpanded)
        self.timingOffset = try c.decode(Double.self, forKey: .timingOffset)
        self.scaleRoot    = try c.decode(Int.self,    forKey: .scaleRoot)
        self.scaleIndex   = try c.decode(Int.self,    forKey: .scaleIndex)
        // colorIndex (v1.9.1): in Legacy-Presets nicht vorhanden → Sentinel -1.
        // Pattern-Decoder patcht fehlende Werte positionsbasiert nach, damit
        // das optische Erscheinungsbild alter Presets erhalten bleibt.
        self.colorIndex   = try c.decodeIfPresent(Int.self, forKey: .colorIndex) ?? -1
        // isDrum (v1.12.23): optionaler Key. Fehlt er (Presets bis v1.12.22), gilt die
        // frühere Regel „Kanal 10 = Drum-Spur" — alte Presets sehen aus wie zuvor.
        self.isDrum       = try c.decodeIfPresent(Bool.self, forKey: .isDrum) ?? (channel == 10)
        // instrumentID (v1.13.0): optional; fehlt → externe MIDI-Ausgabe.
        self.instrumentID = try c.decodeIfPresent(UUID.self, forKey: .instrumentID)
    }
}

// MARK: - Validation

extension TrackData {

    /// Clamps container- and lane-field values to valid ranges.
    /// Called after preset decode. Does NOT call `changed.send()`.
    func clampToValidRanges() {
        midiChannel  = max(1,   min(16,  midiChannel))
        timingOffset = max(-0.05, min(0.05, timingOffset))
        scaleRoot    = max(0, min(11, scaleRoot))
        scaleIndex   = max(0, min(TrackData.scales.count - 1, scaleIndex))
        lane.clampToValidRanges()
    }
}
