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
        /// Audio-Loop-Kanal (v1.15.0).
        var isAudioLoop = false
        /// `componentKey` je Effekt der Kette, sobald geladen; sonst nil (v1.17.1: Effekt als
        /// Ziel einer CC-Lane — der Kopf zeigt „?" bis zum Laden).
        var readyEffects: [String?] = []
    }
    @Published private(set) var entries: [Entry] = []

    fileprivate func update(_ channels: [InstrumentChannelData], status: [UUID: InstrumentRack.SlotStatus],
                            effects: [UUID: [InstrumentRack.SlotStatus]]) {
        let new = channels.map { c -> Entry in
            let st = effects[c.id] ?? []
            return Entry(id: c.id, name: c.name,
                         readyInstrument: status[c.id] == .ready ? c.instrument?.componentKey : nil,
                         isAudioLoop: c.audioLoop != nil,
                         readyEffects: c.effects.indices.map { st.indices.contains($0) && st[$0] == .ready
                                                               ? c.effects[$0].componentKey : nil })
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

    /// v1.17.3: 64 (vorher 16). Je Kanal fest angelegt: Instrument-Warteschlange (~100 KB),
    /// Loop-Kern, Notenbuch-Port, vier Effekt-Warteschlangen (je ~25 KB).
    static let maxChannels = 64
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
        didSet { directory.update(channels, status: instrumentStatus, effects: effectStatus) }
    }
    /// Kanalliste (ID + Name) für die Ausgangswahl der Spuren. Eigenes Objekt, damit
    /// Spurköpfe nur Anlegen/Löschen/Umbenennen sehen — nicht jede Faderbewegung.
    let directory = ChannelDirectory()
    @Published private(set) var instrumentStatus: [UUID: SlotStatus] = [:] {
        didSet { directory.update(channels, status: instrumentStatus, effects: effectStatus); updateRouteLatencies() }
    }
    @Published private(set) var effectStatus: [UUID: [SlotStatus]] = [:] {
        didSet { directory.update(channels, status: instrumentStatus, effects: effectStatus); updateRouteLatencies() }
    }

    // MARK: - Routenlatenz (v1.15.2, Codex T7)

    /// Deklarierte Latenz je Kanal (Instrument + Effekte + Gates, `AUAudioUnit.latency`) in
    /// Sekunden. AVAudioEngine gleicht Plug-in-Latenzen nicht aus; ohne Ausgleich klänge ein
    /// Kanal mit Lookahead-Effekt um dessen Latenz später als ein trockener.
    private(set) var routeLatency: [UUID: Double] = [:]
    /// Größte Routenlatenz (Sekunden): so weit muss die Clock zusätzlich vorausplanen.
    private(set) var maxRouteLatency: Double = 0
    /// Obergrenze des Ausgleichs (darüber wird nur bis hier ausgeglichen).
    static let maxRouteCompensation: Double = 0.1

    /// Liest die deklarierten Latenzen neu, setzt den Ausgleich je Slot und meldet eine
    /// geänderte Höchstlatenz an die Clock (Main; billig, auch aus dem Wächter).
    func updateRouteLatencies() {
        var lat: [UUID: Double] = [:]
        for (id, l) in live {
            var units: [AVAudioUnit] = l.effects.compactMap { $0 }
            if let i = l.instrument { units.append(i) }
            if let g = l.gatePre { units.append(g) }
            if let g = l.gatePost { units.append(g) }
            let sum = units.reduce(0.0) { $0 + max(0, $1.auAudioUnit.latency) }
            let v = min(Self.maxRouteCompensation, sum.isFinite ? sum : 0)
            lat[id] = v
            let host = UInt64(v * Self.hostTicksPerSecond)
            if queue(l.slot).latencyAdvance != host { queue(l.slot).setLatencyAdvance(host) }
            // Loop-Quelle: Instrument gibt es nicht, die Kette hinter der Quelle zählt.
            if l.source != nil, loopCore(l.slot).outputAdvanceHost != host { loopCore(l.slot).setOutputAdvance(host) }
            // Effekt-Parameter (v1.17.1): Audio am Ausgang hat diesen Effekt um die Latenz von
            // ihm selbst und allen späteren Effekten früher durchlaufen.
            var later = 0.0
            for (i, unit) in l.effects.enumerated().reversed() {
                later += max(0, unit?.auAudioUnit.latency ?? 0)
                guard let q = l.effectQueueSlots[l.effectTokens[i]] else { continue }
                let v = min(Self.maxRouteCompensation, later.isFinite ? later : 0)
                let h = UInt64(v * Self.hostTicksPerSecond)
                if effectQueue(q).latencyAdvance != h { effectQueue(q).setLatencyAdvance(h) }
            }
        }
        routeLatency = lat
        let m = lat.values.max() ?? 0
        if abs(m - maxRouteLatency) > 0.000_5 {
            maxRouteLatency = m
            onOutputConfigChange?()
        }
    }

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

    // MARK: - Audio-Loops (v1.15.0)

    /// Loop-Kerne, Taktanker, Material, Eingang, Anzeigen (eigener Besitzer, v1.18.4).
    let loops = AudioLoopController(count: InstrumentRack.maxChannels)
    /// Taktanker vom Tick-Thread für die Loop-Kerne.
    var barClock: BarClock { loops.barClock }
    /// Fester Block von Loop-Kernen, einer je Slot (Zugang aus Tick-, Eingangs- und
    /// Ausgangs-Render über den Slot-Index, wie `queues`).
    var loopCores: UnsafeMutablePointer<Unmanaged<AudioLoopCore>> { loops.cores }
    func loopCore(_ slot: Int) -> AudioLoopCore { loops.core(slot) }
    /// Was der Tick-Pfad vom Rack erreicht (v1.16.1, Codex V16-6): feste Blöcke und Taktanker.
    var tickOutputs: TickOutputs {
        TickOutputs(queues: queues, effectQueues: effectQueues, loopCores: loopCores, barClock: barClock,
                    hostSync: hostSync, owner: self)
    }

    // MARK: - Effekt-Warteschlangen (v1.17.1)

    /// Ein Platz je möglichem Effekt (`maxChannels × maxEffectsPerChannel`). Ein geladener
    /// Effekt belegt einen Platz, solange er geladen ist; der Tick-Pfad erreicht ihn über
    /// `ParameterTarget.queue` und die Belegung `ParameterTarget.epoch`, wie die Kanäle.
    static let effectQueueCount = maxChannels * maxEffectsPerChannel
    let effectQueues: UnsafeMutablePointer<Unmanaged<AUEventQueue>>
    @inline(__always)
    func effectQueue(_ i: Int) -> AUEventQueue { effectQueues[i].takeUnretainedValue() }
    private var freeEffectQueues: [Int] = Array((0..<InstrumentRack.effectQueueCount).reversed())

    // MARK: - Host-Takt für Plug-ins (v1.17.2)

    /// Tempo, Position, Transport für `musicalContextBlock`/`transportStateBlock` aller
    /// Instrumente und Effekte. Der Tick-Pfad schreibt (`TickOutputs.hostSync`). Liegt beim
    /// Loop-Controller (v1.18.13): die Zeitdehnung der Loops liest dieselbe Position.
    var hostSync: HostSync { loops.hostSync }
    /// Parameterkataloge und Zielauflösung (eigener Besitzer, v1.18.0).
    let catalog = ParameterCatalog()
    /// Laden, Klangzustand, Host-Bindung, Render-Observer, Editoren (eigener Besitzer, v1.18.5).
    private lazy var plugins = PluginLifecycle(hostSync: hostSync, recorder: diagnostics)

    /// Nutzung der Host-Blöcke je geladenem Plug-in (Diagnose, Tests).
    func hostBindingCalls(_ id: UUID) -> (instrument: Int, effects: [Int])? {
        guard let l = live[id] else { return nil }
        let inst = l.hostBinding.map { $0.musicCalls.load(ordering: .relaxed) + $0.transportCalls.load(ordering: .relaxed) } ?? 0
        let fx = l.effectTokens.map { t in
            l.effectHostBindings[t].map { $0.musicCalls.load(ordering: .relaxed) + $0.transportCalls.load(ordering: .relaxed) } ?? 0
        }
        return (inst, fx)
    }
    /// Loop-Kern eines Audio-Loop-Kanals (nil bei anderen Kanälen).
    func loopCore(for id: UUID?) -> AudioLoopCore? { loops.core(for: id) }
    func preencodeIdleLoops() { loops.preencodeIdle() }
    #if DEBUG
    var _preencodedCount: Int { loops.assets._preencodedCount }
    var _encodingCount: Int { loops.assets._encodingCount }
    var _loopStatusPolling: Bool { loops._statusPolling }
    #endif
    var inputEngine: AudioInputEngine { loops.inputEngine }
    func loopDisplay(_ id: UUID?) -> AudioLoopDisplay? { loops.display(id) }
    @discardableResult
    func refreshLoopDisplays() -> Bool { loops.refreshDisplays() }
    func kickLoopDisplays() { loops.kickDisplays() }

    // MARK: - Live-Zustand (Main)

    private final class Live {
        let slot: Int
        /// Gain-Stufe des Faders (−96 … +6 dB); der Mixer dahinter macht Panorama und Stumm.
        /// Trägt auch den Kanal-EQ (v1.18.11): Bänder nach `ChannelEQ.unitBands`.
        let gain = AVAudioUnitEQ(numberOfBands: ChannelEQ.unitBandCount)
        let mixer = AVAudioMixerNode()
        /// Pegel des Kanals nach Fader/Mute (vor dem Panorama).
        let meter = LevelMeter()
        var tapInstalled = false
        /// Kanalausgang hängt an der Summe (siehe `hook`).
        var hooked = false
        var instrument: AVAudioUnit?
        /// Umrechnung von der eigenen Rate des Instruments auf die Geräterate (v1.18.9),
        /// nur wenn `renderRate` von ihr abweicht.
        var rateStage: AVAudioMixerNode?
        /// Quelle eines Audio-Loop-Kanals (statt eines Instruments).
        var source: AVAudioSourceNode?
        /// Gate vor bzw. nach dem Fader (Audio-Loop-Kanäle, v1.15.0).
        var gatePre:  AVAudioUnit?
        var gatePost: AVAudioUnit?
        /// Laufender Ladeauftrag des Instruments. Nie wiederverwendet: ein verspäteter
        /// Abschluss trifft weder einen späteren Auftrag noch eine neue Live-Instanz
        /// desselben Kanals (H4, v1.13.13).
        var instrumentRequest: UUID?
        var observerToken: Int?
        /// Parallel zu `InstrumentChannelData.effects`.
        var effects: [AVAudioUnit?] = []
        var effectTokens: [UUID] = []
        /// Je geladenem Effekt (nach Token): Platz im Block `effectQueues`, Render-Observer,
        /// Parameterliste (v1.17.1).
        var effectQueueSlots: [UUID: Int] = [:]
        var effectObserverTokens: [UUID: Int] = [:]
        /// Host-Takt-Bindung je Installation (v1.17.6): Instrument und Effekte (Token).
        var hostBinding: HostBinding?
        var effectHostBindings: [UUID: HostBinding] = [:]
        /// Editor nach dem Laden öffnen (ausdrückliche Wahl im Kanalzug).
        var openInstrumentWhenLoaded = false
        var openEffectWhenLoaded: Set<UUID> = []
        init(slot: Int) { self.slot = slot }
    }

    private var live: [UUID: Live] = [:]
    private var freeSlots: [Int] = Array((0..<InstrumentRack.maxChannels).reversed())
    /// Audio-Engine, Summe, Format, Lauf (eigener Besitzer, v1.18.3).
    private lazy var graph: AudioGraph = {
        let g = AudioGraph(masterMeter: masterMeter)
        g.onStarted = { [weak self] in self?.graphStarted() }
        g.onWillStart = { [weak self] in self?.reaffirmHostBindings(force: true) }
        g.onFault = { [weak self] reason in self?.graphFaulted(reason) }
        g.onConfigurationChange = { [weak self] e in
            guard let self else { return }
            self.diagnostics.event("config", ["running": e.isRunning,
                                              "output": Self.describe(e.outputNode.outputFormat(forBus: 0)),
                                              "device": AudioDiagnostics.defaultOutputDevice()])
            self.rebuildGraphUnlessRecovering()
        }
        return g
    }()
    /// Die Engine für Umbauten; nil, solange keine angelegt ist oder der Graph außer Betrieb ist
    /// (`AudioGraph.faulted`, v1.18.38): danach baut kein Weg des Racks mehr um (Codex R38-R2-01).
    private var engineStorage: AVAudioEngine? { graph.faulted == nil ? graph.engineIfCreated : nil }
    private var invalidationObserver: NSObjectProtocol?
    /// Audio-Diagnose (Aufzeichnung im Betrieb, Menü „Hilfe").
    let diagnostics = AudioDiagnostics()
    /// Messproben und Plug-in-Beobachtung (eigener Besitzer, v1.18.1).
    private lazy var rackDiagnostics = RackDiagnostics(recorder: diagnostics)

    private static let hostTicksPerSecond: Double = {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        return 1_000_000_000.0 * Double(tb.denom) / Double(tb.numer)
    }()

    // MARK: - Init

    init() {
        queues = .allocate(capacity: Self.maxChannels)
        for i in 0..<Self.maxChannels { (queues + i).initialize(to: .passRetained(AUEventQueue())) }
        effectQueues = .allocate(capacity: Self.effectQueueCount)
        for i in 0..<Self.effectQueueCount { (effectQueues + i).initialize(to: .passRetained(
            AUEventQueue(ringCapacity: 256, pendingCapacity: 128))) }
        catalog.host = self
        loops.host = self
        loops.devices.probe = { [weak self] in
            guard let self else { return (.init(), .init()) }
            let inp = self.loops.inputEngine
            let input = AudioDeviceState.endpoint(unit: inp.inputUnit, running: inp.isRunning, format: inp.format,
                                                  input: true, error: inp.isRunning ? nil : inp.lastError)
            let e = self.engineStorage
            let output = AudioDeviceState.endpoint(unit: e?.outputNode.audioUnit, running: self.graph.isRunning,
                                                   format: e?.outputNode.outputFormat(forBus: 0), input: false,
                                                   error: self.graph.isRunning ? nil : self.graph.startError)
            return (input, output)
        }
        loops.devices.refresh()
        catalog.onChange = { [weak self] in self?.onRoutingChange?() }
        GateAudioUnit.register()
        diagnostics.header = { [weak self] in
            guard let self else { return [:] }
            return self.rackDiagnostics.header(self.diagnosticProbe())
        }
        diagnostics.onRecordingChange = { [weak self] _ in
            guard let self else { return }
            self.updateWatchdog(needed: self.live.values.contains { $0.instrument != nil })
        }
        // Ein ausgelagertes Plug-in hat seinen Prozess verloren (Absturz des AU-Hosts).
        // Nie `queue: .main` (v1.18.20, iMac-Hänger): mit Warteschlange wartet der Absender, bis
        // Main den Block ausgeführt hat. Absender ist die XPC-Warteschlange des Plug-ins — dieselbe,
        // die einem synchronen Aufruf von Main (z. B. `detach` beim Instrumentwechsel) antworten
        // müsste. Beide warten aufeinander. Darum hier sofort zurückkehren, Main bekommt es später.
        invalidationObserver = NotificationCenter.default.addObserver(
            forName: Self.invalidationName, object: nil, queue: nil
        ) { [weak self] note in
            let object = note.object as AnyObject?
            DispatchQueue.main.async { self?.pluginInvalidated(object) }
        }
    }

    deinit {
        // Erst die Engine anhalten: Render-Observer und Loop-Quellen lesen Warteschlangen und
        // Kerne, die danach freigegeben werden (Rack-Block hier, Loop-Kerne mit `loops`).
        graph.stop()
        loops.inputEngine.stop()
        if let o = invalidationObserver { NotificationCenter.default.removeObserver(o) }
        for l in live.values {
            removeObserver(l)
            for (token, t) in l.effectObserverTokens {
                plugins.removeObserver(t, from: l.effectTokens.firstIndex(of: token).flatMap { l.effects[$0] })
            }
        }
        for i in 0..<Self.maxChannels { queues[i].release() }
        queues.deinitialize(count: Self.maxChannels); queues.deallocate()
        for i in 0..<Self.effectQueueCount { effectQueues[i].release() }
        effectQueues.deinitialize(count: Self.effectQueueCount); effectQueues.deallocate()
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

    // MARK: - Parameter (Fassade über `ParameterCatalog`, v1.18.0)

    typealias ParameterInfo = ParameterCatalog.Info
    typealias ParameterSource = ParameterCatalog.Source

    func parameters(for id: UUID) -> [ParameterInfo] { catalog.parameters(for: id) }
    func effectParameters(for id: UUID, at index: Int) -> [ParameterInfo] {
        catalog.effectParameters(for: id, at: index)
    }
    func parameterRange(_ address: UInt64, in id: UUID) -> (min: Float, max: Float)? {
        catalog.parameterRange(address, in: id)
    }
    func parameterSources(for id: UUID) -> [ParameterSource] { catalog.sources(for: id) }
    func parameters(for id: UUID, source: ParameterSource) -> [ParameterInfo] {
        catalog.parameters(for: id, source: source)
    }
    static func parameterRef(_ p: ParameterInfo, of source: ParameterSource) -> ParameterRef {
        ParameterCatalog.ref(p, of: source)
    }
    func parameterSource(of ref: ParameterRef, in id: UUID) -> ParameterSource? { catalog.source(of: ref, in: id) }
    func bindEffectInstance(_ ref: ParameterRef, in id: UUID) -> ParameterRef { catalog.bindEffectInstance(ref, in: id) }
    func resolveParameter(_ ref: ParameterRef, in id: UUID) -> ParameterTarget? { catalog.resolve(ref, in: id) }

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
        if copy.audioLoop != nil { loops.copyMaterial(from: id, to: copy.id) }
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

    private func applyMasterVolume() { graph.applyMasterVolume(masterVolume) }

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
            // Effekt-Instanzen: fehlende (ältere Dateien) und doppelte neu vergeben.
            var seen = Set<UUID>()
            for i in data.effects.indices {
                if let inst = data.effects[i].instance, seen.insert(inst).inserted { continue }
                let fresh = UUID(); data.effects[i].instance = fresh; seen.insert(fresh)
            }
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
        q.prefault()                                      // Puffer des Kanals real belegen (Main)
        q.setActive(false); q.invalidate(); q.beginOccupancy()
        // Loop-Kern folgt derselben Belegung.
        loops.occupy(slot: slot, epoch: q.occupancyEpoch, loop: data.audioLoop.map { (data.id, $0) })
        if let e = engine() {
            e.attach(l.gain); e.attach(l.mixer)
            e.connect(l.gain, to: l.mixer, format: mixFormat())
            hook(l)
            installMeterTap(l)
        }
        Self.apply(data.eq, to: l.gain)
        applyMix(data, to: l)
        if let settings = data.audioLoop {
            installLoopSource(l)
            loops.configure(data.id, settings)
        }
    }

    private func uninstall(_ id: UUID) {
        guard let l = live.removeValue(forKey: id) else { return }
        l.instrumentRequest = nil
        let q = queue(l.slot)
        q.setActive(false); q.invalidate(); q.beginOccupancy()
        removeObserver(l)
        for token in l.effectTokens { releaseEffectQueue(l, token: token); plugins.closeEditor(.effect(token)) }
        plugins.closeEditor(.instrument(id))
        removeMeterTap(l)
        loops.vacate(id, slot: l.slot, epoch: q.occupancyEpoch)
        if let e = engineStorage {
            // Plug-ins zuerst über die Fehlergrenze; scheitert eines, ist der Graph außer Betrieb
            // und die gespeicherte Engine `e` wird nicht mehr angefasst (Codex R38-R3-01).
            let plugins = ([l.instrument] + l.effects).compactMap { $0 }
            if plugins.allSatisfy({ graph.detach($0) }) {
                if let n = l.source { e.detach(n) }
                if let n = l.gatePre { e.detach(n) }
                if let n = l.gatePost { e.detach(n) }
                if let n = l.rateStage { e.detach(n) }
                e.detach(l.gain); e.detach(l.mixer)
            }
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

    // MARK: Kanal-EQ (v1.18.11) — Schreibweg Rack, kein Undo (wie Pegel/Pan)

    func setEQ(_ eq: ChannelEQ, for id: UUID) {
        var e = eq; e.clamp()
        mutate(id) { $0.eq = e }
    }
    func setEQOn(_ on: Bool, for id: UUID) { mutate(id) { $0.eq.isOn = on } }
    func setEQBand(_ band: ChannelEQ.Band, at index: Int, for id: UUID) {
        guard ChannelEQ.defaultBands.indices.contains(index), band.kind == ChannelEQ.defaultBands[index].kind else { return }
        var b = band; b.clamp()
        mutate(id) { $0.eq.bands[index] = b }
    }
    func setEQBandOn(_ on: Bool, band index: Int, for id: UUID) {
        guard ChannelEQ.defaultBands.indices.contains(index) else { return }
        mutate(id) { $0.eq.bands[index].isOn = on }
    }

    /// Setzt die Stufen des EQ in die Gain-Stufe eines Kanals (Main). Nur geänderte Werte
    /// werden geschrieben; der Fader (`globalGain`) bleibt unberührt.
    static func apply(_ eq: ChannelEQ, to unit: AVAudioUnitEQ) {
        for (b, u) in zip(unit.bands, eq.unitBands) {
            if u.bypass { if !b.bypass { b.bypass = true }; continue }
            if b.filterType != u.type { b.filterType = u.type }
            if b.frequency != u.frequency { b.frequency = u.frequency }
            if b.gain != u.gain { b.gain = u.gain }
            if b.bandwidth != u.bandwidth { b.bandwidth = u.bandwidth }
            if b.bypass { b.bypass = false }
        }
    }

    private func mutate(_ id: UUID, _ change: (inout InstrumentChannelData) -> Void) {
        guard let idx = channels.firstIndex(where: { $0.id == id }) else { return }
        var data = channels[idx]
        change(&data)
        guard data != channels[idx] else { return }
        let soloChanged = data.isSoloed != channels[idx].isSoloed
        let eqChanged = data.eq != channels[idx].eq
        channels[idx] = data
        if eqChanged, let l = live[id] { Self.apply(data.eq, to: l.gain) }
        if let a = data.audioLoop { loops.settingsChanged(id, a) }
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

    /// Lädt eine Instrumentdatei (EXS, SoundFont, DLS, aupreset) in einen Apple Sampler auf dem
    /// Kanal (v1.18.16): Umwandlung im App-Prozess, dann wie jedes Instrument mit Zustand.
    /// Abschluss auf Main: nil = geladen bzw. Laden begonnen.
    func loadSamplerInstrument(_ url: URL, for id: UUID, completion: @escaping (AppleSampler.Failure?) -> Void) {
        AppleSampler.convert(url) { [weak self] result in
            guard let self, self.live[id] != nil else { return }
            switch result {
            case .failure(let f):
                self.diagnostics.event("samplerLoad", ["file": url.lastPathComponent, "ok": false, "error": "\(f)"])
                completion(f)
            case .success(let converted):
                let name = "Apple Sampler · " + url.deletingPathExtension().lastPathComponent
                var ref = PluginRef(description: AppleSampler.description, name: name, state: converted.state)
                ref.drumMap = converted.drumMap
                self.setInstrument(ref, for: id)
                self.diagnostics.event("samplerLoad", ["file": url.lastPathComponent, "ok": true,
                                                       "drumGroups": converted.drumMap?.hasGroups ?? false])
                completion(nil)
            }
        }
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

    private func teardownInstrument(_ l: Live, rewire doRewire: Bool = true) {
        l.openInstrumentWhenLoaded = false
        l.instrumentRequest = nil
        let q = queue(l.slot)
        q.setActive(false); q.invalidate(); q.beginOccupancy(); q.setDrumMap(nil)
        removeObserver(l)
        if let n = l.instrument, engineStorage != nil { graph.detach(n) }
        if let m = l.rateStage, let e = engineStorage { e.disconnectNodeOutput(m); e.detach(m); l.rateStage = nil }
        l.instrument = nil
        l.hostBinding = nil
        if let id = live.first(where: { $0.value === l })?.key {
            plugins.closeEditor(.instrument(id))
            catalog.instrumentUnloaded(channel: id)
            rackDiagnostics.forget(channel: id)
        }
        if doRewire { rewire(l) }
    }

    private func loadInstrument(_ ref: PluginRef, into id: UUID) {
        guard let l = live[id] else { return }
        guard graph.faulted == nil else { instrumentStatus[id] = .missing; return }   // außer Betrieb
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
            PluginLifecycle.restoreState(ref.state, into: unit)
            l.hostBinding = self.plugins.bindHost(unit, queue: self.queues[l.slot])
            guard self.graph.attach(unit) else {                 // Graph außer Betrieb
                l.hostBinding = nil; self.instrumentStatus[id] = .missing; return
            }
            l.instrument = unit
            guard self.rewire(l) else { return }     // Kette tot: abgebaut, Durchlauf lädt nach
            self.installObserver(l)
            if !self.graph.isRunning { self.plugins.confirm(l.hostBinding, unit) }   // nie beim Rendern
            let q = self.queue(l.slot)
            q.invalidate(); q.beginOccupancy()
            q.setDrumMap(AppleSampler.isSampler(ref) ? ref.drumMap : nil)
            q.setActive(!(self.channel(id)?.instrument?.bypassed ?? false))
            self.instrumentStatus[id] = .ready
            self.rackDiagnostics.observe(unit, channel: id) { [weak self] in self?.channel(id)?.name }
            self.catalog.instrumentLoaded(unit, channel: id)
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
        var ref = ref
        ref.instance = UUID()                 // neue Instanz (auch beim Austausch auf einem Platz)
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
        plugins.closeEditor(.effect(token))
        releaseEffectQueue(l, token: token)               // vor dem Abhängen: Observer zuerst weg
        if let n = l.effects[index], engineStorage != nil { graph.detach(n) }
        channels[idx].effects.remove(at: index)
        l.effects.remove(at: index); l.effectTokens.remove(at: index)
        effectStatus[id]?.remove(at: index)
        rewire(l)
        onRoutingChange?()           // Effekt-Ziele: Platz frei, laufende Nummern verschoben
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
        updateRouteLatencies()       // Latenz der späteren Effekte je Effekt neu
        onRoutingChange?()           // laufende Nummer gleicher Plug-ins kann sich ändern
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
        guard graph.faulted == nil else { effectStatus[id]?[index] = .missing; return }   // außer Betrieb
        let token = l.effectTokens[index]
        instantiate(ref) { [weak self] unit in
            // Position über das Token suchen: die Kette kann sich inzwischen verschoben haben.
            guard let self, let l = self.live[id],
                  let i = l.effectTokens.firstIndex(of: token) else { return }
            guard let unit else { self.effectStatus[id]?[i] = .missing; return }
            PluginLifecycle.restoreState(ref.state, into: unit)
            // Aktuellen Bypass-Stand anwenden (kann sich während des Ladens geändert haben).
            let bypassed = self.channel(id).flatMap { $0.effects.indices.contains(i) ? $0.effects[i].bypassed : nil }
            unit.auAudioUnit.shouldBypassEffect = bypassed ?? ref.bypassed
            if let slot = self.reserveEffectQueue(l, token: token) {
                l.effectHostBindings[token] = self.plugins.bindHost(unit, queue: self.effectQueues[slot])
            }
            guard self.graph.attach(unit) else {                 // Graph außer Betrieb
                self.releaseEffectQueue(l, token: token); self.effectStatus[id]?[i] = .missing; return
            }
            l.effects[i] = unit
            guard self.rewire(l) else { return }     // Kette tot: abgebaut, Durchlauf lädt nach
            self.installEffectObserver(l, token: token, unit: unit)
            if !self.graph.isRunning { self.plugins.confirm(l.effectHostBindings[token], unit) }
            self.catalog.effectLoaded(unit, token: token)
            self.effectStatus[id]?[i] = .ready
            self.onRoutingChange?()      // Parameterziele dieses Effekts werden auflösbar
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
            if let unit = l.instrument, let s = PluginLifecycle.stateData(of: unit) {
                channels[idx].instrument?.state = s
            }
            for i in channels[idx].effects.indices where l.effects.indices.contains(i) {
                if let unit = l.effects[i], let s = PluginLifecycle.stateData(of: unit) {
                    channels[idx].effects[i].state = s
                }
            }
        }
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

    /// Route einer Spur nach ihrem Ausgang (v1.16.0, Codex M4): eine Noten-/CC-Spur erreicht
    /// nur Instrumentenkanäle, eine Loop-Spur nur Loop-Kanäle. Alles andere ist MIDI (−1) —
    /// geprüft an einer Stelle statt nachträglich geklemmt.
    func route(for output: TrackOutput) -> Int {
        switch output {
        case .midi: return -1
        case .instrument(let id):
            guard channel(id)?.source.isAudioLoop == false else { return -1 }
            return route(for: id)
        case .audioLoop(let id):
            guard channel(id)?.source.isAudioLoop == true else { return -1 }
            return route(for: id)
        }
    }
    func routeEpoch(for output: TrackOutput) -> UInt32 {
        let r = route(for: output)
        return r < 0 ? 0 : queue(r).occupancyEpoch
    }

    /// Verwirft alle geplanten Ereignisse aller Kanäle und beendet klingende Noten
    /// (All Notes Off auf allen 16 MIDI-Kanälen). Für Stop.
    func silenceAll() {
        for l in live.values {
            let q = queue(l.slot)
            q.invalidate()
            for ch in 0..<16 { q.pushFromMain(0xB0 | UInt8(ch), 123, 0) }
            for slot in l.effectQueueSlots.values { effectQueue(slot).invalidate() }
        }
    }

    // MARK: - Editor-Fenster

    func openInstrumentEditor(_ id: UUID) {
        guard let unit = live[id]?.instrument else { return }
        plugins.openEditor(.instrument(id), unit: unit,
                           title: "\(channel(id)?.name ?? "") — \(channel(id)?.instrument?.name ?? "")")
    }

    func openEffectEditor(_ id: UUID, index: Int) {
        guard let l = live[id], l.effects.indices.contains(index), let unit = l.effects[index] else { return }
        let name = channel(id)?.effects[index].name ?? ""
        plugins.openEditor(.effect(l.effectTokens[index]), unit: unit, title: "\(channel(id)?.name ?? "") — \(name)")
    }

    // MARK: - Audio-Engine und Verdrahtung

    /// Legt die Engine bei Bedarf an; nil, wenn der Graph außer Betrieb ist.
    private func engine() -> AVAudioEngine? { graph.faulted == nil ? graph.engine() : nil }

    /// Nach jedem (Neu-)Start der Engine: Fehler und Laufzustand veröffentlichen. Die
    /// Host-Blöcke bestätigt `onWillStart` vorher, solange die Engine steht.
    private func graphStarted() {
        if engineError != graph.startError { engineError = graph.startError }
        scheduleHostBlockCheck()
        if isAudioRunning != graph.isRunning { isAudioRunning = graph.isRunning }
        loops.devices.refresh()
        onOutputConfigChange?()   // Clock-Vorlauf vom Gerät der Engine (v1.18.15)
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
        graph.removeMasterTap()
        graph.wireMaster()
        for l in live.values {
            guard graph.faulted == nil else { break }        // Umbau ab Stilllegung sofort beenden
            removeMeterTap(l)
            e.disconnectNodeOutput(l.gain)
            if let gp = l.gatePost { e.disconnectNodeOutput(gp) }
            e.disconnectNodeOutput(l.mixer); l.hooked = false
            wireFader(l)
            hook(l)
            installMeterTap(l)
            if l.source != nil { installLoopSource(l) }   // neue Abtastrate → neue Quelle
            rewire(l)
            installObserver(l)
        }
        loops.resample()
        updateEngineRunning()
        onOutputConfigChange?()   // Vorläufe der Clock an neuen Puffer anpassen (Codex R8)
    }

    /// Ausgabeformat/-gerät hat sich geändert (nach dem Umbau des Graphen). Main.
    var onOutputConfigChange: (() -> Void)?

    /// Ausgabepuffer in Sekunden für den Clock-Vorlauf (v1.18.15): bei laufender Engine vom Gerät,
    /// an dem ihre Ausgabe-Einheit hängt — der Systemstandard kann ein anderes sein —, sonst vom
    /// Standardgerät (dort startet die Engine). Main.
    var outputBufferSeconds: Double {
        let id = graph.isRunning ? AudioDevices.current(of: engineStorage?.outputNode.audioUnit) : nil
        return (id ?? AudioDevices.systemDefault(input: false)).flatMap { AudioDevices.bufferSeconds($0, input: false) }
            ?? 512.0 / 48_000
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

    private static let log = Logger(subsystem: "com.firstoffifth.sequencer", category: "audio")
    typealias WatchdogFinding = OutputWatchdog.Finding
    typealias RecoveryOutcome = OutputWatchdog.Outcome
    static var watchdogInterval: TimeInterval { OutputWatchdog.interval }
    static var stallTicks: Int { OutputWatchdog.stallTicks }
    static func watchdogFinding(needed: Bool, running: Bool, tapInstalled: Bool,
                                stalledTicks: Int, nonFinite: Bool) -> WatchdogFinding? {
        OutputWatchdog.finding(needed: needed, running: running, tapInstalled: tapInstalled,
                               stalledTicks: stalledTicks, nonFinite: nonFinite)
    }

    /// Wächter (eigener Besitzer, Codex M6). Das Rack liefert Messwerte und führt die
    /// Wiederherstellung aus.
    private lazy var watchdog: OutputWatchdog = {
        let w = OutputWatchdog()
        w.onTick = { [weak self] in
            guard let self else { return }
            if self.diagnostics.isRecording { self.rackDiagnostics.sample(self.diagnosticProbe()) }
            self.updateRouteLatencies()   // Plug-ins können ihre Latenz zur Laufzeit ändern
        }
        w.read = { [weak self] in
            guard let self, let e = self.engineStorage else { return nil }
            return OutputWatchdog.Reading(
                needed: self.graph.faulted == nil && !self.isRecoveringPlugins
                    && self.live.values.contains { $0.instrument != nil },
                running: e.isRunning, tapInstalled: self.graph.masterTapInstalled,
                blocks: self.masterMeter.blockCount,
                nonFinite: self.masterMeter.hasNonFinite || self.live.values.contains { $0.meter.hasNonFinite })
        }
        w.recover = { [weak self] finding in
            guard let self, self.engineStorage != nil else { return 0 }   // nil auch außer Betrieb
            _ = self.masterMeter.takeNonFinite()
            self.live.values.forEach { _ = $0.meter.takeNonFinite() }
            self.diagnostics.event("watchdog", ["finding": finding.rawValue])
            self.graph.stopAndReset()      // Zustand der Knoten verwerfen (NaN im Filtergedächtnis)
            self.rebuildGraph()                  // startet neu; Host-Blöcke vor dem Start
            return self.masterMeter.blockCount
        }
        w.onOutcome = { [weak self] ok in self?.diagnostics.event("recovery", ["ok": ok]) }
        return w
    }()
    /// Diagnose: Engine-Wiederherstellungen seit Programmstart, letzter Anlass und Ergebnis.
    var audioRecoveries: Int { watchdog.recoveries }
    var lastRecoveryFinding: WatchdogFinding? { watchdog.lastFinding }
    var lastRecoveryOutcome: RecoveryOutcome? { watchdog.lastOutcome }

    private func updateWatchdog(needed instrumentsLoaded: Bool) {
        // Läuft auch ohne Instrumente, solange die Diagnose aufzeichnet (Messproben).
        watchdog.update(needed: instrumentsLoaded || diagnostics.isRecording,
                        currentBlocks: masterMeter.blockCount)
    }

    // MARK: - Audio-Diagnose (v1.13.14; Besitzer `RackDiagnostics` seit v1.18.1)

    private static func describe(_ f: AVAudioFormat) -> String { RackDiagnostics.describe(f) }

    /// Schreibgeschützte Momentaufnahme für Kopf und Messprobe.
    private func diagnosticProbe() -> RackDiagnostics.Probe {
        let chans = channels.compactMap { c -> RackDiagnostics.ChannelProbe? in
            guard let l = live[c.id] else { return nil }
            let calls = hostBindingCalls(c.id).map { [$0.instrument] + $0.effects }
            return .init(data: c, status: instrumentStatus[c.id].map { "\($0)" } ?? "-", meter: l.meter,
                         queue: queue(l.slot), instrument: l.instrument,
                         latencySeconds: routeLatency[c.id] ?? 0,
                         loop: l.source != nil ? loopCore(l.slot) : nil, hostCalls: calls)
        }
        return .init(engine: engineStorage, recoveries: audioRecoveries, masterMeter: masterMeter,
                     masterGainDB: graph.masterGainDB, channels: chans)
    }

    static let invalidationName = NSNotification.Name(rawValue: kAudioComponentInstanceInvalidationNotification as String)

    // MARK: Wiederanlauf nach Absturz des Plug-in-Prozesses (v1.18.32)
    //
    // Alle out-of-process geladenen Plug-ins von FoF teilen sich einen AU-Host-Prozess. Stürzt
    // eines ab (gemessen: Shortcircuit XT 0.9.316 beim Abbau, GUI-Abbau auf dem XPC-Thread),
    // sind alle übrigen Instanzen tot: jeder Block meldet einen Fehler, der Kanal bleibt still.
    // FoF lädt jeden betroffenen Platz (Instrument oder Effekt) neu, mit dem zuletzt bekannten
    // Zustand aus dem Modell (letztes Laden/Speichern; den Zustand der toten Instanz kann
    // niemand mehr lesen — vorher ging er beim Speichern ebenso verloren). Stürzt derselbe
    // Platz innerhalb von `recoveryLockout` nach einem Neustart erneut ab, gibt FoF auf
    // (Status „fehlt"), damit ein Plug-in, das beim Laden abstürzt, keine Schleife erzeugt.

    /// Sperrzeit je Platz (Tests setzen sie hoch, damit ein langsamer Volllauf sie nicht überschreitet).
    var recoveryLockout: TimeInterval = 10
    private var recoveredAt: [UUID: Date] = [:]          // Kanal (Instrument) bzw. Token (Effekt)

    // Gesammelter Durchlauf (v1.18.37, iMac-Absturz 17:18): die Meldungen kommen je Instanz
    // einzeln auf Main an. Der alte Weg lud den gemeldeten Effekt neu und verband dabei den
    // Kanal mit seinem noch nicht gemeldeten, toten Instrument — `AVAudioEngine.connect` wirft
    // dann eine ObjC-Ausnahme (AUInterfaceBaseV3::SetFormat) und beendet FoF. Darum:
    // 1. Jede Meldung löst ihre Einheit sofort aus der Engine (abbauen bzw. lösen, ohne zu
    //    verbinden); danach berührt kein Start, kein `prepare`, keine Host-Bestätigung sie mehr.
    // 2. Bis zum Durchlauf keine automatischen Starts, `adopt`-Neustarts, Wächter- oder
    //    Geräte-Neuaufbauten (`isRecoveringPlugins`).
    // 3. Erst wenn `recoveryQuietTime` lang keine Meldung mehr kam, verbindet ein Durchlauf
    //    jeden betroffenen Kanal einmal neu und lädt die Plätze nach.
    // Keine Annahme über Prozesse (Codex-Review 1.18.37: native und Rosetta-Plug-ins haben
    // getrennte Hosting-Dienste) und keine gespeicherten Objektkennungen: tot ist, was sich
    // meldet. Grenze: eine tote Einheit, deren Meldung noch aussteht, kennt FoF nicht; trifft
    // eine Nutzeraktion ihren Kanal vor der Meldung, kann `connect` weiterhin werfen.

    /// Ruhezeit nach der letzten Meldung bis zum Durchlauf. Bündelt die Meldungen eines
    /// Absturzes; sie garantiert nicht, dass alle toten Einheiten gemeldet sind.
    var recoveryQuietTime: TimeInterval = 0.3
    /// Tests: jede Kette, die `rewire` verbindet.
    var _rewireObserver: (([AVAudioNode]) -> Void)?
    /// Kanäle mit gelösten toten Plätzen bis zum Durchlauf: Instrument, Effektplätze (Token).
    private var pendingRecovery: [UUID: (instrument: Bool, effects: Set<UUID>)] = [:]
    private var recoveryGeneration = 0
    /// Ein Gerätewechsel während der Ruhezeit baut erst nach dem Durchlauf neu.
    private var rebuildAfterRecovery = false

    /// Von der ersten Meldung bis zum Durchlauf: keine automatischen Starts, Neustarts
    /// (`adopt`, Wächter) oder Neuaufbauten — sie berührten alle Knoten der Engine, auch tote,
    /// deren Meldung noch aussteht. Nutzeraktionen laufen weiter.
    var isRecoveringPlugins: Bool { !pendingRecovery.isEmpty }

    private func rebuildGraphUnlessRecovering() {
        guard graph.faulted == nil else { return }
        if isRecoveringPlugins { rebuildAfterRecovery = true } else { rebuildGraph() }
    }

    private func pluginInvalidated(_ object: AnyObject?) {
        guard let object else { return }
        guard graph.faulted == nil else {              // außer Betrieb: nichts mehr umbauen
            diagnostics.event("invalidated", ["channel": "?", "faulted": true])
            return
        }
        guard let (id, l, slot) = locate(object) else {
            Self.log.error("Plug-in-Prozess beendet (keiner aktiven Instanz zugeordnet)")
            diagnostics.event("invalidated", ["channel": "?"])
            return
        }
        if let i = slot { report(id, slot: "effect \(i + 1)") } else { report(id, slot: "instrument") }
        markDead(id, l, slot: slot)
        scheduleRecoveryPass()
    }

    /// Löst einen Platz aus der Engine (ohne Verbinden) und merkt ihn für den Durchlauf vor.
    private func markDead(_ id: UUID, _ l: Live, slot: Int?) {
        guard graph.faulted == nil else { return }
        // Erst vormerken und Status setzen, dann abbauen (der Abbau kann den Graph außer
        // Betrieb nehmen, Codex R38-04).
        var p = pendingRecovery[id] ?? (false, [])
        if let i = slot { p.effects.insert(l.effectTokens[i]); effectStatus[id]?[i] = .loading }
        else { p.instrument = true; instrumentStatus[id] = .loading }
        pendingRecovery[id] = p
        if let i = slot { removeDeadEffect(l, index: i) } else { teardownInstrument(l, rewire: false) }
    }

    /// Der Graph ist außer Betrieb (Aufräumen nach einer Ausnahme gescheitert): kein Wiederanlauf,
    /// kein Start mehr; Anzeige und Diagnose. Erst ein Neustart von FoF bringt Audio zurück.
    private func graphFaulted(_ reason: String) {
        Self.log.error("Audio-Engine außer Betrieb: \(reason, privacy: .public)")
        diagnostics.event("graphFault", ["reason": reason])
        pendingRecovery = [:]
        rebuildAfterRecovery = false
        recoveryGeneration &+= 1                      // geplanten Durchlauf verwerfen
        // Plätze, die auf ein Nachladen warteten, bekommen keines mehr.
        for (id, st) in instrumentStatus where st == .loading { instrumentStatus[id] = .missing }
        for (id, list) in effectStatus { effectStatus[id] = list.map { $0 == .loading ? .missing : $0 } }
        engineError = reason
        // Tatsächlicher Zustand: scheiterte auch das Anhalten, läuft die Engine womöglich weiter.
        if isAudioRunning != graph.isRunning { isAudioRunning = graph.isRunning }
    }

    private func scheduleRecoveryPass() {
        guard graph.faulted == nil else { return }
        recoveryGeneration &+= 1
        let generation = recoveryGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + recoveryQuietTime) { [weak self] in
            guard let self, self.recoveryGeneration == generation else { return }
            self.recoverPendingPlugins()
        }
    }

    /// Verbinden des Kanals ist gescheitert (v1.18.38, zweite Linie zu den Meldungen) — ein
    /// Kanalfehler, kein bestätigter Prozesstod: meist ist eine Einheit der Kette tot und ihre
    /// Meldung steht aus; die Ausnahme sagt nicht, welche. Darum baut FoF alle Plug-ins des
    /// Kanals ab und lädt sie im Durchlauf nach (ungesicherte Klangänderungen gehen dabei
    /// verloren). Die Sperre `recoveryLockout` begrenzt das: scheitert es gleich wieder, bleibt
    /// der Platz „fehlt". Kein `hook`, kein `adopt` für diese Kette.
    private func connectFailed(_ l: Live, _ fault: String) {
        guard graph.faulted == nil, let id = live.first(where: { $0.value === l })?.key else { return }
        Self.log.error("Verbinden gescheitert (Kanal \(self.channel(id)?.name ?? "?", privacy: .public)): \(fault, privacy: .public)")
        diagnostics.event("connectFault", ["channel": channel(id)?.name ?? "?", "fault": fault])
        for i in l.effects.indices where l.effects[i] != nil {
            markDead(id, l, slot: i)
            if graph.faulted != nil { return }           // Abbau scheiterte: Stilllegung, nichts mehr vormerken
        }
        if l.instrument != nil { markDead(id, l, slot: nil) }
        if graph.faulted == nil, pendingRecovery[id] != nil { scheduleRecoveryPass() }
    }

    /// Kanal und Platz einer geladenen Einheit (Platz nil = Instrument).
    private func locate(_ object: AnyObject) -> (UUID, Live, Int?)? {
        for (id, l) in live {
            if let u = l.instrument, u.auAudioUnit === object { return (id, l, nil) }
            if let i = l.effects.firstIndex(where: { $0?.auAudioUnit === object }) { return (id, l, i) }
        }
        return nil
    }

    private func recoverPendingPlugins() {
        let pending = pendingRecovery
        pendingRecovery = [:]
        // Alle gemeldeten toten Knoten sind gelöst; erst jetzt wird verbunden und geladen.
        if rebuildAfterRecovery { rebuildAfterRecovery = false; rebuildGraph() }
        for (id, p) in pending {
            guard graph.faulted == nil else { return }
            guard let l = live[id] else { continue }
            guard rewire(l) else {
                if graph.faulted != nil { return }       // Stilllegung: nichts wieder einsetzen
                // Neuer Fehler: offene Plätze verlustfrei in die nächste Runde (Codex R38-03).
                var q = pendingRecovery[id] ?? (false, [])
                q.instrument = q.instrument || p.instrument
                q.effects.formUnion(p.effects)
                pendingRecovery[id] = q
                continue
            }
            for token in p.effects {
                // Ein synchroner Ladeabschluss kann stilllegen: vor jedem Auftrag prüfen (R38-R3-03).
                guard graph.faulted == nil else { return }
                // Nur wenn der Platz noch derselbe und leer ist (der Nutzer kann inzwischen
                // Effekte entfernt oder verschoben haben).
                if let i = l.effectTokens.firstIndex(of: token), l.effects[i] == nil { reloadEffect(id, l, index: i) }
            }
            guard graph.faulted == nil else { return }
            if p.instrument, l.instrument == nil, l.instrumentRequest == nil { reloadInstrument(id) }
        }
        updateEngineRunning()
    }

    private func report(_ id: UUID, slot: String) {
        let name = channel(id)?.name ?? "?"
        Self.log.error("Plug-in-Prozess beendet (Kanal \(name, privacy: .public), \(slot, privacy: .public))")
        diagnostics.event("invalidated", ["channel": name, "slot": slot])
    }

    /// true: Neustart erlaubt (und vermerkt). false: kurz nach einem Neustart erneut tot.
    private func mayRecover(_ key: UUID, now: Date = Date()) -> Bool {
        if let last = recoveredAt[key], now.timeIntervalSince(last) < recoveryLockout { return false }
        recoveredAt[key] = now
        return true
    }

    private func reloadInstrument(_ id: UUID) {
        guard let ref = channel(id)?.instrument else { return }
        let name = channel(id)?.name ?? "?"
        guard mayRecover(id) else {
            instrumentStatus[id] = .missing
            diagnostics.event("pluginRecovery", ["channel": name, "slot": "instrument", "gaveUp": true])
            return
        }
        instrumentStatus[id] = .loading
        diagnostics.event("pluginRecovery", ["channel": name, "slot": "instrument", "plugin": ref.name])
        loadInstrument(ref, into: id)
        onRoutingChange?()           // neue Belegung → Snapshot mit neuer Epoche
    }

    /// Löst einen toten Effekt aus dem Kanal, ohne neu zu verbinden.
    private func removeDeadEffect(_ l: Live, index i: Int) {
        guard l.effectTokens.indices.contains(i), l.effects.indices.contains(i) else { return }
        let token = l.effectTokens[i]
        plugins.closeEditor(.effect(token))
        releaseEffectQueue(l, token: token)                // Observer der toten Instanz zuerst weg
        if let n = l.effects[i], engineStorage != nil { graph.detach(n) }
        l.effects[i] = nil
    }

    private func reloadEffect(_ id: UUID, _ l: Live, index i: Int) {
        guard let data = channel(id), data.effects.indices.contains(i), l.effectTokens.indices.contains(i) else { return }
        let token = l.effectTokens[i]
        let ref = data.effects[i]
        guard mayRecover(token) else {
            effectStatus[id]?[i] = .missing
            diagnostics.event("pluginRecovery", ["channel": data.name, "slot": "effect \(i + 1)", "gaveUp": true])
            onRoutingChange?()
            return
        }
        effectStatus[id]?[i] = .loading
        diagnostics.event("pluginRecovery", ["channel": data.name, "slot": "effect \(i + 1)", "plugin": ref.name])
        loadEffect(ref, into: id, at: i)
        onRoutingChange?()
    }

    private func mixFormat() -> AVAudioFormat? { graph.mixFormat }

    /// Verbindet Instrument → Effekte (in Reihenfolge, nur geladene) → Gain-Stufe des Kanals.
    /// - Returns: false, wenn das Verbinden scheiterte und der Kanal abgebaut wurde (`connectFailed`).
    @discardableResult
    private func rewire(_ l: Live) -> Bool {
        guard graph.faulted == nil else { return false }       // vor engineStorage (nil außer Betrieb)
        guard let e = engineStorage else { return true }
        let head: AVAudioNode? = l.instrument ?? l.source
        // Eigene Rate des Instruments (v1.18.9): Umrechnungsstufe direkt dahinter.
        let rate = l.instrument != nil ? stageRate(l) : nil
        if rate != nil, l.rateStage == nil { let m = AVAudioMixerNode(); e.attach(m); l.rateStage = m }
        if rate == nil, let m = l.rateStage { e.disconnectNodeOutput(m); e.detach(m); l.rateStage = nil }
        let chain: [AVAudioNode] = ([head, l.rateStage] + l.effects + [l.gatePre]).compactMap { $0 }
        guard head != nil else { return graph.disconnect(chain, from: l.gain) }
        _rewireObserver?(chain)
        if let fault = graph.connectChain(chain, into: l.gain,
                                          headFormat: rate.flatMap { AVAudioFormat(standardFormatWithSampleRate: $0, channels: 2) }) {
            connectFailed(l, fault)
            return false
        }
        if let fault = hook(l) { connectFailed(l, fault); return false }
        if !isRecoveringPlugins, graph.adopt(chain + [l.gain, l.mixer]) { diagnostics.event("restart", ["reason": "newNodes"]) }
        return graph.faulted == nil                            // `adopt` kann stilllegen (R38-R3-02)
    }

    /// Hängt den Kanalausgang an die Summe (v1.18.10).
    ///
    /// Gemessen (macOS 26, AVAudioEngine): bei laufender Engine greift eine Verbindung in den
    /// Summenmixer nur, wenn der Zweig darüber schon eine Quelle hat — dann bereitet die
    /// Engine alle Knoten des Zweigs vor, ohne Neustart. Ein Kanal ohne Quelle, der an die
    /// laufende Summe gehängt wird, kommt dort nie an; ein später darunter gehängtes
    /// Instrument bleibt stumm (der Befund von v1.13.6, früher mit Neustart der Engine
    /// gelöst, der alle Kanäle unterbrach). Darum hängt ein leerer Kanal bei laufender Engine
    /// erst, wenn Instrument oder Loop-Quelle da sind; Effekte in einem hängenden Zweig
    /// einzufügen oder zu tauschen ist dagegen ohne Weiteres möglich.
    /// - Returns: nil, oder die Ausnahme beim Verbinden (die Engine bereitet dabei den ganzen
    ///   Zweig vor, also auch seine Plug-ins).
    @discardableResult
    private func hook(_ l: Live) -> String? {
        guard !l.hooked, let e = engineStorage else { return nil }
        if e.isRunning, l.instrument == nil, l.source == nil { return nil }
        if let fault = graph.connect(l.mixer, to: e.mainMixerNode, format: mixFormat()) { return fault }
        l.hooked = true
        return nil
    }

    /// Abweichende Rate des Instruments eines Kanals, nil = Geräterate.
    private func stageRate(_ l: Live) -> Double? {
        guard let id = live.first(where: { $0.value === l })?.key, let r = channel(id)?.renderRate,
              let device = mixFormat()?.sampleRate, r != device else { return nil }
        return r
    }

    /// Abtastrate, mit der das Instrument eines Kanals rendert (nil = Geräterate). Ein
    /// laufendes Instrument wird mit neuem Format neu verbunden; die Engine startet dafür
    /// kurz neu (wie beim Laden eines Plug-ins).
    func setRenderRate(_ rate: Double?, for id: UUID) {
        let r = rate.flatMap { InstrumentChannelData.renderRates.contains($0) ? $0 : nil }
        guard let idx = channels.firstIndex(where: { $0.id == id }), channels[idx].renderRate != r else { return }
        channels[idx].renderRate = r
        if let l = live[id], l.instrument != nil, engineStorage != nil {
            let running = graph.isRunning
            if running { graph.stop() }
            removeObserver(l)
            if rewire(l) { installObserver(l) }    // Rate des Instruments → Frames je Host-Tick
            if running, !isRecoveringPlugins { graph.start() }
            updateRouteLatencies()
            diagnostics.event("renderRate", ["channel": channels[idx].name, "rate": r ?? 0])
        }
        onProjectChange?()
    }

    /// Abtastrate des Ausgabegeräts (nil, solange keines bekannt ist).
    var outputSampleRate: Double? { mixFormat()?.sampleRate }

    /// Tatsächliche Rate des Instruments (Anzeige, Tests).
    func instrumentRenderRate(_ id: UUID) -> Double? { live[id]?.instrument?.outputFormat(forBus: 0).sampleRate }

    /// Bestätigt vor jedem Start der Engine (sie steht) die Host-Blöcke aller geladenen
    /// Plug-ins (v1.17.10, Codex A17-09; Zeitpunkt v1.18.10). Befund A17-09: ein ausgelagertes
    /// Instrument verlor sie bei einem Neustart der Engine. Befund v1.18.10 (iMac, macOS 12):
    /// Setzen, während das Plug-in im Hostprozess rendert, lässt AUHostingServiceXPC abstürzen
    /// (Odin2 → transportStateProc → leerer Funktionszeiger) — deshalb nur hier. Gesetzt wird
    /// nur, wenn der Getter leer ist — dieselbe Bindung, vermerkt in der Diagnose.
    private func reaffirmHostBindings(force: Bool = false) {
        for l in live.values {
            if let unit = l.instrument, let b = l.hostBinding { plugins.reaffirm(b, unit, force: force) }
            for (i, token) in l.effectTokens.enumerated() {
                if let unit = l.effects[i], let b = l.effectHostBindings[token] { plugins.reaffirm(b, unit, force: force) }
            }
        }
    }

    /// Nachprüfung nach jedem Start (A17-09, v1.18.10): Bindungen, die seither rendern, aber
    /// nicht gerufen werden, bekommen ihre Blöcke einmal zurück. Ein späterer Start entwertet
    /// eine noch ausstehende Prüfung.
    private var hostCheckGeneration = 0
    private func scheduleHostBlockCheck() {
        hostCheckGeneration &+= 1
        let gen = hostCheckGeneration
        var marks: [(HostBinding, AVAudioUnit, PluginLifecycle.UseMark)] = []
        for l in live.values {
            if let u = l.instrument, let b = l.hostBinding { marks.append((b, u, plugins.mark(b))) }
            for (i, t) in l.effectTokens.enumerated() {
                if let u = l.effects[i], let b = l.effectHostBindings[t] { marks.append((b, u, plugins.mark(b))) }
            }
        }
        guard !marks.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hostCheckDelay) { [weak self] in
            guard let self, gen == self.hostCheckGeneration, self.graph.isRunning else { return }
            for (b, u, m) in marks where self.isLive(b) { self.plugins.restoreIfUnused(b, u, since: m) }
        }
    }
    static let hostCheckDelay: TimeInterval = 0.3

    /// Gehört die Bindung noch zu einem geladenen Plug-in?
    private func isLive(_ b: HostBinding) -> Bool {
        live.values.contains { $0.hostBinding === b || $0.effectHostBindings.values.contains { $0 === b } }
    }

    private func adoptNewNodes(_ nodes: [AVAudioNode]) {
        if !isRecoveringPlugins, graph.adopt(nodes) { diagnostics.event("restart", ["reason": "newNodes"]) }
    }

    private func updateEngineRunning() {
        guard engineStorage != nil else { return }
        let needed = live.values.contains { $0.instrument != nil || $0.source != nil }
        if needed, !graph.isRunning, !isRecoveringPlugins {
            graph.installMasterTap()
            graph.start()
        } else if !needed, graph.isRunning {
            graph.stop()
            masterMeter.reset()
            live.values.forEach { $0.meter.reset() }
        }
        if isAudioRunning != graph.isRunning {
            isAudioRunning = graph.isRunning
            if !graph.isRunning { onOutputConfigChange?() }   // wieder vom Standardgerät
        }
        loops.devices.refresh()
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


    private func instantiate(_ ref: PluginRef, completion: @escaping (AVAudioUnit?) -> Void) {
        plugins.instantiate(ref, completion: completion)
    }

    // MARK: - Render-Observer (Übergabe an den Audio-Thread)

    private func removeObserver(_ l: Live) {
        plugins.removeObserver(l.observerToken, from: l.instrument)
        l.observerToken = nil
    }

    /// Hängt die Warteschlange des Kanals an den Render-Durchlauf seines Instruments.
    private func installObserver(_ l: Live) {
        removeObserver(l)
        guard let unit = l.instrument else { return }
        l.observerToken = plugins.installInstrumentObserver(unit, queue: queues[l.slot], binding: l.hostBinding)
    }

    /// Belegt für einen geladenen Effekt einen Platz im Block `effectQueues` (v1.17.1); der
    /// Render-Observer kommt nach dem Verdrahten (`installEffectObserver`).
    ///
    /// Der Observer läuft auf dem Audio-Thread, bevor der Effekt rendert, und plant Parameter
    /// wie beim Instrument mit Sample-Offset ein — sie gelten für denselben Block. Er fängt
    /// nur die Warteschlange (unretained, das Rack hält den Block) und den Schedule-Block.
    @discardableResult
    private func reserveEffectQueue(_ l: Live, token: UUID) -> Int? {
        releaseEffectQueue(l, token: token)
        guard let slot = freeEffectQueues.popLast() else { return nil }
        l.effectQueueSlots[token] = slot
        let q = effectQueue(slot)
        q.prefault()
        q.invalidate(); q.beginOccupancy(); q.setActive(true)
        updateRouteLatencies()
        return slot
    }

    /// Render-Observer des Effekts (nach dem Verdrahten: Abtastrate steht fest).
    private func installEffectObserver(_ l: Live, token: UUID, unit: AVAudioUnit) {
        guard let slot = l.effectQueueSlots[token] else { return }
        l.effectObserverTokens[token] = plugins.installEffectObserver(unit, queue: effectQueues[slot],
                                                                      binding: l.effectHostBindings[token])
    }

    /// Gibt den Platz eines Effekts frei: Observer ab, Belegung beendet (verspätete Ereignisse
    /// für ihn erreichen einen späteren Effekt auf diesem Platz nie), Platz zurück.
    private func releaseEffectQueue(_ l: Live, token: UUID) {
        if let t = l.effectObserverTokens.removeValue(forKey: token) {
            plugins.removeObserver(t, from: l.effectTokens.firstIndex(of: token).flatMap { l.effects[$0] })
        }
        catalog.effectUnloaded(token: token)
        l.effectHostBindings[token] = nil
        guard let slot = l.effectQueueSlots.removeValue(forKey: token) else { return }
        let q = effectQueue(slot)
        q.setActive(false); q.invalidate(); q.beginOccupancy()
        freeEffectQueues.append(slot)
    }

    // MARK: - Audio-Loop-Kanäle (v1.15.0)

    /// Legt einen Audio-Loop-Kanal an (Quelle: Loop-Spieler).
    @discardableResult
    func addAudioLoopChannel(name: String) -> UUID? {
        guard canAddChannel, let slot = freeSlots.popLast() else { return nil }
        let data = InstrumentChannelData(name: name, source: .audioLoop(AudioLoopSettings()))
        install(data, slot: slot)
        channels.append(data)
        updateEngineRunning()
        onRoutingChange?(); onProjectChange?()
        return data.id
    }

    /// Entnimmt einen Audio-Loop-Kanal samt Material (Undo von „Audio-Loop-Spur hinzufügen",
    /// Codex M3). Rückgabe für `putAudioLoopChannel`.
    func takeAudioLoopChannel(_ id: UUID) -> (data: InstrumentChannelData, index: Int, storage: AudioLoopStorage?)? {
        guard let idx = channels.firstIndex(where: { $0.id == id }), channels[idx].audioLoop != nil
        else { return nil }
        let taken = (data: channels[idx], index: idx, storage: loops.assets[id])
        removeChannel(id)
        return taken
    }

    /// Setzt einen entnommenen Audio-Loop-Kanal mit derselben Identität und demselben
    /// Material wieder ein (Redo).
    func putAudioLoopChannel(_ data: InstrumentChannelData, index: Int, storage: AudioLoopStorage?) {
        guard channel(data.id) == nil, canAddChannel, let slot = freeSlots.popLast() else { return }
        install(data, slot: slot)
        channels.insert(data, at: min(index, channels.count))
        loops.put(storage, for: data.id)
        updateEngineRunning()
        onRoutingChange?(); onProjectChange?()
    }

    /// Verbindet Gain → (Gate nach dem Fader) → Kanal-Mixer.
    private func wireFader(_ l: Live) {
        guard let e = engineStorage else { return }
        let format = mixFormat()
        if let gp = l.gatePost {
            e.connect(l.gain, to: gp, format: format)
            e.connect(gp, to: l.mixer, format: format)
        } else {
            e.connect(l.gain, to: l.mixer, format: format)
        }
    }

    /// Quelle des Kanals: rendert Mithören und Loop des Kerns dieses Slots.
    private func installLoopSource(_ l: Live) {
        guard let e = engine() else { return }
        if let old = l.source { e.detach(old) }
        let format = mixFormat() ?? AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let sr = format.sampleRate
        let core = loops.cores[l.slot]
        let node = AVAudioSourceNode(format: format) { _, timestamp, frameCount, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            guard list.count > 0, let lp = list[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let rp = list.count > 1 ? (list[1].mData?.assumingMemoryBound(to: Float.self) ?? lp) : lp
            let ts = timestamp.pointee
            let host = ts.mFlags.contains(.hostTimeValid) ? ts.mHostTime : 0
            let rate = ts.mFlags.contains(.rateScalarValid) ? ts.mRateScalar : 1
            core._withUnsafeGuaranteedRef {
                $0.renderOutput(host: host, frames: Int(frameCount), sampleRate: sr, rateScalar: rate,
                                l: lp, r: rp)
            }
            return noErr
        }
        e.attach(node)
        l.source = node
        rewire(l)
    }

    /// Einstellungen eines Audio-Loop-Kanals ändern (Länge nur, solange der Loop leer ist).
    func setAudioLoopSettings(_ s: AudioLoopSettings, for id: UUID) {
        guard let old = channel(id)?.audioLoop, old != s else { return }
        var new = s; new.clamp()
        if new.bars != old.bars, loopCore(for: id)?.hasMaterial == true { new.bars = old.bars }
        mutate(id) { $0.audioLoop = new }
        loops.configure(id, new)
        loops.updateInputNeeded()
        loops.kickDisplays()
    }

    /// Setzt das Gate an einem Ort (Pre/Post) ein, stellt es ein oder nimmt es heraus.
    private func setGate(_ position: GatePosition, _ g: GateSettings, in l: Live) {
        let wanted = g.position == position
        let current = position == .preFader ? l.gatePre : l.gatePost
        if let unit = current {
            if wanted { (unit.auAudioUnit as? GateAudioUnit)?.control.apply(g, enabled: true); return }
            removeGate(position, from: l)
            return
        }
        guard wanted else { return }
        // Eigene, im Prozess registrierte Komponente: synchron anlegen (kein Ladeauftrag).
        guard let e = engine() else { return }
        let unit = AVAudioUnitEffect(audioComponentDescription: GateAudioUnit.componentDescription)
        (unit.auAudioUnit as? GateAudioUnit)?.control.apply(g, enabled: true)
        e.attach(unit)
        if position == .preFader {
            l.gatePre = unit
            rewire(l)
        } else {
            removeMeterTap(l)
            e.disconnectNodeOutput(l.gain)
            l.gatePost = unit
            wireFader(l)
            installMeterTap(l)
            adoptNewNodes([unit])
        }
    }

    private func removeGate(_ position: GatePosition, from l: Live) {
        guard let e = engineStorage else { return }
        if position == .preFader, let unit = l.gatePre {
            e.disconnectNodeOutput(unit)
            l.gatePre = nil
            e.detach(unit)
            rewire(l)
        } else if position == .postFader, let unit = l.gatePost {
            removeMeterTap(l)
            e.disconnectNodeOutput(l.gain)
            e.disconnectNodeOutput(unit)
            l.gatePost = nil
            e.detach(unit)
            wireFader(l)
            installMeterTap(l)
        }
    }

    // Aufnahme, Material, Transport, Latenzmessung, Speichern: `AudioLoopController`.

    /// Scharfschalten (true) oder Aufnahme beenden (false).
    func setLoopRecording(_ on: Bool, for id: UUID, bpm: Double, quartersPerBar: Double = 4) {
        loops.setRecording(on, for: id, bpm: bpm, quartersPerBar: quartersPerBar)
    }
    /// Undo/Redo des letzten Durchlaufs (Rückgabe für den versionsgebundenen Dokument-Undo).
    @discardableResult
    func undoLoop(_ id: UUID) -> (old: AudioLoopStorage, new: AudioLoopStorage)? { loops.undo(id) }
    /// Löscht das Material (nur im Ruhezustand). Rückgabe: der gelöste Speicher (für Undo).
    @discardableResult
    func clearLoop(_ id: UUID) -> AudioLoopStorage? { loops.clear(id) }
    /// Versionsgebundener Tausch des Materials (Dokument-Undo, Codex M2).
    @discardableResult
    func exchangeLoop(_ id: UUID, expected: AudioLoopStorage?, with new: AudioLoopStorage?,
                      keepUndo: Bool) -> Bool {
        loops.exchange(id, expected: expected, with: new, keepUndo: keepUndo)
    }

    /// Transport angehalten: Anker stoppen (zur Host-Zeit `at`, Standard jetzt), alle
    /// Aufnahmen beenden.
    func transportStopped(at host: UInt64 = mach_absolute_time(), session: UInt32? = nil) {
        hostSync.stop(at: host, session: session)   // Songende hat der Tick schon gesetzt (A17-01)
        loops.transportStopped(at: host)
    }
    func transportStarted() { loops.transportStarted() }

    static var probeTimeout: TimeInterval { AudioLoopController.probeTimeout }
    func measureLoopLatency(_ id: UUID) { loops.measureLatency(id) }
    func updateInputNeeded() { loops.updateInputNeeded() }

    func loopFiles() -> [AudioLoopFile]? { loops.files() }
    func loopSaveJobs() -> [(id: UUID, job: AudioLoopAssets.SaveJob)] { loops.saveJobs() }
    func adoptEncodedLoop(_ file: AudioLoopFile, storage: AudioLoopStorage, version: Int, for id: UUID) {
        loops.adoptEncoded(file, storage: storage, version: version, for: id)
    }
    @discardableResult
    func restoreLoops(_ files: [AudioLoopFile]) -> Int { loops.restore(files) }
    func loopWaveform(_ id: UUID, buckets: Int) -> [AudioLoopDisplay.WaveBucket] { loops.waveform(id, buckets: buckets) }
    func loopFrames(_ id: UUID) -> Int { loops.frames(id) }

    // MARK: - Test-Zugang

    #if DEBUG
    /// Bindet Material ohne Aufnahme (Tests).
    func _setLoopStorage(_ st: AudioLoopStorage, for id: UUID) { loops._setStorage(st, for: id) }
    func _liveInstrument(_ id: UUID) -> AVAudioUnit? { live[id]?.instrument }
    /// Gain-Stufe des Kanals (Tap vor Stumm/Panorama, Messungen).
    func _liveGain(_ id: UUID) -> AVAudioNode? { live[id]?.gain }
    /// Neu gesetzte Host-Blöcke des Instruments seit dem Laden (Diagnose).
    func _instrumentHostReinstalls(_ id: UUID) -> Int? {
        live[id]?.hostBinding?.reinstalls.load(ordering: .relaxed)
    }
    /// Renderdurchläufe des Instruments (Vor-Render-Observer) — belegt, dass es rendert.
    func _instrumentPreRenders(_ id: UUID) -> Int? {
        live[id].map { queue($0.slot).preRenders.load(ordering: .relaxed) }
    }
    /// Starts der Engine seit Anlegen und ihr echter Laufzustand (Tests, v1.18.38).
    var _graphStarts: Int { graph.starts }
    var _graphIsRunning: Bool { graph.isRunning }
    func _liveEffect(_ id: UUID, at i: Int) -> AVAudioUnit? {
        guard let l = live[id], l.effects.indices.contains(i) else { return nil }
        return l.effects[i]
    }
    var _engineIsRunning: Bool { engineStorage?.isRunning ?? false }
    var _engineStarts: Int { graph.starts }
    /// Renderressourcen der Kanalknoten (Diagnose): Instrument, Gain, Mixer.
    func _allocation(_ id: UUID) -> String {
        guard let l = live[id] else { return "-" }
        func f(_ n: AVAudioNode?) -> String { n.map { $0.auAudioUnit.renderResourcesAllocated ? "1" : "0" } ?? "n" }
        return "inst \(f(l.instrument)) gain \(f(l.gain)) mix \(f(l.mixer))"
    }
    /// Tatsächlich anliegender Kanalpegel als linearer Gain (Gain-Stufe × Stumm/Solo).
    func _liveOutputVolume(_ id: UUID) -> Float? {
        live[id].map { $0.mixer.outputVolume * powf(10, $0.gain.globalGain / 20) }
    }
    func _stopEngineBehindTheRacksBack() { engineStorage?.stop() }
    func _watchdogTick() { watchdog._tickIgnoringLockout() }
    /// Ersetzt das Laden von Plug-ins: der Test bekommt den Abschluss und ruft ihn selbst auf.
    var _instantiateOverride: ((PluginRef, @escaping (AVAudioUnit?) -> Void) -> Void)? {
        get { plugins._instantiateOverride }
        set { plugins._instantiateOverride = newValue }
    }
    /// Setzt das Instrument eines Kanals ohne Laden auf „bereit" (Parameterbindungs-Tests).
    func _markInstrumentReady(_ id: UUID, as ref: PluginRef) {
        guard let idx = channels.firstIndex(where: { $0.id == id }) else { return }
        channels[idx].instrument = ref
        instrumentStatus[id] = .ready
    }
    func _setParameters(_ list: [ParameterInfo], for id: UUID) { catalog._setInstrumentParameters(list, for: id) }
    /// Hängt einen Effekt ohne Laden an und meldet ihn bereit, mit Warteschlange und
    /// Parametern (Effekt-Ziel-Tests). Liefert seinen Platz im Block `effectQueues`.
    @discardableResult
    func _addReadyEffect(_ ref: PluginRef, parameters list: [ParameterInfo], to id: UUID) -> Int? {
        guard let idx = channels.firstIndex(where: { $0.id == id }), let l = live[id] else { return nil }
        let token = UUID()
        channels[idx].effects.append(ref)
        l.effects.append(nil); l.effectTokens.append(token)
        reserveEffectQueue(l, token: token)
        catalog._setEffectParameters(list, token: token)
        effectStatus[id, default: []].append(.ready)
        return l.effectQueueSlots[token]
    }
    var _freeEffectQueueCount: Int { freeEffectQueues.count }
    func _editorWindow(_ id: UUID, effect index: Int?) -> NSWindow? {
        guard let l = live[id] else { return nil }
        guard let index else { return plugins.window(.instrument(id)) }
        return l.effectTokens.indices.contains(index) ? plugins.window(.effect(l.effectTokens[index])) : nil
    }
    #endif
}

// MARK: - Lesezugang des Parameterkatalogs (v1.18.0)

extension InstrumentRack: ParameterCatalogHost {
    func catalogChannel(_ id: UUID) -> InstrumentChannelData? { channel(id) }
    func catalogInstrument(_ id: UUID) -> (unit: AVAudioUnit?, ready: Bool) {
        (live[id]?.instrument, instrumentStatus[id] == .ready)
    }
    func catalogEffects(_ id: UUID) -> [(token: UUID, unit: AVAudioUnit?, ready: Bool)] {
        guard let l = live[id] else { return [] }
        let st = effectStatus[id] ?? []
        return l.effectTokens.enumerated().map { i, t in
            (t, l.effects.indices.contains(i) ? l.effects[i] : nil, st.indices.contains(i) && st[i] == .ready)
        }
    }
    func catalogEffectQueue(_ id: UUID, token: UUID) -> (slot: Int, epoch: UInt32)? {
        guard let slot = live[id]?.effectQueueSlots[token] else { return nil }
        return (slot, effectQueue(slot).occupancyEpoch)
    }
}

// MARK: - Zugang der Loop-Steuerung (v1.18.4)

extension InstrumentRack: AudioLoopHost {
    var loopChannels: [(id: UUID, settings: AudioLoopSettings)] {
        channels.compactMap { c in c.audioLoop.map { (c.id, $0) } }
    }
    var loopSampleRate: Double? { mixFormat()?.sampleRate }
    var loopOutputRunning: Bool { graph.isRunning }
    var loopOutputLatencyFrames: Int {
        if graph.isRunning, let id = AudioDevices.current(of: engineStorage?.outputNode.audioUnit) {
            return AudioDevices.latencyFrames(id, input: false)
        }
        return AudioInputEngine.deviceLatency(scope: kAudioDevicePropertyScopeOutput,
                                              selector: kAudioHardwarePropertyDefaultOutputDevice)
    }
    func loopConfigured(_ id: UUID, _ settings: AudioLoopSettings) {
        guard let l = live[id] else { return }
        setGate(.preFader, settings.gate, in: l)
        setGate(.postFader, settings.gate, in: l)
        updateRouteLatencies()
    }
    func loopSettingsMeasured(_ settings: AudioLoopSettings, for id: UUID) { setAudioLoopSettings(settings, for: id) }
    func loopProjectChanged() { onProjectChange?() }
}
