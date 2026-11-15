import Foundation

// MARK: - TrackOutput (v1.16.0, Codex M4)
//
// Was eine Spur spielt und wohin — als ein Fall statt als Kombination aus optionaler
// Kanal-ID und Bool. Ungültige Kombinationen (Loop-Spur ohne Kanal, Loop-Spur auf MIDI,
// Notenspur auf einem Loop-Kanal) sind damit nicht darstellbar bzw. werden beim Auflösen
// der Route (`InstrumentRack.route(for:)`) nach Quelle des Kanals geprüft.
//
// Presetformat: Pflichtschlüssel `output` — `{"midi":{}}`, `{"instrument":"<uuid>"}`,
// `{"audioLoop":"<uuid>"}`. Presets vor v1.16.0 laden nicht.
enum TrackOutput: Equatable, Sendable {
    /// Externe MIDI-Ausgabe (CoreMIDI).
    case midi
    /// Noten-/CC-Spur auf einem Instrumentenkanal des Racks. Zeigt die ID auf keinen
    /// Instrumentenkanal (mehr), gilt externe MIDI-Ausgabe.
    case instrument(UUID)
    /// Audio-Loop-Spur: spielt den Loop dieses Kanals statt Steps. Fest an den Kanal gebunden.
    case audioLoop(UUID)

    /// Kanal, auf den die Spur zeigt (nil = MIDI).
    var channelID: UUID? {
        switch self {
        case .midi:                                 return nil
        case .instrument(let id), .audioLoop(let id): return id
        }
    }
    var isAudioLoop: Bool { if case .audioLoop = self { return true } else { return false } }
}

extension TrackOutput: Codable {
    private enum CodingKeys: String, CodingKey { case midi, instrument, audioLoop }
    private struct Empty: Codable {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.allKeys.count == 1, let key = c.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath,
                                                    debugDescription: "output: genau ein Fall erwartet"))
        }
        switch key {
        case .midi:       self = .midi
        case .instrument: self = .instrument(try c.decode(UUID.self, forKey: .instrument))
        case .audioLoop:  self = .audioLoop(try c.decode(UUID.self, forKey: .audioLoop))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .midi:                try c.encode(Empty(), forKey: .midi)
        case .instrument(let id):  try c.encode(id, forKey: .instrument)
        case .audioLoop(let id):   try c.encode(id, forKey: .audioLoop)
        }
    }
}

// MARK: - ChannelSource (v1.16.0, Codex M4)

/// Quelle eines Rack-Kanals — genau eine: ein AU-Instrument (noch keins gewählt = nil) oder
/// der Loop-Spieler. Presetformat: Pflichtschlüssel `source` —
/// `{"instrument":{…}}` / `{"instrument":{}}` (leer) bzw. `{"audioLoop":{…}}`.
enum ChannelSource: Equatable {
    case instrument(PluginRef?)
    case audioLoop(AudioLoopSettings)

    var isAudioLoop: Bool { if case .audioLoop = self { return true } else { return false } }
}

extension ChannelSource: Codable {
    private enum CodingKeys: String, CodingKey { case instrument, audioLoop }
    private struct Empty: Codable {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.allKeys.count == 1, let key = c.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath,
                                                    debugDescription: "source: genau ein Fall erwartet"))
        }
        switch key {
        case .instrument:
            // Leeres Objekt = noch kein Instrument gewählt.
            if (try? c.decode(Empty.self, forKey: .instrument)) != nil,
               (try? c.decode(PluginRef.self, forKey: .instrument)) == nil {
                self = .instrument(nil)
            } else {
                self = .instrument(try c.decode(PluginRef.self, forKey: .instrument))
            }
        case .audioLoop:
            self = .audioLoop(try c.decode(AudioLoopSettings.self, forKey: .audioLoop))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .instrument(let ref?): try c.encode(ref, forKey: .instrument)
        case .instrument(nil):      try c.encode(Empty(), forKey: .instrument)
        case .audioLoop(let s):     try c.encode(s, forKey: .audioLoop)
        }
    }
}
