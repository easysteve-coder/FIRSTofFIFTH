import Foundation
import AVFoundation

// MARK: - Kanal-EQ (v1.18.11)
//
// Acht Bänder wie Logic Channel EQ: Low Cut · Low Shelf · vier Glocken · High Shelf · High Cut.
// Umgesetzt in der Gain-Stufe des Kanals (`AVAudioUnitEQ`, die schon den Fader trägt) —
// kein zusätzlicher Knoten im Renderweg. Gemessen (Offline-Render, `ChannelEQTests`):
// - Glocke: Bandbreite in Oktaven zwischen den Punkten halben dB-Gewinns (RBJ-Peak).
// - Shelf: feste Steilheit, halber Gewinn an der Eckfrequenz (RBJ-Shelf, S = 1).
// - Hoch-/Tiefpass: Butterworth 2. Ordnung, 12 dB/Okt., −3 dB an der Eckfrequenz.
// Steilere Cuts sind Kaskaden gleicher Stufen mit verschobener Eckfrequenz, so dass die Summe
// genau an der angezeigten Frequenz −3 dB hat.

struct ChannelEQ: Codable, Equatable {

    enum Kind: String, Codable { case lowCut, lowShelf, bell, highShelf, highCut }

    struct Band: Codable, Equatable {
        var kind: Kind
        var isOn: Bool
        /// Hz, 20 … 20 000
        var frequency: Double
        /// dB, −24 … +24 (Cuts: ohne Bedeutung)
        var gain: Double = 0
        /// Güte der Glocken, 0,1 … 12
        var q: Double = 0.71
        /// Flankensteilheit der Cuts in dB/Okt.: 12, 24, 36, 48
        var slope: Int = 24

        var usesGain: Bool { kind != .lowCut && kind != .highCut }
        var usesQ: Bool { kind == .bell }
        var usesSlope: Bool { !usesGain }

        /// Beeinflusst das Band den Klang?
        var isActive: Bool { isOn && (usesSlope || abs(gain) > 0.01) }

        mutating func clamp() {
            frequency = min(ChannelEQ.maxFrequency, max(ChannelEQ.minFrequency, frequency.isFinite ? frequency : 1000))
            gain = min(ChannelEQ.maxGain, max(-ChannelEQ.maxGain, gain.isFinite ? gain : 0))
            q = min(ChannelEQ.maxQ, max(ChannelEQ.minQ, q.isFinite ? q : 0.71))
            if !ChannelEQ.slopes.contains(slope) { slope = 24 }
        }
    }

    static let minFrequency = 20.0, maxFrequency = 20_000.0
    static let maxGain = 24.0
    static let minQ = 0.1, maxQ = 12.0
    static let slopes = [12, 24, 36, 48]
    static let bandCount = 8
    /// Stufen der Einheit: je Cut vier (48 dB/Okt.), Shelves und Glocken je eine.
    static let unitBandCount = 4 + 1 + 4 + 1 + 4

    var isOn = true
    var bands: [Band] = ChannelEQ.defaultBands

    static let defaultBands: [Band] = [
        Band(kind: .lowCut,    isOn: false, frequency: 30),
        Band(kind: .lowShelf,  isOn: true,  frequency: 80),
        Band(kind: .bell,      isOn: true,  frequency: 250),
        Band(kind: .bell,      isOn: true,  frequency: 800),
        Band(kind: .bell,      isOn: true,  frequency: 2_500),
        Band(kind: .bell,      isOn: true,  frequency: 6_000),
        Band(kind: .highShelf, isOn: true,  frequency: 12_000),
        Band(kind: .highCut,   isOn: false, frequency: 18_000),
    ]

    /// Keine Klangänderung (ausgeschaltet oder alle Bänder neutral).
    var isNeutral: Bool { !isOn || !bands.contains { $0.isActive } }

    /// Grundeinstellung eines Bands (⌥-Klick).
    static func defaultBand(_ index: Int) -> Band { defaultBands[index] }

    /// Ungültige Bänderzahl oder -arten (fremde Datei) → Grundeinstellung; Werte begrenzen.
    mutating func clamp() {
        if bands.count != Self.bandCount || zip(bands, Self.defaultBands).contains(where: { $0.kind != $1.kind }) {
            bands = Self.defaultBands
        }
        for i in bands.indices { bands[i].clamp() }
    }

    // MARK: Abbildung auf AVAudioUnitEQ

    struct UnitBand: Equatable {
        var type: AVAudioUnitEQFilterType
        var frequency: Float
        var gain: Float
        var bandwidth: Float
        var bypass: Bool
    }

    /// Q → Bandbreite in Oktaven (zwischen den Punkten halben Gewinns).
    static func octaves(q: Double) -> Double { 2 / log(2) * asinh(1 / (2 * q)) }

    /// Eckfrequenz je Stufe einer Kaskade aus `stages` Butterworth-Stufen 2. Ordnung, damit die
    /// Summe bei `f` genau −3 dB hat: |H|² je Stufe = 1/(1+(f/fc)^∓4), Summe = 1/2.
    static func stageCorner(_ f: Double, stages: Int, highPass: Bool) -> Double {
        let r = pow(pow(2, 1 / Double(stages)) - 1, 0.25)
        return highPass ? f * r : f / r
    }

    /// Stufen in fester Reihenfolge (`unitBandCount`); ausgeschaltet = überbrückt.
    var unitBands: [UnitBand] {
        var out: [UnitBand] = []
        func cut(_ b: Band, highPass: Bool) {
            let stages = b.slope / 12
            let fc = Float(Self.stageCorner(b.frequency, stages: stages, highPass: highPass))
            for s in 0..<4 {
                out.append(UnitBand(type: highPass ? .highPass : .lowPass, frequency: fc, gain: 0,
                                    bandwidth: 1, bypass: !(isOn && b.isOn) || s >= stages))
            }
        }
        for b in bands {
            switch b.kind {
            case .lowCut:  cut(b, highPass: true)
            case .highCut: cut(b, highPass: false)
            case .lowShelf, .highShelf, .bell:
                out.append(UnitBand(type: b.kind == .bell ? .parametric : (b.kind == .lowShelf ? .lowShelf : .highShelf),
                                    frequency: Float(b.frequency), gain: Float(b.gain),
                                    bandwidth: Float(Self.octaves(q: b.q)),
                                    bypass: !(isOn && b.isActive)))
            }
        }
        return out
    }

    // MARK: Antwort (Anzeige)

    /// Betragsgang eines Bands in dB bei `f` (digitale Biquads wie die Einheit).
    static func response(_ b: Band, at f: Double, sampleRate: Double) -> Double {
        guard b.isOn else { return 0 }
        switch b.kind {
        case .lowCut, .highCut:
            let stages = b.slope / 12
            let fc = stageCorner(b.frequency, stages: stages, highPass: b.kind == .lowCut)
            let c = Biquad.butterworth(fc, sampleRate: sampleRate, highPass: b.kind == .lowCut)
            return Double(stages) * c.decibels(at: f, sampleRate: sampleRate)
        case .bell:
            return Biquad.peak(b.frequency, gain: b.gain, octaves: octaves(q: b.q), sampleRate: sampleRate)
                .decibels(at: f, sampleRate: sampleRate)
        case .lowShelf, .highShelf:
            return Biquad.shelf(b.frequency, gain: b.gain, low: b.kind == .lowShelf, sampleRate: sampleRate)
                .decibels(at: f, sampleRate: sampleRate)
        }
    }

    /// Gesamtgang in dB bei `f`.
    func response(at f: Double, sampleRate: Double) -> Double {
        guard isOn else { return 0 }
        return bands.reduce(0) { $0 + Self.response($1, at: f, sampleRate: sampleRate) }
    }
}

/// Biquad-Koeffizienten (RBJ Audio-EQ-Cookbook), nur zur Anzeige und für Tests.
struct Biquad {
    var b0, b1, b2, a0, a1, a2: Double

    func decibels(at f: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * min(f, sampleRate * 0.4999) / sampleRate
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = a0 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        let mag2 = (nr * nr + ni * ni) / max(1e-30, dr * dr + di * di)
        return 10 * log10(max(1e-30, mag2))
    }

    static func butterworth(_ f0: Double, sampleRate: Double, highPass: Bool) -> Biquad {
        let w = 2 * Double.pi * min(f0, sampleRate * 0.49) / sampleRate
        let alpha = sin(w) / (2 * (1 / 2.0.squareRoot()))
        let c = cos(w)
        if highPass {
            return Biquad(b0: (1 + c) / 2, b1: -(1 + c), b2: (1 + c) / 2, a0: 1 + alpha, a1: -2 * c, a2: 1 - alpha)
        }
        return Biquad(b0: (1 - c) / 2, b1: 1 - c, b2: (1 - c) / 2, a0: 1 + alpha, a1: -2 * c, a2: 1 - alpha)
    }

    static func peak(_ f0: Double, gain: Double, octaves bw: Double, sampleRate: Double) -> Biquad {
        let A = pow(10, gain / 40)
        let w = 2 * Double.pi * min(f0, sampleRate * 0.49) / sampleRate
        let alpha = sin(w) * sinh(log(2) / 2 * bw * w / sin(w))
        let c = cos(w)
        return Biquad(b0: 1 + alpha * A, b1: -2 * c, b2: 1 - alpha * A,
                      a0: 1 + alpha / A, a1: -2 * c, a2: 1 - alpha / A)
    }

    static func shelf(_ f0: Double, gain: Double, low: Bool, sampleRate: Double) -> Biquad {
        let A = pow(10, gain / 40)
        let w = 2 * Double.pi * min(f0, sampleRate * 0.49) / sampleRate
        let c = cos(w), s = sin(w)
        let alpha = s / 2 * 2.0.squareRoot()          // S = 1
        let r = 2 * A.squareRoot() * alpha
        if low {
            return Biquad(b0: A * ((A + 1) - (A - 1) * c + r), b1: 2 * A * ((A - 1) - (A + 1) * c),
                          b2: A * ((A + 1) - (A - 1) * c - r),
                          a0: (A + 1) + (A - 1) * c + r, a1: -2 * ((A - 1) + (A + 1) * c),
                          a2: (A + 1) + (A - 1) * c - r)
        }
        return Biquad(b0: A * ((A + 1) + (A - 1) * c + r), b1: -2 * A * ((A - 1) + (A + 1) * c),
                      b2: A * ((A + 1) + (A - 1) * c - r),
                      a0: (A + 1) - (A - 1) * c + r, a1: 2 * ((A - 1) - (A + 1) * c),
                      a2: (A + 1) - (A - 1) * c - r)
    }
}
