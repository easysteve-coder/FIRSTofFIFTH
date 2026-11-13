import Testing
import Foundation
import AppKit
import SwiftUI
@testable import VintageSequencer

// GUI-02 — Bild-Evidenz für das Step-Material (nur Evidenzlauf mit TEST_RUNNER_GUI02_PREFIX; kein Pixelvergleich,
// keine Gradient-Konstanten). Rendert dieselbe Szene vorher/nachher bei 100 % (2× Retina, keine Nachbearbeitung):
// Step-Blätter je WIDTH (30/54/120) und zwei Gesamtfenster (920/1600 pt). Zusätzlich misst der Lauf die mittlere
// Helligkeit der linken/mittleren/rechten Körperfläche eines aktiven Steps (Textspur ausgeschlossen).
@MainActor
struct GUI02StepMaterialEvidenceTests {

    private var prefix: String { ProcessInfo.processInfo.environment["GUI02_PREFIX"] ?? "after" }

    private func scene() -> SequencerEngine {
        UserDefaults.standard.set("en", forKey: "appLanguage")
        let engine = SequencerEngine()
        engine.addTrack(kind: .cc)
        let tracks = engine.currentPattern.tracks
        tracks[0].colorIndex = 0     // Amber
        tracks[1].colorIndex = 1     // Blau
        tracks[2].colorIndex = 3     // Magenta
        for ti in 0..<3 {
            let lane = tracks[ti].lane
            for i in 0..<lane.stepCount { lane.steps[i].isActive = false }
            for i in [1, 2, 3, 4, 5] { lane.steps[i].isActive = true }
            lane.steps[2].velocity = 50
            lane.steps[2].ratchet = .x2
            lane.steps[2].probability = 0.5
        }
        return engine
    }

    private func environment<V: View>(_ v: V, _ engine: SequencerEngine) -> some View {
        v.environmentObject(engine)
            .environmentObject(engine.transportState)
            .environmentObject(engine.midiLearnState)
            .environmentObject(engine.playbackDisplay)
            .environmentObject(engine.scrollState)
            .environmentObject(engine.stepWidthState)
            .environmentObject(engine.viewportController)
            .environmentObject(engine.interactionController)
            .environmentObject(engine.clockDiagnostics)
            .environmentObject(engine.midi)
            .environment(\.colorScheme, .dark)
    }

    private func png(_ host: NSView) -> Data? {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private func settle(_ host: NSView) async {
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(80))
        host.layoutSubtreeIfNeeded()
    }

    /// Spalten: aus, aktiv, aktiv mit Velocity/Ratchet/Probability, ausgewählt, Learn-Ziel, Playhead.
    private func sheet(engine: SequencerEngine, width: Double) -> some View {
        let tracks = engine.currentPattern.tracks
        let cols = ["off", "on", "vel/ratchet/prob", "selected", "learn", "playhead"]
        let cell = CGFloat(width)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: VintageTheme.stepSpacing) {
                Text("").frame(width: 50)
                ForEach(cols, id: \.self) { c in
                    Text(c).font(VintageTheme.monoSmall).foregroundColor(VintageTheme.textSecondary)
                        .frame(width: cell, alignment: .leading).lineLimit(1).minimumScaleFactor(0.5)
                }
            }
            ForEach(0..<3, id: \.self) { ti in
                let track = engine.viewModel(for: tracks[ti])
                let accent = VintageTheme.color(forTrack: tracks[ti].colorIndex)
                HStack(spacing: VintageTheme.stepSpacing) {
                    Text(["amber", "blue", "magenta"][ti]).font(VintageTheme.monoSmall)
                        .foregroundColor(VintageTheme.textSecondary).frame(width: 50, alignment: .leading)
                    // Spaltenzuordnung: Step-Indizes 0 (aus), 1 (an), 2 (vel/ratchet/prob), 3 (an, ausgewählt),
                    // 4 (an, Learn-Ziel nur in der Amber-Zeile), 5 (an, Playhead).
                    ForEach(0..<6, id: \.self) { c in
                        StepButtonView(track: track, index: c, trackIndex: ti,
                                       isCurrentStep: c == 5,
                                       isSelected: c == 3,
                                       accentColor: accent,
                                       size: VintageTheme.stepSize, width: cell)
                    }
                }
            }
        }
        .padding(14)
        .background(GridWellSurface())
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GUI02_PREFIX"] != nil,
                   "Evidenzlauf: TEST_RUNNER_GUI02_PREFIX setzen"))
    func captureStepMaterialScenes() async throws {
        var luminance: [String: Any] = [:]
        for width in [30.0, 54.0, 120.0] {
            let engine = scene()
            engine.stepWidthState.size = width
            engine.midiLearnState.learnMode = true
            engine.setLearnTarget(track: 0, step: 4)
            let size = CGSize(width: 50 + 6 * (CGFloat(width) + 4) + 28 + 8, height: 3 * 54 + 2 * 8 + 28 + 40)
            let host = NSHostingView(rootView: environment(sheet(engine: engine, width: width), engine))
            let win = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                               styleMask: [.borderless], backing: .buffered, defer: false)
            win.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            await settle(host)
            let data = try #require(png(host))
            try data.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("GUI02-\(prefix)-sheet-w\(Int(width)).png"))
            // Helligkeitsprofil über die Breite eines aktiven Amber-Steps (Spalte „on“): obere Kante, untere Kante und Körper
            // links/rechts neben LED und Text (y = Oberkante + 8 pt). Mittlere Helligkeit kleiner Pixelfenster.
            if let rep = NSBitmapImageRep(data: data) {
                let scale = CGFloat(rep.pixelsWide) / size.width
                let x0 = (14 + 50 + VintageTheme.stepSpacing + 1 * (CGFloat(width) + 4)) * scale   // linke Kante Step „on“
                let y0 = 36 * scale                                                                // Oberkante Amber-Zeile
                func luma(_ xFrac: CGFloat, _ yPx: CGFloat) -> Double {
                    var sum = 0.0, n = 0.0
                    let cx = Int(x0 + xFrac * CGFloat(width) * scale)
                    for dx in -2...2 { for dy in -1...1 {
                        if let c = rep.colorAt(x: cx + dx, y: Int(yPx) + dy)?.usingColorSpace(.sRGB) {
                            sum += 0.2126 * Double(c.redComponent) + 0.7152 * Double(c.greenComponent) + 0.0722 * Double(c.blueComponent); n += 1 } } }
                    return n > 0 ? sum / n : -1
                }
                let top = y0 + 1.5 * scale, bottom = y0 + (54 - 2.5) * scale, body = y0 + 8 * scale
                luminance["w\(Int(width))"] = [
                    "topEdge":    ["left": luma(0.15, top),    "mid": luma(0.5, top),    "right": luma(0.85, top)],
                    "bottomEdge": ["left": luma(0.15, bottom), "mid": luma(0.5, bottom), "right": luma(0.85, bottom)],
                    "body":       ["left": luma(0.15, body),   "right": luma(0.85, body)],
                ]
            }
            win.contentView = nil
        }
        let json = try JSONSerialization.data(withJSONObject: luminance, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("GUI02-\(prefix)-luma.json"))

        // Gesamtfenster (normale App-Ansicht), 920 und 1600 pt
        for (name, size, width) in [("920", CGSize(width: 920, height: 760), 54.0), ("1600", CGSize(width: 1600, height: 760), 54.0)] {
            let engine = scene()
            engine.stepWidthState.size = width
            let host = NSHostingView(rootView: MainView()
                .environmentObject(NotesStore())
                .environmentObject(engine).environmentObject(engine.transportState)
                .environmentObject(engine.presetEditorState).environmentObject(engine.midiLearnState)
                .environmentObject(engine.playbackDisplay).environmentObject(engine.scrollState)
                .environmentObject(engine.stepWidthState).environmentObject(engine.viewportController)
                .environmentObject(engine.interactionController).environmentObject(engine.clockDiagnostics)
                .environmentObject(engine.midi).preferredColorScheme(.dark))
            let win = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                               styleMask: [.borderless], backing: .buffered, defer: false)
            win.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            win.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            win.orderFrontRegardless()
            await settle(host)
            let data = try #require(png(host))
            try data.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("GUI02-\(prefix)-window-\(name).png"))
            win.orderOut(nil); win.contentView = nil
        }
        UserDefaults.standard.removeObject(forKey: "appLanguage")
    }
}
