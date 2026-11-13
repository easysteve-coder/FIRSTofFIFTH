import Testing
@testable import VintageSequencer

// MARK: - EngineEventBuffer Tests
//
// Testet das funktionale Grundverhalten des EngineEventBuffers im Single-Thread-Kontext.
// Kein Threading, keine Tick-Thread-Simulation, keine Performance-Benchmarks.
//
// Implementation-Details, auf die sich die Tests stützen:
//   - capacity = 64 Slots, davon maximal 63 nutzbar (ein Slot reserviert)
//   - pushNotesFired(): speichert bis zu 8 Noten inline via UInt8(clamping:)
//   - pushPatternSwitch(): speichert patternIdx als UInt8
//   - drain(): FIFO, liest alle verfügbaren Events
//   - Überlauf: Event wird still verworfen, kein Crash

// MARK: - notesFired Events

struct EngineEventBufferNotesFiredTests {

    /// Ein notesFired-Event pushen und vollständig prüfen.
    @Test func singleNotesFiredRoundtrip() {
        let buffer = EngineEventBuffer()

        buffer.pushNotesFired(trackIdx: 2, notes: [60, 64, 67], offDelayMs: 250)

        var received: [EngineEvent] = []
        buffer.drain { received.append($0) }

        #expect(received.count          == 1)
        #expect(received[0].tag         == .notesFired)
        #expect(received[0].trackIdx    == 2)
        #expect(received[0].offDelayMs  == 250)
        #expect(received[0].noteCount   == 3)
        #expect(received[0].notesArray() == [60, 64, 67])
    }

    /// Nach dem Drain muss der Buffer leer sein.
    @Test func bufferIsEmptyAfterDrain() {
        let buffer = EngineEventBuffer()

        buffer.pushNotesFired(trackIdx: 0, notes: [48], offDelayMs: 100)

        buffer.drain { _ in }   // einmal leeren

        var secondDrain: [EngineEvent] = []
        buffer.drain { secondDrain.append($0) }
        #expect(secondDrain.isEmpty)
    }

    /// trackIdx wird korrekt gespeichert und übertragen.
    @Test func trackIdxIsPreservedCorrectly() {
        let buffer = EngineEventBuffer()

        buffer.pushNotesFired(trackIdx: 0,   notes: [60], offDelayMs: 0)
        buffer.pushNotesFired(trackIdx: 7,   notes: [60], offDelayMs: 0)
        buffer.pushNotesFired(trackIdx: 255, notes: [60], offDelayMs: 0)

        var received: [EngineEvent] = []
        buffer.drain { received.append($0) }

        #expect(received.count          == 3)
        #expect(received[0].trackIdx    == 0)
        #expect(received[1].trackIdx    == 7)
        #expect(received[2].trackIdx    == 255)
    }

    /// offDelayMs wird korrekt als UInt16 gespeichert (inkl. Randwerte).
    @Test func offDelayMsIsPreservedCorrectly() {
        let buffer = EngineEventBuffer()

        buffer.pushNotesFired(trackIdx: 0, notes: [60], offDelayMs: 0)
        buffer.pushNotesFired(trackIdx: 0, notes: [60], offDelayMs: 500)
        buffer.pushNotesFired(trackIdx: 0, notes: [60], offDelayMs: 65535)  // UInt16.max

        var received: [EngineEvent] = []
        buffer.drain { received.append($0) }

        #expect(received[0].offDelayMs == 0)
        #expect(received[1].offDelayMs == 500)
        #expect(received[2].offDelayMs == 65535)
    }

    /// noteCount und notesArray() stimmen für verschiedene Chord-Größen.
    @Test func noteCountMatchesActualNotes() {
        let buffer = EngineEventBuffer()

        buffer.pushNotesFired(trackIdx: 0, notes: [36],                    offDelayMs: 0)
        buffer.pushNotesFired(trackIdx: 0, notes: [60, 64],                offDelayMs: 0)
        buffer.pushNotesFired(trackIdx: 0, notes: [48, 52, 55, 59],        offDelayMs: 0)

        var received: [EngineEvent] = []
        buffer.drain { received.append($0) }

        #expect(received[0].noteCount   == 1)
        #expect(received[0].notesArray() == [36])

        #expect(received[1].noteCount   == 2)
        #expect(received[1].notesArray() == [60, 64])

        #expect(received[2].noteCount   == 4)
        #expect(received[2].notesArray() == [48, 52, 55, 59])
    }

    /// Grenzfall: 0 Noten — noteCount = 0, notesArray() = [].
    @Test func zeroNotesIsHandledCorrectly() {
        let buffer = EngineEventBuffer()

        buffer.pushNotesFired(trackIdx: 1, notes: [], offDelayMs: 80)

        var received: [EngineEvent] = []
        buffer.drain { received.append($0) }

        #expect(received.count           == 1)
        #expect(received[0].noteCount    == 0)
        #expect(received[0].notesArray() == [])
        #expect(received[0].offDelayMs   == 80)
    }

    /// Grenzfall: genau 8 Noten — alle werden inline gespeichert.
    @Test func maxInlineNoteCount() {
        let buffer  = EngineEventBuffer()
        let chord   = [60, 62, 64, 65, 67, 69, 71, 72]   // genau 8

        buffer.pushNotesFired(trackIdx: 0, notes: chord, offDelayMs: 0)

        var received: [EngineEvent] = []
        buffer.drain { received.append($0) }

        #expect(received[0].noteCount    == 8)
        #expect(received[0].notesArray() == chord)
    }

    /// Mehr als 8 Noten: nur die ersten 8 werden gespeichert, Rest still verworfen.
    @Test func notesAboveMaxAreDropped() {
        let buffer     = EngineEventBuffer()
        let bigChord   = [60, 62, 64, 65, 67, 69, 71, 72, 74, 76]  // 10 Noten

        buffer.pushNotesFired(trackIdx: 0, notes: bigChord, offDelayMs: 0)

        var received: [EngineEvent] = []
        buffer.drain { received.append($0) }

        #expect(received[0].noteCount    == 8,           "Erwartet 8 gespeicherte Noten")
        #expect(received[0].notesArray() == Array(bigChord.prefix(8)))
    }

    /// MIDI-Notenwerte werden via UInt8(clamping:) gespeichert — 0–127 bleiben exakt erhalten.
    @Test func midiNoteValuesAreStoredCorrectly() {
        let buffer = EngineEventBuffer()
        let notes  = [0, 1, 60, 64, 127]

        buffer.pushNotesFired(trackIdx: 0, notes: notes, offDelayMs: 0)

        var received: [EngineEvent] = []
        buffer.drain { received.append($0) }

        #expect(received[0].notesArray() == notes)
    }
}

// MARK: - patternSwitch Events

struct EngineEventBufferPatternSwitchTests {

    /// Ein patternSwitch-Event pushen und vollständig prüfen.
    @Test func singlePatternSwitchRoundtrip() {
        let buffer = EngineEventBuffer()

        buffer.pushPatternSwitch(patternIdx: 2)

        var received: [EngineEvent] = []
        buffer.drain { received.append($0) }

        #expect(received.count          == 1)
        #expect(received[0].tag         == .patternSwitch)
        #expect(received[0].patternIdx  == 2)
    }

    /// Alle vier Pattern-Indizes (0–3) werden korrekt übertragen.
    @Test func allPatternIndicesArePreserved() {
        let buffer = EngineEventBuffer()

        for idx: UInt8 in [0, 1, 2, 3] {
            buffer.pushPatternSwitch(patternIdx: idx)
        }

        var received: [EngineEvent] = []
        buffer.drain { received.append($0) }

        #expect(received.count == 4)
        for (i, event) in received.enumerated() {
            #expect(event.tag        == .patternSwitch)
            #expect(event.patternIdx == UInt8(i))
        }
    }
}

// MARK: - Gemischte Events / FIFO-Reihenfolge

struct EngineEventBufferMixedTests {

    /// notesFired und patternSwitch gemischt — FIFO-Reihenfolge muss exakt erhalten bleiben.
    @Test func mixedEventTypesMaintainFIFOOrder() {
        let buffer = EngineEventBuffer()

        buffer.pushNotesFired(trackIdx: 0, notes: [60],  offDelayMs: 100)
        buffer.pushPatternSwitch(patternIdx: 1)
        buffer.pushNotesFired(trackIdx: 1, notes: [48, 52], offDelayMs: 200)
        buffer.pushPatternSwitch(patternIdx: 3)
        buffer.pushNotesFired(trackIdx: 2, notes: [],    offDelayMs: 50)

        var received: [EngineEvent] = []
        buffer.drain { received.append($0) }

        #expect(received.count == 5)

        #expect(received[0].tag         == .notesFired)
        #expect(received[0].trackIdx    == 0)
        #expect(received[0].notesArray() == [60])
        #expect(received[0].offDelayMs  == 100)

        #expect(received[1].tag         == .patternSwitch)
        #expect(received[1].patternIdx  == 1)

        #expect(received[2].tag         == .notesFired)
        #expect(received[2].trackIdx    == 1)
        #expect(received[2].notesArray() == [48, 52])
        #expect(received[2].offDelayMs  == 200)

        #expect(received[3].tag         == .patternSwitch)
        #expect(received[3].patternIdx  == 3)

        #expect(received[4].tag         == .notesFired)
        #expect(received[4].trackIdx    == 2)
        #expect(received[4].noteCount   == 0)
        #expect(received[4].offDelayMs  == 50)
    }

    /// Drain bei leerem Buffer — kein Crash, kein Event.
    @Test func drainEmptyBufferDoesNothing() {
        let buffer = EngineEventBuffer()

        var callCount = 0
        buffer.drain { _ in callCount += 1 }

        #expect(callCount == 0)
    }

    /// Mehrfacher Drain auf leerem Buffer bleibt stabil.
    @Test func repeatedDrainOnEmptyBufferIsStable() {
        let buffer = EngineEventBuffer()

        var total = 0
        buffer.drain { _ in total += 1 }
        buffer.drain { _ in total += 1 }
        buffer.drain { _ in total += 1 }

        #expect(total == 0)
    }
}

// MARK: - Überlaufverhalten

struct EngineEventBufferOverflowTests {

    /// Mehr als 63 Events pushen — kein Crash, genau 63 Events kommen raus.
    @Test func overflowDropsEventsGracefully() {
        let buffer    = EngineEventBuffer()
        let maxUsable = EngineEventBuffer.capacity

        for i in 0..<(EngineEventBuffer.capacity + 17) {
            buffer.pushNotesFired(trackIdx: 0, notes: [i % 127 + 1], offDelayMs: UInt16(i))
        }

        var received: [EngineEvent] = []
        buffer.drain { received.append($0) }

        #expect(received.count == maxUsable,
                "Erwartet \(maxUsable) Events, erhalten \(received.count)")
    }

    /// Auch patternSwitch-Events verhalten sich bei Überlauf korrekt.
    @Test func patternSwitchOverflowDropsGracefully() {
        let buffer    = EngineEventBuffer()
        let maxUsable = EngineEventBuffer.capacity

        for i in 0..<(EngineEventBuffer.capacity + 17) {
            buffer.pushPatternSwitch(patternIdx: UInt8(i % 4))
        }

        var received: [EngineEvent] = []
        buffer.drain { received.append($0) }

        #expect(received.count == maxUsable)
        #expect(received.allSatisfy { $0.tag == .patternSwitch })
    }

    /// Nach Überlauf + Drain läuft der Buffer normal weiter.
    @Test func overflowFollowedByDrainThenReuse() {
        let buffer = EngineEventBuffer()

        // Buffer füllen (Überlauf erzeugen)
        for _ in 0..<(EngineEventBuffer.capacity + 17) {
            buffer.pushNotesFired(trackIdx: 0, notes: [60], offDelayMs: 0)
        }

        var firstBatch: [EngineEvent] = []
        buffer.drain { firstBatch.append($0) }
        #expect(firstBatch.count == EngineEventBuffer.capacity)

        // Frisch befüllen
        buffer.pushNotesFired(trackIdx: 3, notes: [48, 52], offDelayMs: 150)
        buffer.pushPatternSwitch(patternIdx: 2)

        var secondBatch: [EngineEvent] = []
        buffer.drain { secondBatch.append($0) }

        #expect(secondBatch.count           == 2)
        #expect(secondBatch[0].tag          == .notesFired)
        #expect(secondBatch[0].trackIdx     == 3)
        #expect(secondBatch[0].notesArray() == [48, 52])
        #expect(secondBatch[0].offDelayMs   == 150)
        #expect(secondBatch[1].tag          == .patternSwitch)
        #expect(secondBatch[1].patternIdx   == 2)
    }
}

// MARK: - Wiederverwendung

struct EngineEventBufferReuseTests {

    /// Push → Drain → Push → Drain: mehrere Zyklen, keine Kreuzkontamination.
    @Test func reuseAfterDrainIsCorrect() {
        let buffer = EngineEventBuffer()

        // Zyklus 1
        buffer.pushNotesFired(trackIdx: 0, notes: [60], offDelayMs: 100)
        buffer.pushPatternSwitch(patternIdx: 1)

        var cycle1: [EngineEvent] = []
        buffer.drain { cycle1.append($0) }

        #expect(cycle1.count          == 2)
        #expect(cycle1[0].tag         == .notesFired)
        #expect(cycle1[1].tag         == .patternSwitch)
        #expect(cycle1[1].patternIdx  == 1)

        // Zyklus 2 — andere Werte
        buffer.pushNotesFired(trackIdx: 2, notes: [36, 40, 43], offDelayMs: 300)

        var cycle2: [EngineEvent] = []
        buffer.drain { cycle2.append($0) }

        #expect(cycle2.count           == 1)
        #expect(cycle2[0].trackIdx     == 2)
        #expect(cycle2[0].notesArray() == [36, 40, 43])
        #expect(cycle2[0].offDelayMs   == 300)

        // Zyklus 3 — leer
        var cycle3: [EngineEvent] = []
        buffer.drain { cycle3.append($0) }
        #expect(cycle3.isEmpty)
    }

    /// Viele kleine Zyklen mit gemischten Event-Typen bleiben konsistent.
    @Test func multipleSmallMixedCyclesRemainConsistent() {
        let buffer = EngineEventBuffer()

        for cycle in 0..<8 {
            // Pro Zyklus: 1 notesFired + 1 patternSwitch
            buffer.pushNotesFired(trackIdx: UInt8(cycle), notes: [60 + cycle],
                                  offDelayMs: UInt16(cycle * 10))
            buffer.pushPatternSwitch(patternIdx: UInt8(cycle % 4))

            var received: [EngineEvent] = []
            buffer.drain { received.append($0) }

            #expect(received.count          == 2,              "Zyklus \(cycle): falsche Anzahl")
            #expect(received[0].tag         == .notesFired,    "Zyklus \(cycle): erstes Event soll notesFired sein")
            #expect(received[0].trackIdx    == UInt8(cycle),   "Zyklus \(cycle): trackIdx falsch")
            #expect(received[0].offDelayMs  == UInt16(cycle * 10), "Zyklus \(cycle): offDelayMs falsch")
            #expect(received[1].tag         == .patternSwitch, "Zyklus \(cycle): zweites Event soll patternSwitch sein")
            #expect(received[1].patternIdx  == UInt8(cycle % 4), "Zyklus \(cycle): patternIdx falsch")
        }
    }
}
