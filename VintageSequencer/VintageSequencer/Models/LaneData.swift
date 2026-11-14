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
    /// Pad-Lane (v1.13.16): lange Steps (Viertel bis 8 Takte) für Flächen und Drones.
    /// Steplänge kommt aus `TrackData.padRatios`; im Raster kompakt dargestellt (ein Step
    /// = eine Standardbreite) statt zeitgetreu. Nur bei `kind == .step` sinnvoll.
    var isPad: Bool = false
    /// Fester Ton (v1.13.16): gesetzt spielen alle Steps diese Note statt ihrer eigenen
    /// (z. B. eine Kick über die ganze Spur). Die Noten der Steps bleiben erhalten.
    var fixedNote: Int? = nil

    /// Erlaubte Steplängen dieser Lane, aufsteigend.
    var ratioOptions: [(num: Int, den: Int)] { isPad ? TrackData.padRatios : TrackData.sortedRatios }
    /// Verhältnis für die Rasterbreite: Pad-Lanes kompakt (1/1), sonst zeitgetreu.
    var displayNumerator:   Int { isPad ? 1 : stepLengthNumerator }
    var displayDenominator: Int { isPad ? 1 : stepLengthDenominator }

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
        case isPad = "pad"
        case fixedNote
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
        switch kind {
        case .step:
            try c.encode(Array(steps.prefix(stepCount)), forKey: .steps)
            if isPad { try c.encode(true, forKey: .isPad) }   // optional, nur wenn gesetzt
            try c.encodeIfPresent(fixedNote, forKey: .fixedNote)
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
        switch kind {
        case .step:
            var decoded = try c.decode([Step].self, forKey: .steps)
            while decoded.count < 64 { decoded.append(Step()) }
            self.steps = decoded
            self.isPad = (try? c.decodeIfPresent(Bool.self, forKey: .isPad)) ?? false
            self.fixedNote = (try? c.decodeIfPresent(Int.self, forKey: .fixedNote)) ?? nil
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

    /// Clamps sequence-field values to their valid ranges.
    /// Called after preset decode. Does NOT call `changed.send()` — load path
    /// ends with an explicit `hasUnsavedChanges = false`.
    func clampToValidRanges() {
        stepCount             = max(1, min(64, stepCount))
        stepLengthNumerator   = max(1, stepLengthNumerator)
        stepLengthDenominator = max(1, stepLengthDenominator)
        if kind != .step { isPad = false; fixedNote = nil }
        fixedNote = fixedNote.map { max(0, min(127, $0)) }
        if isPad, !TrackData.padRatios.contains(where: {
            $0.num == stepLengthNumerator && $0.den == stepLengthDenominator
        }) {
            stepLengthNumerator = 16; stepLengthDenominator = 1   // unbekannte Länge → 1 Takt
        }

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
}
