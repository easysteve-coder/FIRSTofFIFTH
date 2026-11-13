import Testing
import Foundation
import AppKit
import SwiftUI
@testable import VintageSequencer

// GUI-01 — Fader-Mathematik (echtes Interaktionsrisiko) und Playback-Last-Regression der UI.

struct MaterialFaderMathTests {
    private let range: ClosedRange<Double> = 30...120   // StepWidthState-Bereich, Schritt 1

    @Test func marksSitAtMinMidMax() {
        #expect(MaterialFaderMath.fraction(30, range: range) == 0)
        #expect(MaterialFaderMath.fraction(75, range: range) == 0.5)
        #expect(MaterialFaderMath.fraction(120, range: range) == 1)
        #expect(MaterialFaderMath.fraction(10, range: range) == 0, "außerhalb geklemmt")
        #expect(MaterialFaderMath.fraction(500, range: range) == 1)
    }

    /// Kein Sprung beim Greifen: Translation 0 liefert den Startwert; Griff greift nie „daneben“.
    @Test(arguments: [30.0, 31.0, 75.0, 119.0, 120.0])
    func zeroTranslationKeepsValue(start: Double) {
        #expect(MaterialFaderMath.dragged(start: start, translation: 0, travel: 45, range: range, step: 1) == start)
    }

    /// Min/Mitte/Maximum werden über den vollen Verfahrweg erreicht und bleiben darin (Klemmung).
    @Test func dragReachesMinMidMaxAndClamps() {
        let travel = 45.0
        #expect(MaterialFaderMath.dragged(start: 30, translation: travel, travel: travel, range: range, step: 1) == 120)
        #expect(MaterialFaderMath.dragged(start: 30, translation: travel / 2, travel: travel, range: range, step: 1) == 75)
        #expect(MaterialFaderMath.dragged(start: 120, translation: -travel, travel: travel, range: range, step: 1) == 30)
        #expect(MaterialFaderMath.dragged(start: 120, translation: 900, travel: travel, range: range, step: 1) == 120)
        #expect(MaterialFaderMath.dragged(start: 30, translation: -900, travel: travel, range: range, step: 1) == 30)
    }

    /// Gleicher Drag ergibt bei wiederholter Ausführung dieselben Werte; Ergebnis liegt auf dem 1er-Raster.
    @Test func repeatedDragIsDeterministicAndOnGrid() {
        for _ in 0..<3 {
            for t in stride(from: -50.0, through: 50.0, by: 3.7) {
                let v = MaterialFaderMath.dragged(start: 75, translation: t, travel: 45, range: range, step: 1)
                #expect(v == MaterialFaderMath.dragged(start: 75, translation: t, travel: 45, range: range, step: 1))
                #expect(v == v.rounded() && (30...120).contains(v))
            }
        }
    }

    /// Resize ändert den Wert nicht: Der Wert ist die Quelle der Wahrheit, nur die Position skaliert mit dem Verfahrweg.
    @Test func resizeKeepsValueAndScalesPosition() {
        let v = 90.0
        let f = MaterialFaderMath.fraction(v, range: range)
        for travel in [30.0, 45.0, 120.0] {
            let x = travel * f
            // Zurückrechnen aus der Position ergibt denselben Wert (Verfahrweg-unabhängig).
            #expect(MaterialFaderMath.dragged(start: 30, translation: x, travel: travel, range: range, step: 1) == v)
        }
    }
}

@MainActor
struct GUI01PlaybackLoadTests {
    /// Playhead-Last auf der echten MainView: pro Positionswechsel dürfen nur die betroffenen Step-Zellen
    /// neu ausgewertet werden (altes + neues Feld je Spur). Misst außerdem die Dauer je Update (Offscreen,
    /// UI-Regression — keine Timing-Freigabe). Ergebnisse als Datei (Präfix wie GUI01SceneRenderTests).
    @Test func playheadUpdatesOnlyTouchAffectedCells() {
        UserDefaults.standard.set("en", forKey: "appLanguage")
        defer { UserDefaults.standard.removeObject(forKey: "appLanguage") }
        let engine = SequencerEngine()
        engine.addTrack(kind: .cc)
        let notes = NotesStore()
        let root = MainView()
            .environmentObject(notes).environmentObject(engine).environmentObject(engine.transportState)
            .environmentObject(engine.presetEditorState).environmentObject(engine.midiLearnState)
            .environmentObject(engine.playbackDisplay).environmentObject(engine.scrollState)
            .environmentObject(engine.stepWidthState).environmentObject(engine.viewportController)
            .environmentObject(engine.interactionController).environmentObject(engine.clockDiagnostics)
            .environmentObject(engine.midi).preferredColorScheme(.dark)
        let host = NSHostingView(rootView: root)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 760),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = host
        defer { win.contentView = nil }
        func spin(_ s: TimeInterval) { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        spin(0.5)

        let trackCount = engine.currentPattern.tracks.count
        let stepTracks = engine.currentPattern.tracks.filter { $0.lane.kind == .step }.count
        func set(_ step: Int) { engine.playbackDisplay.steps = Array(repeating: step, count: trackCount) }
        set(0); spin(0.1)                       // Ausgangslage einschwingen lassen

        let updates = 64
        let before = StepButtonView.renderCount
        let t0 = CACurrentMediaTime()
        for i in 1...updates { set(i % 16); spin(0.01) }
        let ms = (CACurrentMediaTime() - t0) * 1000 / Double(updates) - 10   // minus Spin-Wartezeit
        let renders = StepButtonView.renderCount - before
        let perUpdate = Double(renders) / Double(updates)

        let prefix = ProcessInfo.processInfo.environment["GUI01_PREFIX"] ?? "after"
        let line = "prefix=\(prefix) updates=\(updates) stepTracks=\(stepTracks) stepButtonBodies=\(renders) perUpdate=\(perUpdate) msPerUpdate(offscreen, minus 10ms spin)=\(String(format: "%.2f", ms))\n"
        try? line.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("GUI01-load-\(prefix).txt"),
                        atomically: true, encoding: .utf8)
        // Erwartung laut StepButtonView-Equatable-Gating: höchstens 2 Zellen je Step-Spur und Update.
        #expect(perUpdate <= Double(2 * stepTracks) + 0.5, "StepButton-Bodies je Update: \(perUpdate)")
    }
}
