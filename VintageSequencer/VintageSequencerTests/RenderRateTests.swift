import Testing
import Foundation
import AVFoundation
import Atomics
@testable import VintageSequencer

// v1.18.9 — Abtastrate des Instruments je Kanal: ein Sampler mit grober eigener Umrechnung
// (Decent Sampler, gemessen −35,7 dB) rendert auf der Rate seiner Samples; die Engine rechnet um.

@MainActor @Suite(.serialized) struct RenderRateTests {

    @Test func keyIsOptionalAndValidated() throws {
        var c = InstrumentChannelData(name: "K")
        let plain = try JSONEncoder().encode(c)
        #expect(!String(decoding: plain, as: UTF8.self).contains("renderRate"))
        #expect(try JSONDecoder().decode(InstrumentChannelData.self, from: plain).renderRate == nil)
        c.renderRate = 44_100
        let set = try JSONDecoder().decode(InstrumentChannelData.self, from: JSONEncoder().encode(c))
        #expect(set.renderRate == 44_100)
        c.renderRate = 12_345; c.clampToValidRanges()
        #expect(c.renderRate == nil)
    }

    /// Echtes Instrument: rendert nach dem Umstellen mit 44,1 kHz, rendert weiter, zurück auf Gerät.
    @Test func instrumentRendersAtChosenRate() async throws {
        let rack = InstrumentRack()
        let id = try #require(rack.addChannel(name: "R")); rack.setMuted(id, true)
        let dls = PluginRef(description: AudioComponentDescription(
            componentType: kAudioUnitType_MusicDevice, componentSubType: kAudioUnitSubType_DLSSynth,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0),
            name: "DLSMusicDevice")
        rack.setInstrument(dls, for: id)
        let deadline = Date().addingTimeInterval(60)
        while rack.instrumentStatus[id] == .loading, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        try #require(rack.instrumentStatus[id] == .ready, "DLS nicht ladbar")
        guard rack._engineIsRunning, let device = rack.outputSampleRate else { return }
        let other = device == 44_100 ? 48_000.0 : 44_100.0
        rack.setRenderRate(other, for: id)
        #expect(rack.channel(id)?.renderRate == other)
        #expect(rack.instrumentRenderRate(id) == other)
        #expect(rack._engineIsRunning)
        let q = rack.queue(rack.route(for: id))
        let before = q.preRenders.load(ordering: .relaxed)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(q.preRenders.load(ordering: .relaxed) > before, "Instrument rendert nach dem Umstellen nicht")
        rack.setRenderRate(nil, for: id)
        #expect(rack.instrumentRenderRate(id) == device)
    }
}
