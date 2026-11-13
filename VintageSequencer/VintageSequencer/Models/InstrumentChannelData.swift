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
    var instrument: PluginRef?
    var effects:    [PluginRef] = []
    /// Linearer Gain 0 … +6 dB (≈ 1,995; bis v1.13.4: 0 … 1)
    var volume:     Float = 0.8
    /// −1 (links) … +1 (rechts)
    var pan:        Float = 0
    var isMuted:    Bool = false
    var isSoloed:   Bool = false

    init(name: String) { self.name = name }

    // Eigener Decoder: später hinzugekommene Felder (isSoloed, v1.13.1) sind optional.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id         = try c.decode(UUID.self, forKey: .id)
        name       = try c.decode(String.self, forKey: .name)
        instrument = try c.decodeIfPresent(PluginRef.self, forKey: .instrument)
        effects    = try c.decodeIfPresent([PluginRef].self, forKey: .effects) ?? []
        volume     = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 0.8
        pan        = try c.decodeIfPresent(Float.self, forKey: .pan) ?? 0
        isMuted    = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        isSoloed   = try c.decodeIfPresent(Bool.self, forKey: .isSoloed) ?? false
    }

    mutating func clampToValidRanges() {
        volume = max(0, min(InstrumentRack.maxGain, volume))
        pan    = max(-1, min(1, pan))
    }
}
