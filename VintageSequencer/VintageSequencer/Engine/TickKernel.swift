import Foundation
import CoreMIDI
import Atomics

// MARK: - TickKernel (v1.16.0, Codex M6)
//
// Besitzer des Tick-Pfads: Tick-Zutritt, Tick-eigener Zustand (Runtime-Slots, PRNG,
// Aktivierung, Puls, Sitzung/Plan-Linie, Verspätung), die Rückkanal-Atomics an Main und die
// Tick-Funktionen (`clockTick` INT, `tick` EXT, `advanceSteps`). Vorher Teil von
// `SequencerEngine`; Verhalten unverändert.
//
// Eigentum: alles mit `rt`-Präfix und der PRNG gehört dem Inhaber des Tick-Zutritts
// (`enterTick`/`exitTick`). Main liest nur die Atomics und schreibt nur die Transport-
// Spiegel (`isPlayingRT`, `clockIsInternal`, `midiStartPending`). Die Abhängigkeiten sind
// unveränderliche Referenzen, in `init` (Main) übergeben; `displaySignal` setzt Main einmal,
// bevor der erste Tick laufen kann. Keine Allokation, kein Lock nach init.

/// Feste Rack-Blöcke für den Tick-Pfad. Die Zeiger gelten, solange `owner` lebt; der Kern
/// hält ihn deshalb stark (kein Zugriff über ihn).
struct TickOutputs {
    let queues: UnsafeMutablePointer<Unmanaged<AUEventQueue>>
    /// Warteschlangen der Effekte (v1.17.1), erreicht über `ParameterTarget.queue`.
    let effectQueues: UnsafeMutablePointer<Unmanaged<AUEventQueue>>
    let loopCores: UnsafeMutablePointer<Unmanaged<AudioLoopCore>>
    let barClock: BarClock
    /// Host-Takt der Plug-ins (v1.17.2): Anker je Puls.
    let hostSync: HostSync
    let owner: AnyObject
}

final class TickKernel {
    /// Größe des Runtime-Slot-Blocks.
    static let runtimeSlotCount = 256
    private let publisher: SnapshotPublisher
    private let noteOut: NoteOutput
    /// Echtzeit-Zugang zum Rack: Warteschlangen, Loop-Kerne, Taktanker — sonst nichts.
    private let out: TickOutputs
    private let midi: MIDIManager
    private let displayBuffer: DisplayEventBuffer
    private let engineEventBuffer: EngineEventBuffer
    /// Weckruf des Display-Drains (Main legt ihn in init an).
    var displaySignal: DispatchSourceUserDataOr?

    init(publisher: SnapshotPublisher, noteOut: NoteOutput, outputs: TickOutputs, midi: MIDIManager,
         displayBuffer: DisplayEventBuffer, engineEventBuffer: EngineEventBuffer) {
        self.publisher = publisher
        self.noteOut = noteOut
        self.out = outputs
        self.midi = midi
        self.displayBuffer = displayBuffer
        self.engineEventBuffer = engineEventBuffer
    }

    deinit {
        rtRuntimes.deinitialize(count: Self.runtimeSlotCount); rtRuntimes.deallocate()
    }

    // MARK: Transport-Spiegel (Main schreibt, Tick liest — RT-1, Arch-Slice-16b)

    /// Exklusiver Tick-Zutritt (RT-3a, seit v1.12.19 als CAS — siehe `enterTick()`):
    /// true, solange ein Tick läuft — vom Zutritt bis nach dem letzten MIDI-Send dieses
    /// Ticks, gleich ob er vom internen Clock-Thread oder vom MIDI-Read-Thread kommt.
    /// stop() wartet auf false, bevor es Snapshot-Box oder Notenbuch anfasst.
    let activeTick       = ManagedAtomic<Bool>(false)
    /// Spiegel von isPlaying (Dekker-Partner von `activeTick`).
    let isPlayingRT      = ManagedAtomic<Bool>(false)
    /// Spiegel von (clockMode == .internal).
    let clockIsInternal  = ManagedAtomic<Bool>(true)
    /// 0xFA mit dem ersten 0xF8 senden (Arch-Slice-16b): Main setzt, `clockTick` konsumiert.
    let midiStartPending = ManagedAtomic<Bool>(false)

    // MARK: Tick-eigener Zustand

    /// Fester Block von `runtimeSlotCount` TrackRuntimes (v1.12.19). Main vergibt nur Slot +
    /// Epoche im Snapshot; nur der Tick liest/schreibt den Block.
    let rtRuntimes: UnsafeMutablePointer<TrackRuntime> = {
        let p = UnsafeMutablePointer<TrackRuntime>.allocate(capacity: TickKernel.runtimeSlotCount)
        p.initialize(repeating: TrackRuntime(), count: TickKernel.runtimeSlotCount)
        return p
    }()
    /// RT-4b: alloc-freier PRNG (Random-Direction, Probability-Gate). Seed einmalig auf Main.
    var rtRandom = RTRandom(seed: UInt64.random(in: .min ... .max))
    /// Aktivierung, die der Tick gerade spielt.
    private var rtActiveSerial = 0
    /// Pulse seit Sitzungsbeginn (erster Tick = 0).
    private var rtPulse = 0
    /// Musikalischer Abschnitt (v1.18.23, Konzept Taktart und Zeit 4.1, Codex KT-01): Taktart,
    /// Ursprung (Puls, absoluter Takt) und Aktivierung des laufenden Patterns. Taktgrenzen
    /// liegen bei `rtOrigin + k · rtPulsesPerBar`, Takt = `rtBar0 + k` — nie `pulse % ppb` ab
    /// Sitzungsbeginn. Nur der Tick schreibt; HostSync und Taktanker bekommen ihn je Puls.
    private var rtMeter = TimeSignature.common
    private var rtPulsesPerBar = 96
    private var rtOrigin = 0
    private var rtBar0 = 0
    private var rtActivation = 0
    private var rtPattern = -1
    /// Sitzung und Plan-Linie, unter denen der Tick gerade spielt.
    private var rtSession: UInt32 = 0
    private var rtPlanID:  UInt32 = 0
    private var rtSongEndSignaled = false
    /// Verschiebung des zuletzt verarbeiteten Ticks (`clockTick` liest sie für das 0xF8
    /// desselben Ticks).
    private var rtLastLateShift: UInt64 = 0

    // MARK: Rückkanal an Main (Atomics)

    /// Letzter selbst vollzogener Wechsel (v1.15.1/v1.15.2): Bit 56–63 Sitzung, 44–55
    /// Plan-Linie, 32–43 Aktivierung (je niederwertige Bits), 0–31 Puls. Ein Atomic, damit
    /// Main Aktivierung und Puls desselben Wechsels liest. Verlustfrei; das Ring-Event ist
    /// nur der Weckruf.
    let rtSwitchStamp = ManagedAtomic<UInt64>(0)
    static func switchStamp(session: UInt32, plan: UInt32, serial: Int, pulse: Int) -> UInt64 {
        UInt64(session & 0xFF) << 56 | UInt64(plan & 0xFFF) << 44
            | UInt64(UInt32(truncatingIfNeeded: serial) & 0xFFF) << 32
            | UInt64(UInt32(truncatingIfNeeded: pulse))
    }
    /// Verspätete Ticks seit Start (Diagnose).
    let rtLateTicks        = ManagedAtomic<Int>(0)
    /// Erschöpfter Song-Horizont und Planabweichungen (Tick zählt, Main meldet).
    let rtHorizonUnderruns = ManagedAtomic<Int>(0)
    let rtPlanConflicts    = ManagedAtomic<Int>(0)
    /// Songende erreicht (`stopAtPulse`); Main hält auf `rtSongEndHost` an.
    let rtSongEnded   = ManagedAtomic<Bool>(false)
    let rtSongEndHost = ManagedAtomic<UInt64>(0)
    /// Geclampte Note/CC-Timestamps bzw. verschobene 0xF8 — kumulativ, diagnostisch.
    let clampCountNotes = ManagedAtomic<Int>(0)
    let clampCountClock = ManagedAtomic<Int>(0)
    /// Zeitpunkt des letzten externen Ticks (Off-Wächter).
    let lastExtTickHost = ManagedAtomic<UInt64>(0)

    /// 1 ms in Host-Ticks: Boden für Future-Timestamps.
    private static let safetyOffsetMach: MIDITimeStamp = HostTime.nanosToMachTime(1_000_000)

    #if DEBUG
    /// Welche Box der letzte Tick dereferenziert hat (RT-3).
    private(set) var _rt3LastTickBoxRaw: Int = 0
    /// Einmaliger Pause-Hook mitten in advanceSteps() (RT-3a), selbst-löschend.
    var _rt3aPausePoint: (() -> Void)?
    /// Sendeentschlüsse für 0xF8/0xFA in clockTick (S01).
    private(set) var _s01ClockSendCount = 0
    private(set) var _s01StartSendCount = 0
    /// Vom Tick gesendete Songende-Abschlüsse (0xFC) — je Sitzung höchstens einer.
    private(set) var _songEndStopCount = 0
    #endif

    // MARK: Tick-Zutritt (v1.12.19 — ein Tick zur Zeit, nur während Wiedergabe)
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
    let rejectedTicks = ManagedAtomic<Int>(0)

    @inline(__always)
    func enterTick() -> Bool {
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
    func exitTick() {
        activeTick.store(false, ordering: .sequentiallyConsistent)
    }

    /// Externer Clock-Puls (MIDI-Read-Thread). Im EXT-Modus erzeugen wir keine ausgehende Clock.
    func tick(scheduledAt: MIDITimeStamp) {
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

    /// Neuer Abschnitt beim Patternwechsel auf Puls `pulse` (Tick-Thread).
    ///
    /// Mit dem Wechsel beginnt ein neuer Abschnitt in der Taktart des neuen Patterns und ein
    /// neuer Takt (Konzept 4.2). Auf einer Taktgrenze (Song immer) zählt die Taktnummer einmal
    /// weiter, nie doppelt; mitten im Takt (Ende Spur 1) ist der alte Takt verkürzt und der neue
    /// beginnt hier (v1.18.24; bis v1.18.23 blieb das Raster stehen).
    @inline(__always)
    private func openSection(at pulse: Int, meter: TimeSignature) {
        rtActivation &+= 1
        let rel = pulse &- rtOrigin
        guard rel >= 0 else { return }
        rtBar0 &+= rel / rtPulsesPerBar + (rel % rtPulsesPerBar == 0 ? 0 : 1)
        rtOrigin = pulse
        rtMeter = meter
        rtPulsesPerBar = max(1, meter.pulsesPerBar)
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
        guard rt.pulseAccumulator + 1.0 >= t0.lane.pulses(ofStep: rt.currentStep) else { return false }
        var rng = rtRandom
        return Self.advance(&rt, snap: t0, rng: &rng) == 0
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
        // beweis: siehe `SnapshotPublisher`).
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
        let acquired = publisher.acquire()
        guard case let .protected(raw) = acquired,
              let ptr = UnsafeRawPointer(bitPattern: raw)
        else {
            if case .exhausted = acquired {
                // Sichtbarer Fehlerpfad: wartefreier Zähler (einziger Schreiber) + Wecken
                // des Display-Drains; Main spiegelt ihn in clockDiagnostics.
                publisher.recordAcquireFailure()
                displaySignal?.or(data: 1)
            }
            return false
        }
        // Hazard am Tick-Ende freigeben — deckt alle weiteren Rückkehrpfade ab.
        // Reihenfolge: `bundle`/`snap` (lexikalisch später deklariert) enden vor diesem defer;
        // die Reader-Kopien der Arrays sind damit vor dem Hazard-Clear freigegeben.
        defer {
            publisher.release()
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
        // Neue Sitzung (v1.15.2): an der Sitzungsnummer erkannt, nicht an der Aktivierung —
        // die kann ein ohne Main vollzogener Songwechsel schon erreicht haben (Codex R1).
        if bundle.session != rtSession {
            rtSession = bundle.session
            rtPulse = 0
            rtSongEndSignaled = false
            rtMeter = bundle.snapshot.meter
            rtPulsesPerBar = max(1, rtMeter.pulsesPerBar)
            rtOrigin = 0; rtBar0 = 0; rtActivation = 1
            out.barClock.beginSession()
            out.hostSync.beginSession(bundle.session, meter: bundle.meter)
            rtActiveSerial = bundle.serial
            rtPlanID = bundle.planID
        }
        var snap = bundle.snapshot
        // `holding`: der erreichte Schritt gehört zu einer abgelösten Plan-Linie — weiter
        // spielen, nicht weiter wechseln, bis Main nachgezogen hat (Codex R6).
        var holding = false
        let k = rtActiveSerial &- bundle.serial
        if k <= 0 {
            rtActiveSerial = bundle.serial
            rtPlanID = bundle.planID
        } else if bundle.planID == rtPlanID {
            if k <= bundle.planCount, let q = bundle.plannedSnapshot(k) { snap = q } else { holding = true }
        } else {
            let kp = rtActiveSerial &- bundle.prevBase
            if bundle.prevPlanID == rtPlanID, kp >= 1, kp <= bundle.prevSteps.count {
                snap = bundle.prevSteps[kp - 1]
            } else {
                rtPlanConflicts.wrappingIncrement(ordering: .relaxed)
            }
            holding = true
        }
        let pulse = rtPulse
        rtPulse &+= 1
        // Verspäteter Tick (v1.15.2, Codex T2): EINE Verschiebung für alle Wege dieses Ticks —
        // Noten, CCs, Taktanker, Loop-Fenster, Songende und das ausgehende 0xF8 (`clockTick`
        // liest `rtLastLateShift`); keiner verliert seinen Puls. Darüber hinaus gibt es genau
        // einen Einzelboden: ein Ereignis, das Overshoot-Korrektur oder negativer Spuroffset
        // trotzdem vor `nowSafe` legen würde, wird auf `nowSafe` begrenzt (gezählt in
        // `clampCountNotes`). Bei fristgerechten Ticks tritt das nicht ein — beide Vorläufe
        // enthalten Overshoot (ein Intervall) und die Offsetreserve (v1.16.1, Codex V16-3).
        let nowSafe = mach_absolute_time() + Self.safetyOffsetMach
        let lateShift = tickTime < nowSafe ? nowSafe - tickTime : 0
        let outTime = tickTime &+ lateShift
        rtLastLateShift = lateShift
        if lateShift > 0 { rtLateTicks.wrappingIncrement(ordering: .relaxed) }
        // Reihenfolge des Grenzticks (v1.18.23, Konzept 4.2): erst Songende bzw. Wechsel
        // entscheiden und den Abschnitt bestimmen, dann Taktanker, Host-Takt, Loop-Fenster und
        // Noten mit demselben `outTime` veröffentlichen. Am Songende kein neuer Abschnitt.
        let songOver = bundle.stopAtPulse >= 0 && pulse >= bundle.stopAtPulse
        let ppb = rtPulsesPerBar
        // Wechselgrenze: im Song der vorgegebene Takt-Puls, sonst das Ende von Track 0. Liegt
        // der Puls schon zurück (Song während des Laufs gekürzt), an der nächsten Taktgrenze.
        // Nächster geplanter Wechsel (Song: mehrere hintereinander ohne Main, v1.15.1).
        let nextK = rtActiveSerial &- bundle.serial &+ 1
        // Horizont erschöpft (Codex R7): der nächste Wechsel wäre fällig, Main hat keinen
        // weiteren geplant. Das Pattern spielt weiter; gezählt und von Main gemeldet.
        if !songOver, !holding, nextK == bundle.planCount &+ 1, bundle.planEndPulse >= 0,
           pulse >= bundle.planEndPulse, (pulse &- bundle.planEndPulse) % ppb == 0 {
            rtHorizonUnderruns.wrappingIncrement(ordering: .relaxed)
        }
        if !songOver, !holding, nextK >= 1, nextK <= bundle.planCount, let q = bundle.plannedSnapshot(nextK) {
            let at = bundle.switchPulse(nextK)
            let atBoundary = at >= 0
                ? pulse >= at && (pulse &- at) % ppb == 0
                : nextK == 1 && (bundle.switchOnBar
                    ? (pulse &- rtOrigin) % ppb == 0          // nächster Taktstrich (E3)
                    : track0WillWrap(in: snap))
            if atBoundary {
                rtActiveSerial = bundle.serial &+ nextK
                rtSwitchStamp.store(Self.switchStamp(session: rtSession, plan: rtPlanID,
                                                     serial: rtActiveSerial, pulse: pulse), ordering: .releasing)
                engineEventBuffer.pushPatternSwitch(patternIdx: 0)   // Weckruf für Main
                displaySignal?.or(data: 1)
                snap = q
                openSection(at: pulse, meter: q.meter)
                // Ein im Plan wiederkehrendes Pattern teilt Slots und Epochen mit seinem
                // früheren Lauf: frisch beginnen (Tick-eigene Runtime, keine Allokation).
                if at >= 0 {
                    for t in q.tracks where t.slot >= 0 {
                        (rtRuntimes + t.slot).pointee = TrackRuntime(epoch: t.epoch)
                    }
                }
            }
        }
        rtPattern = snap.pattern
        // Taktanker für Audio-Loops (v1.15.0): Takt n beginnt auf diesem Tick — gezählt ab dem
        // Ursprung des Abschnitts.
        let rel = pulse &- rtOrigin
        if rel >= 0, rel % rtPulsesPerBar == 0 {
            out.barClock.publish(bar: rtBar0 &+ rel / rtPulsesPerBar, host: outTime)
        }
        // Host-Takt der Plug-ins (v1.17.2): Puls, Zeitpunkt, Tempo und Abschnitt — auf demselben
        // Zeitpunkt. Ab dem Endpuls kein Anker mehr: das Ende setzt der Tick selbst (unten);
        // spätere Ticks dürfen die Position nicht weiterbewegen (v1.17.6, Codex A17-01).
        if !songOver {
            let nk = rtActiveSerial &- bundle.serial &+ 1
            var nextPattern = -1, nextAt = -1
            if !holding, nk >= 1, nk <= bundle.planCount, let q = bundle.plannedSnapshot(nk) {
                nextPattern = q.pattern; nextAt = bundle.switchPulse(nk)
            }
            out.hostSync.publish(pulse: pulse, host: outTime, bpm: bundle.bpm,
                                 section: HostSync.Section(meter: rtMeter, originPulse: rtOrigin,
                                                           originBar: rtBar0, activation: rtActivation,
                                                           pattern: rtPattern, nextPattern: nextPattern,
                                                           nextSwitchPulse: nextAt))
        }
        // Songende (v1.14.0): ab `stopAtPulse` kein neuer Anschlag mehr; Main hält an.
        // Fällige Offs laufen weiter aus.
        if songOver {
            // Ende zur geplanten Zeit dieses Pulses, nicht zur Reaktionszeit von Main (Codex
            // H5): Loop-Fenster schließen hier, Main beendet die Taktanker auf `rtSongEndHost`.
            if !rtSongEndSignaled {
                rtSongEndSignaled = true   // einmal je Sitzung: Main merkt den Endpuls vor
                for i in 0..<InstrumentRack.maxChannels {
                    out.loopCores[i]._withUnsafeGuaranteedRef { $0.closeWindow(at: outTime) }
                }
                // Abschluss aller Wege auf demselben Zeitpunkt, ohne Main (Codex V16-1):
                // klingende Noten (MIDI und Instrumente) enden spätestens jetzt, 0xFC folgt
                // 1 ns danach. Main hält später nur noch Anzeige und Transport an und sendet
                // für das Songende weder Flush noch ein zweites 0xFC.
                noteOut.endAllNotes(at: outTime)
                midi.sendStopRT(at: outTime &+ 1)
                // Plug-in-Transport steht auf demselben Zeitpunkt (A17-01) — Main nur Nachbereitung.
                out.hostSync.end(at: outTime)
                #if DEBUG
                _songEndStopCount &+= 1
                #endif
                rtSongEndHost.store(outTime, ordering: .relaxed)
                rtSongEnded.store(true, ordering: .releasing)
            }
            displaySignal?.or(data: 1)
            noteOut.flushDueNoteOffs(upTo: tickTime)
            return true
        }
        let pulseDuration = 60.0 / (bundle.bpm * 24.0)
        // Safety-Clamp-Boden je Ereignis (`nowSafe`, oben): greift nur noch für Ereignisse,
        // die die Overshoot-Korrektur oder ein negativer Spuroffset vor „jetzt + 1 ms" legt.

        // Audio-Loop-Fenster: ein Puls plus ein Viertel Reserve (Jitter externer Clock). Jeder
        // Kern, den dieser Tick nicht meldet (stumm, nicht im Pattern, anderer Ausgang),
        // schließt sein Fenster exakt auf tickTime — die Reserve reicht damit nie über eine
        // Mute-, Pattern- oder Songgrenze (Codex H5/T6).
        let loopSpan = HostTime.nanosToMachTime(UInt64(pulseDuration * 1.25 * 1_000_000_000))
        var loopMarked: UInt64 = 0          // ein Bit je Kanal (maxChannels ≤ 64)
        for trackSnap in snap.tracks where trackSnap.isAudioLoop {
            let muted = trackSnap.isMuted || (snap.hasSolo && !trackSnap.isSolo)
            guard !muted, trackSnap.route >= 0, trackSnap.route < InstrumentRack.maxChannels else { continue }
            out.loopCores[trackSnap.route]._withUnsafeGuaranteedRef {
                $0.markActive(tickTime: outTime, spanTicks: loopSpan, epoch: trackSnap.routeEpoch)
            }
            loopMarked |= 1 << UInt64(trackSnap.route)
        }
        for i in 0..<InstrumentRack.maxChannels where loopMarked & (1 << UInt64(i)) == 0 {
            out.loopCores[i]._withUnsafeGuaranteedRef { $0.closeWindow(at: outTime) }
        }
        for trackIdx in snap.tracks.indices {
            let trackSnap = snap.tracks[trackIdx]
            if trackSnap.isAudioLoop { continue }   // keine Steps; Fenster oben gemeldet
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
                // Länge des klingenden Steps (Gruppe: je Step verschieden, v1.18.30).
                let pps = trackSnap.lane.pulses(ofStep: runtime.pointee.currentStep)
                guard runtime.pointee.pulseAccumulator >= pps else { continue }
                runtime.pointee.pulseAccumulator -= pps
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
            let overshootMach  = HostTime.nanosToMachTime(UInt64(overshootNS))
            let exactStepTime  = outTime > overshootMach ? outTime - overshootMach : outTime

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

                let stepDuration = trackSnap.lane.pulses(ofStep: stepIdx) * pulseDuration
                let isOddStep    = (stepIdx % 2 == 1)
                let swingDelay   = isOddStep
                    ? stepDuration * ((bundle.swing / 100.0) - 0.5) * 0.66
                    : 0.0
                let offset = trackSnap.timingOffset

                // Vorzeichenbehaftet (v1.15.2, Codex T8): ein negativer Spuroffset zieht vor;
                // begrenzt wird erst an der echten Frist `nowSafe`.
                let ccTimeRaw  = HostTime.shifted(exactStepTime, bySeconds: swingDelay + offset)
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
                    if p.queue >= 0 {
                        // Effekt im Kanal (v1.17.1): eigene Warteschlange und Belegung.
                        out.effectQueues[p.queue]._withUnsafeGuaranteedRef {
                            _ = $0.pushParameterFromTick(address: p.address, value: v, at: ccTime, epoch: p.epoch)
                        }
                    } else {
                        out.queues[trackSnap.route]._withUnsafeGuaranteedRef {
                            _ = $0.pushParameterFromTick(address: p.address, value: v, at: ccTime,
                                                         epoch: trackSnap.routeEpoch)
                        }
                    }
                } else {
                    noteOut.outCC(route:   trackSnap.route,
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

            let stepDuration = trackSnap.lane.pulses(ofStep: stepIdx) * pulseDuration
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
            // Halten über folgende Steps (vorwärts, wie `holdSpan`); Drone: ganzer Durchlauf.
            var heldPulses = 0.0
            if step.holdSpan > 0 {
                for j in 1...step.holdSpan { heldPulses += trackSnap.lane.pulses(ofStep: stepIdx + j) }
            }
            let cycleSeconds  = trackSnap.lane.cyclePulses() * pulseDuration
            let capturedNotes = step.notes
            let capturedVel   = step.velocity
            let capturedCh    = trackSnap.midiChannel
            let capturedGate  = step.gate

            for r in 0..<ratchets {
                let onDelay  = swingDelay + offset + Double(r) * rInterval   // vorzeichenbehaftet (T8)
                let isChord  = capturedNotes.count > 1
                let effectiveGate = ratchets > 1 ? min(capturedGate, 1.0) :
                                    isChord      ? max(capturedGate, 0.5)  : capturedGate
                // Gehaltene Steps: volle eigene Länge plus jede Halte-Step-Länge (bei „Gruppe"
                // die Längen der folgenden Steps), der letzte Abschnitt mit dem Gate dieses
                // Steps (höchstens legato).
                let heldSeconds = holdSteps > 0
                    ? heldPulses * pulseDuration + rInterval * min(effectiveGate, 1.0)
                    : rInterval * effectiveGate
                let offDelay = onDelay + (isDrone ? cycleSeconds : max(0.010, heldSeconds))

                let onTimeRaw = HostTime.shifted(exactStepTime, bySeconds: onDelay)
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
                    ? cycleSeconds + stepDuration * 0.5
                    : max(0.010, heldSeconds)
                let gateDurationMach = HostTime.nanosToMachTime(UInt64(gateSeconds * 1_000_000_000))
                offTime = onTime + gateDurationMach

                for note in capturedNotes {
                    noteOut.sendNote(route: trackSnap.route, epoch: trackSnap.routeEpoch,
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
        noteOut.flushDueNoteOffs(upTo: tickTime)
        return true
    }

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
        //    v1.15.2 (Codex T2): ein verspäteter Tick wird um dieselbe Verschiebung wie seine
        //    Noten und Taktanker später gesendet, nicht verworfen — ein pulszählender
        //    Empfänger verliert sonst dauerhaft seine Taktposition. Die ClockSource verankert
        //    nach mehr als zwei Intervallen Rückstand neu; mehr als zwei eng aufeinander
        //    folgende Pulse entstehen dadurch nicht. `clampCountClock` zählt verschobene Pulse.
        let shift = rtLastLateShift
        if shift > 0 { clampCountClock.store(clampCountClock.load(ordering: .relaxed) &+ 1, ordering: .relaxed) }
        let safeTickTime = timestamp &+ shift
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
