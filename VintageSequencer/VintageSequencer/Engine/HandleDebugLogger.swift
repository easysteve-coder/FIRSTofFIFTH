#if DEBUG
import Combine
import Foundation
import CoreGraphics

// MARK: - HandleDebugLogger
//
// Lightweight event sink for the handle-drag / scroll path.
// Only compiled in DEBUG builds.
//
// Call sites reach it via the singleton `HandleDebugLogger.shared`.
// Remove `#if DEBUG` guards at every call site to disable.
//
// Thread safety: all @Published mutations are dispatched
// to the next main-runloop iteration so they never fire
// inside a SwiftUI view-update pass.

final class HandleDebugLogger: ObservableObject {
    static let shared = HandleDebugLogger()
    private init() {}

    // MARK: — Live state (read by HandleDebugOverlayView)

    @Published private(set) var currentTotalX:       CGFloat = 0
    @Published private(set) var currentStepCount:    Int     = 0
    @Published private(set) var currentOffset:       CGFloat = 0
    @Published private(set) var isEdgeScrollActive:  Bool    = false
    @Published private(set) var isDragging:          Bool    = false

    // Newest-first, capped at maxLines.
    @Published private(set) var lines: [String] = []
    private let maxLines = 80

    // MARK: — Internal

    private var dragSeq = 0   // incremented per coalesced onDrag call

    // MARK: — Logging API

    /// Handle drag has started (mouseDown).
    func logDragStart() {
        dragSeq = 0
        let line = stamp("▶ START")
        defer_mut { s in s.isDragging = true; s.push(line) }
    }

    /// Handle drag has ended (mouseUp).
    func logDragEnd() {
        let line = stamp("■ END")
        defer_mut { s in s.isDragging = false; s.push(line) }
    }

    /// Called once per coalesced onDrag dispatch.
    /// - Parameter totalX: accumulated translation since drag start.
    func logOnDrag(totalX: CGFloat) {
        dragSeq += 1
        let seq  = dragSeq
        let tx   = totalX
        let line = stamp(String(format: "#%d onDrag  totalX=%+.1f", seq, tx))
        defer_mut { s in s.currentTotalX = tx; s.push(line) }
    }

    /// Called after every track.stepCount assignment.
    func logStepCount(old: Int, new: Int) {
        let n    = new
        let line = stamp("◆ stepCount  \(old) → \(new)")
        defer_mut { s in s.currentStepCount = n; s.push(line) }
    }

    /// Called wherever hScrollOffset changes.
    /// - Parameter source: "edgeScroll" | "trackpad" | "scrollbar"
    func logScrollChange(old: CGFloat, new: CGFloat, source: String) {
        guard abs(old - new) > 0.01 else { return }
        let n    = new
        let line = stamp(String(format: "⟳ scroll[%@]  %.1f→%.1f  Δ%+.1f",
                                 source, old, new, new - old))
        defer_mut { s in s.currentOffset = n; s.push(line) }
    }

    /// Called every time the edge-scroll timer fires in HandleNSView.
    func logEdgeScroll(velocity: CGFloat) {
        let active = velocity != 0
        let line   = active
            ? stamp(String(format: "⤏ edgeScroll  vel=%+.1f", velocity))
            : nil
        defer_mut { s in
            s.isEdgeScrollActive = active
            if let l = line { s.push(l) }
        }
    }

    /// Called from StepGridView.onChange(of: hScrollOffset).
    /// - Parameter blocked: true when isHandleDragging suppressed the callback.
    func logOnChange(old: CGFloat, new: CGFloat, blocked: Bool) {
        let tag  = blocked ? "BLOCKED" : "pass"
        let line = stamp(String(format: "Δ onChange  %.1f→%.1f  [%@]", old, new, tag))
        defer_mut { s in s.push(line) }
    }

    // MARK: — Private helpers

    /// Build a timestamped log line and print it immediately to the console.
    /// Console output is synchronous; overlay update is deferred.
    private func stamp(_ msg: String) -> String {
        let ts   = String(format: "%.3f",
                          Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
        let line = "[\(ts)] \(msg)"
        print("[HDbg] \(line)")
        return line
    }

    /// Defers @Published mutations to the next runloop iteration,
    /// avoiding "Publishing changes from within view updates" warnings.
    private func defer_mut(_ mutation: @escaping (HandleDebugLogger) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            mutation(self)
        }
    }

    private func push(_ line: String) {
        lines.insert(line, at: 0)
        if lines.count > maxLines { lines.removeLast() }
    }
}
#endif
