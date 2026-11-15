import Foundation

// MARK: - Drum-Gruppen (v1.18.28)
//
// Stephan: „bei den exs- Dateien fehlt die "Interaktion" zwischen HH closed/ped und open".
// Gemessen: Der AUSampler übernimmt beim EXS-Import weder die Exclusive-Gruppe einer Gruppe noch
// One-Shot der Zonen — das offene Becken klingt mit dem Ausklang der Hüllkurve (Jazz Brush Kit:
// 0,89 s) weiter. FoF liest beides selbst aus der EXS-Datei:
//   - Sperrgruppe: eine Note der Gruppe beendet alle klingenden Noten der Gruppe (auch dieselbe
//     Taste). Umsetzung im Render-Durchlauf des Kanals (`AUEventQueue`): vor dem Note-On gehen
//     Note-Offs an alle Tasten der Gruppe, gleicher Sample-Offset.
//   - One-Shot: Note-Offs aus dem Sequencer erreichen diese Tasten nicht, das Sample klingt aus.
//   - Damit das Note-Off der Sperrgruppe hörbar abschneidet, bekommt die Lautstärke-Hüllkurve
//     (Hüllkurve 0) der Layer, deren Tasten alle in einer Sperrgruppe und One-Shot sind, 10 ms
//     Ausklang (gemessen: vorher 0,89 s Nachklang, danach < 100 ms still). Andere Wege zum
//     Ausklang gibt es für diese Layer nicht mehr (Note-Offs kommen nur noch von der Gruppe
//     oder als „alle Noten aus").
//
// EXS-Format (little-endian, „TBOS"): Blöcke mit 84 Byte Kopf (Signatur, Größe, Kennung, …,
// Name 64 Byte). Typ = Bits 24…27 der Signatur: 1 Zone, 2 Gruppe. Zone: Optionen (Bit 0 One-Shot)
// an 0, Tastenbereich an 6/7, Gruppenindex (Int32) an 88. Gruppe: Exclusive-Nummer an 4
// (0 = keine). Gruppenindex = Reihenfolge der Gruppen-Blöcke.

struct DrumMap: Codable, Equatable {
    /// Je MIDI-Taste: Bits 0…6 Sperrgruppe (0 = keine), Bit 7 One-Shot.
    private(set) var keys: [UInt8]

    static let oneShotBit: UInt8 = 0x80

    init(keys: [UInt8]) {
        var k = Array(keys.prefix(128))
        if k.count < 128 { k += Array(repeating: 0, count: 128 - k.count) }
        self.keys = k
    }

    func group(_ key: Int) -> UInt8 { keys[key] & 0x7F }
    func isOneShot(_ key: Int) -> Bool { keys[key] & Self.oneShotBit != 0 }
    var hasGroups: Bool { keys.contains { $0 & 0x7F != 0 } }

    // Gespeichert als Liste von 128 Zahlen (optionaler Schlüssel `drumMap` am Instrument).
    init(from decoder: Decoder) throws {
        let v = try decoder.singleValueContainer().decode([UInt8].self)
        guard v.count == 128 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "drumMap: 128 Einträge"))
        }
        keys = v
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(keys)
    }

    // MARK: EXS lesen

    /// nil: kein EXS (oder unlesbar) oder weder Sperrgruppen noch One-Shot.
    static func exs(_ data: Data) -> DrumMap? {
        let b = [UInt8](data)
        func u32(_ o: Int) -> UInt32 {
            UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
        }
        guard b.count >= 84, b[16] == 0x54, b[17] == 0x42, b[18] == 0x4F, b[19] == 0x53 else { return nil }   // "TBOS"
        var exclusive: [UInt8] = []                         // je Gruppe in Reihenfolge
        var zones: [(lo: Int, hi: Int, group: Int, oneShot: Bool)] = []
        var o = 0
        while o + 84 <= b.count {
            let sig = u32(o), size = Int(u32(o + 4))
            let p = o + 84
            guard size >= 0, p + size <= b.count else { break }
            switch (sig >> 24) & 0x0F {
            case 1 where size >= 92:
                let lo = Int(b[p + 6]), hi = Int(b[p + 7])
                zones.append((min(lo, hi), max(lo, hi), Int(Int32(bitPattern: u32(p + 88))), b[p] & 1 != 0))
            case 2 where size >= 5:
                exclusive.append(b[p + 4])
            default: break
            }
            o = p + size
        }
        var groupOf = [UInt8](repeating: 0, count: 128)
        var shots = [Int](repeating: 0, count: 128), total = [Int](repeating: 0, count: 128)
        for z in zones where z.hi < 128 {
            let ex = exclusive.indices.contains(z.group) ? exclusive[z.group] & 0x7F : 0
            for k in z.lo...z.hi {
                total[k] += 1
                if z.oneShot { shots[k] += 1 }
                if ex != 0, groupOf[k] == 0 || ex < groupOf[k] { groupOf[k] = ex }
            }
        }
        var keys = [UInt8](repeating: 0, count: 128)
        for k in 0..<128 where total[k] > 0 {
            keys[k] = groupOf[k] | (shots[k] == total[k] ? oneShotBit : 0)
        }
        return keys.contains(where: { $0 != 0 }) ? DrumMap(keys: keys) : nil
    }

    // MARK: Sampler-Zustand

    static let chokeRelease = 0.01

    /// Kurzer Ausklang (Hüllkurve 0, Stufe 5) für Layer, deren Tasten alle in einer Sperrgruppe
    /// und One-Shot sind. Rückgabe: geänderter Zustand und Zahl der Layer.
    func shortenChokeReleases(_ state: [String: Any]) -> (state: [String: Any], layers: Int) {
        guard var ins = state["Instrument"] as? [String: Any],
              var layers = ins["Layers"] as? [[String: Any]] else { return (state, 0) }
        var changed = 0
        for i in layers.indices {
            guard let zones = layers[i]["Zones"] as? [[String: Any]], !zones.isEmpty,
                  var envs = layers[i]["Envelopes"] as? [[String: Any]],
                  let e = envs.firstIndex(where: { ($0["ID"] as? Int) == 0 }),
                  var stages = envs[e]["Stages"] as? [[String: Any]] else { continue }
            let choked = zones.allSatisfy { z in
                guard let lo = z["min key"] as? Int, let hi = z["max key"] as? Int,
                      (0..<128).contains(lo), (0..<128).contains(hi), lo <= hi else { return false }
                return (lo...hi).allSatisfy { group($0) != 0 && isOneShot($0) }
            }
            guard choked, let s = stages.firstIndex(where: { ($0["stage"] as? Int) == 5 }) else { continue }
            if let t = stages[s]["time"] as? Double, t <= Self.chokeRelease { continue }
            stages[s]["time"] = Self.chokeRelease
            envs[e]["Stages"] = stages
            layers[i]["Envelopes"] = envs
            changed += 1
        }
        guard changed > 0 else { return (state, 0) }
        ins["Layers"] = layers
        var out = state
        out["Instrument"] = ins
        return (out, changed)
    }
}
