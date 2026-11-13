import Foundation

// MARK: - PlaybackSnapshot
//
// Unveränderliche Datenstrukturen für den Tick-Thread.
// Der Tick-Thread liest ausschließlich aus diesen Structs —
// niemals direkt aus Track oder Pattern.
//
// Lifecycle:
//   buildPatternSnapshot() wird NUR auf dem Main-Thread aufgerufen.
//   Der Tick-Thread greift pro Tick via PlaybackStateBundle auf den Snapshot zu.
//
// ═══════════════════════════════════════════════════════════════════════════════
// D9 — DESIGN-INVARIANTE: SNAPSHOT-IMMUTABILITY NACH PUBLISH
// ═══════════════════════════════════════════════════════════════════════════════
//
// Alle Snapshot-Typen (StepSnapshot, TrackSnapshot, PatternSnapshot,
// PlaybackStateBundle, PlaybackBundleBox) sind nach dem Publish VOLLSTÄNDIG
// unveränderlich. Das ist keine Konvention — es ist eine strukturelle Anforderung
// des Lock-Free-Atomic-Modells (E3).
//
// Warum das zwingend ist:
//   Der Tick-Thread liest Snapshot-Felder OHNE jede Synchronisation (kein Lock,
//   kein Barrier außer dem einmaligen acquiring load des Pointers). Das ist nur
//   korrekt, weil nach dem Publish niemand die Daten mehr schreibt. Würde ein
//   Feld nach dem Publish mutiert, könnte der Tick-Thread einen halb-aktualisierten
//   Zustand lesen — undefiniertes Verhalten, plattformabhängige Korruption.
//
// Konkrete Regeln für spätere Erweiterungen:
//   ✗ Keine `var`-Properties in StepSnapshot, TrackSnapshot, PatternSnapshot,
//     PlaybackStateBundle einführen (würde die statische Immutabilitäts-Garantie brechen).
//   ✗ Keine Klassen-Referenzen (class-Typen) in Snapshot-Structs, die nach dem
//     Publish von außen mutiert werden könnten.
//   ✗ Kein `lazy var` in Snapshot-Structs (lazy var schreibt beim ersten Zugriff
//     zurück in self — Race-Condition auf dem Tick-Thread).
//   ✓ Neue Felder immer als `let` mit werttyp (struct / enum / primitiv / [T] mit T: Sendable).
//   ✓ PlaybackBundleBox.bundle ist `let` — darf nie zu `var` werden.
//
// Änderungen am Modell (z. B. neue Track-Parameter) erfordern immer:
//   1. Neues `let`-Feld in TrackSnapshot/StepSnapshot hinzufügen.
//   2. buildPatternSnapshot() / Track.makeSnapshot() anpassen.
//   3. Tick-Thread-Lesepfad in advanceSteps() ergänzen.
//   Kein direkter Zugriff des Tick-Threads auf Track/Pattern — je.
// ═══════════════════════════════════════════════════════════════════════════════

// MARK: - StepSnapshot

/// Unveränderlicher Snapshot eines einzelnen Steps.
/// Alle Werte sind geclampt und garantiert gültig.
struct StepSnapshot: Sendable {
    let isActive:    Bool
    let notes:       [Int]          // mind. 1 Element, alle 0…127
    let velocity:    Int            // 1…127
    let gate:        Double         // > 0
    let probability: Double         // 0.0…1.0
    let ratchet:     RatchetCount
    /// Drone: Ton hält einen ganzen Durchlauf der Spur (v1.13.12).
    var isDrone:     Bool = false
    // Step-Lane-Purify (P1/P3): per-Step-CC-Felder wurden in P1 aus dem
    // RT-Snapshot und in P3 (v1.11.0) aus dem Modell entfernt. CC-Verläufe
    // laufen ausschließlich über echte CC-Lanes (LaneSnapshotPayload.cc).
}

// MARK: - LaneSnapshotPayload

/// Typsichere, lane-kind-abhängige Payload eines `LaneSnapshot`
/// (Lane Slice 6 — Snapshot-Payload als discriminated union).
///
/// Ersetzt die vorherige flache Mischform auf `LaneSnapshot`, in der
/// `steps` / `ccValues` / `ccNumber` / `ccIsMuted` nebeneinander lagen
/// und pro Kind je ein Teil per Sentinel leer gesetzt wurde. Die
/// Diskriminierung ist jetzt im Typsystem verankert — der RT-Pfad
/// switcht direkt über diesen Enum und kann die Sentinel-Guards
/// entfallen lassen.
///
/// **D9-Immutabilität:** alle assoziierten Werte sind Werttypen mit
/// ausschließlich `let`-Semantik (Arrays, Ints, Bool). Nach Publish
/// nicht mehr veränderbar — identische Garantie wie bei den früheren
/// flachen `let`-Feldern.
enum LaneSnapshotPayload: Sendable {
    /// Step-Lane: klassische Noten-/Gate-/Ratchet-Steps.
    /// Die Array-Länge entspricht `LaneSnapshot.stepCount`.
    case step(steps: [StepSnapshot])

    /// CC-Lane: pro-Step-CC-Werte + CC-Controller-Nummer + Mute.
    /// `values.count` entspricht `LaneSnapshot.stepCount`.
    case cc(values: [Int], number: Int, isMuted: Bool)
}

// MARK: - LaneSnapshot

/// Unveränderlicher Snapshot des Sequenzkerns (Lane-Modell v1).
/// Enthält ausschließlich Felder, die den Step-Ablauf beschreiben.
///
/// Lane Slice 6: Payload liegt jetzt in `payload: LaneSnapshotPayload`
/// als discriminated union. `kind` bleibt als schneller Diskriminator
/// für Display-/Logging-Pfade erhalten — Cache-freundlicher als ein
/// Enum-Unpack nur zum Typ-Check.
struct LaneSnapshot: Sendable {
    /// Lane-Typ-Diskriminator (Lane Slice 3).
    /// Spiegel von LaneData.kind; fließt via buildPatternSnapshot() in den RT-Pfad.
    /// Redundant zur Diskriminierung in `payload`, bleibt aber als schneller
    /// Kurzzugriff für Nicht-Hot-Path-Code erhalten.
    let kind:          LaneKind
    let stepCount:     Int             // 1…64
    let direction:     PlayDirection
    let pulsesPerStep: Double          // > 0, geclampt vor Speicherung
    /// Kind-abhängige Payload — Step-Steps oder CC-Werte/Nummer/Mute.
    let payload:       LaneSnapshotPayload
}

// MARK: - TrackSnapshot

/// Unveränderlicher Snapshot eines Tracks für einen Playback-Zyklus.
/// Container-Felder liegen direkt auf TrackSnapshot; der Sequenzkern wird
/// als verschachtelter `lane: LaneSnapshot` gehalten (Lane-Modell v1).
/// Alle Werte sind geclampt — der Tick-Thread darf blind darauf vertrauen.
/// Ziel einer CC-Lane im gehosteten Instrument (v1.13.9): Parameter-Adresse und der
/// Wertebereich, auf den die Lane-Werte 0 … 127 abgebildet werden.
struct ParameterTarget: Sendable, Equatable {
    let address: UInt64
    let min: Float
    let max: Float
}

struct TrackSnapshot: Sendable {
    let lane:          LaneSnapshot
    let midiChannel:   Int             // 1…16
    let isMuted:       Bool
    let isSolo:        Bool
    let timingOffset:  Double
    /// Runtime-Bindung (v1.12.19): Index des `TrackRuntime`-Slots, den dieser Track im
    /// Tick-Thread benutzt (−1 = kein Slot frei → Track bleibt stumm). Vom Main-Thread
    /// pro Track-Identität vergeben und über Snapshots hinweg stabil gehalten.
    let slot:          Int
    /// Generation der Slot-Vergabe. Weicht sie von `TrackRuntime.epoch` ab, beginnt der
    /// Tick-Thread für diesen Slot mit einer frischen Runtime. Topologie und Runtime-
    /// Zuordnung reisen damit IM Snapshot — atomar mit ihm, ohne getrennte Mailbox.
    let epoch:         UInt32
    /// Ausgang (v1.13.0): −1 = externe MIDI-Ausgabe (CoreMIDI), sonst der Slot der
    /// Ereigniswarteschlange eines gehosteten Instruments (`InstrumentRack.queues`).
    let route:         Int
    /// Belegung des Ausgangs-Slots beim Snapshot-Bau (v1.13.13). Ereignisse tragen sie;
    /// eine spätere Belegung (anderes Instrument im selben Slot) verwirft sie.
    let routeEpoch:    UInt32
    /// CC-Lane mit Instrument-Parameter als Ziel; nil = kein Parameterziel aufgelöst.
    let parameter:     ParameterTarget?
    /// CC-Lane hat ein Parameterziel, das sich nicht auflösen lässt (Instrument lädt noch,
    /// anderes Instrument, Parameter fehlt): die Lane sendet dann NICHTS — nicht still
    /// MIDI-CC statt des gewählten Parameters (v1.13.13).
    let ccUnresolved:  Bool

    init(lane: LaneSnapshot, midiChannel: Int, isMuted: Bool, isSolo: Bool,
         timingOffset: Double, slot: Int = -1, epoch: UInt32 = 0, route: Int = -1,
         routeEpoch: UInt32 = 0, parameter: ParameterTarget? = nil, ccUnresolved: Bool = false) {
        self.parameter = parameter
        self.routeEpoch = routeEpoch
        self.ccUnresolved = ccUnresolved
        self.lane = lane; self.midiChannel = midiChannel; self.isMuted = isMuted
        self.isSolo = isSolo; self.timingOffset = timingOffset
        self.slot = slot; self.epoch = epoch; self.route = route
    }
}

// MARK: - PatternSnapshot

/// Snapshot des aktiven Patterns.
struct PatternSnapshot: Sendable {
    let tracks:  [TrackSnapshot]
    let hasSolo: Bool              // vorberechnet — kein contains() im Hot Path
}

// MARK: - PlaybackStateBundle

/// Atomares Bündel aus Pattern-Snapshot, BPM und Swing.
/// Wird in einem einzigen Lock-Zugriff gelesen — kein doppeltes Locken.
/// BPM und Swing sind Transport-/Editor-State, kein Pattern-Inhalt, daher
/// konzeptionell getrennt, aber technisch im selben Bundle, damit der
/// Tick-Thread pro Tick nur einen atomaren Load braucht.
///
/// RT-1 (Playback-State-Ownership): `swing` liegt seit v1.12.2 hier statt
/// per `@Published`-Read (`presetEditorState.swing`) im Tick-Thread gelesen
/// zu werden. Der frühere Direktzugriff war ein Cross-Thread-Datenrennen
/// (Main-Thread schreibt, Tick-Thread liest ungeschützt). Publiziert wird
/// bei Swing-Änderung über den `presetEditorState.$swing`-Sink.
struct PlaybackStateBundle: Sendable {
    let snapshot: PatternSnapshot
    let bpm:      Double
    let swing:    Double
    /// Aktivierungsnummer des Patterns in `snapshot`. Erhöht sich bei jedem vollzogenen
    /// Patternwechsel und jedem Session-Start.
    let serial:   Int
    /// Vorgemerktes Pattern (quantisierter Wechsel), bereits vollständig gebaut. Der
    /// Tick-Thread wechselt an der Track-0-Grenze selbst darauf (Aktivierung `serial + 1`)
    /// — der erste Step des neuen Patterns fällt exakt auf die Grenze, ohne Main-Hop.
    let queued:   PatternSnapshot?

    init(snapshot: PatternSnapshot, bpm: Double, swing: Double,
         serial: Int = 0, queued: PatternSnapshot? = nil) {
        self.snapshot = snapshot; self.bpm = bpm; self.swing = swing
        self.serial = serial; self.queued = queued
    }
}

// MARK: - PlaybackBundleBox

/// Reference-type wrapper for PlaybackStateBundle — required for E3 lock-free atomic exchange.
///
/// Because PlaybackStateBundle is a value type (struct), it cannot be stored directly in an
/// atomic pointer. This thin class box gives it a stable object identity that can be referenced
/// via `Unmanaged<PlaybackBundleBox>` as a raw `Int` in `ManagedAtomic<Int>`.
///
/// `@unchecked Sendable`: intentionally read from the audio thread without a lock.
/// Written only by the Main thread (indirectly, by publishing a new box). RT-3
/// (v1.12.5): der Single-Reader-Hazard-Pointer in SequencerEngine garantiert
/// formal — preemptions-unabhängig, nicht mehr zeitbasiert — dass der Main-Thread
/// eine Box nie freigibt, solange der Tick-Thread sie dereferenziert. Der Pointer
/// ist damit immer gültig, wenn der Tick-Thread ihn liest.
///
/// RT-3a (v1.12.6): Die Garantie galt ursprünglich nur gegen `publishSnapshot()`.
/// `stop()` riss Hazard-Pointer und Box-Referenzen bedingungslos ab — sicher für
/// den internen Clock-Thread (durch `audioClock.stop()` synchron beendet), aber
/// nicht für einen bereits laufenden externen MIDI-Tick (eigener Thread, von
/// `audioClock.stop()` nicht erfasst). `stop()` beweist jetzt per `activeTick`-
/// Atomic (bounded Spin), dass kein Tick — intern oder extern — mehr läuft,
/// bevor es die Box freigibt. Die Lifetime-Garantie gilt damit gegen jeden
/// Aufrufer, nicht mehr nur gegen den Publish-Pfad.
final class PlaybackBundleBox: @unchecked Sendable {
    let bundle: PlaybackStateBundle
    init(_ bundle: PlaybackStateBundle) { self.bundle = bundle }
    #if DEBUG
    /// S01: Test-Sonde — feuert im deinit auf dem freigebenden Thread (Nachweis „nicht RT“).
    var _deinitProbe: (() -> Void)?
    deinit { _deinitProbe?() }
    #endif
}

// MARK: - TrackRuntime

/// Mutabler Laufzeitzustand eines Tracks — ausschließlich im Tick-Thread.
/// Niemals von der UI gelesen oder geschrieben.
///
/// v1.12.19: Die Runtimes liegen in einem festen Slot-Block der SequencerEngine, den
/// ausschließlich der Tick-Thread anfasst. Welcher Track welchen Slot benutzt und ob er
/// frisch beginnt, steht im Snapshot (`TrackSnapshot.slot`/`.epoch`). Strukturänderungen
/// und Patternwechsel brauchen damit keine eigene Übergabe an den Tick-Thread mehr
/// (früher: Array + Command-Mailbox, Befunde K1/B3).
///
/// currentStep = -1 bedeutet "noch nicht gestartet".
/// Beim ersten Advance wird -1 → 0 (Forward/PingPong) bzw. → n-1 (Reverse),
/// sodass der erste ausgelöste Step korrekt Step 0 (bzw. Step n-1 bei Reverse) ist.
/// (B2 — Off-by-one-Fix)
struct TrackRuntime {
    var currentStep:       Int    = -1
    var pulseAccumulator:  Double = 0.0
    var pingPongForward:   Bool   = true
    /// Slot-Generation, zu der dieser Zustand gehört (vgl. `TrackSnapshot.epoch`).
    var epoch:             UInt32 = 0
    /// Frische Runtime: der erste Tick löst sofort den ersten Step aus (statt erst nach
    /// einer vollen Step-Länge). Damit fällt Step 1 auf den ersten Clock-Puls nach
    /// MIDI-Start bzw. exakt auf die Patterngrenze.
    var armed:             Bool   = true
}
