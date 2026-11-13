import Foundation
import Combine      // ObservableObject, @Published — no transitive import in Xcode 26
import CoreGraphics

// MARK: - ViewportController

/// Single legitimate scroll-write authority for the horizontal viewport.
///
/// **Arch-Slice-6 — Scroll-Bridge centralization:**
/// All horizontal scroll mutations — from interaction code, the trackpad monitor,
/// and the NSScrollView bridge — must flow through this controller.
/// No code outside this class may write `scrollState.hScrollOffset` directly.
///
/// **Three write paths (all owned here):**
///   1. `scroll(by:)`            — edge-scroll during active sessions (handle, rubber-band, …)
///   2. `scrollTrackpad(delta:)` — two-finger trackpad / scroll wheel (MainView NSEvent monitor)
///   3. `syncFromScrollbar(_:)`  — NSScrollView thumb drag (NativeHScrollbar bridge)
///
/// **Upper-bound clamping (`maxScrollOffset`):**
/// Defaults to `.greatestFiniteMagnitude` (effectively unclamped) until the first lane
/// geometry report arrives. All write paths clamp to `[0, maxScrollOffset]`.
/// G01/G01-R1: the effective bound is `LaneGeometry.maxOffset(contentExtent(topology, WIDTH) − laneViewport)`
/// (`effectiveMaxOffset`): topology and viewport come from the rendered lanes (`reportLane…`), WIDTH is the
/// controller's own `stepWidth`. One bound for trackpad, edge-scroll, scrollbar sync, zoom compensation and
/// resize clamping; `maxScrollOffset` only mirrors it (and is the fallback before the first measurement).
///
/// **Session lifecycle:**
/// `beginSession()` / `endSession()` inform the rest of the system that an interaction
/// session is in progress. `syncFromScrollbar` is suppressed while a session is active
/// to prevent the NSScrollView bridge from writing stale positions during handle drag.
///
/// **Re-entrancy guard (`isSyncingScrollbar`):**
/// Prevents the NSScrollView bridge from creating an update loop:
///   VC offset change → `updateNSView` scrolls NSScrollView → `boundsChanged` fires →
///   `syncFromScrollbar` sees `isSyncingScrollbar == true` → returns early.
/// `NativeHScrollbar.updateNSView` sets this flag around the outward scroll.
/// Internal (not private) so that `NativeHScrollbar` (same module) can access it.
///
/// **Thread safety:** Must be called on the main thread.
final class ViewportController: ObservableObject {

    // MARK: - Published state

    /// True while any interaction session has the viewport locked.
    /// Views and the scrollbar bridge read `scrollState.isAnyHandleDragging`
    /// for the same information — both are kept in sync via `beginSession/endSession`.
    private(set) var sessionActive: Bool = false

    // MARK: - Scroll bounds

    /// Upper bound for `hScrollOffset`.
    ///
    /// All three write paths clamp to `[0, maxScrollOffset]`.
    /// Defaults to `.greatestFiniteMagnitude` — effectively unclamped.
    /// Set only by `applyLaneMetrics` (G01), from the geometry the rendered lanes report.
    var maxScrollOffset: CGFloat = .greatestFiniteMagnitude

    // MARK: - Lane geometry (G01 / G01-R1)

    /// Last applied lane geometry: viewport start/width and the distinct lane topologies. Published, but it
    /// changes only when the layout geometry changes (resize, ratio, step count, structure) — never during
    /// scroll, zoom or playback. It carries NO width-dependent value, so a late measurement can never belong to
    /// an older WIDTH than the controller's current one.
    @Published private(set) var laneMetrics = LaneMetrics()

    /// Effective step width (WIDTH) the scroll bound is computed for. Set by `MainView` from the committed
    /// `StepWidthState.size` (`setStepWidth`) and ahead of the commit by `adjustScroll` inside the pinch handler
    /// (same call stack as the commit, so no view update can interleave). nil until first known.
    private(set) var stepWidth: Double?

    #if DEBUG
    /// DEBUG-Testnaht (G01): Anzahl der Meldungen.
    private(set) var _g01ReportCount = 0
    #endif

    private var pendingLaneMetrics = LaneMetrics()
    private var laneFlushScheduled = false

    /// Entry points for the lanes' preference callbacks. They run during view updates, therefore they
    /// never write published state synchronously: the newest values are merged into `pendingLaneMetrics`
    /// and applied once on the next main-queue turn. Superseded reports are overwritten, so a stale
    /// measurement cannot be applied afterwards.
    func reportLaneViewport(_ viewport: LaneViewport?) {
        guard let v = viewport, v.isValid else { return }
        pendingLaneMetrics.viewportMinX  = v.minX
        pendingLaneMetrics.viewportWidth = v.width
        scheduleLaneFlush()
    }

    func reportLaneShapes(_ shapes: [LaneShape]) {
        pendingLaneMetrics.shapes = shapes
        scheduleLaneFlush()
    }

    private func scheduleLaneFlush() {
        #if DEBUG
        _g01ReportCount += 1
        #endif
        guard !laneFlushScheduled else { return }
        laneFlushScheduled = true
        DispatchQueue.main.async { [weak self] in self?.flushLaneMetrics() }
    }

    /// Applies the merged pending report (internal for tests).
    func flushLaneMetrics() {
        laneFlushScheduled = false
        applyLaneMetrics(pendingLaneMetrics)
    }

    /// Takes new viewport/topology and re-clamps an offset that became invalid (resize, ratio, step count,
    /// structure). An unmeasured viewport (width 0) leaves everything unchanged.
    func applyLaneMetrics(_ m: LaneMetrics) {
        guard m.hasViewport else { return }
        if m != laneMetrics { laneMetrics = m }
        refreshBoundAndClamp()
    }

    /// Records the committed WIDTH (idempotent) and re-clamps the offset to the bound of that width.
    func setStepWidth(_ width: Double) {
        guard width.isFinite, width > 0, stepWidth != width else { return }
        stepWidth = width
        refreshBoundAndClamp()
    }

    /// The one effective upper bound of the CURRENT state for all offset writers:
    /// `max(0, contentExtent(topology, WIDTH) − viewport)`. Until viewport and WIDTH are known, the
    /// legacy `maxScrollOffset` (default: unclamped) applies.
    var effectiveMaxOffset: CGFloat { effectiveMaxOffset(forStepWidth: stepWidth) }

    /// Same bound for an explicit WIDTH (used by zoom compensation for the width it is about to commit).
    func effectiveMaxOffset(forStepWidth width: Double?) -> CGFloat {
        guard laneMetrics.hasViewport, let width else { return maxScrollOffset }
        return LaneGeometry.maxOffset(contentExtent: laneMetrics.contentExtent(at: width),
                                      viewportWidth: laneMetrics.viewportWidth)
    }

    private func refreshBoundAndClamp() {
        let bound = effectiveMaxOffset
        guard laneMetrics.hasViewport, stepWidth != nil else { return }
        maxScrollOffset = bound
        let clamped = LaneGeometry.clamp(scrollState.hScrollOffset, max: bound)
        if abs(clamped - scrollState.hScrollOffset) > 0.01 { scrollState.hScrollOffset = clamped }
    }

    // MARK: - Scrollbar sync re-entrancy guard

    /// True while `NativeHScrollbar.updateNSView` is pushing a position outward
    /// into the NSScrollView (VC → NSScrollView direction).
    ///
    /// Prevents the `boundsDidChange` notification that `scroll(to:)` generates from
    /// triggering a `syncFromScrollbar` write-back and creating an infinite loop.
    ///
    /// **Access:** Internal (not private) — readable and writable by `NativeHScrollbar`
    /// (private struct inside MainView.swift, same module `VintageSequencer`).
    var isSyncingScrollbar: Bool = false

    // MARK: - Internal

    /// The scroll state this controller manages.
    ///
    /// Internal — `InteractionController` subscribes to `scrollState.$hScrollOffset`
    /// via Combine for rubber-band auto-scroll recomputation (Arch-Slice-3).
    let scrollState: ScrollState

    // MARK: - Init

    init(scrollState: ScrollState) {
        self.scrollState = scrollState
    }

    // MARK: - Session lifecycle

    /// Lock the viewport for an active interaction session.
    /// Idempotent — calling while already active is a no-op.
    func beginSession() {
        guard !sessionActive else { return }
        sessionActive = true
        scrollState.isAnyHandleDragging = true
    }

    /// Release the viewport after a session ends.
    /// Idempotent — calling while inactive is a no-op.
    func endSession() {
        guard sessionActive else { return }
        sessionActive = false
        scrollState.isAnyHandleDragging = false
    }

    // MARK: - Scroll write API

    /// Apply a scroll delta from interaction code (edge-scroll during sessions).
    ///
    /// Clamps to `[0, maxScrollOffset]`.
    /// This is the write path for handle drag, rubber-band, and pitch-drag edge-scroll.
    func scroll(by delta: CGFloat) {
        let newOffset = max(0, min(effectiveMaxOffset, scrollState.hScrollOffset + delta))
        scrollState.hScrollOffset = newOffset
    }

    /// Apply a two-finger trackpad / scroll-wheel delta from the NSEvent monitor.
    ///
    /// `delta` is `NSEvent.scrollingDeltaX` as-is. The formula `offset − delta`
    /// matches macOS scroll convention. Clamps to `[0, maxScrollOffset]`.
    ///
    /// - Parameter delta: Raw `scrollingDeltaX` from the NSEvent.
    func scrollTrackpad(delta: CGFloat) {
        let newOffset = max(0, min(effectiveMaxOffset, scrollState.hScrollOffset - delta))
        scrollState.hScrollOffset = newOffset
    }

    /// Sync the scroll position from the NSScrollView bridge (user drags scrollbar thumb).
    ///
    /// **Session guard:** No-op while any interaction session is active —
    /// prevents the bridge from writing stale positions during handle drag.
    ///
    /// **Re-entrancy guard:** No-op while `isSyncingScrollbar` is true —
    /// prevents the outward `updateNSView` direction from triggering a write-back loop.
    ///
    /// Clamps to `[0, maxScrollOffset]`.
    func syncFromScrollbar(_ offset: CGFloat) {
        guard !isSyncingScrollbar, !sessionActive else { return }
        let clamped = max(0, min(effectiveMaxOffset, offset))
        // Equality-Check: verhindert spurious objectWillChange-Fires wenn der
        // NSScrollView nach einem programmatischen Scroll die gleiche Position meldet.
        guard abs(clamped - scrollState.hScrollOffset) > 0.5 else { return }
        isSyncingScrollbar = true
        scrollState.hScrollOffset = clamped
        isSyncingScrollbar = false
    }

    // MARK: - Zoom (Arch-Slice-9)

    /// Current zoom scale — 1.0 = base (54 px/step), updated by `adjustScroll`.
    ///
    /// Published so the debug panel and any view that wants to observe zoom level
    /// can react. IC.updatePinchZoom is the only write path.
    private(set) var zoomScale: CGFloat = 1.0

    /// Adjust the scroll offset to keep the content at `anchorX` (screen space) fixed
    /// while the step width changes from `oldStepWidth` to `newStepWidth`.
    ///
    /// **Formula (anchor-stable zoom, Padding-korrigiert):**
    ///
    /// Herleitung: `scaleEffect(x: m, anchor: A)` transformiert jeden Punkt `x` zu
    /// `A + (x − A) × m`. Step i hat Container-Position `P − S + slot × i`, wobei
    /// `P` = stepGridLeadingPad (8px), `S` = hScrollOffset, `slot` = stepWidth + spacing.
    ///
    /// Damit der Commit-Zustand (neues Layout) exakt dem scaleEffect entspricht:
    ///   `S' = m × S + (m − 1) × (A − P)`
    ///
    /// Umgeschrieben mit `ratio = newSlot / oldSlot`:
    ///   `contentX = (anchorX − P) + scrollOffset`
    ///   `newOffset = contentX × ratio + P − anchorX`
    ///
    /// Also updates `zoomScale` (= newStepWidth / 54).
    ///
    /// - Parameters:
    ///   - oldStepWidth: Step width before this update (px).
    ///   - newStepWidth: Step width after this update (px).
    ///   - anchorX:      Screen-space X that stays fixed during zoom (typically pinch center).
    func adjustScroll(oldStepWidth: CGFloat, newStepWidth: CGFloat, anchorX: CGFloat) {
        guard oldStepWidth > 0, newStepWidth != oldStepWidth else { return }
        let spacing   = VintageTheme.stepSpacing
        let P         = VintageTheme.stepGridLeadingPad
        let ratio     = (newStepWidth + spacing) / (oldStepWidth + spacing)
        let contentX  = (anchorX - P) + scrollState.hScrollOffset
        let newOffset = contentX * ratio + P - anchorX
        // Bound for the NEW width, computed exactly from topology + the width that is about to be committed
        // (`StepWidthState` receives `committed.rounded()`). Never scaled from an earlier measurement, so any
        // number of updates before the next preference delivery stays exact.
        let committedWidth = Double(newStepWidth.rounded())
        let bound = effectiveMaxOffset(forStepWidth: committedWidth)
        stepWidth = committedWidth
        if laneMetrics.hasViewport { maxScrollOffset = bound }
        scrollState.hScrollOffset = LaneGeometry.clamp(newOffset, max: bound)
        zoomScale = newStepWidth / 54.0   // 54 px = standard base step width
    }
}
