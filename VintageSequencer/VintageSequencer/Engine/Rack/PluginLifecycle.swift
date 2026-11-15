import Foundation
import AVFoundation
import AppKit
import CoreAudioKit
import Atomics

// MARK: - PluginLifecycle (v1.18.5, Codex A17-10 — Zerlegung des Racks, Schritt 5)
//
// Was ein Plug-in vom Laden bis zum Entfernen braucht, ohne Kanäle oder Engine zu kennen:
// Laden (nur out-of-process), Klangzustand lesen/setzen, Host-Takt-Bindung samt Bestätigung
// nach dem Verdrahten und nach Engine-Starts (A17-09), Render-Observer (Übergabe an den
// Audio-Thread) und Editorfenster. Das Rack entscheidet, wann was geschieht, und hält Knoten,
// Warteschlangen und Belegung; der Lebenszyklus hält nur die Fenster. Nur Main — bis auf die
// Render-Observer, die auf dem Audio-Thread laufen (dort nur Warteschlange und Schedule-Blöcke).

final class PluginLifecycle {

    private let hostSync: HostSync
    private let recorder: AudioDiagnostics

    init(hostSync: HostSync, recorder: AudioDiagnostics) {
        self.hostSync = hostSync
        self.recorder = recorder
    }

    static let hostTicksPerSecond: Double = {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        return 1_000_000_000.0 * Double(tb.denom) / Double(tb.numer)
    }()

    // MARK: Laden

    #if DEBUG
    /// Ersetzt das Laden von Plug-ins: der Test bekommt den Abschluss und ruft ihn selbst auf.
    var _instantiateOverride: ((PluginRef, @escaping (AVAudioUnit?) -> Void) -> Void)?
    #endif

    /// Lädt ein Plug-in; der Abschluss kommt auf Main (nil = nicht ladbar).
    func instantiate(_ ref: PluginRef, completion: @escaping (AVAudioUnit?) -> Void) {
        #if DEBUG
        if let override = _instantiateOverride { override(ref, completion); return }
        #endif
        let d = ref.componentDescription
        // Nur out-of-process. Ein Rückfall auf das Laden im eigenen Prozess würde in der
        // Sandbox den Systemdialog „Sicherheitseinstellungen senken" auslösen (v1.13.7).
        AVAudioUnit.instantiate(with: d, options: .loadOutOfProcess) { [weak self] unit, error in
            DispatchQueue.main.async {
                if let error {
                    self?.recorder.event("loadError", ["plugin": ref.name, "error": "\(error)"])
                }
                completion(unit)
            }
        }
    }

    // MARK: Klangzustand

    static func stateData(of unit: AVAudioUnit) -> Data? {
        guard let state = unit.auAudioUnit.fullState else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
    }

    static func restoreState(_ data: Data?, into unit: AVAudioUnit) {
        guard let data,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              var dict = plist as? [String: Any] else { return }
        // Apple-Sampler (v1.18.16): Samplepfade eines anderen Rechners auf freigegebene Ordner.
        if AppleSampler.isSampler(unit.audioComponentDescription) { dict = AppleSampler.relocate(dict) }
        unit.auAudioUnit.fullState = dict
    }

    // MARK: Host-Takt (v1.17.6, Codex A17-09)

    /// Setzt die Host-Blöcke eines Plug-ins einmal je Installation (vor dem Einhängen in die
    /// Engine, damit sie beim Anlegen der Renderressourcen feststehen). Die Bindung ist neu je
    /// Installation; Blöcke und Render-Observer halten sie stark. Ob der Renderpfad die Blöcke
    /// nutzt, zeigen ihre Zähler (Diagnose `hostCalls`).
    func bindHost(_ unit: AVAudioUnit, queue: Unmanaged<AUEventQueue>) -> HostBinding {
        let binding = HostBinding()
        let q = queue.takeUnretainedValue()           // stark gefangen: lebt so lange wie die Blöcke
        let (music, transport) = hostSync.blocks(binding: binding, advance: { q.latencyAdvance })
        unit.auAudioUnit.musicalContextBlock = music
        unit.auAudioUnit.transportStateBlock = transport
        binding.install = { [weak unit] in
            guard let au = unit?.auAudioUnit else { return }
            au.musicalContextBlock = music
            au.transportStateBlock = transport
        }
        return binding
    }

    /// Zweiter, fester Installationspunkt: nach dem Verdrahten (Renderressourcen stehen).
    /// Beobachtet im Volllauf: ein ausgelagertes Instrument rief vor dem Einhängen gesetzte
    /// Blöcke nicht auf (Nutzungszähler 0, Effekt daneben versorgt).
    func confirm(_ binding: HostBinding?, _ unit: AVAudioUnit) {
        guard let binding else { return }
        if unit.auAudioUnit.musicalContextBlock == nil || unit.auAudioUnit.transportStateBlock == nil {
            binding.install?()
            recorder.event("hostBlocksInstalledAfterWiring", ["unit": unit.name])
        }
    }

    /// Nach jedem Lebenszyklus-Ereignis der Engine (Neuverdrahten, Start, Neustart): Befund
    /// v1.17.10 — ein ausgelagertes Instrument verlor die Blöcke beim Neustart der Engine.
    /// Gesetzt wird nur, wenn der Getter leer ist — dieselbe Bindung, vermerkt in der Diagnose.
    func reaffirm(_ binding: HostBinding, _ unit: AVAudioUnit, force: Bool = false) {
        let au = unit.auAudioUnit
        guard force || au.musicalContextBlock == nil || au.transportStateBlock == nil else { return }
        binding.install?()
        binding.reinstalls.wrappingIncrement(ordering: .relaxed)
        recorder.event("hostBlocksReaffirmed", ["unit": unit.name])
    }

    /// Zustand einer Bindung zum Zeitpunkt eines Engine-Starts.
    struct UseMark { let renders: Int; let calls: Int }
    func mark(_ b: HostBinding) -> UseMark { UseMark(renders: b.renders.load(ordering: .relaxed), calls: b.calls) }

    /// Nach einem Start: hat das Plug-in seither gerendert, die Host-Blöcke aber nie
    /// aufgerufen, sind sie im Hostprozess verloren (A17-09) — dann, und nur dann, einmal
    /// setzen. Ein Plug-in, das sie aufruft, wird nie angefasst: Ersetzen eines Blocks, den
    /// der Renderthread im Hostprozess gerade benutzt, lässt diesen abstürzen (v1.18.10).
    @discardableResult
    func restoreIfUnused(_ binding: HostBinding, _ unit: AVAudioUnit, since m: UseMark) -> Bool {
        guard binding.renders.load(ordering: .relaxed) - m.renders >= 4, binding.calls == m.calls else { return false }
        binding.install?()
        binding.reinstalls.wrappingIncrement(ordering: .relaxed)
        recorder.event("hostBlocksRestored", ["unit": unit.name])
        return true
    }

    // MARK: Render-Observer (Übergabe an den Audio-Thread)

    /// Hängt die Warteschlange eines Kanals an den Render-Durchlauf seines Instruments.
    ///
    /// Der Block läuft auf dem Audio-Thread: er fängt nur die Warteschlange (unretained — das
    /// Rack hält sie für seine ganze Lebensdauer), die Schedule-Blöcke des AUs, die Bindung
    /// (Atomics) und eine Konstante. Kein Heap, kein Lock, kein Zugriff auf Rack oder Engine.
    /// - Returns: Observer-Token, nil ohne MIDI-Eingang oder Abtastrate.
    func installInstrumentObserver(_ unit: AVAudioUnit, queue: Unmanaged<AUEventQueue>,
                                   binding: HostBinding?) -> Int? {
        guard let schedule = unit.auAudioUnit.scheduleMIDIEventBlock else { return nil }
        let scheduleParameter = unit.auAudioUnit.scheduleParameterBlock
        let sampleRate = unit.outputFormat(forBus: 0).sampleRate
        guard sampleRate > 0 else { return nil }
        let ticksPerFrame = Self.hostTicksPerSecond / sampleRate
        let binding = binding ?? HostBinding()
        binding.ticksPerFrame.store(ticksPerFrame.bitPattern, ordering: .relaxed)
        return unit.auAudioUnit.token(byAddingRenderObserver: { flags, timestamp, frameCount, _ in
            if flags.contains(.unitRenderAction_PostRender) {
                // Diagnose: nur Zähler (Atomics), sonst nichts.
                queue._withUnsafeGuaranteedRef { q in
                    q.postRenders.wrappingIncrement(ordering: .relaxed)
                    if flags.contains(.unitRenderAction_PostRenderError) {
                        q.renderErrors.wrappingIncrement(ordering: .relaxed)
                    }
                }
                return
            }
            guard flags.contains(.unitRenderAction_PreRender) else { return }
            let ts = timestamp.pointee
            // Host-Takt (v1.17.2): Blockzeit für `musicalContextBlock`/`transportStateBlock`.
            binding.renderHost.store(ts.mFlags.contains(.hostTimeValid) ? ts.mHostTime : 0, ordering: .relaxed)
            binding.renders.wrappingIncrement(ordering: .relaxed)
            queue._withUnsafeGuaranteedRef { q in
                q.preRenders.wrappingIncrement(ordering: .relaxed)
                q.render(hostStart: ts.mHostTime,
                         hostValid: ts.mFlags.contains(.hostTimeValid),
                         frames: Int(frameCount),
                         ticksPerFrame: ticksPerFrame, emit: { offset, packed in
                    var bytes = (UInt8(truncatingIfNeeded: packed),
                                 UInt8(truncatingIfNeeded: packed >> 8),
                                 UInt8(truncatingIfNeeded: packed >> 16))
                    withUnsafeBytes(of: &bytes) { raw in
                        schedule(AUEventSampleTimeImmediate + AUEventSampleTime(offset), 0, 3,
                                 raw.bindMemory(to: UInt8.self).baseAddress!)
                    }
                }, emitParameter: { offset, address, value in
                    scheduleParameter(AUEventSampleTimeImmediate + AUEventSampleTime(offset), 0,
                                      address, value)
                })
            }
        })
    }

    /// Render-Observer eines Effekts (nach dem Verdrahten: Abtastrate steht fest). Läuft vor
    /// dem Rendern des Effekts und plant Parameter mit Sample-Offset ein — sie gelten für
    /// denselben Block (v1.17.1).
    func installEffectObserver(_ unit: AVAudioUnit, queue: Unmanaged<AUEventQueue>,
                               binding: HostBinding?) -> Int? {
        let scheduleParameter = unit.auAudioUnit.scheduleParameterBlock
        let sampleRate = unit.outputFormat(forBus: 0).sampleRate
        guard sampleRate > 0 else { return nil }
        let ticksPerFrame = Self.hostTicksPerSecond / sampleRate
        let binding = binding ?? HostBinding()
        binding.ticksPerFrame.store(ticksPerFrame.bitPattern, ordering: .relaxed)
        return unit.auAudioUnit.token(byAddingRenderObserver: { flags, timestamp, frameCount, _ in
            guard flags.contains(.unitRenderAction_PreRender) else { return }
            let ts = timestamp.pointee
            binding.renderHost.store(ts.mFlags.contains(.hostTimeValid) ? ts.mHostTime : 0, ordering: .relaxed)
            binding.renders.wrappingIncrement(ordering: .relaxed)
            queue._withUnsafeGuaranteedRef { q in
                q.render(hostStart: ts.mHostTime,
                         hostValid: ts.mFlags.contains(.hostTimeValid),
                         frames: Int(frameCount),
                         ticksPerFrame: ticksPerFrame, emit: { _, _ in },
                         emitParameter: { offset, address, value in
                    scheduleParameter(AUEventSampleTimeImmediate + AUEventSampleTime(offset), 0, address, value)
                })
            }
        })
    }

    func removeObserver(_ token: Int?, from unit: AVAudioUnit?) {
        guard let token, let unit else { return }
        unit.auAudioUnit.removeRenderObserver(token)
    }

    // MARK: Editorfenster

    /// Instrument eines Kanals bzw. Effekt (nach Token).
    enum Editor: Hashable { case instrument(UUID), effect(UUID) }

    private var windows: [Editor: NSWindow] = [:]
    /// Angefordert, Controller noch nicht da: ein zweiter Klick öffnet kein zweites Fenster,
    /// ein Schließen vorher verwirft das Fenster.
    private var pending: Set<Editor> = []

    /// Öffnet den Editor oder holt ein offenes Fenster nach vorn.
    func openEditor(_ key: Editor, unit: AVAudioUnit, title: String) {
        if let w = windows[key] { w.makeKeyAndOrderFront(nil); return }
        guard pending.insert(key).inserted else { return }
        makeEditorWindow(for: unit, title: title) { [weak self] w in
            guard let self, self.pending.remove(key) != nil else { w?.close(); return }
            if let w { self.windows[key] = w }
        }
    }

    func closeEditor(_ key: Editor) {
        pending.remove(key)
        windows.removeValue(forKey: key)?.close()
    }

    func window(_ key: Editor) -> NSWindow? { windows[key] }

    /// Baut das Editor-Fenster eines Plug-ins.
    ///
    /// `requestViewController` liefert bei out-of-process geladenen AUs immer einen
    /// (entfernten) Controller — auch für Plug-ins OHNE eigene Oberfläche; dessen View ist
    /// dann 1 × 1 Punkt groß (z. B. AUMatrixReverb). Ein so kleiner oder fehlender Editor
    /// wird durch die Parameteransicht des Systems ersetzt. Die Fenstergröße folgt der
    /// tatsächlichen Editorgröße.
    private func makeEditorWindow(for unit: AVAudioUnit, title: String, store: @escaping (NSWindow?) -> Void) {
        unit.auAudioUnit.requestViewController { controller in
            DispatchQueue.main.async {
                var vc = controller
                var size = Self.editorSize(of: controller)
                if size == nil {
                    let generic = AUGenericView(audioUnit: unit.audioUnit)
                    var frame = generic.frame
                    if frame.width < 200 { frame.size.width = 520 }
                    if frame.height < 80 { frame.size.height = 320 }
                    frame.size.height = min(frame.height, 640)
                    let scroll = NSScrollView(frame: NSRect(origin: .zero, size: frame.size))
                    scroll.hasVerticalScroller = true
                    scroll.drawsBackground = false
                    scroll.documentView = generic
                    let host = NSViewController()
                    host.view = scroll
                    vc = host; size = frame.size
                }
                guard let vc, let size else { store(nil); return }
                let w = NSWindow(contentViewController: vc)
                w.title = title
                w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
                w.isReleasedWhenClosed = false
                // Vollbild (v1.17.10): unter macOS 12 öffnete der Editor sonst einen eigenen
                // Schreibtisch. Hilfsfenster des Vollbild-Raums, über dem Hauptfenster.
                w.collectionBehavior.insert([.fullScreenAuxiliary, .moveToActiveSpace])
                if let main = NSApp.windows.first(where: { $0.styleMask.contains(.fullScreen) && $0 !== w }) {
                    main.addChildWindow(w, ordered: .above)
                }
                w.setContentSize(size)
                w.center()
                w.makeKeyAndOrderFront(nil)
                store(w)
            }
        }
    }

    /// Brauchbare Größe eines gelieferten Editors, nil wenn er fehlt oder leer ist.
    private static func editorSize(of controller: NSViewController?) -> NSSize? {
        guard let controller else { return nil }
        for size in [controller.preferredContentSize, controller.view.frame.size]
        where size.width >= 40 && size.height >= 40 { return size }
        return nil
    }
}
