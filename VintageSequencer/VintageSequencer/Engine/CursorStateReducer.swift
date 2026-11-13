// MARK: - CursorStateReducer

/// Pure state reducer for cursor ownership transitions.
///
/// **No AppKit imports. No side effects. No dependencies.**
///
/// Encodes exactly two rules:
/// 1. `.idle → .session` when a session becomes active (→ disable cursor rects).
/// 2. `.session → .idle` when a session ends or focus is lost (→ enable cursor rects).
///
/// Both transitions are idempotent: calling `acquireIfNeeded()` twice in a row
/// only triggers the side-effect-requiring transition once (return value signals
/// whether the caller must perform the AppKit call).
///
/// **Design mirror:** Analogous to `HandleDragSession.proposedStepCount` —
/// a pure, tested state function whose caller (`CursorController`) owns all
/// AppKit side effects.
///
/// **Testability:** This type has zero AppKit dependencies and is fully
/// unit-testable without a running AppKit application or window.
struct CursorStateReducer: Equatable {

    // MARK: - Ownership

    /// Whether the cursor is owned by the interaction controller or the view layer.
    enum Ownership: Equatable {
        /// `CursorController` owns the cursor.
        /// `NSWindow.disableCursorRects()` is active.
        case session

        /// The view-layer cursor-rect system owns the cursor.
        /// `NSWindow.enableCursorRects()` is active; `resetCursorRects` is operational.
        case idle
    }

    // MARK: - State

    private(set) var ownership: Ownership = .idle

    // MARK: - Transitions

    /// Attempt to acquire cursor ownership.
    ///
    /// Call when `sessionCursorHint != .none`.
    ///
    /// - Returns: `true` on the `.idle → .session` transition —
    ///   the caller MUST call `disableCursorRects()`.
    ///   `false` when already `.session` — idempotent, no AppKit call needed.
    @discardableResult
    mutating func acquireIfNeeded() -> Bool {
        guard ownership == .idle else { return false }
        ownership = .session
        return true
    }

    /// Release cursor ownership.
    ///
    /// Call when `sessionCursorHint == .none`, on focus loss, or on deactivation.
    ///
    /// - Returns: `true` on the `.session → .idle` transition —
    ///   the caller MUST call `enableCursorRects()` + `resetCursorRects()`.
    ///   `false` when already `.idle` — idempotent, no AppKit call needed.
    @discardableResult
    mutating func releaseIfNeeded() -> Bool {
        guard ownership == .session else { return false }
        ownership = .idle
        return true
    }

    // MARK: - Query

    /// `true` when the controller currently owns the cursor (session is active).
    var isOwningCursor: Bool { ownership == .session }
}
