import AppKit
import Combine

// MARK: - CursorController

/// Single legitimate `NSCursor` writer for interaction sessions.
///
/// ## Ownership model
///
/// `CursorStateReducer` tracks whether this controller or the view-layer
/// cursor-rect system owns the cursor at any moment. Exactly one owner at a time.
///
/// | State | Owner | AppKit mechanism |
/// |---|---|---|
/// | Session active | `CursorController` | `disableCursorRects` + `NSCursor.set()` |
/// | Idle | View layer | `enableCursorRects` + `resetCursorRects` |
///
/// ## Lifecycle robustness
///
/// **Focus loss** (`NSWindow.didResignKeyNotification`):
/// Ownership is unconditionally released and cursor rects are re-enabled on the
/// resigning window. Prevents permanently disabled cursor rects when the window
/// loses key status mid-drag (Cmd-Tab, modal alert, Mission Control).
///
/// **Focus regain** (`NSWindow.didBecomeKeyNotification`):
/// Modifier flag cache is refreshed (user may have changed modifiers while the
/// app was in the background) and `apply()` is re-run. If a session is still
/// active, ownership is re-acquired; otherwise the view layer remains in control.
///
/// ## Modifier caching
///
/// `cachedModifiers` is populated from each `flagsChanged` event — not by lazily
/// reading `NSEvent.modifierFlags` inside `apply()`. This ensures the cursor
/// always reflects the modifier state at the exact moment of the key event, not
/// at the potentially later moment the Combine sink or event handler runs.
/// Initialized from `NSEvent.modifierFlags` at construction as a baseline.
///
/// ## Idempotent ownership transitions
///
/// `disableCursorRects()` is called **once** on the `.idle → .session` transition,
/// not on every subsequent modifier-key change during the same session. Similarly,
/// `enableCursorRects()` is called **once** on the `.session → .idle` transition.
/// This is enforced by `CursorStateReducer.acquireIfNeeded()` / `releaseIfNeeded()`.
///
/// ## Hover cursor unification
///
/// Both hover cursor sources now use the AppKit cursor-rect mechanism:
/// - `HandleNSView.resetCursorRects()` → `resizeLeftRight` (corner dot handles)
/// - `StretchCursorNSView.resetCursorRects()` → `resizeUpDown` (stretch handle)
///
/// Because both use cursor rects, `disableCursorRects()` suppresses both during
/// sessions and `enableCursorRects()` + `resetCursorRects()` restores both on
/// session end — including when the pointer is already over a hover zone (AppKit
/// re-evaluates cursor rects immediately on `resetCursorRects()`).
///
/// ## Thread safety
///
/// All paths arrive on the main thread:
/// - Combine sink: `receive(on: RunLoop.main)`
/// - `NSEvent.addLocalMonitorForEvents`: main-thread delivery guaranteed by AppKit
/// - `NotificationCenter` observers: `queue: .main`
final class CursorController {

    // MARK: - State

    private var reducer = CursorStateReducer()

    /// Modifier flags captured from the most recent `flagsChanged` event.
    /// Initialized from `NSEvent.modifierFlags` at construction time.
    private var cachedModifiers: NSEvent.ModifierFlags

    // MARK: - Dependencies

    private let ic: InteractionController

    // MARK: - Subscriptions / Observers

    private var hintSink:       AnyCancellable?
    private var flagMonitor:    Any?
    private var resignObserver: NSObjectProtocol?
    private var becomeObserver: NSObjectProtocol?

    // MARK: - Init / Deinit

    init(ic: InteractionController) {
        self.ic = ic
        self.cachedModifiers = NSEvent.modifierFlags   // baseline at construction

        // 1. React to session start / end (hint changes drive the primary update).
        //
        // BUGFIX (Arch-Slice-13):
        //
        // Two bugs in the original implementation:
        //
        // Bug A — stale property read:
        //   `{ _ in self?.apply() }` ignores the emitted value and re-reads
        //   `ic.sessionCursorHint` inside `apply()`. Because `@Published` fires in
        //   `willSet` (before the assignment), and `.receive(on:)` defers delivery,
        //   multiple hint changes within one RunLoop iteration (e.g. begin + commit
        //   for a fast tap, or SwiftUI gesture batch) cause ALL deferred sinks to
        //   read the FINAL value (`.none`). The cursor never changes.
        //
        // Bug B — RunLoop.main only fires in .default mode:
        //   `.receive(on: RunLoop.main)` schedules on `.defaultRunLoopMode`.
        //   During AppKit event tracking (e.g. SwiftUI DragGesture modal tracking),
        //   the RunLoop runs in `.NSEventTrackingRunLoopMode`, so the sink NEVER fires
        //   during the drag — only after it ends, when the hint is already `.none`.
        //
        // Fix:
        //   • Use `DispatchQueue.main` instead of `RunLoop.main` — the dispatch queue
        //     drains in ALL RunLoop modes, including event-tracking mode.
        //   • Capture and use the emitted `hint` value directly instead of re-reading
        //     the property. The emitted value is the NEW value (from `willSet`) and
        //     is correct regardless of when delivery occurs.
        //   • `apply()` (called from flagMonitor and handleFocusGained) is kept for
        //     synchronous paths that correctly read the live property.
        hintSink = ic.$sessionCursorHint
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hint in
                self?.apply(hint: hint)
            }

        // 2. Cache modifier flags on each key event; immediately re-apply cursor.
        //    Caching from the event (not reading NSEvent.modifierFlags in apply())
        //    ensures the cursor reflects modifier state at the exact moment of press.
        flagMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.cachedModifiers = event.modifierFlags
            self?.apply()
            return event
        }

        // 3. Focus loss: unconditionally release ownership to prevent permanently
        //    disabled cursor rects after Cmd-Tab or other out-of-app transitions.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleFocusLost(window: notification.object as? NSWindow)
        }

        // 4. Focus regain: refresh modifier cache and re-apply.
        becomeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleFocusGained()
        }
    }

    deinit {
        if let m = flagMonitor    { NSEvent.removeMonitor(m) }
        if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
        if let o = becomeObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: - Internal access for tests

    /// `true` when this controller currently owns the cursor.
    /// Exposed `internal` so unit tests can assert ownership state without
    /// needing an AppKit window (all AppKit calls are guarded by optionals).
    internal var isOwningCursor: Bool { reducer.isOwningCursor }

    // MARK: - Core logic

    /// Synchronous wrapper for modifier-key and focus-regain paths.
    ///
    /// Reads `ic.sessionCursorHint` directly — safe here because both callers
    /// (flagMonitor, handleFocusGained) run synchronously on the main thread
    /// AFTER the assignment has completed, so the property reflects the live value.
    ///
    /// The Combine sink does NOT go through this wrapper — it calls
    /// `apply(hint:)` directly with the emitted value to avoid the stale-read
    /// race described in the BUGFIX comment above.
    private func apply() {
        apply(hint: ic.sessionCursorHint)
    }

    /// Core cursor-update logic.
    ///
    /// `hint` is always the authoritative, non-stale value — either the value
    /// emitted by the Combine publisher (willSet, before assignment) or the live
    /// property value read synchronously on the main thread.
    ///
    /// No access to `ic.sessionCursorHint` here: the caller is responsible for
    /// supplying the correct value. This prevents the stale-read bug where a
    /// deferred sink reads `.none` because begin + commit both fired before delivery.
    ///
    /// Modifier-key state is taken from `cachedModifiers` (populated by
    /// `flagMonitor`) so that the cursor reflects the exact modifier state at the
    /// moment the hint or key event arrived, not at render time.
    private func apply(hint: SessionCursorHint) {
        if hint != .none {
            acquireOwnership(hint: hint)
        } else {
            releaseOwnership()
        }
    }

    /// Acquire cursor ownership for the given session hint.
    ///
    /// `disableCursorRects()` is called **only on the `.idle → .session` transition**
    /// (signalled by `reducer.acquireIfNeeded()` returning `true`). Subsequent calls
    /// during the same session (e.g. modifier changes) skip the AppKit call and
    /// only update the cursor image via `NSCursor.set()`.
    private func acquireOwnership(hint: SessionCursorHint) {
        let cursor = CursorPolicy.cursor(hint: hint, modifiers: cachedModifiers)
        if reducer.acquireIfNeeded() {
            // Ownership transition: suppress view-layer cursor rects once.
            NSApp.keyWindow?.disableCursorRects()
        }
        // Always push the cursor — modifier may have changed within the same session.
        cursor.set()
    }

    /// Release cursor ownership.
    ///
    /// `enableCursorRects()` + `resetCursorRects()` are called **only on the
    /// `.session → .idle` transition**. Safe to call redundantly (idempotent).
    private func releaseOwnership() {
        guard reducer.releaseIfNeeded() else { return }
        restoreViewLayerCursors(for: NSApp.keyWindow)
    }

    /// Re-enable cursor rects on the given window and reset to arrow baseline.
    ///
    /// `resetCursorRects()` triggers every registered NSView's `resetCursorRects`
    /// override — including `HandleNSView` and `StretchCursorNSView`. AppKit then
    /// immediately re-evaluates which cursor to show based on the current mouse
    /// position, so the correct hover cursor is restored even if the pointer is
    /// already inside a hover zone when the session ends.
    private func restoreViewLayerCursors(for window: NSWindow?) {
        window?.enableCursorRects()
        window?.resetCursorRects()
        NSCursor.arrow.set()
    }

    // MARK: - Focus event handlers

    /// Called when any window resigns key status.
    ///
    /// Uses the notification's `object` (the specific resigning window) rather
    /// than `NSApp.keyWindow`, because the key-window pointer may already point
    /// to the newly-focused window by the time this notification fires.
    private func handleFocusLost(window: NSWindow?) {
        guard reducer.releaseIfNeeded() else { return }
        // Re-enable cursor rects on the specific window that lost focus,
        // so they are operational when it regains key status.
        window?.enableCursorRects()
        // Arrow as baseline — no window required for NSCursor.set().
        NSCursor.arrow.set()
    }

    /// Called when any window becomes key.
    ///
    /// Refreshes the modifier cache (may be stale after background period) and
    /// re-applies the current cursor. If a session is still active (e.g. the user
    /// Cmd-Tabbed and returned during a slow drag), ownership is re-acquired.
    private func handleFocusGained() {
        cachedModifiers = NSEvent.modifierFlags
        apply()
    }
}
