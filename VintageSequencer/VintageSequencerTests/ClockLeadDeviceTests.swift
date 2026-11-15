import Testing
import Foundation
import CoreAudio
@testable import VintageSequencer

// v1.18.15 — Clock-Vorlauf vom Gerät, an dem die Audio-Engine hängt, nicht vom Systemstandard.

@Suite(.serialized) struct ClockLeadDeviceTests {

    /// Ohne laufende Engine: Puffer des Standardgeräts (dort startet die Engine).
    @MainActor @Test func idleUsesSystemDefault() {
        let engine = SequencerEngine()
        let expected = AudioDevices.systemDefault(input: false).flatMap { AudioDevices.bufferSeconds($0, input: false) }
            ?? 512.0 / 48_000
        #expect(!engine.rack.isAudioRunning)
        #expect(engine.rack.outputBufferSeconds == expected)
        #expect(engine.rack.outputBufferSeconds > 0 && engine.rack.outputBufferSeconds <= 0.1)
    }

    /// Geräteangabe begrenzt auf 100 ms; unbekanntes Gerät liefert nichts.
    @Test func bufferSecondsOfUnknownDevice() {
        #expect(AudioDevices.bufferSeconds(AudioDeviceID(0xFFFF_FF00), input: false) == nil)
    }
}
