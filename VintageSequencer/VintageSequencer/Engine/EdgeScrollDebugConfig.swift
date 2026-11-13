#if DEBUG
import Foundation
import CoreGraphics
import Combine

// MARK: - EdgeScrollDebugConfig

/// Debug-only singleton configuration for live `EdgeScrollVelocity` parameter tuning.
///
/// **Only exists in `#if DEBUG` builds — zero footprint in RELEASE.**
///
/// **Architecture:**
///   - `InteractionController.edgeScrollTick()` reads this config (via `#if DEBUG` guard)
///     to pass live zone/velocity parameters to `EdgeScrollVelocity.velocity(...)`.
///   - `HandleNSView.updateEdgeScrollVelocity()` reads this config for its own calls.
///   - `EdgeScrollDebugPanel` writes to this singleton via SwiftUI `@ObservedObject`.
///   - No production data flow passes through this object.
///
/// **Live readback fields** (`livePointerX`, `liveVelocity`, `liveViewWidth`)
/// are written by `InteractionController.edgeScrollTick()` on every timer tick
/// and displayed in `EdgeScrollDebugPanel`.
final class EdgeScrollDebugConfig: ObservableObject {

    // MARK: - Singleton

    static let shared = EdgeScrollDebugConfig()
    private init() {}

    // MARK: - Tunable parameters

    /// Distance from the LEFT viewport edge (past `leftInset`) where the scroll ramp begins (px).
    @Published var leftZoneWidth:  CGFloat = EdgeScrollVelocity.defaultZoneWidth

    /// Distance from the RIGHT viewport edge (past `rightInset`) where the scroll ramp begins (px).
    @Published var rightZoneWidth: CGFloat = EdgeScrollVelocity.defaultZoneWidth

    /// Maximum scroll speed at the viewport edge (px/frame @ 60 Hz).
    @Published var maxVelocity:    CGFloat = EdgeScrollVelocity.defaultMaxVelocity

    /// Left grid inset — wired into `EdgeScrollVelocity.velocity(leftInset:)`.
    /// Scroll activation is suppressed for pointer positions within this left margin.
    @Published var leftInset:      CGFloat = EdgeScrollVelocity.defaultLeftInset

    /// Right grid inset — wired into `EdgeScrollVelocity.velocity(rightInset:)`.
    /// Scroll activation is suppressed for pointer positions within this right margin.
    @Published var rightInset:     CGFloat = EdgeScrollVelocity.defaultRightInset

    // MARK: - Zoom parameters (Teil B)

    /// Minimum allowed zoom scale (base = 1.0).
    @Published var minZoomScale:    CGFloat = 0.5

    /// Maximum allowed zoom scale (base = 1.0).
    @Published var maxZoomScale:    CGFloat = 4.0

    /// Sensitivity multiplier applied to raw pinch magnification deltas.
    @Published var zoomSensitivity: CGFloat = 1.0

    // MARK: - Live readback (written by IC.edgeScrollTick)

    /// Most recent pointer X reported to the IC edge-scroll timer.
    @Published var livePointerX:  CGFloat = 0

    /// Computed velocity from the last IC edge-scroll tick.
    @Published var liveVelocity:  CGFloat = 0

    /// Viewport width seen by the last IC edge-scroll tick.
    @Published var liveViewWidth: CGFloat = 0

    // MARK: - Zoom live readback (written by IC.updatePinchZoom)

    /// Current zoom scale as last applied by the pinch handler.
    @Published var liveZoomScale:    CGFloat = 1.0

    /// Current horizontal scroll offset as last observed during zoom.
    @Published var liveScrollOffset: CGFloat = 0
}
#endif
