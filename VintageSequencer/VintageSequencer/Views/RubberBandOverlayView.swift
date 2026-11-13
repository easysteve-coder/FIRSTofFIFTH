import SwiftUI

// MARK: - RubberBandOverlayView

/// Rein visuelle Darstellung des Rubber-Band-Auswahlrechtecks.
///
/// Diese View zeichnet nur — sie enthält keine Gesten, keinen State,
/// keinen GeometryReader und keine Scroll-Logik.
///
/// Die Koordinaten werden vollständig vom Parent berechnet und übergeben:
///   - `left`:   Screen-Space X-Position der linken Kante (bereits aus Content-Space konvertiert)
///   - `width`:  Breite des Rechtecks (mind. 4 px, vom Parent geclampt)
///   - `height`: Entspricht `engine.stepDisplaySize` des Parent
///
/// Extracted from `TrackRowView` as part of E2 (TrackRowView decomposition, step 5).
struct RubberBandOverlayView: View {

    /// Screen-space X-Position der linken Kante des Auswahlrechtecks.
    /// Berechnung im Parent: `min(startScreen, endScreen)`
    var left:   CGFloat

    /// Breite des Auswahlrechtecks.
    /// Berechnung im Parent: `max(4, abs(endScreen - startScreen))`
    var width:  CGFloat

    /// Höhe des Auswahlrechtecks — entspricht `stepDisplaySize`.
    var height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color(red: 0.2, green: 0.5, blue: 1.0).opacity(0.15))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color(red: 0.3, green: 0.6, blue: 1.0).opacity(0.65),
                            lineWidth: 1)
            )
            .frame(width: width, height: height)
            .offset(x: left, y: 6)
            .allowsHitTesting(false)
    }
}
