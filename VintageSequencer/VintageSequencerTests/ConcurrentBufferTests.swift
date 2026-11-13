import Testing
import Foundation
@testable import VintageSequencer

// MARK: - ConcurrentBufferTests
//
// T1 — Stellt sicher, dass EngineEventBuffer unter simultanen Push (Background-Thread)
// und Drain (Test-Thread) keine Crashes erzeugt und innerhalb der erwarteten Grenzen bleibt.
//
// Modelliert den RT-Pfad: pushPatternSwitch() wird vom Tick-Thread aufgerufen,
// drain() vom Main-Thread. Hier simuliert durch Thread.detachNewThread.
//
// Erwartung:
//   - Kein Crash
//   - received >= 0  (drain kann nie negative Werte liefern)
//   - received <= total  (drain kann nie mehr Events liefern als gepushed wurden)

struct ConcurrentBufferTests {

    @Test func concurrentPushDrainDoesNotCrash() {
        let buf   = EngineEventBuffer()
        let done  = DispatchSemaphore(value: 0)
        let total = 500

        // Simulate audio thread: push 500 patternSwitch events
        Thread.detachNewThread {
            for i in 0..<total {
                buf.pushPatternSwitch(patternIdx: UInt8(i & 0x03))
            }
            done.signal()
        }

        // Drain on test thread while push is running
        var received = 0
        while done.wait(timeout: .now()) == .timedOut {
            buf.drain { _ in received += 1 }
        }
        // Final drain after push thread has finished
        buf.drain { _ in received += 1 }

        #expect(received >= 0)
        #expect(received <= total)
    }
}
