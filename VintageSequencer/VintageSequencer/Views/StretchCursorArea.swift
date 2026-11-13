import SwiftUI
import AppKit

// MARK: - StretchCursorArea + StretchCursorNSView

/// Transparent AppKit-backed view that registers a `resizeUpDown` cursor rect
/// over its entire bounds.
///
/// **Why not SwiftUI `.onHover`?**
///
/// SwiftUI's `.onHover` calls `NSCursor.set()` directly, bypassing the AppKit
/// cursor-rect mechanism. As a result, `NSWindow.disableCursorRects()` — which
/// `CursorController` uses to suppress view-layer cursors during sessions — does
/// **not** suppress `.onHover` callbacks. A hover event could silently override
/// the session cursor.
///
/// Using `resetCursorRects()` instead puts `StretchCursorNSView` fully under the
/// AppKit cursor-rect system, so `disableCursorRects()` / `enableCursorRects()` /
/// `resetCursorRects()` control it uniformly — identical to `HandleNSView`.
///
/// **Hover unification:**
/// After this change both idle-hover sources use the same AppKit mechanism:
/// - `HandleNSView.resetCursorRects()` → `resizeLeftRight` (corner dot handles)
/// - `StretchCursorNSView.resetCursorRects()` → `resizeUpDown` (stretch handle)
///
/// **Correct session-end restore:**
/// When a session ends, `CursorController` calls `window.resetCursorRects()`.
/// AppKit immediately re-evaluates cursor rects based on the current mouse position.
/// If the pointer is already over the stretch handle at that moment, AppKit switches
/// to `resizeUpDown` without requiring a mouse-move — a behaviour impossible with
/// the old `.onHover` approach (which only fires on pointer entry/exit).
///
/// **Usage:**
/// ```swift
/// .background(StretchCursorArea())
/// ```
struct StretchCursorArea: NSViewRepresentable {

    func makeNSView(context: Context) -> StretchCursorNSView {
        StretchCursorNSView()
    }

    func updateNSView(_ nsView: StretchCursorNSView, context: Context) {
        // No dynamic properties — cursor rect is always resizeUpDown over full bounds.
    }
}

// MARK: - StretchCursorNSView

/// Minimal `NSView` that registers a `resizeUpDown` cursor rect over its bounds.
///
/// No content, no drawing, no event handling — cursor registration only.
final class StretchCursorNSView: NSView {

    override init(frame: NSRect) {
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        // Custom cursor matches the active-session cursor (CursorPolicy .stretchVertical)
        // for visual continuity: same cursor during hover and during drag.
        addCursorRect(bounds, cursor: CustomCursors.stretchVertical)
    }
}
