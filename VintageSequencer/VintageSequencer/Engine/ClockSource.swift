import Foundation
import CoreMIDI
import Darwin
import Atomics

// MARK: - ClockSource

/// Interne 24-PPQ-Clock auf einem eigenen Echtzeit-Thread (v1.12.21).
///
/// Ersetzt die frühere `AudioClockSource` (AVAudioEngine-Tap). Messung am 2026-11-12:
/// der Tap lieferte 4410 Frames (100 ms) statt der angeforderten 256, lief auf einem
/// Thread ohne Time-Constraint-Policy und feuerte die Ticks in Schüben von ~5; der
/// Vorlauf eines Ticks schwankte zwischen 47 und 151 ms, weshalb 120 ms Lookahead nötig
/// waren. Die Tick-Zeitstempel selbst waren schon damals reine Host-Zeit-Arithmetik
/// (additives Raster ab `mach_absolute_time()`), der Tap nur der Wecker.
///
/// Jetzt weckt `mach_wait_until` einen Thread mit `THREAD_TIME_CONSTRAINT_POLICY` genau
/// einmal pro Tick. Zeitbasis und Zeitstempel sind unverändert `mach_absolute_time`-
/// Einheiten = `MIDITimeStamp`.
///
/// **Raster:** T(k+1) = T(k) + Intervall(BPM). Additiv, kein Drift; BPM-Änderungen wirken
/// ab dem nächsten Intervall, ohne Phasensprung.
///
/// **Vorlauf:** Tick k wird `emitMargin` VOR T(k−1) ausgegeben, also ein Tick-Intervall
/// plus `emitMargin` vor seinem eigenen Zeitpunkt. Das volle Intervall ist nötig, weil
/// der Tick-Pfad Steps mit gebrochenem Raster bis zu knapp einem Intervall VOR den
/// Tick-Zeitpunkt datiert (Overshoot-Korrektur in `advanceSteps`).
/// Bei 120 BPM: 20,8 ms + 10 ms ≈ 31 ms (vorher 120 ms).
///
/// **Aufholen:** Liegt der Thread mehr als zwei Intervalle zurück (Rechner war angehalten,
/// Debugger), wird das Raster neu an „jetzt" verankert statt Ticks im Schwall nachzuholen.
///
/// **Lebensdauer:** Der Thread hält nur den internen `State` (nicht die ClockSource).
/// `stop()` und `deinit` erhöhen die Generation; der Thread bemerkt das spätestens beim
/// nächsten Aufwachen und endet, ohne `onTick` aufzurufen. Ein Join ist nicht nötig: der
/// Empfänger (`SequencerEngine.enterTick`) weist Ticks außerhalb der Wiedergabe ohnehin ab.
final class ClockSource {

    /// Abstand zwischen Ausgabe eines Ticks und dem Zeitpunkt des VORHERIGEN Ticks.
    /// Deckt Weck-Jitter des Echtzeit-Threads und die Laufzeit des Tick-Pfads ab.
    static let emitMarginNs: Double = 10_000_000

    // MARK: - Öffentliche API

    /// Wird einmal pro 24-PPQ-Tick vom Clock-Thread aufgerufen, mit dem geplanten
    /// Zeitpunkt des Ticks als CoreMIDI-Zeitstempel (liegt in der Zukunft).
    ///
    /// Vor `start()` setzen; während `isRunning` nicht ändern.
    /// RT-Pflicht der Implementierung: kein Heap, kein blockierender Lock, kein Logging.
    var onTick: ((MIDITimeStamp) -> Void)? {
        get { state.onTick }
        set {
            assert(!isRunning, "[ClockSource] onTick während isRunning gesetzt")
            state.onTick = newValue
        }
    }

    /// BPM — atomar. Geclampt auf 1…300.
    var bpm: Double {
        get { Double(bitPattern: state.bpmBits.load(ordering: .acquiring)) }
        set { state.bpmBits.store(max(1.0, min(300.0, newValue)).bitPattern, ordering: .releasing) }
    }

    var isRunning: Bool { state.running.load(ordering: .acquiring) }

    /// Zusätzlicher Vorlauf in ns (v1.15.2): Ausgabepuffer + negativer Spuroffset. Wirkt nur
    /// auf den Aufrufzeitpunkt des Ticks, nie auf sein Raster; jederzeit änderbar.
    var extraLeadNs: Double {
        get { Double(bitPattern: state.extraLeadBits.load(ordering: .relaxed)) }
        set { state.extraLeadBits.store(max(0, min(200_000_000, newValue)).bitPattern, ordering: .relaxed) }
    }

    // MARK: - Geteilter Zustand

    fileprivate final class State: @unchecked Sendable {
        let bpmBits    = ManagedAtomic<UInt64>((120.0).bitPattern)
        let extraLeadBits = ManagedAtomic<UInt64>((0.0).bitPattern)
        /// Jede start()/stop()-Flanke erhöht die Generation; ein Thread läuft nur, solange
        /// seine Generation aktuell ist.
        let generation = ManagedAtomic<Int>(0)
        let running    = ManagedAtomic<Bool>(false)
        var onTick: ((MIDITimeStamp) -> Void)?
        /// Größte beobachtete Verspätung beim Aufwachen (mach-Einheiten) — Diagnose.
        let maxWakeLateness = ManagedAtomic<UInt64>(0)
    }

    private let state = State()
    private static let nsToMach: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.denom) / Double(tb.numer)
    }()

    deinit { stop() }

    // MARK: - Start / Stop (Main-Thread)

    func start() {
        guard !isRunning else { return }
        state.running.store(true, ordering: .releasing)
        state.maxWakeLateness.store(0, ordering: .relaxed)
        let generation = state.generation.wrappingIncrementThenLoad(ordering: .acquiringAndReleasing)
        let state = self.state
        let thread = Thread { ClockSource.run(state: state, generation: generation) }
        thread.name = "com.vintageseq.clock"
        thread.qualityOfService = .userInteractive   // Rückfall, falls die RT-Policy abgelehnt wird
        thread.start()
    }

    func stop() {
        guard isRunning else { return }
        state.generation.wrappingIncrement(ordering: .acquiringAndReleasing)
        state.running.store(false, ordering: .releasing)
    }

    #if DEBUG
    /// Größte Verspätung beim Aufwachen seit dem letzten start(), in Millisekunden.
    var _maxWakeLatenessMs: Double {
        Double(state.maxWakeLateness.load(ordering: .relaxed)) / ClockSource.nsToMach / 1_000_000
    }
    #endif

    // MARK: - Clock-Thread

    @inline(__always)
    private static func tickIntervalMach(_ state: State) -> Double {
        let bpm = Double(bitPattern: state.bpmBits.load(ordering: .acquiring))
        return (60_000_000_000.0 / (bpm * 24.0)) * nsToMach
    }

    /// Bittet den Kernel um Echtzeit-Scheduling für den aufrufenden Thread.
    private static func requestRealtime(periodMach: Double) {
        var policy = thread_time_constraint_policy_data_t(
            period:      UInt32(min(periodMach, Double(UInt32.max))),
            computation: UInt32(300_000 * nsToMach),      // ≤ 0,3 ms Rechenzeit je Periode
            constraint:  UInt32(2_000_000 * nsToMach),    // fertig binnen 2 ms nach dem Wecken
            preemptible: 1)
        let count = mach_msg_type_number_t(
            MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &policy) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(pthread_mach_thread_np(pthread_self()),
                                  thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
            }
        }
    }

    private static func run(state: State, generation: Int) {
        requestRealtime(periodMach: tickIntervalMach(state))
        func margin() -> Double {
            (emitMarginNs + Double(bitPattern: state.extraLeadBits.load(ordering: .relaxed))) * nsToMach
        }
        // T(0): ein Intervall + Marge in der Zukunft, damit schon der erste Tick den vollen Vorlauf hat.
        var tickTime = Double(mach_absolute_time()) + tickIntervalMach(state) + margin()

        // Einmal laden: onTick ändert sich während des Laufs nicht (Vertrag der Property);
        // so entfällt Retain/Release der Closure pro Tick.
        let onTick = state.onTick

        while state.generation.load(ordering: .acquiring) == generation {
            let interval = tickIntervalMach(state)
            let margin = margin()
            // Ausgabezeitpunkt dieses Ticks: Marge vor dem Zeitpunkt des vorherigen Ticks.
            let emitAt = tickTime - interval - margin
            let now    = Double(mach_absolute_time())
            if emitAt > now {
                mach_wait_until(UInt64(emitAt))
                guard state.generation.load(ordering: .acquiring) == generation else { return }
                let woke = Double(mach_absolute_time())
                if woke > emitAt {
                    let late = UInt64(woke - emitAt)
                    if late > state.maxWakeLateness.load(ordering: .relaxed) {
                        state.maxWakeLateness.store(late, ordering: .relaxed)
                    }
                }
            } else if now - emitAt > 2 * interval {
                // Weit zurück (Rechner/Prozess war angehalten): neu verankern statt nachholen.
                tickTime = now + interval + margin
            }
            onTick?(MIDITimeStamp(tickTime.rounded()))
            tickTime += interval
        }
    }
}
