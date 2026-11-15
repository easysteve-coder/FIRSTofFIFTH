import Foundation

// MARK: - Zeitangaben für die Anzeige (v1.18.21)
//
// Stephan: „Eine Anzeige wie bei Logic bezüglich Taktart und Position (in Sekunden oder in Beats)
// brauchen wir noch." Reine Rechnung, keine Darstellung (Texte in `Str`). Grundlage: 24 Pulse je
// Viertel; ein Step mit Verhältnis num:den dauert num/den Sechzehntel.

enum TimingInfo {

    /// Musikalische Position wie in Logic: Takt.Schlag.Teil.Tick, jeweils ab 1.
    struct Position: Equatable {
        var bar: Int, beat: Int, division: Int, tick: Int
        /// Ticks je Sechzehntel (Logic: 960 je Viertel).
        static let ticksPerDivision = 240
    }

    /// Position aus Vierteln seit Start in der Taktart `m`. Schlag in Nennereinheiten (6/8:
    /// sechs Achtel), Teil = Sechzehntel im Schlag (bei Nenner 16 immer 1).
    static func position(quarters q: Double, meter m: TimeSignature) -> Position {
        let qpb = m.quartersPerBar
        let k = (max(0, q) / qpb + 1e-9).rounded(.down)
        return position(bar: Int(k), quartersIntoBar: max(0, q) - k * qpb, meter: m)
    }

    /// Position aus absolutem Takt (0 = erster) und Vierteln seit dessen Beginn — so liefert sie
    /// `HostSync.State` (Takt ab dem Ursprung des Abschnitts, v1.18.23).
    static func position(bar: Int, quartersIntoBar q: Double, meter m: TimeSignature) -> Position {
        let sixteenths = max(0, q * 4) + 1e-9                  // Rundungsrest nicht in den Vortick
        let perBar = m.sixteenthsPerBar, perBeat = m.sixteenthsPerBeat
        let whole = min(Int(sixteenths.rounded(.down)), perBar - 1)
        let tick = Int(((sixteenths - Double(whole)) * Double(Position.ticksPerDivision)).rounded(.down))
        return Position(bar: max(0, bar) + 1, beat: whole / perBeat + 1,
                        division: whole % perBeat + 1, tick: min(tick, Position.ticksPerDivision - 1) + 1)
    }

    /// Ganze Takte bis zum Wechselpuls `at` ab Puls `now` (aufgerundet) in Takten zu `ppb`
    /// Pulsen; nil ohne geplanten Puls.
    static func barsUntil(pulse at: Int, from now: Double, pulsesPerBar ppb: Double) -> Int? {
        guard at >= 0, ppb > 0 else { return nil }
        return max(0, Int(((Double(at) - now) / ppb - 1e-9).rounded(.up)))
    }

    /// Laufzeit h:mm:ss.mmm.
    static func clock(seconds: Double) -> (h: Int, m: Int, s: Int, ms: Int) {
        let total = Int((max(0, seconds) * 1000).rounded(.down))
        return (total / 3_600_000, total / 60_000 % 60, total / 1000 % 60, total % 1000)
    }

    /// Dauer eines Steps mit Verhältnis num:den (zur Sechzehntel) bei `bpm`, in Sekunden.
    static func stepSeconds(num: Int, den: Int, bpm: Double) -> Double {
        guard bpm > 0, den > 0 else { return 0 }
        return 15.0 / bpm * Double(num) / Double(den)
    }

    /// Notenwert eines Steps als gekürzter Bruch einer ganzen Note: num:den → num / (16 · den).
    static func noteValue(num: Int, den: Int) -> (num: Int, den: Int) {
        let n = max(1, num), d = 16 * max(1, den), g = gcd(n, d)
        return (n / g, d / g)
    }

    /// Länge einer Spur: Steps · num/den Sechzehntel, als gekürzter Bruch von Sechzehnteln.
    static func spanSixteenths(steps: Int, num: Int, den: Int) -> (num: Int, den: Int) {
        let n = max(0, steps) * max(1, num), d = max(1, den), g = max(1, gcd(n, d))
        return (n / g, d / g)
    }

    /// Ganzzahlige Länge zerlegt in Takte, Schläge und Sechzehntel der Taktart (nil = gebrochen).
    static func split(sixteenths s: (num: Int, den: Int), meter m: TimeSignature)
        -> (bars: Int, beats: Int, sixteenths: Int)? {
        guard s.den == 1 else { return nil }
        let n = s.num, bar = m.sixteenthsPerBar, beat = m.sixteenthsPerBeat
        return (n / bar, n % bar / beat, n % beat)
    }

    static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? abs(a) : gcd(b, a % b) }
}
