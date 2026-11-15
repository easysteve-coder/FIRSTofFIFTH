import Testing
import Foundation
import AVFoundation
@testable import VintageSequencer

// v1.18.11 — Kanal-EQ: die angezeigte Kurve muss dem entsprechen, was die Einheit tatsächlich
// rendert (Offline-Render mit Sinus, Pegel nach dem Einschwingen).

@MainActor @Suite(.serialized) struct ChannelEQTests {
    static let rate = 48_000.0

    /// Gemessener Gewinn (dB) eines Sinus bei `freq` durch eine Einheit mit `eq`.
    static func measure(_ eq: ChannelEQ, at freq: Double) throws -> Double {
        let f = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let e = AVAudioEngine()
        try e.enableManualRenderingMode(.offline, format: f, maximumFrameCount: 4096)
        var phase = 0.0
        let src = AVAudioSourceNode(format: f) { _, _, n, abl in
            let p = UnsafeMutableAudioBufferListPointer(abl)[0].mData!.assumingMemoryBound(to: Float.self)
            for i in 0..<Int(n) { p[i] = Float(sin(phase)); phase += 2 * .pi * freq / rate }
            return noErr
        }
        let unit = AVAudioUnitEQ(numberOfBands: ChannelEQ.unitBandCount)
        InstrumentRack.apply(eq, to: unit)
        e.attach(src); e.attach(unit)
        e.connect(src, to: unit, format: f); e.connect(unit, to: e.mainMixerNode, format: f)
        try e.start()
        defer { e.stop() }
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: f, frameCapacity: 4096))
        var sum = 0.0, n = 0
        for k in 0..<24 {
            _ = try e.renderOffline(4096, to: buf)
            guard k >= 8, let d = buf.floatChannelData?[0] else { continue }
            for i in 0..<Int(buf.frameLength) { sum += Double(d[i] * d[i]) }
            n += Int(buf.frameLength)
        }
        return 10 * log10(sum / Double(n) / 0.5)
    }

    static func only(_ index: Int, _ change: (inout ChannelEQ.Band) -> Void) -> ChannelEQ {
        var eq = ChannelEQ()
        for i in eq.bands.indices { eq.bands[i].isOn = false }
        eq.bands[index].isOn = true
        change(&eq.bands[index])
        return eq
    }

    static let freqs: [Double] = [40, 100, 300, 700, 1000, 1500, 3000, 8000, 15000]

    func check(_ eq: ChannelEQ, tolerance: Double = 0.3, floor: Double = -60) throws {
        for f in Self.freqs {
            let model = eq.response(at: f, sampleRate: Self.rate)
            guard model > floor else { continue }
            let real = try Self.measure(eq, at: f)
            #expect(abs(real - model) < tolerance, "\(f) Hz: Einheit \(real) dB, Kurve \(model) dB")
        }
    }

    @Test func neutralIsTransparent() throws {
        let eq = ChannelEQ()
        #expect(eq.isNeutral)
        #expect(abs(try Self.measure(eq, at: 1000)) < 0.01)
    }

    @Test func bellMatchesUnit() throws {
        try check(Self.only(3) { $0.frequency = 1000; $0.gain = 12; $0.q = 1.4 })
        try check(Self.only(4) { $0.frequency = 3000; $0.gain = -9; $0.q = 4 })
        try check(Self.only(2) { $0.frequency = 300; $0.gain = 6; $0.q = 0.3 })
    }

    @Test func shelvesMatchUnit() throws {
        try check(Self.only(1) { $0.frequency = 200; $0.gain = 10 })
        try check(Self.only(6) { $0.frequency = 5000; $0.gain = -8 })
    }

    @Test func cutsMatchUnitAndHitMinus3dB() throws {
        for slope in ChannelEQ.slopes {
            let lc = Self.only(0) { $0.frequency = 700; $0.slope = slope }
            try check(lc, tolerance: 0.4)
            #expect(abs(lc.response(at: 700, sampleRate: Self.rate) + 3.01) < 0.05)
            let hc = Self.only(7) { $0.frequency = 3000; $0.slope = slope }
            try check(hc, tolerance: 0.4)
            // Tiefpass: Frequenzverzerrung des digitalen Filters verschiebt die Summe leicht.
            #expect(abs(hc.response(at: 3000, sampleRate: Self.rate) + 3.01) < 0.25)
        }
        // Steilheit: drei Oktaven unter der Ecke bei 48 dB/Okt. weit tiefer als bei 12.
        let soft = Self.only(0) { $0.frequency = 1000; $0.slope = 12 }
        let steep = Self.only(0) { $0.frequency = 1000; $0.slope = 48 }
        #expect(steep.response(at: 125, sampleRate: Self.rate) < soft.response(at: 125, sampleRate: Self.rate) - 50)
    }

    @Test func combinedMatchesUnit() throws {
        var eq = ChannelEQ()
        eq.bands[0].isOn = true; eq.bands[0].frequency = 40; eq.bands[0].slope = 24
        eq.bands[1].gain = 4
        eq.bands[3].gain = -6; eq.bands[3].q = 2
        eq.bands[5].gain = 5
        eq.bands[6].gain = -3
        try check(eq, tolerance: 0.5)
        var off = eq; off.isOn = false
        #expect(off.isNeutral)
        #expect(abs(try Self.measure(off, at: 1000)) < 0.01)
    }

    @Test func codingIsAdditiveAndClamped() throws {
        var ch = InstrumentChannelData(name: "K")
        let plain = try JSONEncoder().encode(ch)
        #expect(!(String(data: plain, encoding: .utf8) ?? "").contains("\"eq\""), "Grundeinstellung wird nicht geschrieben")
        ch.eq.bands[2].gain = 7.5
        ch.eq.bands[0].isOn = true; ch.eq.bands[0].slope = 48
        let back = try JSONDecoder().decode(InstrumentChannelData.self, from: JSONEncoder().encode(ch))
        #expect(back.eq == ch.eq)
        // Fremde Werte werden begrenzt, falsche Bänder ersetzt.
        var bad = ch
        bad.eq.bands[2].gain = 99; bad.eq.bands[0].slope = 7; bad.eq.bands[4].frequency = 1
        bad.clampToValidRanges()
        #expect(bad.eq.bands[2].gain == ChannelEQ.maxGain)
        #expect(bad.eq.bands[0].slope == 24)
        #expect(bad.eq.bands[4].frequency == ChannelEQ.minFrequency)
        bad.eq.bands.removeLast(); bad.clampToValidRanges()
        #expect(bad.eq.bands == ChannelEQ.defaultBands)
    }

    /// Der Rack setzt den EQ in die Gain-Stufe des Kanals, ohne den Fader zu berühren.
    @Test func rackAppliesToGainStage() throws {
        let rack = InstrumentRack()
        let id = try #require(rack.addChannel(name: "E"))
        rack.setVolume(id, 0.5)
        var eq = ChannelEQ(); eq.bands[3].gain = 6
        rack.setEQ(eq, for: id)
        let unit = try #require(rack._liveGain(id) as? AVAudioUnitEQ)
        #expect(unit.bands.count == ChannelEQ.unitBandCount)
        let bell = unit.bands[4 + 1 + 1]                 // Low Cut (4), Low Shelf, Glocke 1, Glocke 2
        #expect(!bell.bypass && bell.gain == 6 && bell.filterType == .parametric)
        #expect(abs(unit.globalGain - InstrumentRack.decibels(0.5)) < 0.001)
        rack.setEQBandOn(false, band: 3, for: id)
        #expect(bell.bypass)
        rack.setEQOn(false, for: id)
        #expect(unit.bands.allSatisfy { $0.bypass })
        rack.removeChannel(id)
    }

    @Test func labels() {
        let de = Str("de"), en = Str("en")
        #expect(de.eqFrequency(80) == "80 Hz")
        #expect(de.eqFrequency(2500) == "2,50 kHz")
        #expect(en.eqFrequency(12000) == "12.0 kHz")
        #expect(de.eqGain(4.5) == "+4,5 dB")
        #expect(de.eqGain(-3) == "−3,0 dB")
        #expect(de.eqGain(0) == "0,0 dB")
        #expect(en.eqQ(0.71) == "Q 0.71")
        #expect(de.eqSlope(24) == "24 dB/Okt.")
    }
}
