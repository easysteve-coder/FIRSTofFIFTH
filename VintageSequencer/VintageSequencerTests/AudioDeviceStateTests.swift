import Testing
import Foundation
import AVFoundation
import CoreAudio
@testable import VintageSequencer

// v1.18.7 — Geräteanzeige: angezeigt wird das Gerät der laufenden Engine, nicht der
// Systemstandard; ohne laufende Engine nur der Hinweis „aus" mit dem Standard als künftigem Gerät.

@MainActor @Suite(.serialized) struct AudioDeviceStateTests {

    @Test func stoppedEndpointNamesNoActiveDevice() {
        let e = AudioDeviceState.endpoint(unit: nil, running: false, format: nil, input: false, error: nil)
        #expect(!e.running)
        #expect(e.device == nil && e.deviceID == nil)
        #expect(!e.differsFromDefault)
        if let d = AudioDevices.systemDefault(input: false) {
            #expect(e.systemDefaultID == d)
            #expect(e.systemDefault == AudioDevices.name(d))
        }
    }

    /// Laufende Ausgabe: Gerät aus der Einheit der Engine, Format aus der Engine.
    @Test func runningOutputReportsEngineDevice() throws {
        guard AudioDevices.systemDefault(input: false) != nil else { return }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = 0
        try engine.start()
        defer { engine.stop() }
        let fmt = engine.outputNode.outputFormat(forBus: 0)
        let e = AudioDeviceState.endpoint(unit: engine.outputNode.audioUnit, running: true,
                                          format: fmt, input: false, error: nil)
        let id = try #require(e.deviceID)
        #expect(id == AudioDevices.current(of: engine.outputNode.audioUnit))
        #expect(e.device == AudioDevices.name(id))
        #expect(e.channels == Int(fmt.channelCount))
        #expect(e.sampleRate == fmt.sampleRate)
        // Gleich dem Standard, solange niemand umschaltet.
        #expect(e.differsFromDefault == (id != e.systemDefaultID))
    }

    @Test func differsOnlyWhileRunningOnAnotherDevice() {
        var e = AudioDeviceState.Endpoint()
        e.running = true; e.deviceID = 10; e.systemDefaultID = 11
        #expect(e.differsFromDefault)
        e.systemDefaultID = 10
        #expect(!e.differsFromDefault)
        e.running = false; e.systemDefaultID = 11
        #expect(!e.differsFromDefault)
    }

    /// Das Rack meldet den Ausgang, sobald seine Engine läuft (Loop-Kanal startet sie).
    @Test func rackPublishesOutputAfterStart() async throws {
        guard AudioDevices.systemDefault(input: false) != nil else { return }
        let rack = InstrumentRack()
        #expect(!rack.loops.devices.output.running)
        let id = try #require(rack.addAudioLoopChannel(name: "L"))
        rack.setMuted(id, true)
        try await Task.sleep(nanoseconds: 200_000_000)
        let out = rack.loops.devices.output
        #expect(out.running == rack._engineIsRunning)
        if out.running { #expect(out.device != nil) }
        #expect(!rack.loops.devices.input.running)          // Eingang erst beim Scharfschalten
        rack.removeChannel(id)
        #expect(!rack.loops.devices.output.running)
    }

    @Test func channelStrings() {
        let s = Str("de")
        #expect(s.loopChannelSelection(0, stereo: false) == "Kanal 1 · Mono")
        #expect(s.loopChannelSelection(2, stereo: true) == "Kanäle 3–4 · Stereo")
        #expect(s.deviceFormat(channels: 2, sampleRate: 48_000) == "2 Kan. · 48 kHz")
        #expect(s.deviceFormat(channels: 1, sampleRate: 44_100) == "1 Kan. · 44.1 kHz")
    }
}
