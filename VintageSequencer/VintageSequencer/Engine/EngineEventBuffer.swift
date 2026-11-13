import Atomics

// MARK: - EngineEvent

/// Ein Engine-Event für Main-Thread-seitige Mutationen, die aus dem Tick-Thread ausgelöst werden.
///
/// Produziert vom Tick-Thread (push), konsumiert vom Main-Thread (drain via displayDrainTimer).
///
/// Feste Größe, kein Heap-Alloc im Push-Pfad:
///   — Noten werden inline als bis zu 8 UInt8-Felder gespeichert.
///   — Kein Swift-Array, keine Closure, kein ARC im Push-Pfad.
struct EngineEvent {

    enum Tag: UInt8 {
        /// Track-Visualisierung aktualisieren: lastFiredNotes setzen, dann nach offDelayMs löschen.
        case notesFired    = 0
        /// Pattern-Wechsel auf dem Main-Thread ausführen (Quantisierungspunkt: Track-0-Wrap).
        case patternSwitch = 1
    }

    var tag:        Tag
    var trackIdx:   UInt8    // notesFired: Track-Index
    var patternIdx: UInt8    // patternSwitch: Ziel-Pattern-Index
    var noteCount:  UInt8    // notesFired: Anzahl aktiver Noten (0–8)
    var offDelayMs: UInt16   // notesFired: Gate-Dauer in ms → asyncAfter-Clear auf Main-Thread

    // Inline-Noten: kein Heap-Alloc.
    // Maximale Chord-Größe in der Praxis ≤ 8; darüber hinausgehende Noten werden still verworfen.
    var note0: UInt8; var note1: UInt8; var note2: UInt8; var note3: UInt8
    var note4: UInt8; var note5: UInt8; var note6: UInt8; var note7: UInt8

    /// Alle aktiven Noten als [Int] — nur auf dem Main-Thread aufrufen (kein RT-Kontext).
    func notesArray() -> [Int] {
        let raw: [UInt8] = [note0, note1, note2, note3, note4, note5, note6, note7]
        return raw.prefix(Int(noteCount)).map { Int($0) }
    }
}

// MARK: - EngineEventBuffer

/// Lock-freier SPSC-Ring für EngineEvents (v1.12.19; ersetzt den Trylock-Puffer).
///
/// Single Producer: Tick-Thread (push — wartefrei). Single Consumer: Main-Thread.
/// Aufbau wie `DisplayEventBuffer`: monotone Zähler, `head` schreibt nur der Consumer,
/// `tail` nur der Producer; kein Lock, kein Heap im Push-Pfad.
///
/// Der Ring trägt nur verzichtbare Hinweise: Noten-Visualisierung und einen Weckruf
/// für den Patternwechsel. Der Patternwechsel selbst wird über ein Atomic zugestellt
/// (`SequencerEngine.rtSwitchedSerial`) und geht bei vollem Ring nicht verloren.
final class EngineEventBuffer {

    static let capacity = 256                      // Zweierpotenz
    private let mask = EngineEventBuffer.capacity - 1
    private let slots: UnsafeMutablePointer<EngineEvent>
    private let head = ManagedAtomic<Int>(0)
    private let tail = ManagedAtomic<Int>(0)

    private static let empty = EngineEvent(
        tag: .notesFired,
        trackIdx: 0, patternIdx: 0,
        noteCount: 0, offDelayMs: 0,
        note0: 0, note1: 0, note2: 0, note3: 0,
        note4: 0, note5: 0, note6: 0, note7: 0)

    init() {
        slots = .allocate(capacity: Self.capacity)
        slots.initialize(repeating: Self.empty, count: Self.capacity)
    }

    deinit {
        slots.deinitialize(count: Self.capacity)
        slots.deallocate()
    }

    @inline(__always)
    private func push(_ ev: EngineEvent) {
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        guard t &- h < Self.capacity else { return }   // voll → verwerfen
        slots[t & mask] = ev
        tail.store(t &+ 1, ordering: .releasing)
    }

    // MARK: - Producer (Tick-Thread)

    /// Schreibt ein notesFired-Event. `notes` stammt aus dem unveränderlichen Snapshot;
    /// es werden nur Werte kopiert (max. 8, weitere entfallen).
    @inline(__always)
    func pushNotesFired(trackIdx: UInt8, notes: [Int], offDelayMs: UInt16) {
        let n = min(notes.count, 8)
        var ev = Self.empty
        ev.trackIdx = trackIdx
        ev.noteCount = UInt8(n)
        ev.offDelayMs = offDelayMs
        if n > 0 { ev.note0 = UInt8(clamping: notes[0]) }
        if n > 1 { ev.note1 = UInt8(clamping: notes[1]) }
        if n > 2 { ev.note2 = UInt8(clamping: notes[2]) }
        if n > 3 { ev.note3 = UInt8(clamping: notes[3]) }
        if n > 4 { ev.note4 = UInt8(clamping: notes[4]) }
        if n > 5 { ev.note5 = UInt8(clamping: notes[5]) }
        if n > 6 { ev.note6 = UInt8(clamping: notes[6]) }
        if n > 7 { ev.note7 = UInt8(clamping: notes[7]) }
        push(ev)
    }

    /// Schreibt ein patternSwitch-Event (Weckruf für den Main-seitigen Abgleich).
    @inline(__always)
    func pushPatternSwitch(patternIdx: UInt8) {
        var ev = Self.empty
        ev.tag = .patternSwitch
        ev.patternIdx = patternIdx
        push(ev)
    }

    // MARK: - Consumer (Main-Thread)

    func drain(_ handler: (EngineEvent) -> Void) {
        var h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        while h != t {
            handler(slots[h & mask])
            h &+= 1
        }
        head.store(h, ordering: .releasing)
    }
}
