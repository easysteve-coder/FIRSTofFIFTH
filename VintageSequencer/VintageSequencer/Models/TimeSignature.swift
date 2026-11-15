import Foundation

// MARK: - Taktart (v1.18.12)
//
// Projektweit, wie das Tempo. Ein Takt hat `numerator` Schläge des Notenwerts 1/`denominator`.
// Zeitbasis bleibt 24 Pulse je Viertel: ein Takt sind 96 · Zähler / Nenner Pulse (4/4 = 96,
// 3/4 = 72, 7/8 = 84). Nenner 2, 4, 8, 16 halten Takt, Schlag und Sechzehntel ganzzahlig.
// Was daran hängt: Song-Szenen (Takte), Taktanker der Audio-Loops, Loop-Länge, Takt für die
// Plug-ins (`HostSync`), Pad-Längen. Geändert wird sie nur im Stillstand; der Tick-Thread
// übernimmt sie zu Beginn einer Sitzung aus dem Snapshot.

struct TimeSignature: Codable, Equatable, Hashable, Sendable {
    var numerator: Int
    var denominator: Int
    /// Gruppierung (v1.18.30, Konzept §10 L5): Aufteilung des Zählers in 2…8 Gruppen in
    /// Schlägen des Nenners, frei wählbar (7/8 als 5+2, 4+3, 2+2+3 …). nil = keine. Gehört zur
    /// Taktart (ein Wechsel ist ein Taktartwechsel), steht im Preset aber im eigenen
    /// Schlüssel `grouping` des Patterns — `timeSignature` bleibt „7/8" für ältere Versionen.
    var grouping: [Int]? = nil
    static let maxGroups = 8

    static let common = TimeSignature(numerator: 4, denominator: 4)
    static let denominators = [2, 4, 8, 16]
    static let numeratorRange = 1...16

    /// Auswahl in der Transportleiste.
    static let choices: [TimeSignature] = [
        .init(numerator: 2, denominator: 4), .init(numerator: 3, denominator: 4),
        .init(numerator: 4, denominator: 4), .init(numerator: 5, denominator: 4),
        .init(numerator: 6, denominator: 4), .init(numerator: 7, denominator: 4),
        .init(numerator: 3, denominator: 8), .init(numerator: 5, denominator: 8),
        .init(numerator: 6, denominator: 8), .init(numerator: 7, denominator: 8),
        .init(numerator: 9, denominator: 8), .init(numerator: 11, denominator: 8),
        .init(numerator: 12, denominator: 8), .init(numerator: 13, denominator: 8),
        .init(numerator: 15, denominator: 16),
    ]

    var isValid: Bool { Self.numeratorRange.contains(numerator) && Self.denominators.contains(denominator) }

    /// Ungültige Werte (fremde Datei) → 4/4; ungültige Gruppierung → keine.
    var clamped: TimeSignature {
        guard isValid else { return .common }
        var m = self
        if let g = grouping, !Self.isValidGrouping(g, numerator: numerator) { m.grouping = nil }
        return m
    }

    static func isValidGrouping(_ g: [Int], numerator: Int) -> Bool {
        (2...maxGroups).contains(g.count) && g.allSatisfy { $0 >= 1 } && g.reduce(0, +) == numerator
    }

    /// Gruppierung als Text „3+4"; Lesen verzeiht Leerzeichen.
    static func groupingText(_ g: [Int]) -> String { g.map(String.init).joined(separator: "+") }
    static func parseGrouping(_ s: String) -> [Int]? {
        let parts = s.split(separator: "+").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }
    }

    /// Anzeige „7/8 (3+4)" (im Preset steht nur `label`).
    var displayLabel: String { grouping.map { "\(label) (\(Self.groupingText($0)))" } ?? label }

    /// Gruppen in Sechzehnteln; ohne Gruppierung eine Gruppe = ein Takt.
    var groupSixteenths: [Int] { (grouping ?? [numerator]).map { $0 * sixteenthsPerBeat } }

    /// Gängige Aufteilungen für das Menü (Rest über „Eigene…"): zwei Gruppen ab 2, drei und
    /// vier Gruppen aus 2…4 — für 7: 2+5, 3+4, 4+3, 5+2, 2+2+3, 2+3+2, 3+2+2.
    static func groupingChoices(numerator n: Int) -> [[Int]] {
        guard n >= 4 else { return [] }
        var out: [[Int]] = (2...(n - 2)).map { [$0, n - $0] }
        func compose(_ rest: Int, _ parts: Int, _ prefix: [Int]) {
            if parts == 0 { if rest == 0 { out.append(prefix) }; return }
            for p in 2...4 where p <= rest { compose(rest - p, parts - 1, prefix + [p]) }
        }
        compose(n, 3, []); compose(n, 4, [])
        return Array(out.prefix(24))
    }

    /// Pulse je Takt (24 je Viertel).
    var pulsesPerBar: Int { 96 * numerator / denominator }
    /// Sechzehntel je Schlag bzw. je Takt.
    var sixteenthsPerBeat: Int { 16 / denominator }
    var sixteenthsPerBar: Int { numerator * sixteenthsPerBeat }
    /// Viertel je Takt (Plug-ins, Loop-Länge).
    var quartersPerBar: Double { 4 * Double(numerator) / Double(denominator) }

    var label: String { "\(numerator)/\(denominator)" }

    // Kompakt im Preset: „7/8".
    init(numerator: Int, denominator: Int, grouping: [Int]? = nil) {
        self.numerator = numerator; self.denominator = denominator; self.grouping = grouping
    }
    /// Unlesbare oder ungültige Angabe → 4/4 (das Projekt lädt trotzdem).
    init(from decoder: Decoder) throws {
        let s = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        let parts = s.split(separator: "/").compactMap { Int($0) }
        let m = parts.count == 2 ? TimeSignature(numerator: parts[0], denominator: parts[1]) : .common
        self = m.clamped
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(label)
    }

    /// Steplängen einer Pad-Lane in Sechzehnteln: ein bis drei Schläge (kürzer als ein Takt),
    /// dann 1, 2, 3, 4 und 8 Takte. Für 4/4 dieselben Werte wie bis v1.18.11.
    var padSixteenths: [Int] {
        let beats = (1...max(1, min(numerator - 1, 3))).map { $0 * sixteenthsPerBeat }.filter { $0 < sixteenthsPerBar }
        return beats + [1, 2, 3, 4, 8].map { $0 * sixteenthsPerBar }
    }

    /// Länge in Sechzehnteln nach einem Taktartwechsel: ganze Takte bleiben ganze Takte, ganze
    /// Schläge (unter einem Takt) bleiben Schläge; alles andere bleibt unverändert.
    /// Ohne Gruppierung gleich; gleiche Gruppierung zählt bei gleichem Zähler/Nenner.
    func convert(sixteenths n: Int, to new: TimeSignature) -> Int {
        if n % sixteenthsPerBar == 0 { return n / sixteenthsPerBar * new.sixteenthsPerBar }
        if n % sixteenthsPerBeat == 0 { return n / sixteenthsPerBeat * new.sixteenthsPerBeat }
        return n
    }
}
