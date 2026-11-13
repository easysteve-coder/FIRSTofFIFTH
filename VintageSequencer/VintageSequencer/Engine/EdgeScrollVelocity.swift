import CoreGraphics

// MARK: - EdgeScrollVelocity

/// Pure scroll-velocity policy for edge auto-scroll during drag interactions.
///
/// **Arch-Slice-7 — AutoScroll + Handle-Geometrie:**
/// Replaces the hardcoded linear ramp in `EdgeAutoScroller` and `HandleNSView`
/// with a single, testable, smoothstep policy.
///
/// **No state, no dependencies, no side effects.**
/// The caller (`InteractionController`) owns the timer and applies the velocity.
///
/// **Smoothstep curve:**
///
///   t = clamp((zoneWidth − distance) / zoneWidth, 0, 1)
///   velocity = maxVelocity × t² × (3 − 2t)
///
/// Properties:
///   - Zero velocity and zero derivative at the zone entry (no abrupt onset)
///   - Maximum velocity at the viewport edge
///   - Positive = scroll right, negative = scroll left
///
/// **Zone reference:** The `viewWidth` parameter is the width of the scrollable
/// viewport as seen by the caller. For `StepGridView` this is `geo.size.width`;
/// for `HandleNSView` this is `window.contentView.bounds.width`.
enum EdgeScrollVelocity {

    // MARK: - Default parameters
    //
    // v1.12.23 (GUI-Revision): Die frühere Zone von 300 px je Seite überlappte in schmalen
    // Lanes — bei 551 px Breite scrollte ein ruhender Zeiger in der Lane-Mitte. Jetzt:
    //   • Zone 80 px, zusätzlich auf ein Viertel der nutzbaren Breite begrenzt → die
    //     mittlere Hälfte des Viewports ist immer scrollfrei, die Zonen überlappen nie.
    //   • Insets verschieben nur die Kante, an der die volle Geschwindigkeit erreicht ist.
    //     Im Inset und jenseits des Viewports gilt volle Geschwindigkeit (vorher: 0 — ein
    //     über den Rand hinaus gezogener Zeiger hielt das Scrollen an).
    //   • Rubberband meldet Lane-Koordinaten (Insets 0). Die Eck-Anfasser melden
    //     Fensterkoordinaten und übergeben den Spurkopf bzw. den rechten Rand als Inset.

    /// Breite der Rampe vor jeder (um das Inset verschobenen) Viewport-Kante (px).
    static let defaultZoneWidth:   CGFloat = 80
    /// Höchstgeschwindigkeit an der Kante (px/Frame bei 60 Hz).
    static let defaultMaxVelocity: CGFloat = 14
    static let defaultLeftInset:   CGFloat = 0
    static let defaultRightInset:  CGFloat = 0

    // MARK: - Public API

    /// Auto-Scroll-Geschwindigkeit für die aktuelle Zeigerposition.
    ///
    /// - Parameters:
    ///   - pointerX:   Zeiger-X im Koordinatenraum des Aufrufers.
    ///   - viewWidth:  Breite des Viewports im selben Raum.
    ///   - leftZoneWidth / rightZoneWidth: Rampenbreite je Seite (0 = Seite aus).
    ///   - leftInset / rightInset: nicht scrollbarer Rand je Seite (z. B. Spurkopf).
    ///   - maxVelocity: px/Frame an der Kante.
    /// - Returns: px/Frame. Positiv = nach rechts, negativ = nach links, 0 = kein Scroll.
    static func velocity(
        pointerX:       CGFloat,
        viewWidth:      CGFloat,
        leftZoneWidth:  CGFloat = defaultZoneWidth,
        rightZoneWidth: CGFloat = defaultZoneWidth,
        leftInset:      CGFloat = defaultLeftInset,
        rightInset:     CGFloat = defaultRightInset,
        maxVelocity:    CGFloat = defaultMaxVelocity
    ) -> CGFloat {
        let usable = viewWidth - leftInset - rightInset
        guard viewWidth > 0, usable > 0 else { return 0 }
        let cap       = usable / 4
        let leftZone  = min(leftZoneWidth,  cap)
        let rightZone = min(rightZoneWidth, cap)

        let distLeft  = pointerX - leftInset
        let distRight = (viewWidth - rightInset) - pointerX

        if rightZone > 0, distRight < rightZone {
            return  maxVelocity * smoothstep(t: (rightZone - distRight) / rightZone)
        }
        if leftZone > 0, distLeft < leftZone {
            return -maxVelocity * smoothstep(t: (leftZone - distLeft) / leftZone)
        }
        return 0
    }

    // MARK: - Private helpers

    /// Smoothstep curve: zero derivative at t=0 and t=1, monotone in between.
    private static func smoothstep(t raw: CGFloat) -> CGFloat {
        let t = max(0, min(1, raw))   // clamp to [0, 1]
        return t * t * (3 - 2 * t)
    }
}
