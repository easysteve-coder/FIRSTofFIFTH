import Testing
@testable import VintageSequencer

// v1.18.14 — Stephan: „gewürfelte akkorde auch auf Skala begrenzen wenn ausgewählt."

private struct Seeded: RandomNumberGenerator {
    var s: UInt64
    mutating func next() -> UInt64 {
        s &+= 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct PadChordScaleTests {

    /// Jede Skala, jede Quelle, fest gewählte Familie oder Zufall: jeder Ton liegt in der Skala.
    @Test(arguments: Array(1..<TrackData.scales.count))
    func everyNoteInScale(scale: Int) {
        let intervals = Set(TrackData.scales[scale].intervals)
        let fixed: [ChordProgressionFamily?] = [nil] + PadChords.families.map { $0 }
        var rng = Seeded(s: UInt64(scale) * 7919)
        for root in [0, 5, 10] {
            for source in PadChordSource.allCases {
                for family in fixed {
                    for _ in 0..<4 {
                        let chords = SequencerEngine.rolledChords(scaleIndex: scale, scaleRoot: root, count: 8,
                                                                  source: source, fixedFamily: family, using: &rng)
                        #expect(chords.count == 8)
                        for chord in chords {
                            #expect(chord.count >= 3, "\(TrackData.scales[scale].name): \(chord)")
                            for n in chord {
                                #expect(intervals.contains(((n % 12) - root + 12) % 12),
                                        "\(TrackData.scales[scale].name) \(source) \(family?.id ?? "-"): \(chord)")
                            }
                        }
                    }
                }
            }
        }
    }

    /// Codex: jede Skala braucht mindestens einen Dreiklang aus eigenen Tönen, sonst fiele das
    /// Würfeln auf einen leiterfremden Rückfall. Neue Skalen müssen das hier erfüllen.
    @Test func everyScaleHasAFittingTriad() {
        for (i, s) in TrackData.scales.enumerated() where i > 0 {
            let set = Set(s.intervals)
            let triads = s.intervals.flatMap { r in [ChordQuality.maj, .min, .aug, .dim].map { ChordSymbol(r, $0) } }
                .filter { PadChords.fits($0, scale: set) }
            #expect(!triads.isEmpty, "\(s.name): kein Dreiklang")
        }
    }

    /// Passende Familien bleiben erhalten: in Dur spielen die Bücher weiter (nicht nur leitereigen).
    @Test func majorKeepsFittingFamilies() {
        let major = Set(TrackData.scales[1].intervals)
        #expect(PadChords.families.contains { PadChords.fits($0, scale: major) })
    }

    /// Chromatisch (keine Skala): unverändert, Farben dürfen leiterfremd sein.
    @Test func chromaticUnrestricted() {
        var rng = Seeded(s: 1)
        let chords = SequencerEngine.rolledChords(scaleIndex: 0, scaleRoot: 0, count: 8, source: .free,
                                                  fixedFamily: nil, using: &rng)
        #expect(chords.count == 8)
    }
}
