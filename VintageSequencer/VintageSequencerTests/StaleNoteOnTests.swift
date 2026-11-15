import Testing
import Foundation
import Atomics
@testable import VintageSequencer

// v1.18.36 — Stephan: „solo schalten und solo entfernen gibt es massive übersteuerungen". Wurde ein
// Instrument eine Weile nicht gerendert (Solo eines anderen Kanals, SCXT lädt ein Kit), lagen alle
// aufgelaufenen Note-Ons im nächsten Block auf Offset 0 (gemessen +19 dBFS). Überfällige Note-Ons
// verwirft die Warteschlange; Offs, CCs und Parameter gehen weiter hinaus.

@Suite struct StaleNoteOnTests {

    private func render(_ q: AUEventQueue, at hostStart: UInt64) -> [UInt32] {
        var out: [UInt32] = []
        q.render(hostStart: hostStart, hostValid: true, frames: 512, ticksPerFrame: 1,
                 emit: { _, p in out.append(p) }, emitParameter: { _, _, _ in })
        return out
    }

    @Test func overdueNoteOnsAreDroppedOffsAndCCsStay() {
        let q = AUEventQueue()
        q.setActive(true)
        let late = UInt64(AUEventQueue.staleFrames) * 3          // weit überfällig
        let now: UInt64 = 1_000_000
        q.pushFromTick(0x90, 60, 100, at: now - late)
        q.pushFromTick(0x80, 60, 0, at: now - late + 10)
        q.pushFromTick(0xB0, 74, 64, at: now - late + 20)
        q.pushFromTick(0x90, 62, 0, at: now - late + 30)              // Note-On mit Anschlag 0 = Off
        let out = render(q, at: now)
        #expect(out == [AUEvent.pack(0x80, 60, 0), AUEvent.pack(0xB0, 74, 64), AUEvent.pack(0x90, 62, 0)])
        #expect(q.staleNoteOns.load(ordering: .relaxed) == 1)
    }

    @Test func slightlyLateAndTimelyNoteOnsStillPlay() {
        let q = AUEventQueue()
        q.setActive(true)
        let now: UInt64 = 1_000_000
        q.pushFromTick(0x90, 60, 100, at: now - UInt64(AUEventQueue.staleFrames) / 2)   // knapp zu spät
        q.pushFromTick(0x90, 64, 100, at: now + 100)                                   // in diesem Block
        let out = render(q, at: now)
        #expect(out == [AUEvent.pack(0x90, 60, 100), AUEvent.pack(0x90, 64, 100)])
        #expect(q.staleNoteOns.load(ordering: .relaxed) == 0)
    }

    @Test func immediateEventsAreNeverStale() {
        let q = AUEventQueue()
        q.setActive(true)
        q.pushFromMain(0x90, 60, 100)                            // Vorhören: „sofort" (Zeit 0)
        #expect(render(q, at: 10_000_000) == [AUEvent.pack(0x90, 60, 100)])
    }
}
