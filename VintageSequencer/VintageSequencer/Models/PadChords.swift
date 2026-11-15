import Foundation

// MARK: - Pad-Akkorde (v1.13.16)
//
// Akkordfolgen für Pad-Lanes. Zwei Quellen:
//  - `.books`: Folgen aus Lizzio, „Chord Progression Codex“, und Callipari, „Illustrierte
//    Harmonie“ — dieselbe Auswahl und dieselben Seitenangaben wie die Harmonie-Vorlagen
//    in Planarium. Die Folgen sind auf die Tonika 0 notiert und werden auf den
//    Grundton der Spur transponiert.
//  - `.free`: leitereigene Akkorde der Skala der Spur, Zufallsweg mit gemeinsamen Tönen.
// Läuft nur auf Main (Randomize-Befehl), nie im Tick-Pfad.

enum ChordQuality: CaseIterable {
    case maj, min, dim, aug, dom7, maj7, min7, six, min6, minMaj7, add9, minAdd9

    var intervals: [Int] {
        switch self {
        case .maj:     return [0, 4, 7]
        case .min:     return [0, 3, 7]
        case .dim:     return [0, 3, 6]
        case .aug:     return [0, 4, 8]
        case .dom7:    return [0, 4, 7, 10]
        case .maj7:    return [0, 4, 7, 11]
        case .min7:    return [0, 3, 7, 10]
        case .six:     return [0, 4, 7, 9]
        case .min6:    return [0, 3, 7, 9]
        case .minMaj7: return [0, 3, 7, 11]
        case .add9:    return [0, 2, 4, 7]
        case .minAdd9: return [0, 2, 3, 7]
        }
    }

    var suffix: String {
        switch self {
        case .maj:     return ""
        case .min:     return "m"
        case .dim:     return "°"
        case .aug:     return "+"
        case .dom7:    return "7"
        case .maj7:    return "maj7"
        case .min7:    return "m7"
        case .six:     return "6"
        case .min6:    return "m6"
        case .minMaj7: return "m(maj7)"
        case .add9:    return "add9"
        case .minAdd9: return "m(add9)"
        }
    }
}

/// Ein Akkord relativ zur Tonika: Grundton in Halbtönen (0…11) und Klangart.
struct ChordSymbol: Equatable {
    let root: Int
    let quality: ChordQuality
    init(_ root: Int, _ quality: ChordQuality) { self.root = ((root % 12) + 12) % 12; self.quality = quality }
}

struct ChordProgressionFamily: Identifiable {
    enum Shape {
        /// Feste Reihenfolge; eine der Varianten wird gewählt und zyklisch aufgefüllt.
        case sequence([[ChordSymbol]])
        /// Beliebige Reihenfolge innerhalb des Vorrats, Start auf dem ersten Akkord.
        case net([ChordSymbol])
        /// Tonika im Wechsel mit einem der übrigen Akkorde.
        case hub(tonic: ChordSymbol, others: [ChordSymbol])
        /// Terzkette: abwechselnd Dur und Moll, jeder Akkord auf der Terz des vorigen.
        case thirdChain
    }

    let id: String
    let nameEN: String
    let nameDE: String
    let source: String
    let shape: Shape

    func name(german: Bool) -> String { german ? nameDE : nameEN }
}

enum PadChordSource: String, CaseIterable {
    case books
    case free
}

/// Was RND auf eine Step-Spur würfelt (v1.16.2). Normale Spuren starten mit Einzeltönen,
/// Pad-Spuren mit Akkorden; die Wahl gilt je Spurart (Schlüssel in `SequencerEngine`).
enum RandomNoteMode: String, CaseIterable {
    case single
    case chords
    case mixed
}

enum PadChords {

    // Seitenangaben übernommen aus den Planarium-Harmonievorlagen (Lizzio, Chord
    // Progression Codex; Callipari, Illustrierte Harmonie).
    static let families: [ChordProgressionFamily] = [
        .init(id: "popNet", nameEN: "Pop net", nameDE: "Pop-Netz",
              source: "Lizzio, Chord Progression Codex, p. 62–77, 102–105",
              shape: .net([.init(0, .maj), .init(2, .min), .init(4, .min),
                           .init(5, .maj), .init(7, .maj), .init(9, .min)])),
        .init(id: "minorTriangle", nameEN: "Minor triangle", nameDE: "Moll-Dreieck",
              source: "Lizzio, Chord Progression Codex, p. 84–90",
              shape: .net([.init(0, .min), .init(8, .maj), .init(3, .maj), .init(10, .maj)])),
        .init(id: "andalusian", nameEN: "Andalusian", nameDE: "Andalusisch",
              source: "Lizzio, Chord Progression Codex, p. 93–94, 236",
              shape: .sequence([[.init(0, .min), .init(10, .maj), .init(8, .maj), .init(7, .maj)]])),
        .init(id: "longing", nameEN: "Longing", nameDE: "Sehnsucht",
              source: "Lizzio, Chord Progression Codex, p. 270–271",
              shape: .sequence([[.init(0, .maj), .init(5, .maj), .init(5, .min), .init(0, .maj)]])),
        .init(id: "epic", nameEN: "Epic", nameDE: "Episch",
              source: "Lizzio, Chord Progression Codex, p. 270–275, 282",
              shape: .sequence([[.init(0, .maj), .init(8, .maj), .init(10, .maj), .init(0, .maj)],
                                [.init(0, .maj), .init(3, .maj), .init(8, .maj), .init(10, .maj)]])),
        .init(id: "godChords", nameEN: "God chords", nameDE: "Götterakkorde",
              source: "Lizzio, Chord Progression Codex, p. 290–291",
              shape: .hub(tonic: .init(0, .maj),
                          others: [.init(9, .maj), .init(4, .maj), .init(8, .maj), .init(3, .maj)])),
        .init(id: "spooky", nameEN: "Spooky", nameDE: "Spuk",
              source: "Lizzio, Chord Progression Codex, p. 291–292, 325",
              shape: .hub(tonic: .init(0, .min),
                          others: [.init(3, .min), .init(4, .min), .init(8, .min), .init(9, .min)])),
        .init(id: "lineCliche", nameEN: "Line cliché", nameDE: "Line-Klischee",
              source: "Lizzio, Chord Progression Codex, p. 219, 235–236",
              shape: .sequence([[.init(0, .maj), .init(0, .maj7), .init(0, .dom7), .init(0, .six)],
                                [.init(0, .min), .init(0, .minMaj7), .init(0, .min7), .init(0, .min6)]])),
        .init(id: "modeSwitch", nameEN: "Mode switch", nameDE: "Modus-Schalter",
              source: "Lizzio, Chord Progression Codex, p. 300–318",
              shape: .sequence([[.init(0, .min), .init(5, .maj)],      // dorisch
                                [.init(0, .maj), .init(2, .maj)],      // lydisch
                                [.init(0, .maj), .init(10, .maj)],     // mixolydisch
                                [.init(0, .min), .init(1, .maj)]])),   // phrygisch
        .init(id: "thirdChain", nameEN: "Third chain", nameDE: "Terzkette",
              source: "Callipari, Illustrierte Harmonie, p. 62–65, 123–125; Lizzio, Chord Progression Codex, p. 198–199, 323",
              shape: .thirdChain),
        .init(id: "secondaryDominants", nameEN: "Secondary dominants", nameDE: "Zwischendominanten",
              source: "Callipari, Illustrierte Harmonie, p. 67, 83–86; Lizzio, Chord Progression Codex, p. 170–178",
              shape: .sequence([[.init(0, .maj), .init(9, .dom7), .init(2, .min), .init(7, .dom7)],
                                [.init(0, .maj), .init(4, .dom7), .init(9, .min), .init(2, .dom7), .init(7, .maj)]])),
        .init(id: "fifthsLoop", nameEN: "Fifths loop", nameDE: "Quintfall",
              source: "Lizzio, Chord Progression Codex, p. 195; Callipari, Illustrierte Harmonie, p. 68–69",
              shape: .sequence([[.init(0, .min), .init(5, .min), .init(10, .maj), .init(3, .maj),
                                 .init(8, .maj), .init(2, .dim), .init(7, .maj)]])),
        .init(id: "neapolitan", nameEN: "Neapolitan", nameDE: "Neapolitaner",
              source: "Lizzio, Chord Progression Codex, p. 118, 287–288, 305–306",
              shape: .sequence([[.init(0, .min), .init(8, .maj), .init(1, .maj), .init(7, .dom7)]])),
        .init(id: "picardy", nameEN: "Picardy switch", nameDE: "Picardie",
              source: "Lizzio, Chord Progression Codex, p. 198, 266–267, 278–282; Callipari, Illustrierte Harmonie, p. 76, 78",
              shape: .sequence([[.init(0, .min), .init(5, .min), .init(7, .dom7), .init(0, .maj)]])),
        .init(id: "hexatonic", nameEN: "Hexatonic cycle", nameDE: "Hexatonik",
              source: "Callipari, Illustrierte Harmonie, p. 108–113; Lizzio, Chord Progression Codex, p. 49",
              shape: .sequence([[.init(0, .maj), .init(0, .min), .init(8, .maj),
                                 .init(8, .min), .init(4, .maj), .init(4, .min)]])),
        .init(id: "risingSun", nameEN: "Rising sun", nameDE: "Rising Sun",
              source: "Lizzio, Chord Progression Codex, p. 302–303",
              shape: .sequence([[.init(0, .min), .init(3, .maj), .init(5, .maj), .init(8, .maj),
                                 .init(0, .min), .init(3, .maj), .init(7, .maj), .init(7, .maj)]])),
        .init(id: "blues", nameEN: "Twelve-bar blues", nameDE: "Zwölftakt-Blues",
              source: "Lizzio, Chord Progression Codex, p. 256–263",
              shape: .sequence([[.init(0, .dom7), .init(0, .dom7), .init(0, .dom7), .init(0, .dom7),
                                 .init(5, .dom7), .init(5, .dom7), .init(0, .dom7), .init(0, .dom7),
                                 .init(7, .dom7), .init(5, .dom7), .init(0, .dom7), .init(7, .dom7)]])),
    ]

    static func family(id: String) -> ChordProgressionFamily? { families.first { $0.id == id } }

    // MARK: Skala (v1.18.14)

    /// Tonklassen eines Akkords relativ zur Tonika.
    static func pitchClasses(_ c: ChordSymbol) -> Set<Int> {
        Set(c.quality.intervals.map { (c.root + $0) % 12 })
    }

    /// Liegen alle Töne des Akkords in der Skala (Intervalle relativ zur Tonika)?
    static func fits(_ c: ChordSymbol, scale: Set<Int>) -> Bool { pitchClasses(c).isSubset(of: scale) }

    /// Alle Akkorde, die eine Familie spielen kann; nil = nicht aufzählbar (Terzkette, chromatisch).
    static func chords(of family: ChordProgressionFamily) -> [ChordSymbol]? {
        switch family.shape {
        case .sequence(let variants): return variants.flatMap { $0 }
        case .net(let pool):          return pool
        case .hub(let t, let others): return [t] + others
        case .thirdChain:             return nil
        }
    }

    /// Passt jede mögliche Folge der Familie in die Skala?
    static func fits(_ family: ChordProgressionFamily, scale: Set<Int>) -> Bool {
        chords(of: family)?.allSatisfy { fits($0, scale: scale) } ?? false
    }

    // MARK: Folge erzeugen

    /// `count` Akkorde aus einer Familie (relativ zur Tonika 0).
    static func progression<R: RandomNumberGenerator>(_ family: ChordProgressionFamily, count: Int,
                                                      using rng: inout R) -> [ChordSymbol] {
        let n = max(1, count)
        switch family.shape {
        case .sequence(let variants):
            let seq = variants.randomElement(using: &rng) ?? variants[0]
            return (0..<n).map { seq[$0 % seq.count] }
        case .net(let pool):
            var out = [pool[0]]
            while out.count < n {
                let last = out[out.count - 1]
                // Letzter Step: nicht auf der Tonika enden, damit der Kreis zur Eins zurückführt.
                let candidates = pool.filter { $0 != last && (out.count < n - 1 || $0 != pool[0] || pool.count <= 2) }
                out.append(candidates.randomElement(using: &rng) ?? pool[0])
            }
            return out
        case .hub(let tonic, let others):
            var out: [ChordSymbol] = []
            var prev: ChordSymbol?
            for i in 0..<n {
                if i % 2 == 0 { out.append(tonic); continue }
                let pick = others.filter { $0 != prev }.randomElement(using: &rng) ?? others[0]
                out.append(pick); prev = pick
            }
            return out
        case .thirdChain:
            var out: [ChordSymbol] = []
            var root = 0
            for i in 0..<n {
                out.append(.init(root, i % 2 == 0 ? .maj : .min))
                root += (i % 2 == 0) ? 4 : 3
            }
            return out
        }
    }

    /// Leitereigene Folge: Dreiklänge (gelegentlich Septakkorde bzw. add9) der Skala,
    /// Zufallsweg bevorzugt über gemeinsame Töne. Ohne Skala (chromatisch) wird Dur bzw.
    /// natürliches Moll genommen. `restrict` (v1.18.14, Skala eingestellt): jeder Akkord liegt
    /// ganz in der Skala — Farben nur, wenn sie passen; Skalen ohne sieben Stufen (Pentatonik,
    /// Blues, Ganzton) bekommen Akkorde aus ihren eigenen Tönen.
    static func freeProgression<R: RandomNumberGenerator>(scaleIndex: Int, count: Int, restrict: Bool = false,
                                                          using rng: inout R) -> [ChordSymbol] {
        let scales = TrackData.scales
        var steps = scales.indices.contains(scaleIndex) ? scales[scaleIndex].intervals : []
        if restrict, steps.count != 7, !steps.isEmpty {
            return scaleChordWalk(scale: steps, count: count, using: &rng)
        }
        let scaleSet: Set<Int>? = restrict ? Set(steps) : nil
        if steps.count != 7 {
            let minorish = steps.contains(3) && !steps.contains(4)
            steps = minorish ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]
        }
        func pc(_ degree: Int) -> Int { steps[degree % 7] + 12 * (degree / 7) }
        let diatonic: [(ChordSymbol, Set<Int>)] = (0..<7).compactMap { d in
            let r = steps[d]
            let third = (pc(d + 2) - r + 12) % 12, fifth = (pc(d + 4) - r + 12) % 12
            let seventh = (pc(d + 6) - r + 12) % 12
            let base: ChordQuality
            switch (third, fifth) {
            case (4, 7): base = .maj
            case (3, 7): base = .min
            case (3, 6): base = .dim
            case (4, 8): base = .aug
            default: return nil
            }
            var q = base
            if Int.random(in: 0..<3, using: &rng) == 0 {   // Farbe für Flächen
                switch (base, seventh) {
                case (.maj, 11): q = .maj7
                case (.maj, 10): q = .dom7
                case (.min, 10): q = .min7
                case (.maj, _):  q = .add9
                case (.min, _):  q = .minAdd9
                default: break
                }
            }
            if let scaleSet, !fits(ChordSymbol(r, q), scale: scaleSet) { q = base }
            let sym = ChordSymbol(r, q)
            return (sym, Set(q.intervals.map { (r + $0) % 12 }))
        }
        guard let tonic = diatonic.first?.0 else { return [ChordSymbol(0, .maj)] }
        var out = [tonic]
        while out.count < max(1, count) {
            let last = out[out.count - 1]
            let lastPCs = Set(last.quality.intervals.map { (last.root + $0) % 12 })
            let options = diatonic.filter { $0.0.root != last.root && $0.0.quality != .dim }
            // Gewicht: gemeinsame Töne ×2 + 1, damit auch entfernte Stufen vorkommen.
            let weighted = options.flatMap { o in
                Array(repeating: o.0, count: 1 + 2 * o.1.intersection(lastPCs).count)
            }
            out.append(weighted.randomElement(using: &rng) ?? tonic)
        }
        return out
    }

    /// Zufallsweg über alle Akkorde, die ganz aus den Tönen von `scale` bestehen (Skalen ohne
    /// sieben Stufen). Start auf der Tonika, sonst wie `freeProgression` gewichtet.
    static func scaleChordWalk<R: RandomNumberGenerator>(scale: [Int], count: Int,
                                                         using rng: inout R) -> [ChordSymbol] {
        let set = Set(scale)
        let order: [ChordQuality] = [.maj, .min, .aug, .six, .min6, .maj7, .min7, .dom7, .add9, .minAdd9, .dim]
        let all = scale.flatMap { r in order.map { ChordSymbol(r, $0) } }.filter { fits($0, scale: set) }
        let triads = all.filter { [.maj, .min, .aug].contains($0.quality) }
        guard let tonic = triads.first(where: { $0.root == 0 }) ?? all.first(where: { $0.root == 0 }) ?? all.first else {
            return Array(repeating: ChordSymbol(0, .maj), count: max(1, count))  // Skala ohne Dreiklang
        }
        var out = [tonic]
        while out.count < max(1, count) {
            let last = out[out.count - 1], lastPCs = pitchClasses(last)
            // Farben seltener als Dreiklänge; nicht zweimal derselbe Akkord.
            let options = all.filter { $0 != last && $0.quality != .dim }
            let weighted = options.flatMap { o in
                Array(repeating: o, count: (triads.contains(o) ? 3 : 1) * (1 + pitchClasses(o).intersection(lastPCs).count))
            }
            out.append(weighted.randomElement(using: &rng) ?? tonic)
        }
        return out
    }

    // MARK: Stimmführung

    /// Setzt Akkordsymbole (relativ zur Tonika) in MIDI-Noten um: Bass (Grundton,
    /// Oktave 2/3) plus Akkord in enger Lage um C4, jede Lage so gewählt, dass die
    /// Oberstimmen möglichst wenig springen.
    static func voice(_ chords: [ChordSymbol], tonic: Int) -> [[Int]] {
        var previous: [Int]?
        return chords.map { c in
            let root = (c.root + tonic) % 12
            let pcs = c.quality.intervals.map { (root + $0) % 12 }
            var best: [Int] = []
            var bestCost = Int.max
            for inversion in 0..<pcs.count {
                let ordered = Array(pcs[inversion...] + pcs[..<inversion])
                for base in 52...64 where base % 12 == ordered[0] {
                    var notes = [base]
                    for p in ordered.dropFirst() {
                        var n = notes[notes.count - 1] + 1
                        while n % 12 != p { n += 1 }
                        notes.append(n)
                    }
                    guard notes.last! <= 79 else { continue }
                    let cost: Int
                    if let prev = previous {
                        cost = notes.map { n in prev.map { abs($0 - n) }.min() ?? 0 }.reduce(0, +)
                    } else {
                        cost = abs((notes.first! + notes.last!) / 2 - 64)
                    }
                    if cost < bestCost { bestCost = cost; best = notes }
                }
            }
            previous = best
            let bass = 36 + root          // C2 … B2
            return ([bass] + best).sorted()
        }
    }
}
