import AVFoundation
import CoreAudio

// MARK: - AudioInputEngine (v1.15.0)
//
// Eigene AVAudioEngine nur für den Eingang: Eingang → Senke, die jeden Block an die
// Loop-Kerne reicht. Getrennt von der Ausgabe-Engine des Racks, weil AVAudioEngine auf macOS
// Ein- und Ausgang in einer Geräteeinheit koppelt (Erfahrung aus lOOper 0.4.7): ein Problem
// des Eingangs darf die Instrumente nicht stummschalten. Läuft nur, solange eine Spur scharf
// ist oder mithört — sonst ist das Mikrofon aus.
//
// Zeitbezug über Host-Zeitstempel (Taktanker), daher geräteübergreifend gültig. Gleiche
// Abtastrate von Ein- und Ausgang ist Voraussetzung für die Aufnahme (der Kern prüft das).

final class AudioInputEngine {

    private var engine: AVAudioEngine?
    private let cores: UnsafeMutablePointer<Unmanaged<AudioLoopCore>>
    private let coreCount: Int
    private static let maxInputChannels = 64
    private let channelPointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
        .allocate(capacity: AudioInputEngine.maxInputChannels)

    /// Läuft die Engine tatsächlich (nicht nur „gestartet")?
    var isRunning: Bool { engine?.isRunning ?? false }
    /// Eingabe-Einheit der laufenden Engine (Gerät: `AudioDevices.current`), nil ohne Engine.
    var inputUnit: AudioUnit? { engine?.inputNode.audioUnit }
    /// Format des laufenden Eingangs.
    var format: AVAudioFormat? { engine.map { $0.inputNode.outputFormat(forBus: 0) } }
    /// Auftragsnummer (v1.15.1, Codex H10): jeder Start-/Stoppwunsch erhöht sie; verspätete
    /// Abschlüsse der Mikrofonfreigabe mit älterer Nummer werden verworfen.
    private var generation = 0
    private var configObserver: NSObjectProtocol?
    /// Main: Eingang wurde nach einer Geräte-/Formatänderung neu gestartet (oder ist
    /// ausgefallen) — Rack aktualisiert Latenz und Fehlerstatus.
    var onRestart: ((Bool) -> Void)?
    private(set) var lastError: String?
    /// Eingangsformat des laufenden Geräts (Kanalzahl für die Auswahl im Spurkopf).
    private(set) var channelCount = 0
    private(set) var sampleRate: Double = 0
    /// Latenz des Eingangsgeräts in Frames (Gerätelatenz + Sicherheitsabstand).
    private(set) var latencyFrames = 0

    init(cores: UnsafeMutablePointer<Unmanaged<AudioLoopCore>>, count: Int) {
        self.cores = cores; self.coreCount = count
        channelPointers.initialize(repeating: nil, count: Self.maxInputChannels)
    }

    deinit {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        engine?.stop()
        channelPointers.deallocate()
    }

    /// Startet den Eingang (Main). Fragt bei Bedarf nach der Mikrofonfreigabe; `done` meldet,
    /// ob der Eingang läuft. `stillNeeded` wird nach einer verzögerten Freigabe erneut gefragt:
    /// ist der Bedarf inzwischen weg (oder kam ein neuer Auftrag), startet nichts.
    func start(stillNeeded: @escaping () -> Bool = { true }, done: @escaping (Bool) -> Void) {
        guard !isRunning else { done(true); return }
        if engine != nil { stop() }   // stehengebliebene Engine verwerfen
        generation &+= 1
        let gen = generation
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            done(startEngine())
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { [weak self] in
                    guard let self, gen == self.generation, !self.isRunning, stillNeeded() else { return }
                    done(granted ? self.startEngine() : self.fail("denied"))
                }
            }
        default:
            done(fail("denied"))
        }
    }

    func stop() {
        generation &+= 1   // ausstehende Freigabe-Abschlüsse entwerten
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        guard let e = engine else { return }
        e.stop()
        engine = nil
    }

    private func fail(_ reason: String) -> Bool { lastError = reason; return false }

    /// Geräte-/Formatwechsel: die Engine hat angehalten. Neu aufbauen (neues Format, neue
    /// Latenz) und dem Rack melden (Codex H6).
    private func handleConfigurationChange() {
        guard engine != nil else { return }
        stop()
        let ok = startEngine()
        onRestart?(ok)
    }

    private func startEngine() -> Bool {
        let e = AVAudioEngine()
        let input = e.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { return fail("noInput") }
        let cores = cores, count = coreCount, ptrs = channelPointers
        let maxCh = Self.maxInputChannels
        let sr = format.sampleRate
        let sink = AVAudioSinkNode { timestamp, frameCount, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
            // Nicht verschachtelt: ein Puffer je Kanal (Standardformat der Engine).
            let n = min(list.count, maxCh)
            for i in 0..<n { ptrs[i] = list[i].mData?.assumingMemoryBound(to: Float.self) }
            let ts = timestamp.pointee
            guard ts.mFlags.contains(.hostTimeValid) else { return noErr }
            let rate = ts.mFlags.contains(.rateScalarValid) ? ts.mRateScalar : 1
            for i in 0..<count {
                cores[i]._withUnsafeGuaranteedRef {
                    $0.consumeInput(host: ts.mHostTime, frames: Int(frameCount), sampleRate: sr,
                                    rateScalar: rate, channels: ptrs, channelCount: n)
                }
            }
            return noErr
        }
        e.attach(sink)
        e.connect(input, to: sink, format: format)
        do {
            e.prepare()
            try e.start()
        } catch {
            return fail(error.localizedDescription)
        }
        engine = e
        channelCount = Int(format.channelCount)
        sampleRate = sr
        // Latenz des Geräts, an dem die Engine tatsächlich hängt (v1.18.7), nicht des Standards.
        latencyFrames = AudioDevices.current(of: input.audioUnit).map { AudioDevices.latencyFrames($0, input: true) }
            ?? Self.deviceLatency(scope: kAudioDevicePropertyScopeInput,
                                  selector: kAudioHardwarePropertyDefaultInputDevice)
        lastError = nil
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: e, queue: nil) { [weak self] _ in
            DispatchQueue.main.async { self?.handleConfigurationChange() }   // nie warten lassen (v1.18.20)
        }
        return true
    }

    /// Gerätelatenz + Sicherheitsabstand des Standardgeräts (Frames).
    static func deviceLatency(scope: AudioObjectPropertyScope, selector: AudioObjectPropertySelector) -> Int {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr
        else { return 0 }
        func read(_ sel: AudioObjectPropertySelector) -> Int {
            var v = UInt32(0); var s = UInt32(MemoryLayout<UInt32>.size)
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            return AudioObjectGetPropertyData(device, &a, 0, nil, &s, &v) == noErr ? Int(v) : 0
        }
        return read(kAudioDevicePropertyLatency) + read(kAudioDevicePropertySafetyOffset)
    }
}
