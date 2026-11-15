import SwiftUI
import AppKit

// MARK: - CornerDotHandle + HandleNSView
// Extracted from TrackRowView.swift — E2.4

/// SwiftUI-Wrapper um `HandleNSView`.
struct CornerDotHandle: NSViewRepresentable {
    var color:         Color = .white
    var dotAtTop:      Bool  = false
    var onStart:       () -> Void
    var onDrag:        (_ totalTranslationX: CGFloat) -> Void
    var onEnd:         () -> Void
    /// Called with a scroll velocity (px/frame) while cursor is in the edge zone;
    /// called with 0 on drag end.
    var onEdgeScroll:  ((_ velocity: CGFloat) -> Void)? = nil

    func makeNSView(context: Context) -> HandleNSView {
        let v = HandleNSView()
        v.dotColor     = NSColor(color)
        v.dotAtTop     = dotAtTop
        v.onStart      = onStart
        v.onDrag       = onDrag
        v.onEnd        = onEnd
        v.onEdgeScroll = onEdgeScroll
        return v
    }

    func updateNSView(_ nsView: HandleNSView, context: Context) {
        nsView.dotColor     = NSColor(color)
        nsView.dotAtTop     = dotAtTop
        nsView.onStart      = onStart
        nsView.onDrag       = onDrag
        nsView.onEnd        = onEnd
        nsView.onEdgeScroll = onEdgeScroll
    }
}

// MARK: - HandleNSView

final class HandleNSView: NSView {
    // Neu zeichnen bei Änderung (v1.18.25): sonst blieb nach einer Farbwahl die alte Farbe.
    var dotColor:     NSColor = .white { didSet { if dotColor != oldValue { needsDisplay = true } } }
    var dotAtTop:     Bool    = false  { didSet { if dotAtTop != oldValue { needsDisplay = true } } }
    var onStart:      (() -> Void)?
    var onDrag:       ((_ totalTranslationX: CGFloat) -> Void)?
    var onEnd:        (() -> Void)?
    var onEdgeScroll: ((_ velocity: CGFloat) -> Void)?

    // ── Drag state ───────────────────────────────────────────────────────
    /// Window-x at mouseDown — never modified during the drag.
    private var dragStartX:    CGFloat = 0
    private var edgeScrollVel: CGFloat = 0
    private var dragMonitor:   Any?
    private var edgeScrollTimer: Timer?

    // Session guard (Fix C):
    // Set true in mouseDown, false as the FIRST thing in leftMouseUp.
    // Every DispatchQueue.main.async block checks this before running,
    // so no pending onDrag or edge-scroll dispatch can fire after mouseUp.
    private var dragActive: Bool = false

    // onDrag coalescing — one pending dispatch at a time.
    private var pendingTotalX:       CGFloat = 0
    private var dragUpdateScheduled: Bool    = false

    // Edge-scroll coalescing (Fix D) — one pending dispatch at a time.
    private var pendingEdgeVel:       CGFloat = 0
    private var edgeScrollScheduled:  Bool    = false

    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let ta = NSTrackingArea(rect: .zero,
                                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
    }
    required init?(coder: NSCoder) { fatalError() }

    // ── Drawing ──────────────────────────────────────────────────────────
    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isHovered ? 1.0 : 0.5
        dotColor.withAlphaComponent(alpha).setFill()
        let r: CGFloat = 3
        let cx = bounds.midX
        let cy: CGFloat = dotAtTop ? bounds.maxY - r - 1 : bounds.minY + r + 1
        NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r*2, height: r*2)).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true  }
    override func mouseExited(with event: NSEvent)  { isHovered = false }

    // ── Drag ─────────────────────────────────────────────────────────────
    override func mouseDown(with event: NSEvent) {
        dragActive           = true          // session guard: opened here
        dragStartX           = event.locationInWindow.x
        pendingTotalX        = 0
        dragUpdateScheduled  = false
        pendingEdgeVel       = 0
        edgeScrollScheduled  = false
        onStart?()
#if DEBUG
        HandleDebugLogger.shared.logDragStart()
#endif

        dragMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) { [weak self] evt in
            guard let self else { return evt }
            switch evt.type {

            case .leftMouseDragged:
                // ── Modell-Update (einziger onDrag-Pfad, coalesced) ────────
                // pendingTotalX immer auf neuesten Wert setzen.
                // Ist noch kein Dispatch ausstehend, genau einen starten.
                // Mehrere schnelle Events überschreiben pendingTotalX —
                // beim Ausführen wird nur der letzte Wert verarbeitet.
                self.pendingTotalX = evt.locationInWindow.x - self.dragStartX
                if !self.dragUpdateScheduled {
                    self.dragUpdateScheduled = true
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.dragActive else { return }  // Fix C
                        let tx = self.pendingTotalX
#if DEBUG
                        HandleDebugLogger.shared.logOnDrag(totalX: tx)
#endif
                        self.onDrag?(tx)
                        self.dragUpdateScheduled = false
                    }
                }
                // ── Edge-Scroll-Erkennung ─────────────────────────────────
                // Nur Geschwindigkeit setzen — der Timer kümmert sich um den Offset.
                self.updateEdgeScrollVelocity(mouseX: evt.locationInWindow.x)

            case .leftMouseUp:
                // Fix C: close the session FIRST.
                // Any DispatchQueue.main.async blocks queued by the drag handler
                // or edge-scroll timer will find dragActive == false and return
                // immediately — BEFORE onEnd clears the snapshots.
                self.dragActive = false
                self.stopEdgeScrollTimer()
                self.onEdgeScroll?(0)
                self.onEnd?()
#if DEBUG
                HandleDebugLogger.shared.logDragEnd()
#endif
                if let m = self.dragMonitor {
                    NSEvent.removeMonitor(m)
                    self.dragMonitor = nil
                }

            default: break
            }
            return evt
        }
    }

    // ── Edge-Scroll ───────────────────────────────────────────────────────
    /// Computes edge-scroll velocity from the current mouse X position.
    ///
    /// In DEBUG builds, reads zone/velocity parameters from `EdgeScrollDebugConfig.shared`
    /// so the debug panel can tune them live. In RELEASE builds, uses the default constants.
    private func updateEdgeScrollVelocity(mouseX: CGFloat) {
        guard let winW = window?.contentView?.bounds.width else {
            edgeScrollVel = 0
            stopEdgeScrollTimer()
            return
        }
        // Fensterkoordinaten: links liegt der feste Spurkopf, rechts der Rand neben der Lane.
        // Beide sind kein Scrollbereich und gehen als Inset ein (v1.12.23).
        let headerInset = VintageTheme.trackHeaderWidth + 1
        let trailingInset: CGFloat = 40
#if DEBUG
        let cfg = EdgeScrollDebugConfig.shared
        let vel = EdgeScrollVelocity.velocity(
            pointerX:       mouseX,
            viewWidth:      winW,
            leftZoneWidth:  cfg.leftZoneWidth,
            rightZoneWidth: cfg.rightZoneWidth,
            leftInset:      headerInset + cfg.leftInset,
            rightInset:     trailingInset + cfg.rightInset,
            maxVelocity:    cfg.maxVelocity
        )
#else
        let vel = EdgeScrollVelocity.velocity(pointerX: mouseX, viewWidth: winW,
                                              leftInset: headerInset, rightInset: trailingInset)
#endif
        if abs(vel) > 0.5 {
            edgeScrollVel = vel
            startEdgeScrollTimer()
        } else {
            edgeScrollVel = 0
            stopEdgeScrollTimer()
        }
    }

    /// Timer-Callback: Scroll **und** nachgeführtes Drag-Update.
    ///
    /// **Warum onDrag hier?**
    /// Wenn der Pointer am Bildrand stehen bleibt (Edge-Zone erreicht), feuern
    /// keine neuen `leftMouseDragged`-Events mehr — `onDrag` wird also nicht
    /// erneut aufgerufen. Der Auto-Scroll verschiebt den Viewport trotzdem weiter,
    /// aber das Modell (stepCount / ratio) friert ein, weil der
    /// `contentDisplacement`-Wert (translationX + Δscroll) nie neu berechnet wird.
    ///
    /// Fix: Nach jedem Scroll-Tick den Drag mit dem letzten bekannten `pendingTotalX`
    /// nochmals auswerten. Da IC.updateHandleDrag / updateRatioDrag idempotent sind
    /// (`guard proposed != current else { return }`), sind doppelte Aufrufe harmlos.
    /// Die Reihenfolge ist kritisch: **erst scrollen, dann Modell aktualisieren** —
    /// so liest das IC-Update den bereits geänderten `hScrollOffset`.
    ///
    /// Fix D — Coalescing: pendingEdgeVel wird bei jedem Tick überschrieben.
    /// Ist kein Dispatch ausstehend, wird genau einer gestartet.
    private func startEdgeScrollTimer() {
        guard edgeScrollTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self, self.edgeScrollVel != 0 else { return }
            self.pendingEdgeVel = self.edgeScrollVel
            guard !self.edgeScrollScheduled else { return }
            self.edgeScrollScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.dragActive else {   // Fix C
                    self?.edgeScrollScheduled = false
                    return
                }
                // 1. Scroll the viewport (via IC.applyEdgeScroll → VC.scroll).
                self.onEdgeScroll?(self.pendingEdgeVel)
                // 2. Re-apply drag model update with the now-updated scroll offset.
                //    Pointer may be stationary, but scroll changed → model must follow.
                self.onDrag?(self.pendingTotalX)
                self.edgeScrollScheduled = false
            }
        }
        RunLoop.main.add(t, forMode: .common)
        edgeScrollTimer = t
    }

    private func stopEdgeScrollTimer() {
        edgeScrollTimer?.invalidate()
        edgeScrollTimer   = nil
        edgeScrollVel     = 0
        pendingEdgeVel    = 0
        edgeScrollScheduled = false
    }

    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    override var intrinsicContentSize: NSSize { NSSize(width: 10, height: 10) }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
