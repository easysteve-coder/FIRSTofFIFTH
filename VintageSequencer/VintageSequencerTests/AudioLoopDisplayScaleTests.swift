import Testing
import Foundation
import CoreGraphics
@testable import VintageSequencer

struct AudioLoopDisplayScaleTests {
    typealias B = AudioLoopDisplay.WaveBucket

    @Test func quietMaterialFillsTheHeight() {
        let wave = [B(lo: -0.05, hi: 0.1), B(lo: -0.01, hi: 0.01)]
        let g = WaveformScale.gain(for: wave)
        #expect(abs(g - 10) < 0.001)
        #expect(abs(WaveformScale.height(0.1, gain: g) - 1) < 0.0001)
        // Leise Stelle (−20 dB unter der Spitze) wird auf ~0,32 statt 0,1 angehoben.
        #expect(abs(WaveformScale.height(0.01, gain: g) - 0.316) < 0.01)
        #expect(WaveformScale.height(-0.05, gain: g) < 0)
    }

    @Test func gainIsCappedAndSilenceStaysFlat() {
        #expect(WaveformScale.gain(for: [B(lo: -0.001, hi: 0.001)]) == WaveformScale.maxGain)
        #expect(WaveformScale.gain(for: [B(lo: 0, hi: 0)]) == 1)
        #expect(WaveformScale.height(0, gain: 64) == 0)
        #expect(WaveformScale.gain(for: [B(lo: -1, hi: 1)]) == 1)
    }

    @Test func meterRisesInstantlyFallsAndHolds() {
        let m = InputMeterBallistics()
        var r = m.step(peak: 1.0, at: 0)
        #expect(r.level == 0 && r.hold == 0)
        r = m.step(peak: 0, at: 1.0)          // 1 s später: −24 dB, Spitze gehalten
        #expect(abs(r.level + 24) < 0.01 && r.hold == 0)
        r = m.step(peak: 0.1, at: 2.0)         // nach 1,5 s Halter neu: −20 dB
        #expect(abs(r.hold + 20) < 0.01)
        #expect(InputMeterBallistics.position(-60) == 0 && InputMeterBallistics.position(0) == 1)
    }
}
