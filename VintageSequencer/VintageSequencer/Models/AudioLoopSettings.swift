import Foundation

// MARK: - Audio-Loop (v1.15.0)
//
// Einstellungen eines Audio-Loop-Kanals. Das Material selbst (`AudioLoopStorage`) gehört dem
// Rack und wird separat gespeichert (Preset-Schlüssel `audioLoops`); hier stehen nur kleine,
// vergleichbare Werte — `InstrumentChannelData` wird bei jeder Mixer-Änderung verglichen.

/// Wo das Gate im Kanal sitzt.
enum GatePosition: String, Codable, CaseIterable, Sendable {
    /// Aus.
    case off
    /// Am Eingang: vor Mithören und Aufnahme — Störgeräusche landen gar nicht erst im Loop.
    case input
    /// Nach den Effekten, vor dem Fader.
    case preFader
    /// Nach dem Fader, vor Panorama/Summe.
    case postFader
}

struct GateSettings: Codable, Equatable, Sendable {
    var position:    GatePosition = .off
    /// Schwelle in dBFS.
    var thresholdDB: Float = -50
    /// Ausklingzeit in ms.
    var releaseMs:   Float = 150
    /// Haltezeit nach dem Unterschreiten der Schwelle in ms.
    var holdMs:      Float = 40

    static let thresholdRange: ClosedRange<Float> = -80...0
    static let releaseRange:   ClosedRange<Float> = 10...2000
    static let holdRange:      ClosedRange<Float> = 0...500

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        position    = try c.decodeIfPresent(GatePosition.self, forKey: .position) ?? .off
        thresholdDB = try c.decodeIfPresent(Float.self, forKey: .thresholdDB) ?? -50
        releaseMs   = try c.decodeIfPresent(Float.self, forKey: .releaseMs) ?? 150
        holdMs      = try c.decodeIfPresent(Float.self, forKey: .holdMs) ?? 40
    }

    mutating func clamp() {
        thresholdDB = min(max(thresholdDB, Self.thresholdRange.lowerBound), Self.thresholdRange.upperBound)
        releaseMs   = min(max(releaseMs, Self.releaseRange.lowerBound), Self.releaseRange.upperBound)
        holdMs      = min(max(holdMs, Self.holdRange.lowerBound), Self.holdRange.upperBound)
    }
}

struct AudioLoopSettings: Codable, Equatable, Sendable {
    /// Loop-Länge in Takten (4/4). Nur änderbar, solange der Loop leer ist.
    var bars:            Int = 4
    /// Erster Eingangskanal des Audiogeräts (0-basiert).
    var inputChannel:    Int = 0
    /// Stereo: Eingangskanäle `inputChannel` und `inputChannel + 1`; sonst Mono auf beide Seiten.
    var stereo:          Bool = false
    /// Eingang mithören (über den Kanalzug).
    var monitor:         Bool = false
    /// Zusätzlicher Latenzausgleich der Aufnahme in ms (+ = Aufnahme früher einordnen).
    var latencyOffsetMs: Float = 0
    var gate = GateSettings()

    static let barOptions = [1, 2, 4, 8, 16]
    static let latencyRange: ClosedRange<Float> = -100...200
    /// Obergrenze der Loop-Dauer. Speicher: Stereo-Float + Undo-Kopie = 4 Kanäle × 4 Byte je
    /// Frame, bei 48 kHz und 120 s ≈ 92 MB je Loop.
    static let maxSeconds: Double = 120
    /// Obergrenze des gesamten Loop-PCM eines Projekts (inkl. Undo-Kopien). Darüber wird
    /// kein neuer Loop-Speicher angelegt bzw. geladen, sondern ein Fehler gemeldet.
    static let maxProjectBytes = 1 << 30

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bars            = try c.decodeIfPresent(Int.self, forKey: .bars) ?? 4
        inputChannel    = try c.decodeIfPresent(Int.self, forKey: .inputChannel) ?? 0
        stereo          = try c.decodeIfPresent(Bool.self, forKey: .stereo) ?? false
        monitor         = try c.decodeIfPresent(Bool.self, forKey: .monitor) ?? false
        latencyOffsetMs = try c.decodeIfPresent(Float.self, forKey: .latencyOffsetMs) ?? 0
        gate            = try c.decodeIfPresent(GateSettings.self, forKey: .gate) ?? GateSettings()
    }

    mutating func clamp() {
        if !Self.barOptions.contains(bars) { bars = 4 }
        inputChannel    = max(0, min(63, inputChannel))
        latencyOffsetMs = min(max(latencyOffsetMs, Self.latencyRange.lowerBound), Self.latencyRange.upperBound)
        gate.clamp()
    }
}
