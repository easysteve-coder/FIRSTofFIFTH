import Testing
@testable import VintageSequencer

// MARK: - DisplayEventBuffer Tests
//
// Testet das funktionale Grundverhalten des SPSC-Ring-Buffers im Single-Thread-Kontext.
// Kein Threading, kein Tick-Thread, keine Performance-Benchmarks.
//
// Implementation-Details, auf die sich die Tests stützen:
//   - capacity = 64 Slots, davon maximal 63 nutzbar
//     (ein Slot bleibt frei, um Voll/Leer zu unterscheiden)
//   - push(): trylock → bei vollem Buffer wird das Event still verworfen
//   - drain(): lock, liest alle vorhandenen Events in Einfügereihenfolge (FIFO)

struct DisplayEventBufferTests {

    // MARK: - Grundverhalten: Push + Drain

    /// Ein Event pushen, drainen, Inhalt prüfen, erneut drainen → leer.
    @Test func singlePushDrain() {
        let buffer = DisplayEventBuffer()

        buffer.push(trackIdx: 2, stepIdx: 7, hostTime: 0)

        var received: [DisplayEvent] = []
        buffer.drain { received.append($0) }

        #expect(received.count       == 1)
        #expect(received[0].trackIdx == 2)
        #expect(received[0].stepIdx  == 7)

        // Buffer muss nach dem Drain leer sein
        var secondDrain: [DisplayEvent] = []
        buffer.drain { secondDrain.append($0) }
        #expect(secondDrain.isEmpty)
    }

    // MARK: - FIFO-Reihenfolge

    /// Mehrere unterschiedliche Events — Drain muss Einfügereihenfolge exakt einhalten.
    @Test func multipleEventsPreserveFIFOOrder() {
        let buffer = DisplayEventBuffer()

        let input: [(UInt8, UInt8)] = [(0,0), (1,5), (2,10), (3,15), (0,1)]
        for (t, s) in input {
            buffer.push(trackIdx: t, stepIdx: s, hostTime: 0)
        }

        var received: [(UInt8, UInt8)] = []
        buffer.drain { received.append(($0.trackIdx, $0.stepIdx)) }

        #expect(received.count == input.count)
        for i in input.indices {
            #expect(received[i].0 == input[i].0, "trackIdx an Index \(i) falsch")
            #expect(received[i].1 == input[i].1, "stepIdx an Index \(i) falsch")
        }
    }

    // MARK: - Leerer Buffer

    /// Drain auf leerem Buffer — kein Crash, kein Event, korrekter Early-Exit.
    @Test func drainEmptyBufferDoesNothing() {
        let buffer = DisplayEventBuffer()

        var callCount = 0
        buffer.drain { _ in callCount += 1 }

        #expect(callCount == 0)
    }

    /// Mehrfacher Drain hintereinander auf leerem Buffer bleibt stabil.
    @Test func repeatedDrainOnEmptyBufferIsStable() {
        let buffer = DisplayEventBuffer()

        var total = 0
        buffer.drain { _ in total += 1 }
        buffer.drain { _ in total += 1 }
        buffer.drain { _ in total += 1 }

        #expect(total == 0)
    }

    // MARK: - Überlaufverhalten

    /// Der Buffer fasst maximal 63 Events (capacity=64, ein Slot reserviert).
    /// Überzählige Events werden still verworfen — kein Crash.
    @Test func overflowDropsEventsGracefully() {
        let buffer   = DisplayEventBuffer()
        let maxUsable = DisplayEventBuffer.capacity

        // Mehr Events einfügen, als der Ring fasst — der Überschuss wird verworfen
        for i in 0..<(maxUsable + 7) {
            buffer.push(trackIdx: 0, stepIdx: UInt8(i % 63), hostTime: 0)
        }

        var received: [DisplayEvent] = []
        buffer.drain { received.append($0) }

        // Kein Crash, exakt maxUsable Events erhalten
        #expect(received.count == maxUsable,
                "Erwartet \(maxUsable) Events, erhalten \(received.count)")
    }

    /// Nach einem Überlauf lässt sich der Buffer nach dem Drain normal weiterverwenden.
    @Test func overflowFollowedByDrainThenReuse() {
        let buffer = DisplayEventBuffer()

        // Buffer füllen (Überlauf erzeugen)
        for _ in 0..<(DisplayEventBuffer.capacity + 7) {
            buffer.push(trackIdx: 1, stepIdx: 0, hostTime: 0)
        }

        // Leeren
        var firstBatch: [DisplayEvent] = []
        buffer.drain { firstBatch.append($0) }
        #expect(firstBatch.count == DisplayEventBuffer.capacity)

        // Erneut befüllen und drainen
        buffer.push(trackIdx: 3, stepIdx: 9, hostTime: 0)
        buffer.push(trackIdx: 4, stepIdx: 11, hostTime: 0)

        var secondBatch: [DisplayEvent] = []
        buffer.drain { secondBatch.append($0) }

        #expect(secondBatch.count       == 2)
        #expect(secondBatch[0].trackIdx == 3)
        #expect(secondBatch[0].stepIdx  == 9)
        #expect(secondBatch[1].trackIdx == 4)
        #expect(secondBatch[1].stepIdx  == 11)
    }

    // MARK: - Wiederverwendung nach Drain

    /// Push → Drain → Push → Drain: Buffer muss mehrere Zyklen korrekt durchlaufen.
    @Test func reuseAfterDrainIsCorrect() {
        let buffer = DisplayEventBuffer()

        // Zyklus 1
        buffer.push(trackIdx: 0, stepIdx: 1, hostTime: 0)
        buffer.push(trackIdx: 0, stepIdx: 2, hostTime: 0)

        var cycle1: [DisplayEvent] = []
        buffer.drain { cycle1.append($0) }

        #expect(cycle1.count       == 2)
        #expect(cycle1[0].stepIdx  == 1)
        #expect(cycle1[1].stepIdx  == 2)

        // Zyklus 2 — unterschiedliche Werte
        buffer.push(trackIdx: 1, stepIdx: 10, hostTime: 0)

        var cycle2: [DisplayEvent] = []
        buffer.drain { cycle2.append($0) }

        #expect(cycle2.count       == 1)
        #expect(cycle2[0].trackIdx == 1)
        #expect(cycle2[0].stepIdx  == 10)

        // Zyklus 3 — leer
        var cycle3: [DisplayEvent] = []
        buffer.drain { cycle3.append($0) }
        #expect(cycle3.isEmpty)
    }

    /// Viele Push/Drain-Zyklen mit wechselnden Batchgrößen bleiben konsistent.
    @Test func multipleSmallCyclesRemainConsistent() {
        let buffer = DisplayEventBuffer()

        for cycle in 0..<10 {
            let batchSize = cycle + 1   // 1, 2, 3, ... 10
            for step in 0..<batchSize {
                buffer.push(trackIdx: UInt8(cycle), stepIdx: UInt8(step), hostTime: 0)
            }

            var received: [DisplayEvent] = []
            buffer.drain { received.append($0) }

            #expect(received.count == batchSize, "Zyklus \(cycle): falsche Anzahl Events")
            for (i, event) in received.enumerated() {
                #expect(event.trackIdx == UInt8(cycle), "Zyklus \(cycle), Index \(i): trackIdx falsch")
                #expect(event.stepIdx  == UInt8(i),     "Zyklus \(cycle), Index \(i): stepIdx falsch")
            }
        }
    }

    // MARK: - Randwerte

    /// UInt8-Randwerte (0 und 255) werden korrekt gespeichert und ausgelesen.
    @Test func uint8BoundaryValuesRoundtrip() {
        let buffer = DisplayEventBuffer()

        buffer.push(trackIdx: 0,   stepIdx: 0, hostTime: 0)
        buffer.push(trackIdx: 255, stepIdx: 255, hostTime: 0)
        buffer.push(trackIdx: 0,   stepIdx: 255, hostTime: 0)
        buffer.push(trackIdx: 255, stepIdx: 0, hostTime: 0)

        var received: [DisplayEvent] = []
        buffer.drain { received.append($0) }

        #expect(received.count == 4)
        #expect(received[0].trackIdx == 0   && received[0].stepIdx == 0)
        #expect(received[1].trackIdx == 255 && received[1].stepIdx == 255)
        #expect(received[2].trackIdx == 0   && received[2].stepIdx == 255)
        #expect(received[3].trackIdx == 255 && received[3].stepIdx == 0)
    }
}
