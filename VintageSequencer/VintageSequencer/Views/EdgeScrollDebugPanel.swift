#if DEBUG
import SwiftUI

// MARK: - EdgeScrollDebugPanel

/// Debug-only HUD for live `EdgeScrollVelocity` parameter tuning and zoom inspection.
///
/// **Only compiled in `#if DEBUG` builds — zero footprint in RELEASE.**
///
/// Reads from and writes to `EdgeScrollDebugConfig.shared`. Does NOT
/// directly call any scroll logic — the config singleton is the only
/// bridge to production code.
///
/// Placed as a `.overlay(alignment: .topTrailing)` in `MainView`.
struct EdgeScrollDebugPanel: View {

    @ObservedObject private var cfg = EdgeScrollDebugConfig.shared
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {

            // ── Toggle button ────────────────────────────────────────────
            Button(action: { isExpanded.toggle() }) {
                Text(isExpanded ? "▾ Debug" : "▸ Debug")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.yellow)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.fullArea)
            .background(Color.black.opacity(0.75))

            // ── Expanded panel ───────────────────────────────────────────
            if isExpanded {
                VStack(alignment: .leading, spacing: 5) {

                    // Parameters
                    Group {
                        sliderRow("L Zone",  value: $cfg.leftZoneWidth,  range: 10...500)
                        sliderRow("R Zone",  value: $cfg.rightZoneWidth, range: 10...500)
                        sliderRow("Max V",   value: $cfg.maxVelocity,    range: 1...60)
                        sliderRow("L Inset", value: $cfg.leftInset,      range: 0...300)
                        sliderRow("R Inset", value: $cfg.rightInset,     range: 0...300)
                    }

                    Divider()
                        .background(Color.white.opacity(0.25))
                        .padding(.vertical, 2)

                    // Live readback
                    Group {
                        liveRow("Pointer X",  cfg.livePointerX,  format: "%.0f")
                        liveRow("View W",     cfg.liveViewWidth,  format: "%.0f")
                        liveRow("Velocity",   cfg.liveVelocity,   format: "%.2f")
                    }

                    Divider()
                        .background(Color.white.opacity(0.25))
                        .padding(.vertical, 2)

                    // Computed: effective non-scroll zone
                    let effLeft  = cfg.leftInset  + cfg.leftZoneWidth
                    let effRight = cfg.liveViewWidth - cfg.rightInset - cfg.rightZoneWidth
                    Group {
                        liveRow("Dead L",  effLeft,  format: "%.0f")
                        liveRow("Dead R",  effRight, format: "%.0f")
                    }

                    Divider()
                        .background(Color.white.opacity(0.25))
                        .padding(.vertical, 2)

                    // ZOOM section
                    Group {
                        sliderRow("Min Z",  value: $cfg.minZoomScale,    range: 0.1...1.0, format: "%.2f")
                        sliderRow("Max Z",  value: $cfg.maxZoomScale,    range: 1.0...8.0, format: "%.2f")
                        sliderRow("Z Sens", value: $cfg.zoomSensitivity, range: 0.1...3.0, format: "%.2f")
                        liveRow("Zoom",   cfg.liveZoomScale,    format: "%.3f")
                        liveRow("Scroll", cfg.liveScrollOffset, format: "%.0f")
                    }

                    // Reset button
                    Button("Reset") {
                        cfg.leftZoneWidth  = EdgeScrollVelocity.defaultZoneWidth
                        cfg.rightZoneWidth = EdgeScrollVelocity.defaultZoneWidth
                        cfg.maxVelocity    = EdgeScrollVelocity.defaultMaxVelocity
                        cfg.leftInset      = EdgeScrollVelocity.defaultLeftInset
                        cfg.rightInset     = EdgeScrollVelocity.defaultRightInset
                        cfg.minZoomScale    = 0.5
                        cfg.maxZoomScale    = 4.0
                        cfg.zoomSensitivity = 1.0
                    }
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.orange)
                    .buttonStyle(.fullArea)
                    .padding(.top, 3)
                }
                .padding(8)
                .background(Color.black.opacity(0.85))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white)
            }
        }
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.yellow.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sliderRow(_ label: String,
                            value: Binding<CGFloat>,
                            range: ClosedRange<CGFloat>,
                            format: String = "%.0f") -> some View {
        HStack(spacing: 4) {
            Text(label)
                .frame(width: 48, alignment: .leading)
                .foregroundColor(.gray)
            Slider(value: value, in: range)
                .frame(width: 110)
            Text(String(format: format, value.wrappedValue))
                .frame(width: 28, alignment: .trailing)
                .foregroundColor(.white)
        }
    }

    @ViewBuilder
    private func liveRow(_ label: String, _ val: CGFloat, format: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .frame(width: 60, alignment: .leading)
                .foregroundColor(.gray)
            Text(String(format: format, val))
                .foregroundColor(.green)
        }
    }
}
#endif
