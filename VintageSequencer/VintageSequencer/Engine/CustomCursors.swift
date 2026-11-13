import AppKit

// MARK: - CustomCursors

/// Centralized factory for custom NSCursor instances used in VintageSequencer.
///
/// **Design contract:**
/// - Each cursor is a `static let` — created exactly once, reused everywhere.
/// - No cursor construction on hover events or drag frames.
/// - Views reference these directly in `resetCursorRects()`; `CursorPolicy`
///   references them from session hint → cursor mapping. Zero duplication.
///
/// **Thread safety:** Swift `static let` is lazily initialized with a thread-safe
/// dispatch_once guarantee. Safe to access from any thread.
enum CustomCursors {

    // MARK: - Stretch Vertical

    /// Custom cursor for vertical stretch/adjust interactions.
    ///
    /// **Used by:**
    ///   - `StretchCursorNSView.resetCursorRects()` → idle hover
    ///   - `CursorPolicy.cursor(hint: .stretchVertical, …)` → active session
    ///
    /// **Design:**
    /// Two short horizontal grip rails flanking a center gap, with small
    /// filled arrowheads pointing outward above and below — communicating
    /// "vertical expand/compress". Echoes the horizontal-stripe grip visual
    /// of StretchHandleView without duplicating the system resizeUpDown arrow.
    ///
    /// ```
    ///      ▲          ← small up arrowhead (tip y≈15)
    ///   ────────      ← top rail    (y 11…12.5)
    ///
    ///   ────────      ← bottom rail (y 3.5…5)
    ///      ▼          ← small down arrowhead (tip y≈0.5)
    /// ```
    ///
    /// **Hotspot:** center (8, 8) — pointer lands on the visual midpoint of
    /// the grip gap, matching the StretchHandleView interaction zone.
    ///
    /// **Coordinates:** NSImage non-flipped (origin bottom-left, y upward).
    static let stretchVertical: NSCursor = makeStretchVerticalCursor()

    // MARK: - Private construction

    private static func makeStretchVerticalCursor() -> NSCursor {
        let ptSize  = NSSize(width: 16, height: 16)
        let hotspot = NSPoint(x: 8, y: 8)   // center — visually neutral anchor

        let image = NSImage(size: ptSize)
        image.lockFocus()

        NSColor.black.setFill()

        // ── Up arrowhead (tip at top, base aligns with top rail) ─────────
        // Non-flipped: y=15 is near top of image.
        let up = NSBezierPath()
        up.move(to:  NSPoint(x: 8,    y: 15.5))   // tip
        up.line(to:  NSPoint(x: 5.5,  y: 13.0))   // base-left
        up.line(to:  NSPoint(x: 10.5, y: 13.0))   // base-right
        up.close()
        up.fill()

        // ── Top grip rail ─────────────────────────────────────────────────
        NSBezierPath(rect: NSRect(x: 3.5, y: 11.0, width: 9, height: 1.5)).fill()

        // ── Bottom grip rail ───────────────────────────────────────────────
        NSBezierPath(rect: NSRect(x: 3.5, y: 3.5, width: 9, height: 1.5)).fill()

        // ── Down arrowhead (tip at bottom, base aligns with bottom rail) ──
        // Non-flipped: y=0.5 is near bottom of image.
        let down = NSBezierPath()
        down.move(to:  NSPoint(x: 8,    y: 0.5))   // tip
        down.line(to:  NSPoint(x: 5.5,  y: 3.0))   // base-left
        down.line(to:  NSPoint(x: 10.5, y: 3.0))   // base-right
        down.close()
        down.fill()

        image.unlockFocus()
        return NSCursor(image: image, hotSpot: hotspot)
    }
}
