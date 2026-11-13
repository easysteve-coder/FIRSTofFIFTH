import Testing
import Foundation
@testable import VintageSequencer

// MARK: - MIDIManagerRTSafeTests
//
// RT-4c: sendRTSafe() liest den aktuell gewählten Output-Endpoint jetzt über
// einen atomaren Snapshot (rtOutputAtomic) statt über os_unfair_lock_trylock.
// Der frühere Trylock konnte bei Kontention (Main-Thread schreibt gerade
// selectedOutput) `out == 0` liefern und das Event still überspringen — auch
// wenn tatsächlich ein Output gewählt war. Diese Tests laufen ohne echtes
// CoreMIDI-Setup (MIDIManager() hat vor setup() keine Seiteneffekte) und
// prüfen ausschließlich den Atomic-Mirror-Mechanismus selbst.

struct MIDIManagerRTSafeTests {

    @Test func atomicMirrorReflectsSelectedOutputSynchronously() {
        let midi = MIDIManager()

        midi.selectedOutput = 42
        #expect(midi._rt4cReadOutputAtomic() == 42)

        midi.selectedOutput = 7
        #expect(midi._rt4cReadOutputAtomic() == 7)

        midi.selectedOutput = 0
        #expect(midi._rt4cReadOutputAtomic() == 0)
    }

    @Test func zeroIsPreservedWhenNoOutputSelected() {
        let midi = MIDIManager()
        #expect(midi._rt4cReadOutputAtomic() == 0, "Frisch konstruiert: kein Output gewählt")

        midi.selectedOutput = 0
        #expect(midi._rt4cReadOutputAtomic() == 0)
    }

    /// Regressionstest gegen den behobenen Bug: selectedOutput ist während
    /// der gesamten Stress-Phase nie 0 (nur 42/99) — der atomare Read darf
    /// unter paralleler Main-seitiger Schreiblast trotzdem NIE 0 liefern.
    /// Der frühere Trylock-Drop konnte genau das (mit geringer
    /// Wahrscheinlichkeit) tun, wenn der Lock kurz contended war.
    @Test func atomicReadNeverFalsePositiveZeroUnderContention() {
        let midi = MIDIManager()
        midi.selectedOutput = 42

        let iterations = 5000
        var observedZero = false
        let lock = NSLock()

        let readerThread = Thread {
            for _ in 0..<iterations {
                let v = midi._rt4cReadOutputAtomic()
                if v == 0 {
                    lock.lock(); observedZero = true; lock.unlock()
                }
            }
        }
        readerThread.start()

        for i in 0..<iterations {
            midi.selectedOutput = (i % 2 == 0) ? 42 : 99
        }

        while !readerThread.isFinished { Thread.sleep(forTimeInterval: 0.001) }

        #expect(!observedZero,
                "Atomarer Read darf unter Kontention nie fälschlich 0 liefern — selectedOutput war nie 0")
    }
}
