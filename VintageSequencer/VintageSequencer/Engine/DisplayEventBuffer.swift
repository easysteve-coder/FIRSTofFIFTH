import Atomics

// MARK: - DisplayEvent

/// Ein Display-Update-Event: welcher Track welchen Step anzeigen soll.
///
/// Produziert vom Tick-Thread, konsumiert vom Main-Thread (Display-Drain).
struct DisplayEvent {
    var trackIdx: UInt8
    var stepIdx:  UInt8
    var hostTime: UInt64      // geplanter Tick-Zeitpunkt (MIDITimeStamp)
}

// MARK: - DisplayEventBuffer

/// Lock-freier SPSC-Ring für DisplayEvents (v1.12.19; ersetzt den Trylock-Puffer).
///
/// Single Producer: Tick-Thread. Single Consumer: Main-Thread.
///
/// - Feste Größe, Speicher ausschließlich in init alloziert.
/// - `push` ist wartefrei: zwei atomare Loads, ein Slot-Write, ein atomarer Store.
///   Kein Lock — ein gleichzeitiger `drain` kann kein Event mehr verdrängen.
/// - Monotone Zähler (kein Wrap): Slot = Zähler & Maske. `head` schreibt nur der
///   Consumer, `tail` nur der Producer.
/// - Voller Ring: Event wird verworfen (reine Anzeige, das nächste Event korrigiert).
final class DisplayEventBuffer {

    static let capacity = 1024                     // Zweierpotenz
    private let mask = DisplayEventBuffer.capacity - 1
    private let slots: UnsafeMutablePointer<DisplayEvent>
    private let head = ManagedAtomic<Int>(0)
    private let tail = ManagedAtomic<Int>(0)

    init() {
        slots = .allocate(capacity: Self.capacity)
        slots.initialize(repeating: DisplayEvent(trackIdx: 0, stepIdx: 0, hostTime: 0),
                         count: Self.capacity)
    }

    deinit {
        slots.deinitialize(count: Self.capacity)
        slots.deallocate()
    }

    // MARK: - Producer (Tick-Thread)

    @inline(__always)
    func push(trackIdx: UInt8, stepIdx: UInt8, hostTime: UInt64) {
        let t = tail.load(ordering: .relaxed)          // nur der Producer schreibt tail
        let h = head.load(ordering: .acquiring)
        guard t &- h < Self.capacity else { return }   // voll → verwerfen
        slots[t & mask] = DisplayEvent(trackIdx: trackIdx, stepIdx: stepIdx, hostTime: hostTime)
        tail.store(t &+ 1, ordering: .releasing)       // Slot veröffentlichen
    }

    // MARK: - Consumer (Main-Thread)

    func drain(_ handler: (DisplayEvent) -> Void) {
        var h = head.load(ordering: .relaxed)          // nur der Consumer schreibt head
        let t = tail.load(ordering: .acquiring)
        while h != t {
            handler(slots[h & mask])
            h &+= 1
        }
        head.store(h, ordering: .releasing)
    }
}
