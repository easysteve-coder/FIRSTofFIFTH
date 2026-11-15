import Testing
import Foundation
import AVFoundation
import Atomics
@testable import VintageSequencer

// v1.18.10 — Laden während der Wiedergabe ohne Aussetzer (Stephan: „wenn ich eine audiospur
// erzeuge oder ein AU Plugin während der wiedergabe lade, stockt die wiedergabe"). Gemessen:
// Engine-Starts und Lücken im Audiostrom eines laufenden Kanals (Sample-Zeit der Tap-Puffer).

@MainActor @Suite(.serialized) struct GlitchFreeLoadTests {
    static let dls = PluginRef(description: AudioComponentDescription(
        componentType: kAudioUnitType_MusicDevice, componentSubType: kAudioUnitSubType_DLSSynth,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0),
        name: "DLSMusicDevice")
    static let delay = PluginRef(description: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_Delay,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0),
        name: "AUDelay")

    final class Stream { var times: [(Double, Int)] = [] }

    func wait(_ rack: InstrumentRack, _ id: UUID) async throws {
        let deadline = Date().addingTimeInterval(30)
        while (rack.instrumentStatus[id] == .loading || (rack.effectStatus[id] ?? []).contains(.loading)),
              Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
    }

    @Test func loadingDuringPlaybackKeepsAudioRunning() async throws {
        let rack = InstrumentRack()
        let a = try #require(rack.addChannel(name: "A")); rack.setMuted(a, true)
        rack.setInstrument(Self.dls, for: a)
        try await wait(rack, a)
        try #require(rack.instrumentStatus[a] == .ready)
        // Unbeteiligter Kanal: sein Strom muss lückenlos bleiben.
        let c = try #require(rack.addChannel(name: "C")); rack.setMuted(c, true)
        rack.setInstrument(Self.dls, for: c)
        try await wait(rack, c)
        guard rack._engineIsRunning else { return }
        try await Task.sleep(nanoseconds: 300_000_000)
        let gain = try #require(rack._liveGain(c))
        let st = Stream()
        gain.installTap(onBus: 0, bufferSize: 512, format: nil) { b, when in
            let t = when.sampleTime, n = Int(b.frameLength)
            DispatchQueue.main.async { st.times.append((Double(t), n)) }
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let starts0 = rack._engineStarts

        // 1. Effekt auf A, 2. neuer Instrumentkanal, 3. Audio-Loop-Kanal, 4. Effekt tauschen.
        rack.addEffect(Self.delay, to: a); try await wait(rack, a)
        let b = try #require(rack.addChannel(name: "B")); rack.setMuted(b, true)
        rack.setInstrument(Self.dls, for: b); try await wait(rack, b)
        let loop = try #require(rack.addAudioLoopChannel(name: "L")); rack.setMuted(loop, true)
        rack.assignEffect(Self.delay, at: 0, in: a); try await wait(rack, a)
        try await Task.sleep(nanoseconds: 400_000_000)
        gain.removeTap(onBus: 0)

        let restarts = rack._engineStarts - starts0
        var gaps = 0
        for i in 1..<st.times.count {
            let (t0, n0) = st.times[i - 1], (t1, _) = st.times[i]
            if abs(t1 - (t0 + Double(n0))) > 1 { gaps += 1 }
        }
        let qb = rack.queue(rack.route(for: b))
        #expect(restarts == 0, "Engine neu gestartet: \(restarts)×")
        #expect(gaps == 0, "Lücken im Audiostrom: \(gaps)")
        #expect(qb.preRenders.load(ordering: .relaxed) > 0, "neues Instrument rendert nicht")
        #expect(rack.effectStatus[a] == [.ready])
        #expect(rack._allocation(b) == "inst 1 gain 1 mix 1")
        #expect(rack._allocation(loop) == "inst n gain 1 mix 1", "Loop-Kanal hängt nicht im Renderweg")
    }
}
