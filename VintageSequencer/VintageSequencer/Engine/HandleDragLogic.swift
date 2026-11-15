import CoreGraphics

// MARK: - HandleDragLogic

/// Reine Berechnungsfunktionen für den Handle-Drag-Pfad.
///
/// Kapselt die Logik aus `CornerHandlesView`, damit sie ohne SwiftUI/AppKit
/// deterministisch getestet werden kann.
///
/// **Invarianten:**
/// - `stepCount` ändert `hScrollOffset` nie — nur `edgeScroll` darf das.
/// - `stepCount` ist idempotent: derselbe `totalX`-Wert liefert immer dasselbe Ergebnis.
/// - `ratioIndex` ist idempotent: derselbe `totalX`-Wert liefert immer denselben Index.
enum HandleDragLogic {

    // MARK: - Step-Count-Handle

    /// Berechnet die neue Step-Anzahl aus dem kumulierten Drag-Delta.
    ///
    /// - Parameters:
    ///   - totalX:     Gesamtverschiebung in Pixeln seit Drag-Start
    ///                 (= currentMouseX − startMouseX + autoScrollAccum).
    ///   - pxPerStep:  Breite eines Slots inkl. Spacing
    ///                 (= (stepWidthSize + stepSpacing) × num/den).
    ///   - startCount: `stepCount` bei Drag-Start (aus Snapshot).
    /// - Returns: Neue Step-Anzahl, geklemmt auf [1, 64].
    static func stepCount(
        totalX:     CGFloat,
        pxPerStep:  CGFloat,
        startCount: Int
    ) -> Int {
        let delta = Int((totalX / pxPerStep).rounded())
        return max(1, min(64, startCount + delta))
    }

    // MARK: - Ratio-Handle

    /// Berechnet den nächstgelegenen Ratio-Index aus dem kumulierten Drag-Delta.
    ///
    /// Jedes Ratio hat einen Schwellenwert (threshold) relativ zur Basis:
    ///   `thr = contentUnit × (ratio_i − base_ratio)`
    ///
    /// Der Index mit dem kleinsten Abstand zu `totalX` wird zurückgegeben.
    ///
    /// - Parameters:
    ///   - totalX:         Gesamtverschiebung in Pixeln seit Drag-Start.
    ///   - contentUnit:    Gesamtbreite des Inhalts bei Ratio 1:1
    ///                     (= stepCount × (stepWidthSize + stepSpacing)).
    ///                     Berechnet beim Drag-Start, stabil für die Session.
    ///   - baseRatioIndex: Index des Ausgangs-Ratios bei Drag-Start.
    ///   - ratios:         Die Ratio-Tabelle (typischerweise Track.sortedRatios).
    /// - Returns: Index in `ratios` des nächstgelegenen Ratios.
    ///   - longStepPx:     Ziehweg je Stufe der langen Längen (> 2 Sechzehntel, v1.18.29) —
    ///                     zeitgetreu wäre der Weg bis 8 Takte unbedienbar lang. nil = alles
    ///                     zeitgetreu.
    static func ratioIndex(
        totalX:         CGFloat,
        contentUnit:    CGFloat,
        baseRatioIndex: Int,
        ratios:         [(num: Int, den: Int)],
        longStepPx:     CGFloat? = nil
    ) -> Int {
        guard !ratios.isEmpty else { return baseRatioIndex }
        let base = max(0, min(ratios.count - 1, baseRatioIndex))
        // Lage jeder Stufe auf dem Ziehweg: kurze Längen zeitgetreu, lange in festen Stufen
        // hinter der längsten kurzen.
        let values = ratios.map { CGFloat($0.num) / CGFloat($0.den) }
        let lastShort = values.lastIndex { $0 <= 2 }
        func position(_ i: Int) -> CGFloat {
            guard let px = longStepPx, px > 0, let ls = lastShort, i > ls else { return contentUnit * values[i] }
            return contentUnit * values[ls] + CGFloat(i - ls) * px
        }
        let basePos  = position(base)
        var bestIdx  = base
        var bestDist = CGFloat.infinity
        for i in 0..<ratios.count {
            let thr = position(i) - basePos
            let dist = abs(totalX - thr)
            if dist < bestDist {
                bestDist = dist
                bestIdx  = i
            }
        }
        return bestIdx
    }

    // MARK: - Edge-Scroll

    /// Wendet eine Edge-Scroll-Geschwindigkeit auf den aktuellen Offset an.
    ///
    /// Wird nur aus dem Edge-Scroll-Timer in `HandleNSView` gerufen —
    /// nie aus dem normalen Drag-Pfad.
    ///
    /// - Parameters:
    ///   - currentOffset: Aktueller `hScrollOffset`.
    ///   - velocity:      Scroll-Geschwindigkeit (px/Frame), negativ = nach links.
    /// - Returns: Neuer Offset, geklemmt auf ≥ 0.
    static func applyEdgeScroll(currentOffset: CGFloat, velocity: CGFloat) -> CGFloat {
        max(0, currentOffset + velocity)
    }
}
