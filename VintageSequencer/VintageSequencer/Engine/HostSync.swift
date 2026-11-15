import Foundation
import Atomics
import AudioToolbox

// MARK: - HostSync (v1.17.2, Zeitvertrag v1.17.6)
//
// Tempo, Position und Transport für gehostete Plug-ins (Instrumente und Effekte). AUs
// synchronisieren sich nicht über MIDI-Clock, sondern fragen beim Rendern den Host:
// `musicalContextBlock` (Tempo, Taktart, Beat-Position) und `transportStateBlock` (läuft,
// Sample-Position). FoF beantwortet beide aus dieser Quelle.
//
// Zeitvertrag (v1.17.6, Codex A17-01–03):
//   - Eine Sitzung hat eine feste Startzeit (Host-Zeit von Puls 0) und ein Ende. Vor dem Start
//     und ab dem Ende steht der Transport; die Position bleibt am Ende stehen.
//   - Beat-Position: stückweise linear. Jeder Pulsanker „Puls p zur Host-Zeit t, Tempo b" gilt
//     ab t bis zum nächsten Anker. Die Anker liegen in einem Ring (`ringSize`), damit auch
//     vorausgeplante Anker die noch zu rendernde Zeit davor nicht überschreiben: eine Abfrage
//     benutzt den jüngsten Anker mit t ≤ Abfragezeit. Ein vorausgeplanter Tempowechsel gilt
//     also erst ab seiner Grenze.
//   - Sample-Position: verstrichene Zeit seit dem Start in Samples der Ausgangsrate — eine
//     Zeitleiste unabhängig vom Tempo (Apple: `currentSamplePosition`). Tempowechsel und
//     Tempo-Regler im Stillstand verschieben sie nicht. FoF kennt kein Springen: jede Sitzung
//     beginnt bei 0; ein Sitzungswechsel meldet `.changed`.
//
// Besitz:
//   - Tick-Thread: `beginSession` (mit der Sitzungsnummer des Snapshots), `publish` je Puls,
//     `end` am Songende — auf dem geplanten Zeitpunkt, ohne Main (A17-01).
//   - Main: `stop(at:session:)` beim Benutzer-Stop — wirkt nur auf die genannte Sitzung;
//     `setIdleTempo`.
//   - Das Ende wird nur früher (Vergleichen-und-Tauschen): mehrere Schreiber können ein
//     früheres Ende nie durch ein späteres ersetzen. Nur `beginSession` setzt es zurück.
//   - Leser: Audio-Threads der Plug-ins, wartefrei (Seqlock, begrenzte Wiederholung, Ring
//     fester Größe), nur Atomics.
//
// Abschnitt (v1.18.23, Konzept Taktart und Zeit 4.1, Codex KT-01): jeder Anker trägt den
// musikalischen Abschnitt, in dem sein Puls liegt — Taktart, Ursprung (Puls und absolute
// Taktnummer), Aktivierung, laufendes und nächstes Pattern samt Wechselpuls. `state(at:)`
// liefert Taktart, Takt und Taktbeginn aus DEMSELBEN Anker wie Position und Tempo; die
// Host-Blöcke lesen keine getrennte globale Taktart mehr. Im Stillstand gilt die Taktart des
// Projekts (`setMeter`), gerechnet ab Viertel 0.

final class HostSync {

    /// Ergebnis einer Abfrage zur Host-Zeit `h`.
    struct State: Equatable {
        var tempo: Double
        /// Viertel seit Transportstart (0 am ersten Puls).
        var beat: Double
        /// Transport läuft an dieser Stelle.
        var moving: Bool
        /// Sekunden seit Sitzungsstart (Grundlage der Sample-Position); im Stillstand eingefroren.
        var seconds: Double = 0
        /// Sitzung, zu der die Antwort gehört (0 = keine).
        var session: UInt32 = 0
        /// Taktart an dieser Stelle (laufend: die des Abschnitts; sonst die des Projekts).
        var numerator: Int = 4
        var denominator: Int = 4
        /// Absoluter Takt (0 = erster) und sein Beginn in Vierteln.
        var bar: Int = 0
        var barStart: Double = 0
        /// Abschnitt: Aktivierung (0 = keine Sitzung), laufendes Pattern (−1 = unbekannt),
        /// nächstes Pattern (−1 = keins geplant) und dessen Wechselpuls (−1 = am Ende von Spur 1
        /// bzw. unbekannt).
        var activation: Int = 0
        var pattern: Int = -1
        var nextPattern: Int = -1
        var nextSwitchPulse: Int = -1
        /// Puls an dieser Stelle (gebrochen, seit Sitzungsbeginn).
        var pulse: Double = 0

        var quartersPerBar: Double { 4 * Double(numerator) / Double(denominator) }
        var pulsesPerBar: Double { 96 * Double(numerator) / Double(denominator) }
    }

    /// Musikalischer Abschnitt eines Ankers (vom Tick je Puls übergeben, nur Werte).
    struct Section: Equatable {
        /// Zähler · 256 + Nenner; 0 = Taktart der Sitzung.
        var meterBits: Int = 0
        var originPulse: Int = 0
        var originBar: Int = 0
        var activation: Int = 1
        var pattern: Int = -1
        var nextPattern: Int = -1
        var nextSwitchPulse: Int = -1

        init(meter: TimeSignature? = nil, originPulse: Int = 0, originBar: Int = 0, activation: Int = 1,
             pattern: Int = -1, nextPattern: Int = -1, nextSwitchPulse: Int = -1) {
            meterBits = meter.map { $0.numerator << 8 | $0.denominator } ?? 0
            self.originPulse = originPulse; self.originBar = originBar; self.activation = activation
            self.pattern = pattern; self.nextPattern = nextPattern; self.nextSwitchPulse = nextSwitchPulse
        }
    }

    static let pulsesPerBeat = 24.0
    /// Taktart (v1.18.12): Zähler · 256 + Nenner, gesetzt von Main (Stillstand) und vom Tick zu
    /// Sitzungsbeginn. Nur Atomics — die Blöcke lesen sie im Render der Plug-ins.
    /// Projekttaktart: gilt im Stillstand und als Vorgabe einer Sitzung (`beginSession`).
    private let meterBits = UnsafeAtomic<Int>.create(4 << 8 | 4)
    private let sessionMeterBits = UnsafeAtomic<Int>.create(4 << 8 | 4)
    func setMeter(_ m: TimeSignature) { meterBits.store(m.numerator << 8 | m.denominator, ordering: .relaxed) }
    /// Taktart des Projekts (Stillstand). Laufend gilt die des Abschnitts: `state(at:)`.
    var meter: (numerator: Int, denominator: Int) { Self.unpack(meterBits.load(ordering: .relaxed)) }
    @inline(__always)
    private static func unpack(_ b: Int) -> (numerator: Int, denominator: Int) { (max(1, b >> 8), max(1, b & 0xFF)) }
    /// Anker im Ring. Der Tick plant höchstens ein Tick-Intervall plus Sicherheitsabstand und
    /// Verspätung voraus — bei 300 BPM (8,3 ms je Puls) wenige Pulse. 32 Anker decken auch
    /// längere Verspätungen; fehlt ein passender Anker, wird vom ältesten aus gerechnet.
    static let ringSize = 32

    private let seq        = UnsafeAtomic<UInt64>.create(0)
    private let count      = UnsafeAtomic<Int>.create(0)          // Anker dieser Sitzung
    private let startHost  = UnsafeAtomic<UInt64>.create(0)       // 0: noch kein Anker
    private let sessionID  = UnsafeAtomic<UInt32>.create(0)
    private let endHost    = UnsafeAtomic<UInt64>.create(0)       // .max = läuft
    private let idleBits   = UnsafeAtomic<UInt64>.create(120.0.bitPattern)
    private let ringPulse: UnsafeMutablePointer<UnsafeAtomic<Int>>
    private let ringHost:  UnsafeMutablePointer<UnsafeAtomic<UInt64>>
    private let ringBPM:   UnsafeMutablePointer<UnsafeAtomic<UInt64>>
    // Abschnitt je Anker (v1.18.23).
    private let ringMeter:  UnsafeMutablePointer<UnsafeAtomic<Int>>
    private let ringOrigin: UnsafeMutablePointer<UnsafeAtomic<Int>>     // Ursprungspuls
    private let ringBar0:   UnsafeMutablePointer<UnsafeAtomic<Int>>     // Takt am Ursprung
    private let ringAct:    UnsafeMutablePointer<UnsafeAtomic<Int>>     // Aktivierung
    private let ringPat:    UnsafeMutablePointer<UnsafeAtomic<Int>>     // (Pattern+1)·256 + (nächstes+1)
    private let ringNext:   UnsafeMutablePointer<UnsafeAtomic<Int>>     // Wechselpuls
    let ticksPerSecond: Double

    init() {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        ticksPerSecond = 1_000_000_000.0 * Double(tb.denom) / Double(tb.numer)
        ringPulse = .allocate(capacity: Self.ringSize)
        ringHost  = .allocate(capacity: Self.ringSize)
        ringBPM   = .allocate(capacity: Self.ringSize)
        ringMeter = .allocate(capacity: Self.ringSize); ringOrigin = .allocate(capacity: Self.ringSize)
        ringBar0  = .allocate(capacity: Self.ringSize); ringAct = .allocate(capacity: Self.ringSize)
        ringPat   = .allocate(capacity: Self.ringSize); ringNext = .allocate(capacity: Self.ringSize)
        for i in 0..<Self.ringSize {
            (ringPulse + i).initialize(to: .create(0))
            (ringHost + i).initialize(to: .create(0))
            (ringBPM + i).initialize(to: .create(0))
            (ringMeter + i).initialize(to: .create(4 << 8 | 4)); (ringOrigin + i).initialize(to: .create(0))
            (ringBar0 + i).initialize(to: .create(0)); (ringAct + i).initialize(to: .create(0))
            (ringPat + i).initialize(to: .create(0)); (ringNext + i).initialize(to: .create(-1))
        }
    }

    deinit {
        seq.destroy(); count.destroy(); startHost.destroy(); sessionID.destroy()
        endHost.destroy(); idleBits.destroy(); meterBits.destroy(); sessionMeterBits.destroy()
        for i in 0..<Self.ringSize {
            ringPulse[i].destroy(); ringHost[i].destroy(); ringBPM[i].destroy()
            ringMeter[i].destroy(); ringOrigin[i].destroy(); ringBar0[i].destroy()
            ringAct[i].destroy(); ringPat[i].destroy(); ringNext[i].destroy()
        }
        ringPulse.deallocate(); ringHost.deallocate(); ringBPM.deallocate()
        ringMeter.deallocate(); ringOrigin.deallocate(); ringBar0.deallocate()
        ringAct.deallocate(); ringPat.deallocate(); ringNext.deallocate()
    }

    // MARK: Schreiber (Tick-Thread)

    /// Neue Sitzung (im Tick mit Puls 0, vor dessen `publish`). RT-sicher.
    func beginSession(_ session: UInt32 = 0, meter: TimeSignature = .common) {
        setMeter(meter)
        sessionMeterBits.store(meter.numerator << 8 | meter.denominator, ordering: .relaxed)
        seq.wrappingIncrement(ordering: .acquiringAndReleasing)          // ungerade: Schreiben läuft
        count.store(0, ordering: .relaxed)
        startHost.store(0, ordering: .relaxed)
        sessionID.store(session, ordering: .relaxed)
        endHost.store(.max, ordering: .relaxed)
        seq.wrappingIncrement(ordering: .releasing)                      // gerade: fertig
    }

    /// Puls `p` liegt zur Host-Zeit `h`, Tempo `bpm`, im Abschnitt `section`. RT-sicher: nur
    /// Atomics. Ohne Abschnitt: Taktart der Sitzung ab Puls 0.
    @inline(__always)
    func publish(pulse p: Int, host h: UInt64, bpm: Double, section: Section = Section()) {
        let meter = section.meterBits != 0 ? section.meterBits : sessionMeterBits.load(ordering: .relaxed)
        seq.wrappingIncrement(ordering: .acquiringAndReleasing)
        let n = count.load(ordering: .relaxed)
        let i = n % Self.ringSize
        ringPulse[i].store(p, ordering: .relaxed)
        ringHost[i].store(h, ordering: .relaxed)
        ringBPM[i].store(bpm.bitPattern, ordering: .relaxed)
        ringMeter[i].store(meter, ordering: .relaxed)
        ringOrigin[i].store(section.originPulse, ordering: .relaxed)
        ringBar0[i].store(section.originBar, ordering: .relaxed)
        ringAct[i].store(section.activation, ordering: .relaxed)
        ringPat[i].store((section.pattern + 1) << 8 | (section.nextPattern + 1), ordering: .relaxed)
        ringNext[i].store(section.nextSwitchPulse, ordering: .relaxed)
        if n == 0 { startHost.store(h, ordering: .relaxed) }
        count.store(n &+ 1, ordering: .relaxed)
        seq.wrappingIncrement(ordering: .releasing)
    }

    /// Songende im Tick: Transport steht ab `h` (geplanter Zeitpunkt des Endpulses).
    func end(at h: UInt64) { lowerEnd(to: h) }

    // MARK: Main

    /// Benutzer-Stop: Transport der Sitzung `session` steht ab `h`. Eine andere (neuere)
    /// Sitzung bleibt unberührt. nil = die laufende Sitzung.
    func stop(at h: UInt64 = mach_absolute_time(), session: UInt32? = nil) {
        if let session, sessionID.load(ordering: .acquiring) != session { return }
        lowerEnd(to: h)
    }

    /// Tempo, das Plug-ins im Stillstand sehen (Tempo-Regler, geladenes Projekt).
    func setIdleTempo(_ bpm: Double) {
        guard bpm.isFinite, bpm > 0 else { return }
        idleBits.store(bpm.bitPattern, ordering: .relaxed)
    }

    var currentSession: UInt32 { sessionID.load(ordering: .acquiring) }

    /// Ende nur nach vorn verlegen (früher), nie nach hinten.
    private func lowerEnd(to h: UInt64) {
        var current = endHost.load(ordering: .acquiring)
        while h < current {
            let (done, seen) = endHost.compareExchange(expected: current, desired: h,
                                                       ordering: .acquiringAndReleasing)
            if done { return }
            current = seen
        }
    }

    // MARK: Leser (Audio-Threads)

    /// Tempo, Position und Lauf zur Host-Zeit `h`. RT-sicher, wartefrei.
    func state(at h: UInt64) -> State {
        let idle = Double(bitPattern: idleBits.load(ordering: .relaxed))
        var ok = false
        var n = 0, start: UInt64 = 0, sess: UInt32 = 0
        var p = 0, anchor: UInt64 = 0, bpm = idle
        var mBits = 0, origin = 0, bar0 = 0, act = 0, pat = 0, nextAt = -1
        let end = endHost.load(ordering: .acquiring)
        let at = min(h, end)                                             // im Stillstand: Endposition
        for _ in 0..<4 {
            let s1 = seq.load(ordering: .acquiring)
            guard s1 & 1 == 0 else { continue }
            n = count.load(ordering: .relaxed)
            start = startHost.load(ordering: .relaxed)
            sess = sessionID.load(ordering: .relaxed)
            // Jüngster Anker mit Zeitpunkt ≤ `at`; sonst der älteste vorhandene.
            let kept = min(n, Self.ringSize)
            var found = false
            for k in 0..<kept {
                let i = (n - 1 - k) % Self.ringSize
                let t = ringHost[i].load(ordering: .relaxed)
                if t <= at || k == kept - 1 {
                    p = ringPulse[i].load(ordering: .relaxed)
                    anchor = t
                    bpm = Double(bitPattern: ringBPM[i].load(ordering: .relaxed))
                    mBits = ringMeter[i].load(ordering: .relaxed)
                    origin = ringOrigin[i].load(ordering: .relaxed)
                    bar0 = ringBar0[i].load(ordering: .relaxed)
                    act = ringAct[i].load(ordering: .relaxed)
                    pat = ringPat[i].load(ordering: .relaxed)
                    nextAt = ringNext[i].load(ordering: .relaxed)
                    found = true
                    if t <= at { break }
                }
            }
            atomicMemoryFence(ordering: .acquiring)
            if seq.load(ordering: .relaxed) == s1 { ok = found || n == 0; break }
        }
        let running = h < end
        let project = Self.unpack(meterBits.load(ordering: .relaxed))
        guard ok, n > 0, bpm > 0, at >= start else {
            var st = State(tempo: idle, beat: 0, moving: false, seconds: 0, session: sess)
            (st.numerator, st.denominator) = project
            return st
        }
        let seconds = at >= anchor ? Double(at - anchor) / ticksPerSecond
                                   : -Double(anchor - at) / ticksPerSecond
        let pulse = max(0, Double(p) + seconds * bpm / 60 * Self.pulsesPerBeat)
        let beat = pulse / Self.pulsesPerBeat
        let elapsed = Double(at - start) / ticksPerSecond
        var st = State(tempo: running ? bpm : idle, beat: beat, moving: running,
                       seconds: elapsed, session: sess)
        st.pulse = pulse
        if running {
            // Abschnitt des Ankers: Takt ab dessen Ursprung (KT-01), nie ab Viertel 0.
            (st.numerator, st.denominator) = Self.unpack(mBits)
            let ppb = st.pulsesPerBar
            let k = max(0, ((pulse - Double(origin)) / ppb + 1e-9).rounded(.down))
            st.bar = bar0 + Int(k)
            st.barStart = (Double(origin) + k * ppb) / Self.pulsesPerBeat
            st.activation = act
            st.pattern = (pat >> 8) - 1
            st.nextPattern = (pat & 0xFF) - 1
            st.nextSwitchPulse = nextAt
        } else {
            // Stillstand: Taktart des Projekts ab Viertel 0 (Anzeige, Plug-ins).
            (st.numerator, st.denominator) = project
            let qpb = st.quartersPerBar
            let k = (beat / qpb + 1e-9).rounded(.down)
            st.bar = Int(k); st.barStart = k * qpb
        }
        return st
    }

    // MARK: Host-Blöcke für ein Plug-in

    /// Blöcke für ein Plug-in. Sie halten `self` und `binding` stark: beide leben, solange das
    /// Plug-in (oder ein Editor, der es noch hält) die Blöcke hat — kein Zugriff auf Speicher
    /// des Racks. `advance` liefert den Latenzausgleich der Route (Host-Ticks).
    func blocks(binding: HostBinding, advance: @escaping () -> UInt64)
        -> (AUHostMusicalContextBlock, AUHostTransportStateBlock) {
        let sync = self
        func now() -> (State, Double) {
            let stamp = binding.renderHost.load(ordering: .relaxed)
            let h = (stamp != 0 ? stamp : mach_absolute_time()) &+ advance()
            let tpf = Double(bitPattern: binding.ticksPerFrame.load(ordering: .relaxed))
            let sr = tpf > 0 ? sync.ticksPerSecond / tpf : 48_000
            return (sync.state(at: h), sr)
        }
        let music: AUHostMusicalContextBlock = { tempo, num, den, beat, toNext, downbeat in
            binding.musicCalls.wrappingIncrement(ordering: .relaxed)
            let (st, sr) = now()
            tempo?.pointee = st.tempo
            // Taktart und Taktbeginn aus demselben Anker wie die Position (v1.18.23, KT-01).
            num?.pointee = Double(st.numerator)             // Zähler ist Double, Nenner Int (API)
            den?.pointee = st.denominator
            beat?.pointee = st.beat
            let frac = st.beat - st.beat.rounded(.down)
            toNext?.pointee = frac == 0 ? 0 : Int(((1 - frac) * 60 / st.tempo * sr).rounded())
            downbeat?.pointee = st.barStart                 // Beat in Vierteln (API)
            return true
        }
        let transport: AUHostTransportStateBlock = { flags, samplePos, cycleStart, cycleEnd in
            binding.transportCalls.wrappingIncrement(ordering: .relaxed)
            let (st, sr) = now()
            var f: AUHostTransportStateFlags = []
            if st.moving { f.insert(.moving) }
            if binding.noteChange(moving: st.moving, session: st.session) { f.insert(.changed) }
            flags?.pointee = f
            samplePos?.pointee = (st.seconds * sr).rounded()
            cycleStart?.pointee = 0
            cycleEnd?.pointee = 0
            return true
        }
        return (music, transport)
    }
}

// MARK: - HostBinding (v1.17.6, Codex A17-09)

/// Bindung EINER Plug-in-Installation an den Host-Takt: Blockzeit (vom Vor-Render-Observer),
/// Host-Ticks je Sample, Nutzungszähler. Neu je Installation; Blöcke und Observer halten sie
/// stark, ihre Lebensdauer endet mit dem letzten Nutzer. Die Zähler belegen, dass der
/// Renderpfad des Plug-ins die Blöcke tatsächlich aufruft (Diagnose und Tests) — ein
/// gesetzter Getter allein beweist das nicht.
final class HostBinding {
    let renderHost     = ManagedAtomic<UInt64>(0)
    let ticksPerFrame  = ManagedAtomic<UInt64>(0)
    let musicCalls     = ManagedAtomic<Int>(0)
    let transportCalls = ManagedAtomic<Int>(0)
    /// Renderdurchläufe des Plug-ins (Vor-Render-Observer, v1.18.10): zusammen mit den
    /// Aufrufzählern belegt das, ob ein rendernder Block die Host-Blöcke noch erreicht.
    let renders        = ManagedAtomic<Int>(0)
    var calls: Int { musicCalls.load(ordering: .relaxed) + transportCalls.load(ordering: .relaxed) }
    /// Letzter gemeldeter Lauf/Sitzung (für `.changed`). Gepackt in ein Wort, damit auch ein
    /// Plug-in, das aus mehreren Threads fragt, jeden Wechsel genau einmal sieht.
    private let lastReported = ManagedAtomic<UInt64>(0)
    /// Setzt dieselben Blöcke erneut am Plug-in (nur Main, fester Lebenszykluspunkt).
    var install: (() -> Void)?
    /// Wie oft die Blöcke nach einem Engine-Ereignis neu gesetzt werden mussten (Diagnose).
    let reinstalls = ManagedAtomic<Int>(0)

    /// true, wenn sich Lauf oder Sitzung seit der letzten Meldung geändert haben.
    @inline(__always)
    func noteChange(moving: Bool, session: UInt32) -> Bool {
        let word = UInt64(session) << 1 | (moving ? 1 : 0)
        return lastReported.exchange(word, ordering: .relaxed) != word
    }
}
