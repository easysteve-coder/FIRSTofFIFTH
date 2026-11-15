import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import Combine

// MARK: - Audiogeräte (v1.18.7)
//
// Welches Gerät eine laufende Engine tatsächlich benutzt, steht in ihrer Ein-/Ausgabe-Einheit
// (`kAudioOutputUnitProperty_CurrentDevice`), nicht im Systemstandard: der kann sich ändern,
// während die Engine noch am alten Gerät hängt. Nur Main; nichts davon im Render-Pfad.

enum AudioDevices {

    /// Gerät, an dem die Ein- bzw. Ausgabe-Einheit einer Engine gerade hängt.
    static func current(of unit: AudioUnit?) -> AudioDeviceID? {
        guard let unit else { return nil }
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                      kAudioUnitScope_Global, 0, &id, &size)
        return st == noErr && id != kAudioObjectUnknown ? id : nil
    }

    /// Puffer eines Geräts in Sekunden (Rahmengröße / Nennrate, höchstens 100 ms), nil ohne Angabe.
    static func bufferSeconds(_ id: AudioDeviceID, input: Bool) -> Double? {
        var frames = UInt32(0); var fs = UInt32(MemoryLayout<UInt32>.size)
        var fa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                            mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
                                            mElement: kAudioObjectPropertyElementMain)
        var rate = Float64(0); var rs = UInt32(MemoryLayout<Float64>.size)
        var ra = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &fa, 0, nil, &fs, &frames) == noErr,
              AudioObjectGetPropertyData(id, &ra, 0, nil, &rs, &rate) == noErr, rate > 0, frames > 0
        else { return nil }
        return min(Double(frames) / rate, 0.1)
    }

    static func systemDefault(input: Bool) -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return st == noErr && id != kAudioObjectUnknown ? id : nil
    }

    static func name(_ id: AudioDeviceID) -> String? {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr,
              let s = name?.takeRetainedValue() else { return nil }
        return s as String
    }

    /// Kanäle eines Geräts in einer Richtung (Summe aller Streams).
    static func channelCount(_ id: AudioDeviceID, input: Bool) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Latenz + Sicherheitsabstand eines Geräts in einer Richtung (Frames).
    static func latencyFrames(_ id: AudioDeviceID, input: Bool) -> Int {
        let scope = input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
        func read(_ sel: AudioObjectPropertySelector) -> Int {
            var v = UInt32(0); var s = UInt32(MemoryLayout<UInt32>.size)
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            return AudioObjectGetPropertyData(id, &a, 0, nil, &s, &v) == noErr ? Int(v) : 0
        }
        return read(kAudioDevicePropertyLatency) + read(kAudioDevicePropertySafetyOffset)
    }
}

/// Welche Geräte Aufnahme und Wiedergabe gerade benutzen (Anzeige im Spurkopf und im
/// Eingangs-Popover). Eigenes Zustandsobjekt (CLAUDE.md Regel 4): nur die Loop-Zeilen lesen es.
final class AudioDeviceState: ObservableObject {

    struct Endpoint: Equatable {
        /// Die Engine dieser Richtung läuft.
        var running = false
        /// Gerät der laufenden Engine (nil, solange sie nicht läuft).
        var device: String?
        var deviceID: AudioDeviceID?
        /// Kanäle des Geräts in dieser Richtung (laufend: Engineformat, sonst Systemstandard).
        var channels = 0
        var sampleRate: Double = 0
        /// Systemstandard dieser Richtung — wird beim nächsten Start benutzt.
        var systemDefault: String?
        var systemDefaultID: AudioDeviceID?
        /// Fehler beim letzten Start (z. B. kein Zugriff), sonst nil.
        var error: String?

        /// Die laufende Engine hängt an einem anderen Gerät als der aktuelle Systemstandard.
        var differsFromDefault: Bool {
            running && deviceID != nil && systemDefaultID != nil && deviceID != systemDefaultID
        }
    }

    @Published private(set) var input = Endpoint()
    @Published private(set) var output = Endpoint()

    /// Liefert den Ist-Zustand beider Richtungen (vom Besitzer gesetzt).
    var probe: (() -> (input: Endpoint, output: Endpoint))?

    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init() {
        // Systemstandard, Geräteliste: Änderungen kommen auf Main.
        for sel in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice,
                    kAudioHardwarePropertyDevices] {
            var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block) == noErr {
                listeners.append((addr, block))
            }
        }
    }

    deinit {
        for (a, b) in listeners {
            var addr = a
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, b)
        }
    }

    /// Ist-Zustand neu lesen; veröffentlicht nur Änderungen (Main).
    func refresh() {
        guard let p = probe?() else { return }
        if p.input != input { input = p.input }
        if p.output != output { output = p.output }
    }

    /// Zustand einer Richtung aus der Einheit einer (ggf. laufenden) Engine.
    static func endpoint(unit: AudioUnit?, running: Bool, format: AVAudioFormat?, input: Bool,
                         error: String?) -> Endpoint {
        var e = Endpoint()
        e.running = running
        e.error = error
        if let d = AudioDevices.systemDefault(input: input) {
            e.systemDefaultID = d
            e.systemDefault = AudioDevices.name(d)
        }
        if running, let id = AudioDevices.current(of: unit) {
            e.deviceID = id
            e.device = AudioDevices.name(id)
            e.channels = Int(format?.channelCount ?? 0)
            e.sampleRate = format?.sampleRate ?? 0
        } else if let d = e.systemDefaultID {
            e.channels = AudioDevices.channelCount(d, input: input)
        }
        return e
    }
}
