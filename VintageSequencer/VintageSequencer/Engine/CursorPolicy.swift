import AppKit

// MARK: - CursorPolicy

/// Pure mapping from `SessionCursorHint` + modifier flags to `NSCursor`.
///
/// **No state, no dependencies, no side effects.**
/// The caller (`CursorController`) owns the NSEvent monitor and applies the result.
///
/// **Modifier evaluation lives here, not in `InteractionController`.**
/// IC remains modifier-agnostic; only cursor semantics depend on modifier state.
///
/// **Design mirror:** Analogous to `EdgeScrollVelocity` — a pure, testable
/// policy enum that the owning controller feeds with live inputs.
enum CursorPolicy {

    // MARK: - Public API

    /// Returns the appropriate `NSCursor` for the given session hint and modifier flags.
    ///
    /// - Parameters:
    ///   - hint:      The cursor intent published by `InteractionController`.
    ///   - modifiers: Current modifier key flags (typically `NSEvent.modifierFlags`).
    /// - Returns: The `NSCursor` to display.
    static func cursor(hint: SessionCursorHint,
                       modifiers: NSEvent.ModifierFlags) -> NSCursor {
        switch hint {
        case .none:
            return .arrow

        case .resizeHorizontal:
            // Step-count handle drag, ratio handle drag.
            return .resizeLeftRight

        case .resizeVertical:
            // Pitch drag — generic vertical resize.
            return .resizeUpDown

        case .stretchVertical:
            // Stretch ratio drag, stretch count drag — custom grip cursor.
            // Same cursor as the idle hover (StretchCursorNSView) for continuity.
            return CustomCursors.stretchVertical

        case .selectRegion:
            // Rubber-band selection.
            return .crosshair

        case .moveStep:
            // Step-swap drag.
            // Option held → copy semantics (green ⊕ badge, macOS standard).
            // No Option → move semantics (closed-hand grab).
            return modifiers.contains(.option) ? .dragCopy : .closedHand
        }
    }
}
