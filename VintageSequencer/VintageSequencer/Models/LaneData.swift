import Foundation
import Combine

// MARK: - LaneData
//
// Sequenzkern — trägt alles, was die Step-Abfolge eines Tracks beschreibt.
// Gehört per 1:1-Beziehung zu genau einer TrackData (siehe ENGINEERING.md —
// Lane-Modell v1). Plain class mit `var`-Feldern, NICHT ObservableObject.
//
// Mutationen müssen von `changed.send()` gefolgt werden. Für undo-fähige,
// interaktionsgetriebene Mutationen ist ModelWriter der kanonische Pfad;
// Direktpfade (MIDI-Learn, Randomize, Paste) rufen `send()` manuell auf.
//
// CC-Lane Slice 1 (v1.8.0): LaneData trägt zusätzlich zu den Step-Feldern
// nun auch CC-Lane-Payload-Felder (`ccValues`, `ccNumber`, `ccLabel`,
// `ccIsMuted`). Welche Felder semantisch relevant sind, entscheidet
// `kind`. Das ist eine **pragmatische Übergangsform** für Slice 1 —
// ausdrücklich nicht das endgültige Zielmodell. Ein späterer Slice
// migriert die Payload in eine Enum-assoziierte Struktur.
final class LaneData: Identifiable {

    /// Fires synchronously on the Main Thread after any sequence-field mutation.
    /// TrackViewModel subscribes and forwards to its `objectWillChange`.
    let changed = PassthroughSubject<Void, Never>()

    /// Stable UUID — serialized and restored.
    let id: UUID

    /// Expliziter Lane-Typ-Diskriminator (Lane Slice 3).
    /// Pflichtfeld in JSON.
    let kind: LaneKind

    // MARK: - Shared Sequenz-Felder (beide Lane-Typen)

    var stepCount: Int = 16 {
        didSet {
            while steps.count    < stepCount { steps.append(Step()) }
            while ccValues.count < stepCount { ccValues.append(64) }
        }
    }
    var direction: PlayDirection = .forward
    /// Step length as a ratio of a 16th note: numerator / denominator.
    var stepLengthNumerator:   Int = 1
    var stepLengthDenominator: Int = 1
    /// RND-Töne dieser Spur (v1.18.29, vorher je Spurart): nil = Einzeltöne. Optionaler
    /// Schlüssel `rnd`. Frühere Pad-Spuren laden mit Akkorden.
    var rndMode: RandomNoteMode? = nil
    /// Fester Ton (v1.13.16) bzw. fester Akkord (v1.16.2): gesetzt spielen alle Steps diese
    /// Noten statt ihrer eigenen (z. B. eine Kick oder ein Akkord über die ganze Spur). Die
    /// Noten der Steps bleiben erhalten. `nil` = aus; sonst nicht leer, sortiert.
    /// Format: ein Ton als `fixedNote` (Int, wie bisher), mehrere als `fixedNotes` ([Int]).
    var fixedNotes: [Int]? = nil

    /// Länge eines Steps in Sechzehnteln (Gate-Anzeige, v1.17.1).
    var stepSixteenths: Double {
        Double(max(1, stepLengthNumerator)) / Double(max(1, stepLengthDenominator))
    }
    /// Erlaubte Steplängen jeder Lane, aufsteigend (v1.18.29): die Verhältnisse 1/2…2/1 einer
    /// Sechzehntel und die musikalischen Längen in der Taktart des Patterns (Schläge, Takte).
    func ratioOptions(_ meter: TimeSignature) -> [(num: Int, den: Int)] {
        TrackData.stepRatios(meter)
    }
    /// Lange Steps (v1.18.29, vorher nur Pad-Spuren): länger als eine Achtel, ganze Sechzehntel.
    /// Im Raster in eigener Breite (`stepWidth`) statt zeitgetreu; ein Taktartwechsel rechnet
    /// sie um (ganze Takte/Schläge bleiben ganze).
    var isLongStep: Bool { stepGroup || stepSixteenths > 2 }
    /// Steplänge „Gruppe" (v1.18.30, Konzept §10 L5): Step k dauert Gruppe k mod n der
    /// Gruppierung des Patterns (7/8 als 3+4: abwechselnd 3/8 und 4/8). Ohne Gruppierung ein
    /// Takt. `stepLengthNumerator/Denominator` tragen dann die erste Gruppe — so spielen
    /// ältere Versionen gleich lange Steps dieser Länge. Optionaler Schlüssel `stepGroup`.
    var stepGroup: Bool = false
    /// Gruppen dieser Spur in Achteln (v1.18.31, Stephan: „sollten die Gruppierungen nicht je
    /// Track gelten?"): z. B. 3+4 in 7/8 oder 3+3+2 in 4/4. Die Summe muss keinen Takt ergeben
    /// (dann läuft die Spur gegen den Takt). nil = Vorgabe aus der Taktart des Patterns.
    /// Optionaler Schlüssel `groups` („3+4").
    var groups: [Int]? = nil
    static let groupRange = 1...64
    static func isValidGroups(_ g: [Int]) -> Bool {
        (1...TimeSignature.maxGroups).contains(g.count) && g.allSatisfy { groupRange.contains($0) }
    }
    /// Vorgabe aus der Taktart: ihre Gruppierung in Achteln, sonst ein Takt.
    static func defaultGroups(_ meter: TimeSignature) -> [Int] {
        if let g = meter.grouping, meter.denominator <= 8 { return g.map { $0 * (8 / meter.denominator) } }
        return [max(1, meter.sixteenthsPerBar / 2)]
    }
    /// Gruppen in Achteln, wie sie gelten.
    func effectiveGroups(_ meter: TimeSignature) -> [Int] { groups ?? Self.defaultGroups(meter) }
    /// Gruppen in Sechzehnteln.
    func groupSixteenths(_ meter: TimeSignature) -> [Int] { effectiveGroups(meter).map { $0 * 2 } }
    /// Länge von Step `k` in Sechzehnteln in der Taktart `meter`.
    func sixteenths(ofStep k: Int, meter: TimeSignature) -> Double {
        guard stepGroup else { return stepSixteenths }
        let g = groupSixteenths(meter)
        return Double(g[((k % g.count) + g.count) % g.count])
    }

    /// Ganze Längenangabe einer Spur (Befehl `setLength`, v1.18.31).
    struct LengthState: Equatable {
        var num: Int, den: Int, group: Bool, groups: [Int]?
    }
    var lengthState: LengthState {
        get { LengthState(num: stepLengthNumerator, den: stepLengthDenominator, group: stepGroup, groups: groups) }
        set {
            stepLengthNumerator = max(1, newValue.num); stepLengthDenominator = max(1, newValue.den)
            stepGroup = newValue.group; groups = newValue.groups
        }
    }
    /// Breite langer Steps in Normal-Stepbreiten (1…8), 0 = automatisch nach Länge
    /// (`autoWidth`). Schlüssel `width` (bis v1.18.28 `padWidth`, nur bei Pads).
    var stepWidth: Int = 0
    static let stepWidthRange = 0...8
    /// Automatische Breite: bis zwei Schläge 1, bis ein Takt 4/4 2, länger 3.
    var autoWidth: Int { stepSixteenths <= 8 ? 1 : stepSixteenths <= 16 ? 2 : 3 }
    var effectiveStepWidth: Int { stepWidth == 0 ? autoWidth : stepWidth }

    /// Verhältnis für die Rasterbreite: lange Steps in eigener Breite, sonst zeitgetreu.
    var displayNumerator:   Int { isLongStep ? effectiveStepWidth : stepLengthNumerator }
    var displayDenominator: Int { isLongStep ? 1 : stepLengthDenominator }

    // MARK: - Step-Lane Payload (semantisch nur bei kind == .step)

    var steps: [Step]

    // MARK: - CC-Lane Payload (semantisch nur bei kind == .cc)

    /// Pro-Step CC-Werte (0…127). Größe analog zu `steps` (64).
    var ccValues: [Int]
    /// CC-Controller-Nummer (0…127), die diese Lane sendet.
    var ccNumber: Int = 74
    /// UI-Label, nur für Anzeige — nicht im RT-Snapshot.
    var ccLabel:  String = "CC1"
    /// Mute-Zustand der CC-Lane.
    var ccIsMuted: Bool = false
    /// Ziel im gehosteten Instrument (v1.13.9): gesetzt steuert die Lane diesen Parameter
    /// statt MIDI-CC `ccNumber` — nur solange die Spur auf einen Instrumentenkanal geht.
    var ccParameter: ParameterRef? = nil

    // MARK: - Init

    init(stepCount: Int = 16, id: UUID = UUID(), kind: LaneKind = .step) {
        self.id        = id
        self.kind      = kind
        self.stepCount = stepCount
        switch kind {
        case .step:
            self.steps    = (0..<64).map { _ in Step() }
            self.ccValues = []
        case .cc:
            self.steps    = []
            self.ccValues = Array(repeating: 64, count: 64)
        }
    }
}

// MARK: - Codable
//
// CC-Lane Slice 1: kind-abhängige Serialisierung — strict decode, kein
// Legacy-Fallback, kein decodeIfPresent. Preset-Bruch beim Laden alter
// Lanes OHNE kind-Feld bleibt bestehen (Slice 3-Entscheidung).

extension LaneData: Codable {
    enum CodingKeys: String, CodingKey {
        case id, kind, stepCount, direction
        case stepLengthNumerator, stepLengthDenominator
        case legacyPad = "pad"          // bis v1.18.28, nur gelesen
        case padWidth                   // bis v1.18.28, nur gelesen
        case stepWidth = "width"
        case stepGroup
        case groups
        case rndMode = "rnd"
        case fixedNote, fixedNotes
        // step payload
        case steps
        // cc payload
        case ccValues, ccNumber, ccLabel, ccIsMuted, ccParameter
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,                             forKey: .id)
        try c.encode(kind,                           forKey: .kind)
        try c.encode(stepCount,                      forKey: .stepCount)
        try c.encode(direction,                      forKey: .direction)
        try c.encode(stepLengthNumerator,            forKey: .stepLengthNumerator)
        try c.encode(stepLengthDenominator,          forKey: .stepLengthDenominator)
        if stepWidth != 0 { try c.encode(stepWidth, forKey: .stepWidth) }
        if stepGroup { try c.encode(true, forKey: .stepGroup) }
        try c.encodeIfPresent(groups.map(TimeSignature.groupingText), forKey: .groups)
        switch kind {
        case .step:
            try c.encode(Array(steps.prefix(stepCount)), forKey: .steps)
            try c.encodeIfPresent(rndMode?.rawValue, forKey: .rndMode)
            if let f = fixedNotes, !f.isEmpty {
                if f.count == 1 { try c.encode(f[0], forKey: .fixedNote) }   // lesbar für ältere Versionen
                else { try c.encode(f, forKey: .fixedNotes) }
            }
        case .cc:
            try c.encode(Array(ccValues.prefix(stepCount)), forKey: .ccValues)
            try c.encode(ccNumber,  forKey: .ccNumber)
            try c.encode(ccLabel,   forKey: .ccLabel)
            try c.encode(ccIsMuted, forKey: .ccIsMuted)
            try c.encodeIfPresent(ccParameter, forKey: .ccParameter)
        }
    }

    convenience init(from decoder: Decoder) throws {
        let c         = try decoder.container(keyedBy: CodingKeys.self)
        let id        = try c.decode(UUID.self,     forKey: .id)
        // `kind` ist ab v1.5.0 Pflichtfeld — kein Legacy-Fallback.
        let kind      = try c.decode(LaneKind.self, forKey: .kind)
        let stepCount = try c.decode(Int.self,      forKey: .stepCount)
        self.init(stepCount: stepCount, id: id, kind: kind)
        self.direction             = try c.decode(PlayDirection.self, forKey: .direction)
        self.stepLengthNumerator   = try c.decode(Int.self, forKey: .stepLengthNumerator)
        self.stepLengthDenominator = try c.decode(Int.self, forKey: .stepLengthDenominator)
        self.stepGroup = ((try? c.decodeIfPresent(Bool.self, forKey: .stepGroup)) ?? nil) ?? false
        self.groups = ((try? c.decodeIfPresent(String.self, forKey: .groups)) ?? nil)
            .flatMap(TimeSignature.parseGrouping).flatMap { Self.isValidGroups($0) ? $0 : nil }
        // Frühere Pad-Spur (bis v1.18.28): normale Spur mit langen Steps, Breite, Akkorde.
        let wasPad = (try? c.decodeIfPresent(Bool.self, forKey: .legacyPad)) ?? false
        self.stepWidth = ((try? c.decodeIfPresent(Int.self, forKey: .stepWidth)) ?? nil)
            ?? (wasPad ? ((try? c.decodeIfPresent(Int.self, forKey: .padWidth)) ?? nil) ?? 1 : 0)
        switch kind {
        case .step:
            var decoded = try c.decode([Step].self, forKey: .steps)
            while decoded.count < 64 { decoded.append(Step()) }
            self.steps = decoded
            let rnd = ((try? c.decodeIfPresent(String.self, forKey: .rndMode)) ?? nil).flatMap(RandomNoteMode.init(rawValue:))
            self.rndMode = rnd ?? (wasPad ? .chords : nil)
            let chord  = (try? c.decodeIfPresent([Int].self, forKey: .fixedNotes)) ?? nil
            let single = (try? c.decodeIfPresent(Int.self, forKey: .fixedNote)) ?? nil
            self.fixedNotes = chord ?? single.map { [$0] }
        case .cc:
            var decoded = try c.decode([Int].self, forKey: .ccValues)
            while decoded.count < 64 { decoded.append(64) }
            self.ccValues  = decoded
            self.ccNumber  = try c.decode(Int.self,    forKey: .ccNumber)
            self.ccLabel   = try c.decode(String.self, forKey: .ccLabel)
            self.ccIsMuted = try c.decode(Bool.self,   forKey: .ccIsMuted)
            self.ccParameter = try c.decodeIfPresent(ParameterRef.self, forKey: .ccParameter)
        }
    }
}

// MARK: - Validation

extension LaneData {

    /// Noten geklemmt, ohne Doppelte, aufsteigend; leer → nil.
    static func normalizedNotes(_ notes: [Int]) -> [Int]? {
        let n = Array(Set(notes.map { max(0, min(127, $0)) })).sorted()
        return n.isEmpty ? nil : n
    }

    /// Clamps sequence-field values to their valid ranges.
    /// Called after preset decode. Does NOT call `changed.send()` — load path
    /// ends with an explicit `hasUnsavedChanges = false`.
    func clampToValidRanges() {
        stepCount             = max(1, min(64, stepCount))
        stepLengthNumerator   = max(1, stepLengthNumerator)
        stepLengthDenominator = max(1, stepLengthDenominator)
        if kind != .step { rndMode = nil; fixedNotes = nil }
        fixedNotes = fixedNotes.flatMap { Self.normalizedNotes($0) }
        stepWidth = max(Self.stepWidthRange.lowerBound, min(Self.stepWidthRange.upperBound, stepWidth))
        // Lange Steps: höchstens 8 Takte 16/16 (die Auswahl hängt von der Taktart ab,
        // gespeicherte Längen bleiben gültig).
        if stepLengthDenominator == 1 { stepLengthNumerator = min(TrackData.maxLongSixteenths, stepLengthNumerator) }

        switch kind {
        case .step:
            for i in steps.indices {
                steps[i].velocity    = max(1,     min(127, steps[i].velocity))
                steps[i].gate        = max(0.001, min(8.0, steps[i].gate))
                steps[i].probability = max(0.0,   min(1.0, steps[i].probability))
                steps[i].notes       = steps[i].notes.map { max(0, min(127, $0)) }
                if steps[i].notes.isEmpty { steps[i].notes = [60] }
            }
        case .cc:
            ccNumber = max(0, min(127, ccNumber))
            for i in ccValues.indices {
                ccValues[i] = max(0, min(127, ccValues[i]))
            }
        }
    }
}

// MARK: - ParameterRef

/// Verweis auf einen Parameter eines gehosteten Instruments. Identität ist die Adresse;
/// `name` ist Anzeige und bleibt lesbar, wenn das Plug-in fehlt.
struct ParameterRef: Codable, Equatable {
    var address: UInt64
    var name:    String
    /// Plug-in, zu dem die Adresse gehört (`PluginRef.componentKey`, v1.13.13). Ein anderes
    /// Instrument auf dem Kanal löst das Ziel nicht auf — dieselbe Adresse kann dort etwas
    /// anderes bedeuten. nil (Dateien aus v1.13.9 … v1.13.12): an kein Plug-in gebunden.
    var component: String? = nil
    /// Effekt statt Instrument (v1.17.1): laufende Nummer unter den Effekten mit derselben
    /// Kennung `component` in der Kette des Kanals (0 = erster). nil = Instrument. Ältere
    /// Versionen ignorieren den Schlüssel; das Ziel löst dort nicht auf (anderes Plug-in).
    var effect: Int? = nil
    /// Effekt-Instanz (v1.17.8, Codex A17-04): eindeutiges Ziel, unabhängig von Reihenfolge.
    /// Gesetzt, wird nur diese Instanz aufgelöst — entfernt man sie, bleibt das Ziel offen
    /// (kein Verrutschen auf einen gleichen Effekt). `effect` wird für ältere Versionen
    /// weiter geschrieben; Ziele ohne Instanz ordnet das Laden einmal über `effect` zu.
    var effectInstance: UUID? = nil
}
