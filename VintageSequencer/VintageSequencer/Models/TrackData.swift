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

    // MARK: Notenwerte (v1.18.31)
    //
    // Stephan: „Die Step-Längen in Quick-Select sind für Normalos nicht intuitiv, da müssen wir
    // mit brüchen arbeiten". Angezeigt wird jede Länge als Bruch der ganzen Note (1/16, 3/8,
    // 1/12); gespeichert bleibt sie als Vielfaches einer Sechzehntel (Zähler/Nenner) wie bisher.

    enum NoteRow: CaseIterable { case straight, dotted, triplet, quintuplet, septuplet }

    /// Schnellwahl je Zeile, Brüche der ganzen Note.
    static let noteRows: [(row: NoteRow, values: [(p: Int, q: Int)])] = [
        (.straight,   [(1, 32), (1, 16), (1, 8), (1, 4), (1, 2), (1, 1)]),
        (.dotted,     [(3, 32), (3, 16), (3, 8), (3, 4)]),
        (.triplet,    [(1, 24), (1, 12), (1, 6), (1, 3)]),
        (.quintuplet, [(1, 20), (1, 10), (1, 5)]),
        (.septuplet,  [(1, 28), (1, 14), (1, 7)]),
    ]

    private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? abs(a) : gcd(b, a % b) }

    /// Bruch der ganzen Note → Länge in Sechzehnteln (Zähler/Nenner, gekürzt).
    static func ratio(whole p: Int, _ q: Int) -> (num: Int, den: Int) {
        let a = 16 * max(1, p), b = max(1, q), g = gcd(a, b)
        return (a / g, b / g)
    }
    /// Länge in Sechzehnteln → Bruch der ganzen Note (gekürzt).
    static func wholeFraction(num: Int, den: Int) -> (p: Int, q: Int) {
        let a = max(1, num), b = 16 * max(1, den), g = gcd(a, b)
        return (a / g, b / g)
    }
    /// Eingabe „5/16", „1/12", „2" (ganze Noten) → Länge in Sechzehnteln; nil = unlesbar oder
    /// außerhalb 1 Puls … 8 Takte 16/16.
    static func parseFraction(_ text: String) -> (num: Int, den: Int)? {
        let parts = text.replacingOccurrences(of: " ", with: "").split(separator: "/").map { Int($0) }
        guard (1...2).contains(parts.count), parts.allSatisfy({ ($0 ?? 0) > 0 }) else { return nil }
        let r = ratio(whole: parts[0]!, parts.count == 2 ? parts[1]! : 1)
        let pulses = 6.0 * Double(r.num) / Double(r.den)
        guard pulses >= 1, Double(r.num) / Double(r.den) <= Double(maxLongSixteenths) else { return nil }
        return r
    }

    /// Ganze Takte in der Taktart des Patterns: 1, 2, 3, 4, 8 (v1.18.31; vorher mit Schlägen).
    static func barRatios(_ meter: TimeSignature) -> [(num: Int, den: Int)] {
        [1, 2, 3, 4, 8].map { ($0 * meter.sixteenthsPerBar, 1) }
    }
    /// Alle Längen der Schnellwahl einer Spur, aufsteigend, ohne doppelte Werte — Liste des
    /// Längen-Anfassers.
    static func stepRatios(_ meter: TimeSignature) -> [(num: Int, den: Int)] {
        let all = noteRows.flatMap { $0.values.map { ratio(whole: $0.p, $0.q) } } + barRatios(meter)
        var seen = Set<Double>(), out: [(num: Int, den: Int)] = []
        for r in all.sorted(by: { Double($0.num) / Double($0.den) < Double($1.num) / Double($1.den) }) {
            let v = Double(r.num) / Double(r.den)
            if seen.insert(v).inserted { out.append(r) }
        }
        return out
    }
    /// Längste Pad-Steplänge in Sechzehnteln (8 Takte 16/16).
    static let maxLongSixteenths = 8 * 16 * 16


    // MARK: - Change notification (NOT Codable)

    /// Fires synchronously on the Main Thread after any container-field mutation.
    /// TrackViewModel subscribes and forwards to its `objectWillChange`.
    let changed = PassthroughSubject<Void, Never>()
    /// Reine Ansichtsänderung (Einklappen, v1.17.7): die Spurzeile zeichnet neu, Playback
    /// und Snapshot reagieren nicht (Codex A17-08).
    let viewChanged = PassthroughSubject<Void, Never>()

    // MARK: - Identity

    let id: UUID
    /// Zeile (v1.18.6, Codex A17-12): die Spuren derselben Zeile in allen Patterns teilen
    /// diesen Schlüssel. Verschieben, Einklappen, Löschen und Duplizieren wirken über ihn,
    /// nicht über die Zeilennummer — Patterns mit unterschiedlichen Spuren verrutschen nicht.
    /// Kopien eines Patterns behalten ihn, eine duplizierte Spur bekommt eine neue Zeile.
    var row: UUID
    /// Beim Laden aus der Datei gelesen (nicht gespeichert). Fehlt er, vergibt
    /// `Pattern.assignMissingRows` die Zeile nach Zeilennummer (ältere Dateien).
    private(set) var rowFromFile = false

    // MARK: - Sequence (1:1)

    /// The single LaneData that carries this track's sequence kernel.
    /// Non-optional, stable for the lifetime of the TrackData instance.
    let lane: LaneData

    // MARK: - Container fields

    var name:        String        = "Track"
    var midiChannel: Int           = 1
    /// Kanal der Ausgabe an `route` (v1.18.33): externes MIDI (route < 0) spielt auf dem
    /// Spurkanal, ein gehostetes Instrument immer auf Kanal 1. Sonst trafen Spuren mit
    /// verschiedenen Kanälen im Sampler getrennte Stimmen — die Sperrgruppe (Hi-Hat) ging
    /// ins Leere, und Kanäle, auf die ein Instrument nicht hört, blieben stumm.
    static let instrumentChannel = 1
    func outputChannel(route: Int) -> Int {
        route >= 0 ? Self.instrumentChannel : max(1, min(16, midiChannel))
    }
    /// Bearbeitungsmodus der Spur: Drum-Namen und Drum-Auswahl statt Klaviatur/Akkorden.
    /// Seit v1.12.23 eigener Zustand; vorher implizit „MIDI-Kanal 10". Reine
    /// Darstellungs-/Bearbeitungsfrage — der Tick-Pfad liest das Feld nicht.
    var isDrum:        Bool          = false
    /// Was die Spur spielt und wohin (v1.16.0, Codex M4): MIDI, Instrumentenkanal oder —
    /// fest — der Loop eines Audio-Loop-Kanals. Mehrere Spuren dürfen denselben
    /// Instrumentenkanal spielen.
    var output: TrackOutput = .midi
    /// Kanal der Spur (nil = MIDI). Setzen wählt den Instrumentenkanal einer Noten-/CC-Spur;
    /// eine Audio-Loop-Spur bleibt an ihren Kanal gebunden (Setzen wirkt dort nicht).
    var instrumentID: UUID? {
        get { output.channelID }
        set {
            guard !output.isAudioLoop else { return }
            output = newValue.map { .instrument($0) } ?? .midi
        }
    }
    /// Audio-Loop-Spur: spielt den Loop ihres Kanals statt Steps; die Lane ist ungenutzt und
    /// wird nicht gespeichert.
    var isAudioLoop: Bool { output.isAudioLoop }
    var isMuted:       Bool          = false
    var isSolo:        Bool          = false
    var isExpanded:    Bool          = false
    /// Timing offset in seconds: negative = ahead (pushed), positive = behind (laid back)
    var timingOffset:  Double        = 0.0
    /// Größter Spuroffset in Sekunden, beide Richtungen; der Clock-Vorlauf deckt ihn ab.
    static let maxTimingOffset = 0.050
    var scaleRoot:     Int           = 0    // 0=C … 11=B
    var scaleIndex:    Int           = 0    // 0=Chromatic (off)
    /// Persistenter Index in `VintageTheme.trackColors` (v1.9.1, Slice A).
    /// An die Track-Identität gebunden — bleibt beim Löschen/Einfügen anderer
    /// Tracks stabil. Wird bei Track-Erzeugung gesetzt.
    var colorIndex:    Int           = 0
    /// Eigene Farbe aus dem Farbrad als "#RRGGBB" (v1.18.25); nil = Palette (`colorIndex`).
    /// Optionaler Presetschlüssel `color`.
    var customColor:   String?       = nil
    /// Eingeklappt (v1.17.3): die Zeile zeigt nur eine schmale Leiste; die Spur spielt
    /// weiter. Reine Ansicht, gilt für die Zeile in allen Patterns (`setTrackCollapsed`).
    var isCollapsed:   Bool          = false

    // MARK: - Init

    init(name: String,
         stepCount: Int = 16,
         midiChannel: Int = 1,
         id: UUID = UUID(),
         row: UUID = UUID(),
         colorIndex: Int = 0,
         lane: LaneData? = nil) {
        self.id          = id
        self.row         = row
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
        laneCopy.rndMode               = lane.rndMode
        laneCopy.stepWidth             = lane.stepWidth
        laneCopy.stepGroup             = lane.stepGroup
        laneCopy.groups                = lane.groups
        laneCopy.fixedNotes            = lane.fixedNotes
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
            row:         row,
            lane:        laneCopy
        )
        copy.isMuted      = isMuted
        copy.isSolo       = isSolo
        copy.isDrum       = isDrum
        copy.output       = output
        copy.isExpanded   = isExpanded
        copy.timingOffset = timingOffset
        copy.scaleRoot    = scaleRoot
        copy.scaleIndex   = scaleIndex
        copy.colorIndex   = colorIndex
        copy.customColor  = customColor
        copy.isCollapsed  = isCollapsed
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
        case colorIndex, isDrum, output
        case customColor = "color"
        case isCollapsed = "collapsed"
        case row
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,           forKey: .id)
        try c.encode(name,         forKey: .name)
        try c.encode(midiChannel,  forKey: .midiChannel)
        if !isAudioLoop { try c.encode(lane, forKey: .lane) }   // Loop-Spur: keine Steps
        try c.encode(isMuted,      forKey: .isMuted)
        try c.encode(isSolo,       forKey: .isSolo)
        try c.encode(isExpanded,   forKey: .isExpanded)
        try c.encode(timingOffset, forKey: .timingOffset)
        try c.encode(scaleRoot,    forKey: .scaleRoot)
        try c.encode(scaleIndex,   forKey: .scaleIndex)
        try c.encode(colorIndex,   forKey: .colorIndex)
        try c.encodeIfPresent(customColor, forKey: .customColor)
        try c.encode(isDrum,       forKey: .isDrum)
        try c.encode(output,       forKey: .output)
        if isCollapsed { try c.encode(true, forKey: .isCollapsed) }   // optional, nur wenn gesetzt
        try c.encode(row,          forKey: .row)                        // optional beim Lesen (v1.18.6)
    }

    convenience init(from decoder: Decoder) throws {
        let c        = try decoder.container(keyedBy: CodingKeys.self)
        let id       = try c.decode(UUID.self,     forKey: .id)
        let name     = try c.decode(String.self,   forKey: .name)
        let channel  = try c.decode(Int.self,      forKey: .midiChannel)
        // `output` ist ab v1.16.0 Pflicht (ältere Presets laden nicht).
        let output   = try c.decode(TrackOutput.self, forKey: .output)
        let lane     = output.isAudioLoop ? LaneData() : try c.decode(LaneData.self, forKey: .lane)
        self.init(name: name, midiChannel: channel, id: id, lane: lane)
        self.output  = output
        self.isMuted      = try c.decode(Bool.self,   forKey: .isMuted)
        self.isSolo       = try c.decode(Bool.self,   forKey: .isSolo)
        self.isExpanded   = try c.decode(Bool.self,   forKey: .isExpanded)
        // Zulässiger Bereich ±50 ms (Bedienung und Clock-Vorlauf, v1.16.1 Codex V16-3).
        self.timingOffset = max(-Self.maxTimingOffset,
                                min(Self.maxTimingOffset, try c.decode(Double.self, forKey: .timingOffset)))
        self.scaleRoot    = try c.decode(Int.self,    forKey: .scaleRoot)
        self.scaleIndex   = try c.decode(Int.self,    forKey: .scaleIndex)
        // colorIndex (v1.9.1): in Legacy-Presets nicht vorhanden → Sentinel -1.
        // Pattern-Decoder patcht fehlende Werte positionsbasiert nach, damit
        // das optische Erscheinungsbild alter Presets erhalten bleibt.
        self.colorIndex   = try c.decodeIfPresent(Int.self, forKey: .colorIndex) ?? -1
        // Eigene Farbe (v1.18.25): optional; unlesbar → Palette.
        self.customColor  = (try? c.decodeIfPresent(String.self, forKey: .customColor)).flatMap { $0 }
            .flatMap { VintageTheme.color(hex: $0) != nil ? $0 : nil }
        // isDrum (v1.12.23): optionaler Key. Fehlt er (Presets bis v1.12.22), gilt die
        // frühere Regel „Kanal 10 = Drum-Spur" — alte Presets sehen aus wie zuvor.
        self.isDrum       = try c.decodeIfPresent(Bool.self, forKey: .isDrum) ?? (channel == 10)
        self.isCollapsed  = (try? c.decodeIfPresent(Bool.self, forKey: .isCollapsed)) ?? false
        if let r = try c.decodeIfPresent(UUID.self, forKey: .row) { self.row = r; self.rowFromFile = true }
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
