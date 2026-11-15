import SwiftUI
import AppKit

// MARK: - LaneGeometry (G01)

/// Reine Geometrie für den horizontal scrollenden Lane-Bereich (Step- und CC-Lane).
///
/// Eine Wahrheit pro Größe:
///   - **Inhaltsausdehnung** (`contentExtent`): Summe der real gerenderten, gerundeten Zellbreiten
///     (`VintageTheme.distributedStepWidth`) + Zellabstände + führendes/nachfolgendes Padding + Corner-Handle-Breite.
///   - **Viewport-Breite**: gemessen am tatsächlichen Lane-GeometryReader (`LaneViewportReporter`), nicht aus
///     Fensterbreite minus Konstanten geschätzt.
///   - **Maximaler Offset**: `max(0, contentExtent − viewportWidth)`, einzige Formel (`maxOffset`).
enum LaneGeometry {

    /// Name des Koordinatenraums, in dem der Viewport-Beginn (minX) gemessen wird (gesetzt in `MainView`).
    static let space = "fofLaneSpace"

    /// Index der Step-Zelle unter einem Punkt der Lane, nil in Lücken, Rändern und hinter dem
    /// letzten Step. Umkehrung des Zell-Layouts (`distributedStepWidth`): Zelle i reicht von
    /// round(slot·i) bis round(slot·(i+1)) − stepSpacing, versetzt um `stepGridLeadingPad`.
    ///
    /// - Parameters:
    ///   - contentX: x im Inhaltsraum der Lane (Bildschirm-x + Scroll-Offset).
    ///   - y / rowHeight / cellHeight: Zellen sitzen senkrecht mittig in der Zeile.
    static func stepIndex(contentX: CGFloat, y: CGFloat, rowHeight: CGFloat, cellHeight: CGFloat,
                          stepCount: Int, num: Int, den: Int, stepWidthSize: Double) -> Int? {
        guard stepCount > 0, den > 0, num > 0 else { return nil }
        let top = (rowHeight - cellHeight) / 2
        guard y >= top, y < top + cellHeight else { return nil }
        let slot = (CGFloat(stepWidthSize) + VintageTheme.stepSpacing) * CGFloat(num) / CGFloat(den)
        let x = contentX - VintageTheme.stepGridLeadingPad
        guard slot > 0, x >= 0 else { return nil }
        // Rundung der Zellgrenzen kann den Punkt in die Nachbarzelle legen → beide prüfen.
        let guess = Int(x / slot)
        for i in [guess - 1, guess, guess + 1] where i >= 0 && i < stepCount {
            let start = (slot * CGFloat(i)).rounded(.toNearestOrEven)
            let end   = (slot * CGFloat(i + 1)).rounded(.toNearestOrEven) - VintageTheme.stepSpacing
            if x >= start && x < end { return i }
        }
        return nil
    }

    /// Inhaltsausdehnung einer Lane mit `stepCount` Zellen. Referenz: reale gerundete Zellgrenzen.
    ///
    /// Layout (Step- und CC-Lane): `HStack(spacing: stepSpacing) { Zellen…; CornerHandles }`
    /// mit `.padding(.horizontal, stepGridLeadingPad)` → Summe(Zellbreiten) + n × stepSpacing
    /// + 2 × stepGridLeadingPad + cornerHandlesWidth.
    static func contentExtent(stepCount: Int, num: Int, den: Int, stepWidthSize: Double) -> CGFloat {
        let n = max(0, stepCount)
        var cells: CGFloat = 0
        for i in 0..<n {
            cells += VintageTheme.distributedStepWidth(index: i, num: num, den: den, stepWidthSize: stepWidthSize)
        }
        return sane(cells + CGFloat(n) * VintageTheme.stepSpacing
                    + 2 * VintageTheme.stepGridLeadingPad
                    + VintageTheme.cornerHandlesWidth)
    }

    /// Breiteste Lane für die gegebene WIDTH; 0 ohne Lanes. Exakt für jede Breite, weil aus der Topologie
    /// (Stepzahl, Ratio) und der realen Rundung berechnet — nie durch Skalieren einer anderen gemessenen Breite.
    static func contentExtent(shapes: [LaneShape], stepWidthSize: Double) -> CGFloat {
        shapes.map {
            contentExtent(stepCount: $0.stepCount, num: $0.num, den: $0.den, stepWidthSize: stepWidthSize)
        }.max() ?? 0
    }

    /// Breiteste Lane des Patterns; 0 ohne Tracks.
    static func contentExtent(tracks: [TrackData], stepWidthSize: Double) -> CGFloat {
        contentExtent(shapes: tracks.map(LaneShape.init(track:)), stepWidthSize: stepWidthSize)
    }

    /// Einheitliche Scrollgrenze für Trackpad, Edge-Scroll, Scrollbar, Zoom-Kompensation und Resize-Klemmung.
    static func maxOffset(contentExtent: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        max(0, sane(contentExtent) - sane(viewportWidth))
    }

    /// Klemmt `offset` auf `[0, maxOffset]`; NaN/Infinity zählen als 0.
    static func clamp(_ offset: CGFloat, max maxOffset: CGFloat) -> CGFloat {
        Swift.max(0, Swift.min(sane(maxOffset), sane(offset)))
    }

    /// Breite des scrollbaren Dokuments für den NSScrollView, dessen Clip `viewportWidth` breit ist:
    /// natives Maximum (`documentWidth − clipWidth`) == `maxOffset`.
    static func documentWidth(contentExtent: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        max(sane(contentExtent), sane(viewportWidth), 1)
    }

    /// Ersetzt NaN, Infinity und negative Größen durch 0.
    static func sane(_ v: CGFloat) -> CGFloat {
        v.isFinite ? Swift.max(0, v) : 0
    }
}

// MARK: - Messwerte der gerenderten Lanes (Preferences)

/// Topologie einer Lane: alles, was ihre Inhaltsbreite außer WIDTH bestimmt. Bewusst ohne Breitenangabe — eine verspätete
/// Meldung kann dadurch nie zu einem älteren WIDTH-Stand gehören.
struct LaneShape: Hashable {
    var stepCount: Int
    var num: Int
    var den: Int

    init(stepCount: Int, num: Int = 1, den: Int = 1) {
        self.stepCount = stepCount; self.num = num; self.den = den
    }
    init(track: TrackData) {
        self.init(stepCount: track.lane.stepCount,
                  num: track.lane.displayNumerator, den: track.lane.displayDenominator)
    }
}

/// Von den Lane-Views gemeldete Geometrie: Viewport und Lane-Topologien (alle Lanes teilen sich dieselbe Viewport-Geometrie).
struct LaneMetrics: Equatable {
    /// Beginn des Lane-Viewports im Raum `LaneGeometry.space`; nil = noch nicht gemessen.
    var viewportMinX: CGFloat? = nil
    var viewportWidth: CGFloat = 0
    /// Verschiedene Lane-Topologien des Patterns (ohne Duplikate).
    var shapes: [LaneShape] = []

    var hasViewport: Bool { viewportMinX != nil && viewportWidth > 0 }

    /// Breiteste Inhaltsausdehnung für die gegebene WIDTH.
    func contentExtent(at stepWidthSize: Double) -> CGFloat {
        LaneGeometry.contentExtent(shapes: shapes, stepWidthSize: stepWidthSize)
    }
}

/// Viewport-Beginn und -Breite (eine Wahrheit: alle Lanes melden dasselbe; die erste gültige Meldung zählt).
struct LaneViewport: Equatable {
    var minX: CGFloat
    var width: CGFloat
    var isValid: Bool { minX.isFinite && width.isFinite && width > 0 }
}

struct LaneViewportKey: PreferenceKey {
    static let defaultValue: LaneViewport? = nil
    static func reduce(value: inout LaneViewport?, nextValue: () -> LaneViewport?) {
        if value == nil || value?.isValid == false { value = nextValue() }
    }
}

/// Topologien aller gerenderten Lanes (ohne Duplikate).
struct LaneShapesKey: PreferenceKey {
    static let defaultValue: [LaneShape] = []
    static func reduce(value: inout [LaneShape], nextValue: () -> [LaneShape]) {
        for s in nextValue() where !value.contains(s) { value.append(s) }
    }
}

/// Misst den echten Lane-Viewport. Klein gehalten: bei vertikalem Scrollen läuft nur dieser Reader neu,
/// nicht der Lane-Inhalt. Es wird nur minX/Breite gemeldet (nicht minY) → keine Änderung beim Scrollen.
struct LaneViewportReporter: View {
    var body: some View {
        GeometryReader { g in
            Color.clear.preference(
                key: LaneViewportKey.self,
                value: LaneViewport(minX: g.frame(in: .named(LaneGeometry.space)).minX,
                                    width: g.size.width))
        }
        .allowsHitTesting(false)
    }
}

#if DEBUG
// MARK: - DEBUG-Testnaht

/// Hält die zuletzt gemessene Lane-Geometrie für Tests (kein Produktionsdiagnosefeld, nur DEBUG).
/// Wird aus den Lane-Views geschrieben, nie gelesen.
final class LaneGeometryProbe {
    static let shared = LaneGeometryProbe()
    /// Schlüssel: `"<lane>/<name>"`, z. B. `"step/clipContainer"`.
    private(set) var samples: [String: CGFloat] = [:]
    func record(_ key: String, _ value: CGFloat) { samples[key] = value }
    func reset() { samples.removeAll() }
}

/// Meldet die tatsächliche Größe des Containers, auf dem `.clipped()`/`.contentShape` liegen.
struct LaneGeometryProbeView: View {
    let key: String
    var body: some View {
        GeometryReader { g in
            Color.clear
                .onAppear { LaneGeometryProbe.shared.record(key, g.size.width) }
                .onValueChange(of: g.size.width) { w in LaneGeometryProbe.shared.record(key, w) }
        }
        .allowsHitTesting(false)
    }
}
#endif

// MARK: - SecondaryClickCatcher

/// Fängt Sekundärklicks (rechte Maustaste, ctrl+Klick) über einer Lane ab — genau EINE
/// AppKit-View je Lane statt einer je Step. SwiftUI kennt keine Rechtsklick-Geste;
/// `.contextMenu` würde ein Menü zeigen statt direkt zu handeln.
///
/// Die View ist für alle anderen Ereignisse durchlässig (`hitTest` → nil): Klicks, Drags,
/// Scrollen und Hover erreichen unverändert die SwiftUI-Gesten darunter. Sie beansprucht
/// einen Sekundärklick nur, wenn `accepts(point)` zustimmt (Punkt liegt auf einem Step).
struct SecondaryClickCatcher: NSViewRepresentable {
    /// Punkt im Koordinatenraum der überlagerten View (Ursprung oben links).
    let accepts: (CGPoint) -> Bool
    let action:  (CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView(); v.accepts = accepts; v.action = action; return v
    }
    func updateNSView(_ v: CatcherView, context: Context) { v.accepts = accepts; v.action = action }

    final class CatcherView: NSView {
        var accepts: (CGPoint) -> Bool = { _ in false }
        var action:  (CGPoint) -> Void = { _ in }
        override var isFlipped: Bool { true }

        private static func isSecondary(_ e: NSEvent?) -> Bool {
            guard let e else { return false }
            if e.type == .rightMouseDown || e.type == .rightMouseUp { return true }
            return (e.type == .leftMouseDown || e.type == .leftMouseUp) && e.modifierFlags.contains(.control)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard Self.isSecondary(NSApp.currentEvent), let sv = superview else { return nil }
            let local = convert(point, from: sv)
            return bounds.contains(local) && accepts(local) ? self : nil
        }
        override func rightMouseDown(with event: NSEvent) { fire(event) }
        override func mouseDown(with event: NSEvent)      { fire(event) }   // ctrl+Klick
        private func fire(_ event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            if accepts(p) { action(p) }
        }
    }
}
