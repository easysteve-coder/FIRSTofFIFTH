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
    /// Halten (v1.13.16): schlägt nicht an; der Ton des vorherigen Steps läuft weiter.
    var isHold:      Bool = false
    /// Anzahl der direkt folgenden aktiven Halte-Steps (Vorwärtsrichtung, zyklisch), um
    /// deren Länge dieser Step klingt. Auf Main vorberechnet, der Tick-Pfad liest nur.
    var holdSpan:    Int  = 0
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
    /// Steplänge „Gruppe" (v1.18.30): Länge je Step zyklisch aus der Gruppierung; leer =
    /// alle Steps `pulsesPerStep`.
    var groups:        StepGroups = StepGroups()

    /// Pulse von Step `k` (Tick-Pfad, ohne Allokation).
    @inline(__always)
    func pulses(ofStep k: Int) -> Double {
        groups.count == 0 ? pulsesPerStep : groups.pulses(at: k)
    }
    /// Pulse eines ganzen Durchlaufs (Drone).
    @inline(__always)
    func cyclePulses() -> Double {
        guard groups.count > 0 else { return pulsesPerStep * Double(stepCount) }
        var sum = 0.0
        for k in 0..<stepCount { sum += groups.pulses(at: k) }
        return sum
    }
}

/// Bis zu 8 Gruppenlängen in Pulsen als festes Tupel (v1.18.30): der Tick liest sie ohne
/// Allokation und ohne Array-Zugriff über Referenzen.
struct StepGroups: Sendable {
    private(set) var count = 0
    private var p: (Double, Double, Double, Double, Double, Double, Double, Double) = (0, 0, 0, 0, 0, 0, 0, 0)

    init() {}
    /// Main: Längen in Pulsen (> 0), höchstens 8 werden übernommen.
    init(_ pulses: [Double]) {
        count = min(8, pulses.count)
        for (i, v) in pulses.prefix(8).enumerated() {
            let x = max(0.001, v)
            switch i {
            case 0: p.0 = x
            case 1: p.1 = x
            case 2: p.2 = x
            case 3: p.3 = x
            case 4: p.4 = x
            case 5: p.5 = x
            case 6: p.6 = x
            default: p.7 = x
            }
        }
    }

    /// Länge der Gruppe für Step `k` (zyklisch, auch für negative k). Nur mit count > 0.
    @inline(__always)
    func pulses(at k: Int) -> Double {
        let i = ((k % count) + count) % count
        switch i {
        case 0: return p.0
        case 1: return p.1
        case 2: return p.2
        case 3: return p.3
        case 4: return p.4
        case 5: return p.5
        case 6: return p.6
        default: return p.7
        }
    }
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
    /// Platz im Block `InstrumentRack.effectQueues` (v1.17.1); −1 = Instrument des Kanals.
    var queue: Int = -1
    /// Belegung dieses Platzes, für die geplant wird (nur bei `queue >= 0`).
    var epoch: UInt32 = 0
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
    /// Audio-Loop-Spur (v1.15.0): der Tick-Thread markiert nur das Zeitfenster, in dem der
    /// Loop-Kern `route` klingt; keine Steps, keine Ereignisse.
    let isAudioLoop:   Bool

    init(lane: LaneSnapshot, midiChannel: Int, isMuted: Bool, isSolo: Bool,
         timingOffset: Double, slot: Int = -1, epoch: UInt32 = 0, route: Int = -1,
         routeEpoch: UInt32 = 0, parameter: ParameterTarget? = nil, ccUnresolved: Bool = false,
         isAudioLoop: Bool = false) {
        self.isAudioLoop = isAudioLoop
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
    /// Taktart dieses Patterns (v1.18.23, Konzept Taktart und Zeit 4.1). Der Tick übernimmt sie
    /// beim Öffnen eines Abschnitts. Bis zur Taktart je Pattern (Paket 3) = Projekttaktart.
    let meter:   TimeSignature
    /// Pattern-Platz 0…15 (Anzeige des Abschnitts); −1 = unbekannt.
    let pattern: Int

    init(tracks: [TrackSnapshot], hasSolo: Bool, meter: TimeSignature = .common, pattern: Int = -1) {
        self.tracks = tracks; self.hasSolo = hasSolo; self.meter = meter; self.pattern = pattern
    }
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
    /// Taktart (v1.18.12). Der Tick-Thread übernimmt sie zu Beginn einer Sitzung; geändert
    /// wird sie nur im Stillstand.
    let meter:    TimeSignature
    /// Manueller Wechsel (`switchAtPulse` −1) auf dem nächsten Taktstrich statt am Ende von
    /// Spur 1 (v1.18.24, Entscheidung E3).
    let switchOnBar: Bool
    /// Aktivierungsnummer des Patterns in `snapshot`. Erhöht sich bei jedem vollzogenen
    /// Patternwechsel und jedem Session-Start.
    let serial:   Int
    /// Vorgemerktes Pattern (quantisierter Wechsel), bereits vollständig gebaut. Der
    /// Tick-Thread wechselt an der Track-0-Grenze selbst darauf (Aktivierung `serial + 1`)
    /// — der erste Step des neuen Patterns fällt exakt auf die Grenze, ohne Main-Hop.
    let queued:   PatternSnapshot?
    /// Song (v1.14.0): absoluter Puls (seit Sitzungsbeginn), auf dem zu `queued` gewechselt
    /// wird — eine Taktgrenze. −1 = an der Track-0-Grenze (manueller Wechsel).
    let switchAtPulse: Int
    /// Song-Ende ohne Loop: ab diesem Puls schlägt der Tick-Thread nichts mehr an. −1 = nie.
    let stopAtPulse:   Int
    /// Song (v1.15.1, Codex H3): weitere vorausgeplante Wechsel nach `queued`, in Reihenfolge.
    /// Der Tick-Thread geht sie ohne Main durch (Aktivierung `serial + 2`, `+ 3`, …); Main
    /// zieht nur nach und füllt den Horizont wieder auf.
    let later:         [PlanStep]

    struct PlanStep: Sendable {
        let snapshot:      PatternSnapshot
        let switchAtPulse: Int
    }

    /// Anzahl vorausgeplanter Wechsel (`queued` + `later`).
    var planCount: Int { queued == nil ? 0 : 1 + later.count }

    /// Snapshot der Aktivierung `serial + k` (0 = `snapshot`); nil außerhalb des Plans.
    @inline(__always)
    func plannedSnapshot(_ k: Int) -> PatternSnapshot? {
        if k == 0 { return snapshot }
        if k == 1 { return queued }
        return k - 2 < later.count && k >= 2 ? later[k - 2].snapshot : nil
    }

    /// Wechselpuls in die Aktivierung `serial + k` (k ≥ 1); −1 = an der Track-0-Grenze.
    @inline(__always)
    func switchPulse(_ k: Int) -> Int { k == 1 ? switchAtPulse : later[k - 2].switchAtPulse }

    // MARK: Identität (v1.15.2, Codex R1/R6/R7)

    /// Wiedergabe-Sitzung. Getrennt von der Aktivierungsnummer: eine neue Sitzung erkennt der
    /// Tick-Thread an diesem Wert, nicht an einer höheren `serial` (die kann ein schon ohne
    /// Main vollzogener Songwechsel ebenfalls erreicht haben).
    let session: UInt32
    /// Plan-Linie. Gleich bleibt sie, solange Main den Plan nur fortschreibt (Nachziehen,
    /// Horizont auffüllen); jede inhaltliche Änderung (Vormerkung, Song) bekommt eine neue.
    let planID: UInt32
    /// Vorgänger-Linie samt ihrer geplanten Snapshots: Hat der Tick-Thread unter ihr schon
    /// gewechselt, ohne dass Main es vor dem Bau dieses Bundles gesehen hat, spielt er den dort
    /// erreichten Schritt weiter und wartet auf Main, statt ihn dem neuen Plan zuzuordnen.
    let prevPlanID: UInt32
    let prevBase:   Int
    let prevSteps:  [PatternSnapshot]
    /// Puls, auf dem nach dem letzten geplanten Schritt der nächste Wechsel fällig wäre
    /// (−1 = keiner). Erreicht der Tick ihn ohne neuen Plan: Horizont erschöpft (gezählt).
    let planEndPulse: Int

    init(snapshot: PatternSnapshot, bpm: Double, swing: Double, meter: TimeSignature = .common,
         switchOnBar: Bool = false, serial: Int = 0, queued: PatternSnapshot? = nil,
         switchAtPulse: Int = -1, stopAtPulse: Int = -1, later: [PlanStep] = [],
         session: UInt32 = 0, planID: UInt32 = 0,
         prevPlanID: UInt32 = 0, prevBase: Int = 0, prevSteps: [PatternSnapshot] = [],
         planEndPulse: Int = -1) {
        self.snapshot = snapshot; self.bpm = bpm; self.swing = swing; self.meter = meter
        self.switchOnBar = switchOnBar
        self.serial = serial; self.queued = queued
        self.switchAtPulse = switchAtPulse; self.stopAtPulse = stopAtPulse
        self.later = queued == nil ? [] : later
        self.session = session; self.planID = planID
        self.prevPlanID = prevPlanID; self.prevBase = prevBase; self.prevSteps = prevSteps
        self.planEndPulse = planEndPulse
    }

    /// Alle geplanten Snapshots (für `prevSteps` des Nachfolgers). Main.
    var plannedSnapshots: [PatternSnapshot] {
        guard let q = queued else { return [] }
        return [q] + later.map(\.snapshot)
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
