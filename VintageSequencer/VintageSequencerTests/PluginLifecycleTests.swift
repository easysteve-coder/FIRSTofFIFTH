import Testing
import Foundation
import AVFoundation
import AppKit
@testable import VintageSequencer

// v1.18.5 — PluginLifecycle (Zerlegung des Racks, Schritt 5): Editorfenster gehören dem
// Lebenszyklus. Ein Editor, der vor dem Eintreffen seines Fensters geschlossen wird, darf
// nicht verwaist auftauchen; ein zweiter Aufruf während des Anforderns öffnet kein zweites.

@MainActor @Suite(.serialized) struct PluginLifecycleTests {

    private func delayUnit() -> AVAudioUnit { AVAudioUnitDelay() }

    private func settle(_ ms: UInt64 = 600) async throws {
        try await Task.sleep(nanoseconds: ms * 1_000_000)
    }

    private func windows(titled title: String) -> [NSWindow] {
        NSApp.windows.filter { $0.title == title && $0.isVisible }
    }

    @Test func editorClosedBeforeArrivalStaysClosed() async throws {
        let life = PluginLifecycle(hostSync: HostSync(), recorder: AudioDiagnostics())
        let key = PluginLifecycle.Editor.effect(UUID())
        let title = "PLT-close-\(UUID().uuidString.prefix(6))"
        life.openEditor(key, unit: delayUnit(), title: title)
        life.closeEditor(key)
        try await settle()
        #expect(life.window(key) == nil)
        #expect(windows(titled: title).isEmpty)
    }

    @Test func secondOpenWhilePendingOpensOneWindow() async throws {
        let life = PluginLifecycle(hostSync: HostSync(), recorder: AudioDiagnostics())
        let key = PluginLifecycle.Editor.effect(UUID())
        let title = "PLT-once-\(UUID().uuidString.prefix(6))"
        let unit = delayUnit()
        life.openEditor(key, unit: unit, title: title)
        life.openEditor(key, unit: unit, title: title)
        try await settle()
        let w = try #require(life.window(key))
        #expect(windows(titled: title).count == 1)
        life.closeEditor(key)
        #expect(!w.isVisible)
        #expect(life.window(key) == nil)
    }

    @Test func stateRoundTrip() throws {
        let a = AVAudioUnitDelay(); a.delayTime = 0.42
        let data = try #require(PluginLifecycle.stateData(of: a))
        let b = AVAudioUnitDelay()
        PluginLifecycle.restoreState(data, into: b)
        #expect(abs(b.delayTime - 0.42) < 0.0001)
    }
}
