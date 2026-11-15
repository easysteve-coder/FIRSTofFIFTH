import Testing
import Foundation
import AppKit
import SwiftUI
import Combine
@testable import VintageSequencer

// G01 — Lane-Viewport und konsistente horizontale Scrollgrenzen.
//
// Szenen rendern die echten App-Views offscreen (NSHostingView in borderlosem NSWindow) und erfassen die
// tatsächlich gemessene Geometrie (DEBUG-Probe in den Lanes, NSScrollView-Clip/Dokument der Scrollbar,
// ViewportController-Maximum). Offscreen-Render ersetzt weder Live-App noch Maus-/Trackpad-Prüfung.
// Bilder + JSON: Container-tmp, Präfix aus TEST_RUNNER_G01_PREFIX (Default "after").
@MainActor
struct G01LaneViewportTests {

    private var prefix: String { ProcessInfo.processInfo.environment["G01_PREFIX"] ?? "after" }

    // MARK: Szene

    /// 4 Step-Spuren (lang / 9:8 / kurz / Standard) + 1 CC-Spur (lang), zwei Trackfarben.
    private func scene() -> SequencerEngine {
        UserDefaults.standard.set("en", forKey: "appLanguage")
        let engine = SequencerEngine()
        engine.addTrack(kind: .cc)
        let tracks = engine.currentPattern.tracks
        for (ti, t) in tracks.enumerated() where t.lane.kind == .step {
            for i in stride(from: ti % 2, to: min(16, t.lane.steps.count), by: 3) { t.lane.steps[i].isActive = true }
        }
        tracks[0].lane.stepCount = 32                                       // lang
        if tracks.count > 1 { tracks[1].colorIndex = 1                       // blau, 9:8
            tracks[1].lane.stepLengthNumerator = 9; tracks[1].lane.stepLengthDenominator = 8 }
        if tracks.count > 2 { tracks[2].lane.stepCount = 6 }                // kurz neben der längsten
        if let cc = tracks.last(where: { $0.lane.kind == .cc }) { cc.lane.stepCount = 24 }
        return engine
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

    /// Layout abwarten und der Main-Queue Zeit geben (`DispatchQueue.main.async` läuft im @MainActor-Test erst,
    /// wenn der Test-Body per `await` abgibt; ein verschachtelter RunLoop genügt dafür nicht).
    /// Wartet per `await` (der Main-Thread bleibt für andere Tests/Dispatch frei, kein blockierender RunLoop).
    private func pump(_ host: NSView, _ t: TimeInterval = 0.4) async {
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: UInt64(Int(t * 1000) * 1_000_000))
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: UInt64(80) * 1_000_000)
        host.layoutSubtreeIfNeeded()
    }

    private func findScroller(_ v: NSView) -> NSScrollView? {
        if let sv = v as? NSScrollView, sv.hasHorizontalScroller, !sv.hasVerticalScroller { return sv }
        for s in v.subviews { if let f = findScroller(s) { return f } }
        return nil
    }

    private func savePNG(_ host: NSView, name: String) -> Bool {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        try? png.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("G01-\(prefix)-\(name).png"))
        return png.count > 2_000
    }

    // MARK: Messung (Vorher/Nachher)

    /// Erfasst pro Szene die gemessenen Größen und speichert Bilder (links/Mitte/rechts).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["G01_PREFIX"] != nil,
                   "Evidenzlauf: TEST_RUNNER_G01_PREFIX setzen (Bilder + volle Matrix)"))
    func captureGeometryAndImages() async throws {
        let notes = NotesStore()
        var records: [[String: Any]] = []
        // Läuft nur als Evidenzlauf (TEST_RUNNER_G01_PREFIX gesetzt): 18 Bilder + volle Matrix. Im Standardlauf belegt
        // das Hosten des ganzen MainView den Main-Actor so lange, dass zeitfensterbasierte Tests anderer Suites (S01) kippen;
        // die Kernzusicherungen laufen dort leichtgewichtig in `G01LaneRenderTests`.
        let full = true
        let sizes = [("920", CGSize(width: 920, height: 760)), ("1600", CGSize(width: 1600, height: 760))]
        for (wname, size) in (full ? sizes : [sizes[0]]) {
            for width in (full ? [30.0, 54.0, 120.0] : [54.0]) {
                let engine = scene()
                engine.stepWidthState.size = width
                let host = NSHostingView(rootView: mainView(engine, notes: notes))
                let win = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
                win.contentView = host
                host.frame = NSRect(origin: .zero, size: size)
                // Preferences aus GeometryReadern werden erst im nächsten Update-Zyklus ausgeliefert; den treibt
                // ein geordnetes Fenster. Weit außerhalb aller Bildschirme: kein sichtbares Aufblitzen.
                win.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
                win.orderFrontRegardless()
                await pump(host, 0.6)

                let vc = engine.viewportController
                let tracks = engine.currentPattern.tracks
                let maxOff = vc.maxScrollOffset
                for (pos, frac) in (full ? [("left", 0.0), ("mid", 0.5), ("right", 1.0)] : [("right", 1.0)]) {
                    let target: CGFloat = maxOff.isFinite && maxOff < 1e9 ? CGFloat(frac) * maxOff : 0
                    vc.scroll(by: target - engine.scrollState.hScrollOffset)
                    await pump(host, 0.25)

                    var rec: [String: Any] = [
                        "window": wname, "width": width, "scroll": pos,
                        "offset": Double(engine.scrollState.hScrollOffset),
                        "vcMax": maxOff.isFinite && maxOff < 1e9 ? Double(maxOff) : -1,
                        "newContentExtent": Double(LaneGeometry.contentExtent(tracks: tracks, stepWidthSize: width)),
                    ]
                    let lm = vc.laneMetrics
                    rec["reports"] = Double(vc._g01ReportCount)
                    rec["laneMetrics.minX"] = Double(lm.viewportMinX ?? -1)
                    rec["laneMetrics.viewport"] = Double(lm.viewportWidth)
                    rec["laneMetrics.extent"] = Double(lm.contentExtent(at: width))
                    #if DEBUG
                    for (i, t) in tracks.enumerated() {
                        let kind = t.lane.kind == .cc ? "cc" : "step"
                        for name in ["content", "clipContainer", "viewport"] {
                            if let v = LaneGeometryProbe.shared.samples["\(t.id)/\(name)"] { rec["probe.\(kind)\(i).\(name)"] = Double(v) }
                        }
                    }
                    #endif
                    if let sv = findScroller(host) {
                        rec["scrollerFrameWidth"] = Double(sv.frame.width)
                        rec["scrollerClipWidth"] = Double(sv.contentView.bounds.width)
                        rec["scrollerDocWidth"] = Double(sv.documentView?.frame.width ?? -1)
                        rec["scrollerNativeMax"] = Double((sv.documentView?.frame.width ?? 0) - sv.contentView.bounds.width)
                        rec["scrollerClipX"] = Double(sv.contentView.bounds.origin.x)
                    }
                    #if DEBUG
                    // Formel gegen die real gerenderte Inhaltsbreite jeder Lane (HStack inkl. Padding/Handles).
                    for t in tracks.enumerated() {
                        let kind = t.element.lane.kind == .cc ? "cc" : "step"
                        let rendered = LaneGeometryProbe.shared.samples["\(t.element.id)/content"]
                        let expected = LaneGeometry.contentExtent(stepCount: t.element.lane.stepCount,
                                                                  num: t.element.lane.stepLengthNumerator,
                                                                  den: t.element.lane.stepLengthDenominator,
                                                                  stepWidthSize: width)
                        #expect(rendered == expected, "\(kind)\(t.offset) w\(Int(width)) \(wname): gerendert \(String(describing: rendered)) ≠ Formel \(expected)")
                        #expect(LaneGeometryProbe.shared.samples["\(t.element.id)/clipContainer"] == LaneGeometryProbe.shared.samples["\(t.element.id)/viewport"],
                                "\(kind)\(t.offset): Clip-Container ≠ Viewport")
                    }
                    // Gemeinsame Grenze: Controller == natives Scrollbar-Maximum == Inhalt − Viewport; Clip == Lane-Viewport.
                    let lmX = vc.laneMetrics
                    #expect(vc.maxScrollOffset == LaneGeometry.maxOffset(contentExtent: lmX.contentExtent(at: width), viewportWidth: lmX.viewportWidth))
                    if let sv = findScroller(host) {
                        #expect(sv.contentView.bounds.width == lmX.viewportWidth, "Scrollbar-Clip ≠ Lane-Viewport")
                        #expect(max(0, (sv.documentView?.frame.width ?? 0) - sv.contentView.bounds.width) == vc.maxScrollOffset,
                                "natives Maximum ≠ Controller-Maximum")
                        #expect(sv.convert(sv.bounds.origin, to: nil).x == lmX.viewportMinX, "Scrollbar-Beginn ≠ Lane-Viewport-Beginn")
                    // Thumb folgt dem Controller-Offset (Trackpad/Edge-Scroll/Zoom schreiben nur den Offset).
                    #expect(abs(sv.contentView.bounds.origin.x - engine.scrollState.hScrollOffset) < 0.5, "Thumb ≠ Offset")
                    }
                    #endif
                    records.append(rec)
                    #expect(savePNG(host, name: "w\(width == 54 ? "54" : String(Int(width)))-\(wname)-\(pos)"))
                }
                win.orderOut(nil)
                win.contentView = nil
            }
        }
        let data = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("G01-\(prefix)-geometry.json"))
        UserDefaults.standard.removeObject(forKey: "appLanguage")
    }
}

// MARK: - Reine Geometrie (G01)

@MainActor
struct G01LaneGeometryTests {

    private let widths: [Double] = [30, 54, 120]
    private let counts: [Int] = [1, 16, 64]

    /// Referenz: explizite Summe der gerenderten (gerundeten) Zellbreiten + HStack-Abstände + Padding + Handle.
    private func explicitExtent(n: Int, num: Int, den: Int, width: Double) -> CGFloat {
        var cells: CGFloat = 0
        for i in 0..<n {
            cells += VintageTheme.distributedStepWidth(index: i, num: num, den: den, stepWidthSize: width)
        }
        // HStack(spacing: stepSpacing) mit n Zellen + 1 Handle-Spalte → n Abstände; .padding(.horizontal, leadingPad) beidseitig.
        return cells + CGFloat(n) * 4 + 2 * 8 + 12
    }

    @Test func contentExtentMatchesExplicitCellSumForAllRatiosWidthsAndCounts() {
        for r in TrackData.sortedRatios {
            for w in widths {
                for n in counts {
                    let got = LaneGeometry.contentExtent(stepCount: n, num: r.num, den: r.den, stepWidthSize: w)
                    #expect(got == explicitExtent(n: n, num: r.num, den: r.den, width: w),
                            "ratio \(r.num):\(r.den) width \(w) count \(n)")
                    // Gegenprüfung: Summe telescopiert zu round(n × slot) + 2 × pad + Handle.
                    let slot = (CGFloat(w) + 4) * CGFloat(r.num) / CGFloat(r.den)
                    let closed = (slot * CGFloat(n)).rounded(.toNearestOrEven) + 28
                    #expect(got == closed, "closed form \(r.num):\(r.den) width \(w) count \(n)")
                }
            }
        }
    }

    @Test func contentExtentEdgeCases() {
        #expect(LaneGeometry.contentExtent(tracks: [], stepWidthSize: 54) == 0)
        // Count 0: nur Padding + Handle, nie negativ.
        #expect(LaneGeometry.contentExtent(stepCount: 0, num: 1, den: 1, stepWidthSize: 54) == 28)
        #expect(LaneGeometry.contentExtent(stepCount: -3, num: 1, den: 1, stepWidthSize: 54) == 28)
    }

    @Test func longestLaneDeterminesPatternExtent() {
        let long = TrackData(name: "long"); long.lane.stepCount = 32
        let short = TrackData(name: "short"); short.lane.stepCount = 6
        let ratio = TrackData(name: "ratio"); ratio.lane.stepLengthNumerator = 9; ratio.lane.stepLengthDenominator = 8
        let e = LaneGeometry.contentExtent(tracks: [short, ratio, long], stepWidthSize: 54)
        #expect(e == LaneGeometry.contentExtent(stepCount: 32, num: 1, den: 1, stepWidthSize: 54))
        #expect(e > LaneGeometry.contentExtent(stepCount: 16, num: 9, den: 8, stepWidthSize: 54))
    }

    @Test func maxOffsetIsContentMinusViewportAndNeverInvalid() {
        #expect(LaneGeometry.maxOffset(contentExtent: 1000, viewportWidth: 400) == 600)
        #expect(LaneGeometry.maxOffset(contentExtent: 400, viewportWidth: 400) == 0)      // gleich
        #expect(LaneGeometry.maxOffset(contentExtent: 300, viewportWidth: 400) == 0)      // Inhalt kleiner
        #expect(LaneGeometry.maxOffset(contentExtent: 1000, viewportWidth: 0) == 1000)    // ungemessen → ganzer Inhalt
        for bad: CGFloat in [.nan, .infinity, -.infinity, -5] {
            let a = LaneGeometry.maxOffset(contentExtent: bad, viewportWidth: 400)
            let b = LaneGeometry.maxOffset(contentExtent: 1000, viewportWidth: bad)
            #expect(a.isFinite && a >= 0)
            #expect(b.isFinite && b >= 0)
        }
    }

    @Test func clampHandlesNegativeTooLargeAndNaN() {
        #expect(LaneGeometry.clamp(-10, max: 500) == 0)
        #expect(LaneGeometry.clamp(250, max: 500) == 250)
        #expect(LaneGeometry.clamp(900, max: 500) == 500)
        #expect(LaneGeometry.clamp(.nan, max: 500) == 0)
        #expect(LaneGeometry.clamp(100, max: .nan) == 0)
        #expect(LaneGeometry.clamp(.infinity, max: 500) == 0)
    }

    @Test func documentWidthGivesNativeMaximumEqualToMaxOffset() {
        for (content, viewport): (CGFloat, CGFloat) in [(1884, 551), (1116, 1231), (551, 551), (3996, 1231)] {
            let doc = LaneGeometry.documentWidth(contentExtent: content, viewportWidth: viewport)
            #expect(max(0, doc - viewport) == LaneGeometry.maxOffset(contentExtent: content, viewportWidth: viewport))
        }
        #expect(LaneGeometry.documentWidth(contentExtent: .nan, viewportWidth: .nan) >= 1)
    }
}

// MARK: - ViewportController: eine Grenze für alle Schreibpfade (G01)

/// Referenz für gerenderte Inhaltsbreite: Summe der real gerenderten Zellbreiten + HStack-Abstände + Padding + Handle.
private func renderedExtent(steps n: Int, num: Int = 1, den: Int = 1, width: Double) -> CGFloat {
    var cells: CGFloat = 0
    for i in 0..<n { cells += VintageTheme.distributedStepWidth(index: i, num: num, den: den, stepWidthSize: width) }
    return cells + CGFloat(n) * 4 + 2 * 8 + 12
}

@MainActor
struct G01ViewportControllerTests {

    /// Controller mit Viewport und einer Lane-Topologie bei der gegebenen WIDTH.
    private func controller(shapes: [LaneShape], viewport: CGFloat, width: Double = 54, offset: CGFloat = 0) -> ViewportController {
        let vc = ViewportController(scrollState: ScrollState())
        vc.setStepWidth(width)
        vc.applyLaneMetrics(LaneMetrics(viewportMinX: 237, viewportWidth: viewport, shapes: shapes))
        vc.scrollState.hScrollOffset = offset
        return vc
    }

    @Test func allWritePathsShareTheSameBound() {
        // 34 Steps @54 → Inhalt 2000, Viewport 500 → Maximum 1500
        let paths: [(String, (ViewportController) -> Void)] = [
            ("scroll(by:)",       { $0.scroll(by: 10_000) }),
            ("scrollTrackpad",    { $0.scrollTrackpad(delta: -10_000) }),
            ("syncFromScrollbar", { $0.syncFromScrollbar(10_000) }),
        ]
        for (name, push) in paths {
            let vc = controller(shapes: [LaneShape(stepCount: 34)], viewport: 500, offset: 1400)
            push(vc)
            #expect(vc.effectiveMaxOffset == 1500, "\(name)")
            #expect(vc.maxScrollOffset == 1500, "\(name)")
            #expect(vc.scrollState.hScrollOffset == 1500, "\(name)")
        }
        // Zoom: Anker am rechten Ende, Verbreiterung → exakt die Grenze der NEUEN Breite.
        let vc = controller(shapes: [LaneShape(stepCount: 34)], viewport: 500, offset: 1500)
        vc.adjustScroll(oldStepWidth: 54, newStepWidth: 108, anchorX: 500)
        let newMax = renderedExtent(steps: 34, width: 108) - 500
        let ratio = CGFloat(112) / 58
        let unclamped = ((500 - 8) + 1500) * ratio + 8 - 500
        #expect(vc.scrollState.hScrollOffset == min(unclamped, newMax))
        #expect(vc.effectiveMaxOffset == newMax)
    }

    @Test func zoomAnchorFormulaIsUnchangedInsideTheBound() {
        let vc = controller(shapes: [LaneShape(stepCount: 400)], viewport: 500, offset: 300)
        vc.adjustScroll(oldStepWidth: 54, newStepWidth: 108, anchorX: 100)
        let ratio = (108.0 + 4) / (54.0 + 4)
        let expected = ((100 - 8) + 300) * ratio + 8 - 100
        #expect(abs(vc.scrollState.hScrollOffset - expected) < 0.001)
    }

    @Test func shrinkingBoundReclampsInvalidOffset() {
        let vc = controller(shapes: [LaneShape(stepCount: 51)], viewport: 500, offset: 2400)   // Inhalt 2986, Maximum 2486
        #expect(vc.scrollState.hScrollOffset == 2400)
        // Stepzahl kleiner (Handle-Drag/Count)
        vc.applyLaneMetrics(LaneMetrics(viewportMinX: 237, viewportWidth: 500, shapes: [LaneShape(stepCount: 30)]))
        #expect(vc.effectiveMaxOffset == 1268)
        #expect(vc.scrollState.hScrollOffset == 1268)
        // Resize: Viewport breiter
        vc.applyLaneMetrics(LaneMetrics(viewportMinX: 237, viewportWidth: 900, shapes: [LaneShape(stepCount: 30)]))
        #expect(vc.effectiveMaxOffset == 868)
        #expect(vc.scrollState.hScrollOffset == 868)
        // WIDTH kleiner (Fader): Grenze folgt, Offset klemmt
        vc.setStepWidth(30)
        #expect(vc.effectiveMaxOffset == renderedExtent(steps: 30, width: 30) - 900)
        #expect(vc.scrollState.hScrollOffset == vc.effectiveMaxOffset)
        // Inhalt kleiner als Viewport → 0
        vc.applyLaneMetrics(LaneMetrics(viewportMinX: 237, viewportWidth: 2000, shapes: [LaneShape(stepCount: 30)]))
        #expect(vc.effectiveMaxOffset == 0)
        #expect(vc.scrollState.hScrollOffset == 0)
    }

    @Test func unmeasuredViewportLeavesStateUnchanged() {
        let vc = controller(shapes: [LaneShape(stepCount: 34)], viewport: 500, offset: 700)
        vc.applyLaneMetrics(LaneMetrics(viewportMinX: nil, viewportWidth: 0, shapes: [LaneShape(stepCount: 1)]))
        #expect(vc.effectiveMaxOffset == 1500)
        #expect(vc.scrollState.hScrollOffset == 700)
        vc.applyLaneMetrics(LaneMetrics(viewportMinX: 237, viewportWidth: .nan, shapes: [LaneShape(stepCount: 1)]))
        #expect(vc.effectiveMaxOffset == 1500)
        vc.setStepWidth(.nan); vc.setStepWidth(-5); vc.setStepWidth(0)
        #expect(vc.stepWidth == 54)
    }

    @Test func applyingMetricsPublishesOnlyOnGeometryChange() {
        let vc = controller(shapes: [LaneShape(stepCount: 34)], viewport: 500)
        var changes = 0
        let sub = vc.objectWillChange.sink { changes += 1 }
        defer { sub.cancel() }
        // Gleiche Geometrie; Scrollen und WIDTH-Wechsel ändern nur Offset/Breite, nicht die gemeldete Geometrie.
        // (`adjustScroll` publiziert wie zuvor `zoomScale` und ist hier bewusst nicht enthalten.)
        vc.applyLaneMetrics(LaneMetrics(viewportMinX: 237, viewportWidth: 500, shapes: [LaneShape(stepCount: 34)]))
        vc.scroll(by: 100); vc.scroll(by: 100); vc.scrollTrackpad(delta: -50)
        vc.setStepWidth(66)
        #expect(changes == 0)
        vc.applyLaneMetrics(LaneMetrics(viewportMinX: 237, viewportWidth: 500, shapes: [LaneShape(stepCount: 35)]))
        #expect(changes == 1)
    }

    @Test func coalescedReportsApplyOnlyTheNewestValues() async {
        let vc = ViewportController(scrollState: ScrollState())
        vc.setStepWidth(54)
        vc.reportLaneViewport(LaneViewport(minX: 237, width: 500))
        vc.reportLaneShapes([LaneShape(stepCount: 10)])
        vc.reportLaneShapes([LaneShape(stepCount: 34)])          // überholt die erste Meldung
        #expect(vc.maxScrollOffset == .greatestFiniteMagnitude)   // noch nichts angewendet (nie synchron)
        try? await Task.sleep(nanoseconds: UInt64(50) * 1_000_000)
        #expect(vc.maxScrollOffset == 1500)
        #expect(vc.laneMetrics.shapes == [LaneShape(stepCount: 34)])
    }
}

// MARK: - H1 (Review G01): Zoom-Grenze bei mehreren Updates ohne zwischenzeitliche Messung

@MainActor
struct G01R1ZoomBoundTests {

    private let viewport: CGFloat = 551

    /// Der Gestenhandler committet nach `adjustScroll` die gerundete Breite in `StepWidthState`; `MainView` meldet sie
    /// per `setStepWidth` (idempotent). Hier nachgestellt, ohne dass zwischen den Updates eine Messung eintrifft.
    private func pinch(_ vc: ViewportController, from old: CGFloat, to new: CGFloat, anchor: CGFloat = 551) {
        vc.adjustScroll(oldStepWidth: old, newStepWidth: new, anchorX: anchor)
        vc.setStepWidth(Double(new.rounded()))
    }

    private func rightEndController(steps: Int = 32, num: Int = 1, den: Int = 1, width: Double = 54) -> ViewportController {
        let vc = ViewportController(scrollState: ScrollState())
        vc.setStepWidth(width)
        vc.applyLaneMetrics(LaneMetrics(viewportMinX: 237, viewportWidth: viewport,
                                        shapes: [LaneShape(stepCount: steps, num: num, den: den)]))
        vc.scrollState.hScrollOffset = vc.effectiveMaxOffset
        return vc
    }

    private func maxFor(steps: Int, num: Int = 1, den: Int = 1, width: Double) -> CGFloat {
        max(0, renderedExtent(steps: steps, num: num, den: den, width: width) - viewport)
    }

    /// Rechnung aus dem Review: 32 Steps 1:1, WIDTH 54, Inhalt 1884, Viewport 551, Offset am rechten Ende 1333, Anker 551.
    @Test func twoZoomUpdatesWithoutNewMeasurementStayConsistent() {
        let vc = rightEndController()
        #expect(vc.scrollState.hScrollOffset == 1333)
        pinch(vc, from: 54, to: 60)
        #expect(abs(vc.scrollState.hScrollOffset - 1525) < 0.5, "erster Schritt")
        pinch(vc, from: 60, to: 66)
        let correctMax = CGFloat(32 * (66 + 4) + 28) - 551          // 1717
        #expect(abs(vc.scrollState.hScrollOffset - correctMax) < 0.5, "zweiter Schritt: \(vc.scrollState.hScrollOffset)")
        // Danach darf kein Schreiber den Zoomoffset an die alte Grenze zurückklemmen.
        vc.scroll(by: 0)
        #expect(abs(vc.scrollState.hScrollOffset - correctMax) < 0.5, "scroll(by: 0)")
        #expect(vc.effectiveMaxOffset == correctMax)
        #expect(vc.maxScrollOffset == correctMax, "gespiegeltes Maximum bleibt nicht beim alten Wert")
    }

    /// Dasselbe ohne vorheriges `setStepWidth` (Controller kennt die Basisbreite nur aus der Metrik-Anwendung).
    @Test func zoomWorksEvenIfWidthWasNeverReported() {
        let vc = ViewportController(scrollState: ScrollState())
        vc.applyLaneMetrics(LaneMetrics(viewportMinX: 237, viewportWidth: viewport, shapes: [LaneShape(stepCount: 32)]))
        vc.scrollState.hScrollOffset = 1333
        vc.adjustScroll(oldStepWidth: 54, newStepWidth: 60, anchorX: 551)
        vc.adjustScroll(oldStepWidth: 60, newStepWidth: 66, anchorX: 551)
        #expect(abs(vc.scrollState.hScrollOffset - 1717) < 0.5)
    }

    @Test func manyUpdatesInAndOutAtTheRightEndWithDirectionChanges() {
        let vc = rightEndController()
        // hinein, 4 Updates vor jeder Messung
        for (o, n) in [(54, 58), (58, 63), (63, 69), (69, 76)] as [(CGFloat, CGFloat)] {
            pinch(vc, from: o, to: n)
            #expect(abs(vc.scrollState.hScrollOffset - maxFor(steps: 32, width: Double(n))) < 0.5, "hinein \(n)")
        }
        // Richtung wechseln: heraus
        for (o, n) in [(76, 70), (70, 62), (62, 54)] as [(CGFloat, CGFloat)] {
            pinch(vc, from: o, to: n)
            #expect(vc.scrollState.hScrollOffset <= maxFor(steps: 32, width: Double(n)) + 0.5, "heraus \(n)")
            #expect(vc.effectiveMaxOffset == maxFor(steps: 32, width: Double(n)))
        }
        // wieder hinein
        pinch(vc, from: 54, to: 90)
        #expect(vc.effectiveMaxOffset == maxFor(steps: 32, width: 90))
        #expect(vc.scrollState.hScrollOffset <= vc.effectiveMaxOffset)
    }

    @Test func otherWritersBetweenZoomStepsDoNotJumpBack() {
        let vc = rightEndController()
        pinch(vc, from: 54, to: 62)
        vc.scrollTrackpad(delta: 0)
        pinch(vc, from: 62, to: 70)
        vc.syncFromScrollbar(vc.scrollState.hScrollOffset)       // Thumb meldet gleiche Position
        vc.scroll(by: 0)
        pinch(vc, from: 70, to: 78)
        let m = maxFor(steps: 32, width: 78)
        #expect(vc.effectiveMaxOffset == m)
        #expect(vc.scrollState.hScrollOffset <= m + 0.5)
        // Trackpad bis ans Ende: exakt neue Grenze, nicht die alte
        vc.scrollTrackpad(delta: -100_000)
        #expect(vc.scrollState.hScrollOffset == m)
    }

    @Test func lateMeasurementsDoNotResetTheBoundToAnOlderState() {
        let vc = rightEndController()
        let late = LaneMetrics(viewportMinX: 237, viewportWidth: viewport, shapes: [LaneShape(stepCount: 32)])
        pinch(vc, from: 54, to: 66)
        let afterZoom = vc.scrollState.hScrollOffset
        // Eine verspätete Messung (gleiche Topologie, ältere Anwendung) trifft nach dem neueren Zoom ein.
        vc.applyLaneMetrics(late)
        #expect(vc.scrollState.hScrollOffset == afterZoom)
        #expect(vc.effectiveMaxOffset == maxFor(steps: 32, width: 66))
        // Danach legitime Änderungen: Count 32 → 20, Resize 551 → 700, Ratio 9:8
        vc.applyLaneMetrics(LaneMetrics(viewportMinX: 237, viewportWidth: viewport, shapes: [LaneShape(stepCount: 20)]))
        #expect(vc.effectiveMaxOffset == maxFor(steps: 20, width: 66))
        #expect(vc.scrollState.hScrollOffset == vc.effectiveMaxOffset, "Offset korrekt geklemmt")
        vc.applyLaneMetrics(LaneMetrics(viewportMinX: 237, viewportWidth: 700, shapes: [LaneShape(stepCount: 20)]))
        #expect(vc.effectiveMaxOffset == max(0, renderedExtent(steps: 20, width: 66) - 700))
        vc.applyLaneMetrics(LaneMetrics(viewportMinX: 237, viewportWidth: 700, shapes: [LaneShape(stepCount: 64, num: 9, den: 8)]))
        #expect(vc.effectiveMaxOffset == renderedExtent(steps: 64, num: 9, den: 8, width: 66) - 700)
    }

    @Test func nonIntegerRatiosUseTheRenderedSlotSums() {
        for r in TrackData.sortedRatios {
            for (w0, w1) in [(30.0, 47.0), (54.0, 71.0), (101.0, 120.0)] {
                for n in [1, 16, 64] {
                    let vc = rightEndController(steps: n, num: r.num, den: r.den, width: w0)
                    pinch(vc, from: CGFloat(w0), to: CGFloat(w0 + 8))
                    pinch(vc, from: CGFloat(w0 + 8), to: CGFloat(w1))
                    let expected = maxFor(steps: n, num: r.num, den: r.den, width: w1)
                    #expect(vc.effectiveMaxOffset == expected, "\(r.num):\(r.den) \(w0)→\(w1) n=\(n)")
                    #expect(vc.scrollState.hScrollOffset <= expected + 0.001)
                }
            }
        }
    }

    @Test func fractionalPinchWidthsUseTheCommittedRoundedWidth() {
        // Der Handler committet `committed.rounded()`; die Grenze muss zu dieser gerundeten Breite gehören.
        let vc = rightEndController()
        vc.adjustScroll(oldStepWidth: 54, newStepWidth: 62.6, anchorX: 551)
        #expect(vc.effectiveMaxOffset == maxFor(steps: 32, width: 63))
        #expect(vc.stepWidth == 63)
    }
}

// MARK: - Native Scrollbar-Bridge (G01)

@MainActor
struct G01ScrollbarBridgeTests {

    /// Hostet die echte `GlobalHScrollbar` (NSScrollView) mit Metriken aus einem echten ViewportController.
    private struct Harness: View {
        @ObservedObject var vc: ViewportController
        var body: some View { GlobalHScrollbar(metrics: vc.laneMetrics) }
    }

    private func settle(_ host: NSView) async {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        try? await Task.sleep(nanoseconds: UInt64(80) * 1_000_000)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    private func find(_ v: NSView) -> NSScrollView? {
        if let sv = v as? NSScrollView { return sv }
        for s in v.subviews { if let r = find(s) { return r } }
        return nil
    }

    @Test func nativeMaximumEqualsSharedMaximumAndSyncsBothDirections() async throws {
        let vc = ViewportController(scrollState: ScrollState())
        let sw = StepWidthState()
        sw.size = 54
        vc.setStepWidth(54)
        vc.applyLaneMetrics(LaneMetrics(viewportMinX: 237, viewportWidth: 551, shapes: [LaneShape(stepCount: 32)]))   // Inhalt 1884
        let host = NSHostingView(rootView: Harness(vc: vc)
            .environmentObject(vc).environmentObject(vc.scrollState).environmentObject(sw))
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 18),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 1400, height: 18)
        win.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        win.orderFrontRegardless()
        defer { win.orderOut(nil); win.contentView = nil }
        await settle(host)

        let sv = try #require(find(host))
        #expect(sv.convert(sv.bounds.origin, to: nil).x == 237, "Scrollbar beginnt am Lane-Viewport")
        #expect(sv.contentView.bounds.width == 551)
        #expect(sv.documentView?.frame.width == 1884)
        let nativeMax = (sv.documentView?.frame.width ?? 0) - sv.contentView.bounds.width
        #expect(nativeMax == vc.maxScrollOffset)
        #expect(nativeMax == 1333)

        // Controller → NSScrollView
        vc.scroll(by: 700)
        await settle(host)
        #expect(abs(sv.contentView.bounds.origin.x - 700) < 0.5)
        #expect(vc.scrollState.hScrollOffset == 700, "keine Rückkopplung: Offset bleibt")

        // NSScrollView (Thumb) → Controller, bis ans Ende; darüber hinaus wird geklemmt.
        // Wie ein echter Thumb-Drag: der NSClipView-Constraint begrenzt auf das native Maximum.
        let constrained = sv.contentView.constrainBoundsRect(NSRect(x: 5000, y: 0, width: 551, height: 1))
        sv.contentView.scroll(to: constrained.origin)
        sv.reflectScrolledClipView(sv.contentView)
        await settle(host)
        #expect(vc.scrollState.hScrollOffset == nativeMax)
        #expect(sv.contentView.bounds.origin.x <= nativeMax + 0.5)

        // Resize am rechten Ende: Viewport wird breiter → Maximum sinkt, Offset klemmt, Clip folgt.
        vc.applyLaneMetrics(LaneMetrics(viewportMinX: 237, viewportWidth: 900, shapes: [LaneShape(stepCount: 32)]))
        await settle(host)
        #expect(sv.contentView.bounds.width == 900)
        #expect(vc.maxScrollOffset == 984)
        #expect(vc.scrollState.hScrollOffset == 984)
        #expect(abs(sv.contentView.bounds.origin.x - 984) < 0.5)
        #expect((sv.documentView?.frame.width ?? 0) - sv.contentView.bounds.width == vc.maxScrollOffset)

        // Inhalt kleiner als Viewport: kein Overscroll.
        vc.applyLaneMetrics(LaneMetrics(viewportMinX: 237, viewportWidth: 1231, shapes: [LaneShape(stepCount: 18)]))
        await settle(host)
        #expect(vc.maxScrollOffset == 0)
        #expect(vc.scrollState.hScrollOffset == 0)
        #expect(sv.contentView.bounds.origin.x == 0)
    }
}

// MARK: - Lane-Views: gerenderte Breite == Formel, Clip == Viewport (leichtgewichtig, ohne MainView)

@MainActor
struct G01LaneRenderTests {

    private func pump(_ host: NSView) async {
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: UInt64(250) * 1_000_000)
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: UInt64(80) * 1_000_000)
        host.layoutSubtreeIfNeeded()
    }

    /// Step- und CC-Lanes in der Zeilenstruktur der App (Viewport 551 pt + feste Stretch-Spalte), Inhalt breiter als der Viewport.
    @Test func lanesRenderFormulaWidthAndClipToTheViewport() async throws {
        UserDefaults.standard.set("en", forKey: "appLanguage")
        defer { UserDefaults.standard.removeObject(forKey: "appLanguage") }
        let engine = SequencerEngine()
        engine.addTrack(kind: .cc)
        let tracks = engine.currentPattern.tracks
        tracks[0].lane.stepCount = 32
        tracks[1].lane.stepLengthNumerator = 9; tracks[1].lane.stepLengthDenominator = 8
        tracks[2].lane.stepCount = 6
        tracks.last(where: { $0.lane.kind == .cc })?.lane.stepCount = 24
        let ids = tracks.map(\.id)
        let viewport: CGFloat = 551
        let grids = tracks.map { _ in StepGridCoordinator() }

        let content = VStack(spacing: 8) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, td in
                LaneBodyView(track: engine.viewModel(for: td), grid: grids[idx],
                             accentColor: VintageTheme.color(forTrack: td.colorIndex),
                             trackIndex: idx, ccLaneDrawMode: .constant(false))
            }
        }
        .frame(width: viewport + StretchHandleView.width)
        .environmentObject(engine)
        .environmentObject(engine.transportState)
        .environmentObject(engine.midiLearnState)
        .environmentObject(engine.playbackDisplay)
        .environmentObject(engine.scrollState)
        .environmentObject(engine.stepWidthState)
        .environmentObject(engine.viewportController)
        .environmentObject(engine.interactionController)

        let host = NSHostingView(rootView: content)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: viewport + StretchHandleView.width, height: 900),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: viewport + StretchHandleView.width, height: 900)
        defer { win.contentView = nil }

        for width in [30.0, 54.0, 120.0] {
            engine.stepWidthState.size = width
            await pump(host)
            for (i, td) in tracks.enumerated() {
                let key = "\(ids[i])"
                let samples = LaneGeometryProbe.shared.samples
                let expected = LaneGeometry.contentExtent(stepCount: td.lane.stepCount,
                                                          num: td.lane.stepLengthNumerator,
                                                          den: td.lane.stepLengthDenominator,
                                                          stepWidthSize: width)
                let kind = td.lane.kind == .cc ? "cc" : "step"
                #expect(samples[key + "/content"] == expected, "\(kind)\(i) w\(Int(width)): gerendert ≠ Formel")
                #expect(samples[key + "/viewport"] == viewport, "\(kind)\(i) w\(Int(width)): Viewport")
                #expect(samples[key + "/clipContainer"] == viewport,
                        "\(kind)\(i) w\(Int(width)): Clip-Container ≠ Viewport (Inhalt \(expected))")
            }
        }
    }
}
