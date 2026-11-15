import Testing
import Foundation
@testable import VintageSequencer

// v1.18.21 — Positionsanzeige und Spurangaben (Konzept Taktart und Zeit, Paket 1).

@Suite struct TimingInfoTests {
    typealias P = TimingInfo.Position
    let common = TimeSignature.common
    let sevenEight = TimeSignature(numerator: 7, denominator: 8)
    let sixEight = TimeSignature(numerator: 6, denominator: 8)

    @Test func startIsOneOneOneOne() {
        #expect(TimingInfo.position(quarters: 0, meter: common) == P(bar: 1, beat: 1, division: 1, tick: 1))
    }

    @Test func fourFour() {
        // Viertel 5,25 = Takt 2, Schlag 2, zweite Sechzehntel.
        #expect(TimingInfo.position(quarters: 5.25, meter: common) == P(bar: 2, beat: 2, division: 2, tick: 1))
        // Halbe Sechzehntel weiter: Tick 121.
        #expect(TimingInfo.position(quarters: 5.25 + 0.125, meter: common) == P(bar: 2, beat: 2, division: 2, tick: 121))
        // Letzter Tick vor dem Takt.
        #expect(TimingInfo.position(quarters: 4 - 1e-6, meter: common).bar == 1)
        #expect(TimingInfo.position(quarters: 4, meter: common) == P(bar: 2, beat: 1, division: 1, tick: 1))
    }

    /// 7/8: Schlag in Achteln (1–7), Teil = Sechzehntel im Achtel (1–2); Takt = 3,5 Viertel.
    @Test func sevenEightCountsEighths() {
        #expect(TimingInfo.position(quarters: 3.5, meter: sevenEight) == P(bar: 2, beat: 1, division: 1, tick: 1))
        #expect(TimingInfo.position(quarters: 3.0 + 0.25, meter: sevenEight) == P(bar: 1, beat: 7, division: 2, tick: 1))
    }

    /// 6/8: sechs Achtel (Entscheidung E5).
    @Test func sixEightSixBeats() {
        #expect(TimingInfo.position(quarters: 2.5, meter: sixEight) == P(bar: 1, beat: 6, division: 1, tick: 1))
        #expect(TimingInfo.position(quarters: 3.0, meter: sixEight).bar == 2)
    }

    /// Nenner 16: Teil ist immer 1.
    @Test func sixteenthDenominator() {
        let m = TimeSignature(numerator: 15, denominator: 16)
        for k in 0..<30 { #expect(TimingInfo.position(quarters: Double(k) / 4, meter: m).division == 1) }
        #expect(TimingInfo.position(quarters: 15.0 / 4, meter: m) == P(bar: 2, beat: 1, division: 1, tick: 1))
    }

    @Test func clockFormat() {
        let c = TimingInfo.clock(seconds: 3723.4567)
        #expect(c.h == 1 && c.m == 2 && c.s == 3 && c.ms == 456)
        #expect(TimingInfo.clock(seconds: -1).ms == 0)
    }

    /// Dauer: 120 BPM, Sechzehntel 125 ms (wie `StepTimingTests` mit echter Clock gemessen).
    @Test func stepDurations() {
        #expect(abs(TimingInfo.stepSeconds(num: 1, den: 1, bpm: 120) - 0.125) < 1e-12)
        #expect(abs(TimingInfo.stepSeconds(num: 1, den: 2, bpm: 120) - 0.0625) < 1e-12)
        #expect(abs(TimingInfo.stepSeconds(num: 2, den: 3, bpm: 120) - 0.25 / 3) < 1e-12)
        #expect(abs(TimingInfo.stepSeconds(num: 16, den: 1, bpm: 120) - 2.0) < 1e-12)
    }

    @Test func noteValues() {
        #expect(TimingInfo.noteValue(num: 1, den: 1) == (1, 16))
        #expect(TimingInfo.noteValue(num: 2, den: 1) == (1, 8))
        #expect(TimingInfo.noteValue(num: 1, den: 2) == (1, 32))
        #expect(TimingInfo.noteValue(num: 2, den: 3) == (1, 24))       // Sechzehnteltriole
        #expect(TimingInfo.noteValue(num: 4, den: 3) == (1, 12))       // Achteltriole
        #expect(TimingInfo.noteValue(num: 3, den: 2) == (3, 32))       // punktierte Sechzehntel
        #expect(TimingInfo.noteValue(num: 16, den: 1) == (1, 1))       // Pad: ganzer Takt 4/4
    }

    @Test func spans() {
        #expect(TimingInfo.spanSixteenths(steps: 16, num: 1, den: 1) == (16, 1))
        #expect(TimingInfo.spanSixteenths(steps: 15, num: 2, den: 3) == (10, 1))
        #expect(TimingInfo.spanSixteenths(steps: 5, num: 2, den: 3) == (10, 3))
        #expect(TimingInfo.split(sixteenths: (16, 1), meter: common)! == (1, 0, 0))
        #expect(TimingInfo.split(sixteenths: (21, 1), meter: common)! == (1, 1, 1))
        #expect(TimingInfo.split(sixteenths: (14, 1), meter: sevenEight)! == (1, 0, 0))
        #expect(TimingInfo.split(sixteenths: (10, 3), meter: common) == nil)
        let s = Str("de")
        #expect(s.span((21, 1), meter: common) == "1 T 1 Sl. 1/16")
        #expect(s.span((10, 3), meter: common) == "10/48")
    }

    /// Anzeige gegen HostSync: Anker auf geplanten Ausgabezeiten, Abfrage zur jeweiligen Zeit
    /// liefert genau die Position dieses Pulses (kein zweiter Vorlaufabzug, Codex KT-04).
    @Test func positionFromHostSyncAnchors() {
        let h = HostSync()
        h.beginSession(1, meter: sevenEight)
        let t0: UInt64 = 1_000_000_000
        let perPulse = UInt64(h.ticksPerSecond * 60 / 120 / 24)     // 120 BPM
        for p in 0..<200 { h.publish(pulse: p, host: t0 + UInt64(p) * perPulse, bpm: 120) }
        let m = h.meter
        let meter = TimeSignature(numerator: m.numerator, denominator: m.denominator)
        #expect(meter == sevenEight)
        // Puls 84 = Beginn Takt 2 in 7/8; Puls 96 = 16 Sechzehntel = Takt 2, zweites Achtel.
        let at84 = h.state(at: t0 + 84 * perPulse)
        #expect(TimingInfo.position(quarters: at84.beat, meter: meter) == P(bar: 2, beat: 1, division: 1, tick: 1))
        let at96 = h.state(at: t0 + 96 * perPulse)
        #expect(TimingInfo.position(quarters: at96.beat, meter: meter) == P(bar: 2, beat: 2, division: 1, tick: 1))
        #expect(abs(at96.seconds - 2.0) < 1e-3)                      // 96 Pulse = 4 Viertel = 2 s
        // Vor dem ersten Anker: Start.
        #expect(TimingInfo.position(quarters: h.state(at: t0 - 1000).beat, meter: meter).bar == 1)
        // Nach Stop: Position bleibt am Ende stehen.
        h.stop(at: t0 + 120 * perPulse, session: 1)
        let late = h.state(at: t0 + 190 * perPulse)
        #expect(!late.moving)
        #expect(abs(late.beat - 5.0) < 1e-6)
    }
}
