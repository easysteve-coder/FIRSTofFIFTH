import Testing
import Foundation
import AVFoundation
import Atomics
@testable import VintageSequencer

// v1.18.10 — Host-Blöcke dürfen nicht gesetzt werden, während das Plug-in rendert.
// Befund iMac (macOS 12.7.6): AUHostingServiceXPC stürzt in transportStateProc ab, als Odin2
// den Transport-Block aufrief, während FoF ihn beim Wechsel eines Effekts neu setzte.

@MainActor @Suite(.serialized) struct HostBlockSafetyTests {
    static let dls = PluginRef(description: AudioComponentDescription(
        componentType: kAudioUnitType_MusicDevice, componentSubType: kAudioUnitSubType_DLSSynth,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0),
        name: "DLSMusicDevice")
    static let delay = PluginRef(description: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_Delay,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0),
        name: "AUDelay")

    /// Effekte während des Renderns wechseln: das Instrument bekommt keine neuen Blöcke.
    @Test func swappingEffectsDoesNotTouchRenderingInstrument() async throws {
        let rack = InstrumentRack()
        let id = try #require(rack.addChannel(name: "H")); rack.setMuted(id, true)
        rack.setInstrument(Self.dls, for: id)
        var deadline = Date().addingTimeInterval(60)
        while rack.instrumentStatus[id] == .loading, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        try #require(rack.instrumentStatus[id] == .ready)
        try await Task.sleep(nanoseconds: 300_000_000)
        let base = rack._instrumentHostReinstalls(id) ?? 0
        for _ in 0..<4 {
            rack.assignEffect(Self.delay, at: 0, in: id)
            deadline = Date().addingTimeInterval(20)
            while rack.effectStatus[id]?.first == .loading, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        let after = rack._instrumentHostReinstalls(id) ?? 0
        let line = "reinstalls base \(base) after \(after) running \(rack._engineIsRunning) calls \(rack.hostBindingCalls(id).map { "\($0.instrument)" } ?? "-")\n"
        try? line.write(toFile: NSTemporaryDirectory() + "fof-hostblock-safety.txt", atomically: true, encoding: .utf8)
        #expect(after == base, "Host-Blöcke des rendernden Instruments neu gesetzt: \(after - base)×")
    }
}
