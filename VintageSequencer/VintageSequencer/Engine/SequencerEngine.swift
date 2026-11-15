import Foundation
import Combine
import AppKit
import CoreMIDI
import CoreAudio
import Darwin
import UniformTypeIdentifiers
import Atomics   // E3: ManagedAtomic — add via Xcode: File → Add Package Dependencies
                 // URL: https://github.com/apple/swift-atomics  version 1.1.0 – <2.0.0

class SequencerEngine: ObservableObject {

    // MARK: - Transport-Zustand (Arch-Slice-19)
    //
    // BPM, isPlaying, clockMode, currentPatternIndex, queuedPatternIndex wurden aus
    // SequencerEngine in ein separates TransportState-Objekt ausgelagert.
    // engine.objectWillChange feuert bei diesen Änderungen NICHT mehr →
    // StepGrid/StepButton re-evaluieren NICHT bei BPM-Drehung (war: ~6.700/s).
    //
    // Interner Engine-Code bleibt unverändert — die Computed-Properties forwarden
    // transparent auf transportState, sodass `bpm`, `isPlaying` etc. ohne Präfix
    // weiterhin nutzbar sind. Writes/Reads delegieren an transportState.
    //
    // Schreibregel: Ausschließlich die Engine schreibt auf transportState.
    // Views verwenden engine.play(), engine.stop(), engine.setBPM(_:), engine.setClockMode(_:).

    let transportState = TransportState()

    var bpm: Double {
        get { transportState.bpm }
        set {
            transportState.bpm = newValue
            updateExtLookahead(refreshDevice: false)   // EXT-Vorlauf enthält ein Pulsintervall
        }
    }
    var isPlaying: Bool {
        get { transportState.isPlaying }
        // RT-1: atomaren Spiegel mitschreiben — alle isPlaying-Schreibpfade
        // (play/stop/startFromExternal) laufen durch diesen Setter.
        // RT-1a: Atomic VOR @Published (Producer-before-observer). Der
        // $isPlaying-Sink feuert synchron im willSet; ein dadurch angestoßener
        // Read darf den RT-Spiegel nie im alten Zustand sehen.
        set {
            // seq_cst: bildet mit dem Tick-Zutritt (enterTick) ein Dekker-Paar — siehe dort.
            isPlayingRT.store(newValue, ordering: .sequentiallyConsistent)
            transportState.isPlaying = newValue
            if newValue { rack.transportStarted() }   // Loop-Anzeigen: Wiedergabeort abfragen
        }
    }
    var clockMode: ClockMode {
        get { transportState.clockMode }
        // RT-1: atomaren Spiegel mitschreiben — setClockMode() ist der einzige
        // Schreibpfad. Audio-/MIDI-Thread liest clockIsInternal statt @Published.
        // RT-1a: Atomic ZWINGEND vor @Published. Der $clockMode-Sink startet/
        // stoppt synchron im willSet die ClockSource; ein dadurch ausgelöster
        // erster clockTick muss clockIsInternal bereits im neuen Zustand sehen,
        // sonst entkoppeln interner Step und ausgehende 0xF8 (Befund H1).
        set {
            clockIsInternal.store(newValue == .internal, ordering: .releasing)
            transportState.clockMode = newValue
        }
    }
    var currentPatternIndex: Int {
        get { transportState.currentPatternIndex }
        // Taktart, Raster und Vormerkanzeige folgen dem aktuellen Pattern (v1.18.24).
        set { transportState.currentPatternIndex = newValue; if patterns.indices.contains(newValue) { syncMeter() } }
    }
    var queuedPatternIndex: Int? {
        get { transportState.queuedPatternIndex }
        // RT-1: atomaren Spiegel mitschreiben (nil → Sentinel −1). Alle
        // Schreibpfade (switchPattern, stop, Drain) laufen durch diesen Setter.
        // RT-1a: Atomic vor @Published — dieselbe Producer-before-observer-
        // Invariante wie isPlaying/clockMode.
        set {
            queuedPatternAtomic.store(newValue ?? -1, ordering: .releasing)
            transportState.queuedPatternIndex = newValue
        }
    }

    // Swing — delegiert an presetEditorState (Pre-Lane Slice C).
    // Kein @Published hier — feuert kein engine.objectWillChange bei Knob-Drehung.
    var swing: Double {
        get { presetEditorState.swing }
        set { presetEditorState.swing = newValue }
    }

    @Published var patterns: [Pattern] = Pattern.defaultSlots()
    var numTracks: Int { currentPattern.tracks.count }  // D3: computed — kein manuelles Sync nötig
    /// Höhe der Step-Buttons — fix auf L (54 px).
    let stepDisplaySize: Double = 54
    /// Breite der Step-Buttons — in eigenem StepWidthState-Objekt,
    /// damit Width-/Pinch-Änderungen keine Engine-weite Re-Render-Kaskade auslösen.
    /// Analog zu playbackDisplay und scrollState.
    let stepWidthState = StepWidthState()

    /// Convenience-Accessor für Nicht-View-Code (z.B. Utility-Funktionen).
    /// Kein @Published — feuert KEIN engine.objectWillChange.
    var stepWidthSize: Double { stepWidthState.size }
    // MARK: - Clock Jitter Diagnostics (Arch-Slice-A)
    //
    // Ausgelagert aus SequencerEngine in ClockDiagnosticsState, damit Jitter-Writes
    // (~1×/s während Playback) kein engine.objectWillChange feuern und keine
    // engine-weiten View-Invalidierungen auslösen. Analog zu TransportState,
    // PlaybackDisplayState, ScrollState, StepWidthState.
    //
    // Schreiber: SequencerEngine (Clock-Sampling-Fenster, Main-Thread).
    // Leser: StatusBar (MainView), BodyRunCounter (Debug).
    let clockDiagnostics = ClockDiagnosticsState()
    // activeSelectionTrack — ENTFERNT (Arch-Slice-3).
    // Das Single-Track-Selection-Enforcement übernimmt jetzt der Combine-Sink
    // in StepGridCoordinator.connectInteractionController: wenn IC einen
    // RubberBandUpdate für eine andere Track-ID publiziert, löscht jeder
    // Koordinator selbstständig seine selectedSteps.
    // Kein @Published-Property in der Engine mehr nötig.

    /// Playback-Anzeigezustand (aktuell beleuchteter Step pro Track) — in eigenem
    /// PlaybackDisplayState-Objekt, damit Drain-Timer-Writes keine Engine-weite
    /// SwiftUI-Re-Render-Kaskade auslösen. Analog zu scrollState.
    let playbackDisplay = PlaybackDisplayState()
    /// Song (v1.14.0): Szenenfolge über allen Patterns; eigenes State-Objekt, nur die
    /// Song-Lane beobachtet es.
    let songState = SongState()
    /// Zuletzt bediente Audio-Loop-Spur (Ziel der Taste R).
    var lastAudioLoopTrack: UUID?
    var song: Song { songState.song }

    /// Horizontaler Scroll-Offset — in eigenem ScrollState-Objekt,
    /// damit Scroll-Events keine Engine-weite Re-Render-Kaskade auslösen.
    let scrollState = ScrollState()

    /// Single scroll-write authority — created lazily from scrollState.
    /// Arch-Slice-1: Count Handle edge-scroll flows through here.
    lazy var viewportController: ViewportController = ViewportController(scrollState: scrollState)

    /// Global interaction state machine (modal, one session at a time).
    /// Arch-Slice-1: Count Handle drag session managed here.
    lazy var interactionController: InteractionController = InteractionController(viewportController: viewportController)

    /// Cursor and modifier feedback controller.
    ///
    /// Observes `interactionController.sessionCursorHint` via Combine and
    /// `NSEvent.flagsChanged` via a local monitor. Sets `NSCursor` exclusively
    /// during active sessions; view-layer hover cursors take over when idle.
    ///
    /// Initialized lazily; triggered by the `.onAppear` in `VintageSequencerApp`.
    /// (Arch-Slice-9 — Phase 1)
    lazy var cursorController: CursorController = CursorController(ic: interactionController)

    // MARK: - MIDILearnState (Pre-Lane Slice D)
    //
    // Ausgelagert aus SequencerEngine: patternSwitchCC, trackMuteCCs, learnMode,
    // learnTarget. CC-Remote-Control- und Learn-Writes feuern nur noch
    // midiLearnState.objectWillChange — nicht mehr engine.objectWillChange.
    // TransportView, StepButtonView, SettingsView subscriben direkt via
    // @EnvironmentObject MIDILearnState.
    let midiLearnState = MIDILearnState()

    // Convenience-Accessors — SequencerEngine+MIDILearn.swift (und andere Extensions)
    // können engine.patternSwitchCC / engine.learnMode etc. weiterhin direkt nutzen.
    // Kein @Published — feuern kein engine.objectWillChange.
    var patternSwitchCC: Int {
        get { midiLearnState.patternSwitchCC }
        set { midiLearnState.patternSwitchCC = newValue }
    }
    var trackMuteCCs: [Int] {
        get { midiLearnState.trackMuteCCs }
        set { midiLearnState.trackMuteCCs = newValue }
    }
    var learnMode: Bool {
        get { midiLearnState.learnMode }
        set { midiLearnState.learnMode = newValue }
    }
    var learnTarget: (track: Int, step: Int)? {
        get { midiLearnState.learnTarget }
        set { midiLearnState.learnTarget = newValue }
    }

    // MARK: - PresetEditorState (Pre-Lane Slice C)
    //
    // Ausgelagert aus SequencerEngine: swing, hasUnsavedChanges, currentPresetURL,
    // recentFiles, lastErrorMessage, clipboard, stepClipboard.
    // Preset-I/O-Writes feuern nur presetEditorState.objectWillChange —
    // nicht mehr engine.objectWillChange. TransportView und StepSelectionToolbar
    // subscriben direkt via @EnvironmentObject PresetEditorState.
    let presetEditorState = PresetEditorState()

    // Convenience-Accessors — Nicht-View-Code (Extensions, AppDelegate) kann
    // engine.hasUnsavedChanges etc. weiterhin direkt lesen/schreiben.
    // Kein @Published — feuern kein engine.objectWillChange.
    /// Nicht-fataler Hinweis des letzten `loadData` (z. B. nicht wiederherstellbare Loops).
    var loadWarning: String?
    var lastErrorMessage: String? {
        get { presetEditorState.lastErrorMessage }
        set { presetEditorState.lastErrorMessage = newValue }
    }
    var hasUnsavedChanges: Bool {
        get { presetEditorState.hasUnsavedChanges }
        set { presetEditorState.hasUnsavedChanges = newValue }
    }
    var currentPresetURL: URL? {
        get { presetEditorState.currentPresetURL }
        set { presetEditorState.currentPresetURL = newValue }
    }
    var recentFiles: [URL] {
        get { presetEditorState.recentFiles }
        set { presetEditorState.recentFiles = newValue }
    }
    var clipboard: Pattern? {
        get { presetEditorState.clipboard }
        set { presetEditorState.clipboard = newValue }
    }
    var stepClipboard: [Step] {
        get { presetEditorState.stepClipboard }
        set { presetEditorState.stepClipboard = newValue }
    }

    let midi = MIDIManager()

    // Externe Clock: BPM-Schätzung aus Pulsabstand.
    // Nur vom MIDI-Read-Thread geschrieben — kein Sharing, kein Lock nötig.
    private var extPulseCount:  Int    = 0
    private var extBeatStart:   UInt64 = 0

    // Externe Clock (v1.15.1, Codex T1): Zeitbezug ist der Paketzeitstempel des 0xF8, nicht
    // die Ankunft des Callbacks; jeder Puls — auch der erste — wird um denselben festen
    // Vorlauf `extLookaheadMach` später geplant. Früher: Callbackzeit + EMA eines Pulses,
    // erster Puls ohne Vorlauf (Phasensprung nach dem Start, Bündelung verfälschte die EMA).
    /// Vorlauf im EXT-Modus: 10 ms + ein Ausgabepuffer (Renderhorizont gehosteter
    /// Instrumente/Loops, Codex T3). Main setzt, MIDI-Read-Thread liest.
    private let extLookaheadMach = ManagedAtomic<UInt64>(0)
    /// Main bittet den MIDI-Read-Thread, seinen Messzustand (Pulszähler, EMA) zurückzusetzen.
    /// Die Variablen oben schreibt ausschließlich der MIDI-Read-Thread — Main setzt nur
    /// dieses Flag (früher schrieb Main sie direkt: Datenrennen).
    private let extResetRequested = ManagedAtomic<Bool>(false)

    // MARK: - Playback Snapshot (E3, RT-3, S01)
    //
    // Publikation und Erwerb des Bundles besitzt `SnapshotPublisher` (Hazard-Pointer-
    // Protokoll und Ordnungsbeweis dort). Die Engine baut Bundles und ruft publish/acquire.
    let publisher = SnapshotPublisher()

    /// Exklusiver Tick-Zutritt (RT-3a, seit v1.12.19 als CAS — siehe `enterTick()`):
    /// true, solange ein Tick läuft — vom Zutritt bis nach dem letzten MIDI-Send dieses
    /// Ticks, gleich ob er vom internen Clock-Thread oder vom MIDI-Read-Thread kommt.
    /// stop() wartet auf false, bevor es Snapshot-Box oder Notenbuch anfasst.
    @inline(__always) private var activeTick: ManagedAtomic<Bool> { kernel.activeTick }
    /// RT-3b: true zwischen „Sync-Spin-Backstop in stop() erreicht" und dem
    /// tatsächlichen Abschluss des aufgeschobenen RT-State-Teardowns. Nur
    /// Main-Thread (stop()/play()/startFromExternal() und der Async-Retry
    /// laufen alle auf der Main-Queue — GCD serialisiert sie, kein Atomic
    /// nötig). Schließt Codex-Befund H3: der frühere Backstop-Pfad in stop()
    /// führte den Teardown trotz activeTick == true durch (H2 in anderer
    /// Form). Jetzt gilt hart: activeTick == true ⇒ nie freigeben, auch nicht
    /// auf dem Timeout-Pfad — stattdessen aufschieben, bis wirklich quieszent.
    private var stopCleanupPending = false
    // MARK: Runtime-Slots (v1.12.19 — Topologie reist im Snapshot)
    //
    // Fester Block von `runtimeSlotCount` TrackRuntimes, einmal in init alloziert und nie
    // in der Größe verändert. AUSSCHLIESSLICH der Tick-Thread liest/schreibt ihn (innerhalb
    // des activeTick-Fensters). Der Main-Thread fasst ihn nie an: er vergibt nur Slot +
    // Epoche pro Track-Identität (`slotByTrack`) und schreibt beides in den Snapshot. Der
    // Tick-Thread vergleicht je Track `runtime.epoch` mit `snapshot.epoch` und beginnt bei
    // Abweichung frisch. Damit gibt es keinen Versatz mehr zwischen Snapshot-Topologie und
    // Runtime-Zuordnung (früher: getrennte Command-Mailbox, Befund B3) und keine
    // Strukturmutation eines Arrays im Tick-Pfad.
    static let runtimeSlotCount = TickKernel.runtimeSlotCount
    /// Obergrenze für neue Spuren je Pattern: aktuelles + vorgemerktes Pattern müssen
    /// zusammen in den Slot-Block passen, sonst blieben Spuren stumm.
    static let maxTracksPerPattern = runtimeSlotCount / 2
    private var canGrowTracks: Bool { patterns.allSatisfy { $0.tracks.count < Self.maxTracksPerPattern } }
    #if DEBUG
    private var rtRuntimes: UnsafeMutablePointer<TrackRuntime> { kernel.rtRuntimes }   // Test-Fenster
    #endif
    /// Main-only: Slot-Vergabe je Track-UUID. Slots bleiben belegt, solange der Track im
    /// aktuellen oder im vorgemerkten Pattern liegt.
    private var slotByTrack: [UUID: (slot: Int, epoch: UInt32)] = [:]
    private var freeSlots: [Int] = Array((0..<SequencerEngine.runtimeSlotCount).reversed())
    private var nextSlotEpoch: UInt32 = 1
    /// Main-only: Aktivierungsnummer des aktuellen Patterns (siehe PlaybackStateBundle.serial).
    private var patternSerial = 1
    /// Rückkanal des Tick-Pfads (Besitzer `TickKernel`): letzter Wechsel, Songende, Zähler.
    private var rtSwitchStamp: ManagedAtomic<UInt64> { kernel.rtSwitchStamp }
    private var rtLateTicks: ManagedAtomic<Int> { kernel.rtLateTicks }
    private var rtHorizonUnderruns: ManagedAtomic<Int> { kernel.rtHorizonUnderruns }
    private var rtPlanConflicts: ManagedAtomic<Int> { kernel.rtPlanConflicts }
    private var rtSongEnded: ManagedAtomic<Bool> { kernel.rtSongEnded }
    private var rtSongEndHost: ManagedAtomic<UInt64> { kernel.rtSongEndHost }
    /// EXT-Start ohne Main-Umweg (v1.15.2): Main hat im Stopp eine Sitzung vorbereitet
    /// (`armExternalStart`); der MIDI-Thread schaltet sie bei 0xFA/0xFB scharf.
    private let extArmed     = ManagedAtomic<Bool>(false)
    private let extStartedRT = ManagedAtomic<Bool>(false)
    /// Main: vorgemerkter Stopp auf dem Endpuls (Host-Zeit, Sitzung).
    private var pendingSongStop: (host: UInt64, session: UInt32)?
    private var songStopScheduled = false

    // MARK: Song-Steuerung (Main-only, v1.14.0)
    /// Songplanung (Werttyp, Codex M6) und Plan-Linien/Sitzungen (R1/R6).
    private var songPlanner = SongPlanner()
    /// Vorgemerkte Taktarten je Pattern-Platz (E2): das Pattern lief beim Ändern. Main.
    private var pendingMeters: [Int: TimeSignature] = [:]
    private var planLedger  = PlanLedger()
    typealias PlanEntry = PlanLedger.Entry
    static var songHorizon: Int { SongPlanner.horizon }
    private var songRunStart: Int? { songPlanner.runStart }
    private var songNextScene: Int? { songPlanner.nextScene }
    private var sessionCounter: UInt32 { planLedger.session }

    // MARK: Notenbuch und Ausgabe (v1.16.0: eigener Besitzer `NoteOutput`, Codex M6)
    /// In `init` angelegt (lazy nur wegen der Abhängigkeit von `midi`/`rack`).
    private lazy var noteOut = NoteOutput(midi: midi, rack: rack)
    /// Der Off-Wächter braucht noch den Zeitpunkt des letzten externen Ticks.
    private var lastExtTickHost: ManagedAtomic<UInt64> { kernel.lastExtTickHost }
    /// Main-only: läuft während der Wiedergabe (siehe `startOffWatchdog`).
    private var offWatchdog: DispatchSourceTimer?

    // MARK: - TrackViewModel cache (Slice G)
    //
    // One TrackViewModel per TrackData, created lazily. Views never hold TrackData
    // directly; they receive TrackViewModel from this cache via viewModel(for:).
    // The cache is pruned after preset loads and newProject() to release stale VMs.
    private var vmCache: [UUID: TrackViewModel] = [:]

    /// Returns the cached TrackViewModel for `td`, creating one if needed.
    func viewModel(for td: TrackData) -> TrackViewModel {
        // Identität prüfen, nicht nur die UUID: nach Decode/Restore kann eine NEUE
        // TrackData-Instanz dieselbe UUID tragen. Ein VM auf die alte Instanz würde
        // Edits an einem Objekt zeigen, das Snapshot und Save nicht mehr lesen.
        if let vm = vmCache[td.id], vm.data === td { return vm }
        let vm = TrackViewModel(data: td)
        vmCache[td.id] = vm
        return vm
    }

    /// Removes cache entries whose IDs are not in `liveIDs`.
    /// Call after preset load or newProject() to release ViewModels for discarded tracks.
    /// Verwirft alle ViewModels (Preset-Load, New Project).
    func resetVMCache() { vmCache.removeAll() }

    /// Undo-Manager des Fensters (von MainView gesetzt). Strukturoperationen, Paste und
    /// MIDI-Learn registrieren hier ihr Undo; Load/New leeren den Stack.
    weak var undoManager: UndoManager?

    func pruneVMCache(keeping liveIDs: Set<UUID>) {
        vmCache.keys
            .filter { !liveIDs.contains($0) }
            .forEach { vmCache.removeValue(forKey: $0) }
    }

    // MARK: - Infrastruktur (Display-Buffer, Event-Buffer, Timer, ClockSource)
    private let displayBuffer      = DisplayEventBuffer()
    /// Engine-Event-Buffer für RT-sichere Main-Thread-Mutationen (A2+A3).
    /// Produzent: Tick-Thread (advanceSteps). Konsument: displaySignal handler.
    private let engineEventBuffer  = EngineEventBuffer()
    /// Gehört dem Tick-Kern (Weckruf aus dem Tick); Main legt ihn in init an.
    private var displaySignal: DispatchSourceUserDataOr? {
        get { kernel.displaySignal } set { kernel.displaySignal = newValue }
    }
    /// Tick-Pfad (v1.16.0, Codex M6). In `init` angelegt, bevor ein Tick laufen kann.
    private lazy var kernel = TickKernel(publisher: publisher, noteOut: noteOut, outputs: rack.tickOutputs, midi: midi,
                                         displayBuffer: displayBuffer, engineEventBuffer: engineEventBuffer)

    /// AU-Host (v1.13.0): Instrumentenkanäle, Effekte, Mixer. Main-eigen; der Tick-Pfad
    /// erreicht nur die festen Ereigniswarteschlangen (`rack.queues[route]`).
    let rack = InstrumentRack()

    /// Interne Clock-Quelle.
    /// onTick → clockTick(at:) → advanceSteps(tickTime:).
    private let audioClock         = ClockSource()

    // MARK: - Clamp-Zähler (Besitzer `TickKernel`, nur diagnostisch)
    private var clampCountNotes: ManagedAtomic<Int> { kernel.clampCountNotes }
    private var clampCountClock: ManagedAtomic<Int> { kernel.clampCountClock }
    #if DEBUG
    /// Letzter vom Drain gelesener clampCountNotes-Wert — für Delta-Erkennung.
    /// Nur Main-Thread (Drain-Handler).
    private var _drainLastClampNotes: Int = 0
    private var _drainLastClampClock: Int = 0

    // MARK: - Step-Timing Diagnostics (Debug)
    //
    // Misst die tatsächlichen Zeitabstände zwischen aufeinanderfolgenden
    // playbackDisplay.steps-Updates auf dem Main Thread.
    //
    // Aktivierung im LLDB:
    //   expr SequencerEngine.stepTimingLog = true
    // Deaktivierung:
    //   expr SequencerEngine.stepTimingLog = false
    //
    // Ausgabe-Format:
    //   🕐 s00  Δ124.3ms  ◀ BAR      ← step 0, Bar-Beginn markiert
    //   🕐 s01  Δ125.1ms
    //   🕐 s02  Δ124.8ms
    //
    // Erwartetes Ergebnis bei korrekter Gleichmäßigkeit:
    //   Alle Δ-Werte nahezu identisch (± Dispatch-Jitter <5 ms).
    //   Kein systematisch längerer Wert bei step 0.
    //
    // Hinweis: Misst Drain-Timing, nicht Render-Timing.
    //   Wenn Drain-Δ gleichmäßig, aber Cursor sichtbar ungleichmäßig →
    //   SwiftUI-Rendering ist die Ursache (Frame-Rate, Animationen).
    static var stepTimingLog: Bool = false
    private var _stepTimingLast:    Double = 0   // CACurrentMediaTime() des letzten Updates
    // hop-Berechnung verwendet Self.machTimebase (bereits vorhanden, static, immer verfügbar)
    #endif

    // MARK: - MIDI-Start-Timing (Arch-Slice-16b)
    //
    // Im INT-Modus wird 0xFA (MIDI Start) NICHT sofort bei play() gesendet.
    // Stattdessen sendet clockTick() es auf dem Tick-Thread mit demselben
    // Future-Timestamp wie den ersten 0xF8-Puls.
    //
    // Grund: ein sofort gesendetes 0xFA läge um den Tick-Vorlauf (ein Tick-Intervall
    // + ClockSource.emitMargin) vor dem ersten 0xF8. Das externe Gerät setzte Beat 1
    // auf „jetzt" und fände den ersten Puls verspätet → Resync-Ruckeln.
    //
    // Fix: 0xFA und erster 0xF8 landen gleichzeitig → sofortiger Lock, kein Ruckeln.
    //
    // Thread-Safety: ManagedAtomic<Bool> — atomar von Main-Thread geschrieben (play/stop),
    // atomar vom Tick-Thread gelesen und gelöscht (clockTick).
    private var midiStartPending: ManagedAtomic<Bool> { kernel.midiStartPending }

    // MARK: - RT-1: Playback-State-Ownership (v1.12.2)
    //
    // Der Tick-Thread (INT: Clock-Thread; EXT: MIDI-Read-Thread) las bisher
    // `isPlaying`, `clockMode` und `queuedPatternIndex` direkt aus den
    // `@Published`-Objekten (TransportState). Das sind Cross-Thread-Datenrennen:
    // Main-Thread schreibt, Audio-/MIDI-Thread liest ungeschützt (auf ARM64 ohne
    // TSO eine reale Gefahr für torn reads / Sichtbarkeitslücken).
    //
    // Fix: atomare Spiegel, geschrieben ausschließlich über die Computed-Property-
    // Setter (isPlaying/clockMode/queuedPatternIndex — alle Schreibpfade laufen dort
    // durch), gelesen vom Audio-/MIDI-Thread. Vorlage: `midiStartPending`.
    //
    // `queuedPatternAtomic`: Sentinel −1 = kein Wechsel angefragt (nil).
    // `clockIsInternal`:     Spiegel von (clockMode == .internal); Default .internal → true.
    // `isPlayingRT`:         Spiegel von isPlaying; Default false.
    private let queuedPatternAtomic = ManagedAtomic<Int>(-1)
    // Beide gehören dem Tick-Kern; die Engine-Namen sind Weiterleitungen.
    @inline(__always) private var clockIsInternal: ManagedAtomic<Bool> { kernel.clockIsInternal }
    @inline(__always) private var isPlayingRT: ManagedAtomic<Bool> { kernel.isPlayingRT }

    #if DEBUG
    // RT-1: Test-only-Fenster auf die atomaren Playback-Spiegel und den
    // aktuell publizierten Bundle. Read-only, keine Mutation. Ermöglicht
    // Bundle-Konsistenz- und Pattern-Queue-Tests ohne Zugriff auf die
    // privaten Atomics.
    func _rt1PublishedBundle() -> PlaybackStateBundle? {
        publisher._publishedBundle
    }
    var _rt1QueuedPatternAtomic: Int  { queuedPatternAtomic.load(ordering: .acquiring) }
    var _rt1ClockIsInternal:     Bool { clockIsInternal.load(ordering: .acquiring) }
    var _rt1IsPlayingRT:         Bool { isPlayingRT.load(ordering: .acquiring) }

    // RT-1a: Deterministisches Test-Setup für die clockTick-Modus-Invariante.
    // Baut Runtimes + Bundle wie play(), aber OHNE die ClockSource zu
    // starten — so lässt sich clockTick(at:) synchron und ohne Tick-Thread-
    // Race treiben. Nur für Unit-Tests der Producer-before-observer-Regel.
    func _rt1SetupRuntimesForTest() {
        beginRuntimeSession()
        publishSnapshot()
        // Tick-Zutritt verlangt isPlayingRT; der @Published-Zustand bleibt unberührt.
        isPlayingRT.store(true, ordering: .sequentiallyConsistent)
    }
    /// Slot des Tracks an Position `track` im zuletzt publizierten Snapshot (−1 = keiner).
    private func _testSlot(track: Int) -> Int {
        guard let b = publisher.current?.bundle, b.snapshot.tracks.indices.contains(track) else { return -1 }
        return b.snapshot.tracks[track].slot
    }
    /// Aktueller Runtime-Step eines Tracks (Test-Fenster). −1 auch für „frisch": eine
    /// Runtime, deren Epoche noch nicht zur Slot-Vergabe passt, startet beim nächsten Tick neu.
    func _rt1CurrentStep(track: Int) -> Int {
        let slot = _testSlot(track: track)
        guard slot >= 0, let b = publisher.current?.bundle else { return -999 }
        let rt = rtRuntimes[slot]
        return rt.epoch == b.snapshot.tracks[track].epoch ? rt.currentStep : -1
    }

    /// Treibt genau einen internen Tick.
    func _rt2DriveOneTick(at ts: UInt64) { clockTick(at: ts) }
    /// Setzt den Cursor eines Tracks (Test-Tagging); bindet die Runtime dabei an die
    /// aktuelle Slot-Epoche, als hätte der Track bereits gespielt.
    func _rt2SetCurrentStep(track: Int, to value: Int) {
        let slot = _testSlot(track: track)
        guard slot >= 0, let b = publisher.current?.bundle else { return }
        rtRuntimes[slot].epoch = b.snapshot.tracks[track].epoch
        rtRuntimes[slot].armed = false
        rtRuntimes[slot].currentStep = value
    }
    /// pulseAccumulator eines Tracks (Read-only) — für Cursor-Erhalt-Prüfung.
    func _rt2PulseAccumulator(track: Int) -> Double {
        let slot = _testSlot(track: track)
        return slot >= 0 ? rtRuntimes[slot].pulseAccumulator : -1
    }
    /// Zahl der Tracks im zuletzt publizierten Snapshot (0 = kein Bundle publiziert).
    func _rt2RuntimeCount() -> Int { publisher.current?.bundle.snapshot.tracks.count ?? 0 }
    /// Sitzung des aktuell publizierten Bundles (nil = keins).
    var _publishedSession: UInt32? { publisher.current?.bundle.session }
    /// Zahl der aktuell vergebenen Runtime-Slots (Main-seitige Buchhaltung).
    var _slotsInUse: Int { slotByTrack.count }
    var _patternSerial: Int { patternSerial }
    /// Ticks, die abgewiesen wurden, weil bereits ein Tick lief (Tick-Zutritt).
    var _rejectedTicks: Int { kernel.rejectedTicks.load(ordering: .relaxed) }
    /// Spätester geplanter Off-Zeitpunkt einer Note im Notenbuch (0 = keiner).
    /// Spätestes bekanntes Off der Note (ungesendet oder gesendet); 0 = Buch leer.
    func _noteBookEntry(channel: Int, note: Int, route: Int = -1) -> UInt64 {
        let e = noteOut._entry(channel: channel, note: note, route: route)
        return max(e.pendingOff, e.sentOff)
    }
    func _noteBookPendingOff(channel: Int, note: Int, route: Int = -1) -> UInt64 {
        noteOut._entry(channel: channel, note: note, route: route).pendingOff
    }
    /// Treibt den Off-Wächter synchron, als stünde die externe Clock schon lange genug still.
    func _runOffWatchdogForTest() { flushOverdueOffsIfClockStalled(stallMach: 0) }

    // RT-3: Test-Fenster auf die Hazard-Pointer-Lebensdauer-Sicherung.
    var _rt3HazardRaw:     Int { publisher._hazardRaw }
    var _rt3AtomicRaw:     Int { publisher._publishedRaw }
    var _rt3CurrentBoxRaw: Int { publisher.current.map  { SnapshotPublisher.rawOf($0) } ?? 0 }
    var _rt3DeferredBoxRaw: Int { publisher._deferredRaw }
    /// Simuliert einen Audio-Leser mitten im Tick: Hazard auf die aktuell
    /// publizierte Box setzen.
    func _rt3AnnounceCurrentHazard() {
        publisher._announceCurrentHazard()
    }
    func _rt3ClearHazard() { publisher.release() }
    /// Welche Box der letzte Tick tatsächlich dereferenziert hat.
    var _rt3LastTickBoxRaw: Int { kernel._rt3LastTickBoxRaw }
    /// Weak-Sonde auf die aktuelle Box — beweist Deallozierung/Am-Leben-Bleiben.
    weak var _rt3WeakProbe: PlaybackBundleBox?
    func _rt3SetWeakProbeToCurrent() { _rt3WeakProbe = publisher.current }
    var _rt3WeakProbeAlive: Bool { _rt3WeakProbe != nil }
    func _rt3DriveOneTick(at ts: UInt64) { clockTick(at: ts) }

    // S01: Test-Fenster an den echten Grenzen des Snapshot-Erwerbs. Der Hook läuft
    // synchron auf dem Reader-Thread; ein Test, der darin publishSnapshot() aufruft,
    // erzwingt Pointerwechsel deterministisch (kein Allocator-Zufall). Nur DEBUG —
    // der Produktionsbuild enthält weder Hook noch Aufruf.
    typealias _S01Stage = SnapshotPublisher.Stage
    var _s01AcquireHook: ((_S01Stage, Int) -> Void)? {
        get { publisher._acquireHook } set { publisher._acquireHook = newValue }
    }
    var _s01ForceExhaustion: ManagedAtomic<Bool> { publisher._forceExhaustion }
    /// Anzahl publishSnapshot()-Aufrufe (nur Main schreibt) — Diagnose für Swing-/Main-Hop-Tests.
    private(set) var _s01PublishCount = 0
    /// Anzahl abgebrochener Gesamttick wegen erschöpftem Erwerb (Atomic-Spiegel).
    var _s01AcquireFailures: Int { publisher.acquireFailures }
    /// Entscheidungsstellen der Clock-Ausgabe in clockTick (Aufruf von sendClock/sendStartRT).
    /// Zählt nur den Sendeentschluss, keine CoreMIDI-Bytes (Beobachtungsnaht: Slice S04).
    var _s01ClockSendCount: Int { kernel._s01ClockSendCount }
    var _s01StartSendCount: Int { kernel._s01StartSendCount }
    var _s01MidiStartPending: Bool { midiStartPending.load(ordering: .acquiring) }
    func _s01ArmMidiStart() { midiStartPending.store(true, ordering: .releasing) }
    func _s01PulseAccumulator(track: Int) -> Double { _rt2PulseAccumulator(track: track) }
    /// Deinit-Sonde an der aktuell publizierten Box (feuert auf dem Thread, der die letzte Referenz löst).
    func _s01SetDeinitProbeOnCurrent(_ probe: @escaping () -> Void) { publisher.current?._deinitProbe = probe }
    /// Sonde (Deinit + Weak) auf die Box, die der Reader gerade hält (`_rt3LastTickBoxRaw`).
    /// Nur aufrufen, während der Reader geparkt ist — sein Hazard hält die Box am Leben.
    func _s01ProbeHeldBox(_ probe: @escaping () -> Void) {
        guard let p = UnsafeRawPointer(bitPattern: _rt3LastTickBoxRaw) else { return }
        let box = Unmanaged<PlaybackBundleBox>.fromOpaque(p).takeUnretainedValue()
        box._deinitProbe = probe
        _rt3WeakProbe = box
    }

    // RT-3a: Test-Fenster auf die Stop-/External-Clock-Quieszenz.
    /// Einmaliger Pause-Hook mitten in advanceSteps() (nach Snapshot-Erwerb +
    /// Hazard-Announce, vor MIDI-Emission) — Test-Fenster, um einen externen
    /// Tick deterministisch mitten im Lauf zu parken. No-op wenn nil; feuert
    /// höchstens einmal (selbst-löschend), kein Folge-Tick pausiert versehentlich.
    var _rt3aPausePoint: (() -> Void)? {
        get { kernel._rt3aPausePoint } set { kernel._rt3aPausePoint = newValue }
    }
    var _rt3aActiveTick: Bool { activeTick.load(ordering: .acquiring) }
    /// Treibt den EXTERNEN Clock-Pfad direkt (tick(scheduledAt:) ist private) —
    /// exakt der Aufrufpfad von midi.onClockPulse auf dem MIDI-Read-Thread.
    func _rt3aDriveOneExternalTick(at ts: UInt64) { tick(scheduledAt: ts) }
    var _extLookaheadMach: UInt64 { extLookaheadMach.load(ordering: .relaxed) }
    var _skipReconcileOnce = false
    var _horizonUnderruns: Int { rtHorizonUnderruns.load(ordering: .relaxed) }
    var _planConflicts: Int { rtPlanConflicts.load(ordering: .relaxed) }
    var _clockExtraLeadNs: Double { audioClock.extraLeadNs }
    var _lateTicks: Int { rtLateTicks.load(ordering: .relaxed) }

    // RT-3b: Test-Fenster auf den Fail-Safe Deferred Cleanup.
    var _rt3bCleanupPending: Bool { stopCleanupPending }

    // RT-4a: Test-Fenster auf die Catch-up-/Resync-Strategie (geclampte
    // ausgehende 0xF8-Pulse werden verworfen statt gebursted — die interne
    // Step-Fortschreibung in advanceSteps() bleibt davon unberührt, s.
    // clockTick() unten).
    var _rt4ClampCountClock: Int { clampCountClock.load(ordering: .relaxed) }

    // RT-4b: Test-Fenster auf den RT-sicheren PRNG — deterministischer Seed
    // für reproduzierbare Zufalls-Assertions (Random-Direction, Probability-Gate).
    func _rt4bSetRandomSeedForTest(_ seed: UInt64) { kernel.rtRandom = RTRandom(seed: seed) }
    #endif

    // Zeitumrechnung: `HostTime` (v1.16.1). Die Engine-Namen bleiben als Weiterleitung.
    private static var machTimebase: mach_timebase_info_data_t { HostTime.timebase }
    @inline(__always)
    static func shifted(_ t: UInt64, bySeconds seconds: Double) -> UInt64 { HostTime.shifted(t, bySeconds: seconds) }
    static func machToNanos(_ t: UInt64) -> UInt64 { HostTime.machToNanos(t) }
    static func nanosToMachTime(_ ns: UInt64) -> UInt64 { HostTime.nanosToMachTime(ns) }

    /// RT-SAFE: Klemmt einen MIDITimeStamp auf ≥ jetzt + 1 ms.
    /// Identische Logik wie der Safety-Clamp in advanceSteps() — als shared Helper extrahiert,
    /// damit clockTick() denselben Clamp-Boden verwenden kann.
    /// @inline(__always): Keine Call-Overhead im Tick-Thread-Pfad.
    @inline(__always)
    private var cancellables:      Set<AnyCancellable> = []
    /// Per-Track-Mutations subscribing bag — rebuilt automatically whenever the
    /// pattern / track structure changes. Cleared at the start of every
    /// `rebuildAllTrackSubs(for:)` call.
    private var trackChangeSubs:      Set<AnyCancellable> = []
    /// Structural subscriptions — one per Pattern, watching `pattern.$tracks`.
    /// Cleared and rebuilt alongside `trackChangeSubs`.
    private var patternStructureSubs: Set<AnyCancellable> = []
    /// RunLoop-coalescing gate for `publishSnapshot()`.
    ///
    /// Set to `true` when the first `td.changed` fires during a RunLoop pass and
    /// a `main.async` snapshot rebuild is already enqueued. Subsequent fires within
    /// the same synchronous execution path skip the enqueue — only one snapshot
    /// is published per RunLoop pass regardless of how many `changed.send()` calls
    /// arrived (e.g. dragging velocity across 16 steps fires 16 sends → 1 snapshot).
    ///
    /// The async closure always resets the flag **before** the `isPlaying` guard so
    /// the flag is never left `true` after the closure runs, even on a Stop/Play cycle.
    private var snapshotPending = false
    /// Main-only: true, während die EXT-Clock-BPM-Schätzung `bpm` schreibt (kein Dirty-Flag).
    private var applyingExternalBPMEstimate = false
    /// Main-only: ein asynchroner Speichervorgang läuft (v1.16.1).
    var saveInFlight = false
    var currentPattern: Pattern { patterns[currentPatternIndex] }

    init() {
        _ = kernel    // jetzt (Main) anlegen, samt `noteOut` — der Tick-Pfad darf nie eine
                      // lazy-Initialisierung auslösen
        midi.setup()
        loadRecentFiles()
        startDisplaySignal()
        // AU-Host: Änderungen am Rack sind Projektänderungen; eine neue Slot-Zuordnung muss
        // in den Playback-Snapshot. Ein entfernter Kanal stellt seine Spuren auf externe
        // MIDI-Ausgabe zurück (sonst blieben sie an einer toten ID hängen).
        rack.onProjectChange = { [weak self] in
            self?.presetEditorState.markChanged()
        }
        rack.onRoutingChange = { [weak self] in
            guard let self, self.transportState.isPlaying else { return }
            self.publishSnapshot()
        }
        rack.onOutputConfigChange = { [weak self] in self?.updateExtLookahead() }
        rack.onChannelRemoved = { [weak self] id in
            guard let self else { return }
            for pattern in self.patterns {
                for td in pattern.tracks where td.instrumentID == id {
                    td.instrumentID = nil
                    td.changed.send()
                }
            }
        }
        // onTick einmalig vor start() setzen — Lebenszyklus-Pflicht (ClockSource).
        // Der Clock-Thread erreicht nur den Tick-Kern (kein Engine-Zugriff, kein weak-Load).
        audioClock.onTick = { [kernel] timestamp in
            kernel.clockTick(at: timestamp)
        }
        midi.onClockPulse = { [weak self] packetTime in
            // Guard: nur im EXT-Modus verarbeiten.
            // Verhindert Doppel-Tick wenn ClockSource (INT) und eingehende
            // 0xF8-Nachrichten (z.B. aus Logic) gleichzeitig aktiv sind → vorher: 2× Tempo-Bug.
            // RT-1: atomarer Read statt @Published (läuft auf dem MIDI-Read-Thread).
            guard let self, !self.clockIsInternal.load(ordering: .acquiring) else { return }
            let now = packetTime
            if self.extResetRequested.exchange(false, ordering: .acquiringAndReleasing) {
                self.extPulseCount = 0
            }
            // BPM-Schätzung aus Pulsabstand: alle 24 Pulse (= 1 Beat) neu berechnen.
            // Aktualisiert die BPM-Anzeige im Takt des externen Masters.
            self.extPulseCount += 1
            if self.extPulseCount == 1 {
                self.extBeatStart = now
            } else if self.extPulseCount > 24 {
                let tb = SequencerEngine.machTimebase
                let intervalMach = now - self.extBeatStart
                let intervalNS   = Double(intervalMach) * Double(tb.numer) / Double(tb.denom)
                if intervalNS > 0 {
                    let calcBPM = (60_000_000_000.0 / intervalNS * 10).rounded() / 10
                    if calcBPM > 20 && calcBPM < 300 {
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.applyingExternalBPMEstimate = true
                            self.bpm = calcBPM
                            self.applyingExternalBPMEstimate = false
                        }
                    }
                }
                self.extPulseCount = 1
                self.extBeatStart  = now
            }
            // Fester Vorlauf ab der Paketzeit: konstante Phase zum Master, Future-Timestamps
            // für CoreMIDI, AU-Warteschlangen und Taktanker.
            self.tick(scheduledAt: packetTime &+ self.extLookaheadMach.load(ordering: .relaxed))
        }
        midi.onStart      = { [weak self] in self?.startFromExternal(isContinue: false) }
        midi.onStop       = { [weak self] in
            // RT-1: atomare Reads statt @Published (läuft auf dem MIDI-Read-Thread).
            guard let self,
                  self.isPlayingRT.load(ordering: .acquiring),
                  !self.clockIsInternal.load(ordering: .acquiring) else { return }
            self.stop()
        }
        midi.onContinue   = { [weak self] in self?.startFromExternal(isContinue: true) }
        // 0xFA/0xFB direkt auf dem MIDI-Read-Thread (v1.15.2): eine im Stopp vorbereitete
        // Sitzung wird sofort scharf — der nächste 0xF8 ist Puls 0, auch wenn Main noch
        // beschäftigt ist. Main zieht Anzeige und Transportzustand danach nach.
        midi.onStartRT    = { [weak self] in
            guard let self, !self.clockIsInternal.load(ordering: .acquiring),
                  self.extArmed.exchange(false, ordering: .acquiringAndReleasing) else { return }
            self.extStartedRT.store(true, ordering: .releasing)
            self.isPlayingRT.store(true, ordering: .sequentiallyConsistent)
        }
        midi.onCC         = { [weak self] _, num, val in self?.handleIncomingCC(num, val) }
        midi.onNoteOn     = { [weak self] _, note, _ in self?.handleLearnNoteOn(note) }
        // C1: MIDI Device Disconnect — läuft auf dem Main-Thread (via refreshPorts).
        midi.onOutputDisconnected = { [weak self] in
            self?.lastErrorMessage = self?.strings.errMIDIOutputGone
        }
        // Slice B: midi.objectWillChange-Forwarding entfernt.
        // MIDIManager ist als eigenes @EnvironmentObject(engine.midi) injiziert.
        // SettingsView und StatusBar subscriben direkt via @EnvironmentObject MIDIManager —
        // MIDI-Device-Änderungen feuern nicht mehr engine.objectWillChange.
        // Pre-Lane Slice F: reaktive Track-Subscription einrichten.
        // Ersetzt den manuellen resubscribeTrackChanges()-Aufruf.
        setupTrackSubscriptions()
        // Arch-Slice-19: Combine-Sinks für TransportState-Seiteneffekte.
        // Ersetzt die früheren @Published-didSet-Blöcke für bpm und clockMode.
        setupTransportSinks()
    }

    deinit {
        // libdispatch rule: a suspended DispatchSource must not be released while suspended.
        // cancel() followed by resume() is the documented teardown sequence for inactive sources.
        // Arch-Slice-12a: discovered by WorkflowEngineTests.PlaybackTransportTests.
        // Without this, ARC deinit of a test-scope SequencerEngine crashes with:
        //   BUG IN CLIENT OF LIBDISPATCH: Release of an inactive object
        offWatchdog?.cancel()
        displaySignal?.cancel()
        if !isPlaying {
            // Signal was suspended (D4) — must be resumed once after cancel() so
            // libdispatch can complete its internal teardown without the crash.
            displaySignal?.resume()
        }
    }

    // MARK: - Reactive Track Subscriptions (Pre-Lane Slice F)

    /// One-time setup called from `init()`.
    ///
    /// 1. Does an immediate `rebuildAllTrackSubs` for the current (initial) patterns.
    /// 2. Subscribes to future `$patterns` changes so that preset loads, `newProject()`,
    ///    and `pasteToCurrentPattern()` trigger an automatic rebuild without any
    ///    manual call-site.
    ///
    /// Track-structural changes (add / remove / insert / duplicate / restore) are handled
    /// by per-Pattern `pattern.$tracks` watchers installed inside `rebuildAllTrackSubs`.
    private func setupTrackSubscriptions() {
        rebuildAllTrackSubs(for: patterns)   // initial setup

        // React to future $patterns replacements (preset load, newProject, pastePattern).
        $patterns
            .dropFirst()   // initial value already handled above
            .sink { [weak self] newPatterns in
                self?.rebuildAllTrackSubs(for: newPatterns)
            }
            .store(in: &cancellables)
    }

    /// Rebuilds both `patternStructureSubs` (Pattern.$tracks watchers) and
    /// `trackChangeSubs` (Track.objectWillChange handlers) from the given pattern set.
    ///
    /// **Safe to call from within a Combine sink** — Combine allows a subscription to
    /// cancel itself (by clearing the bag that holds it) during its own sink closure.
    ///
    /// **Thread safety:** always called on the Main Thread (all pattern/track mutations
    /// happen on Main Thread; `$patterns` and `pattern.$tracks` emit on their write thread).
    ///
    /// **Subscription lifetime:**
    ///   - `patternStructureSubs` is owned by the Engine instance. Each rebuild clears
    ///     the bag first, which cancels all previous structural watchers before installing
    ///     the new ones. No dangling structural subscriptions.
    ///   - `trackChangeSubs` is similarly owned and cleared on each rebuild. Old Track
    ///     objects whose sinks are cancelled are released by the bag; they hold no strong
    ///     reference back to Engine (only `[weak self]`). No leak.
    ///
    /// **No rebuild loops:**
    ///   - Track sinks write `hasUnsavedChanges` and defer `publishSnapshot()`. Neither
    ///     touches `patterns` or `pattern.tracks` → no re-trigger. ✓
    ///   - Pattern.$tracks sinks call `rebuildAllTrackSubs(for: self.patterns)` but do NOT
    ///     modify `patterns` or `pattern.tracks` themselves → no re-trigger. ✓
    private func rebuildAllTrackSubs(for patterns: [Pattern],
                                     pending: (pattern: Pattern, tracks: [TrackData])? = nil) {
        #if DEBUG
        _subscriptionRebuilds += 1
        #endif
        trackChangeSubs      = []
        patternStructureSubs = []

        for pattern in patterns {
            // Level 2 — structural watcher.
            // When pattern.tracks is mutated (append / remove / insert), $tracks fires
            // → full rebuild automatically picks up the new track set.
            // @Published emittiert im willSet: `pattern.tracks` trägt hier noch den ALTEN
            // Stand. Deshalb den emittierten Wert verwenden — sonst bliebe der neu
            // eingefügte Track dieses Patterns ohne Change-Subscription.
            pattern.$tracks
                .dropFirst()
                .sink { [weak self, weak pattern] newTracks in
                    guard let self, let pattern else { return }
                    // In einer Strukturtransaktion genau ein Neuaufbau am Ende (Codex A17-07).
                    if self.structureTransactionDepth > 0 { self.structureRebuildPending = true; return }
                    self.rebuildAllTrackSubs(for: self.patterns, pending: (pattern, newTracks))
                }
                .store(in: &patternStructureSubs)

            // Level 3 — content-change handlers.
            // Lane-Modell v1: container and sequence signals fire independently;
            // both must mark unsaved changes and trigger a snapshot republish
            // during playback. We subscribe to td.changed AND td.lane.changed
            // with an identical handler. `snapshotPending` coalesces multiple
            // emissions (container + lane, or multi-step drags) into one rebuild
            // per RunLoop pass.
            let handler: () -> Void = { [weak self] in
                guard let self else { return }
                self.hasUnsavedChanges = true
                guard self.isPlaying, !self.snapshotPending else { return }
                self.snapshotPending = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    // Reset flag unconditionally — before the isPlaying guard —
                    // so a Stop/Play cycle never leaves the flag stuck at true.
                    self.snapshotPending = false
                    guard self.isPlaying else { return }
                    self.publishSnapshot()
                }
            }
            let liveTracks = (pending?.pattern === pattern) ? pending!.tracks : pattern.tracks
            for td in liveTracks {
                td.changed
                    .sink(receiveValue: handler)
                    .store(in: &trackChangeSubs)
                td.lane.changed
                    .sink(receiveValue: handler)
                    .store(in: &trackChangeSubs)
            }
        }
    }

    // MARK: - Display-Signal (Event-basiert)

    /// Richtet das event-basierte Display-Signal ein (DispatchSource.makeUserDataOrSource).
    /// Ersetzt den früheren 16-ms-Polling-Timer — Signal feuert nur wenn advanceSteps
    /// tatsächlich neue Daten in den Ring-Buffer geschrieben hat (displaySignal.or(1)).
    /// Eliminiert Timer-Moiré (Interferenz 16ms-Timer ↔ Step-Events).
    /// Der Handler startet im suspendierten Zustand — resume() wird in play() aufgerufen.
    /// Leert den Ring-Buffer und schreibt playbackDisplay.steps auf dem Main-Thread.
    /// objectWillChange feuert auf playbackDisplay, nicht auf SequencerEngine —
    /// nur StepGridView (via @EnvironmentObject playbackDisplay) wird invalidiert.
    ///
    /// **Arch-Slice-14 — "Publishing changes from within view updates"-Fix:**
    /// Vorher: `queue: .main` → Handler feuerte synchron auf dem GCD-Main-Queue und
    /// konnte einen laufenden SwiftUI-Render-Pass unterbrechen → @Published-Write
    /// löste nested OWC aus → Warning + Render-Kaskade (StepGrid 304/s, Einfrieren).
    /// Nachher: `queue: drainQueue` (Background) → Handler postet via `main.async`
    /// → @Published-Writes landen zwischen RunLoop-Iterationen, nie während eines
    /// aktiven Render-Passes → Warning beseitigt, Kaskade eliminiert.
    private func startDisplaySignal() {
        // Arch-Slice-14: Dedizierte Background-Queue für den DispatchSource-Handler.
        // Die Queue wird vom DispatchSource retained — kein Instanz-Ivar nötig.
        let drainQueue = DispatchQueue(label: "com.vintageseq.displayDrain", qos: .userInteractive)
        let signal = DispatchSource.makeUserDataOrSource(queue: drainQueue)
        signal.setEventHandler { [weak self] in
            // Alle Drain-Arbeit auf dem Main-Thread ausführen, aber als async-Block —
            // damit @Published-Writes nie in einen laufenden SwiftUI-Render-Pass fallen.
            DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            #if DEBUG
            let drainStart = CACurrentMediaTime()
            #endif

            // ── Arch-Slice-18: Scheduled Display Updates ─────────────────────────────
            //
            // Problem (diagnostiziert): displayBuffer.push verwendete mach_absolute_time()
            // als hostTime — d.h. den damaligen Audio-Callback-Zeitpunkt, der auf das 5.8ms-Raster
            // quantisiert ist. Step-Intervalle variierten dadurch zwischen 96ms und 107ms
            // statt uniform 125ms (bei 120 BPM). Ursache: nicht-ganzzahliges Verhältnis
            // Tick-Intervall (20.83ms) / Callback-Intervall (5.80ms) = 3.59.
            //
            // Fix: hostTime = tickTime (geplanter Tick-Zeitpunkt als MIDITimeStamp).
            // tickTime-Werte sind exakt uniform (additives Modell in ClockSource).
            // Der Drain liest tickTime, berechnet den verbleibenden Delay bis zum geplanten
            // Zeitpunkt und plant asyncAfter exakt dorthin → Step-Cursor wechselt zum
            // musikalischen Zeitpunkt, nicht zur nächsten Callback-Grenze.
            //
            // P3-Invariante erhalten: alle Tracks eines Ticks tragen denselben tickTS
            // → eine Gruppe → ein asyncAfter-Block → ein objectWillChange-Broadcast.
            //
            // Arch-Slice-14-Invariante erhalten: @Published-Write erfolgt in asyncAfter
            // (deferred) → nie während eines laufenden SwiftUI-Render-Passes.

            // --- 1. displayBuffer leeren, nach tickTS gruppieren ---
            var groups: [UInt64: [(track: Int, step: Int)]] = [:]
            let stepCount = self.playbackDisplay.steps.count
            self.displayBuffer.drain { event in
                let t = Int(event.trackIdx)
                let s = Int(event.stepIdx)
                guard t < stepCount else { return }
                groups[event.hostTime, default: []].append((track: t, step: s))
            }

            // --- 2. Pro Gruppe: asyncAfter zum tickTS planen ---
            // numer/denom als lokale Kopien — einmal gelesen, in alle Closures captured.
            let nowMach = mach_absolute_time()
            let numer   = Double(Self.machTimebase.numer)
            let denom   = Double(Self.machTimebase.denom)
            for (tickTS, updates) in groups {
                let delaySecs: Double
                if tickTS > nowMach {
                    let deltaNs = Double(tickTS - nowMach) * numer / denom
                    delaySecs   = deltaNs / 1_000_000_000.0
                } else {
                    // tickTS liegt in der Vergangenheit (z.B. OS-Sleep-Catchup):
                    // asyncAfter(0) ≙ main.async — deferred, nie synchron. ✓
                    delaySecs = 0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + delaySecs) { [weak self] in
                    // R1 (Stop-Guard): Closures, die beim stop() bereits geplant waren,
                    // dürfen nach dem Stop-Zeitpunkt keine Display-Schreibzugriffe mehr machen.
                    guard let self, self.isPlaying else { return }
                    // P3: alle Tracks der Gruppe in eine lokale Kopie schreiben,
                    // dann einmal zuweisen → ein objectWillChange-Broadcast.
                    var steps   = self.playbackDisplay.steps
                    var changed = false
                    for u in updates where u.track < steps.count {
                        if steps[u.track] != u.step {
                            steps[u.track] = u.step
                            changed         = true
                        }
                    }
                    guard changed else { return }
                    self.playbackDisplay.steps = steps
                    #if DEBUG
                    // stepTimingLog: IN der asyncAfter-Closure — misst den tatsächlichen
                    // sichtbaren Umschaltzeitpunkt (nicht den Drain-Zeitpunkt).
                    // Δ   = Abstand zwischen zwei Step-Wechseln (Gleichmäßigkeit).
                    // hop = Abstand zwischen geplantem tickTS und tatsächlicher Ausführung
                    //       → zeigt asyncAfter-Scheduling-Jitter (Ziel: 0–3ms).
                    if Self.stepTimingLog, !steps.isEmpty,
                       let t0 = updates.first(where: { $0.track == 0 }) {
                        let nowMs = CACurrentMediaTime() * 1000.0
                        let step  = t0.step
                        let last  = self._stepTimingLast
                        // hop: tatsächliche Ausführungszeit minus geplantem tickTS
                        let nowMach2 = mach_absolute_time()
                        let hopMs: Double
                        if nowMach2 >= tickTS {
                            let ns = Double(nowMach2 - tickTS) * numer / denom
                            hopMs  = ns / 1_000_000.0
                        } else {
                            hopMs = 0.0   // asyncAfter feuerte minimal zu früh — vernachlässigbar
                        }
                        if last > 0 {
                            let delta = nowMs - last
                            let bar   = step == 0 ? "  ◀ BAR" : ""
                            print(String(format: "🕐 s%02d  Δ%.1fms  hop+%.1fms%@",
                                         step, delta, hopMs, bar))
                        }
                        self._stepTimingLast = nowMs
                    }
                    #endif
                }
            }

            // --- 3. Engine-Events (A2+A3): Pattern-Switch, NotesFired — unverändert ---
            self.engineEventBuffer.drain { event in
                switch event.tag {
                case .notesFired:
                    let t = Int(event.trackIdx)
                    let tracks = self.currentPattern.tracks
                    guard t < tracks.count else { return }
                    // Slice G: lastFiredNotes lives on TrackViewModel, not TrackData.
                    let vm = self.viewModel(for: tracks[t])
                    vm.lastFiredNotes = event.notesArray()
                    // Visual-Clear nach Gate-Dauer — asyncAfter vom Main-Thread ist kein RT-Problem.
                    let delayMs = Int(event.offDelayMs)
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
                        guard let self else { return }
                        let tracks = self.currentPattern.tracks
                        if t < tracks.count {
                            if let vm = self.vmCache[tracks[t].id] {
                                vm.lastFiredNotes = []
                            }
                        }
                    }
                case .patternSwitch:
                    // Nur Weckruf: der Tick-Thread hat bereits gewechselt. Main zieht den
                    // sichtbaren Zustand nach; maßgeblich ist das Atomic, nicht das Event.
                    if self.reconcilePatternSwitch() { self.publishSnapshot() }
                }
            }

            // Falls das Weck-Event bei vollem Ring verworfen wurde: hier nachziehen.
            if self.reconcilePatternSwitch() { self.publishSnapshot() }
            // Songende erreicht (Tick-Thread spielt nichts mehr an): anhalten.
            self.stopIfSongEnded()
            self.reportPlanDiagnostics()

            // --- 4. S01: abgebrochene Gesamttick sichtbar machen (StatusBar) ---
            self.syncSnapshotAcquireDisplay()

            #if DEBUG
            let drainMs = (CACurrentMediaTime() - drainStart) * 1000
            if drainMs > 2.0 {
                print("⏱️ drain \(String(format: "%.1f", drainMs))ms groups=\(groups.count)")
            }
            // Arch-Slice-14+: Clamp-Diagnose — unverändert.
            // clampCountNotes steigt → MIDI Note-Timestamps lagen in der Vergangenheit
            //   → Tick kam zu spät → Notes wurden auf "jetzt" geclampt
            //   → mehrere Notes feuern gleichzeitig statt gleichmäßig → hörbarer "Haken".
            // clampCountClock steigt → dasselbe für ausgehende 0xF8-Clock-Pulse.
            let snapNotes = self.clampCountNotes.load(ordering: .relaxed)
            let snapClock = self.clampCountClock.load(ordering: .relaxed)
            let deltaNotes = snapNotes - _drainLastClampNotes
            let deltaClock = snapClock - _drainLastClampClock
            if deltaNotes > 0 || deltaClock > 0 {
                print("🔴 MIDI-CLAMP ΔNotes=\(deltaNotes) ΔClock=\(deltaClock) totalNotes=\(snapNotes) totalClock=\(snapClock) — Tick zu spät, Vorlauf nicht ausreichend!")
                _drainLastClampNotes = snapNotes
                _drainLastClampClock = snapClock
            }
            #endif
            } // end DispatchQueue.main.async (Arch-Slice-14)
        }
        // Signal suspendiert belassen — wird in play() via resume() aktiviert (D4).
        displaySignal = signal
    }

    // MARK: - S01 — Anzeige abgebrochener Ticks (Main-Thread only)

    /// Sitzungsbezogener Nullpunkt des atomaren Fehlerzählers (Main).
    private var snapshotAcquireBaseline = 0
    private var acquireDisplayLastPublish: CFTimeInterval = 0
    private var acquireDisplaySyncScheduled = false

    /// Setzt die Anzeige für eine neue Sitzung zurück (play()/EXT-Start). Main.
    private func resetSnapshotAcquireDisplay() {
        snapshotAcquireBaseline = publisher.acquireFailures
        acquireDisplayLastPublish = 0
        if clockDiagnostics.snapshotAcquireFailures != 0 { clockDiagnostics.snapshotAcquireFailures = 0 }
    }

    /// Spiegelt den atomaren Fehlerzähler (Reader schreibt) nach `clockDiagnostics`, das die
    /// StatusBar beobachtet. Der erste Fehler erscheint sofort; weitere Änderungen werden auf
    /// höchstens ein Update pro Sekunde koalesziert (kein Invalidierungssturm pro Tick), ein
    /// nachlaufender Abgleich stellt den Endstand sicher. Main.
    private func syncSnapshotAcquireDisplay() {
        let total = publisher.acquireFailures - snapshotAcquireBaseline
        let shown = clockDiagnostics.snapshotAcquireFailures
        guard total != shown else { return }
        let now = CACurrentMediaTime()
        if shown == 0 || now - acquireDisplayLastPublish >= 1.0 {
            clockDiagnostics.snapshotAcquireFailures = total
            acquireDisplayLastPublish = now
        } else if !acquireDisplaySyncScheduled {
            acquireDisplaySyncScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                self.acquireDisplaySyncScheduled = false
                self.syncSnapshotAcquireDisplay()
            }
        }
    }

    // MARK: - Snapshot Building (Main-Thread only)

    /// Baut einen vollständig validierten PatternSnapshot aus dem aktuellen Edit-Model.
    /// Darf ausschließlich auf dem Main-Thread aufgerufen werden.
    /// Der Tick-Thread vertraut blind auf die gelieferten Werte — keine ungültigen
    /// Werte dürfen den Snapshot verlassen.
    private func buildPatternSnapshot(for pattern: Pattern, index: Int) -> PatternSnapshot {
        let meter = pattern.timeSignature
        let tracks = pattern.tracks.map { track -> TrackSnapshot in
            let lane = track.lane
            // Steplänge „Gruppe" (v1.18.30): Längen je Step aus der Gruppierung des Patterns;
            // ohne Gruppierung ein Takt.
            let grouped: (pps: Double?, groups: StepGroups) = {
                guard lane.stepGroup else { return (nil, StepGroups()) }
                let g = lane.groupSixteenths(meter).map { 6.0 * Double($0) }
                return g.count > 1 ? (g[0], StepGroups(g)) : (g[0], StepGroups())
            }()

            // Exhaustiveness-Anker (Lane Slice 3):
            // Der einzige Ort, an dem `LaneKind` zum Dispatch wird. Künftige
            // Lane-Typen fügen hier einen Case hinzu und werden vom Compiler
            // markiert. `advanceSteps` bleibt bewusst step-only — die Weiche
            // sitzt hier, nicht im Hot-Path.
            // Kein `default` — Exhaustiveness ist der Zweck dieses Switches.
            let laneSnap: LaneSnapshot
            switch lane.kind {
            case .step:
                let stepCount = max(1, min(64, lane.stepCount))
                let den       = max(1, lane.stepLengthDenominator)
                let num       = max(1, lane.stepLengthNumerator)
                let pps       = max(0.001, 6.0 * Double(num) / Double(den))

                let steps = (0..<stepCount).map { i -> StepSnapshot in
                    let s = lane.steps[i]
                    let notes = lane.fixedNotes.map { $0.map { max(0, min(127, $0)) } }
                        ?? (s.notes.isEmpty ? [60] : s.notes.map { max(0, min(127, $0)) })
                    return StepSnapshot(
                        isActive:    s.isActive,
                        notes:       notes,
                        velocity:    max(1, min(127, s.velocity)),
                        gate:        max(0.001, s.gate),
                        probability: max(0.0, min(1.0, s.probability)),
                        ratchet:     s.ratchet,
                        isDrone:     s.isDrone,
                        isHold:      s.isActive && s.isHold,
                        holdSpan:    Self.holdSpan(after: i, in: lane.steps, count: stepCount)
                    )
                }

                laneSnap = LaneSnapshot(
                    kind:          .step,
                    stepCount:     stepCount,
                    direction:     lane.direction,
                    pulsesPerStep: grouped.pps ?? pps,
                    payload:       .step(steps: steps),
                    groups:        grouped.groups
                )
            case .cc:
                let stepCount = max(1, min(64, lane.stepCount))
                let den       = max(1, lane.stepLengthDenominator)
                let num       = max(1, lane.stepLengthNumerator)
                let pps       = max(0.001, 6.0 * Double(num) / Double(den))

                let ccs = (0..<stepCount).map { i -> Int in
                    max(0, min(127, lane.ccValues[i]))
                }

                laneSnap = LaneSnapshot(
                    kind:          .cc,
                    stepCount:     stepCount,
                    direction:     lane.direction,
                    pulsesPerStep: grouped.pps ?? pps,
                    payload:       .cc(values:  ccs,
                                       number:  max(0, min(127, lane.ccNumber)),
                                       isMuted: lane.ccIsMuted),
                    groups:        grouped.groups
                )
            }

            let binding = runtimeBinding(for: track.id)
            // CC-Lane mit Instrument-Parameter: Bereich jetzt (Main) auflösen. Fehlt der
            // Parameter oder lädt das Instrument noch, bleibt es bei MIDI-CC.
            let route = rack.route(for: track.output)
            var parameter: ParameterTarget?
            var ccUnresolved = false
            if lane.kind == .cc, let ref = lane.ccParameter, route >= 0, let ch = track.instrumentID {
                if let target = rack.resolveParameter(ref, in: ch) { parameter = target }
                else { ccUnresolved = true }
            }
            return TrackSnapshot(
                lane:          laneSnap,
                midiChannel:   max(1, min(16, track.midiChannel)),
                isMuted:       track.isMuted,
                isSolo:        track.isSolo,
                timingOffset:  track.timingOffset,
                slot:          binding.slot,
                epoch:         binding.epoch,
                route:         route,
                routeEpoch:    rack.routeEpoch(for: track.output),
                parameter:     parameter,
                ccUnresolved:  ccUnresolved,
                isAudioLoop:   track.isAudioLoop && route >= 0
            )
        }

        let hasSolo = tracks.contains { $0.isSolo }
        return PatternSnapshot(tracks: tracks, hasSolo: hasSolo, meter: pattern.timeSignature, pattern: index)
    }

    // MARK: Runtime-Slot-Vergabe (Main-Thread only)

    /// Liefert Slot + Epoche für eine Track-Identität; vergibt bei Bedarf einen freien Slot
    /// mit neuer Epoche. Ohne freien Slot: (−1, 0) → der Track bleibt stumm (> 256 Tracks
    /// in aktuellem + vorgemerktem Pattern; praktisch unerreichbar).
    private func runtimeBinding(for id: UUID) -> (slot: Int, epoch: UInt32) {
        if let b = slotByTrack[id] { return b }
        guard let slot = freeSlots.popLast() else { return (-1, 0) }
        let b = (slot: slot, epoch: nextSlotEpoch)
        nextSlotEpoch &+= 1
        if nextSlotEpoch == 0 { nextSlotEpoch = 1 }   // 0 = „nie gebunden"
        slotByTrack[id] = b
        return b
    }

    /// Gibt die Slots aller Tracks frei, die weder im aktuellen noch im vorgemerkten
    /// Pattern liegen. Ein später zurückkehrender Track bekommt eine neue Epoche und
    /// startet damit frisch. Sicher gegen den Tick-Thread: der sieht eine Neuvergabe erst
    /// mit dem Snapshot, der sie enthält — zusammen mit der neuen Epoche.
    private func releaseUnusedSlots(keeping live: Set<UUID>) {
        for (id, b) in slotByTrack where !live.contains(id) {
            slotByTrack[id] = nil
            freeSlots.append(b.slot)
        }
    }

    /// Beginnt eine neue Wiedergabe-Sitzung: alle Slot-Bindungen verwerfen (jeder Track
    /// bekommt eine neue Epoche → frische Runtime), neue Aktivierungsnummer.
    private func beginRuntimeSession() {
        slotByTrack.removeAll(keepingCapacity: true)
        freeSlots = Array((0..<Self.runtimeSlotCount).reversed())
        patternSerial += 1
        planLedger.beginSession()
    }

    /// Zieht einen vom Tick-Thread vollzogenen Patternwechsel auf Main nach
    /// (currentPatternIndex, Anzeige). `true`, wenn ein Wechsel übernommen wurde —
    /// der Aufrufer publiziert danach einen Snapshot mit der neuen Aktivierung.
    @discardableResult
    private func reconcilePatternSwitch() -> Bool {
        // Der Tick-Thread kann seit dem letzten Publish mehrere geplante Wechsel vollzogen
        // haben (Song, v1.15.1): k = Anzahl, maßgeblich ist der zuletzt vollzogene.
        // Zuordnung über Sitzung und Plan-Linie des Stempels (v1.15.2): nur so lässt sich ein
        // Wechsel unter einer inzwischen ersetzten Vormerkung richtig benennen (Codex R6).
        let stamp = rtSwitchStamp.load(ordering: .acquiring)
        guard planLedger.matchesSession(stampByte: UInt32(stamp >> 56)) else { return false }
        let plan = UInt32((stamp >> 44) & 0xFFF)
        let low = UInt32((stamp >> 32) & 0xFFF)
        let k = Int((low &- UInt32(truncatingIfNeeded: patternSerial)) & 0xFFF)
        let lastPulse = Int(UInt32(truncatingIfNeeded: stamp))
        guard k >= 1, k < 0x800,
              let line = planLedger.line(stampPlan: plan),
              let step = line.steps[patternSerial + k] else { return false }
        let fromCurrentLine = line.id == planLedger.currentID
        let idx = step.pattern
        guard patterns.indices.contains(idx) else { return false }
        for td in currentPattern.tracks {
            if let vm = vmCache[td.id] {
                vm.lastFiredNotes.forEach { sendImmediateNoteOff(td, note: $0) }
                vm.lastFiredNotes = []
            }
        }
        cancelInteractionSession()   // die Lanes des alten Patterns verschwinden
        patternSerial += k
        // Eine Vormerkung, die erst nach dem Wechsel unter der alten Linie kam, bleibt stehen.
        if fromCurrentLine || queuedPatternIndex == idx { queuedPatternIndex = nil }
        currentPatternIndex = idx
        playbackDisplay.steps = Array(repeating: -1, count: patterns[idx].tracks.count)
        // Das abgelöste Pattern gibt seine Runtime-Slots ab, sofern es nicht im verbleibenden
        // Plan liegt: der Tick-Thread kann ihn schon weiter abspielen (Song, mehrere Wechsel
        // ohne Main) — dessen Slots und Epochen müssen bis zum nächsten Publish stehen bleiben.
        // Kehrt ein Pattern zurück, setzt der Tick-Thread seine Runtimes beim Wechsel zurück.
        var keep = Set(patterns[idx].tracks.map(\.id))
        for p in planLedger.plannedPatterns(after: patternSerial) where patterns.indices.contains(p) {
            keep.formUnion(patterns[p].tracks.map(\.id))
        }
        releaseUnusedSlots(keeping: keep)
        if let scene = step.scene {
            // Song: der letzte Wechsel lag auf `rtSwitchPulse` — dort beginnt der neue Lauf.
            songPlanner.beginRun(scene: scene, pulse: lastPulse)
            scheduleSongNext()
        }
        return true
    }

    // MARK: - Song (v1.14.0)

    /// Song-Start (Main, im Stop-Zustand oder bei externem Neustart, vor `beginRuntimeSession`):
    /// erstes Szenen-Pattern aktivieren, ersten Lauf ab Puls 0, nächsten Wechsel vormerken.
    private func beginSongIfActive() {
        clearSongSchedule()
        rtSongEnded.store(false, ordering: .releasing)
        guard song.isActive else { return }
        let first = song.scenes[0].pattern
        if patterns.indices.contains(first), first != currentPatternIndex { applyPatternSwitch(first) }
        songPlanner.beginRun(scene: 0, pulse: 0)
        scheduleSongNext()
    }

    /// Merkt aus dem laufenden Lauf den nächsten Wechsel (Pattern + absoluter Puls) oder das
    /// Songende vor. Publiziert nicht — der Aufrufer tut das (bzw. publishSnapshot baut danach).
    ///
    /// v1.15.1 (Codex H3): bis zu `songHorizon` Wechsel im Voraus, begrenzt durch die
    /// Runtime-Slots (jedes verschiedene Pattern im Plan belegt einen Slot je Spur). Der
    /// Tick-Thread geht den Plan allein durch; Main füllt beim Nachziehen auf.
    private func scheduleSongNext() {
        let perPattern = max(1, currentPattern.tracks.count)
        guard songPlanner.schedule(song: song, playing: currentPatternIndex, patternCount: patterns.count,
                                   maxDistinct: max(2, Self.runtimeSlotCount / perPattern),
                                   pulsesPerBar: { [patterns] p in
                                       patterns.indices.contains(p) ? patterns[p].timeSignature.pulsesPerBar : Song.pulsesPerBar
                                   }) else {
            clearSongSchedule(); return
        }
        songState.playingScene = songPlanner.runStart
        queuedPatternIndex = songPlanner.plan.first?.pattern
    }

    /// Hebt jede Song-Vormerkung auf (Stop, Song aus). Lässt `queuedPatternIndex` nur dann
    /// stehen, wenn er nicht vom Song stammt.
    private func clearSongSchedule() {
        if songNextScene != nil { queuedPatternIndex = nil }
        songPlanner.clear()
        if songState.playingScene != nil { songState.playingScene = nil }
    }

    /// Ersetzt den Song mit Undo. Läuft gerade ein Song, gilt die Änderung ab dem nächsten
    /// Wechsel (der laufende Lauf wird neu berechnet).
    func setSongUndoable(_ new: Song, actionName: String) {
        let old = song
        guard new != old else { return }
        applySong(new)
        guard let um = undoManager else { return }
        registerReversibleUndo(um: um, target: self, actionName: actionName,
                               forward:  { $0.applySong(new) },
                               backward: { $0.applySong(old) })
    }

    private func applySong(_ new: Song) {
        var s = new
        s.clamp(patternCount: patterns.count)
        songState.song = s
        hasUnsavedChanges = true
        if !isPlaying { armExternalStart(); return }
        guard songRunStart != nil else { return }
        reconcilePatternSwitch()
        if !song.isActive {
            clearSongSchedule()
        } else {
            songPlanner.clampRun(sceneCount: song.scenes.count)
            scheduleSongNext()
        }
        publishSnapshot()
    }

    // MARK: - Taktart je Pattern (v1.18.12, je Pattern seit v1.18.24)

    /// Taktart des aktuellen Patterns (Raster, Pad-Längen, Anzeige).
    var timeSignature: TimeSignature { transportState.timeSignature }
    var switchOnBar: Bool { transportState.switchOnBar }

    /// Taktart des aktuellen Patterns ändern, mit Undo. Läuft dieses Pattern gerade, wird sie
    /// vorgemerkt und gilt, sobald es nicht mehr läuft (Entscheidung E2) — so bleiben Taktraster
    /// und Pad-Längen eines laufenden Abschnitts zueinander passend (Codex KT-02).
    func setTimeSignatureUndoable(_ requested: TimeSignature, actionName: String) {
        requestMeter(requested.clamped, pattern: currentPatternIndex, actionName: actionName)
    }

    private func requestMeter(_ m: TimeSignature, pattern i: Int, actionName: String, publish: Bool = true) {
        guard patterns.indices.contains(i) else { return }
        if isPlaying, i == currentPatternIndex {
            pendingMeters[i] = m == patterns[i].timeSignature ? nil : m
            syncMeter()
            return
        }
        pendingMeters[i] = nil
        let old = patterns[i].timeSignature
        guard m != old else { syncMeter(); return }
        var pads: [(LaneData, old: Int, new: Int)] = []
        // Lange Steps jeder Spur (v1.18.29; vorher nur Pad-Spuren).
        for t in patterns[i].tracks where t.lane.stepGroup || (t.lane.isLongStep && t.lane.stepLengthDenominator == 1) {
            // „Gruppe" (v1.18.30): Ersatzlänge = erste Gruppe in der neuen Taktart.
            let n = t.lane.stepLengthNumerator
            let k = t.lane.stepGroup ? t.lane.groupSixteenths(m)[0] : old.convert(sixteenths: n, to: m)
            if k != n { pads.append((t.lane, n, k)) }
        }
        let pattern = patterns[i]
        applyMeter(m, to: pattern, pads: pads.map { ($0.0, $0.new) }, publish: publish)
        guard let um = undoManager else { return }
        // Identitätsgebunden an Pattern und Lanes; Undo/Redo folgen derselben Vormerkregel.
        registerReversibleUndo(um: um, target: self, actionName: actionName,
                               forward:  { $0.restoreMeter(m, of: pattern, pads: pads.map { ($0.0, $0.new) }, actionName: actionName) },
                               backward: { $0.restoreMeter(old, of: pattern, pads: pads.map { ($0.0, $0.old) }, actionName: actionName) })
    }

    private func restoreMeter(_ m: TimeSignature, of pattern: Pattern, pads: [(LaneData, Int)], actionName: String) {
        guard let i = patterns.firstIndex(where: { $0 === pattern }) else { return }
        if isPlaying, i == currentPatternIndex { pendingMeters[i] = m; syncMeter(); return }
        applyMeter(m, to: pattern, pads: pads)
    }

    private func applyMeter(_ m: TimeSignature, to pattern: Pattern, pads: [(LaneData, Int)], publish: Bool = true) {
        for (lane, n) in pads where lane.stepLengthNumerator != n {
            lane.stepLengthNumerator = n; lane.changed.send()
        }
        pattern.timeSignature = m
        hasUnsavedChanges = true
        syncMeter()
        if publish { publishSnapshot() }
    }

    /// Vorgemerkte Taktarten übernehmen, deren Pattern nicht mehr läuft (Main; aus
    /// `publishSnapshot` und Stop). Je Übernahme ein Undo-Schritt.
    private func applyPendingMeters() {
        guard !pendingMeters.isEmpty else { return }
        for (i, m) in pendingMeters where !isPlaying || i != currentPatternIndex {
            pendingMeters[i] = nil
            // Aus `publishSnapshot`: nicht selbst veröffentlichen, der Aufrufer baut danach.
            requestMeter(m, pattern: i, actionName: Str(UserDefaults.standard.string(forKey: "appLanguage") ?? "en").undoTimeSignature,
                         publish: false)
        }
    }

    /// Anzeige, Raster und Plug-in-Takt im Stillstand auf die Taktart des aktuellen Patterns.
    func syncMeter() {
        let m = currentPattern.timeSignature
        if transportState.timeSignature != m {
            objectWillChange.send()               // Taktart: Transportereignis (Raster, Pad-Längen)
            transportState.timeSignature = m
        }
        rack.hostSync.setMeter(m)
        let pending = pendingMeters[currentPatternIndex]
        if transportState.pendingTimeSignature != pending { transportState.pendingTimeSignature = pending }
    }

    /// Laden: Vormerkungen gehören zum abgelösten Projekt.
    func pendingMetersReset() {
        pendingMeters = [:]
        syncMeter()
        publishSnapshot()
    }

    /// Ohne Undo (Laden/Neu, Tests): alle Patterns auf `m`.
    func replaceTimeSignature(_ m: TimeSignature) {
        let m = m.clamped
        pendingMeters = [:]
        for p in patterns { p.timeSignature = m }
        syncMeter()
        publishSnapshot()
    }

    /// Patternwechsel ohne Song: nächster Taktstrich oder Ende Spur 1 (E3), mit Undo.
    func setSwitchOnBarUndoable(_ on: Bool, actionName: String) {
        let old = switchOnBar
        guard on != old else { return }
        replaceSwitchOnBar(on)
        hasUnsavedChanges = true
        guard let um = undoManager else { return }
        registerReversibleUndo(um: um, target: self, actionName: actionName,
                               forward: { $0.replaceSwitchOnBar(on) }, backward: { $0.replaceSwitchOnBar(old) })
    }

    func replaceSwitchOnBar(_ on: Bool) {
        guard on != transportState.switchOnBar else { return }
        transportState.switchOnBar = on
        publishSnapshot()
    }

    /// Ohne Undo (Laden/Neu): der Undo-Stapel wird dort ohnehin geleert.
    func replaceSong(_ new: Song) {
        var s = new
        s.clamp(patternCount: patterns.count)
        songState.song = s
        if !isPlaying { armExternalStart() }
    }

    /// Veröffentlicht einen neuen PlaybackStateBundle atomar — kein Lock, kein Blocking.
    /// Darf ausschließlich auf dem Main-Thread aufgerufen werden.
    ///
    /// RT-3 — Hazard-Pointer-Freigabe (v1.12.5):
    ///   1. Neue Box erzeugen und in `bundleCurrent` halten (Main-Thread-Ownership).
    ///   2. Rohen Pointer atomar publizieren (.releasing) — der Tick-Thread sieht
    ///      danach entweder den alten oder den neuen Pointer, beide leben.
    ///   3. Die abgelöste Box NUR freigeben, wenn der Tick-Thread sie laut Hazard
    ///      nicht gerade dereferenziert; sonst um einen Zyklus aufschieben
    ///      (`bundleDeferred`). So kann keine Box unter dem Tick-Thread wegsterben,
    ///      unabhängig von Tick-Dauer und Preemption.
    /// `bpmOverride`: für Aufrufe aus einem `$bpm`-Sink. @Published emittiert im willSet,
    /// `bpm` läse dort noch den alten Wert.
    func publishSnapshot(bpmOverride: Double? = nil) {
        #if DEBUG
        _s01PublishCount &+= 1
        #endif
        rack.hostSync.setIdleTempo(bpmOverride ?? bpm)   // Plug-ins sehen das Tempo auch im Stillstand
        // Ein bereits vollzogener Wechsel muss VOR dem Bauen übernommen sein — sonst trüge
        // der neue Bundle noch die alte Aktivierung.
        #if DEBUG
        // Test: simuliert einen Tick-Wechsel genau zwischen Abgleich und Veröffentlichung.
        if _skipReconcileOnce { _skipReconcileOnce = false } else { reconcilePatternSwitch() }
        #else
        reconcilePatternSwitch()
        #endif
        // Vorgemerkte Taktarten (E2), sobald ihr Pattern nicht mehr läuft; danach Anzeige/Raster.
        applyPendingMeters()
        syncMeter()
        rack.loops.setStretchTarget(bpm: bpmOverride ?? bpm, quartersPerBar: timeSignature.quartersPerBar)
        let snap   = buildPatternSnapshot(for: currentPattern, index: currentPatternIndex)
        var live   = Set(currentPattern.tracks.map(\.id))
        // Negative Spuroffsets brauchen Vorlauf (Codex T8): größten über alle Patterns führen.
        let reserve = min(TrackData.maxTimingOffset,
                          max(0, -(patterns.lazy.flatMap(\.tracks).map(\.timingOffset).min() ?? 0)))
        if reserve != negativeOffsetReserve {
            negativeOffsetReserve = reserve
            updateExtLookahead(refreshDevice: false)
        }
        var queued: PatternSnapshot?
        var later: [PlaybackStateBundle.PlanStep] = []
        var entries: [PlanEntry] = []
        if let q = queuedPatternIndex, patterns.indices.contains(q), q != currentPatternIndex {
            // Song: der ganze Plan (je Pattern ein Snapshot, Wiederholungen teilen ihn);
            // sonst nur die manuelle Vormerkung.
            var built: [Int: PatternSnapshot] = [currentPatternIndex: snap]
            func snapshot(_ p: Int) -> PatternSnapshot {
                if let s = built[p] { return s }
                let s = buildPatternSnapshot(for: patterns[p], index: p); built[p] = s
                live.formUnion(patterns[p].tracks.map(\.id))
                return s
            }
            queued = snapshot(q)
            if let first = songPlanner.plan.first, first.pattern == q {
                entries = songPlanner.plan.map { ($0.pattern, $0.scene, $0.pulse) }
                later = songPlanner.plan.dropFirst().map {
                    PlaybackStateBundle.PlanStep(snapshot: snapshot($0.pattern), switchAtPulse: $0.pulse)
                }
            } else {
                entries = [(q, nil, -1)]
            }
        }
        releaseUnusedSlots(keeping: live)
        let songQueued = queued != nil && songNextScene != nil
        // Plan-Linie: Fortschreibung, solange jeder schon geplante künftige Schritt gleich
        // bleibt; sonst neue Linie mit dem bisherigen Plan als Vorgänger.
        let steps = Dictionary(uniqueKeysWithValues: entries.enumerated().map { (patternSerial + $0.offset + 1, $0.element) })
        let previous = publisher.current?.bundle
        var prevID: UInt32 = 0, prevBase = 0, prevSteps: [PatternSnapshot] = []
        if planLedger.record(steps, serial: patternSerial),
           let prev = previous, prev.session == sessionCounter {
            prevID = prev.planID; prevBase = prev.serial; prevSteps = prev.plannedSnapshots
        }
        let bundle = PlaybackStateBundle(snapshot: snap, bpm: bpmOverride ?? bpm, swing: swing,
                                         meter: timeSignature, switchOnBar: switchOnBar,
                                         serial: patternSerial, queued: queued,
                                         switchAtPulse: songQueued ? songPlanner.switchAtPulse : -1,
                                         stopAtPulse: songPlanner.stopAtPulse, later: later,
                                         session: sessionCounter, planID: planLedger.currentID,
                                         prevPlanID: prevID, prevBase: prevBase, prevSteps: prevSteps,
                                         planEndPulse: songQueued ? songPlanner.planEndPulse : -1)
        let newBox = PlaybackBundleBox(bundle)

        publisher.publish(newBox)
    }


    // MARK: - Transport-Sink-Setup (Arch-Slice-19)

    /// Richtet Combine-Sinks für TransportState-Properties ein.
    /// Ersetzt die früheren @Published-didSet-Blöcke:
    ///   bpm.didSet:       ClockSource-Sync + publishSnapshot + hasUnsavedChanges
    ///   clockMode.didSet: ClockSource Start/Stop bei Modus-Wechsel
    ///
    /// isPlaying und currentPatternIndex werden zusätzlich an engine.objectWillChange
    /// weitergeleitet, damit VintageSequencerApp (CommandMenu) und MainView (ForEach
    /// über tracks) korrekt aktualisiert werden. BPM und clockMode werden bewusst NICHT
    /// weitergeleitet — das ist der Kern des Performance-Fixes.
    private func setupTransportSinks() {
        // bpm → ClockSource + Snapshot + Unsaved-Flag
        // KEIN Forwarding an engine.objectWillChange → StepGrid/StepButton re-rendert
        // nicht bei BPM-Änderung. Nur transportState.objectWillChange feuert.
        transportState.$bpm
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] newBPM in
                guard let self else { return }
                self.audioClock.bpm = newBPM
                if self.transportState.isPlaying { self.publishSnapshot(bpmOverride: newBPM) }
                // Die BPM-Schätzung aus der externen Clock ist keine Projektänderung.
                guard !self.applyingExternalBPMEstimate else { return }
                // Guard: @Published feuert objectWillChange auch bei true=true.
                // Nur beim ersten Wechsel false→true zuweisen, sonst engine.OWC-Flood
                // bei jedem BPM-Tick → StepGrid-Rebuilds trotz TransportState-Isolation.
                self.presetEditorState.markChanged()
            }
            .store(in: &cancellables)

        // clockMode → ClockSource Start/Stop bei Modus-Wechsel während Playback.
        // .removeDuplicates() = Äquivalent zum alten `guard oldValue != clockMode`.
        // KEIN Forwarding an engine.objectWillChange.
        transportState.$clockMode
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] newMode in
                guard let self else { return }
                guard self.transportState.isPlaying else { return }
                if newMode == .external {
                    // INT→EXT: ClockSource stoppen — externer Master übernimmt.
                    self.audioClock.stop()
                    self.extResetRequested.store(true, ordering: .releasing)   // BPM-Zähler + EMA
                } else {
                    // EXT→INT: ClockSource starten.
                    self.audioClock.bpm = self.transportState.bpm
                    self.audioClock.start()
                }
            }
            .store(in: &cancellables)

        // isPlaying → engine.objectWillChange forwarden.
        // Notwendig für VintageSequencerApp CommandMenu-Label-Update und allg. Konsistenz.
        // Play/Stop ist ein seltenes Ereignis — kein Performance-Problem.
        transportState.$isPlaying
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // currentPatternIndex → engine.objectWillChange forwarden.
        // Notwendig für MainView (ForEach über engine.currentPattern.tracks).
        // Pattern-Wechsel ist selten — kein Performance-Problem.
        transportState.$currentPatternIndex
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Slice C: recentFiles + clipboard → engine.objectWillChange forwarden.
        // VintageSequencerApp Commands lesen engine.recentFiles und engine.clipboard
        // in einem .commands {}-Kontext, der kein @EnvironmentObject unterstützt.
        // Um "Open Recent"-Menü und ".disabled(clipboard == nil)" reaktiv zu halten,
        // werden diese beiden Felder gezielt weitergeleitet. Sie ändern sich nur bei
        // expliziten Benutzeraktionen (Preset-Open/Save/Copy) — kein Performance-Problem.
        presetEditorState.$recentFiles
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        presetEditorState.$clipboard
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // RT-1: swing → Snapshot-Republish während Playback.
        // Swing liegt seit v1.12.2 im PlaybackStateBundle; der Tick-Thread liest
        // es nicht mehr direkt aus presetEditorState. Damit eine Swing-Änderung
        // wirkt, muss der Bundle neu publiziert werden.
        //
        // Bewusst über die snapshotPending-Koaleszierung (async) statt synchron:
        // @Published emittiert den neuen Wert im willSet, BEVOR das Backing-Feld
        // committet ist — ein synchrones publishSnapshot() läse hier noch den alten
        // swing. Der main.async-Hop garantiert den committeten Wert und koalesziert
        // zugleich schnelle Knob-Drags auf einen Publish pro RunLoop-Pass.
        // KEIN engine.objectWillChange; hasUnsavedChanges bleibt unberührt
        // (Save-Dirty-Handling ist nicht Teil dieses Slices).
        presetEditorState.$swing
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self, self.isPlaying, !self.snapshotPending else { return }
                self.snapshotPending = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.snapshotPending = false
                    guard self.isPlaying else { return }
                    self.publishSnapshot()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Transport-API für Views (Arch-Slice-19)

    /// Setzt BPM über TransportState — einziger von Views verwendeter Schreibpfad.
    /// Klemmt auf 20…300. Löst ClockSource-Sync und Snapshot-Update via Combine-Sink aus.
    func setBPM(_ value: Double) {
        bpm = value.clamped(to: 20...300)
    }

    /// Setzt ClockMode über TransportState — einziger von Views verwendeter Schreibpfad.
    func setClockMode(_ mode: ClockMode) {
        clockMode = mode
        updateExtLookahead()
        armExternalStart()
    }

    /// Bereitet im Stopp (EXT-Modus) die nächste Sitzung vor: Song-Beginn, frische Runtimes,
    /// Snapshot veröffentlicht. Danach genügt dem MIDI-Thread ein atomarer Schalter, um bei
    /// 0xFA/0xFB zu starten (Codex T1: Start/Continue gingen bisher über Main, ein 0xF8 vor
    /// der Startverarbeitung fiel aus). Erneut aufgerufen, wenn sich der Song-Beginn ändert.
    func armExternalStart() {
        extArmed.store(false, ordering: .releasing)
        guard clockMode == .external, !isPlaying, !stopCleanupPending,
              !extStartedRT.load(ordering: .acquiring) else { return }
        queuedPatternIndex = nil
        beginSongIfActive()
        beginRuntimeSession()
        noteOut.clear()
        playbackDisplay.steps = Array(repeating: -1, count: currentPattern.tracks.count)
        resetSnapshotAcquireDisplay()
        publishSnapshot()
        extResetRequested.store(true, ordering: .releasing)
        updateExtLookahead()
        extArmed.store(true, ordering: .releasing)
    }
    #if DEBUG
    var _extArmed: Bool { extArmed.load(ordering: .acquiring) }
    #endif

    /// Vorläufe beider Clock-Quellen (v1.15.2, Codex T3/R8/T8) aus Renderhorizont, Overshoot
    /// und negativen Spuroffsets:
    ///   - INT: die ClockSource ruft jeden Tick ein Intervall + 10 ms + ein Ausgabepuffer +
    ///     größter negativer Spuroffset vor seinem Zeitpunkt auf. Ändert nur den Aufrufzeitpunkt,
    ///     nie das Raster — keine Phasenänderung.
    ///   - EXT: Tick-Zeit = Paketzeit + ein Pulsintervall (Overshoot) + 10 ms + ein
    ///     Ausgabepuffer + größter negativer Spuroffset (v1.16.1, Codex V16-3). Konstante Phase
    ///     zum Master, solange Tempo, Gerät und Offsetreserve gleich bleiben; ändert sich eines
    ///     davon, wird der Vorlauf neu gesetzt (einmaliger Phasenschritt).
    ///   Zulässiger Spuroffset in beiden Modi: ±50 ms (`TrackData.maxTimingOffset`); er liegt
    ///   damit bei fristgerechten Ticks immer vor der Frist und wird nicht begrenzt.
    /// `refreshDevice`: Puffergröße neu abfragen (Gerätewechsel); sonst Zwischenwert.
    func updateExtLookahead(refreshDevice: Bool = true) {
        if refreshDevice || outputBufferSeconds == 0 {
            outputBufferSeconds = rack.outputBufferSeconds
        }
        let pulse = 60.0 / (max(20, bpm) * 24.0)
        // Auf volle ms aufgerundet: kleine Schwankungen der Tempo-Schätzung bewegen ihn nicht.
        // Routenlatenz (Codex T7): AU-Ereignisse gehen um sie früher in den Renderweg — der
        // Vorlauf muss sie mit abdecken.
        let route = rack.maxRouteLatency
        let ext = ((pulse + 0.010 + outputBufferSeconds + negativeOffsetReserve + route) * 1000).rounded(.up) / 1000
        extLookaheadMach.store(Self.nanosToMachTime(UInt64(ext * 1_000_000_000)), ordering: .relaxed)
        audioClock.extraLeadNs = (outputBufferSeconds + negativeOffsetReserve + route) * 1_000_000_000
    }
    /// Puffer des Ausgabegeräts in Sekunden (zwischengespeichert, Main).
    private var outputBufferSeconds: Double = 0
    /// Größter negativer Spuroffset des laufenden Projekts in Sekunden (≥ 0).
    private var negativeOffsetReserve: Double = 0

    // MARK: - Transport

    func play() {
        guard !isPlaying else { return }
        rack.diagnostics.event("play", ["bpm": bpm])
        // RT-3b: play() beginnt eine neue Sitzung und publiziert eine neue Box —
        // das darf nicht mit einem noch ausstehenden Deferred-Cleanup aus einem
        // vorherigen stop() überlappen (sonst reißt eine neue Session dieselbe
        // Race eine Ebene höher wieder auf). Extrem pathologisch (erfordert schon
        // einen > 150 ms hängenden Tick) — im Normalfall ein No-Op.
        if stopCleanupPending {
            guard awaitActiveTickQuiescence() else {
                #if DEBUG
                print("⚠️ RT-3b: play() abgelehnt — vorheriger stop()-Cleanup noch ausstehend")
                #endif
                return
            }
            teardownRTState()
            noteOut.sendPendingNoteOffs()
        }
        // Runtime und Snapshot aufbauen, bevor die Clock startet.
        // Song-Modus: erstes Szenen-Pattern aktivieren und den ersten Wechsel vormerken.
        beginSongIfActive()
        let trackCount           = currentPattern.tracks.count
        // Neue Sitzung: frische Slot-Epochen → jeder Track startet mit frischer Runtime.
        // Quieszent — die Clock läuft noch nicht, isPlayingRT ist false.
        beginRuntimeSession()
        noteOut.clear()
        // Arch-Slice-17: -1 statt 0 — kein vorzeitiges Highlight.
        // Mit 0 zeigte die UI Step 0 sofort beim play()-Aufruf.
        // Der erste echte Tick lieferte ebenfalls Step 0 → Drain erkannte
        // keine Änderung (0 == 0) → kein Re-Render → Step 0 blieb ~250 ms
        // statt ~125 ms sichtbar → visueller „Haken auf der 1".
        // Mit -1 trifft kein StepButton den Vergleich (steps[t] == i → -1 == 0 → false),
        // d.h. kurz kein Highlight. Erster echter Tick: -1 != 0 → Drain feuert
        // sofort → korrekter 125 ms-Rhythmus ab dem ersten Step.
        playbackDisplay.steps    = Array(repeating: -1, count: trackCount)
        #if DEBUG
        _stepTimingLast = 0   // Messung beim nächsten Playback-Start neu beginnen
        #endif
        resetSnapshotAcquireDisplay()   // S01: Fehleranzeige gilt je Sitzung
        // Snapshot publizieren bevor isPlaying = true, damit der erste Tick
        // sofort einen gültigen Bundle vorfindet.
        publishSnapshot()
        isPlaying = true
        displaySignal?.resume()       // D4: Signal nur während Playback aktiv.
        startOffWatchdog()
        if clockMode == .internal {
            // INT-Modus: ClockSource starten.
            // Arch-Slice-16b: 0xFA (MIDI Start) wird NICHT hier gesendet.
            // clockTick() sendet es auf dem Tick-Thread mit demselben Future-Timestamp
            // wie den ersten 0xF8 → Start und Clock kommen gleichzeitig beim Gerät an.
            audioClock.bpm = bpm
            updateExtLookahead()   // INT-Vorlauf: Ausgabepuffer + negative Offsets
            audioClock.start()
            midiStartPending.store(true, ordering: .releasing)
        } else {
            // EXT-Modus: Wir erzeugen keinen Clock → 0xFA sofort senden ist korrekt.
            midi.start()
        }
    }

    func stop() { stop(loopsEndAt: nil) }

    /// Songende erreicht (Tick-Thread spielt nichts mehr an). Den Abschluss aller Wege hat der
    /// Tick schon auf den geplanten Endpuls gelegt — Offs (MIDI und Instrumente), 0xFC,
    /// Loop-Fenster, Plug-in-Transport (v1.16.1/v1.17.6). Main ist nur Nachbereitung: zum
    /// Zeitpunkt des Endpulses Anzeige und Transportzustand anhalten, ohne Flush und ohne
    /// zweites 0xFC. Gilt nur für dieselbe Sitzung; Benutzer-Stop bleibt sofort.
    private func stopIfSongEnded(now: UInt64 = mach_absolute_time()) {
        if rtSongEnded.exchange(false, ordering: .acquiringAndReleasing), isPlaying {
            pendingSongStop = (rtSongEndHost.load(ordering: .relaxed), sessionCounter)
        }
        guard let pending = pendingSongStop, isPlaying, pending.session == sessionCounter else {
            pendingSongStop = nil; return
        }
        if now >= pending.host {
            pendingSongStop = nil
            stop(loopsEndAt: pending.host)
        } else if !songStopScheduled {
            songStopScheduled = true
            let wait = Double(Self.machToNanos(pending.host - now)) / 1_000_000_000
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self else { return }
                self.songStopScheduled = false
                self.stopIfSongEnded()
            }
        }
    }
    /// Erschöpften Song-Horizont und Planabweichungen melden (Diagnose-Ereignis).
    private func reportPlanDiagnostics() {
        let u = rtHorizonUnderruns.load(ordering: .relaxed), c = rtPlanConflicts.load(ordering: .relaxed)
        if u != reportedUnderruns || c != reportedConflicts {
            rack.diagnostics.event("songPlan", ["horizonUnderruns": u, "planConflicts": c])
            reportedUnderruns = u; reportedConflicts = c
        }
    }
    private var reportedUnderruns = 0, reportedConflicts = 0

    #if DEBUG
    func _stopIfSongEnded(now: UInt64 = mach_absolute_time()) { stopIfSongEnded(now: now) }
    var _pendingSongStopHost: UInt64? { pendingSongStop?.host }
    var _songEndStopCount: Int { kernel._songEndStopCount }
    var _clampCountNotes: Int { clampCountNotes.load(ordering: .relaxed) }
    #endif

    /// `loopsEndAt`: Host-Zeit, ab der Audio-Loops schweigen (Songende: der geplante Endpuls).
    /// nil = jetzt.
    private func stop(loopsEndAt: UInt64?) {
        guard isPlaying else { return }   // D4: idempotent — verhindert Double-Suspend des displaySignal.
        rack.diagnostics.event("stop")
        isPlaying = false
        displaySignal?.suspend()      // D4: Signal im Stop-Zustand pausieren.
        stopOffWatchdog()
        audioClock.stop()
        // Arch-Slice-16b: Pending-Start-Flag löschen — falls audioClock.start() fehlschlug
        // oder stop() vor dem ersten clockTick() kam.
        midiStartPending.store(false, ordering: .relaxed)

        // RT-3b — Fail-Safe Deferred Cleanup (Codex-Befund H3, Round
        // FOF-CX-2026-07-14-006). RT-3a bewies Quieszenz per activeTick, aber der
        // damalige Backstop führte den Teardown trotz activeTick == true aus — das
        // war H2 in anderer Form. Jetzt gilt hart: activeTick == true ⇒ nie
        // freigeben, auch nicht auf dem Timeout-Pfad. Erreicht der kurze Sync-Spin
        // seine Deadline, wird der Teardown verschoben statt gewaltsam durchgeführt.
        if awaitActiveTickQuiescence() {
            teardownRTState()
        } else {
            stopCleanupPending = true
            #if DEBUG
            print("⚠️ RT-3b: stop() Sync-Spin-Backstop erreicht — Cleanup deferred")
            #endif
            scheduleDeferredRTStateCleanup()
        }
        // Arch-Slice-19: -1 statt 0 — kein Step-Highlight im Stop-Zustand.
        // Voraussetzung für den engine.isPlaying-freien isCurrentStep in StepGridView:
        // da gültige Step-Indizes ≥ 0 sind, ist playbackDisplay.steps[t] == i immer
        // false wenn der Wert -1 ist — kein engine.isPlaying-Guard mehr nötig.
        // Ein vom Tick-Thread bereits vollzogener Patternwechsel wird noch übernommen,
        // damit die Anzeige das zuletzt gespielte Pattern zeigt.
        reconcilePatternSwitch()
        playbackDisplay.steps = Array(repeating: -1, count: currentPattern.tracks.count)
        // Ausstehende Future-Timestamp-Events aus der CoreMIDI-Queue löschen,
        // damit geplante Note-Offs nicht nach dem Stopp noch auslösen.
        // Songende (v1.16.1, Codex V16-1): Offs und 0xFC hat der Tick schon auf den Endpuls
        // geplant — kein Flush (er könnte genau diese Offs verwerfen), kein zweites 0xFC.
        if loopsEndAt == nil {
            midi.flushOutput()
            midi.stop()
        }
        // Der Flush hat auch geplante Note-Offs verworfen: jede Note, deren Off noch
        // aussteht, bekommt jetzt ein sofortiges Off (Notenbuch). Im Deferred-Pfad
        // läuft das erst nach bewiesener Quieszenz (scheduleDeferredRTStateCleanup).
        if !stopCleanupPending { noteOut.sendPendingNoteOffs() }
        clearSongSchedule()
        // Plug-in-Transport: Songende hat der Tick gesetzt; Benutzer-Stop wirkt nur auf die
        // laufende Sitzung (eine neuere bleibt unberührt).
        rack.transportStopped(at: loopsEndAt ?? mach_absolute_time(), session: sessionCounter)
        defer { armExternalStart() }   // nächster externer Start ohne Main-Umweg
        queuedPatternIndex  = nil
        extResetRequested.store(true, ordering: .releasing)   // EXT-Messzustand: MIDI-Thread setzt selbst zurück
        for td in currentPattern.tracks {
            if let vm = vmCache[td.id] {
                vm.lastFiredNotes.forEach { sendImmediateNoteOff(td, note: $0) }
                vm.lastFiredNotes = []
            }
            // Gehostete Instrumente hat sendPendingNoteOffs/silenceAll bereits beruhigt.
            if td.instrumentID == nil || rack.route(for: td.output) < 0 {
                midi.allNotesOff(channel: td.midiChannel)
            }
        }
        DispatchQueue.main.async { self.objectWillChange.send() }
    }

    // MARK: - RT-3b — Quieszenz-Warten + Fail-Safe Deferred Cleanup

    /// Bounded Sync-Spin — deckt den Normalfall ab (Tick < 1 ms), ohne die UI
    /// spürbar zu blockieren. 150 ms sind großzügig gegenüber jeder realistischen
    /// Tick-Dauer (auch unter TSan-Overhead), aber kurz genug, um „kein
    /// UI-Hänger" ernst zu nehmen. Anders als der frühere 2-s-Wert ist die genaue
    /// Dauer jetzt unkritisch für die Sicherheit: Der Fail-Safe-Pfad in stop()
    /// ist so oder so korrekt (Codex H3) — hier geht es nur um die Fast-Path-Grenze.
    private func awaitActiveTickQuiescence(timeoutNs: UInt64 = 150_000_000) -> Bool {
        let deadline = mach_absolute_time() + Self.nanosToMachTime(timeoutNs)
        while activeTick.load(ordering: .sequentiallyConsistent) {
            sched_yield()
            if mach_absolute_time() >= deadline { return false }
        }
        return true
    }

    /// Tatsächlicher RT-State-Teardown. Aufrufer MUSS activeTick == false bereits
    /// bewiesen haben (sync über awaitActiveTickQuiescence(), oder async über
    /// scheduleDeferredRTStateCleanup()). Den Hazard schreibt nie Main
    /// geschrieben — nur der Reader selbst löscht seinen eigenen Hazard; hier wird
    /// nur die Invariante geprüft.
    private func teardownRTState() {
        #if DEBUG
        // Ein Tick, der nach isPlayingRT = false eintritt, setzt activeTick nur kurz und
        // bricht in enterTick ab, ohne die Box zu berühren (Dekker-Paar). Dieses Fenster
        // abwarten, statt es als Verletzung zu melden (Falschalarm im Volllauf).
        assert(awaitActiveTickQuiescence(timeoutNs: 50_000_000),
               "RT-3b: Teardown nur nach bewiesener Quieszenz")
        assert(publisher.hazardIsClear,
               "RT-3b: Hazard sollte nach bewiesener Quieszenz bereits 0 sein")
        #endif
        publisher.teardown()
        // Die Runtime-Slots bleiben alloziert (Tick-Thread-Eigentum); die nächste Sitzung
        // vergibt neue Epochen und startet damit frisch.
        stopCleanupPending = false
    }

    // MARK: - Notenbuch

    // MARK: Ausgabe nach Ausgang (Tick-Pfad und quieszenter Main)
    //
    // route < 0  → CoreMIDI (gewählter Ausgang + virtuelle Quelle), Future-Timestamp.
    // route ≥ 0  → Warteschlange des gehosteten Instruments; dessen Render-Durchlauf
    //              rechnet denselben Zeitstempel in einen Sample-Offset um.
    // Beides ohne Heap und ohne Lock.

    //
    // Rückgabe (v1.13.13): true = übernommen oder mit Absicht verworfen (kein Instrument,
    // frühere Belegung); false = Warteschlange voll. CoreMIDI meldet keine Ablehnung.
    // `epoch`: Belegung des Slots, für die geplant wurde (`TrackSnapshot.routeEpoch`).


    /// Sofortiges Note-Off von Main an den Ausgang einer Spur (Spur entfernt,
    /// Patternwechsel, Stop).
    func sendImmediateNoteOff(_ td: TrackData, note: Int) {
        let route = rack.route(for: td.output)
        if route < 0 {
            midi.noteOff(channel: td.midiChannel, note: note)
        } else {
            rack.sendFromMain(route: route, UInt8(0x80 | (td.midiChannel - 1) & 0x0F), UInt8(note & 0x7F), 0)
        }
    }

    /// PANIC: beendet sofort alle klingenden Noten — gehostete Instrumente (geplante
    /// Ereignisse verworfen, All Notes Off) und externe MIDI-Ausgabe (All Notes Off auf
    /// allen 16 Kanälen). Die Wiedergabe läuft weiter; kommende Steps klingen wieder.
    func panic() {
        rack.silenceAll()
        for ch in 1...16 { midi.allNotesOff(channel: ch) }
    }

    /// Stellt den Ausgang einer Spur ein (nil = externe MIDI-Ausgabe), rücknehmbar, und
    /// hebt den gewählten Kanal im Mixer hervor.
    func setOutput(of td: TrackData, to channelID: UUID?) {
        if td.instrumentID != channelID {
            ModelWriter().apply(.setInstrument(trackID: td.id, old: td.instrumentID, new: channelID),
                                to: td, undoManager: undoManager)
        }
        rack.highlightedChannel = channelID
    }

    /// Legt einen Instrumentenkanal an und macht ihn zum Ausgang der Spur. nil, wenn das
    /// Rack voll ist. Undo nimmt nur die Zuweisung zurück; der Kanal bleibt bestehen.
    @discardableResult
    func setOutputToNewChannel(of td: TrackData, name: String) -> UUID? {
        guard let id = rack.addChannel(name: name) else { return nil }
        setOutput(of: td, to: id)
        return id
    }

    /// Kurzes Vorhören eines Tons am Ausgang der Spur (Klaviatur, Drum-Auswahl).
    func previewNote(_ note: Int, on td: TrackData, velocity: Int = 90, duration: Double = 0.35) {
        let route = rack.route(for: td.output)
        let epoch = rack.routeEpoch(for: td.output)   // Off nur an dieselbe Belegung
        let ch    = td.midiChannel
        if route < 0 {
            midi.noteOn(channel: ch, note: note, velocity: velocity)
        } else {
            rack.sendFromMain(route: route, UInt8(0x90 | (ch - 1) & 0x0F), UInt8(note & 0x7F), UInt8(velocity & 0x7F))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self else { return }
            // Das Off geht an den Ausgang, der das On bekam — und nur, solange dort noch
            // dieselbe Belegung sitzt (sonst träfe es ein anderes Instrument).
            if route < 0 {
                self.midi.noteOff(channel: ch, note: note)
            } else {
                self.rack.sendFromMain(route: route, epoch: epoch,
                                       UInt8(0x80 | (ch - 1) & 0x0F), UInt8(note & 0x7F), 0)
            }
        }
    }


    // MARK: - Off-Wächter (Main)
    //
    // Offs gehen mit dem Tick hinaus, in dessen Fenster sie fallen. Bleibt die externe Clock
    // ohne Stop-Nachricht aus (Kabel gezogen, Master abgestürzt), käme kein Tick mehr und
    // klingende Noten blieben hängen. Der Wächter prüft während der Wiedergabe alle 100 ms:
    // EXT-Modus, ungesendete Offs vorhanden, letzter Tick älter als 300 ms → er nimmt sich
    // den Tick-Zutritt (wie ein Tick; ein gleichzeitig eintreffender Puls würde abgewiesen)
    // und sendet die überfälligen Offs. Im INT-Modus tut er nichts — der Clock-Thread
    // läuft, solange gespielt wird. Kein Teil des Tick-Pfads.
    private static let offWatchdogStallMach = nanosToMachTime(300_000_000)

    private func startOffWatchdog() {
        offWatchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100),
                       leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            self?.flushOverdueOffsIfClockStalled(stallMach: Self.offWatchdogStallMach)
        }
        timer.resume()
        offWatchdog = timer
    }

    private func stopOffWatchdog() {
        offWatchdog?.cancel()
        offWatchdog = nil
    }

    private func flushOverdueOffsIfClockStalled(stallMach: UInt64) {
        guard !clockIsInternal.load(ordering: .acquiring),
              noteOut.hasPendingOffs.load(ordering: .relaxed) else { return }
        let now = mach_absolute_time()
        let last = lastExtTickHost.load(ordering: .relaxed)
        guard now >= last, now - last >= stallMach else { return }
        guard enterTick() else { return }
        defer { exitTick() }
        noteOut.flushDueNoteOffs(upTo: mach_absolute_time())
    }

    /// Fail-Safe-Pfad (Codex-Befund H3): Sync-Spin-Backstop in stop() erreicht,
    /// ein Tick lief noch. NICHT freigeben — stattdessen alle 20 ms auf Main
    /// erneut prüfen, bis activeTick wirklich false ist, dann teardownRTState().
    /// Rein Main-seitig (GCD-Retry, von DispatchQueue.main.asyncAfter serialisiert),
    /// kein RT-Pfad-Code, kein Busy-Loop.
    private func scheduleDeferredRTStateCleanup() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self, self.stopCleanupPending else { return }   // schon erledigt (z. B. via play())
            if self.activeTick.load(ordering: .sequentiallyConsistent) {
                self.scheduleDeferredRTStateCleanup()
            } else {
                self.teardownRTState()
                self.noteOut.sendPendingNoteOffs()
                self.armExternalStart()
            }
        }
    }

    /// Wechselt das Pattern quantisiert (an der Track-1-Grenze) oder sofort wenn gestoppt.
    ///
    /// Im Playback wird das Zielpattern vorgemerkt und fertig gebaut mitpubliziert
    /// (`PlaybackStateBundle.queued`). Der Tick-Thread wechselt an der Grenze selbst —
    /// der erste Step des neuen Patterns fällt auf denselben Tick, auf dem Step 1 des
    /// alten gelegen hätte. Main zieht Index und Anzeige nach (reconcilePatternSwitch).
    func switchPattern(_ idx: Int) {
        guard (0..<patterns.count).contains(idx) else { return }
        // Im laufenden Song bestimmt die Szenenfolge das Pattern.
        if isPlaying && songRunStart != nil { return }
        if isPlaying {
            reconcilePatternSwitch()
            // Das aktuelle Pattern erneut wählen hebt eine Vormerkung auf.
            queuedPatternIndex = (idx == currentPatternIndex) ? nil : idx
            publishSnapshot()
        } else {
            applyPatternSwitch(idx)
            armExternalStart()
        }
    }

    /// Sofortiger Wechsel im Stop-Zustand (Main).
    private func applyPatternSwitch(_ idx: Int) {
        for td in currentPattern.tracks {
            if let vm = vmCache[td.id] {
                vm.lastFiredNotes.forEach { sendImmediateNoteOff(td, note: $0) }
                vm.lastFiredNotes = []
            }
        }
        cancelInteractionSession()   // die Lanes des alten Patterns verschwinden
        currentPatternIndex = idx
        playbackDisplay.steps = Array(repeating: -1, count: patterns[idx].tracks.count)
    }

    /// MIDI Start/Continue vom externen Master (Main-Thread, via MIDIManager-Dispatch).
    private func startFromExternal(isContinue: Bool) {
        guard clockMode == .external else { return }
        // Vom MIDI-Thread bereits gestartete, vorbereitete Sitzung: nur noch nachziehen.
        if !isPlaying, extStartedRT.exchange(false, ordering: .acquiringAndReleasing) {
            isPlaying = true
            displaySignal?.resume()
            startOffWatchdog()
            return
        }
        extArmed.store(false, ordering: .releasing)
        if isPlaying {
            // Continue bei laufender Wiedergabe: nichts zu tun. Start bei laufender
            // Wiedergabe: von vorn beginnen — neue Sitzung, ohne den Transport-/Display-
            // Lebenszyklus (resume/suspend) ein zweites Mal zu durchlaufen.
            guard !isContinue else { return }
            queuedPatternIndex = nil
            beginSongIfActive()
            beginRuntimeSession()
            playbackDisplay.steps = Array(repeating: -1, count: currentPattern.tracks.count)
            publishSnapshot()
            extResetRequested.store(true, ordering: .releasing)
            return
        }
        // RT-3b: wie play() — nicht mit einem noch ausstehenden Deferred-Cleanup
        // aus einem vorherigen stop() überlappen (siehe dortiger Kommentar).
        if stopCleanupPending {
            guard awaitActiveTickQuiescence() else {
                #if DEBUG
                print("⚠️ RT-3b: startFromExternal() abgelehnt — vorheriger stop()-Cleanup noch ausstehend")
                #endif
                return
            }
            teardownRTState()
            noteOut.sendPendingNoteOffs()
        }
        extResetRequested.store(true, ordering: .releasing)   // sauberer Messbeginn
        updateExtLookahead()
        // Derselbe Sitzungsbeginn wie play() (Codex H4): Song ab Szene 1; die Taktanker setzt
        // der Tick-Thread mit der neuen Aktivierung selbst zurück.
        queuedPatternIndex = nil
        beginSongIfActive()
        beginRuntimeSession()
        noteOut.clear()
        playbackDisplay.steps = Array(repeating: -1, count: currentPattern.tracks.count)   // Arch-Slice-17
        resetSnapshotAcquireDisplay()   // S01: Fehleranzeige gilt je Sitzung
        publishSnapshot()
        isPlaying = true
        // Derselbe Display-Lebenszyklus wie play(): stop() suspendiert genau einmal.
        // (Früher fehlte das resume hier → nach EXT-Start blieb die Anzeige tot und
        // das folgende stop() suspendierte doppelt.)
        displaySignal?.resume()
        startOffWatchdog()
    }

    // MARK: - Tick (v1.16.0: eigener Besitzer `TickKernel`, Codex M6)
    //
    // Zutritt, Tick-eigener Zustand und `advanceSteps` liegen in `TickKernel`. Main nutzt den
    // Zutritt nur für den Off-Wächter und wartet in stop() auf `activeTick`.
    @inline(__always) private func enterTick() -> Bool { kernel.enterTick() }
    @inline(__always) private func exitTick() { kernel.exitTick() }
    /// Externer Clock-Puls (MIDI-Read-Thread).
    private func tick(scheduledAt: MIDITimeStamp) { kernel.tick(scheduledAt: scheduledAt) }

    /// Rückt einen TrackRuntime-Step weiter (Testschnittstelle `AdvanceRuntimeSource`).
    func advanceRuntime(_ runtime: inout TrackRuntime, snap: TrackSnapshot) -> Int {
        kernel.advanceRuntime(&runtime, snap: snap)
    }


    /// Anzahl der aktiven Halte-Steps direkt nach `index` (Vorwärtsrichtung, zyklisch,
    /// höchstens bis vor `index` selbst). Ein Halte-Step selbst hat Spanne 0.
    static func holdSpan(after index: Int, in steps: [Step], count: Int) -> Int {
        guard count > 1, steps.indices.contains(index), !(steps[index].isHold) else { return 0 }
        var span = 0
        var j = (index + 1) % count
        while j != index, steps[j].isActive, steps[j].isHold {
            span += 1
            j = (j + 1) % count
        }
        return span
    }

    // MARK: - Track management

    /// Liefert den kleinsten in `tracks` nicht benutzten Palettenindex.
    /// Ist die Palette voll ausgeschöpft, fällt die Vergabe zyklisch auf
    /// `tracks.count % palette` zurück (stabile, deterministische Zuordnung,
    /// keine Ausnahmesituation — Duplikate sind dann zwangsläufig).
    ///
    /// Track-Farben-Slice v1.12.0: neu hinzugefügte Tracks erhalten damit die
    /// nächste freie Farbe statt einer einfachen Count-Modulo-Zuweisung, die
    /// nach Löschungen zu vermeidbaren Dubletten geführt hätte.
    private func firstFreeColorIndex(in tracks: [TrackData]) -> Int {
        let palette = VintageTheme.trackColors.count
        let used = Set(tracks.map { ((($0.colorIndex % palette) + palette) % palette) })
        for i in 0..<palette where !used.contains(i) { return i }
        return tracks.count % palette
    }

    // MARK: - Track-Struktur (identitätsbasiert, v1.12.18)
    //
    // Strukturoperationen arbeiten mit `TrackPlacement` (Pattern + Track-Instanz +
    // Position) statt mit JSON-Kopien und einem gemeinsamen Index:
    //   - Undo/Redo setzt DIESELBE TrackData-Instanz wieder ein. Ältere Undo-Einträge,
    //     die auf deren LaneData/TrackData zielen (ModelWriter), bleiben gültig.
    //   - Jedes Pattern trägt seine eigene Position — Patterns mit unterschiedlicher
    //     Track-Zahl verrutschen nicht mehr gegeneinander.
    //   - Entfernen sucht per Identität (===), nie per gemerktem Index.
    //   - Ein Placement wirkt nur, solange sein Pattern noch Teil von `patterns` ist
    //     (nach Pattern-Paste/Load ist es wirkungslos statt falsch).

    /// Ein Track an seiner Position in genau einem Pattern.
    struct TrackPlacement {
        let pattern: Pattern
        let track:   TrackData
        let index:   Int
    }

    private func makeTrack(for pattern: Pattern, kind: LaneKind,
                           audioLoopChannel: UUID? = nil, row: UUID, strings s: Str) -> TrackData {
        // v1.9.1 (Slice A): monotoner Ordnungszähler statt count+1 —
        // verhindert doppelte „Track N"-Namen nach Löschungen.
        let n = pattern.nextTrackOrdinal
        pattern.nextTrackOrdinal += 1
        let lane = LaneData(stepCount: 16, kind: kind)
        let td = TrackData(name: audioLoopChannel != nil ? s.audioLoopTrackName(n)
                                 : s.trackName(n),
                           midiChannel: min(n, 16),
                           row: row,
                           colorIndex: firstFreeColorIndex(in: pattern.tracks),
                           lane: lane)
        if let ch = audioLoopChannel { td.output = .audioLoop(ch) }
        return td
    }

    /// Neue Audio-Loop-Spur in allen Patterns mit eigenem Audio-Loop-Kanal (v1.15.0). Der
    /// Kanal gehört der Zeile: alle Patterns spielen denselben Loop; Mute je Pattern.
    @discardableResult
    func addAudioLoopTrack() -> [TrackPlacement] {
        guard canGrowTracks else { return [] }
        let s = Str(UserDefaults.standard.string(forKey: "appLanguage") ?? "en")
        let n = currentPattern.nextTrackOrdinal
        guard let channel = rack.addAudioLoopChannel(name: s.audioLoopTrackName(n)) else { return [] }
        let row = UUID()
        let set = patterns.map { p in
            TrackPlacement(pattern: p, track: makeTrack(for: p, kind: .step, audioLoopChannel: channel,
                                                        row: row, strings: s),
                           index: p.tracks.count)
        }
        insertPlacements(set)
        return set
    }

    /// Mit Undo: Spuren UND der eigens angelegte Kanal werden gemeinsam entfernt bzw.
    /// wiederhergestellt (Codex M3) — Identität und Material bleiben im Undo-Eintrag erhalten.
    func addAudioLoopTrackUndoable(actionName: String) {
        let set = addAudioLoopTrack()
        guard let um = undoManager, let channel = set.first?.track.instrumentID else { return }
        final class Taken { var value: (data: InstrumentChannelData, index: Int, storage: AudioLoopStorage?)? }
        let taken = Taken()
        registerReversibleUndo(um: um, target: self, actionName: actionName,
                               forward: { e in
                                   if let t = taken.value {
                                       e.rack.putAudioLoopChannel(t.data, index: t.index, storage: t.storage)
                                       taken.value = nil
                                   }
                                   e.insertPlacements(set)
                               },
                               backward: { e in
                                   e.removePlacements(set)
                                   taken.value = e.rack.takeAudioLoopChannel(channel)
                               })
    }

    // MARK: Loop-Material als Dokumentbefehl (v1.15.2, Codex M2)
    //
    // Vertrag: Kanal-Einstellungen eines Loops (Länge, Eingang, Mithören, Gate, Ausgleich)
    // folgen dem Kanalvertrag wie Fader/Panorama — kein Dokument-Undo. Material-Operationen
    // (Löschen, letzten Durchlauf zurücknehmen) laufen über den Dokument-UndoManager und sind
    // versionsgebunden: Undo/Redo greift nur, solange der Kanal noch genau den Speicher trägt,
    // den der Befehl hinterlassen hat. Aufnahme selbst ist Transport, kein Dokumentbefehl.

    func clearAudioLoopUndoable(_ channel: UUID, actionName: String) {
        guard let old = rack.clearLoop(channel) else { return }
        registerLoopExchange(channel, before: old, after: nil, keepUndo: false, actionName: actionName)
    }

    func undoAudioLoopPassUndoable(_ channel: UUID, actionName: String) {
        guard let swap = rack.undoLoop(channel) else { return }
        registerLoopExchange(channel, before: swap.old, after: swap.new, keepUndo: true, actionName: actionName)
    }

    private func registerLoopExchange(_ channel: UUID, before: AudioLoopStorage?, after: AudioLoopStorage?,
                                      keepUndo: Bool, actionName: String) {
        hasUnsavedChanges = true
        guard let um = undoManager else { return }
        registerReversibleUndo(um: um, target: self, actionName: actionName,
                               forward: { e in e.rack.exchangeLoop(channel, expected: before, with: after, keepUndo: keepUndo) },
                               backward: { e in e.rack.exchangeLoop(channel, expected: after, with: before, keepUndo: keepUndo) })
    }

    /// Audio-Loop-Spur scharf schalten bzw. Aufnahme beenden (Klick oder Taste R). Ohne
    /// Angabe: die zuletzt bediente Audio-Loop-Spur, sonst die erste im aktuellen Pattern.
    func toggleAudioLoopRecording(_ td: TrackData? = nil) {
        guard let track = td ?? lastAudioLoopTrack.flatMap({ id in currentPattern.tracks.first { $0.id == id } })
                ?? currentPattern.tracks.first(where: { $0.isAudioLoop }),
              let ch = track.instrumentID, let core = rack.loopCore(for: ch) else { return }
        lastAudioLoopTrack = track.id
        let active = core.isRecordRequested || core.state == .recording
        rack.setLoopRecording(!active, for: ch, bpm: bpm, quartersPerBar: timeSignature.quartersPerBar)
    }


    /// Hängt in allen Patterns einen neuen leeren Track an.
    @discardableResult
    func addTrack(kind: LaneKind = .step) -> [TrackPlacement] {
        guard canGrowTracks else { return [] }
        let s = Str(UserDefaults.standard.string(forKey: "appLanguage") ?? "en")
        let row = UUID()
        let set = patterns.map { p in
            TrackPlacement(pattern: p, track: makeTrack(for: p, kind: kind, row: row, strings: s),
                           index: p.tracks.count)
        }
        insertPlacements(set)
        return set
    }

    /// Neue leere Spur direkt nach der Zeile der Spur `index` (aktuelles Pattern), in allen
    /// Patterns; ein Pattern ohne diese Zeile bekommt sie an derselben Nummer.
    @discardableResult
    func insertTrack(after index: Int, kind: LaneKind = .step) -> [TrackPlacement] {
        guard canGrowTracks else { return [] }
        let s = Str(UserDefaults.standard.string(forKey: "appLanguage") ?? "en")
        let anchor = currentPattern.tracks.indices.contains(index) ? currentPattern.tracks[index].row : nil
        let row = UUID()
        let set = patterns.map { p in
            let at = anchor.flatMap { a in p.tracks.firstIndex { $0.row == a } }.map { $0 + 1 }
                ?? min(index + 1, p.tracks.count)
            return TrackPlacement(pattern: p, track: makeTrack(for: p, kind: kind, row: row, strings: s),
                                  index: at)
        }
        insertPlacements(set)
        return set
    }

    /// Dupliziert die Zeile der Spur `index` (aktuelles Pattern) in allen Patterns, die sie
    /// haben; die Kopien bilden eine neue Zeile direkt darunter.
    @discardableResult
    func duplicateTrack(at index: Int) -> [TrackPlacement] {
        guard canGrowTracks, let row = row(at: index) else { return [] }
        let newRow = UUID()
        let set = patterns.compactMap { p -> TrackPlacement? in
            guard let i = p.tracks.firstIndex(where: { $0.row == row }) else { return nil }
            let copy = p.tracks[i].freshCopy()
            copy.row = newRow
            copy.name = p.tracks[i].name + " 2"
            return TrackPlacement(pattern: p, track: copy, index: i + 1)
        }
        insertPlacements(set)
        return set
    }

    /// Entfernt die Zeile der Spur `index` (aktuelles Pattern) aus allen Patterns, die sie
    /// haben und danach nicht leer wären. Rückgabe: die entfernten Instanzen samt Position.
    @discardableResult
    func removeTrack(at index: Int) -> [TrackPlacement] {
        guard currentPattern.tracks.count > 1, let row = row(at: index) else { return [] }
        let set = patterns.compactMap { p -> TrackPlacement? in
            guard p.tracks.count > 1, let i = p.tracks.firstIndex(where: { $0.row == row }) else { return nil }
            return TrackPlacement(pattern: p, track: p.tracks[i], index: i)
        }
        removePlacements(set)
        return set
    }

    /// Setzt Tracks an ihrer Position ein (Add/Insert/Duplicate und Undo von Remove).
    func insertPlacements(_ set: [TrackPlacement]) {
        var currentIdx: Int?
        withStructureTransaction {
            for p in set where patterns.contains(where: { $0 === p.pattern }) {
                guard !p.pattern.tracks.contains(where: { $0 === p.track }) else { continue }
                let at = max(0, min(p.index, p.pattern.tracks.count))
                p.pattern.tracks.insert(p.track, at: at)
                if p.pattern === currentPattern { currentIdx = at }
            }
        }
        structureDidChange(affectsCurrentPattern: currentIdx != nil)
    }

    /// Entfernt Tracks per Identität (Remove und Undo von Add/Insert/Duplicate).
    func removePlacements(_ set: [TrackPlacement]) {
        var currentIdx: Int?
        withStructureTransaction {
            for p in set where patterns.contains(where: { $0 === p.pattern }) {
                guard p.pattern.tracks.count > 1,
                      let at = p.pattern.tracks.firstIndex(where: { $0 === p.track }) else { continue }
                if let vm = vmCache[p.track.id] {
                    vm.lastFiredNotes.forEach { sendImmediateNoteOff(p.track, note: $0) }
                    vm.lastFiredNotes = []
                }
                p.pattern.tracks.remove(at: at)
                if p.pattern === currentPattern { currentIdx = at }
            }
        }
        pruneVMCache(keeping: Set(patterns.flatMap { $0.tracks.map(\.id) }))
        structureDidChange(affectsCurrentPattern: currentIdx != nil)
    }

    /// Zeile der Spur `index` im aktuellen Pattern.
    func row(at index: Int) -> UUID? {
        currentPattern.tracks.indices.contains(index) ? currentPattern.tracks[index].row : nil
    }

    /// Alle Spuren einer Zeile über alle Patterns.
    func tracks(inRow row: UUID) -> [TrackData] {
        patterns.compactMap { p in p.tracks.first { $0.row == row } }
    }

    /// Sucht eine Spur per UUID über alle Patterns.
    func track(withID id: UUID) -> TrackData? {
        for p in patterns { if let t = p.tracks.first(where: { $0.id == id }) { return t } }
        return nil
    }

    /// Bricht eine laufende Drag-Session ab, wenn sich das Modell unter ihr ändert
    /// (Struktur, Patternwechsel, Load/New). Siehe InteractionController.cancelActiveSession.
    func cancelInteractionSession() {
        interactionController.cancelActiveSession(resolveTrack: { [unowned self] in self.track(withID: $0) })
    }

    /// Gemeinsamer Abschluss jeder Strukturmutation (Main).
    ///
    /// Im Playback genügt der neue Snapshot: er trägt die Runtime-Bindung jedes Tracks
    /// (Slot + Epoche). Bestehende Tracks behalten ihren Cursor, neue starten frisch,
    /// entfernte geben ihren Slot frei — ohne Mailbox und ohne Versatz zum Snapshot.
    private func structureDidChange(affectsCurrentPattern: Bool) {
        cancelInteractionSession()
        hasUnsavedChanges = true
        // Positionsbasiertes Learn-Ziel ist nach einer Strukturänderung nicht mehr belastbar.
        learnTarget = nil
        // MainView-ForEach rendert nur bei engine.objectWillChange (Pattern.tracks ist
        // @Published auf Pattern, nicht auf der Engine).
        objectWillChange.send()
        guard isPlaying else { return }
        // playbackDisplay.steps ist Main-owned (nur UI-Leser).
        if affectsCurrentPattern {
            playbackDisplay.steps = Array(repeating: -1, count: currentPattern.tracks.count)
        }
        publishSnapshot()
    }

    // MARK: Undo-fähige Strukturoperationen (einziger Aufrufweg aus Views)

    private func registerStructureUndo(_ set: [TrackPlacement], inserted: Bool, actionName: String) {
        guard let um = undoManager, !set.isEmpty else { return }
        let insert: (SequencerEngine) -> Void = { $0.insertPlacements(set) }
        let remove: (SequencerEngine) -> Void = { $0.removePlacements(set) }
        registerReversibleUndo(um: um, target: self, actionName: actionName,
                               forward:  inserted ? insert : remove,
                               backward: inserted ? remove : insert)
    }

    func addTrackUndoable(kind: LaneKind, actionName: String) {
        registerStructureUndo(addTrack(kind: kind), inserted: true, actionName: actionName)
    }
    func insertTrackUndoable(after index: Int, kind: LaneKind, actionName: String) {
        registerStructureUndo(insertTrack(after: index, kind: kind), inserted: true,
                              actionName: actionName)
    }
    func duplicateTrackUndoable(at index: Int, actionName: String) {
        registerStructureUndo(duplicateTrack(at: index), inserted: true, actionName: actionName)
    }
    func removeTrackUndoable(at index: Int, actionName: String) {
        registerStructureUndo(removeTrack(at: index), inserted: false, actionName: actionName)
    }

    // MARK: Strukturtransaktion (v1.17.7, Codex A17-07)

    /// Tiefe laufender Strukturtransaktionen; währenddessen bauen die `$tracks`-Senken die
    /// Abos nicht je Pattern neu auf, sondern einmal am Ende.
    private var structureTransactionDepth = 0
    private var structureRebuildPending = false

    /// Führt mehrere Strukturänderungen aus und baut die Abos danach genau einmal neu auf.
    private func withStructureTransaction(_ body: () -> Void) {
        structureTransactionDepth += 1
        body()
        structureTransactionDepth -= 1
        guard structureTransactionDepth == 0, structureRebuildPending else { return }
        structureRebuildPending = false
        rebuildAllTrackSubs(for: patterns)
    }

    #if DEBUG
    /// Tests: Abo-Neuaufbauten seit Erzeugung.
    private(set) var _subscriptionRebuilds = 0
    #endif

    // MARK: Zeilen verschieben und einklappen (v1.17.3, Identität v1.17.7)

    /// Reihenfolge der Spuren eines Patterns (Instanzen). Verschieben wird als Vorher/Nachher
    /// je Pattern erfasst und identitätsgebunden angewendet; Undo setzt den Vorher-Stand
    /// ein — exakt invers, auch bei unterschiedlich langen Patterns (Codex A17-05).
    struct TrackOrder {
        let pattern: Pattern
        let tracks: [TrackData]
    }

    /// Setzt die Reihenfolgen in einer Transaktion (nur Patterns des Dokuments).
    func applyTrackOrders(_ orders: [TrackOrder]) {
        withStructureTransaction {
            for o in orders where patterns.contains(where: { $0 === o.pattern })
                && !o.pattern.tracks.elementsEqual(o.tracks, by: ===) {
                o.pattern.tracks = o.tracks
            }
        }
        structureDidChange(affectsCurrentPattern: true)
    }

    /// Vorher/Nachher für „Spur `from` nach `to`" (Nummern im aktuellen Pattern), über die
    /// Zeile (v1.18.6): in jedem Pattern, das die Zeile hat, kommt sie vor die erste Zeile, die
    /// im aktuellen Pattern nach dem Verschieben unter ihr liegt und dort vorkommt — sonst
    /// ans Ende. Andere Patterns bleiben unberührt. nil = keine Bewegung.
    /// Hinweis: die neue Zeile 0 bestimmt die Länge eines Patterns ohne Song.
    func trackMovePlan(from: Int, to: Int) -> (before: [TrackOrder], after: [TrackOrder])? {
        let n = currentPattern.tracks.count
        guard from != to, from >= 0, from < n, to >= 0, to < n else { return nil }
        var order = currentPattern.tracks.map(\.row)
        let row = order.remove(at: from)
        order.insert(row, at: to)
        let below = Array(order[(to + 1)...])
        var before: [TrackOrder] = [], after: [TrackOrder] = []
        for p in patterns {
            guard let i = p.tracks.firstIndex(where: { $0.row == row }) else { continue }
            var t = p.tracks
            let moved = t.remove(at: i)
            let at = below.lazy.compactMap { r in t.firstIndex { $0.row == r } }.first ?? t.count
            t.insert(moved, at: at)
            guard !t.elementsEqual(p.tracks, by: ===) else { continue }
            before.append(TrackOrder(pattern: p, tracks: p.tracks))
            after.append(TrackOrder(pattern: p, tracks: t))
        }
        return (before, after)
    }

    /// Verschieben ohne Undo (Tests, interne Aufrufer).
    @discardableResult
    func moveTrack(from: Int, to: Int) -> Bool {
        guard let plan = trackMovePlan(from: from, to: to) else { return false }
        applyTrackOrders(plan.after)
        return true
    }

    func moveTrackUndoable(from: Int, to: Int, actionName: String) {
        guard let plan = trackMovePlan(from: from, to: to) else { return }
        applyTrackOrders(plan.after)
        guard let um = undoManager else { return }
        let before = plan.before, after = plan.after
        registerReversibleUndo(um: um, target: self, actionName: actionName,
                               forward:  { $0.applyTrackOrders(after) },
                               backward: { $0.applyTrackOrders(before) })
    }

    /// Verschiebt die Spur mit `id` (aktuelles Pattern) an die Position von `targetID`.
    func moveTrackUndoable(id: UUID, onto targetID: UUID, actionName: String) {
        guard let from = currentPattern.tracks.firstIndex(where: { $0.id == id }),
              let to = currentPattern.tracks.firstIndex(where: { $0.id == targetID }) else { return }
        moveTrackUndoable(from: from, to: to, actionName: actionName)
    }

    /// Zielzeile, wenn die Zeile `from` in die Lücke `gap` kommt (0 = über der ersten Zeile,
    /// `count` = unter der letzten); nil, wenn sich nichts bewegt.
    static func moveDestination(from: Int, gap: Int, count: Int) -> Int? {
        guard from >= 0, from < count, gap >= 0, gap <= count else { return nil }
        let to = gap > from ? gap - 1 : gap
        return to == from ? nil : to
    }

    /// Ziehen im Spurkopf: die Spur `id` kommt in die Lücke `gap`.
    func moveTrackUndoable(id: UUID, toGap gap: Int, actionName: String) {
        guard let from = currentPattern.tracks.firstIndex(where: { $0.id == id }),
              let to = Self.moveDestination(from: from, gap: gap, count: currentPattern.tracks.count)
        else { return }
        moveTrackUndoable(from: from, to: to, actionName: actionName)
    }

    /// Ein- oder Ausklappen einer Spur-Instanz (Ansicht, kein Playback-Snapshot, A17-08).
    struct CollapseChange {
        let track: TrackData
        let collapsed: Bool
    }

    /// Setzt die Ansichtszustände je Instanz. Nur Ansichtssignal (`viewChanged`) — die
    /// Senken der Engine (Snapshot bei Playback) reagieren darauf nicht.
    func applyCollapse(_ changes: [CollapseChange]) {
        for c in changes where c.track.isCollapsed != c.collapsed {
            c.track.isCollapsed = c.collapsed
            c.track.viewChanged.send()
        }
        hasUnsavedChanges = true       // Teil des Presets
    }

    /// Klappt die Zeile der Spur `index` ein oder aus — in allen Patterns (ohne Undo).
    func setTrackCollapsed(at index: Int, _ collapsed: Bool) {
        guard let row = row(at: index) else { return }
        applyCollapse(tracks(inRow: row).map { CollapseChange(track: $0, collapsed: collapsed) })
    }

    /// Mit Undo: der alte Zustand jeder betroffenen Instanz wird gemerkt (Codex A17-06).
    func setTrackCollapsedUndoable(at index: Int, _ collapsed: Bool, actionName: String) {
        guard index >= 0, index < currentPattern.tracks.count,
              currentPattern.tracks[index].isCollapsed != collapsed else { return }
        let tracks = tracks(inRow: currentPattern.tracks[index].row)
        let before = tracks.map { CollapseChange(track: $0, collapsed: $0.isCollapsed) }
        let after = tracks.map { CollapseChange(track: $0, collapsed: collapsed) }
        applyCollapse(after)
        guard let um = undoManager else { return }
        registerReversibleUndo(um: um, target: self, actionName: actionName,
                               forward:  { $0.applyCollapse(after) },
                               backward: { $0.applyCollapse(before) })
    }

    /// Ersetzt das Pattern bei `idx` (Pattern-Paste und dessen Undo). Die abgelöste
    /// Pattern-Instanz bleibt im Undo-Eintrag am Leben und wird beim Undo unverändert
    /// wieder eingesetzt.
    func setPattern(at idx: Int, to new: Pattern) {
        guard patterns.indices.contains(idx), patterns[idx] !== new else { return }
        cancelInteractionSession()
        for td in patterns[idx].tracks {
            if let vm = vmCache[td.id] {
                vm.lastFiredNotes.forEach { sendImmediateNoteOff(td, note: $0) }
                vm.lastFiredNotes = []
            }
        }
        patterns[idx] = new   // $patterns → rebuildAllTrackSubs (emittierter Wert)
        pruneVMCache(keeping: Set(patterns.flatMap { $0.tracks.map(\.id) }))
        hasUnsavedChanges = true
        learnTarget = nil
        guard isPlaying else { return }
        // Die Tracks des neuen Patterns haben eigene Identitäten → eigene Slots/Epochen,
        // der Tick-Thread startet sie frisch. (Betrifft auch ein vorgemerktes Pattern.)
        if idx == currentPatternIndex {
            playbackDisplay.steps = Array(repeating: -1, count: new.tracks.count)
        }
        publishSnapshot()
    }

    func replacePatternUndoable(at idx: Int, with new: Pattern, actionName: String) {
        guard patterns.indices.contains(idx) else { return }
        let old = patterns[idx]
        setPattern(at: idx, to: new)
        guard let um = undoManager else { return }
        registerReversibleUndo(um: um, target: self, actionName: actionName,
                               forward:  { $0.setPattern(at: idx, to: new) },
                               backward: { $0.setPattern(at: idx, to: old) })
    }

    // Note Preview state — methods → SequencerEngine+MIDILearn.swift.
    var previewChannel: Int  = 1
    var previewRoute:   Int  = -1
    var previewEpoch:   UInt32 = 0
    var previewNotes:  [Int] = []

    // MARK: - Preset I/O + Clipboard
    // Stored properties; all methods → SequencerEngine+PresetIO.swift.
    // Serialization, file panels, and bookmark logic → PresetManager.swift.

    /// Handles encode/decode, file panels, and recent-files bookmark management.
    let presetManager = PresetManager()   // internal: zugänglich für Extensions in anderen Dateien (E1b)

    // currentPresetURL, hasUnsavedChanges, recentFiles, clipboard, stepClipboard —
    // delegiert an presetEditorState (Pre-Lane Slice C). Computed-Property-Accessors
    // stehen weiter oben in der Klassendefinition.
}

// MARK: - AdvanceRuntimeSource

extension SequencerEngine: AdvanceRuntimeSource {
    // advanceRuntime(_:snap:) ist in der Hauptklasse implementiert (MARK: Step sequencing).
    // Die Protocol-Konformität macht die Funktion für Tests erreichbar
    // (@testable import VintageSequencer) und dokumentiert die testbare
    // Schnittstelle formal. Kein Behavior-Change — der Produktionspfad
    // in advanceSteps() ruft weiterhin self.advanceRuntime(...) direkt auf.
}

// MARK: - Interner Clock-Tick

extension SequencerEngine {
    /// Ein 24-PPQ-Tick der ClockSource (Clock-Thread). Ausführung: `TickKernel.clockTick`.
    func clockTick(at timestamp: MIDITimeStamp) { kernel.clockTick(at: timestamp) }
}
