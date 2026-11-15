import Testing
import Foundation
import AppKit
import SwiftUI
@testable import VintageSequencer

// v1.12.20 — Beobachtungshygiene: hochfrequente Zustände (Playhead, Scroll, Drag-Session,
// gespielte Noten) dürfen den Lane-Body nicht neu laufen lassen. Gemessen an der echten
// MainView, offscreen, über die kumulierten body-Zähler (BodyRunCounter.total).
// Die Suite läuft seriell auf Main; die Zähler sind prozessweit, deshalb wird nur mit
// Differenzen innerhalb eines Tests gearbeitet und andere Render-Tests können mitzählen —
// die Erwartung „0" gilt für Views DIESER Szene nur, weil parallel keine weitere MainView
// Playhead-/Scroll-Updates bekommt (andere Render-Tests rendern statisch).
@MainActor
@Suite(.serialized) struct ObservationHygieneTests {

    private func host(_ engine: SequencerEngine) -> NSWindow {
        let view = MainView()
            .environmentObject(NotesStore())
            .environmentObject(engine)
            .environmentObject(engine.transportState)
            .environmentObject(engine.presetEditorState)
            .environmentObject(engine.midiLearnState)
            .environmentObject(engine.playbackDisplay)
            .environmentObject(engine.scrollState)
            .environmentObject(engine.stepWidthState)
            .environmentObject(engine.viewportController)
            .environmentObject(engine.interactionController)
            .environmentObject(engine.clockDiagnostics)
            .environmentObject(engine.midi)
        let size = CGSize(width: 1200, height: 700)
        let hostView = NSHostingView(rootView: view)
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = hostView
        hostView.frame = NSRect(origin: .zero, size: size)
        hostView.layoutSubtreeIfNeeded()
        spin(0.5)
        return win
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func delta(_ names: [String], during body: () -> Void) -> [String: Int] {
        let before = Dictionary(uniqueKeysWithValues: names.map { ($0, BodyRunCounter.shared.total($0)) })
        body()
        return Dictionary(uniqueKeysWithValues: names.map { ($0, BodyRunCounter.shared.total($0) - before[$0]!) })
    }

    @Test func playheadUpdatesDoNotRerunLaneBodies() {
        let engine = SequencerEngine()
        let win = host(engine)
        defer { win.contentView = nil }
        let tracks = engine.currentPattern.tracks.count
        let updates = 24
        let d = delta(["StepGrid", "TrackRow", "StepButton"]) {
            for i in 0..<updates {
                engine.playbackDisplay.steps = Array(repeating: i % 16, count: tracks)
                spin(0.02)
            }
        }
        #expect(d["StepGrid"] == 0, "Lane-Body lief \(d["StepGrid"]!)× bei \(updates) Playhead-Updates")
        #expect(d["TrackRow"] == 0)
        // Je Update und Spur höchstens zwei Zellen (alte aus, neue an).
        #expect(d["StepButton"]! <= updates * tracks * 2, "StepButton-Bodies: \(d["StepButton"]!)")
        #expect(d["StepButton"]! > 0, "Playhead muss die betroffenen Zellen erreichen")
    }

    @Test func scrollUpdatesDoNotRerunLaneBodies() {
        let engine = SequencerEngine()
        for t in engine.currentPattern.tracks { t.lane.stepCount = 64 }   // scrollbarer Inhalt
        let win = host(engine)
        defer { win.contentView = nil }
        let d = delta(["StepGrid", "TrackRow", "StepButton"]) {
            for i in 1...20 {
                engine.scrollState.hScrollOffset = CGFloat(i * 12)
                spin(0.02)
            }
        }
        #expect(d["StepGrid"] == 0, "Lane-Body lief \(d["StepGrid"]!)× bei 20 Scroll-Updates")
        #expect(d["TrackRow"] == 0)
        #expect(d["StepButton"] == 0)
    }

    @Test func firedNotesDoNotInvalidateTrackRows() {
        let engine = SequencerEngine()
        let win = host(engine)
        defer { win.contentView = nil }
        let vm = engine.viewModel(for: engine.currentPattern.tracks[0])
        let d = delta(["StepGrid", "TrackRow", "StepButton"]) {
            for i in 0..<20 {
                vm.lastFiredNotes = [60 + i]
                spin(0.01)
                vm.lastFiredNotes = []
                spin(0.01)
            }
        }
        #expect(d["StepGrid"] == 0 && d["TrackRow"] == 0 && d["StepButton"] == 0)
    }

    @Test func sessionCanBeAbortedWhenItsTrackDisappears() {
        let engine = SequencerEngine()
        let ic = engine.interactionController
        let td = engine.currentPattern.tracks[3]
        ic.beginPitchDrag(track: td, stepIndex: 0)
        #expect(ic.activeSession != nil)
        engine.removeTrack(at: 3)                    // die View der Session verschwindet
        #expect(ic.activeSession == nil, "Session darf nach Strukturänderung nicht hängen bleiben")
        ic.beginPitchDrag(track: engine.currentPattern.tracks[0], stepIndex: 0)
        #expect(ic.activeSession != nil, "neue Sessions müssen wieder möglich sein")
        engine.cancelInteractionSession()
    }

    @Test func stepWidthIsClampedToProductRange() {
        let state = StepWidthState()
        let saved = state.size
        defer { state.size = saved }
        state.size = 170
        #expect(state.size == 120)
        state.size = 5
        #expect(state.size == 30)
    }

    /// v1.16.2: Jeder Start beginnt in der Mitte des Schiebers; ein alter gespeicherter Wert
    /// wird ignoriert, Verstellen wird nicht mehr gespeichert.
    @Test func stepWidthStartsAtMidpointAndIsNotPersisted() {
        let key = "stepWidthSize"
        let before = UserDefaults.standard.object(forKey: key)
        defer {
            if let before { UserDefaults.standard.set(before, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(120.0, forKey: key)
        let state = StepWidthState()
        #expect(state.size == 75)
        #expect(MaterialFaderMath.fraction(state.size, range: StepWidthState.range) == 0.5)
        state.size = 100
        #expect(UserDefaults.standard.double(forKey: key) == 120, "Verstellen schreibt nichts mehr")
    }
}
