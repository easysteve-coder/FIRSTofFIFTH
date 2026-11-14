import Testing
import Foundation
import AppKit
import SwiftUI
@testable import VintageSequencer

// GUI-01 — Offscreen-Render der normalen App-Ansicht (MainView) und der Step-Taster-Zustände.
//
// Kein Pixelvergleich: der Test sichert nur, dass die echten App-Views mit der realen Engine
// layouten und nicht-leere Bilder liefern. Die Bilder (Container-tmp, Präfix aus
// TEST_RUNNER_GUI01_PREFIX, Default "after") dienen dem Vorher/Nachher-Vergleich durch Menschen.
// Offscreen-Render ersetzt weder Live-App noch Keyboard-/VoiceOver-Prüfung.
@MainActor
struct GUI01SceneRenderTests {

    private var prefix: String { ProcessInfo.processInfo.environment["GUI01_PREFIX"] ?? "after" }

    private func scene(lang: String) -> SequencerEngine {
        UserDefaults.standard.set(lang, forKey: "appLanguage")
        let engine = SequencerEngine()
        engine.addTrack(kind: .cc)                                  // Step-Spuren + eine CC-Spur
        let tracks = engine.currentPattern.tracks
        for (ti, t) in tracks.enumerated() where t.lane.kind == .step {
            for i in stride(from: ti % 2, to: min(16, t.lane.steps.count), by: 3) { t.lane.steps[i].isActive = true }
        }
        if tracks.count > 1 { tracks[1].colorIndex = 1 }             // zweite Trackfarbe (blau)
        return engine
    }

    private func render<V: View>(_ view: V, size: CGSize, name: String) -> Bool {
        let host = NSHostingView(rootView: view)
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))      // SwiftUI-Layout/onAppear abwarten
        host.layoutSubtreeIfNeeded()
        defer { win.contentView = nil }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        try? png.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("GUI01-\(prefix)-\(name).png"))
        return png.count > 2_000
    }

    private func mainView(_ engine: SequencerEngine, notes: NotesStore) -> some View {
        MainView()
            .environmentObject(notes)
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
            .preferredColorScheme(.dark)
    }

    @Test func renderMainViewScenes() {
        let notes = NotesStore()
        // GUI-01-R1: 920/1600 pt × DE/EN × WIDTH 30/120 (Vergleichsmatrix für Plattenhöhe und Produktnamen)
        var configs: [(String, String, CGSize, Double)] = []
        for (wname, size) in [("min", CGSize(width: 920, height: 560)), ("wide", CGSize(width: 1600, height: 760))] {
            for lang in ["en", "de"] {
                for width in [30.0, 120.0] {
                    configs.append(("main-\(lang)-\(wname)-w\(Int(width))", lang, size, width))
                }
            }
        }
        for (name, lang, size, width) in configs {
            let engine = scene(lang: lang)
            engine.stepWidthState.size = width
            engine.midiLearnState.learnMode = true                   // Learn-Ziel sichtbar machen
            engine.setLearnTarget(track: 0, step: 3)
            #expect(render(mainView(engine, notes: notes), size: size, name: name), "Render \(name)")
        }
        UserDefaults.standard.removeObject(forKey: "appLanguage")
    }

    /// Pad-Spur (v1.13.19): eigene Optik, eigene Breite, Längenetikett — Bild für den Menschen.
    @Test func renderPadTrackScene() {
        let notes = NotesStore()
        let engine = scene(lang: "de")
        let pad = engine.addTrack(kind: .step, pad: true).first!.track
        pad.colorIndex = 3
        UserDefaults.standard.set("epic", forKey: SequencerEngine.padChordFamilyKey)
        engine.randomize(track: pad)
        UserDefaults.standard.removeObject(forKey: SequencerEngine.padChordFamilyKey)
        pad.lane.padWidth = 3
        pad.lane.steps[3].isHold = true
        engine.stepWidthState.size = 54
        #expect(render(mainView(engine, notes: notes), size: CGSize(width: 1600, height: 1400), name: "pad-de"))
        UserDefaults.standard.removeObject(forKey: "appLanguage")
    }

    @Test func renderSongScene() {
        let notes = NotesStore()
        let engine = scene(lang: "de")
        engine.replaceSong(Song(scenes: [SongScene(pattern: 0, bars: 4), SongScene(pattern: 1, bars: 8),
                                         SongScene(pattern: 0, bars: 4), SongScene(pattern: 2, bars: 2),
                                         SongScene(pattern: 9, bars: 16)],
                                enabled: true, loops: true))
        engine.songState.playingScene = 1
        engine.currentPatternIndex = 1
        engine.transportState.queuedPatternIndex = 0
        #expect(render(mainView(engine, notes: notes), size: CGSize(width: 1600, height: 900), name: "song-de"))
        UserDefaults.standard.removeObject(forKey: "appLanguage")
    }

    @Test func renderStepButtonStates() {
        let engine = scene(lang: "en")
        let track = engine.viewModel(for: engine.currentPattern.tracks[0])
        engine.midiLearnState.learnMode = true
        engine.setLearnTarget(track: 0, step: 4)
        let cells: [(Int, Bool, Bool)] = [(1, false, false), (0, false, false), (3, true, false), (6, false, true), (4, false, false), (9, false, false)]
        let row = HStack(spacing: VintageTheme.stepSpacing) {
            ForEach(0..<cells.count, id: \.self) { i in
                StepButtonView(track: track, index: cells[i].0, trackIndex: 0,
                               isCurrentStep: cells[i].1, isSelected: cells[i].2,
                               accentColor: VintageTheme.color(forTrack: 0))
            }
        }
        .padding(16).background(VintageTheme.panel)
        .environmentObject(engine).environmentObject(engine.midiLearnState)
        #expect(render(row, size: CGSize(width: 420, height: 90), name: "steps"), "Render steps")
        UserDefaults.standard.removeObject(forKey: "appLanguage")
    }
}
