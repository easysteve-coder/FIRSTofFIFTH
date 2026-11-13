import Foundation
import CoreAudio
import AppKit
import Combine

// MARK: - AudioDiagnostics

/// Audio-Diagnose (v1.13.14): zeichnet im Betrieb auf, was der Audioweg tut, damit Fehler
/// wie „nach Soundwechsel in Odin 2 kein Ton mehr" belegt statt vermutet werden.
///
/// Eine Datei je Aufzeichnung (JSON Lines) im App-Container:
/// `~/Library/Containers/com.firstoffifth.sequencer/Data/Library/Application Support/
/// FIRSTofFIFTH/Diagnostics/audio-<Zeit>.jsonl`. Jede Zeile ist ein Objekt mit `t`
/// (Sekunden seit Beginn) und `k` (Art):
///   - `start`/`stop`: Kopf mit Version, System, Gerät, Kanälen;
///   - `s`: Messprobe viermal je Sekunde (Engine, Summe, je Kanal, Ausgabegerät);
///   - Ereignisse: `config` (Engine-Konfiguration), `watchdog`/`recovery`, `load`,
///     `restart` (Renderweg neu), `au` (Preset/Parameterbaum/Zustand eines Plug-ins
///     geändert), `invalidated` (Plug-in-Prozess beendet), `device`, `overload`,
///     `play`/`stop`, `mark` (vom Benutzer gesetzt).
///
/// Nur Main-Thread. Der Tick- und Render-Pfad werden nicht berührt; Messwerte kommen aus
/// den Atomics der Mess-Taps (`LevelMeter.takeDiagnostics`). Der Ein-Zustand bleibt über
/// einen Neustart erhalten, damit auch Fehler kurz nach dem Start erfasst werden.
final class AudioDiagnostics: ObservableObject {

    @Published private(set) var isRecording = false
    @Published private(set) var fileURL: URL?
    private var handle: FileHandle?
    private var startedAt = Date()
    private var marks = 0
    private var seq = 0
    /// Schreiben auf eigener serieller Queue; Main serialisiert nur.
    private let io = DispatchQueue(label: "com.firstoffifth.diagnostics", qos: .utility)
    private static let defaultsKey = "audioDiagnosticsOn"

    /// Wird beim Einschalten aufgerufen und liefert den Kopf (Rack: Kanäle, Engine).
    var header: (() -> [String: Any])?
    /// Ein-/Ausschalten (Rack hält den Mess-Timer am Laufen).
    var onRecordingChange: ((Bool) -> Void)?

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("FIRSTofFIFTH/Diagnostics", isDirectory: true)
    }

    /// Beim Programmstart: weiter aufzeichnen, wenn es zuletzt eingeschaltet war.
    func resumeIfEnabled() {
        if UserDefaults.standard.bool(forKey: Self.defaultsKey), !isRecording { start() }
    }

    func toggle() { isRecording ? stop() : start() }

    func start() {
        guard !isRecording else { return }
        let dir = Self.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Self.fileStamp.string(from: Date())
        let url = dir.appendingPathComponent("audio-\(stamp).jsonl")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let h = try? FileHandle(forWritingTo: url) else { return }
        handle = h
        fileURL = url
        startedAt = Date()
        marks = 0
        seq = 0
        isRecording = true
        UserDefaults.standard.set(true, forKey: Self.defaultsKey)
        var head: [String: Any] = [
            "wall": ISO8601DateFormatter().string(from: startedAt),
            "app": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "device": Self.defaultOutputDevice(),
        ]
        header?().forEach { head[$0.key] = $0.value }
        write("start", head)
        startDeviceListeners()
        onRecordingChange?(true)
    }

    func stop() {
        guard isRecording else { return }
        write("stop", ["device": Self.defaultOutputDevice()])
        stopDeviceListeners()
        if let h = handle { io.sync { try? h.close() } }   // alles Ausstehende geschrieben
        handle = nil
        isRecording = false
        UserDefaults.standard.set(false, forKey: Self.defaultsKey)
        onRecordingChange?(false)
    }

    /// Markierung des Benutzers („jetzt Sound gewechselt").
    func mark() {
        guard isRecording else { return }
        marks += 1
        write("mark", ["n": marks])
    }

    /// Ereignis protokollieren (Main). Ohne Aufzeichnung ein No-op.
    func event(_ kind: String, _ fields: [String: Any] = [:]) {
        guard isRecording else { return }
        write(kind, fields)
    }

    func revealInFinder() {
        let dir = Self.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let url = fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        else { NSWorkspace.shared.open(dir) }
    }

    // MARK: Schreiben

    private func write(_ kind: String, _ fields: [String: Any]) {
        guard let handle else { return }
        var obj = fields
        obj["t"] = (Date().timeIntervalSince(startedAt) * 1000).rounded() / 1000
        obj["k"] = kind
        seq += 1
        obj["n"] = seq
        guard JSONSerialization.isValidJSONObject(obj),
              var data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        else { return }
        data.append(0x0A)
        io.async { try? handle.write(contentsOf: data) }
    }

    private static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    /// Werte für JSON: NaN/∞ als Text, Zahlen auf vier Stellen.
    static func num(_ v: Float) -> Any {
        guard v.isFinite else { return v.isNaN ? "nan" : "inf" }
        return (Double(v) * 10_000).rounded() / 10_000
    }

    // MARK: Ausgabegerät (CoreAudio, nur lesen)

    private var deviceListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var overloads = 0

    /// Überlast-Meldungen des Geräts seit der letzten Probe.
    func takeOverloads() -> Int { defer { overloads = 0 }; return overloads }

    private func startDeviceListeners() {
        stopDeviceListeners()
        var defaultAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
        let onDefault: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.event("device", ["now": Self.defaultOutputDevice()])
            self.startDeviceListeners()           // Gerät gewechselt: Listener umhängen
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddr, .main, onDefault) == noErr {
            deviceListeners.append((AudioObjectID(kAudioObjectSystemObject), defaultAddr, onDefault))
        }
        guard let dev = Self.defaultOutputDeviceID() else { return }
        func listen(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
                    _ block: @escaping AudioObjectPropertyListenerBlock) {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                  mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectHasProperty(dev, &addr),
                  AudioObjectAddPropertyListenerBlock(dev, &addr, .main, block) == noErr else { return }
            deviceListeners.append((dev, addr, block))
        }
        listen(kAudioDeviceProcessorOverload, scope: kAudioObjectPropertyScopeGlobal) { [weak self] _, _ in
            self?.overloads += 1
        }
        for (selector, name) in [(kAudioDevicePropertyMute, "mute"),
                                 (kAudioDevicePropertyNominalSampleRate, "sampleRate"),
                                 (kAudioDevicePropertyDeviceIsAlive, "alive"),
                                 (kAudioDevicePropertyDeviceIsRunningSomewhere, "running"),
                                 (kAudioDevicePropertyStreamConfiguration, "streams")] {
            let scope = selector == kAudioDevicePropertyMute || selector == kAudioDevicePropertyStreamConfiguration
                ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeGlobal
            listen(selector, scope: scope) { [weak self] _, _ in
                self?.event("device", ["changed": name, "now": Self.defaultOutputDevice()])
            }
        }
    }

    private func stopDeviceListeners() {
        for (obj, addr, block) in deviceListeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(obj, &a, .main, block)
        }
        deviceListeners.removeAll()
    }

    static func defaultOutputDeviceID() -> AudioObjectID? {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }

    /// Zustand des Standard-Ausgabegeräts: Name, Abtastrate, läuft, lebt, stumm, Lautstärke.
    static func defaultOutputDevice() -> [String: Any] {
        guard let dev = defaultOutputDeviceID() else { return ["id": 0] }
        var out: [String: Any] = ["id": Int(dev)]
        func addr(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
            -> AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        }
        func read<T: BitwiseCopyable>(_ a: AudioObjectPropertyAddress, _ zero: T) -> T? {
            var a = a, v = zero, size = UInt32(MemoryLayout<T>.size)
            guard AudioObjectHasProperty(dev, &a),
                  AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr else { return nil }
            return v
        }
        var nameAddr = addr(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if withUnsafeMutablePointer(to: &name, {
            AudioObjectGetPropertyData(dev, &nameAddr, 0, nil, &nameSize, $0)
        }) == noErr, let name {
            out["name"] = name.takeRetainedValue() as String
        }
        var uidAddr = addr(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if withUnsafeMutablePointer(to: &uid, {
            AudioObjectGetPropertyData(dev, &uidAddr, 0, nil, &uidSize, $0)
        }) == noErr, let uid {
            out["uid"] = uid.takeRetainedValue() as String
        }
        if let sr: Float64 = read(addr(kAudioDevicePropertyNominalSampleRate), 0) { out["sampleRate"] = sr }
        if let r: UInt32 = read(addr(kAudioDevicePropertyDeviceIsRunningSomewhere), 0) { out["running"] = r != 0 }
        if let a: UInt32 = read(addr(kAudioDevicePropertyDeviceIsAlive), 0) { out["alive"] = a != 0 }
        if let m: UInt32 = read(addr(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput), 0) { out["mute"] = m != 0 }
        // 'vmvc' = kAudioHardwareServiceDeviceProperty_VirtualMainVolume (AudioToolbox).
        if let v: Float32 = read(addr(0x766D_7663, kAudioObjectPropertyScopeOutput), 0) { out["volume"] = num(v) }
        if let fs: UInt32 = read(addr(kAudioDevicePropertyBufferFrameSize), 0) { out["bufferFrames"] = Int(fs) }
        return out
    }
}
