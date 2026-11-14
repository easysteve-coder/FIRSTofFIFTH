import Foundation
import Combine
import AppKit
import CoreMIDI
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
        set { transportState.bpm = newValue }
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
        set { transportState.currentPatternIndex = newValue }
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

    @Published var patterns: [Pattern] = ["A","B","C","D"].map { Pattern(name: $0) }
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

    var midi = MIDIManager()

    // Externe Clock: BPM-Schätzung aus Pulsabstand.
    // Nur vom MIDI-Read-Thread geschrieben — kein Sharing, kein Lock nötig.
    private var extPulseCount:  Int    = 0
    private var extBeatStart:   UInt64 = 0

    // Externe Clock: prädiktiver Lookahead (T2 — Schritt 2).
    // EMA über gemessene Tick-Intervalle → scheduledAt = now + EMA statt now.
    // Ermöglicht CoreMIDI Future-Timestamps und macht den Overshoot-Fix auch
    // im EXT-Modus wirksam. Nur vom MIDI-Read-Thread gelesen/geschrieben.
    private var extLastTickMach:    UInt64 = 0
    private var extTickIntervalEMA: Double = 0.0
    private let extEMAAlpha:        Double = 0.2
    /// Main bittet den MIDI-Read-Thread, seinen Messzustand (Pulszähler, EMA) zurückzusetzen.
    /// Die Variablen oben schreibt ausschließlich der MIDI-Read-Thread — Main setzt nur
    /// dieses Flag (früher schrieb Main sie direkt: Datenrennen).
    private let extResetRequested = ManagedAtomic<Bool>(false)

    // MARK: - Playback Snapshot (E3 — Lock-Free Atomic Exchange, RT-3 — Hazard-Pointer, S01)
    //
    // Main-Thread publiziert einen neuen PlaybackBundleBox-Pointer atomar.
    // Der Tick-Thread erwirbt ihn über `acquireSnapshot()` (Hazard-Pointer-Protokoll).
    //
    // Lifetime-Garantie (Single-Reader-Hazard-Pointer, RT-3 v1.12.5, S01 v1.12.11):
    //   Der Tick-Thread hält den rohen Box-Pointer über den GESAMTEN Tick
    //   (advanceSteps liest bundle.snapshot/bpm/swing durch die ganze Track-Schleife).
    //
    //   Protokoll (Annahme: genau EIN Reader — Durchsetzung ist Slice S02, B2):
    //     Reader  R1  c = load(atomicBundleRaw)                       [acquiring]
    //             R2  store(hazardBundleRaw, c)                       [seq_cst]
    //             R3  v = load(atomicBundleRaw)                       [seq_cst]
    //             R4  v == c  → c ist geschützt, erst JETZT Dereferenzierung;
    //                 v != c  → c = v, zurück zu R2 (höchstens `snapshotAcquireMaxAttempts`
    //                           Durchläufe; danach Erwerbsfehler, KEINE Dereferenzierung).
    //             R5  Tick-Ende: store(hazardBundleRaw, 0)            [releasing]
    //     Writer  W1  store(atomicBundleRaw, new)                     [seq_cst]
    //             W2  h = load(hazardBundleRaw)                       [seq_cst]
    //             W3  abgelöste Box nur freigeben, wenn rawOf(box) != h; sonst `bundleDeferred`.
    //
    //   Ordnungsbeweis (Dekker/Store-Buffering): R2→R3 und W1→W2 sind je ein
    //   „store, dann load auf der ANDEREN Variable“. Release/Acquire erlaubt, dass
    //   beide Loads die alten Werte sehen (Reader sieht den alten Pointer, Writer
    //   sieht Hazard 0) → Writer gibt die Box frei, die der Reader gerade benutzt.
    //   Mit seq_cst auf allen vier Operationen liegen sie in einer totalen Ordnung S:
    //   steht R2 vor W1, sieht W2 (nach W1) den Hazard → Aufschub; steht W1 vor R2,
    //   sieht R3 (nach R2) den neuen Pointer → Validierung scheitert, keine
    //   Dereferenzierung. Auf ARM64 sind seq_cst-Store/Load stlr/ldar (RCsc, ohne
    //   zusätzliche dmb); die Loads bleiben wartefrei. Sichtbarkeit des Box-Inhalts:
    //   R3 (acquire-Anteil) liest den Wert aus W1 (release-Anteil) → happens-before
    //   für die Initialisierung der Box. R5 (release) ordnet alle Reads der Box vor
    //   das Löschen; W2 (acquire-Anteil) das Freigeben nach dem Lesen von R5.
    //
    //   ABA: Der Reader dereferenziert nie den bei R1 gelesenen Wert, sondern nur
    //   das Objekt, das bei R3 ZUM VALIDIERUNGSZEITPUNKT publiziert ist. Eine
    //   Wiederverwendung der Adresse durch eine neue Box ist deshalb harmlos: Passt
    //   die Adresse zur aktuellen Publikation, ist genau diese lebende Box gemeint.
    //   Auf Writer-Seite führt eine zufällig gleiche Adresse höchstens zu einem
    //   überflüssigen Aufschub (konservativ). Eine aufgeschobene Box bleibt über
    //   `bundleDeferred` am Leben, ihre Adresse kann nicht neu vergeben werden.
    //
    //   Deferred-Retention: höchstens EINE Box (nur ein Reader hat höchstens einen
    //   Hazard). Sie wird beim nächsten publishSnapshot() freigegeben, sobald der
    //   Hazard nicht mehr auf sie zeigt. Freigabe/Deinit laufen auf dem Publisher
    //   (Main), nie auf dem Tick-Thread: der Reader hält keine Referenz (+0).
    //
    //   Beschränkte RT-Arbeit pro Erwerb: 1 Load + höchstens 9×(1 Store + 1 Load)
    //   + 1 Clear; kein Lock, kein Alloc, kein Retain/Release, keine Schleife ohne
    //   Obergrenze. Erschöpfung (≥ 9 Pointerwechsel während des Erwerbs) ist ein
    //   definierter Erwerbsfehler: der Gesamttick wird abgebrochen (siehe advanceSteps).
    //
    private let atomicBundleRaw = ManagedAtomic<Int>(0)
    /// RT-3: Box, die der Tick-Thread gerade dereferenziert (0 = keine). Vom
    /// Tick-Thread mit .releasing geschrieben, vom Main-Thread in publishSnapshot
    /// mit .acquiring gelesen, bevor er eine abgelöste Box freigibt. Wird NUR vom
    /// Reader selbst geschrieben (RT-3a: stop() darf hazardBundleRaw nicht anfassen).
    private let hazardBundleRaw = ManagedAtomic<Int>(0)
    /// S01: Anzahl abgebrochener Gesamttick wegen erschöpftem Snapshot-Erwerb.
    /// Einziger Schreiber ist der Reader (load+store ohne RMW — wartefrei); Main
    /// liest im Display-Drain und spiegelt in `clockDiagnostics.snapshotAcquireFailures`.
    private let snapshotAcquireFailures = ManagedAtomic<Int>(0)
    /// S01: Obergrenze der Erwerbsdurchläufe (= bisherige Grenze „8 Retries“, nicht erhöht).
    private static let snapshotAcquireMaxAttempts = 9
    /// S01: Ergebnis des Snapshot-Erwerbs. Reiner Wertetyp, kein Heap.
    private enum SnapshotAcquire {
        /// Box mit diesem Raw-Pointer ist im Hazard gemeldet UND validiert → dereferenzierbar.
        case protected(Int)
        /// Es ist (noch/nicht mehr) kein Bundle publiziert (vor play(), nach stop()).
        case noBundle
        /// Mehr als `snapshotAcquireMaxAttempts` Publish-Wechsel während des Erwerbs.
        case exhausted
    }
    /// Exklusiver Tick-Zutritt (RT-3a, seit v1.12.19 als CAS — siehe `enterTick()`):
    /// true, solange ein Tick läuft — vom Zutritt bis nach dem letzten MIDI-Send dieses
    /// Ticks, gleich ob er vom internen Clock-Thread oder vom MIDI-Read-Thread kommt.
    /// stop() wartet auf false, bevor es Snapshot-Box oder Notenbuch anfasst.
    private let activeTick = ManagedAtomic<Bool>(false)
    /// RT-3b: true zwischen „Sync-Spin-Backstop in stop() erreicht" und dem
    /// tatsächlichen Abschluss des aufgeschobenen RT-State-Teardowns. Nur
    /// Main-Thread (stop()/play()/startFromExternal() und der Async-Retry
    /// laufen alle auf der Main-Queue — GCD serialisiert sie, kein Atomic
    /// nötig). Schließt Codex-Befund H3: der frühere Backstop-Pfad in stop()
    /// führte den Teardown trotz activeTick == true durch (H2 in anderer
    /// Form). Jetzt gilt hart: activeTick == true ⇒ nie freigeben, auch nicht
    /// auf dem Timeout-Pfad — stattdessen aufschieben, bis wirklich quieszent.
    private var stopCleanupPending = false
    /// Hält die aktuell veröffentlichte Box am Leben (Main-Thread-Ownership).
    private var bundleCurrent:  PlaybackBundleBox? = nil
    /// Aufgeschobene Freigabe: eine abgelöste Box, die der Tick-Thread laut Hazard
    /// noch benutzt. Höchstens eine, da es genau einen Leser gibt.
    private var bundleDeferred: PlaybackBundleBox? = nil
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
    static let runtimeSlotCount = 256
    /// Obergrenze für neue Spuren je Pattern: aktuelles + vorgemerktes Pattern müssen
    /// zusammen in den Slot-Block passen, sonst blieben Spuren stumm.
    static let maxTracksPerPattern = runtimeSlotCount / 2
    private var canGrowTracks: Bool { patterns.allSatisfy { $0.tracks.count < Self.maxTracksPerPattern } }
    private let rtRuntimes: UnsafeMutablePointer<TrackRuntime> = {
        let p = UnsafeMutablePointer<TrackRuntime>.allocate(capacity: SequencerEngine.runtimeSlotCount)
        p.initialize(repeating: TrackRuntime(), count: SequencerEngine.runtimeSlotCount)
        return p
    }()
    /// Main-only: Slot-Vergabe je Track-UUID. Slots bleiben belegt, solange der Track im
    /// aktuellen oder im vorgemerkten Pattern liegt.
    private var slotByTrack: [UUID: (slot: Int, epoch: UInt32)] = [:]
    private var freeSlots: [Int] = Array((0..<SequencerEngine.runtimeSlotCount).reversed())
    private var nextSlotEpoch: UInt32 = 1
    /// Main-only: Aktivierungsnummer des aktuellen Patterns (siehe PlaybackStateBundle.serial).
    private var patternSerial = 1
    /// Tick-Thread-only: Aktivierung, die der Tick-Thread gerade spielt.
    private var rtActiveSerial = 0
    /// Vom Tick-Thread publiziert, sobald er an der Patterngrenze selbst gewechselt hat
    /// (= neue Aktivierungsnummer). Main gleicht damit `currentPatternIndex` ab. Zustellung
    /// über dieses Atomic ist verlustfrei; das Ring-Event ist nur der Weckruf.
    private let rtSwitchedSerial = ManagedAtomic<Int>(0)

    // MARK: Notenbuch (v1.12.19; v1.12.22: Offs werden erst kurz vor ihrem Zeitpunkt gesendet)
    //
    // 16 Kanäle × 128 Noten. Je Note:
    //   pendingOff — Zeitpunkt des noch NICHT an CoreMIDI übergebenen Note-Offs (0 = keins)
    //   sentOff    — spätestes bereits übergebenes Off (kann noch in der Zukunft liegen)
    //   lastOn     — spätestes übergebenes On (kann noch in der Zukunft liegen)
    //
    // Ein einmal übergebenes Off lässt sich nicht zurückholen. Würde es wie früher zusammen
    // mit dem On geplant, schnitte es eine später begonnene gleiche Note ab (Gate > 100 %
    // auf gleicher Tonhöhe, zwei Spuren auf demselben Kanal). Deshalb bleibt das Off im Buch,
    // bis sein Zeitpunkt im Fenster des laufenden Ticks liegt (`flushDueNoteOffs`); ein
    // neues On derselben Note verlängert es bis dahin (`sendNote`).
    //
    // Schreiber ist der Tick-Thread (innerhalb des Tick-Zutritts). Main fasst das Buch nur
    // an, wenn kein Tick laufen kann: nach bewiesener Quieszenz (stop/teardown) oder als
    // Inhaber des Tick-Zutritts (Off-Wächter bei ausbleibender externer Clock).
    struct NoteBookEntry {
        var pendingOff: UInt64 = 0
        var sentOff:    UInt64 = 0
        var lastOn:     UInt64 = 0
    }
    /// Ein Buchabschnitt je Ausgang: Abschnitt 0 = externe MIDI-Ausgabe, Abschnitt
    /// `route + 1` = gehostetes Instrument. Dieselbe Tonhöhe auf verschiedenen Ausgängen
    /// ist nicht dieselbe Note.
    private static let notesPerPort = 16 * 128
    private static let portCount    = 1 + InstrumentRack.maxChannels
    private static let noteBookSize = portCount * notesPerPort
    private let noteBook: UnsafeMutablePointer<NoteBookEntry> = {
        let p = UnsafeMutablePointer<NoteBookEntry>.allocate(capacity: SequencerEngine.noteBookSize)
        p.initialize(repeating: NoteBookEntry(), count: SequencerEngine.noteBookSize)
        return p
    }()
    /// Je Ausgang: untere Schranke des frühesten `pendingOff` (.max = keins) — erspart den
    /// Durchlauf von Abschnitten, in denen nichts fällig ist. Gehört wie das Buch dem
    /// Inhaber des Tick-Zutritts.
    private let earliestPendingOff: UnsafeMutablePointer<UInt64> = {
        let p = UnsafeMutablePointer<UInt64>.allocate(capacity: SequencerEngine.portCount)
        p.initialize(repeating: .max, count: SequencerEngine.portCount)
        return p
    }()
    /// Je Ausgang: Belegungsepoche, zu der die Einträge des Buchabschnitts gehören
    /// (v1.13.13). Gehört wie das Buch dem Inhaber des Tick-Zutritts.
    private let portEpoch: UnsafeMutablePointer<UInt32> = {
        let p = UnsafeMutablePointer<UInt32>.allocate(capacity: SequencerEngine.portCount)
        p.initialize(repeating: 0, count: SequencerEngine.portCount)
        return p
    }()
    /// Für den Off-Wächter (Main): gibt es ungesendete Offs, und wann lief der letzte
    /// externe Tick? Beides vom Tick-Thread geschrieben.
    private let hasPendingOffs  = ManagedAtomic<Bool>(false)
    private let lastExtTickHost = ManagedAtomic<UInt64>(0)
    /// Main-only: läuft während der Wiedergabe (siehe `startOffWatchdog`).
    private var offWatchdog: DispatchSourceTimer?
    /// RT-4b: alloc-freier PRNG für den Tick-Pfad (Random-Direction,
    /// Step-Probability-Gate). Seed wird einmalig bei Konstruktion auf dem
    /// Main-Thread gezogen (nicht RT). Wie die Runtime-Slots gehört er dem
    /// Tick-Thread: alle Nutzstellen liegen innerhalb des Tick-Zutritts
    /// (`enterTick()`), kein Atomic nötig.
    private var rtRandom = RTRandom(seed: UInt64.random(in: .min ... .max))

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
    private var displaySignal: DispatchSourceUserDataOr?

    /// AU-Host (v1.13.0): Instrumentenkanäle, Effekte, Mixer. Main-eigen; der Tick-Pfad
    /// erreicht nur die festen Ereigniswarteschlangen (`rack.queues[route]`).
    let rack = InstrumentRack()

    /// Interne Clock-Quelle.
    /// onTick → clockTick(at:) → advanceSteps(tickTime:).
    private let audioClock         = ClockSource()

    // MARK: - Safety-Clamp + Clamp-Zähler
    // safetyOffsetMach: 1 ms in mach_absolute_time-Einheiten.
    // Stellt sicher, dass MIDI-Future-Timestamps nie in der Vergangenheit liegen.
    private static let safetyOffsetMach: MIDITimeStamp = nanosToMachTime(1_000_000)
    /// Anzahl geclampter Note/CC-Timestamps — kumulativ, kein Reset im Betrieb.
    /// Nur diagnostisch.
    private let clampCountNotes = ManagedAtomic<Int>(0)
    /// Diagnostisch — ausgehender MIDI-Clock 0xF8.
    private let clampCountClock = ManagedAtomic<Int>(0)
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
    private let midiStartPending = ManagedAtomic<Bool>(false)

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
    private let clockIsInternal     = ManagedAtomic<Bool>(true)
    private let isPlayingRT         = ManagedAtomic<Bool>(false)

    #if DEBUG
    // RT-1: Test-only-Fenster auf die atomaren Playback-Spiegel und den
    // aktuell publizierten Bundle. Read-only, keine Mutation. Ermöglicht
    // Bundle-Konsistenz- und Pattern-Queue-Tests ohne Zugriff auf die
    // privaten Atomics.
    func _rt1PublishedBundle() -> PlaybackStateBundle? {
        let raw = atomicBundleRaw.load(ordering: .acquiring)
        guard raw != 0, let ptr = UnsafeRawPointer(bitPattern: raw) else { return nil }
        return Unmanaged<PlaybackBundleBox>.fromOpaque(ptr).takeUnretainedValue().bundle
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
        guard let b = bundleCurrent?.bundle, b.snapshot.tracks.indices.contains(track) else { return -1 }
        return b.snapshot.tracks[track].slot
    }
    /// Aktueller Runtime-Step eines Tracks (Test-Fenster). −1 auch für „frisch": eine
    /// Runtime, deren Epoche noch nicht zur Slot-Vergabe passt, startet beim nächsten Tick neu.
    func _rt1CurrentStep(track: Int) -> Int {
        let slot = _testSlot(track: track)
        guard slot >= 0, let b = bundleCurrent?.bundle else { return -999 }
        let rt = rtRuntimes[slot]
        return rt.epoch == b.snapshot.tracks[track].epoch ? rt.currentStep : -1
    }

    /// Treibt genau einen internen Tick.
    func _rt2DriveOneTick(at ts: UInt64) { clockTick(at: ts) }
    /// Setzt den Cursor eines Tracks (Test-Tagging); bindet die Runtime dabei an die
    /// aktuelle Slot-Epoche, als hätte der Track bereits gespielt.
    func _rt2SetCurrentStep(track: Int, to value: Int) {
        let slot = _testSlot(track: track)
        guard slot >= 0, let b = bundleCurrent?.bundle else { return }
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
    func _rt2RuntimeCount() -> Int { bundleCurrent?.bundle.snapshot.tracks.count ?? 0 }
    /// Zahl der aktuell vergebenen Runtime-Slots (Main-seitige Buchhaltung).
    var _slotsInUse: Int { slotByTrack.count }
    var _patternSerial: Int { patternSerial }
    /// Ticks, die abgewiesen wurden, weil bereits ein Tick lief (Tick-Zutritt).
    var _rejectedTicks: Int { rejectedTicks.load(ordering: .relaxed) }
    /// Spätester geplanter Off-Zeitpunkt einer Note im Notenbuch (0 = keiner).
    /// Spätestes bekanntes Off der Note (ungesendet oder gesendet); 0 = Buch leer.
    func _noteBookEntry(channel: Int, note: Int, route: Int = -1) -> UInt64 {
        let e = noteBook[(route + 1) * Self.notesPerPort + (channel - 1) * 128 + note]
        return max(e.pendingOff, e.sentOff)
    }
    func _noteBookPendingOff(channel: Int, note: Int, route: Int = -1) -> UInt64 {
        noteBook[(route + 1) * Self.notesPerPort + (channel - 1) * 128 + note].pendingOff
    }
    /// Treibt den Off-Wächter synchron, als stünde die externe Clock schon lange genug still.
    func _runOffWatchdogForTest() { flushOverdueOffsIfClockStalled(stallMach: 0) }

    // RT-3: Test-Fenster auf die Hazard-Pointer-Lebensdauer-Sicherung.
    var _rt3HazardRaw:     Int { hazardBundleRaw.load(ordering: .acquiring) }
    var _rt3AtomicRaw:     Int { atomicBundleRaw.load(ordering: .acquiring) }
    var _rt3CurrentBoxRaw: Int { bundleCurrent.map  { Self.rawOf($0) } ?? 0 }
    var _rt3DeferredBoxRaw: Int { bundleDeferred.map { Self.rawOf($0) } ?? 0 }
    /// Simuliert einen Audio-Leser mitten im Tick: Hazard auf die aktuell
    /// publizierte Box setzen.
    func _rt3AnnounceCurrentHazard() {
        hazardBundleRaw.store(atomicBundleRaw.load(ordering: .acquiring), ordering: .releasing)
    }
    func _rt3ClearHazard() { hazardBundleRaw.store(0, ordering: .releasing) }
    /// Welche Box der letzte Tick tatsächlich dereferenziert hat.
    private(set) var _rt3LastTickBoxRaw: Int = 0
    /// Weak-Sonde auf die aktuelle Box — beweist Deallozierung/Am-Leben-Bleiben.
    weak var _rt3WeakProbe: PlaybackBundleBox?
    func _rt3SetWeakProbeToCurrent() { _rt3WeakProbe = bundleCurrent }
    var _rt3WeakProbeAlive: Bool { _rt3WeakProbe != nil }
    func _rt3DriveOneTick(at ts: UInt64) { clockTick(at: ts) }

    // S01: Test-Fenster an den echten Grenzen des Snapshot-Erwerbs. Der Hook läuft
    // synchron auf dem Reader-Thread; ein Test, der darin publishSnapshot() aufruft,
    // erzwingt Pointerwechsel deterministisch (kein Allocator-Zufall). Nur DEBUG —
    // der Produktionsbuild enthält weder Hook noch Aufruf.
    enum _S01Stage { case loaded, announced, validated, released }
    var _s01AcquireHook: ((_S01Stage, Int) -> Void)?
    let _s01ForceExhaustion = ManagedAtomic<Bool>(false)
    /// Anzahl publishSnapshot()-Aufrufe (nur Main schreibt) — Diagnose für Swing-/Main-Hop-Tests.
    private(set) var _s01PublishCount = 0
    /// Anzahl abgebrochener Gesamttick wegen erschöpftem Erwerb (Atomic-Spiegel).
    var _s01AcquireFailures: Int { snapshotAcquireFailures.load(ordering: .acquiring) }
    /// Entscheidungsstellen der Clock-Ausgabe in clockTick (Aufruf von sendClock/sendStartRT).
    /// Zählt nur den Sendeentschluss, keine CoreMIDI-Bytes (Beobachtungsnaht: Slice S04).
    private(set) var _s01ClockSendCount = 0
    private(set) var _s01StartSendCount = 0
    var _s01MidiStartPending: Bool { midiStartPending.load(ordering: .acquiring) }
    func _s01ArmMidiStart() { midiStartPending.store(true, ordering: .releasing) }
    func _s01PulseAccumulator(track: Int) -> Double { _rt2PulseAccumulator(track: track) }
    /// Deinit-Sonde an der aktuell publizierten Box (feuert auf dem Thread, der die letzte Referenz löst).
    func _s01SetDeinitProbeOnCurrent(_ probe: @escaping () -> Void) { bundleCurrent?._deinitProbe = probe }

    // RT-3a: Test-Fenster auf die Stop-/External-Clock-Quieszenz.
    /// Einmaliger Pause-Hook mitten in advanceSteps() (nach Snapshot-Erwerb +
    /// Hazard-Announce, vor MIDI-Emission) — Test-Fenster, um einen externen
    /// Tick deterministisch mitten im Lauf zu parken. No-op wenn nil; feuert
    /// höchstens einmal (selbst-löschend), kein Folge-Tick pausiert versehentlich.
    var _rt3aPausePoint: (() -> Void)?
    var _rt3aActiveTick: Bool { activeTick.load(ordering: .acquiring) }
    /// Treibt den EXTERNEN Clock-Pfad direkt (tick(scheduledAt:) ist private) —
    /// exakt der Aufrufpfad von midi.onClockPulse auf dem MIDI-Read-Thread.
    func _rt3aDriveOneExternalTick(at ts: UInt64) { tick(scheduledAt: ts) }

    // RT-3b: Test-Fenster auf den Fail-Safe Deferred Cleanup.
    var _rt3bCleanupPending: Bool { stopCleanupPending }

    // RT-4a: Test-Fenster auf die Catch-up-/Resync-Strategie (geclampte
    // ausgehende 0xF8-Pulse werden verworfen statt gebursted — die interne
    // Step-Fortschreibung in advanceSteps() bleibt davon unberührt, s.
    // clockTick() unten).
    var _rt4ClampCountClock: Int { clampCountClock.load(ordering: .relaxed) }

    // RT-4b: Test-Fenster auf den RT-sicheren PRNG — deterministischer Seed
    // für reproduzierbare Zufalls-Assertions (Random-Direction, Probability-Gate).
    func _rt4bSetRandomSeedForTest(_ seed: UInt64) { rtRandom = RTRandom(seed: seed) }
    #endif

    // Konvertiert Nanosekunden in Mach-Zeiteinheiten (plattformspezifisch).
    private static let machTimebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()
    private static func nanosToMachTime(_ ns: UInt64) -> UInt64 {
        let tb = machTimebase
        // nanoseconds = mach_time × numer / denom
        // → mach_time  = ns × denom / numer
        // Overflow-Schutz: multipliziere zuerst, wenn denom ≤ numer (kleinerer Faktor vorn).
        return (tb.denom <= tb.numer)
            ? ns * UInt64(tb.denom) / UInt64(tb.numer)
            : ns / UInt64(tb.numer) * UInt64(tb.denom)
    }

    /// RT-SAFE: Klemmt einen MIDITimeStamp auf ≥ jetzt + 1 ms.
    /// Identische Logik wie der Safety-Clamp in advanceSteps() — als shared Helper extrahiert,
    /// damit clockTick() denselben Clamp-Boden verwenden kann.
    /// @inline(__always): Keine Call-Overhead im Tick-Thread-Pfad.
    @inline(__always)
    private func clampToFuture(_ t: MIDITimeStamp) -> MIDITimeStamp {
        let nowSafe = mach_absolute_time() + Self.safetyOffsetMach
        return t < nowSafe ? nowSafe : t
    }
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
    var currentPattern: Pattern { patterns[currentPatternIndex] }

    init() {
        midi.setup()
        loadRecentFiles()
        startDisplaySignal()
        // AU-Host: Änderungen am Rack sind Projektänderungen; eine neue Slot-Zuordnung muss
        // in den Playback-Snapshot. Ein entfernter Kanal stellt seine Spuren auf externe
        // MIDI-Ausgabe zurück (sonst blieben sie an einer toten ID hängen).
        rack.onProjectChange = { [weak self] in
            guard let self, !self.hasUnsavedChanges else { return }
            self.hasUnsavedChanges = true
        }
        rack.onRoutingChange = { [weak self] in
            guard let self, self.transportState.isPlaying else { return }
            self.publishSnapshot()
        }
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
        audioClock.onTick = { [weak self] timestamp in
            self?.clockTick(at: timestamp)
        }
        midi.onClockPulse = { [weak self] in
            // Guard: nur im EXT-Modus verarbeiten.
            // Verhindert Doppel-Tick wenn ClockSource (INT) und eingehende
            // 0xF8-Nachrichten (z.B. aus Logic) gleichzeitig aktiv sind → vorher: 2× Tempo-Bug.
            // RT-1: atomarer Read statt @Published (läuft auf dem MIDI-Read-Thread).
            guard let self, !self.clockIsInternal.load(ordering: .acquiring) else { return }
            let now = mach_absolute_time()
            if self.extResetRequested.exchange(false, ordering: .acquiringAndReleasing) {
                self.extPulseCount      = 0
                self.extLastTickMach    = 0
                self.extTickIntervalEMA = 0.0
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
            // Prädiktiver Lookahead: EMA über gemessene Tick-Intervalle.
            // scheduledAt = now + EMA ≈ vorhergesagter Zeitpunkt des nächsten Ticks.
            // → CoreMIDI erhält Future-Timestamps; Overshoot-Fix wirkt auch im EXT-Modus.
            // Erster Puls (extLastTickMach == 0): kein Intervall messbar → Fallback auf now.
            if self.extLastTickMach > 0 {
                let measured = Double(now - self.extLastTickMach)
                self.extTickIntervalEMA = self.extTickIntervalEMA > 0
                    ? (1.0 - self.extEMAAlpha) * self.extTickIntervalEMA + self.extEMAAlpha * measured
                    : measured
            }
            self.extLastTickMach = now

            let scheduledAt = self.extTickIntervalEMA > 0
                ? now + UInt64(self.extTickIntervalEMA)
                : now
            self.tick(scheduledAt: scheduledAt)
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
        rtRuntimes.deinitialize(count: Self.runtimeSlotCount); rtRuntimes.deallocate()
        noteBook.deinitialize(count: Self.noteBookSize);       noteBook.deallocate()
        earliestPendingOff.deinitialize(count: Self.portCount); earliestPendingOff.deallocate()
        portEpoch.deinitialize(count: Self.portCount); portEpoch.deallocate()
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
        snapshotAcquireBaseline = snapshotAcquireFailures.load(ordering: .acquiring)
        acquireDisplayLastPublish = 0
        if clockDiagnostics.snapshotAcquireFailures != 0 { clockDiagnostics.snapshotAcquireFailures = 0 }
    }

    /// Spiegelt den atomaren Fehlerzähler (Reader schreibt) nach `clockDiagnostics`, das die
    /// StatusBar beobachtet. Der erste Fehler erscheint sofort; weitere Änderungen werden auf
    /// höchstens ein Update pro Sekunde koalesziert (kein Invalidierungssturm pro Tick), ein
    /// nachlaufender Abgleich stellt den Endstand sicher. Main.
    private func syncSnapshotAcquireDisplay() {
        let total = snapshotAcquireFailures.load(ordering: .acquiring) - snapshotAcquireBaseline
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
    private func buildPatternSnapshot(for pattern: Pattern) -> PatternSnapshot {
        let tracks = pattern.tracks.map { track -> TrackSnapshot in
            let lane = track.lane

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
                    let notes = lane.fixedNote.map { [max(0, min(127, $0))] }
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
                    pulsesPerStep: pps,
                    payload:       .step(steps: steps)
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
                    pulsesPerStep: pps,
                    payload:       .cc(values:  ccs,
                                       number:  max(0, min(127, lane.ccNumber)),
                                       isMuted: lane.ccIsMuted)
                )
            }

            let binding = runtimeBinding(for: track.id)
            // CC-Lane mit Instrument-Parameter: Bereich jetzt (Main) auflösen. Fehlt der
            // Parameter oder lädt das Instrument noch, bleibt es bei MIDI-CC.
            let route = rack.route(for: track.instrumentID)
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
                routeEpoch:    rack.routeEpoch(for: track.instrumentID),
                parameter:     parameter,
                ccUnresolved:  ccUnresolved
            )
        }

        let hasSolo = tracks.contains { $0.isSolo }
        return PatternSnapshot(tracks: tracks, hasSolo: hasSolo)
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
    }

    /// Zieht einen vom Tick-Thread vollzogenen Patternwechsel auf Main nach
    /// (currentPatternIndex, Anzeige). `true`, wenn ein Wechsel übernommen wurde —
    /// der Aufrufer publiziert danach einen Snapshot mit der neuen Aktivierung.
    @discardableResult
    private func reconcilePatternSwitch() -> Bool {
        guard let idx = queuedPatternIndex, patterns.indices.contains(idx),
              rtSwitchedSerial.load(ordering: .acquiring) == patternSerial + 1 else { return false }
        for td in currentPattern.tracks {
            if let vm = vmCache[td.id] {
                vm.lastFiredNotes.forEach { sendImmediateNoteOff(td, note: $0) }
                vm.lastFiredNotes = []
            }
        }
        cancelInteractionSession()   // die Lanes des alten Patterns verschwinden
        patternSerial += 1
        queuedPatternIndex  = nil
        currentPatternIndex = idx
        playbackDisplay.steps = Array(repeating: -1, count: patterns[idx].tracks.count)
        return true
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
        // Ein bereits vollzogener Wechsel muss VOR dem Bauen übernommen sein — sonst trüge
        // der neue Bundle noch die alte Aktivierung.
        reconcilePatternSwitch()
        let snap   = buildPatternSnapshot(for: currentPattern)
        var live   = Set(currentPattern.tracks.map(\.id))
        var queued: PatternSnapshot?
        if let q = queuedPatternIndex, patterns.indices.contains(q), q != currentPatternIndex {
            queued = buildPatternSnapshot(for: patterns[q])
            live.formUnion(patterns[q].tracks.map(\.id))
        }
        releaseUnusedSlots(keeping: live)
        let bundle = PlaybackStateBundle(snapshot: snap, bpm: bpmOverride ?? bpm, swing: swing,
                                         serial: patternSerial, queued: queued)
        let newBox = PlaybackBundleBox(bundle)

        let superseded = bundleCurrent   // bisher aktuelle Box — wird jetzt abgelöst
        bundleCurrent  = newBox          // neue Box am Leben halten, BEVOR publiziert wird

        // S01 — Memory Ordering: seq_cst store (W1) + seq_cst hazard load (W2).
        //
        // Der Store ist zugleich Release-Publikation: alle Writes davor (bundleCurrent =
        // newBox, Initialisierung des Box-Inhalts) sind für jeden Reader sichtbar, der den
        // Pointer mit einem acquire-Anteil lädt (R3). Release/Acquire allein genügt für die
        // FREIGABE aber nicht (Store-Buffering, siehe Protokollbeweis oben): erst die
        // gemeinsame Totalordnung von W1, W2, R2, R3 garantiert, dass entweder W2 den
        // Hazard sieht oder R3 den neuen Pointer.
        let rawPtr = Self.rawOf(newBox)
        atomicBundleRaw.store(rawPtr, ordering: .sequentiallyConsistent)

        // Freigabe der abgelösten Box gegen den Hazard-Pointer prüfen (W2/W3).
        let hz = hazardBundleRaw.load(ordering: .sequentiallyConsistent)
        // Eine früher aufgeschobene Box freigeben, sobald der Leser nicht mehr darauf steht.
        if let d = bundleDeferred, Self.rawOf(d) != hz { bundleDeferred = nil }
        // Die gerade abgelöste Box: hält der Leser sie noch, aufschieben; sonst fällt sie hier.
        if let s = superseded, Self.rawOf(s) == hz { bundleDeferred = s }
        // `superseded` darf nicht vor W1/W2 freigegeben werden (ARC verkürzt Lebensdauern
        // bis zur letzten Verwendung); das Halten über den ganzen Ablauf macht die
        // Reihenfolge „publizieren → Hazard lesen → freigeben“ explizit.
        withExtendedLifetime(superseded) {}
    }

    /// RT-3: roher Opaque-Pointer einer Box als Int (identisch zur Publish-Kodierung).
    @inline(__always)
    private static func rawOf(_ box: PlaybackBundleBox) -> Int {
        Int(bitPattern: Unmanaged.passUnretained(box).toOpaque())
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
                if !self.hasUnsavedChanges { self.hasUnsavedChanges = true }
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
    }

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
            sendPendingNoteOffs()
        }
        // Runtime und Snapshot aufbauen, bevor die Clock startet.
        let trackCount           = currentPattern.tracks.count
        // Neue Sitzung: frische Slot-Epochen → jeder Track startet mit frischer Runtime.
        // Quieszent — die Clock läuft noch nicht, isPlayingRT ist false.
        beginRuntimeSession()
        clearNoteBook()
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
            audioClock.start()
            midiStartPending.store(true, ordering: .releasing)
        } else {
            // EXT-Modus: Wir erzeugen keinen Clock → 0xFA sofort senden ist korrekt.
            midi.start()
        }
    }

    func stop() {
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
        midi.flushOutput()
        midi.stop()
        // Der Flush hat auch geplante Note-Offs verworfen: jede Note, deren Off noch
        // aussteht, bekommt jetzt ein sofortiges Off (Notenbuch). Im Deferred-Pfad
        // läuft das erst nach bewiesener Quieszenz (scheduleDeferredRTStateCleanup).
        if !stopCleanupPending { sendPendingNoteOffs() }
        queuedPatternIndex  = nil
        extResetRequested.store(true, ordering: .releasing)   // EXT-Messzustand: MIDI-Thread setzt selbst zurück
        for td in currentPattern.tracks {
            if let vm = vmCache[td.id] {
                vm.lastFiredNotes.forEach { sendImmediateNoteOff(td, note: $0) }
                vm.lastFiredNotes = []
            }
            // Gehostete Instrumente hat sendPendingNoteOffs/silenceAll bereits beruhigt.
            if td.instrumentID == nil || rack.route(for: td.instrumentID) < 0 {
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
    /// scheduleDeferredRTStateCleanup()). hazardBundleRaw wird nie von Main
    /// geschrieben — nur der Reader selbst löscht seinen eigenen Hazard; hier wird
    /// nur die Invariante geprüft.
    private func teardownRTState() {
        #if DEBUG
        assert(!activeTick.load(ordering: .acquiring),
               "RT-3b: Teardown nur nach bewiesener Quieszenz")
        assert(hazardBundleRaw.load(ordering: .acquiring) == 0,
               "RT-3b: hazardBundleRaw sollte nach bewiesener Quieszenz bereits 0 sein")
        #endif
        atomicBundleRaw.store(0, ordering: .releasing)
        bundleCurrent  = nil
        bundleDeferred = nil
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

    @inline(__always) @discardableResult
    private func outNoteOn(route: Int, epoch: UInt32, channel: Int, note: Int, velocity: Int,
                           at t: MIDITimeStamp) -> Bool {
        if route < 0 {
            midi.noteOn(channel: channel, note: note, velocity: velocity, at: t)
            return true
        }
        return rack.queues[route]._withUnsafeGuaranteedRef {
            $0.pushFromTick(UInt8(0x90 | (channel - 1) & 0x0F), UInt8(note & 0x7F),
                            UInt8(velocity & 0x7F), at: t, epoch: epoch)
        }
    }

    @inline(__always) @discardableResult
    private func outNoteOff(route: Int, epoch: UInt32, channel: Int, note: Int,
                            at t: MIDITimeStamp) -> Bool {
        if route < 0 {
            midi.noteOff(channel: channel, note: note, at: t)
            return true
        }
        return rack.queues[route]._withUnsafeGuaranteedRef {
            $0.pushFromTick(UInt8(0x80 | (channel - 1) & 0x0F), UInt8(note & 0x7F), 0,
                            at: t, epoch: epoch)
        }
    }

    @inline(__always) @discardableResult
    private func outCC(route: Int, epoch: UInt32, channel: Int, number: Int, value: Int,
                       at t: MIDITimeStamp) -> Bool {
        if route < 0 {
            midi.cc(channel: channel, number: number, value: value, at: t)
            return true
        }
        return rack.queues[route]._withUnsafeGuaranteedRef {
            $0.pushFromTick(UInt8(0xB0 | (channel - 1) & 0x0F), UInt8(number & 0x7F),
                            UInt8(value & 0x7F), at: t, epoch: epoch)
        }
    }

    /// Sofortiges Note-Off von Main an den Ausgang einer Spur (Spur entfernt,
    /// Patternwechsel, Stop).
    func sendImmediateNoteOff(_ td: TrackData, note: Int) {
        let route = rack.route(for: td.instrumentID)
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
        let route = rack.route(for: td.instrumentID)
        let epoch = rack.routeEpoch(for: td.instrumentID)   // Off nur an dieselbe Belegung
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

    /// Tick-Pfad: gibt ein Note-On aus und trägt sein Off ins Buch ein.
    ///
    /// Steht für dieselbe Note noch ein ungesendetes Off aus, wird es aufgelöst:
    ///   - es läge NACH diesem On (Überlappung) → Off genau auf dem neuen On (Neuanschlag);
    ///     die Note klingt bis zum späteren der beiden Enden.
    ///   - es liegt davor oder gleich → jetzt mit seinem eigenen Zeitpunkt senden.
    ///
    /// `tie` (Drone): klingt die Note noch (ihr Off steht nicht vor diesem On aus), wird nur
    /// ihr Ende hinausgeschoben — kein Off, kein neues On.
    ///
    /// **Ablehnung (v1.13.13).** Weist die Warteschlange eines Instruments ein Ereignis ab
    /// (voll), bleibt das Buch ehrlich: ein abgewiesenes Off gilt nicht als gesendet — die
    /// alte Note klingt weiter, es gibt keinen Neuanschlag, ihr Ende wird bis `off`
    /// verlängert. Ein abgewiesenes On hinterlässt keinen Off-Auftrag.
    ///
    /// **Belegung.** Wechselt die Belegung eines Instrument-Slots (anderes Instrument), gehören
    /// die offenen Offs dieses Buchabschnitts der vorigen Belegung; sie werden verworfen.
    @inline(__always)
    private func sendNote(route: Int, epoch: UInt32, channel: Int, note: Int, velocity: Int,
                          on: MIDITimeStamp, off: MIDITimeStamp, tie: Bool = false) {
        let port = route + 1                                   // Snapshot-Werte sind geclampt
        if route >= 0, portEpoch[port] != epoch { resetPort(port, epoch: epoch) }
        let e = noteBook + (port * Self.notesPerPort + (channel - 1) * 128 + note)
        let pending = e.pointee.pendingOff
        if tie, pending >= on, pending != 0 {
            // `earliestPendingOff` darf zu früh stehen: der nächste Durchlauf der Off-Ausgabe
            // rechnet es neu.
            if off > pending { e.pointee.pendingOff = off }
            return
        }
        if pending == 0 {
            guard outNoteOn(route: route, epoch: epoch, channel: channel, note: note,
                            velocity: velocity, at: on) else { return }
            e.pointee.pendingOff = off
        } else {
            let offAt = pending > on ? on : pending
            guard outNoteOff(route: route, epoch: epoch, channel: channel, note: note, at: offAt) else {
                // Off abgewiesen: alte Note klingt weiter, Ende verlängern, kein Neuanschlag.
                e.pointee.pendingOff = max(pending, off)
                if e.pointee.pendingOff < earliestPendingOff[port] { earliestPendingOff[port] = e.pointee.pendingOff }
                return
            }
            if pending <= on { e.pointee.sentOff = pending }
            if outNoteOn(route: route, epoch: epoch, channel: channel, note: note,
                         velocity: velocity, at: on) {
                e.pointee.pendingOff = pending > on ? max(pending, off) : off
            } else {
                e.pointee.sentOff    = offAt              // Note ist mit dem Off beendet
                e.pointee.pendingOff = 0
                return
            }
        }
        if on > e.pointee.lastOn { e.pointee.lastOn = on }
        if e.pointee.pendingOff < earliestPendingOff[port] { earliestPendingOff[port] = e.pointee.pendingOff }
    }

    /// Belegung eines Instrument-Slots hat gewechselt: offene Offs der vorigen Belegung
    /// verwerfen (ihr Instrument gibt es nicht mehr). Tick-Zutritt. Fest begrenzt
    /// (ein Buchabschnitt), nur bei einem Wechsel.
    @inline(__always)
    private func resetPort(_ port: Int, epoch: UInt32) {
        (noteBook + port * Self.notesPerPort).update(repeating: NoteBookEntry(), count: Self.notesPerPort)
        earliestPendingOff[port] = .max
        portEpoch[port] = epoch
    }

    /// Übergibt alle Offs bis einschließlich `horizon` an ihren Ausgang, jedes mit seinem
    /// eigenen Zeitpunkt. Nur als Inhaber des Tick-Zutritts aufrufen.
    ///
    /// Horizont im Tick-Pfad ist der Tick-Zeitpunkt T(k): der nächste Tick wird erst kurz vor
    /// T(k) ausgegeben und erzeugt nur Ons nach T(k) — ein hier gesendetes Off kann also
    /// keine später begonnene Note mehr treffen.
    @inline(__always)
    private func flushDueNoteOffs(upTo horizon: UInt64) {
        var anyPending = false
        for port in 0..<Self.portCount {
            let first = earliestPendingOff[port]
            if first == .max { continue }
            if first > horizon { anyPending = true; continue }
            let base  = port * Self.notesPerPort
            let route = port - 1
            var earliest = UInt64.max
            for i in 0..<Self.notesPerPort {
                let due = noteBook[base + i].pendingOff
                if due == 0 { continue }
                if due <= horizon,
                   outNoteOff(route: route, epoch: portEpoch[port], channel: i / 128 + 1,
                              note: i % 128, at: due) {
                    noteBook[base + i].sentOff    = due
                    noteBook[base + i].pendingOff = 0
                } else if due < earliest {
                    // Noch nicht fällig — oder abgewiesen: bleibt im Buch, nächster Tick
                    // versucht es erneut (verspätet, aber nicht verloren).
                    earliest = due
                }
            }
            earliestPendingOff[port] = earliest
            if earliest != .max { anyPending = true }
        }
        // Der Off-Wächter muss wissen, ob etwas aussteht.
        hasPendingOffs.store(anyPending, ordering: .relaxed)
    }

    /// Beendet jede Note, deren Off noch aussteht — ungesendet oder gesendet, aber noch in der
    /// Zukunft (MIDIFlushOutput kann es verworfen haben) — und leert das Buch. Nur aufrufen,
    /// wenn kein Tick läuft (activeTick == false und isPlayingRT == false).
    ///
    /// Externe MIDI-Ausgabe: Liegt das letzte On der Note selbst noch in der Zukunft
    /// (Ratchet/Swing/Offset planen Ons bis knapp einen Step voraus), bekommt das Off dessen
    /// Zeitpunkt + 1 ms: Der gewählte Ausgang hat das On per Flush bereits verworfen, die
    /// virtuelle Quelle liefert es aber noch aus (für `MIDIReceived` gibt es keinen Flush,
    /// Befund B5) — das Off muss danach kommen.
    ///
    /// Gehostete Instrumente: Zuerst wird alles Geplante verworfen (`silenceAll`, inklusive
    /// All Notes Off); danach genügt ein sofortiges Off je offener Note.
    private func sendPendingNoteOffs() {
        rack.silenceAll()
        let now = mach_absolute_time()
        for i in 0..<Self.noteBookSize {
            let e = noteBook[i]
            guard e.pendingOff != 0 || e.sentOff > now else { continue }
            let route = i / Self.notesPerPort - 1
            let key   = i % Self.notesPerPort
            if route < 0 {
                midi.noteOff(channel: key / 128 + 1, note: key % 128,
                             at: e.lastOn > now ? e.lastOn + Self.safetyOffsetMach : 0)
            } else {
                rack.sendFromMain(route: route, epoch: portEpoch[route + 1],
                                  UInt8(0x80 | (key / 128) & 0x0F), UInt8(key % 128), 0)
            }
        }
        clearNoteBook()
    }

    private func clearNoteBook() {
        noteBook.update(repeating: NoteBookEntry(), count: Self.noteBookSize)
        earliestPendingOff.update(repeating: .max, count: Self.portCount)
        hasPendingOffs.store(false, ordering: .relaxed)
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
              hasPendingOffs.load(ordering: .relaxed) else { return }
        let now = mach_absolute_time()
        let last = lastExtTickHost.load(ordering: .relaxed)
        guard now >= last, now - last >= stallMach else { return }
        guard enterTick() else { return }
        defer { exitTick() }
        flushDueNoteOffs(upTo: mach_absolute_time())
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
                self.sendPendingNoteOffs()
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
        if isPlaying {
            reconcilePatternSwitch()
            // Das aktuelle Pattern erneut wählen hebt eine Vormerkung auf.
            queuedPatternIndex = (idx == currentPatternIndex) ? nil : idx
            publishSnapshot()
        } else {
            applyPatternSwitch(idx)
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
        if isPlaying {
            // Continue bei laufender Wiedergabe: nichts zu tun. Start bei laufender
            // Wiedergabe: von vorn beginnen — neue Sitzung, ohne den Transport-/Display-
            // Lebenszyklus (resume/suspend) ein zweites Mal zu durchlaufen.
            guard !isContinue else { return }
            queuedPatternIndex = nil
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
            sendPendingNoteOffs()
        }
        extResetRequested.store(true, ordering: .releasing)   // sauberer Messbeginn
        beginRuntimeSession()
        clearNoteBook()
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

    // MARK: - Tick-Zutritt (v1.12.19 — ein Tick zur Zeit, nur während Wiedergabe)
    //
    // `activeTick` ist der exklusive Zutritt zum gesamten Tick-Pfad (Runtime-Slots, PRNG,
    // Notenbuch, Hazard-Fenster, alle MIDI-Sends eines Ticks):
    //   - CAS false→true: höchstens EIN Thread ist im Tick-Pfad. Das setzt die Single-
    //     Reader-Annahme des Hazard-Protokolls durch (S02) — auch wenn sich ein verspäteter
    //     Clock-Thread-Tick und ein externer Puls überlappen sollten. Der Verlierer verwirft
    //     seinen Tick (gezählt), er wartet nie.
    //   - Danach `isPlayingRT` prüfen. Mit stop() bildet das ein Dekker-Paar
    //     (Tick: store activeTick → load isPlayingRT; stop: store isPlayingRT → load
    //     activeTick; alle vier seq_cst): entweder sieht der Tick das Stop und kehrt um,
    //     oder stop() sieht den laufenden Tick und wartet. Ein Tick, der „zwischen Guard
    //     und Eintritt" hängen bleibt (Befund B2), kann nicht mehr entstehen.
    private let rejectedTicks = ManagedAtomic<Int>(0)

    @inline(__always)
    private func enterTick() -> Bool {
        guard activeTick.compareExchange(expected: false, desired: true,
                                         ordering: .sequentiallyConsistent).exchanged else {
            rejectedTicks.store(rejectedTicks.load(ordering: .relaxed) &+ 1, ordering: .relaxed)
            return false
        }
        guard isPlayingRT.load(ordering: .sequentiallyConsistent) else {
            activeTick.store(false, ordering: .sequentiallyConsistent)
            return false
        }
        return true
    }

    @inline(__always)
    private func exitTick() {
        activeTick.store(false, ordering: .sequentiallyConsistent)
    }

    /// Externer Clock-Puls (MIDI-Read-Thread). Im EXT-Modus erzeugen wir keine ausgehende Clock.
    private func tick(scheduledAt: MIDITimeStamp) {
        guard enterTick() else { return }
        defer { exitTick() }
        lastExtTickHost.store(mach_absolute_time(), ordering: .relaxed)
        advanceSteps(tickTime: scheduledAt)
    }

    // MARK: - Step sequencing

    /// Rückt einen TrackRuntime-Step entsprechend der Playback-Richtung weiter.
    /// Arbeitet ausschließlich auf TrackRuntime + TrackSnapshot — kein Track-Zugriff.
    func advanceRuntime(_ runtime: inout TrackRuntime,
                        snap: TrackSnapshot) -> Int {
        Self.advance(&runtime, snap: snap, rng: &rtRandom)
    }

    /// Reine Fortschreibung (ohne Engine-Zustand außer dem übergebenen PRNG) — erlaubt
    /// dem Tick-Pfad, den nächsten Step von Track 0 auf einer Kopie vorauszuberechnen.
    @inline(__always)
    private static func advance(_ runtime: inout TrackRuntime,
                                snap: TrackSnapshot,
                                rng: inout RTRandom) -> Int {
        let n = snap.lane.stepCount   // geclampt ≥ 1, kein % 0 möglich
        switch snap.lane.direction {
        case .forward:
            runtime.currentStep = (runtime.currentStep + 1) % n
        case .reverse:
            // <= 0 fängt auch den Startzustand -1 ab: erster Step = n-1 (B2).
            runtime.currentStep = runtime.currentStep <= 0 ? n - 1 : runtime.currentStep - 1
        case .pingPong:
            if runtime.pingPongForward {
                if runtime.currentStep >= n - 1 {
                    runtime.pingPongForward = false
                    runtime.currentStep     = max(0, n - 2)
                } else {
                    runtime.currentStep += 1
                }
            } else {
                if runtime.currentStep <= 0 {
                    runtime.pingPongForward = true
                    runtime.currentStep     = min(1, n - 1)
                } else {
                    runtime.currentStep -= 1
                }
            }
        case .random:
            // RT-4b: RT-sicherer PRNG statt Int.random (SystemRandomNumberGenerator).
            runtime.currentStep = rng.nextInt(bound: n)
        }
        return runtime.currentStep
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

    /// Würde Track 0 des Patterns `snap` auf DIESEM Tick auf Step 0 zurückspringen?
    /// Rechnet auf Kopien von Runtime und PRNG — verändert nichts. Der spätere echte
    /// Advance liefert denselben Wert (gleicher Ausgangszustand, deterministisch).
    @inline(__always)
    private func track0WillWrap(in snap: PatternSnapshot) -> Bool {
        guard let t0 = snap.tracks.first, t0.slot >= 0 else { return false }
        var rt = rtRuntimes[t0.slot]
        // Frische Runtime (prevStep == -1): erster Step, kein Wrap (B2).
        guard rt.epoch == t0.epoch, !rt.armed, rt.currentStep >= 0 else { return false }
        guard rt.pulseAccumulator + 1.0 >= t0.lane.pulsesPerStep else { return false }
        var rng = rtRandom
        return Self.advance(&rt, snap: t0, rng: &rng) == 0
    }

    /// S01: beschränkter Hazard-Pointer-Erwerb (Protokoll R1–R4 am `atomicBundleRaw`).
    ///
    /// RT-Pflicht: nur Atomics, kein Lock/Alloc/ARC; höchstens
    /// 1 + 2·`snapshotAcquireMaxAttempts` + 1 atomare Operationen. `@inline(never)`,
    /// damit der Nachweis „keine Aufrufe außer Atomics“ am Symbol möglich ist.
    /// Zustand beim Verlassen: `.protected` → Hazard zeigt auf die validierte Box
    /// (der Aufrufer gibt ihn am Tick-Ende frei); `.noBundle`/`.exhausted` → Hazard 0.
    @inline(never)
    private func acquireSnapshot() -> SnapshotAcquire {
        var candidate = atomicBundleRaw.load(ordering: .acquiring)          // R1
        var attempt = 0
        while candidate != 0 {
            #if DEBUG
            _s01AcquireHook?(.loaded, attempt)
            #endif
            hazardBundleRaw.store(candidate, ordering: .sequentiallyConsistent)   // R2
            #if DEBUG
            _s01AcquireHook?(.announced, attempt)
            #endif
            var current = atomicBundleRaw.load(ordering: .sequentiallyConsistent) // R3
            #if DEBUG
            // Test-Injektion: erzwingt „Pointer hat gewechselt“ bei jedem Durchlauf, ohne
            // zweiten Writer. Protokoll, Obergrenze und Abbruchpfad bleiben unverändert.
            if _s01ForceExhaustion.load(ordering: .relaxed) { current = candidate &+ 8 }
            #endif
            if current == candidate {                                         // R4
                #if DEBUG
                _s01AcquireHook?(.validated, attempt)
                #endif
                return .protected(candidate)
            }
            attempt &+= 1
            if attempt >= Self.snapshotAcquireMaxAttempts {
                // `current` ist NICHT gemeldet → nie dereferenzieren. Hazard räumen.
                hazardBundleRaw.store(0, ordering: .releasing)
                return .exhausted
            }
            candidate = current
        }
        hazardBundleRaw.store(0, ordering: .releasing)   // candidate == 0: nichts publiziert
        return .noBundle
    }

    /// Rückgabe `true` = Tick vollständig verarbeitet. `false` = Gesamttick-Abbruch
    /// vor jedem Runtime-Fortschritt (kein Snapshot erwerbbar, S01) — der Aufrufer
    /// darf dann keine Clock-/Start-Bytes allein senden.
    ///
    /// Vorbedingung: der Aufrufer hält den Tick-Zutritt (`enterTick()` erfolgreich);
    /// stop() wartet darauf, bevor es Snapshot-Box oder Notenbuch anfasst.
    @discardableResult
    private func advanceSteps(tickTime: MIDITimeStamp) -> Bool {
        // E3/S01 — Lock-freier, beschränkter Snapshot-Erwerb (Protokoll und Ordnungs-
        // beweis: siehe Kommentar an `atomicBundleRaw`).
        //
        // Dereferenziert wird AUSSCHLIESSLICH eine Box, die im Hazard gemeldet und
        // anschließend gegen die aktuelle Publikation validiert wurde (`.protected`).
        // Es gibt keinen Fall-through: bei erschöpftem Erwerb oder fehlendem Bundle
        // endet advanceSteps hier mit `false` — bevor Runtime-Fortschritt (pulse-
        // Accumulator, currentStep, PRNG), Display-Events oder MIDI entstehen.
        //
        // Gesamttick-Abbruch (S01, Kriterium 4): Der Aufrufer (`clockTick`) sendet bei
        // `false` weder 0xF8 noch 0xFA (midiStartPending bleibt gesetzt und wird vom
        // nächsten erfolgreichen Tick konsumiert). Steps und Clock verlieren damit
        // denselben Puls statt sich zu entkoppeln. Der Erwerb liegt vor jeder Runtime-Arbeit:
        // ein Abbruch hinterlässt weder Runtime-Mutation noch Pulse-/PRNG-Fortschritt.
        let acquired = acquireSnapshot()
        guard case let .protected(raw) = acquired,
              let ptr = UnsafeRawPointer(bitPattern: raw)
        else {
            if case .exhausted = acquired {
                // Sichtbarer Fehlerpfad: wartefreier Zähler (einziger Schreiber) + Wecken
                // des Display-Drains; Main spiegelt ihn in clockDiagnostics.
                snapshotAcquireFailures.store(
                    snapshotAcquireFailures.load(ordering: .relaxed) &+ 1, ordering: .releasing)
                displaySignal?.or(data: 1)
            }
            return false
        }
        // Hazard am Tick-Ende freigeben — deckt alle weiteren Rückkehrpfade ab.
        // Reihenfolge: `bundle`/`snap` (lexikalisch später deklariert) enden vor diesem defer;
        // die Reader-Kopien der Arrays sind damit vor dem Hazard-Clear freigegeben.
        defer {
            hazardBundleRaw.store(0, ordering: .releasing)
            #if DEBUG
            _s01AcquireHook?(.released, 0)
            #endif
        }
        #if DEBUG
        _rt3LastTickBoxRaw = raw   // Test-Fenster: welche Box dieser Tick dereferenziert
        #endif
        let bundle = Unmanaged<PlaybackBundleBox>.fromOpaque(ptr).takeUnretainedValue().bundle
        #if DEBUG
        // RT-3a: Test-Fenster, um einen Tick deterministisch mitten im Lauf zu
        // parken (Hazard bereits gemeldet, vor
        // MIDI-Emission). Einmalig, selbst-löschend.
        if let pause = _rt3aPausePoint { _rt3aPausePoint = nil; pause() }
        #endif
        // Aktives Pattern bestimmen (Patternwechsel im Tick-Thread, Befund N3/S09b).
        //
        //   rtActiveSerial == bundle.serial      → `snapshot` spielen; liegt ein vorgemerktes
        //                                           Pattern vor und Track 0 springt auf DIESEM
        //                                           Tick auf Step 0, wird jetzt gewechselt.
        //   rtActiveSerial == bundle.serial + 1  → der Wechsel ist schon vollzogen, Main hat
        //                                           noch nicht nachgezogen → weiter `queued`.
        //   sonst                                → neue Sitzung/Aktivierung übernehmen.
        //
        // Die Runtimes des neuen Patterns haben eigene Slots/Epochen und sind frisch
        // (armed): ihr erster Step feuert auf diesem Tick — exakt auf der Grenze.
        var snap = bundle.snapshot
        if rtActiveSerial != bundle.serial {
            if let q = bundle.queued, rtActiveSerial == bundle.serial &+ 1 {
                snap = q
            } else {
                rtActiveSerial = bundle.serial
            }
        }
        if rtActiveSerial == bundle.serial, let q = bundle.queued, track0WillWrap(in: snap) {
            rtActiveSerial = bundle.serial &+ 1
            rtSwitchedSerial.store(rtActiveSerial, ordering: .releasing)
            engineEventBuffer.pushPatternSwitch(patternIdx: 0)   // Weckruf für Main
            displaySignal?.or(data: 1)
            snap = q
        }
        let pulseDuration = 60.0 / (bundle.bpm * 24.0)
        // Safety-Clamp-Boden: alle MIDI-Timestamps müssen ≥ jetzt + 1 ms sein.
        // Im INT-Modus liefert die ClockSource tickTime mit einem Tick-Intervall + Marge
        // Vorlauf — der Clamp greift dort nur nach einem Aussetzer des Clock-Threads.
        let nowSafe = mach_absolute_time() + Self.safetyOffsetMach

        for trackIdx in snap.tracks.indices {
            let trackSnap = snap.tracks[trackIdx]
            guard trackSnap.slot >= 0 else { continue }       // kein Runtime-Slot → stumm
            let runtime = rtRuntimes + trackSnap.slot

            // Slot wurde (neu) an diesen Track gebunden → frische Runtime.
            if runtime.pointee.epoch != trackSnap.epoch {
                runtime.pointee = TrackRuntime(epoch: trackSnap.epoch)
            }
            if runtime.pointee.armed {
                // Erster Tick einer frischen Runtime: Step sofort auslösen (Akkumulator 0).
                runtime.pointee.armed = false
            } else {
                runtime.pointee.pulseAccumulator += 1.0
                guard runtime.pointee.pulseAccumulator >= trackSnap.lane.pulsesPerStep else { continue }
                runtime.pointee.pulseAccumulator -= trackSnap.lane.pulsesPerStep
            }

            // T2 — Overshoot-Korrektur: exakter Schritt-Timestamp statt Tick-Timestamp.
            //
            // Nach der Subtraktion enthält pulseAccumulator den Überschuss in [0, 1) Ticks:
            // wie viele Bruchteile eines Ticks der ideale Schrittzeitpunkt VOR tickTime lag.
            // Ohne Korrektur landen alle MIDI-Events auf dem nächsten ganzzahligen Tick,
            // was bei nicht-ganzzahligen pulsesPerStep (z.B. 4:5 → pps=4.8) ein hörbares
            // Muster erzeugt (5,5,5,5,4 Ticks statt gleichmäßig 4.8).
            //
            // Für ganzzahlige Verhältnisse (pps = 6.0, 4.0 …) ist der Überschuss immer 0.0
            // → exactStepTime == tickTime → kein Behavior-Change.
            //
            // Vorlauf-Vertrag: Overshoot < 1 Tick-Intervall. Die ClockSource gibt jeden Tick
            // ein volles Intervall + emitMargin vor seinem Zeitpunkt aus — exactStepTime liegt
            // damit immer mindestens emitMargin in der Zukunft. Externer Clock: Safety-Clamp
            // greift falls nötig.
            let overshootNS    = runtime.pointee.pulseAccumulator * pulseDuration * 1_000_000_000
            let overshootMach  = Self.nanosToMachTime(UInt64(overshootNS))
            let exactStepTime  = tickTime > overshootMach ? tickTime - overshootMach : tickTime

            let stepIdx  = Self.advance(&runtime.pointee, snap: trackSnap, rng: &rtRandom)

            // displayStep: Feedback an UI via Ring-Buffer → displaySignal (Main-Thread).
            // Kein DispatchQueue.main.async mehr — kein Alloc, kein Dispatch-Overhead.
            // Arch-Slice-18: hostTime = tickTime (MIDITimeStamp, future-scheduled).
            // tickTime liegt auf dem additiven Raster der Clock-Quelle — mathematisch uniform.
            // Der Drain plant asyncAfter(deadline: tickTime) → Step-Cursor wechselt exakt
            // zum musikalischen Zeitpunkt statt zur nächsten Callback-Grenze.
            if trackIdx <= 255, stepIdx <= 255 {
                displayBuffer.push(trackIdx: UInt8(trackIdx), stepIdx: UInt8(stepIdx),
                                   hostTime: tickTime)
                displaySignal?.or(data: 1)  // Event-basierter Trigger → Main-Thread drain
            }

            let effectiveMute = trackSnap.isMuted || (snap.hasSolo && !trackSnap.isSolo)
            guard !effectiveMute else { continue }

            // Lane-Kind-Dispatch (CC-Lane Slice 1): Step-Zweig bleibt strukturell
            // unverändert; CC-Zweig ist ein eigener, kleinerer Pfad.
            // Lane Slice 6: Switch auf typsichere Payload-Union statt auf `kind`.
            // Sentinel-Guards gegen leere Step-/CC-Arrays entfallen — der Compiler
            // garantiert, dass jeder Zweig nur die ihm zustehenden Felder sieht.
            switch trackSnap.lane.payload {
            case let .cc(ccValues, ccNumber, ccIsMuted):
                guard !ccIsMuted else { continue }
                guard stepIdx < ccValues.count else { continue }

                let stepDuration = trackSnap.lane.pulsesPerStep * pulseDuration
                let isOddStep    = (stepIdx % 2 == 1)
                let swingDelay   = isOddStep
                    ? stepDuration * ((bundle.swing / 100.0) - 0.5) * 0.66
                    : 0.0
                let offset = trackSnap.timingOffset

                let ccDelayNS  = UInt64(max(0.0, swingDelay + offset) * 1_000_000_000)
                let ccTimeRaw  = exactStepTime + Self.nanosToMachTime(ccDelayNS)
                let ccTime: MIDITimeStamp
                if ccTimeRaw < nowSafe {
                    ccTime = nowSafe
                    clampCountNotes.store(clampCountNotes.load(ordering: .relaxed) &+ 1, ordering: .relaxed)
                } else {
                    ccTime = ccTimeRaw
                }
                if trackSnap.ccUnresolved {
                    // Gewähltes Parameterziel nicht verfügbar: nichts senden (kein Ersatz-CC).
                } else if trackSnap.route >= 0, let p = trackSnap.parameter {
                    let v = p.min + (p.max - p.min) * Float(ccValues[stepIdx]) / 127
                    rack.queues[trackSnap.route]._withUnsafeGuaranteedRef {
                        _ = $0.pushParameterFromTick(address: p.address, value: v, at: ccTime,
                                                     epoch: trackSnap.routeEpoch)
                    }
                } else {
                    outCC(route:   trackSnap.route,
                          epoch:   trackSnap.routeEpoch,
                          channel: trackSnap.midiChannel,
                          number:  ccNumber,
                          value:   ccValues[stepIdx],
                          at:      ccTime)
                }
                continue   // CC-Lane feuert keine Notes / Ratchets

            case .step:
                break   // Step-Pfad nachstehend
            }

            // Step-Payload auspacken für den nachstehenden, strukturell unveränderten
            // Step-Pfad. `guard case let` ist minimal-invasiv: nur 2 Identifier-
            // Ersetzungen (`trackSnap.lane.steps` → `laneSteps`), sonst keine
            // Änderung an der bestehenden Step-Logik.
            guard case let .step(laneSteps) = trackSnap.lane.payload else { continue }
            guard stepIdx < laneSteps.count else { continue }

            let step = laneSteps[stepIdx]
            guard step.isActive else { continue }
            // Halten: kein Anschlag; der vorherige Step hat seine Dauer schon um diesen
            // Step verlängert (holdSpan).
            guard !step.isHold else { continue }
            // RT-4b: RT-sicherer PRNG statt Double.random (SystemRandomNumberGenerator).
            guard rtRandom.nextUnitDouble() <= step.probability else { continue }

            let stepDuration = trackSnap.lane.pulsesPerStep * pulseDuration
            let isOddStep    = (stepIdx % 2 == 1)
            let swingDelay   = isOddStep
                ? stepDuration * ((bundle.swing / 100.0) - 0.5) * 0.66
                : 0.0
            let offset = trackSnap.timingOffset

            // Step-Lane-Purify (P2/P3): Step-Lanes senden keine CCs — CC-Verläufe
            // laufen ausschließlich über CC-Lanes (LaneKind.cc). Track/Step
            // tragen seit P3 (v1.11.0) keine Legacy-CC-Felder mehr.

            // Drone: ein Anschlag, kein Ratchet; die Note hält einen ganzen Durchlauf.
            let isDrone       = step.isDrone
            let holdSteps     = Double(step.holdSpan)
            let ratchets      = (isDrone || step.holdSpan > 0) ? 1 : step.ratchet.rawValue
            let rInterval     = stepDuration / Double(ratchets)
            let capturedNotes = step.notes
            let capturedVel   = step.velocity
            let capturedCh    = trackSnap.midiChannel
            let capturedGate  = step.gate

            for r in 0..<ratchets {
                let onDelay  = max(0.0, swingDelay + offset + Double(r) * rInterval)
                let isChord  = capturedNotes.count > 1
                let effectiveGate = ratchets > 1 ? min(capturedGate, 1.0) :
                                    isChord      ? max(capturedGate, 0.5)  : capturedGate
                // Gehaltene Steps: volle eigene Länge plus jede Halte-Step-Länge, der letzte
                // Abschnitt mit dem Gate dieses Steps (höchstens legato).
                let heldGate = holdSteps > 0 ? holdSteps + min(effectiveGate, 1.0) : effectiveGate
                let offDelay = onDelay + (isDrone ? stepDuration * Double(trackSnap.lane.stepCount)
                                                  : max(0.010, rInterval * heldGate))

                let onTimeRaw = exactStepTime + Self.nanosToMachTime(UInt64(onDelay * 1_000_000_000))
                let onTime: MIDITimeStamp
                let offTime: MIDITimeStamp
                if onTimeRaw < nowSafe {
                    onTime = nowSafe
                    clampCountNotes.store(clampCountNotes.load(ordering: .relaxed) &+ 1, ordering: .relaxed)
                } else {
                    onTime = onTimeRaw
                }
                // offTime: Gate-Dauer relativ zu onTime (nach Clamp), nicht zu tickTime.
                // Garantiert korrekte Gate-Länge auch wenn der Safety-Clamp greift.
                // Drone: Dauer = ganzer Durchlauf der Spur + ein halber Step. Der Überhang hält
                // das Off im Buch, bis derselbe Step wieder fällig ist — `sendNote(tie:)`
                // verlängert dann, statt neu anzuschlagen. Bleibt der Step aus (deaktiviert,
                // Wahrscheinlichkeit, andere Richtung), endet der Ton einen halben Step später.
                let gateSeconds = isDrone
                    ? stepDuration * (Double(trackSnap.lane.stepCount) + 0.5)
                    : max(0.010, rInterval * heldGate)
                let gateDurationMach = Self.nanosToMachTime(UInt64(gateSeconds * 1_000_000_000))
                offTime = onTime + gateDurationMach

                for note in capturedNotes {
                    sendNote(route: trackSnap.route, epoch: trackSnap.routeEpoch,
                             channel: capturedCh, note: note,
                             velocity: capturedVel, on: onTime, off: offTime, tie: isDrone)
                }

                if r == ratchets - 1 {
                    // A2: RT-sicher über EngineEventBuffer statt DispatchQueue.main.async.
                    // offDelay in ms klemmen auf UInt16 (max ~65 s, deutlich über jeder Gate-Dauer).
                    let offDelayMs = UInt16(min(offDelay * 1000, Double(UInt16.max)))
                    engineEventBuffer.pushNotesFired(
                        trackIdx:   UInt8(clamping: trackIdx),
                        notes:      capturedNotes,
                        offDelayMs: offDelayMs)
                }
            }
        }

        // Nach allen Ons dieses Ticks: Offs ausgeben, die bis zum Tick-Zeitpunkt fällig sind.
        flushDueNoteOffs(upTo: tickTime)
        return true
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

    private func makeTrack(for pattern: Pattern, kind: LaneKind, pad: Bool = false,
                           strings s: Str) -> TrackData {
        // v1.9.1 (Slice A): monotoner Ordnungszähler statt count+1 —
        // verhindert doppelte „Track N"-Namen nach Löschungen.
        let n = pattern.nextTrackOrdinal
        pattern.nextTrackOrdinal += 1
        let lane = LaneData(stepCount: pad ? 4 : 16, kind: kind)
        if pad, kind == .step {
            // Pad-Lane (v1.13.16): 4 Steps à 1 Takt, legato.
            lane.isPad = true
            lane.stepLengthNumerator = 16
            lane.stepLengthDenominator = 1
            for i in lane.steps.indices { lane.steps[i].gate = 1.0 }
        }
        return TrackData(name: pad ? s.padTrackName(n) : s.trackName(n),
                         midiChannel: min(n, 16),
                         colorIndex: firstFreeColorIndex(in: pattern.tracks),
                         lane: lane)
    }

    /// Hängt in allen Patterns einen neuen leeren Track an.
    @discardableResult
    func addTrack(kind: LaneKind = .step, pad: Bool = false) -> [TrackPlacement] {
        guard canGrowTracks else { return [] }
        let s = Str(UserDefaults.standard.string(forKey: "appLanguage") ?? "en")
        let set = patterns.map { p in
            TrackPlacement(pattern: p, track: makeTrack(for: p, kind: kind, pad: pad, strings: s),
                           index: p.tracks.count)
        }
        insertPlacements(set)
        return set
    }

    /// Inserts a new empty track directly after `index` in all patterns.
    @discardableResult
    func insertTrack(after index: Int, kind: LaneKind = .step, pad: Bool = false) -> [TrackPlacement] {
        guard canGrowTracks else { return [] }
        let s = Str(UserDefaults.standard.string(forKey: "appLanguage") ?? "en")
        let set = patterns.map { p in
            TrackPlacement(pattern: p, track: makeTrack(for: p, kind: kind, pad: pad, strings: s),
                           index: min(index + 1, p.tracks.count))
        }
        insertPlacements(set)
        return set
    }

    @discardableResult
    func duplicateTrack(at index: Int) -> [TrackPlacement] {
        guard canGrowTracks else { return [] }
        let set = patterns.compactMap { p -> TrackPlacement? in
            guard index >= 0, index < p.tracks.count else { return nil }
            let copy = p.tracks[index].freshCopy()
            copy.name = p.tracks[index].name + " 2"
            return TrackPlacement(pattern: p, track: copy, index: index + 1)
        }
        insertPlacements(set)
        return set
    }

    /// Entfernt den Track bei `index` aus allen Patterns, die ihn haben und danach
    /// nicht leer wären. Rückgabe: die entfernten Instanzen samt Position (für Undo).
    @discardableResult
    func removeTrack(at index: Int) -> [TrackPlacement] {
        guard currentPattern.tracks.count > 1 else { return [] }
        let set = patterns.compactMap { p -> TrackPlacement? in
            guard index >= 0, index < p.tracks.count, p.tracks.count > 1 else { return nil }
            return TrackPlacement(pattern: p, track: p.tracks[index], index: index)
        }
        removePlacements(set)
        return set
    }

    /// Setzt Tracks an ihrer Position ein (Add/Insert/Duplicate und Undo von Remove).
    func insertPlacements(_ set: [TrackPlacement]) {
        var currentIdx: Int?
        for p in set where patterns.contains(where: { $0 === p.pattern }) {
            guard !p.pattern.tracks.contains(where: { $0 === p.track }) else { continue }
            let at = max(0, min(p.index, p.pattern.tracks.count))
            p.pattern.tracks.insert(p.track, at: at)
            if p.pattern === currentPattern { currentIdx = at }
        }
        structureDidChange(affectsCurrentPattern: currentIdx != nil)
    }

    /// Entfernt Tracks per Identität (Remove und Undo von Add/Insert/Duplicate).
    func removePlacements(_ set: [TrackPlacement]) {
        var currentIdx: Int?
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
        pruneVMCache(keeping: Set(patterns.flatMap { $0.tracks.map(\.id) }))
        structureDidChange(affectsCurrentPattern: currentIdx != nil)
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

    func addTrackUndoable(kind: LaneKind, pad: Bool = false, actionName: String) {
        registerStructureUndo(addTrack(kind: kind, pad: pad), inserted: true, actionName: actionName)
    }
    func insertTrackUndoable(after index: Int, kind: LaneKind, pad: Bool = false, actionName: String) {
        registerStructureUndo(insertTrack(after: index, kind: kind, pad: pad), inserted: true,
                              actionName: actionName)
    }
    func duplicateTrackUndoable(at index: Int, actionName: String) {
        registerStructureUndo(duplicateTrack(at: index), inserted: true, actionName: actionName)
    }
    func removeTrackUndoable(at index: Int, actionName: String) {
        registerStructureUndo(removeTrack(at: index), inserted: false, actionName: actionName)
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

    /// Empfängt jeden 24-PPQ-Tick der ClockSource.
    ///
    /// ⚠️ RT-Pflicht: Diese Methode läuft auf dem Clock-Thread (Echtzeit).
    ///   — keine Heap-Allokationen
    ///   — kein blockierender Lock
    ///   — kein DispatchQueue.main.async
    func clockTick(at timestamp: MIDITimeStamp) {
        // RT-1a: INT-Guard VOR advanceSteps (Befund H1). Ein verspäteter Tick
        // nach INT→EXT (audioClock.stop() wartet nicht auf den Clock-Thread) darf
        // weder den internen Step fortschreiben NOCH 0xF8 senden — sonst
        // entkoppeln interner Step-Zähler und ausgehende Clock: Der Sequencer
        // liefe einen Puls weiter, den das externe Gerät nie erhält.
        // clockIsInternal wird im Setter vor dem ClockSource-Start publiziert,
        // der erste Tick sieht also bereits den konsistenten Modus.
        //    RT-1: atomarer Read statt @Published (Tick-Thread).
        guard clockIsInternal.load(ordering: .acquiring) else { return }
        // Tick-Zutritt umschließt Step-Advance UND die Clock-/Start-Sends dieses Ticks:
        // stop() kann nicht zwischen beidem durchgreifen.
        guard enterTick() else { return }
        defer { exitTick() }
        // 1. Step-Advance. S01: ohne erwerbbaren Snapshot ist der Gesamttick
        //    abgebrochen — dann auch KEIN 0xF8/0xFA (kein alleiniger Clock-Send,
        //    Steps und Clock verlieren denselben Puls). midiStartPending bleibt
        //    gesetzt und geht mit dem nächsten vollständigen Tick raus.
        guard advanceSteps(tickTime: timestamp) else { return }
        // 2. Ausgehende MIDI-Clock 0xF8 (nur INT — hier garantiert, s. Guard oben).
        let safeTickTime = clampToFuture(timestamp)
        guard safeTickTime == timestamp else {
            // Arch-Slice-15: Geclamped-Clock-Pulses NICHT senden.
            //
            // Ursache: der Clock-Thread kam weit zu spät (mehr als sein Vorlauf), der
            // Tick-Zeitpunkt liegt in der Vergangenheit. Bis zu zwei Intervalle Rückstand
            // holt die ClockSource nach, darüber verankert sie das Raster neu.
            // Diagnose-Wert: 🔴 MIDI-CLAMP ΔClock=N im Debug-Output.
            //
            // Problem: werden diese geclamped Pulse als 0xF8 gesendet, kommen beim
            // Empfänger-Gerät N Takte-Pulse quasi gleichzeitig an → sein interner
            // Arp-/LFO-/Delay-Takt rastet auf falsche Frequenz ein → hörbarer "Haken".
            //
            // Fix: geclamped Pulse still verwerfen. Das Empfänger-Gerät sieht statt
            // eines Bursts einen kurzen Aussetzer (~100ms) → synct sich nach wenigen
            // Pulsen neu ein. Klanglich unauffälliger als der Burst.
            //
            // Keine Auswirkung auf Note-Timing: advanceSteps() hat die geclamped
            // tickTime bereits intern verarbeitet (pulseAccumulator-Fortschritt,
            // ohne Step-Advance, da pulsesPerStep noch nicht erreicht). ✓
            clampCountClock.store(clampCountClock.load(ordering: .relaxed) &+ 1, ordering: .relaxed)
            return
        }
        // Arch-Slice-16b: 0xFA (MIDI Start) mit dem ersten 0xF8 senden.
        //
        // Hintergrund: play() sendet 0xFA traditionell sofort. Der erste 0xF8 kommt
        // aber erst um den Tick-Vorlauf später. Das externe Gerät resettet seinen
        // Arp/Clock bei 0xFA (Beat 1 = jetzt) → beim ersten 0xF8 "resync-ruckeln".
        //
        // Fix: midiStartPending wird in play() auf true gesetzt (statt midi.start()).
        // Beim ersten non-clamped clockTick() wird 0xFA atomar gelesen und mit
        // demselben Future-Timestamp wie 0xF8 gesendet.
        //
        // 0xFA wird 1 ns vor 0xF8 eingeplant, damit CoreMIDI die Reihenfolge einhält.
        // Musikalisch absolut irrelevant; stellt sicher, dass der Empfänger zuerst
        // den Start-Befehl sieht, bevor der erste Clock-Puls ankommt.
        //
        // RT-sicher: midiStartPending.exchange ist ein einzelner atomarer Read+Clear.
        // midi.sendStartRT nutzt sendRTSafe (stack-only, keine Allokation).
        if midiStartPending.exchange(false, ordering: .acquiringAndReleasing) {
            let startTS = safeTickTime > 0 ? safeTickTime - 1 : safeTickTime
            #if DEBUG
            _s01StartSendCount &+= 1
            #endif
            midi.sendStartRT(at: startTS)
        }
        #if DEBUG
        _s01ClockSendCount &+= 1
        #endif
        midi.sendClock(at: safeTickTime)
    }
}
