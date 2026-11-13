#if DEBUG
import SwiftUI

// MARK: - HandleDebugOverlayView
//
// Compact floating panel for real-time handle-drag / scroll analysis.
//
// Attach in MainView:
//   .overlay(alignment: .bottomTrailing) { HandleDebugOverlayView() }
//
// Remove the matching #if DEBUG block in MainView to disable.
//
// Color coding:
//   cyan    — drag start / end
//   yellow  — stepCount change
//   orange  — scroll change
//   red     — edge-scroll velocity
//   gray    — onChange BLOCKED by isHandleDragging
//   white   — everything else

struct HandleDebugOverlayView: View {
    @ObservedObject private var log = HandleDebugLogger.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {

            // ── Status bar ──────────────────────────────────────────────
            HStack(spacing: 10) {
                pill("drag",  active: log.isDragging,         color: .green)
                pill("edge",  active: log.isEdgeScrollActive, color: .orange)

                Divider().frame(height: 12)
                    .overlay(Color.white.opacity(0.2))

                kv("totalX",  String(format: "%+.1f", log.currentTotalX))
                kv("steps",   "\(log.currentStepCount)")
                kv("offset",  String(format: "%.1f",  log.currentOffset))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.84))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // ── Event log (newest first, last 14 lines) ─────────────────
            VStack(alignment: .leading, spacing: 1) {
                ForEach(
                    Array(log.lines.prefix(14).enumerated()),
                    id: \.offset
                ) { _, line in
                    Text(line)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(lineColor(line))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(6)
            .frame(width: 370, alignment: .leading)
            .background(Color.black.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: — Helpers

    private func pill(_ label: String, active: Bool, color: Color) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(active ? color : Color.white.opacity(0.15))
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(active ? .white : Color.white.opacity(0.35))
        }
    }

    private func kv(_ key: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 10))
                .foregroundColor(Color.white.opacity(0.4))
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white)
                .monospacedDigit()
        }
    }

    private func lineColor(_ line: String) -> Color {
        if line.contains("▶") || line.contains("■") { return .cyan }
        if line.contains("◆")                        { return .yellow }
        if line.contains("⟳")                        { return .orange }
        if line.contains("⤏")                        { return .red.opacity(0.85) }
        if line.contains("BLOCKED")                   { return Color.white.opacity(0.25) }
        return Color.white.opacity(0.65)
    }
}
#endif
