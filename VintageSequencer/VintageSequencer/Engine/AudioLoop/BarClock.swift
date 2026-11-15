import Foundation
import Atomics

// MARK: - BarClock (v1.15.0)
//
// Taktanker vom Tick-Thread an die Audio-Threads der Audio-Loops: „Takt n beginnt zur
// Host-Zeit t". Der Tick-Thread schreibt bei jedem Takt-Puls (Puls % 96 == 0) einen Anker mit
// dem vorausgeplanten Tick-Zeitpunkt; Wiedergabe und Aufnahme rechnen daraus ihren Ort im
// Loop. Damit folgen Loops derselben Zeitbasis wie MIDI-Ereignisse und gehostete
// Instrumente (Host-Zeitstempel), ohne dass Audio-Thread und Tick-Thread einander berühren.
//
// Speicher: vier Ankerplätze (Takt n liegt in Platz n % 4) mit je einer Sequenznummer
// (Seqlock). Einziger Schreiber der Anker: der Tick-Thread — auch der Sitzungsbeginn
// (`beginSession`) läuft dort, im selben Tick, der den Pulszähler auf 0 setzt (v1.15.1,
// Codex H4: vorher setzte Main zurück, der MIDI-Startpfad gar nicht). Main setzt nur das
// Sitzungsende (`stop(at:)`). Leser: beliebig viele, wartefrei mit begrenzter Wiederholung.
//
// Ende: Anker gelten nur für Host-Zeiten vor `endHost`. Beim Songende ist das der
// vorausgeplante Tick-Zeitpunkt des Endpulses (nicht der Moment, in dem Main reagiert).

final class BarClock {

    struct Anchor: Equatable {
        var bar:  Int
        var host: UInt64
        static let none = Anchor(bar: -1, host: 0)
        var isValid: Bool { bar >= 0 }
    }

    /// Die bis zu vier jüngsten Anker, einmal je Audio-Block gelesen.
    struct Window {
        var a0 = Anchor.none, a1 = Anchor.none, a2 = Anchor.none, a3 = Anchor.none
        /// Sitzungsende: ab hier keine Anker mehr (UInt64.max = läuft).
        var end: UInt64 = 0

        /// Keine Sitzung bzw. zur Host-Zeit `h` beendet.
        @inline(__always)
        func isStopped(at h: UInt64) -> Bool {
            h >= end || !(a0.isValid || a1.isValid || a2.isValid || a3.isValid)
        }

        /// Jüngster Anker mit `host ≤ h` (Takt, in dem `h` liegt).
        @inline(__always)
        func anchor(at h: UInt64) -> Anchor {
            guard h < end else { return .none }
            var best = Anchor.none
            if a0.isValid, a0.host <= h, a0.bar > best.bar { best = a0 }
            if a1.isValid, a1.host <= h, a1.bar > best.bar { best = a1 }
            if a2.isValid, a2.host <= h, a2.bar > best.bar { best = a2 }
            if a3.isValid, a3.host <= h, a3.bar > best.bar { best = a3 }
            return best
        }
    }

    // Je Platz: Sequenznummer, Takt, Host-Zeit. Rohspeicher mit `UnsafeAtomic` — im Tick- und
    // Audio-Pfad kein ARC-Verkehr.
    private let seqs  = UnsafeMutablePointer<UnsafeAtomic<UInt64>>.allocate(capacity: 4)
    private let bars  = UnsafeMutablePointer<UnsafeAtomic<Int>>.allocate(capacity: 4)
    private let hosts = UnsafeMutablePointer<UnsafeAtomic<UInt64>>.allocate(capacity: 4)
    private let endHost = UnsafeAtomic<UInt64>.create(0)

    /// Läuft eine Sitzung (Ende noch nicht gesetzt)?
    var isRunning: Bool { endHost.load(ordering: .acquiring) == .max }

    init() {
        for i in 0..<4 {
            (seqs + i).initialize(to: .create(0))
            (bars + i).initialize(to: .create(-1))
            (hosts + i).initialize(to: .create(0))
        }
    }

    deinit {
        for i in 0..<4 { seqs[i].destroy(); bars[i].destroy(); hosts[i].destroy() }
        seqs.deallocate(); bars.deallocate(); hosts.deallocate()
        endHost.destroy()
    }

    // MARK: Schreiber (Tick-Thread)

    /// Takt `bar` beginnt zur Host-Zeit `host`. RT-sicher: nur Atomics.
    func publish(bar: Int, host: UInt64) {
        let i = bar & 3
        seqs[i].wrappingIncrement(ordering: .acquiringAndReleasing)   // ungerade: Schreiben läuft
        bars[i].store(bar, ordering: .relaxed)
        hosts[i].store(host, ordering: .relaxed)
        seqs[i].wrappingIncrement(ordering: .releasing)               // gerade: fertig
    }

    /// Neue Sitzung (Tick-Thread, im Tick mit Puls 0, vor dessen `publish`): alte Anker
    /// verwerfen, Ende aufheben. RT-sicher.
    func beginSession() {
        for i in 0..<4 {
            seqs[i].wrappingIncrement(ordering: .acquiringAndReleasing)
            bars[i].store(-1, ordering: .relaxed); hosts[i].store(0, ordering: .relaxed)
            seqs[i].wrappingIncrement(ordering: .releasing)
        }
        endHost.store(.max, ordering: .releasing)
    }

    // MARK: Main

    /// Sitzungsende zur Host-Zeit `host` (Standard: jetzt). Ein späteres Ende verschiebt ein
    /// früheres nicht. Leser hören dort auf; eine laufende Aufnahme endet.
    func stop(at host: UInt64 = mach_absolute_time()) {
        let current = endHost.load(ordering: .relaxed)
        if host < current { endHost.store(host, ordering: .releasing) }
    }

    // MARK: Leser (Audio-Threads)

    @inline(__always)
    private func read(_ i: Int) -> Anchor {
        for _ in 0..<4 {
            let s1 = seqs[i].load(ordering: .acquiring)
            guard s1 & 1 == 0 else { continue }
            let bar = bars[i].load(ordering: .relaxed), host = hosts[i].load(ordering: .relaxed)
            atomicMemoryFence(ordering: .acquiring)
            if seqs[i].load(ordering: .relaxed) == s1 { return Anchor(bar: bar, host: host) }
        }
        return .none
    }

    /// Momentaufnahme aller Anker; leer, solange der Transport steht. RT-sicher.
    func window() -> Window {
        let end = endHost.load(ordering: .acquiring)
        guard end > 0 else { return Window() }
        return Window(a0: read(0), a1: read(1), a2: read(2), a3: read(3), end: end)
    }
}
