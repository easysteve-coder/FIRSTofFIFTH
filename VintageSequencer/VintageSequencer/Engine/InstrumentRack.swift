import AVFoundation
import AudioToolbox
import CoreAudioKit
import AppKit
import Combine
import Atomics
import os

// MARK: - LevelMeter

/// Spitzenpegel links/rechts des zuletzt gemessenen Blocks (0 … 1+), lock-frei zwischen
/// Mess-Tap (Audio-Hilfsthread) und Anzeige (Main). Haltezeit und Abfall rechnet die Anzeige.
final class LevelMeter {
    private let left  = ManagedAtomic<UInt32>(0)
    private let right = ManagedAtomic<UInt32>(0)
    func store(left l: Float, right r: Float) {
        left.store(l.bitPattern, ordering: .relaxed); right.store(r.bitPattern, ordering: .relaxed)
    }
    func load() -> (left: Float, right: Float) {
        (Float(bitPattern: left.load(ordering: .relaxed)), Float(bitPattern: right.load(ordering: .relaxed)))
    }
    /// Anzeige: holt die höchste Spitze seit der letzten Abholung und setzt zurück, damit
    /// zwischen zwei Bildern kein Block verloren geht.
    func take() -> (left: Float, right: Float) {
        (Float(bitPattern: left.exchange(0, ordering: .relaxed)), Float(bitPattern: right.exchange(0, ordering: .relaxed)))
    }
    func reset() { store(left: 0, right: 0) }

    // Wächter (v1.13.11): Lebenszeichen des Renderwegs und ungültige Samples.
    private let blocks    = ManagedAtomic<Int>(0)
    private let nonFinite = ManagedAtomic<Bool>(false)
    /// Zahl der bisher gemessenen Blöcke — steht sie, rendert die Engine nicht mehr.
    var blockCount: Int { blocks.load(ordering: .relaxed) }
    /// true, wenn seit der letzten Abfrage NaN/∞ im Signal lag (setzt zurück).
    func takeNonFinite() -> Bool { nonFinite.exchange(false, ordering: .relaxed) }
    /// Wie `takeNonFinite`, ohne zurückzusetzen.
    var hasNonFinite: Bool { nonFinite.load(ordering: .relaxed) }

    // Audio-Diagnose (v1.13.14): Rohwerte, unabhängig von der Anzeige abgeholt (die Anzeige
    // nimmt per `take`, die Diagnose per `takeDiagnostics` — keiner verbraucht die Werte des
    // anderen).
    struct Diagnostics {
        /// Höchster endlicher Betrag seit der letzten Abholung (darf weit über 1 liegen).
        var peak: Float
        /// Samples mit Betrag über 1,0 bzw. über 16 (+24 dBFS) und NaN/∞-Samples.
        var over: Int, over16: Int, nonFinite: Int
        /// Gleichanteil (größter Betrag der Kanal-Mittelwerte) und RMS des letzten Blocks.
        var dc: Float, rms: Float
    }
    private let diagPeak      = ManagedAtomic<UInt32>(0)
    private let diagOver      = ManagedAtomic<Int>(0)
    private let diagOver16    = ManagedAtomic<Int>(0)
    private let diagNonFinite = ManagedAtomic<Int>(0)
    private let diagDC        = ManagedAtomic<UInt32>(0)
    private let diagRMS       = ManagedAtomic<UInt32>(0)
    func takeDiagnostics() -> Diagnostics {
        Diagnostics(peak: Float(bitPattern: diagPeak.exchange(0, ordering: .relaxed)),
                    over: diagOver.exchange(0, ordering: .relaxed),
                    over16: diagOver16.exchange(0, ordering: .relaxed),
                    nonFinite: diagNonFinite.exchange(0, ordering: .relaxed),
                    dc: Float(bitPattern: diagDC.load(ordering: .relaxed)),
                    rms: Float(bitPattern: diagRMS.load(ordering: .relaxed)))
    }

    /// Liest einen Tap-Puffer aus (Kanal 0 = links, Kanal 1 = rechts; Mono → beide gleich).
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength), channels = Int(buffer.format.channelCount)
        var l: Float = 0, r: Float = 0, finitePeak: Float = 0
        var over = 0, over16 = 0, bad = 0
        var dc: Double = 0, sq: Double = 0, counted = 0
        for c in 0..<min(channels, 2) {
            var m: Float = 0, sum: Double = 0
            for i in 0..<n {
                let x = ch[c][i], v = abs(x)
                if v.isFinite {
                    if v > m { m = v }
                    if v > 1 { over += 1; if v > 16 { over16 += 1 } }
                    sum += Double(x); sq += Double(x) * Double(x); counted += 1
                } else { bad += 1 }
            }
            if c == 0 { l = m } else { r = m }
            finitePeak = max(finitePeak, m)
            if n > 0 { dc = max(dc, abs(sum / Double(n))) }
        }
        if channels < 2 { r = l }
        diagDC.store(Float(dc).bitPattern, ordering: .relaxed)
        diagRMS.store(Float(counted > 0 ? (sq / Double(counted)).squareRoot() : 0).bitPattern, ordering: .relaxed)
        if over > 0 { diagOver.wrappingIncrement(by: over, ordering: .relaxed) }
        if over16 > 0 { diagOver16.wrappingIncrement(by: over16, ordering: .relaxed) }
        if finitePeak > Float(bitPattern: diagPeak.load(ordering: .relaxed)) {
            diagPeak.store(finitePeak.bitPattern, ordering: .relaxed)
        }
        if bad > 0 {
            diagNonFinite.wrappingIncrement(by: bad, ordering: .relaxed)
            nonFinite.store(true, ordering: .relaxed); l = 0; r = 0
        }
        blocks.wrappingIncrement(ordering: .relaxed)
        // Einziger Schreiber ist der Tap; die Anzeige nimmt per exchange. Überschneidet sich
        // beides, wird schlimmstenfalls eine alte Spitze ein zweites Mal gezeigt.
        let old = load()
        store(left: max(l, old.left), right: max(r, old.right))
    }
}

// MARK: - ChannelDirectory

/// Namen und IDs der Instrumentenkanäle in Rack-Reihenfolge (Main-Thread). Veröffentlicht
/// nur, wenn sich diese Liste ändert.
final class ChannelDirectory: ObservableObject {
    struct Entry: Identifiable, Equatable {
        let id: UUID
        let name: String
        /// `PluginRef.componentKey` des Instruments, sobald es geladen ist; sonst nil.
        var readyInstrument: String? = nil
    }
    @Published private(set) var entries: [Entry] = []

    fileprivate func update(_ channels: [InstrumentChannelData], status: [UUID: InstrumentRack.SlotStatus]) {
        let new = channels.map {
            Entry(id: $0.id, name: $0.name,
                  readyInstrument: status[$0.id] == .ready ? $0.instrument?.componentKey : nil)
        }
        if new != entries { entries = new }
    }
}

// MARK: - InstrumentRack

/// AU-Host der App (v1.13.0): Instrumentenkanäle mit je einem AU-Instrument, einer
/// geordneten Effektkette, Pegel und Panorama, gemischt auf den Standard-Audioausgang.
///
/// ```
/// Tick-Pfad ──▶ AUEventQueue[slot] ──▶ Render-Observer ──▶ Instrument ─▶ Effekte ─▶ Kanal-Mixer ─▶ Main-Mixer ─▶ Ausgang
/// ```
///
/// **Besitz.** Alles hier gehört dem Main-Thread — mit zwei Ausnahmen:
///   - `queues` ist ein fester, in `init` angelegter Block von `maxChannels` Warteschlangen.
///     Der Tick-Pfad schreibt über den Slot-Index hinein (`TrackSnapshot.route`), ohne das
///     Rack zu berühren. Slots werden nie freigegeben, nur neu vergeben. Jede neue Belegung
///     (Instrument geladen, getauscht, Kanal angelegt/entfernt) beginnt mit
///     `beginOccupancy()`; Ereignisse tragen die Belegung, für die sie geplant wurden
///     (`TrackSnapshot.routeEpoch`), und erreichen eine spätere Belegung nie (v1.13.13).
///   - Der Render-Observer eines Instruments läuft auf dessen Audio-Thread und fasst
///     ausschließlich seine Warteschlange und den MIDI-Schedule-Block des AUs an.
///
/// **Audio-Engine.** Wird erst angelegt, wenn der erste Kanal entsteht, und läuft nur,
/// solange mindestens ein Instrument geladen ist. Ohne Kanäle öffnet die App kein
/// Audiogerät (reiner MIDI-Betrieb wie bisher).
///
/// **Plug-ins** werden ausschließlich außerhalb des App-Prozesses geladen
/// (`.loadOutOfProcess`, seit v1.13.7 ohne Rückfall in den App-Prozess, der in der Sandbox
/// einen Systemdialog auslöst). Was so nicht lädt, gilt als nicht ladbar (`.missing`).
///
/// **Fehlende Plug-ins** behalten Identität, Namen und gespeicherten Zustand; der Kanal
/// bleibt stumm und zeigt den Status `.missing`. Nichts wird stillschweigend ersetzt.
final class InstrumentRack: ObservableObject {

    static let maxChannels = 16
    static let maxEffectsPerChannel = 4
    /// Fader reichen bis +6 dB (wie Planarium). Pegel werden als linearer Gain gespeichert.
    static let maxGainDecibels: Float = 6
    static let maxGain: Float = powf(10, maxGainDecibels / 20)

    /// Linearer Gain → dB für die Gain-Stufe (−96 dB = stumm).
    static func decibels(_ gain: Float) -> Float {
        gain > 0 ? max(-96, min(maxGainDecibels, 20 * log10f(gain))) : -96
    }

    enum SlotStatus: Equatable { case empty, loading, ready, missing }

    // MARK: - Beobachtbarer Zustand (Main)

    @Published private(set) var channels: [InstrumentChannelData] = [] {
        didSet { directory.update(channels, status: instrumentStatus) }
    }
    /// Kanalliste (ID + Name) für die Ausgangswahl der Spuren. Eigenes Objekt, damit
    /// Spurköpfe nur Anlegen/Löschen/Umbenennen sehen — nicht jede Faderbewegung.
    let directory = ChannelDirectory()
    @Published private(set) var instrumentStatus: [UUID: SlotStatus] = [:] {
        didSet { directory.update(channels, status: instrumentStatus) }
    }
    @Published private(set) var effectStatus: [UUID: [SlotStatus]] = [:]
    /// Letzter Fehler der Audio-Engine (Start fehlgeschlagen o. Ä.), sonst nil.
    @Published private(set) var engineError: String?
    /// Läuft die Audio-Engine? (Pegelanzeigen stehen sonst still.)
    @Published private(set) var isAudioRunning = false
    /// Summenpegel als linearer Gain 0 … `maxGain`, Teil des Projekts.
    @Published private(set) var masterVolume: Float = 1
    /// Nur Anzeige (nicht gespeichert): Kanal, den die zuletzt angefasste Spur spielt.
    @Published var highlightedChannel: UUID?

    /// Pegelmessung der Summe (nach dem Master-Fader).
    let masterMeter = LevelMeter()

    /// Projektinhalt hat sich geändert (Kanal, Plug-in, Pegel …) → „ungespeichert".
    var onProjectChange: (() -> Void)?
    /// Slot-Zuordnung hat sich geändert → Playback-Snapshot neu publizieren.
    var onRoutingChange: (() -> Void)?
    /// Kanal wurde entfernt → Spuren, die ihn spielten, auf externe MIDI-Ausgabe zurückstellen.
    var onChannelRemoved: ((UUID) -> Void)?

    // MARK: - Tick-Pfad-Zugang

    /// Fester Block von `maxChannels` Warteschlangen (retained für die Lebensdauer des Racks).
    let queues: UnsafeMutablePointer<Unmanaged<AUEventQueue>>

    @inline(__always)
    func queue(_ slot: Int) -> AUEventQueue { queues[slot].takeUnretainedValue() }

    // MARK: - Live-Zustand (Main)

    private final class Live {
        let slot: Int
        /// Gain-Stufe des Faders (−96 … +6 dB); der Mixer dahinter macht Panorama und Stumm.
        let gain = AVAudioUnitEQ(numberOfBands: 0)
        let mixer = AVAudioMixerNode()
        /// Pegel des Kanals nach Fader/Mute (vor dem Panorama).
        let meter = LevelMeter()
        var tapInstalled = false
        var instrument: AVAudioUnit?
        /// Laufender Ladeauftrag des Instruments. Nie wiederverwendet: ein verspäteter
        /// Abschluss trifft weder einen späteren Auftrag noch eine neue Live-Instanz
        /// desselben Kanals (H4, v1.13.13).
        var instrumentRequest: UUID?
        var observerToken: Int?
        /// Parallel zu `InstrumentChannelData.effects`.
        var effects: [AVAudioUnit?] = []
        var effectTokens: [UUID] = []
        var instrumentWindow: NSWindow?
        var effectWindows: [UUID: NSWindow] = [:]
        /// Editor nach dem Laden öffnen (ausdrückliche Wahl im Kanalzug).
        var openInstrumentWhenLoaded = false
        var openEffectWhenLoaded: Set<UUID> = []
        /// Schreibbare Parameter des geladenen Instruments (bei Bedarf gelesen, Main).
        var parameterCache: [ParameterInfo]?
        /// Audio-Diagnose: Beobachtung von Preset/Parameterbaum des Instruments.
        var diagnosticObservations: [NSKeyValueObservation] = []
        init(slot: Int) { self.slot = slot }
    }

    private var live: [UUID: Live] = [:]
    private var freeSlots: [Int] = Array((0..<InstrumentRack.maxChannels).reversed())
    private var engineStorage: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private var invalidationObserver: NSObjectProtocol?
    /// Audio-Diagnose (Aufzeichnung im Betrieb, Menü „Hilfe").
    let diagnostics = AudioDiagnostics()
    private var masterTapInstalled = false
    /// Gain-Stufe der Summe zwischen Main-Mixer und Ausgang (nur verdrahtet, wenn ein
    /// Ausgabeformat bekannt ist; sonst begrenzt der Main-Mixer auf 0 dB).
    private let masterGain = AVAudioUnitEQ(numberOfBands: 0)
    private var masterGainWired = false
    private var masterTapNode: AVAudioNode?

    private static let hostTicksPerSecond: Double = {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        return 1_000_000_000.0 * Double(tb.denom) / Double(tb.numer)
    }()

    // MARK: - Init

    init() {
        queues = .allocate(capacity: Self.maxChannels)
        for i in 0..<Self.maxChannels { (queues + i).initialize(to: .passRetained(AUEventQueue())) }
        diagnostics.header = { [weak self] in self?.diagnosticHeader() ?? [:] }
        diagnostics.onRecordingChange = { [weak self] _ in
            guard let self else { return }
            self.updateWatchdog(needed: self.live.values.contains { $0.instrument != nil })
        }
        // Ein ausgelagertes Plug-in hat seinen Prozess verloren (Absturz des AU-Hosts).
        invalidationObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: kAudioComponentInstanceInvalidationNotification as String),
            object: nil, queue: .main
        ) { [weak self] note in self?.pluginInvalidated(note.object as AnyObject?) }
    }

    deinit {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        if let o = invalidationObserver { NotificationCenter.default.removeObserver(o) }
        for l in live.values { removeObserver(l) }
        engineStorage?.stop()
        for i in 0..<Self.maxChannels { queues[i].release() }
        queues.deinitialize(count: Self.maxChannels); queues.deallocate()
    }

    // MARK: - Abfragen

    var canAddChannel: Bool { channels.count < Self.maxChannels }

    /// Slot-Index für den Tick-Pfad; −1 = kein Kanal (externe MIDI-Ausgabe).
    func route(for channelID: UUID?) -> Int {
        guard let id = channelID, let l = live[id] else { return -1 }
        return l.slot
    }

    func channel(_ id: UUID) -> InstrumentChannelData? { channels.first { $0.id == id } }

    /// Pegelmessung eines Kanals (nil, wenn es den Kanal nicht gibt).
    func meter(for id: UUID) -> LevelMeter? { live[id]?.meter }

    struct ComponentInfo: Identifiable, Equatable {
        let ref: PluginRef
        let manufacturer: String
        var id: String { "\(ref.type)-\(ref.subType)-\(ref.manufacturer)" }
    }

    /// Installierte AU-Instrumente, nach Hersteller und Name sortiert.
    func availableInstruments() -> [ComponentInfo] { components(types: [kAudioUnitType_MusicDevice]) }
    /// Installierte AU-Effekte (Audio- und MIDI-gesteuerte Effekte).
    func availableEffects() -> [ComponentInfo] {
        components(types: [kAudioUnitType_Effect, kAudioUnitType_MusicEffect])
    }

    private func components(types: [OSType]) -> [ComponentInfo] {
        var out: [ComponentInfo] = []
        // Dasselbe Plug-in kann mehrfach installiert sein (System- und Benutzerordner); das
        // System meldet es dann je Kopie. Geladen wird ohnehin über die Kennung — ein Eintrag.
        var seen = Set<String>()
        for t in types {
            let d = AudioComponentDescription(componentType: t, componentSubType: 0,
                                              componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
            for c in AVAudioUnitComponentManager.shared().components(matching: d) {
                let info = ComponentInfo(ref: PluginRef(description: c.audioComponentDescription, name: c.name),
                                         manufacturer: c.manufacturerName)
                if seen.insert(info.id).inserted { out.append(info) }
            }
        }
        return out.sorted { ($0.manufacturer, $0.ref.name) < ($1.manufacturer, $1.ref.name) }
    }

    // MARK: - Instrument-Parameter (Ziel von CC-Lanes)

    struct ParameterInfo: Identifiable, Equatable {
        let address: UInt64
        let name: String
        /// Gruppe im Parameterbaum des Plug-ins ("" = ohne Gruppe).
        let group: String
        let min: Float
        let max: Float
        var id: UInt64 { address }
    }

    /// Schreibbare Parameter des Instruments eines Kanals, in der Reihenfolge des Plug-ins.
    /// Leer, solange kein Instrument geladen ist.
    func parameters(for id: UUID) -> [ParameterInfo] {
        guard let l = live[id] else { return [] }
        if let cached = l.parameterCache { return cached }
        guard let unit = l.instrument else { return [] }
        var list: [ParameterInfo] = []
        // Baum in Plug-in-Reihenfolge durchlaufen; die innerste Gruppe benennt den Abschnitt.
        func walk(_ nodes: [AUParameterNode], group: String) {
            for node in nodes {
                if let g = node as? AUParameterGroup {
                    walk(g.children, group: g.displayName)
                } else if let p = node as? AUParameter,
                          p.flags.contains(.flag_IsWritable), p.maxValue > p.minValue {
                    list.append(ParameterInfo(address: p.address, name: p.displayName, group: group,
                                              min: p.minValue, max: p.maxValue))
                }
            }
        }
        walk(unit.auAudioUnit.parameterTree?.children ?? [], group: "")
        l.parameterCache = list
        return list
    }

    func parameterRange(_ address: UInt64, in id: UUID) -> (min: Float, max: Float)? {
        parameters(for: id).first { $0.address == address }.map { ($0.min, $0.max) }
    }

    /// Löst ein gespeichertes Parameterziel gegen das geladene Instrument eines Kanals auf.
    /// nil, wenn kein Instrument bereit ist, ein anderes Plug-in als das gebundene geladen
    /// ist oder der Parameter dort fehlt (v1.13.13).
    func resolveParameter(_ ref: ParameterRef, in id: UUID) -> ParameterTarget? {
        guard instrumentStatus[id] == .ready, let inst = channel(id)?.instrument else { return nil }
        if let bound = ref.component, bound != inst.componentKey { return nil }
        return parameterRange(ref.address, in: id).map {
            ParameterTarget(address: ref.address, min: $0.min, max: $0.max)
        }
    }

    /// Kennung des geladenen Instruments eines Kanals (für neue Parameterbindungen).
    func readyInstrumentKey(_ id: UUID) -> String? {
        instrumentStatus[id] == .ready ? channel(id)?.instrument?.componentKey : nil
    }

    // MARK: - Kanäle

    @discardableResult
    func addChannel(name: String) -> UUID? {
        guard canAddChannel, let slot = freeSlots.popLast() else { return nil }
        let data = InstrumentChannelData(name: name)
        install(data, slot: slot)
        channels.append(data)
        onRoutingChange?(); onProjectChange?()
        return data.id
    }

    func removeChannel(_ id: UUID) {
        guard let idx = channels.firstIndex(where: { $0.id == id }) else { return }
        uninstall(id)
        channels.remove(at: idx)
        applyMixToAll()          // war es der letzte Solo-Kanal, werden die übrigen wieder hörbar
        onChannelRemoved?(id)
        onRoutingChange?(); onProjectChange?()
        updateEngineRunning()
    }

    /// Legt eine Kopie des Kanals an: gleiches Instrument samt aktuellem Klang, gleiche
    /// Effekte und Einstellungen, eigene Plug-in-Instanzen. Spuren bleiben beim Original.
    @discardableResult
    func duplicateChannel(_ id: UUID, name: String) -> UUID? {
        guard canAddChannel, channel(id) != nil else { return nil }
        captureStates()
        guard var copy = channel(id), let slot = freeSlots.popLast() else { return nil }
        copy.id = UUID(); copy.name = name; copy.isSoloed = false
        install(copy, slot: slot)
        channels.append(copy)
        if let ref = copy.instrument { loadInstrument(ref, into: copy.id) }
        for (i, ref) in copy.effects.enumerated() { loadEffect(ref, into: copy.id, at: i) }
        onRoutingChange?(); onProjectChange?()
        return copy.id
    }

    func setMasterVolume(_ v: Float) {
        let clamped = max(0, min(Self.maxGain, v))
        guard clamped != masterVolume else { return }
        masterVolume = clamped
        applyMasterVolume()
        onProjectChange?()
    }

    private func applyMasterVolume() {
        guard let e = engineStorage else { return }
        if masterGainWired {
            masterGain.globalGain = Self.decibels(masterVolume)
            e.mainMixerNode.outputVolume = masterVolume > 0 ? 1 : 0
        } else {
            e.mainMixerNode.outputVolume = min(1, masterVolume)
        }
    }

    /// Ersetzt das gesamte Rack (Laden / Neues Projekt). Lädt alle Plug-ins neu.
    func replaceAll(_ new: [InstrumentChannelData], masterVolume master: Float = 1) {
        masterVolume = max(0, min(Self.maxGain, master))
        applyMasterVolume()
        highlightedChannel = nil
        for id in Array(live.keys) { uninstall(id) }
        var accepted: [InstrumentChannelData] = []
        for var data in new.prefix(Self.maxChannels) {
            guard let slot = freeSlots.popLast() else { break }
            data.clampToValidRanges()
            data.effects = Array(data.effects.prefix(Self.maxEffectsPerChannel))
            install(data, slot: slot)
            accepted.append(data)
        }
        channels = accepted
        applyMixToAll()
        for data in accepted {
            if let ref = data.instrument { loadInstrument(ref, into: data.id) }
            for (i, ref) in data.effects.enumerated() { loadEffect(ref, into: data.id, at: i) }
        }
        onRoutingChange?()
        updateEngineRunning()
    }

    private func install(_ data: InstrumentChannelData, slot: Int) {
        let l = Live(slot: slot)
        l.effects      = Array(repeating: nil, count: data.effects.count)
        l.effectTokens = data.effects.map { _ in UUID() }
        live[data.id] = l
        instrumentStatus[data.id] = data.instrument == nil ? .empty : .loading
        effectStatus[data.id]     = data.effects.map { _ in .loading }
        let q = queue(slot)
        q.setActive(false); q.invalidate(); q.beginOccupancy()
        let e = engine()
        e.attach(l.gain); e.attach(l.mixer)
        e.connect(l.gain, to: l.mixer, format: mixFormat())
        e.connect(l.mixer, to: e.mainMixerNode, format: mixFormat())
        installMeterTap(l)
        applyMix(data, to: l)
    }

    private func uninstall(_ id: UUID) {
        guard let l = live.removeValue(forKey: id) else { return }
        l.instrumentRequest = nil
        let q = queue(l.slot)
        q.setActive(false); q.invalidate(); q.beginOccupancy()
        removeObserver(l)
        l.instrumentWindow?.close()
        l.effectWindows.values.forEach { $0.close() }
        removeMeterTap(l)
        if let e = engineStorage {
            if let n = l.instrument { e.detach(n) }
            l.effects.compactMap { $0 }.forEach { e.detach($0) }
            e.detach(l.gain); e.detach(l.mixer)
        }
        instrumentStatus[id] = nil
        effectStatus[id] = nil
        freeSlots.append(l.slot)
    }

    // MARK: - Kanal-Eigenschaften

    func rename(_ id: UUID, to name: String) {
        mutate(id) { $0.name = name }
    }
    func setVolume(_ id: UUID, _ v: Float) { mutate(id) { $0.volume = max(0, min(Self.maxGain, v)) } }
    func setPan(_ id: UUID, _ p: Float)    { mutate(id) { $0.pan = max(-1, min(1, p)) } }
    func setMuted(_ id: UUID, _ m: Bool)   { mutate(id) { $0.isMuted = m } }
    func setSoloed(_ id: UUID, _ on: Bool) { mutate(id) { $0.isSoloed = on } }

    private func mutate(_ id: UUID, _ change: (inout InstrumentChannelData) -> Void) {
        guard let idx = channels.firstIndex(where: { $0.id == id }) else { return }
        var data = channels[idx]
        change(&data)
        guard data != channels[idx] else { return }
        let soloChanged = data.isSoloed != channels[idx].isSoloed
        channels[idx] = data
        // Solo eines Kanals ändert, was alle anderen hören lassen.
        if soloChanged { applyMixToAll() } else if let l = live[id] { applyMix(data, to: l) }
        onProjectChange?()
    }

    /// Hörbar ist ein Kanal, wenn er nicht stumm ist und — sobald irgendein Kanal auf Solo
    /// steht — selbst auf Solo steht.
    private func applyMix(_ data: InstrumentChannelData, to l: Live) {
        let anySolo = channels.contains { $0.isSoloed }
        let audible = !data.isMuted && (!anySolo || data.isSoloed)
        l.gain.globalGain = Self.decibels(data.volume)
        l.mixer.outputVolume = audible && data.volume > 0 ? 1 : 0
        l.mixer.pan = data.pan
    }

    private func applyMixToAll() {
        for data in channels { if let l = live[data.id] { applyMix(data, to: l) } }
    }

    // MARK: - Instrument

    /// Setzt (oder entfernt mit nil) das Instrument eines Kanals.
    func setInstrument(_ ref: PluginRef?, for id: UUID) {
        guard let idx = channels.firstIndex(where: { $0.id == id }), let l = live[id] else { return }
        teardownInstrument(l)
        channels[idx].instrument = ref
        instrumentStatus[id] = ref == nil ? .empty : .loading
        if let ref { loadInstrument(ref, into: id) }
        onRoutingChange?()           // neue Belegung → Snapshot mit neuer Epoche
        onProjectChange?()
        updateEngineRunning()
    }

    /// Schaltet das Instrument eines Kanals aus oder ein (Ein/Aus-Feld im Kanalzug). Aus:
    /// klingende Noten enden, neue werden verworfen; das Plug-in bleibt geladen.
    func setInstrumentEnabled(_ enabled: Bool, for id: UUID) {
        guard let idx = channels.firstIndex(where: { $0.id == id }), let l = live[id],
              var ref = channels[idx].instrument, ref.bypassed == enabled else { return }
        ref.bypassed = !enabled
        channels[idx].instrument = ref
        guard l.instrument != nil else { onProjectChange?(); return }
        let q = queue(l.slot)
        if enabled {
            q.invalidate(); q.setActive(true)
        } else {
            q.invalidate()
            for ch in 0..<16 { q.pushFromMain(0xB0 | UInt8(ch), 123, 0) }
            q.setActive(false)
        }
        onProjectChange?()
    }

    /// Öffnet den Editor, sobald das Instrument geladen ist (sofort, wenn es schon läuft).
    func openInstrumentEditorWhenLoaded(_ id: UUID) {
        guard let l = live[id] else { return }
        if l.instrument != nil { openInstrumentEditor(id) } else { l.openInstrumentWhenLoaded = true }
    }

    private func teardownInstrument(_ l: Live) {
        l.openInstrumentWhenLoaded = false
        l.instrumentRequest = nil
        let q = queue(l.slot)
        q.setActive(false); q.invalidate(); q.beginOccupancy()
        removeObserver(l)
        l.instrumentWindow?.close(); l.instrumentWindow = nil
        if let n = l.instrument, let e = engineStorage { e.detach(n) }
        l.instrument = nil
        l.parameterCache = nil
        l.diagnosticObservations = []
        rewire(l)
    }

    private func loadInstrument(_ ref: PluginRef, into id: UUID) {
        guard let l = live[id] else { return }
        let request = UUID()
        l.instrumentRequest = request
        instantiate(ref) { [weak self, weak l] unit in
            // Gilt nur, wenn derselbe Auftrag an derselben Live-Instanz noch aussteht.
            guard let self, let l, self.live[id] === l, l.instrumentRequest == request else { return }
            l.instrumentRequest = nil
            guard let unit else {
                self.instrumentStatus[id] = .missing
                self.diagnostics.event("load", ["channel": self.channel(id)?.name ?? "?", "plugin": ref.name, "ok": false])
                return
            }
            self.restoreState(ref.state, into: unit)
            self.engine().attach(unit)
            l.instrument = unit
            self.rewire(l)
            self.installObserver(l)
            let q = self.queue(l.slot)
            q.invalidate(); q.beginOccupancy()
            q.setActive(!(self.channel(id)?.instrument?.bypassed ?? false))
            self.instrumentStatus[id] = .ready
            self.observeForDiagnostics(l, id: id)
            self.diagnostics.event("load", ["channel": self.channel(id)?.name ?? "?", "plugin": ref.name, "ok": true,
                                            "format": Self.describe(unit.outputFormat(forBus: 0)),
                                            "inProcess": unit.auAudioUnit.isLoadedInProcess,
                                            "maxFrames": Int(unit.auAudioUnit.maximumFramesToRender),
                                            "version": Int(unit.auAudioUnit.componentVersion)])
            self.updateEngineRunning()
            self.onRoutingChange?()      // Parameterbereiche stehen erst jetzt fest
            if l.openInstrumentWhenLoaded { l.openInstrumentWhenLoaded = false; self.openInstrumentEditor(id) }
        }
    }

    // MARK: - Effekte

    func addEffect(_ ref: PluginRef, to id: UUID) {
        insertEffect(ref, at: channel(id)?.effects.count ?? 0, in: id, openEditor: false)
    }

    /// Belegt den Insert-Platz `index` (Wahl im Kanalzug, wie Planarium): ein dort sitzender
    /// Effekt wird entfernt; mit `ref` kommt der neue an dieselbe Stelle der Kette (höchstens
    /// ans Ende) und sein Editor öffnet sich, sobald er geladen ist. `nil` leert den Platz.
    func assignEffect(_ ref: PluginRef?, at index: Int, in id: UUID) {
        guard let data = channel(id), index >= 0 else { return }
        if data.effects.indices.contains(index) { removeEffect(at: index, from: id) }
        guard let ref else { return }
        insertEffect(ref, at: index, in: id, openEditor: true)
    }

    private func insertEffect(_ ref: PluginRef, at index: Int, in id: UUID, openEditor: Bool) {
        guard let idx = channels.firstIndex(where: { $0.id == id }), let l = live[id],
              channels[idx].effects.count < Self.maxEffectsPerChannel else { return }
        let at = max(0, min(index, channels[idx].effects.count))
        let token = UUID()
        channels[idx].effects.insert(ref, at: at)
        l.effects.insert(nil, at: at); l.effectTokens.insert(token, at: at)
        var st = effectStatus[id] ?? []
        st.insert(.loading, at: min(at, st.count)); effectStatus[id] = st
        if openEditor { l.openEffectWhenLoaded.insert(token) }
        loadEffect(ref, into: id, at: at)
        onProjectChange?()
    }

    func removeEffect(at index: Int, from id: UUID) {
        guard let idx = channels.firstIndex(where: { $0.id == id }), let l = live[id],
              channels[idx].effects.indices.contains(index) else { return }
        let token = l.effectTokens[index]
        l.openEffectWhenLoaded.remove(token)
        l.effectWindows.removeValue(forKey: token)?.close()
        if let n = l.effects[index], let e = engineStorage { e.detach(n) }
        channels[idx].effects.remove(at: index)
        l.effects.remove(at: index); l.effectTokens.remove(at: index)
        effectStatus[id]?.remove(at: index)
        rewire(l)
        onProjectChange?()
    }

    /// Verschiebt einen Effekt in der Kette (Signalfolge).
    func moveEffect(from index: Int, to target: Int, in id: UUID) {
        guard let idx = channels.firstIndex(where: { $0.id == id }), let l = live[id],
              channels[idx].effects.indices.contains(index),
              channels[idx].effects.indices.contains(target), index != target else { return }
        channels[idx].effects.insert(channels[idx].effects.remove(at: index), at: target)
        l.effects.insert(l.effects.remove(at: index), at: target)
        l.effectTokens.insert(l.effectTokens.remove(at: index), at: target)
        if var st = effectStatus[id], st.indices.contains(index), st.indices.contains(target) {
            st.insert(st.remove(at: index), at: target); effectStatus[id] = st
        }
        rewire(l)
        onProjectChange?()
    }

    func setEffectBypassed(_ bypassed: Bool, at index: Int, in id: UUID) {
        guard let idx = channels.firstIndex(where: { $0.id == id }), let l = live[id],
              channels[idx].effects.indices.contains(index),
              channels[idx].effects[index].bypassed != bypassed else { return }
        channels[idx].effects[index].bypassed = bypassed
        l.effects[index]?.auAudioUnit.shouldBypassEffect = bypassed
        onProjectChange?()
    }

    private func loadEffect(_ ref: PluginRef, into id: UUID, at index: Int) {
        guard let l = live[id], l.effectTokens.indices.contains(index) else { return }
        let token = l.effectTokens[index]
        instantiate(ref) { [weak self] unit in
            // Position über das Token suchen: die Kette kann sich inzwischen verschoben haben.
            guard let self, let l = self.live[id],
                  let i = l.effectTokens.firstIndex(of: token) else { return }
            guard let unit else { self.effectStatus[id]?[i] = .missing; return }
            self.restoreState(ref.state, into: unit)
            // Aktuellen Bypass-Stand anwenden (kann sich während des Ladens geändert haben).
            let bypassed = self.channel(id).flatMap { $0.effects.indices.contains(i) ? $0.effects[i].bypassed : nil }
            unit.auAudioUnit.shouldBypassEffect = bypassed ?? ref.bypassed
            self.engine().attach(unit)
            l.effects[i] = unit
            self.rewire(l)
            self.effectStatus[id]?[i] = .ready
            if l.openEffectWhenLoaded.remove(token) != nil { self.openEffectEditor(id, index: i) }
        }
    }

    // MARK: - Zustand sichern

    /// Liest den aktuellen Klangzustand aller geladenen Plug-ins in `channels` zurück.
    /// Vor jedem Speichern aufrufen. Nicht geladene (fehlende) Plug-ins behalten ihren
    /// zuletzt gespeicherten Zustand.
    func captureStates() {
        for idx in channels.indices {
            guard let l = live[channels[idx].id] else { continue }
            if let unit = l.instrument, let s = Self.stateData(of: unit) {
                channels[idx].instrument?.state = s
            }
            for i in channels[idx].effects.indices where l.effects.indices.contains(i) {
                if let unit = l.effects[i], let s = Self.stateData(of: unit) {
                    channels[idx].effects[i].state = s
                }
            }
        }
    }

    private static func stateData(of unit: AVAudioUnit) -> Data? {
        guard let state = unit.auAudioUnit.fullState else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
    }

    private func restoreState(_ data: Data?, into unit: AVAudioUnit) {
        guard let data,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any] else { return }
        unit.auAudioUnit.fullState = dict
    }

    // MARK: - Ereignisse von Main (Vorhören, Panik)

    /// - Parameter epoch: Belegung, für die das Ereignis gedacht ist (nil = aktuelle). Ein
    ///   verspätetes Off für eine inzwischen ersetzte Belegung wird so verworfen.
    @discardableResult
    func sendFromMain(route: Int, epoch: UInt32? = nil, _ b0: UInt8, _ b1: UInt8, _ b2: UInt8) -> Bool {
        guard route >= 0, route < Self.maxChannels else { return true }
        return queue(route).pushFromMain(b0, b1, b2, epoch: epoch)
    }

    /// Belegungsepoche des Slots eines Kanals (0 = kein Kanal). Main.
    func routeEpoch(for channelID: UUID?) -> UInt32 {
        let r = route(for: channelID)
        return r < 0 ? 0 : queue(r).occupancyEpoch
    }

    /// Verwirft alle geplanten Ereignisse aller Kanäle und beendet klingende Noten
    /// (All Notes Off auf allen 16 MIDI-Kanälen). Für Stop.
    func silenceAll() {
        for l in live.values {
            let q = queue(l.slot)
            q.invalidate()
            for ch in 0..<16 { q.pushFromMain(0xB0 | UInt8(ch), 123, 0) }
        }
    }

    // MARK: - Editor-Fenster

    func openInstrumentEditor(_ id: UUID) {
        guard let l = live[id], let unit = l.instrument else { return }
        if let w = l.instrumentWindow { w.makeKeyAndOrderFront(nil); return }
        let title = "\(channel(id)?.name ?? "") — \(channel(id)?.instrument?.name ?? "")"
        makeEditorWindow(for: unit, title: title) { [weak l] w in l?.instrumentWindow = w }
    }

    func openEffectEditor(_ id: UUID, index: Int) {
        guard let l = live[id], l.effects.indices.contains(index), let unit = l.effects[index] else { return }
        let token = l.effectTokens[index]
        if let w = l.effectWindows[token] { w.makeKeyAndOrderFront(nil); return }
        let name = channel(id)?.effects[index].name ?? ""
        makeEditorWindow(for: unit, title: "\(channel(id)?.name ?? "") — \(name)") { [weak l] w in
            l?.effectWindows[token] = w
        }
    }

    /// Baut das Editor-Fenster eines Plug-ins.
    ///
    /// `requestViewController` liefert bei out-of-process geladenen AUs immer einen
    /// (entfernten) Controller — auch für Plug-ins OHNE eigene Oberfläche; dessen View ist
    /// dann 1 × 1 Punkt groß (z. B. AUMatrixReverb). Ein so kleiner oder fehlender Editor
    /// wird durch die Parameteransicht des Systems ersetzt. Die Fenstergröße folgt der
    /// tatsächlichen Editorgröße.
    private func makeEditorWindow(for unit: AVAudioUnit, title: String, store: @escaping (NSWindow) -> Void) {
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
                guard let vc, let size else { return }
                let w = NSWindow(contentViewController: vc)
                w.title = title
                w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
                w.isReleasedWhenClosed = false
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

    // MARK: - Audio-Engine und Verdrahtung

    private func engine() -> AVAudioEngine {
        if let e = engineStorage { return e }
        let e = AVAudioEngine()
        engineStorage = e
        e.attach(masterGain)
        wireMasterGain()
        // Gerät/Abtastrate gewechselt: Kette mit dem neuen Format neu verbinden und
        // (die Engine hält dabei selbst an) wieder starten.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: e, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.diagnostics.event("config", ["running": e.isRunning,
                                              "output": Self.describe(e.outputNode.outputFormat(forBus: 0)),
                                              "device": AudioDiagnostics.defaultOutputDevice()])
            self.rebuildGraph()
        }
        return e
    }

    /// Verbindet alle Kanäle neu und startet die Engine (Geräte-/Formatwechsel, Wächter).
    private func rebuildGraph() {
        guard let e = engineStorage else { return }
        let began = Date()
        defer {
            diagnostics.event("rebuild", ["ms": Int(Date().timeIntervalSince(began) * 1000),
                                          "running": e.isRunning,
                                          "output": Self.describe(e.outputNode.outputFormat(forBus: 0))])
        }
        removeMasterTap()
        wireMasterGain()
        for l in live.values {
            removeMeterTap(l)
            e.disconnectNodeOutput(l.gain)
            e.disconnectNodeOutput(l.mixer)
            e.connect(l.gain, to: l.mixer, format: mixFormat())
            e.connect(l.mixer, to: e.mainMixerNode, format: mixFormat())
            installMeterTap(l)
            rewire(l)
            installObserver(l)
        }
        updateEngineRunning()
    }

    // MARK: - Wächter der Audioausgabe (v1.13.11, überarbeitet v1.13.14)
    //
    // Main-Thread, viermal je Sekunde, solange Instrumente geladen sind oder die
    // Audio-Diagnose aufzeichnet. Kein Zugriff aus Tick- oder Render-Pfad; die Messwerte
    // sind Atomics der Taps.
    //
    // Engine angehalten, keine Blöcke mehr (2 s) oder NaN/∞ in einem Tap → Stop, Reset,
    // Neuaufbau — dasselbe wie ein Gerätewechsel von Hand. Höchstens alle 3 s; ein Befund in
    // der Sperrfrist bleibt stehen, bis er behandelt ist. Danach wird geprüft, ob die Engine
    // wieder Blöcke liefert („erholt"), sonst „ohne Erfolg".

    enum WatchdogFinding: String { case stopped, stalled, nonFinite }
    enum RecoveryOutcome: String { case pending, recovered, failed }

    static let watchdogInterval: TimeInterval = 0.25
    /// Prüfungen ohne neuen Block, ab denen die Engine als stehend gilt (≈ 2 s).
    static let stallTicks = 8

    /// Reine Entscheidung des Wächters über die Engine.
    static func watchdogFinding(needed: Bool, running: Bool, tapInstalled: Bool,
                                stalledTicks: Int, nonFinite: Bool) -> WatchdogFinding? {
        guard needed else { return nil }
        if !running { return .stopped }
        if nonFinite { return .nonFinite }
        if tapInstalled, stalledTicks >= stallTicks { return .stalled }
        return nil
    }

    private var watchdog: Timer?
    private var watchdogLastBlocks = 0
    private var watchdogStalledTicks = 0
    private var watchdogLastRecovery = Date.distantPast
    private var recoveryCheck: (at: Date, blocks: Int)?
    /// Diagnose: Engine-Wiederherstellungen seit Programmstart, letzter Anlass und Ergebnis.
    private(set) var audioRecoveries = 0
    private(set) var lastRecoveryFinding: WatchdogFinding?
    private(set) var lastRecoveryOutcome: RecoveryOutcome?
    private static let log = Logger(subsystem: "com.firstoffifth.sequencer", category: "audio")

    private func updateWatchdog(needed instrumentsLoaded: Bool) {
        // Läuft auch ohne Instrumente, solange die Diagnose aufzeichnet (Messproben).
        let needed = instrumentsLoaded || diagnostics.isRecording
        if needed, watchdog == nil {
            watchdogLastBlocks = masterMeter.blockCount; watchdogStalledTicks = 0
            let t = Timer(timeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in
                self?.watchdogTick()
            }
            RunLoop.main.add(t, forMode: .common)
            watchdog = t
        } else if !needed, let t = watchdog {
            t.invalidate(); watchdog = nil
        }
    }

    private func watchdogTick() {
        if diagnostics.isRecording { recordDiagnosticSample() }
        guard let e = engineStorage else { return }
        let now = Date()

        let needed = live.values.contains { $0.instrument != nil }
        let blocks = masterMeter.blockCount
        watchdogStalledTicks = blocks == watchdogLastBlocks ? watchdogStalledTicks + 1 : 0
        watchdogLastBlocks = blocks

        // Ergebnis einer vorigen Wiederherstellung feststellen.
        if let check = recoveryCheck, now >= check.at {
            recoveryCheck = nil
            let ok = e.isRunning && masterMeter.blockCount > check.blocks
            lastRecoveryOutcome = ok ? .recovered : .failed
            if ok { Self.log.notice("Audioausgabe erholt") }
            else  { Self.log.error("Audioausgabe nach Wiederherstellung ohne Erfolg") }
            diagnostics.event("recovery", ["ok": ok])
        }

        // Ungültige Werte nur ansehen, nicht abholen: ein Befund in der Sperrfrist bleibt.
        let bad = masterMeter.hasNonFinite || live.values.contains { $0.meter.hasNonFinite }
        guard let finding = Self.watchdogFinding(needed: needed, running: e.isRunning,
                                                 tapInstalled: masterTapInstalled,
                                                 stalledTicks: watchdogStalledTicks, nonFinite: bad),
              now.timeIntervalSince(watchdogLastRecovery) > 3 else { return }
        watchdogLastRecovery = now
        watchdogStalledTicks = 0
        audioRecoveries += 1
        lastRecoveryFinding = finding
        lastRecoveryOutcome = .pending
        _ = masterMeter.takeNonFinite()
        live.values.forEach { _ = $0.meter.takeNonFinite() }
        Self.log.error("Audioausgabe: Wiederherstellung versucht (\(finding.rawValue, privacy: .public))")
        diagnostics.event("watchdog", ["finding": finding.rawValue])
        e.stop()
        e.reset()                      // Zustand der Knoten verwerfen (NaN im Filtergedächtnis)
        rebuildGraph()
        recoveryCheck = (now.addingTimeInterval(2), masterMeter.blockCount)
    }

    // MARK: - Audio-Diagnose (v1.13.14)

    private var diagLastMasterBlocks = 0
    private var diagLastChannelBlocks: [UUID: Int] = [:]
    private var diagLastQueue: [UUID: (rejected: Int, backlog: Int, pre: Int, post: Int, err: Int)] = [:]
    private var diagLastSample: Date?

    /// Signalwerte eines Messpunkts seit der letzten Probe (nach Fader bzw. Summen-Gain).
    private static func signalRow(_ d: LevelMeter.Diagnostics, blocks: Int) -> [String: Any] {
        ["peak": AudioDiagnostics.num(d.peak), "over1": d.over, "over16": d.over16, "nan": d.nonFinite,
         "dc": AudioDiagnostics.num(d.dc), "rms": AudioDiagnostics.num(d.rms), "blocks": blocks]
    }

    private static func describe(_ f: AVAudioFormat) -> String {
        "\(Int(f.sampleRate))/\(f.channelCount)\(f.isInterleaved ? "i" : "")"
    }

    private func diagnosticHeader() -> [String: Any] {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        var head: [String: Any] = ["engineRunning": engineStorage?.isRunning ?? false,
                                   "audioRecoveries": audioRecoveries,
                                   "hostTime": String(mach_absolute_time()),
                                   "timebase": "\(tb.numer)/\(tb.denom)", "schema": 1]
        if let e = engineStorage { head["output"] = Self.describe(e.outputNode.outputFormat(forBus: 0)) }
        head["channels"] = channels.map { c -> [String: Any] in
            var d: [String: Any] = ["name": c.name, "status": instrumentStatus[c.id].map { "\($0)" } ?? "-",
                                    "effects": c.effects.map(\.name)]
            if let i = c.instrument { d["instrument"] = i.name; d["component"] = i.componentKey }
            return d
        }
        return head
    }

    /// Eine Messprobe (Main, aus dem Wächter-Timer). Pegel sind Rohwerte nach dem Fader:
    /// `peak` darf weit über 1 liegen, `over` zählt Samples über 1,0, `nan` NaN/∞-Samples.
    private func recordDiagnosticSample() {
        var s: [String: Any] = [:]
        let now = Date()
        if let last = diagLastSample { s["dt"] = Int(now.timeIntervalSince(last) * 1000) }   // Timer-Verspätung
        diagLastSample = now
        let blocks = masterMeter.blockCount
        s["sum"] = Self.signalRow(masterMeter.takeDiagnostics(), blocks: blocks &- diagLastMasterBlocks)
        diagLastMasterBlocks = blocks
        if let e = engineStorage {
            s["engine"] = ["running": e.isRunning, "masterGainDB": AudioDiagnostics.num(masterGain.globalGain)]
        }
        var chans: [[String: Any]] = []
        for c in channels {
            guard let l = live[c.id] else { continue }
            let b = l.meter.blockCount
            var row = Self.signalRow(l.meter.takeDiagnostics(), blocks: b &- (diagLastChannelBlocks[c.id] ?? b))
            diagLastChannelBlocks[c.id] = b
            let q = queue(l.slot)
            let now = (rejected: q.rejected.load(ordering: .relaxed), backlog: q.backlog.load(ordering: .relaxed),
                       pre: q.preRenders.load(ordering: .relaxed), post: q.postRenders.load(ordering: .relaxed),
                       err: q.renderErrors.load(ordering: .relaxed))
            let last = diagLastQueue[c.id] ?? now
            diagLastQueue[c.id] = now
            row["name"] = c.name
            row["vol"] = AudioDiagnostics.num(c.volume)
            row["mute"] = c.isMuted
            row["rejected"] = now.rejected &- last.rejected
            row["backlog"] = now.backlog &- last.backlog
            row["auPre"] = now.pre &- last.pre             // Render-Durchläufe des Instruments
            row["auPost"] = now.post &- last.post
            row["auErr"] = now.err &- last.err
            if let u = l.instrument {
                row["rr"] = u.auAudioUnit.renderResourcesAllocated
                row["format"] = Self.describe(u.outputFormat(forBus: 0))
            }
            chans.append(row)
        }
        s["ch"] = chans
        var dev = AudioDiagnostics.defaultOutputDevice()
        dev["overloads"] = diagnostics.takeOverloads()
        s["device"] = dev
        diagnostics.event("s", s)
    }

    /// Plug-in-seitige Änderungen protokollieren: Presetwahl im Editor, neuer Parameterbaum,
    /// Gesamtzustand (Plug-ins melden einen Presetwechsel meist über `allParameterValues`).
    private func observeForDiagnostics(_ l: Live, id: UUID) {
        guard let au = l.instrument?.auAudioUnit else { l.diagnosticObservations = []; return }
        let report: (String) -> Void = { [weak self] what in
            DispatchQueue.main.async {
                guard let self, let d = self.channel(id) else { return }
                var f: [String: Any] = ["channel": d.name, "what": what]
                if let u = self.live[id]?.instrument {
                    f["preset"] = u.auAudioUnit.currentPreset?.name ?? "-"
                    f["format"] = Self.describe(u.outputFormat(forBus: 0))
                    f["rr"] = u.auAudioUnit.renderResourcesAllocated
                }
                self.diagnostics.event("au", f)
            }
        }
        l.diagnosticObservations = [
            au.observe(\.currentPreset) { _, _ in report("preset") },
            au.observe(\.parameterTree) { _, _ in report("parameterTree") },
            au.observe(\.allParameterValues) { _, _ in report("allParameterValues") },
        ]
    }

    private func pluginInvalidated(_ object: AnyObject?) {
        let hit = live.first { _, l in
            (l.instrument?.auAudioUnit).map { $0 === object } == true
                || l.effects.contains { ($0?.auAudioUnit).map { $0 === object } == true }
        }
        let name = hit.flatMap { channel($0.key)?.name } ?? "?"
        Self.log.error("Plug-in-Prozess beendet (Kanal \(name, privacy: .public))")
        diagnostics.event("invalidated", ["channel": name])
    }

    /// Main-Mixer → Gain-Stufe der Summe → Ausgang. Ohne bekanntes Ausgabeformat bleibt
    /// die Standardverbindung (Main-Mixer → Ausgang) bestehen.
    private func wireMasterGain() {
        guard let e = engineStorage else { return }
        if let format = mixFormat() {
            e.connect(e.mainMixerNode, to: masterGain, format: format)
            e.connect(masterGain, to: e.outputNode, format: format)
            masterGainWired = true
        } else {
            masterGainWired = false
        }
        applyMasterVolume()
    }

    /// Stereo in der Abtastrate des Ausgangs; nil, solange kein Ausgabegerät bekannt ist.
    private func mixFormat() -> AVAudioFormat? {
        guard let e = engineStorage else { return nil }
        let sr = e.outputNode.outputFormat(forBus: 0).sampleRate
        guard sr > 0 else { return nil }
        return AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)
    }

    /// Verbindet Instrument → Effekte (in Reihenfolge, nur geladene) → Gain-Stufe des Kanals.
    private func rewire(_ l: Live) {
        guard let e = engineStorage else { return }
        let chain: [AVAudioNode] = ([l.instrument] + l.effects).compactMap { $0 }
        chain.forEach { e.disconnectNodeOutput($0) }
        e.disconnectNodeInput(l.gain)
        guard l.instrument != nil else { return }
        let format = mixFormat()
        var upstream = chain[0]
        for node in chain.dropFirst() {
            e.connect(upstream, to: node, format: format)
            upstream = node
        }
        e.connect(upstream, to: l.gain, format: format)
        adoptNewNodes(chain)
    }

    /// Nimmt bei laufender Engine neu verbundene Plug-ins in den Renderweg auf.
    ///
    /// AVAudioEngine legt für einen Knoten, der an einen bei laufender Engine angelegten
    /// Kanal gehängt wird, keine Render-Ressourcen an: der Kanal bleibt stumm (gemessen
    /// v1.13.6, zweiter Kanal), und Plug-ins, die ihre Freischaltung bis dahin aufschieben
    /// (UADx: unscharfer Editor), bleiben im Ladezustand. Ein Neustart der Engine baut den
    /// Renderweg vollständig auf. Er unterbricht den Ton der übrigen Kanäle kurz — nur beim
    /// Laden oder Umstecken eines Plug-ins, nie im Spielbetrieb.
    private func adoptNewNodes(_ chain: [AVAudioNode]) {
        guard let e = engineStorage, e.isRunning,
              chain.contains(where: { !$0.auAudioUnit.renderResourcesAllocated }) else { return }
        diagnostics.event("restart", ["reason": "newNodes"])
        e.stop()
        e.prepare()
        do { try e.start(); engineError = nil }
        catch { engineError = error.localizedDescription }
        if isAudioRunning != e.isRunning { isAudioRunning = e.isRunning }
    }

    private func updateEngineRunning() {
        guard let e = engineStorage else { return }
        let needed = live.values.contains { $0.instrument != nil }
        if needed, !e.isRunning {
            installMasterTap()
            e.prepare()
            do { try e.start(); engineError = nil }
            catch { engineError = error.localizedDescription }
        } else if !needed, e.isRunning {
            e.stop()
            masterMeter.reset()
            live.values.forEach { $0.meter.reset() }
        }
        if isAudioRunning != e.isRunning { isAudioRunning = e.isRunning }
        updateWatchdog(needed: needed)
    }

    // MARK: - Pegelmessung
    //
    // Taps liefern auf einem Hilfsthread der Audio-Engine (nicht im Renderblock) und
    // schreiben nur zwei Atomics. Sie werden nur gesetzt, wenn ein Ausgabeformat bekannt
    // ist, und IMMER entfernt, bevor ein Knoten neu verbunden oder abgehängt wird —
    // AVFAudio wirft sonst nicht abfangbare Ausnahmen.

    private func installMeterTap(_ l: Live) {
        guard !l.tapInstalled, mixFormat() != nil else { return }
        let meter = l.meter
        l.mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in meter.feed(buffer) }
        l.tapInstalled = true
    }

    private func removeMeterTap(_ l: Live) {
        guard l.tapInstalled else { return }
        l.mixer.removeTap(onBus: 0)
        l.tapInstalled = false
        l.meter.reset()
    }

    private func installMasterTap() {
        guard !masterTapInstalled, let e = engineStorage, mixFormat() != nil else { return }
        let meter = masterMeter
        masterTapNode = masterGainWired ? masterGain : e.mainMixerNode
        masterTapNode?.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in meter.feed(buffer) }
        masterTapInstalled = true
    }

    private func removeMasterTap() {
        guard masterTapInstalled else { return }
        masterTapNode?.removeTap(onBus: 0)
        masterTapNode = nil
        masterTapInstalled = false
        masterMeter.reset()
    }

    private func instantiate(_ ref: PluginRef, completion: @escaping (AVAudioUnit?) -> Void) {
        #if DEBUG
        if let override = _instantiateOverride { override(ref, completion); return }
        #endif
        let d = ref.componentDescription
        // Nur out-of-process. Ein Rückfall auf das Laden im eigenen Prozess würde in der
        // Sandbox den Systemdialog „Sicherheitseinstellungen senken" auslösen (v1.13.7).
        AVAudioUnit.instantiate(with: d, options: .loadOutOfProcess) { [weak self] unit, error in
            DispatchQueue.main.async {
                if let error {
                    self?.diagnostics.event("loadError", ["plugin": ref.name, "error": "\(error)"])
                }
                completion(unit)
            }
        }
    }

    // MARK: - Render-Observer (Übergabe an den Audio-Thread)

    private func removeObserver(_ l: Live) {
        if let t = l.observerToken, let unit = l.instrument {
            unit.auAudioUnit.removeRenderObserver(t)
        }
        l.observerToken = nil
    }

    /// Hängt die Warteschlange des Kanals an den Render-Durchlauf seines Instruments.
    ///
    /// Der Block läuft auf dem Audio-Thread: er fängt nur die Warteschlange (unretained —
    /// das Rack hält sie für seine ganze Lebensdauer), den Schedule-Block des AUs und eine
    /// Konstante. Kein Heap, kein Lock, kein Zugriff auf Rack oder Engine.
    private func installObserver(_ l: Live) {
        removeObserver(l)
        guard let unit = l.instrument, let schedule = unit.auAudioUnit.scheduleMIDIEventBlock else { return }
        let scheduleParameter = unit.auAudioUnit.scheduleParameterBlock
        let sampleRate = unit.outputFormat(forBus: 0).sampleRate
        guard sampleRate > 0 else { return }
        let ticksPerFrame = Self.hostTicksPerSecond / sampleRate
        let queue = queues[l.slot]
        l.observerToken = unit.auAudioUnit.token(byAddingRenderObserver: { flags, timestamp, frameCount, _ in
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

    // MARK: - Test-Zugang

    #if DEBUG
    func _liveInstrument(_ id: UUID) -> AVAudioUnit? { live[id]?.instrument }
    var _engineIsRunning: Bool { engineStorage?.isRunning ?? false }
    /// Tatsächlich anliegender Kanalpegel als linearer Gain (Gain-Stufe × Stumm/Solo).
    func _liveOutputVolume(_ id: UUID) -> Float? {
        live[id].map { $0.mixer.outputVolume * powf(10, $0.gain.globalGain / 20) }
    }
    func _stopEngineBehindTheRacksBack() { engineStorage?.stop() }
    func _watchdogTick() { watchdogLastRecovery = .distantPast; watchdogTick() }
    /// Ersetzt das Laden von Plug-ins: der Test bekommt den Abschluss und ruft ihn selbst auf.
    var _instantiateOverride: ((PluginRef, @escaping (AVAudioUnit?) -> Void) -> Void)?
    /// Setzt das Instrument eines Kanals ohne Laden auf „bereit" (Parameterbindungs-Tests).
    func _markInstrumentReady(_ id: UUID, as ref: PluginRef) {
        guard let idx = channels.firstIndex(where: { $0.id == id }) else { return }
        channels[idx].instrument = ref
        instrumentStatus[id] = .ready
    }
    func _setParameters(_ list: [ParameterInfo], for id: UUID) { live[id]?.parameterCache = list }
    func _editorWindow(_ id: UUID, effect index: Int?) -> NSWindow? {
        guard let l = live[id] else { return nil }
        guard let index else { return l.instrumentWindow }
        return l.effectTokens.indices.contains(index) ? l.effectWindows[l.effectTokens[index]] : nil
    }
    #endif
}
