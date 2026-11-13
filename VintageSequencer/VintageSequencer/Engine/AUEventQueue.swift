import Foundation
import Atomics

// MARK: - AUEvent

/// Ein kurzes MIDI-Ereignis (≤ 3 Bytes) oder ein Parameterwert für ein gehostetes
/// AU-Instrument, datiert in Host-Zeit (`mach_absolute_time`-Einheiten = `MIDITimeStamp`).
/// `hostTime == 0` heißt „sofort" (nächster Renderblock, Offset 0).
struct AUEvent {
    var hostTime:   UInt64
    /// MIDI: b0 | b1 << 8 | b2 << 16. Parameter: Wert als Float-Bitmuster.
    var packed:     UInt32
    /// Leer-Generation (`invalidate`) beim Einreihen.
    var generation: UInt32
    /// Belegung des Slots, für die das Ereignis bestimmt ist (v1.13.13).
    var epoch:      UInt32
    /// Parameter-Ereignis (v1.13.9): `address` ist die Parameter-Adresse des Instruments.
    var address:     UInt64 = 0
    var isParameter: Bool   = false

    @inline(__always)
    static func pack(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8) -> UInt32 {
        UInt32(b0) | UInt32(b1) << 8 | UInt32(b2) << 16
    }

    static let empty = AUEvent(hostTime: 0, packed: 0, generation: 0, epoch: 0)
}

/// Wrapping-Vergleich zweier nur steigender Zähler: liegt `a` nach `b`?
@inline(__always)
func counterIsNewer(_ a: UInt32, than b: UInt32) -> Bool { Int32(bitPattern: a &- b) > 0 }

// MARK: - AUEventRing

/// Lock-freier SPSC-Ring fester Größe. Genau ein Produzent, genau ein Konsument.
/// Kein Heap nach `init`, kein Lock, kein Warten.
final class AUEventRing {
    static let capacity = 1024                       // Zweierpotenz
    private static let mask = capacity - 1
    private let buffer: UnsafeMutablePointer<AUEvent>
    private let head = ManagedAtomic<Int>(0)         // nächster Lese-Index (Konsument)
    private let tail = ManagedAtomic<Int>(0)         // nächster Schreib-Index (Produzent)

    init() {
        buffer = .allocate(capacity: Self.capacity)
        buffer.initialize(repeating: .empty, count: Self.capacity)
    }
    deinit { buffer.deinitialize(count: Self.capacity); buffer.deallocate() }

    /// Produzent. false = Ring voll (Ereignis nicht übernommen).
    @inline(__always)
    func push(_ e: AUEvent) -> Bool {
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        guard t &- h < Self.capacity else { return false }
        buffer[t & Self.mask] = e
        tail.store(t &+ 1, ordering: .releasing)
        return true
    }

    /// Konsument. false = Ring leer.
    @inline(__always)
    func pop(into e: inout AUEvent) -> Bool {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        guard h != t else { return false }
        e = buffer[h & Self.mask]
        head.store(h &+ 1, ordering: .releasing)
        return true
    }
}

// MARK: - AUEventQueue

/// Übergabe von Ereignissen an EIN gehostetes Instrument (v1.13.0, Vertrag v1.13.13).
///
/// **Zeitbasis.** Der Tick-Pfad datiert Ereignisse wie für CoreMIDI in Host-Zeit. Der
/// Render-Durchlauf des Instruments (Render-Observer, Audio-Thread) rechnet jedes fällige
/// Ereignis über den Zeitstempel seines Blocks in einen Sample-Offset um.
///
/// **Threads.**
///   - `pushFromTick` / `pushParameterFromTick`: Inhaber des Tick-Zutritts — ein Produzent.
///   - `pushFromMain`: Main-Thread (Vorhören, Panik, Aufräumen) — eigener Ring.
///   - `render`: Audio-Thread des Instruments — einziger Konsument beider Ringe und
///     einziger Besitzer der Warteliste.
///
/// **Aufnahmevertrag (H1).** Ein Produzent erfährt, ob sein Ereignis übernommen wurde:
/// `push…` liefert `false` nur, wenn der Ring voll ist. Mit Absicht verworfen (kein
/// Instrument geladen, Ereignis für eine frühere Belegung) gilt als erledigt (`true`) — es
/// gibt niemanden, der es spielen könnte. Kein Ereignis wird je vor seiner Zeit ausgegeben:
/// Ist die Warteliste voll, bleibt der Rest im Ring, bis Platz frei wird; der Ring füllt
/// sich dann und weist neue Ereignisse ab (Gegendruck statt Vorziehen). Das Notenbuch des
/// Sequencers behält ein abgewiesenes Off und versucht es im nächsten Tick erneut.
///
/// **Arbeitsgrenze (H7).** Ein `render`-Aufruf entnimmt beiden Ringen zusammen höchstens
/// `pendingCapacity` Ereignisse (und nie mehr, als die Warteliste Platz hat) und prüft die
/// Warteliste einmal (≤ `pendingCapacity`). Füllt ein Produzent während des Leerens nach,
/// bleibt das Überzählige für den nächsten Block liegen.
///
/// **Leeren (`invalidate`) und Belegung (`beginOccupancy`) (H2/H3).** Beide Zähler steigen
/// nur. Ein Ereignis gilt, solange seine Generation und seine Belegung den aktuellen
/// entsprechen. Der Konsument liest beide zu Beginn des Blocks; begegnet ihm ein Ereignis
/// mit NEUEREM Zähler (eingereiht nach einem `invalidate`, das während dieses Blocks
/// geschah), übernimmt er dessen Stand. Ein nach dem Leeren eingereihtes Aufräum-Ereignis
/// geht dadurch nie verloren, und ältere Ereignisse fallen weg. Grenze: Was vor dem Lesen
/// der Zähler schon zur Ausgabe bestimmt war, gehört zu diesem Block — `invalidate` wirkt
/// ab dem nächsten Lesen.
///
/// **Belegung.** Der Rack vergibt Slots neu. `beginOccupancy()` beim Laden, Tauschen und
/// Entfernen eines Instruments macht alle Ereignisse ungültig, die für die vorige Belegung
/// erzeugt wurden — auch solche, die erst danach aus einem älteren Snapshot oder einem
/// verspäteten Vorhör-Off eintreffen. Der Produzent übergibt die Belegung, für die er
/// geplant hat; sie wird nicht beim Einreihen nachgestempelt.
final class AUEventQueue {

    static let pendingCapacity = 512

    private let tickRing = AUEventRing()
    private let mainRing = AUEventRing()
    private let generation = ManagedAtomic<UInt32>(1)
    private let occupancy  = ManagedAtomic<UInt32>(1)
    /// false: kein Instrument geladen — Produzenten verwerfen sofort (kein Ring-Überlauf).
    private let active = ManagedAtomic<Bool>(false)
    /// Diagnose: vom vollen Ring abgewiesene Ereignisse; Blöcke, in denen die volle
    /// Warteliste das Leeren der Ringe begrenzt hat.
    let rejected = ManagedAtomic<Int>(0)
    /// Audio-Diagnose (v1.13.14): Render-Durchläufe des Instruments vor/nach dem Rendern
    /// und gemeldete Renderfehler. Geschrieben vom Render-Observer (nur Inkrement).
    let preRenders   = ManagedAtomic<Int>(0)
    let postRenders  = ManagedAtomic<Int>(0)
    let renderErrors = ManagedAtomic<Int>(0)
    let backlog  = ManagedAtomic<Int>(0)

    // Nur Audio-Thread:
    private let pending: UnsafeMutablePointer<AUEvent>
    private var pendingCount = 0

    init() {
        pending = .allocate(capacity: Self.pendingCapacity)
        pending.initialize(repeating: .empty, count: Self.pendingCapacity)
    }
    deinit { pending.deinitialize(count: Self.pendingCapacity); pending.deallocate() }

    // MARK: Main

    var isActive: Bool { active.load(ordering: .acquiring) }
    func setActive(_ on: Bool) { active.store(on, ordering: .releasing) }

    /// Verwirft alles bisher Eingereihte (Stop, Panik, Ausschalten).
    func invalidate() { generation.wrappingIncrement(ordering: .acquiringAndReleasing) }

    /// Neue Belegung des Slots (Instrument geladen, getauscht, entfernt). Liefert die
    /// Epoche, die Produzenten für die neue Belegung übergeben.
    @discardableResult
    func beginOccupancy() -> UInt32 {
        occupancy.wrappingIncrementThenLoad(ordering: .acquiringAndReleasing)
    }

    /// Aktuelle Belegung (Main: für Snapshot und Vorhören).
    var occupancyEpoch: UInt32 { occupancy.load(ordering: .acquiring) }

    // MARK: Produzenten

    /// - Parameter epoch: Belegung, für die geplant wurde (aus dem Snapshot); nil = aktuelle.
    /// - Returns: false nur bei vollem Ring.
    @inline(__always) @discardableResult
    func pushFromTick(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, at hostTime: UInt64,
                      epoch: UInt32? = nil) -> Bool {
        push(tickRing, AUEvent.pack(b0, b1, b2), hostTime, epoch, address: 0, isParameter: false)
    }

    /// Parameterwert (bereits im Wertebereich des Parameters) für das Instrument.
    @inline(__always) @discardableResult
    func pushParameterFromTick(address: UInt64, value: Float, at hostTime: UInt64,
                               epoch: UInt32? = nil) -> Bool {
        push(tickRing, value.bitPattern, hostTime, epoch, address: address, isParameter: true)
    }

    @discardableResult
    func pushFromMain(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, at hostTime: UInt64 = 0,
                      epoch: UInt32? = nil) -> Bool {
        push(mainRing, AUEvent.pack(b0, b1, b2), hostTime, epoch, address: 0, isParameter: false)
    }

    @inline(__always)
    private func push(_ ring: AUEventRing, _ packed: UInt32, _ hostTime: UInt64, _ epoch: UInt32?,
                      address: UInt64, isParameter: Bool) -> Bool {
        guard active.load(ordering: .relaxed) else { return true }           // niemand da
        let current = occupancy.load(ordering: .acquiring)
        let target = epoch ?? current
        guard target == current else { return true }                         // andere Belegung
        let e = AUEvent(hostTime: hostTime, packed: packed,
                        generation: generation.load(ordering: .acquiring), epoch: target,
                        address: address, isParameter: isParameter)
        if ring.push(e) { return true }
        rejected.wrappingIncrement(ordering: .relaxed)
        return false
    }

    // MARK: Konsument (Audio-Thread)

    /// Gibt alle Ereignisse aus, die in den Renderblock `[hostStart, hostStart + frames)`
    /// fallen oder überfällig sind. `emit(offset, packed)` wird je MIDI-Ereignis mit dem
    /// Sample-Offset im Block (0 ..< frames) aufgerufen.
    ///
    /// - Parameter hostValid: false, wenn der Block keine gültige Host-Zeit trägt
    ///   (Offline-Rendering) — dann gilt alles Eingereihte als fällig, Offset 0.
    @inline(__always)
    func render(hostStart: UInt64, hostValid: Bool, frames: Int, ticksPerFrame: Double,
                emit: (Int, UInt32) -> Void) {
        render(hostStart: hostStart, hostValid: hostValid, frames: frames,
               ticksPerFrame: ticksPerFrame, emit: emit, emitParameter: { _, _, _ in })
    }

    /// Wie oben; Parameter-Ereignisse gehen an `emitParameter(offset, address, value)`.
    @inline(__always)
    func render(hostStart: UInt64, hostValid: Bool, frames: Int, ticksPerFrame: Double,
                emit: (Int, UInt32) -> Void, emitParameter: (Int, UInt64, Float) -> Void) {
        var gen = generation.load(ordering: .acquiring)
        var occ = occupancy.load(ordering: .acquiring)
        #if DEBUG
        _afterCountersLoaded?()
        #endif

        // 1. Ringe in die Warteliste leeren — höchstens so viel, wie Platz ist (Main zuerst:
        //    Panik/Aufräumen sind „sofort").
        var drained = 0
        let limitedMain = drain(mainRing, gen: &gen, occ: &occ, drained: &drained)
        let limitedTick = drain(tickRing, gen: &gen, occ: &occ, drained: &drained)
        if limitedMain || limitedTick { backlog.wrappingIncrement(ordering: .relaxed) }
        #if DEBUG
        _lastDrainCount = drained
        #endif
        guard pendingCount > 0 else { return }

        // Zähler, die seit Blockbeginn gestiegen sind, gelten ab hier (nie rückwärts).
        let g2 = generation.load(ordering: .acquiring), o2 = occupancy.load(ordering: .acquiring)
        if counterIsNewer(g2, than: gen) { gen = g2 }
        if counterIsNewer(o2, than: occ) { occ = o2 }

        // 2. Fälliges in Ankunftsreihenfolge ausgeben, Rest stabil nach vorn schieben.
        let span    = Double(max(frames, 1)) * ticksPerFrame
        let hostEnd = hostStart &+ UInt64(span)
        var keep = 0
        for i in 0..<pendingCount {
            let p = pending[i]
            if p.generation != gen || p.epoch != occ { continue }          // ungültig gemacht
            if !hostValid || p.hostTime == 0 || p.hostTime < hostEnd {
                var offset = 0
                if hostValid, p.hostTime > hostStart, ticksPerFrame > 0 {
                    offset = min(max(frames, 1) - 1, Int(Double(p.hostTime - hostStart) / ticksPerFrame))
                }
                if p.isParameter { emitParameter(offset, p.address, Float(bitPattern: p.packed)) }
                else { emit(offset, p.packed) }
            } else {
                pending[keep] = p
                keep += 1
            }
        }
        pendingCount = keep
    }

    /// Entnimmt einem Ring, solange die Warteliste Platz hat. true = durch volle
    /// Warteliste begrenzt (Rest bleibt im Ring).
    @inline(__always)
    private func drain(_ ring: AUEventRing, gen: inout UInt32, occ: inout UInt32,
                       drained: inout Int) -> Bool {
        var e = AUEvent.empty
        // Zwei Grenzen: Platz in der Warteliste und Gesamtzahl der Entnahmen je Block —
        // auch verworfene (veraltete) Ereignisse zählen, sonst wäre die Arbeit unbegrenzt.
        while pendingCount < Self.pendingCapacity, drained < Self.pendingCapacity {
            guard ring.pop(into: &e) else { return false }
            drained += 1
            if counterIsNewer(e.generation, than: gen) { gen = e.generation }
            if counterIsNewer(e.epoch, than: occ) { occ = e.epoch }
            guard e.generation == gen, e.epoch == occ else { continue }    // veraltet
            pending[pendingCount] = e
            pendingCount += 1
        }
        return true
    }

    #if DEBUG
    /// Nur für Tests, nur wenn kein Render läuft.
    var _pendingCount: Int { pendingCount }
    var _rejectedCount: Int { rejected.load(ordering: .relaxed) }
    var _backlogCount:  Int { backlog.load(ordering: .relaxed) }
    /// Zahl der im letzten `render` entnommenen Ereignisse.
    private(set) var _lastDrainCount = 0
    /// Testhaken: läuft im `render` direkt nach dem Lesen der Zähler (Interleaving-Tests).
    var _afterCountersLoaded: (() -> Void)?
    #endif
}
