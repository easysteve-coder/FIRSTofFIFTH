import Foundation
import Combine

final class Pattern: ObservableObject, Identifiable {
    let id = UUID()
    /// Pattern-Plätze A–P (v1.14.0; bis v1.13.19 A–D).
    static let slotNames: [String] = (0..<16).map { String(UnicodeScalar(UInt8(65 + $0))) }
    @Published var name:   String
    @Published var tracks: [TrackData]

    /// Monotoner Zähler für Track-Nummerierung (v1.9.1, Slice A).
    /// Wird bei jedem neu angelegten Track gelesen und anschließend um 1
    /// erhöht. Dadurch entstehen nach Löschungen keine doppelten
    /// „Track N"-Namen mehr. Nicht @Published — kein UI-Redraw nötig.
    var nextTrackOrdinal: Int

    /// Taktart dieses Patterns (v1.18.24, Konzept Taktart und Zeit, Entscheidung E1). Geschrieben
    /// wird sie über die Engine (`setTimeSignatureUndoable`), nie direkt aus einer View. Der Tick
    /// übernimmt sie beim Öffnen eines Abschnitts (Patternstart).
    var timeSignature: TimeSignature = .common
    /// Beim Laden: stand ein eigener Schlüssel in der Datei? Fehlt er, löst der Ladepfad einmalig
    /// auf die Projekttaktart der Datei auf (nicht gespeichert).
    var timeSignatureFromFile = false

    init(name: String, trackCount: Int = 4) {
        self.name   = name
        self.tracks = (0..<trackCount).map { i in
            TrackData(name: "Track \(i + 1)",
                      stepCount: 16,
                      midiChannel: i + 1,
                      colorIndex: i)
        }
        self.nextTrackOrdinal = trackCount + 1
    }
}

// MARK: - Zeilen (v1.18.6, Codex A17-12)

extension Pattern {
    /// Die 16 leeren Plätze eines neuen Projekts; Zeile n ist in allen Patterns dieselbe.
    static func defaultSlots() -> [Pattern] {
        let slots = slotNames.map { Pattern(name: $0) }
        assignMissingRows(slots, all: true)
        return slots
    }

    /// Vergibt Zeilen nach Zeilennummer: Spur n jedes Patterns bekommt dieselbe Zeile.
    /// `all: false` (Laden) betrifft nur Spuren ohne Zeile aus der Datei; trägt eine
    /// andere Spur an derselben Nummer schon eine, wird sie übernommen.
    static func assignMissingRows(_ patterns: [Pattern], all: Bool = false) {
        let depth = patterns.map(\.tracks.count).max() ?? 0
        for n in 0..<depth {
            let tracks = patterns.compactMap { n < $0.tracks.count ? $0.tracks[n] : nil }
            let missing = tracks.filter { all || !$0.rowFromFile }
            guard !missing.isEmpty else { continue }
            let known = all ? nil : tracks.first(where: { $0.rowFromFile })?.row
            let used = Set(tracks.filter { !all && $0.rowFromFile }.map(\.row))
            let r = known.flatMap { used.count == 1 ? $0 : nil } ?? UUID()
            for t in missing { t.row = r }
        }
    }
}

extension Pattern: Codable {
    enum CodingKeys: String, CodingKey { case name, tracks, nextTrackOrdinal, timeSignature, grouping }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name,             forKey: .name)
        try c.encode(tracks,           forKey: .tracks)
        try c.encode(nextTrackOrdinal, forKey: .nextTrackOrdinal)
        try c.encode(timeSignature,    forKey: .timeSignature)   // immer: Fehlen heißt „Projektvorgabe"
        // Gruppierung (v1.18.30) im eigenen Schlüssel: ältere Versionen lesen „7/8" weiter.
        try c.encodeIfPresent(timeSignature.grouping.map(TimeSignature.groupingText), forKey: .grouping)
    }

    convenience init(from decoder: Decoder) throws {
        let c      = try decoder.container(keyedBy: CodingKeys.self)
        let name   = try c.decode(String.self,       forKey: .name)
        let tracks = try c.decode([TrackData].self,  forKey: .tracks)
        self.init(name: name, trackCount: tracks.count)
        self.tracks = tracks
        // Taktart je Pattern (v1.18.24). Optional; fehlt → Projekttaktart der Datei (Ladepfad).
        if var m = try c.decodeIfPresent(TimeSignature.self, forKey: .timeSignature) {
            m.grouping = ((try? c.decodeIfPresent(String.self, forKey: .grouping)) ?? nil)
                .flatMap(TimeSignature.parseGrouping)
            timeSignature = m.clamped; timeSignatureFromFile = true
        }

        // Legacy-Patch (v1.9.1): Tracks ohne persistierten colorIndex (Sentinel -1)
        // bekommen ihren Array-Positionsindex zugewiesen, damit das bisherige
        // optische Erscheinungsbild alter Presets erhalten bleibt.
        for (i, td) in self.tracks.enumerated() where td.colorIndex < 0 {
            td.colorIndex = i
        }

        // nextTrackOrdinal: in Legacy-Presets nicht vorhanden. Sinnvoller Default
        // ist max(tracks.count, aus Namen extrahiertes Maximum) + 1, damit beim
        // nächsten Add keine Namenskollision mit existierenden „Track N"-Namen
        // entsteht.
        if let persisted = try c.decodeIfPresent(Int.self, forKey: .nextTrackOrdinal) {
            self.nextTrackOrdinal = max(persisted, tracks.count + 1)
        } else {
            self.nextTrackOrdinal = max(
                Pattern.extractMaxOrdinal(from: tracks),
                tracks.count
            ) + 1
        }
    }

    /// Extrahiert die höchste Zahl N aus Namen der Form „Track N" oder „Spur N".
    /// Namen ohne diese Form werden ignoriert. Nur Legacy-Decode-Pfad.
    private static func extractMaxOrdinal(from tracks: [TrackData]) -> Int {
        var best = 0
        for t in tracks {
            let parts = t.name.split(separator: " ")
            guard parts.count >= 2, let n = Int(parts.last!) else { continue }
            if n > best { best = n }
        }
        return best
    }
}
