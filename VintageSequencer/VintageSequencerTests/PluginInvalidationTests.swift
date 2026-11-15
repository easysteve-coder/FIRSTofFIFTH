import Testing
import Foundation
@testable import VintageSequencer

// v1.18.20 — iMac-Hänger (Stephan: „wieder ein sat1 rad hänger beim imac unter 1.18.17").
// Stichprobe: Main hing in `detach` beim Instrumentwechsel, synchroner XPC-Aufruf an das Plug-in.
// Dessen XPC-Warteschlange hing im Melden der Invalidierung und wartete auf Main, weil der
// Beobachter mit `queue: .main` angemeldet war. Hier: Main ist belegt (wie im synchronen Aufruf),
// die Meldung kommt von einer anderen Warteschlange. Sie muss sofort zurückkehren.

@MainActor @Suite struct PluginInvalidationTests {
    @Test func invalidationDoesNotWaitForMain() {
        let rack = InstrumentRack()
        let returned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            NotificationCenter.default.post(name: InstrumentRack.invalidationName, object: NSObject())
            returned.signal()
        }
        // Main bewusst belegt: so stand er im Hänger. Mit dem alten Beobachter liefe das in die Frist.
        let result = returned.wait(timeout: .now() + 2)
        #expect(result == .success, "Invalidierung wartet auf Main — Verklemmung mit synchronem XPC")
        withExtendedLifetime(rack) {}
    }
}
