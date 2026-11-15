import Foundation
import AudioToolbox

// MARK: - PluginRef

/// Verweis auf ein Audio-Unit samt gespeichertem Klangzustand.
///
/// Identität ist das Tripel aus Typ, Subtyp und Hersteller. `name` ist nur Anzeige — er
/// bleibt lesbar, wenn das Plug-in auf diesem Rechner fehlt. `state` ist der vollständige
/// AU-Zustand (`fullState`) als binäre Property-List; er wird auch dann unverändert
/// weitergespeichert, wenn das Plug-in nicht geladen werden konnte.
struct PluginRef: Codable, Equatable {
    var type:         UInt32
    var subType:      UInt32
    var manufacturer: UInt32
    var name:         String
    var state:        Data?
    /// Effekt überbrückt (v1.13.1) bzw. Instrument ausgeschaltet (v1.13.5).
    var bypassed:     Bool = false
    /// Instanz eines Effekts in der Kette (v1.17.8, Codex A17-04): bleibt beim Umordnen gleich,
    /// CC-Ziele verweisen darauf. Optionaler Schlüssel `instance`; fehlt er (ältere Dateien),
    /// vergibt das Rack beim Laden eine neue. Instrumente tragen keine.
    var instance:     UUID? = nil
    /// Drum-Gruppen eines Apple-Sampler-Instruments aus EXS (v1.18.28): Sperrgruppe und
    /// One-Shot je Taste. Optionaler Schlüssel `drumMap`; fehlt er, wirkt nichts davon.
    var drumMap:      DrumMap? = nil

    var componentDescription: AudioComponentDescription {
        AudioComponentDescription(componentType: type, componentSubType: subType,
                                  componentManufacturer: manufacturer,
                                  componentFlags: 0, componentFlagsMask: 0)
    }

    init(description d: AudioComponentDescription, name: String, state: Data? = nil) {
        type = d.componentType; subType = d.componentSubType
        manufacturer = d.componentManufacturer
        self.name = name; self.state = state
    }

    // Eigener Decoder: später hinzugekommene Felder sind optional, damit ältere Projekte laden.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type         = try c.decode(UInt32.self, forKey: .type)
        subType      = try c.decode(UInt32.self, forKey: .subType)
        manufacturer = try c.decode(UInt32.self, forKey: .manufacturer)
        name         = try c.decode(String.self, forKey: .name)
        state        = try c.decodeIfPresent(Data.self, forKey: .state)
        bypassed     = try c.decodeIfPresent(Bool.self, forKey: .bypassed) ?? false
        instance     = try? c.decodeIfPresent(UUID.self, forKey: .instance)
        drumMap      = try? c.decodeIfPresent(DrumMap.self, forKey: .drumMap)
    }

    /// Kennung des Plug-ins als Text (Typ-Subtyp-Hersteller), z. B. für Parameterbindungen.
    var componentKey: String { "\(type)-\(subType)-\(manufacturer)" }

    /// Gleiches Plug-in (ohne Blick auf den Zustand)?
    func isSameComponent(as other: PluginRef) -> Bool {
        type == other.type && subType == other.subType && manufacturer == other.manufacturer
    }
}

// MARK: - InstrumentChannelData

/// Ein Instrumentenkanal des Projekts: ein AU-Instrument, eine geordnete Kette von
/// AU-Effekten, Pegel und Panorama. Spuren verweisen per `TrackData.instrumentID` auf
/// einen Kanal; mehrere Spuren dürfen denselben Kanal spielen.
struct InstrumentChannelData: Codable, Identifiable, Equatable {
    var id:         UUID = UUID()
    var name:       String
    /// Genau eine Quelle (v1.16.0, Codex M4): AU-Instrument oder Loop-Spieler.
    var source:     ChannelSource = .instrument(nil)
    var effects:    [PluginRef] = []
    /// Linearer Gain 0 … +6 dB (≈ 1,995; bis v1.13.4: 0 … 1)
    var volume:     Float = 0.8
    /// −1 (links) … +1 (rechts)
    var pan:        Float = 0
    var isMuted:    Bool = false
    var isSoloed:   Bool = false
    /// Abtastrate, mit der das Instrument rendert (v1.18.9); nil = Rate des Ausgabegeräts.
    /// Ein Sampler, der selbst nur grob umrechnet, rendert so auf der Rate seiner Samples —
    /// die Engine rechnet hochwertig auf die Geräterate um. Optionaler Schlüssel `renderRate`.
    var renderRate: Double? = nil
    static let renderRates: [Double] = [44_100, 48_000, 88_200, 96_000]
    /// Kanal-EQ (v1.18.11). Optionaler Schlüssel `eq`, nur geschrieben, wenn er von der
    /// Grundeinstellung abweicht; ältere Projekte laden mit neutralem EQ.
    var eq = ChannelEQ()

    init(name: String, source: ChannelSource = .instrument(nil)) {
        self.name = name; self.source = source
    }

    /// Instrument eines Instrumentenkanals (nil bei Loop-Kanälen). Setzen wirkt nur auf
    /// Instrumentenkanälen — ein Loop-Kanal bekommt kein Instrument.
    var instrument: PluginRef? {
        get { if case .instrument(let r) = source { return r } else { return nil } }
        set { if case .instrument = source { source = .instrument(newValue) } }
    }
    /// Einstellungen eines Audio-Loop-Kanals (nil bei Instrumentenkanälen). Setzen wirkt nur
    /// auf Loop-Kanälen; die Quelle wechselt nie über diesen Weg.
    var audioLoop: AudioLoopSettings? {
        get { if case .audioLoop(let s) = source { return s } else { return nil } }
        set { if case .audioLoop = source, let s = newValue { source = .audioLoop(s) } }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, source, effects, volume, pan, isMuted, isSoloed, renderRate, eq
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name)
        try c.encode(source, forKey: .source); try c.encode(effects, forKey: .effects)
        try c.encode(volume, forKey: .volume); try c.encode(pan, forKey: .pan)
        try c.encode(isMuted, forKey: .isMuted); try c.encode(isSoloed, forKey: .isSoloed)
        try c.encodeIfPresent(renderRate, forKey: .renderRate)
        if eq != ChannelEQ() { try c.encode(eq, forKey: .eq) }
    }

    // `source` ist ab v1.16.0 Pflicht (ältere Presets laden nicht); die übrigen später
    // hinzugekommenen Felder bleiben optional.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id         = try c.decode(UUID.self, forKey: .id)
        name       = try c.decode(String.self, forKey: .name)
        source     = try c.decode(ChannelSource.self, forKey: .source)
        effects    = try c.decodeIfPresent([PluginRef].self, forKey: .effects) ?? []
        volume     = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 0.8
        pan        = try c.decodeIfPresent(Float.self, forKey: .pan) ?? 0
        isMuted    = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        isSoloed   = try c.decodeIfPresent(Bool.self, forKey: .isSoloed) ?? false
        renderRate = try? c.decodeIfPresent(Double.self, forKey: .renderRate)
        eq         = (try? c.decodeIfPresent(ChannelEQ.self, forKey: .eq)) ?? ChannelEQ()
    }

    mutating func clampToValidRanges() {
        volume = max(0, min(InstrumentRack.maxGain, volume))
        pan    = max(-1, min(1, pan))
        if let r = renderRate, !Self.renderRates.contains(r) { renderRate = nil }
        eq.clamp()
        if case .audioLoop(var s) = source { s.clamp(); source = .audioLoop(s) }
    }
}
