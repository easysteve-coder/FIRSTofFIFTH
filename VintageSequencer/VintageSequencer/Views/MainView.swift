import SwiftUI
import AppKit

struct MainView: View {
    @EnvironmentObject var engine:             SequencerEngine
    // scrollState entfernt (Scroll-Performance-Fix):
    // @EnvironmentObject var scrollState deklarieren erzeugt eine Combine-Subscription
    // auf scrollState.objectWillChange. Da scrollState.hScrollOffset bei jedem
    // Scroll-Event feuert, lief MainView.body ~20×/s neu → ForEach baute alle
    // TrackRowViews neu → TrackRow + TrackHeader je 80-96/s (Test 3).
    // MainView liest scrollState im Body nicht — die Deklaration war ein reiner
    // Subscription-Leak. DEBUG-Logging nutzt jetzt viewportController.scrollState.
    @EnvironmentObject var viewportController: ViewportController
    @EnvironmentObject private var stepWidthState: StepWidthState
    @Environment(\.undoManager) private var undoManager
    @AppStorage("appLanguage") private var lang: String = "en"
    @AppStorage("showMixer") private var showMixer: Bool = false
    private var s: Str { Str(lang) }
    private let writer = ModelWriter()
    @State private var scrollMonitor: Any?
    @State private var titlebarOverlap: CGFloat = 0
    /// Ziehen von Spuren (v1.17.10). Als @State gehalten, NICHT beobachtet: nur die Blätter
    /// (`TrackDragOffset`, Ziehgriff) lesen es — MainView baut beim Ziehen nicht neu.
    @State private var trackDrag = TrackDragState()

    private func addTrack(kind: LaneKind) {
        engine.addTrackUndoable(kind: kind, actionName: s.undoAddTrack)
    }

    var body: some View {
        VStack(spacing: 0) {

            // ── Transport bar ────────────────────────────────────────────
            TransportView()

            // ── Track grid ───────────────────────────────────────────────
            // Arch-Slice-20: GeometryReader liefert viewWidth für GlobalPinchZoomModifier.
            // Ein globaler Pinch-Handler ersetzt N per-Lane-PinchZoomModifier-Instanzen.
            GeometryReader { geo in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 8) {
                        // Song-Lane über allen Patterns (v1.14.0).
                        SongLaneView(songState: engine.songState)
                        ForEach(
                            Array(engine.currentPattern.tracks.enumerated()),
                            id: \.element.id
                        ) { idx, td in
                            TrackRowView(
                                track:       engine.viewModel(for: td),
                                trackIndex:  idx,
                                onRandomize: { engine.randomize(track: td) },
                                onClear: {
                                    let lane = td.lane
                                    let old = lane.steps
                                    var cleared = lane.steps
                                    for i in 0..<lane.stepCount { cleared[i] = Step() }
                                    writer.apply(.setSteps(trackID: td.id,
                                                           oldSteps: old,
                                                           newSteps: cleared,
                                                           actionName: s.undoClear),
                                                 to: td,
                                                 undoManager: undoManager)
                                },
                                onDelete: engine.currentPattern.tracks.count > 1
                                    ? { engine.removeTrackUndoable(at: idx, actionName: s.undoDeleteTrack) }
                                    : nil
                            )
                            .trackDragOffset(td.id)
                        }

                        // Add track menu — Step oder CC, kein hartes Limit.
                        MenuKey(menu: {
                            .of([
                                ClosureMenuItem(title: s.addStepTrack, checked: false) { addTrack(kind: .step) }
                                    .with(image: "square.grid.3x2"),
                                ClosureMenuItem(title: s.addCCTrack, checked: false) { addTrack(kind: .cc) }
                                    .with(image: "dial.min"),
                                ClosureMenuItem(title: s.addAudioLoopTrack, checked: false) {
                                    engine.addAudioLoopTrackUndoable(actionName: s.undoAddTrack)
                                }
                                .with(image: "waveform.circle", enabled: engine.rack.canAddChannel),
                            ])
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle")
                                AddTrackLabel()
                            }
                            .font(VintageTheme.monoSmall)
                            .foregroundColor(VintageTheme.textSecondary)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 14)
                            .background(VintageTheme.panel)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7)
                                .stroke(VintageTheme.panelBorder.opacity(0.6), lineWidth: 1))
                        }
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .coordinateSpace(name: TrackDragState.space)
                    .onPreferenceChange(TrackRowFramesKey.self) { trackDrag.frames = $0 }
                    .environmentObject(trackDrag)
                    .padding(12)
                }
                .background(VintageTheme.background)
                // Bei kleinem Fenster gibt der Mixer nach (bis MixerDock.minHeight), nicht die Spuren.
                .frame(minHeight: 150)
                .modifier(GlobalPinchZoomModifier(
                    viewWidth: geo.size.width,
                    laneMinX:  viewportController.laneMetrics.viewportMinX))
            }

            // ── Globale horizontale Scrollbar ────────────────────────────
            // G01: Clip und Dokument kommen aus der gemessenen Lane-Geometrie.
            GlobalHScrollbar(metrics: viewportController.laneMetrics)

            // ── Mixer (v1.13.1): unten angedockt, über die Transportleiste ein-/ausblendbar ──
            if showMixer { MixerDock() }

            // ── Status bar ───────────────────────────────────────────────
            StatusBar()
        }
        // G01: Lane-Viewport/Inhaltsausdehnung kommen von den gerenderten Lanes (Preference), nicht aus
        // Fensterbreite minus Konstanten. Der Raum misst den Viewport-Beginn für die Scrollbar.
        .coordinateSpace(name: LaneGeometry.space)
        .onPreferenceChange(LaneViewportKey.self) { viewportController.reportLaneViewport($0) }
        .onPreferenceChange(LaneShapesKey.self)   { viewportController.reportLaneShapes($0) }
        // Wirksame WIDTH des Controllers == committeter Zustand (außer innerhalb des Pinch-Handlers, der sie vorab setzt).
        .onValueChange(of: stepWidthState.size, initial: true) { w in viewportController.setStepWidth(w) }
        // Liegt der Inhalt unter der Titelleiste des Fensters, rückt er um das gemessene Maß
        // nach unten (v1.13.10). Gemessen, nicht angenommen: je nach System legt das Fenster
        // den Inhalt unter die Titelleiste oder darunter.
        .padding(.top, titlebarOverlap)
        .background(TitlebarOverlapReader(overlap: $titlebarOverlap))
        .background(VintageTheme.background)
        .frame(minWidth: 920, minHeight: 540)
#if DEBUG
        // Handle-drag / scroll analysis overlay — remove this block to disable.
        .overlay(alignment: .bottomTrailing) {
            HandleDebugOverlayView()
                .padding(.bottom, 44)   // clears scrollbar + status bar
                .padding(.trailing, 12)
        }
        // EdgeScroll tuning panel (Arch-Slice-8) — collapsible HUD, bottom-left
        // so it never overlaps transport controls or notes buttons.
        .overlay(alignment: .bottomLeading) {
            EdgeScrollDebugPanel()
                .padding(.bottom, 44)   // clears scrollbar + status bar
                .padding(.leading, 12)
        }
#endif
        // Die Engine registriert Struktur-, Paste- und Learn-Undo selbst und leert den
        // Stack bei Load/New — dafür braucht sie den Undo-Manager des Fensters.
        .onValueChange(of: undoManager, initial: true) { um in engine.undoManager = um }
        .onAppear {
            // NSEvent-Monitor: zwei-Finger-Trackpad-Wischen → viewportController
            // Arch-Slice-6: replaces direct scrollState.hScrollOffset write.
            // Wird nur ausgelöst wenn horizontal dominiert (abs(dx) > abs(dy)).
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                let dx = event.scrollingDeltaX
                let dy = event.scrollingDeltaY
                guard abs(dx) > abs(dy), abs(dx) > 0.5 else { return event }
                // Grenze (maxScrollOffset) kommt ausschließlich aus der gemessenen Lane-Geometrie (G01).
#if DEBUG
                let oldOffset = viewportController.scrollState.hScrollOffset
#endif
                viewportController.scrollTrackpad(delta: dx)
#if DEBUG
                HandleDebugLogger.shared.logScrollChange(old: oldOffset,
                                                         new: viewportController.scrollState.hScrollOffset,
                                                         source: "trackpad")
#endif
                return event   // pass on so the NSScrollbar thumb follows
            }
        }
        .onDisappear {
            if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
            engine.stop()
            engine.midi.cleanup()
        }
    }
}

// MARK: - Global horizontal scrollbar

/// Einzige horizontale Scrollbar der App — echtes NSScrollView für native Darstellung.
/// Positioniert bündig mit dem Step-Bereich (rechts von Spurkopf-Spalte).
struct GlobalHScrollbar: View {
    @EnvironmentObject var viewportController: ViewportController
    /// Blattview: beobachtet den Offset, damit der Thumb Trackpad-, Edge-Scroll- und Zoom-Änderungen folgt
    /// (MainView selbst abonniert `scrollState` bewusst nicht — Scroll-Performance).
    @EnvironmentObject private var scrollState: ScrollState
    /// Dokumentbreite hängt an der aktuellen WIDTH (Blattview, ändert sich selten).
    @EnvironmentObject private var stepWidthState: StepWidthState
    /// G01: gemessene Lane-Geometrie. Der Scrollbar-Clip ist genau der Lane-Viewport.
    var metrics: LaneMetrics

    /// Rückfall bis zur ersten Messung (eine Layout-Runde).
    private var fallbackLeadingPad: CGFloat { 12 + VintageTheme.trackHeaderWidth + 1 }

    var body: some View {
        HStack(spacing: 0) {
            if metrics.hasViewport, let minX = metrics.viewportMinX {
                // Beginn bündig mit dem Lane-Viewport; rechts davon (feste Zone/Rand) bleibt Leerfläche.
                VintageTheme.panelDark
                    .frame(width: max(0, minX))
                NativeHScrollbar(viewportController: viewportController,
                                 contentExtent: metrics.contentExtent(at: stepWidthState.size),
                                 viewportWidth: metrics.viewportWidth,
                                 offset: scrollState.hScrollOffset)
                    .frame(width: metrics.viewportWidth)
                VintageTheme.panelDark
            } else {
                VintageTheme.panelDark
                    .frame(width: fallbackLeadingPad)
                NativeHScrollbar(viewportController: viewportController,
                                 contentExtent: 0, viewportWidth: 0,
                                 offset: scrollState.hScrollOffset)
            }
        }
        .frame(height: 18)
        .background(VintageTheme.panelDark)
        .overlay(
            Rectangle()
                .fill(VintageTheme.panelBorder)
                .frame(height: 1),
            alignment: .top
        )
    }
}

/// NSScrollView-Wrapper: immer sichtbare horizontale Scrollbar.
///
/// **Arch-Slice-6:** Schreibt nicht mehr direkt in `scrollState.hScrollOffset`.
/// Alle Sync-Pfade laufen über `ViewportController`:
///   - VC → NSScrollView: `updateNSView` liest `viewportController.scrollState.hScrollOffset`
///     und setzt `viewportController.isSyncingScrollbar` als Re-Entranz-Guard.
///   - NSScrollView → VC: `Coordinator.boundsChanged` ruft `viewportController.syncFromScrollbar(_:)`.
/// Der Coordinator hält keine eigenen Sync-Flags mehr — beide leben in `ViewportController`.
struct NativeHScrollbar: NSViewRepresentable {
    var viewportController: ViewportController
    /// G01: Inhaltsausdehnung der breitesten Lane; Dokumentbreite = Ausdehnung, Clip = Lane-Viewport
    /// → natives Maximum (Dokument − Clip) == `LaneGeometry.maxOffset`.
    var contentExtent: CGFloat
    var viewportWidth: CGFloat
    /// Aktueller Controller-Offset (VC → NSScrollView). Als Parameter, damit Offsetänderungen `updateNSView` auslösen.
    var offset: CGFloat

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView()
        sv.hasHorizontalScroller  = true
        sv.hasVerticalScroller    = false
        sv.autohidesScrollers     = false          // immer sichtbar
        sv.horizontalScrollElasticity = .none
        sv.verticalScrollElasticity   = .none
        sv.drawsBackground        = false
        sv.borderType             = .noBorder

        // Dokument-View bestimmt den scrollbaren Bereich
        let doc = NSView(frame: NSRect(x: 0, y: 0,
                                       width: LaneGeometry.documentWidth(contentExtent: contentExtent,
                                                                         viewportWidth: viewportWidth),
                                       height: 1))
        sv.documentView = doc

        // Positionsänderungen beobachten
        sv.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.boundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: sv.contentView
        )
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        // isSyncingScrollbar deckt die gesamte updateNSView-Laufzeit ab.
        // Verhindert, dass boundsChanged-Notifikationen (aus Frame-Resize ODER scroll(to:))
        // syncFromScrollbar innerhalb des SwiftUI-Update-Pass aufrufen und dort
        // @Published-Writes auslösen → "Publishing from view updates" / Feedback-Loop.
        guard !viewportController.isSyncingScrollbar else { return }
        viewportController.isSyncingScrollbar = true
        defer { viewportController.isSyncingScrollbar = false }

        // Inhalt-Breite aktuell halten (nach Step-Count- oder Pinch/Width-Änderung).
        // MUSS im Guard-Block liegen: frame.size.width kann synchron boundsChanged
        // auslösen, wenn der Clip-View seinen Scrollbereich anpasst.
        sv.documentView?.frame.size.width = LaneGeometry.documentWidth(contentExtent: contentExtent,
                                                                       viewportWidth: viewportWidth)

        let cur    = sv.contentView.bounds.origin.x
        if abs(cur - offset) > 0.5 {
            sv.contentView.scroll(to: NSPoint(x: offset, y: 0))
            sv.reflectScrolledClipView(sv.contentView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(viewportController: viewportController) }

    final class Coordinator: NSObject {
        /// Unowned reference — VC outlives the NSViewRepresentable coordinator.
        var viewportController: ViewportController

        init(viewportController: ViewportController) {
            self.viewportController = viewportController
        }
        deinit { NotificationCenter.default.removeObserver(self) }

        /// NSScrollView → VC: Nutzer zieht den Scrollbalken-Thumb.
        ///
        /// Delegiert vollständig an `ViewportController.syncFromScrollbar(_:)`,
        /// das Session-Guard und Re-Entranz-Guard kapselt.
        @objc func boundsChanged(_ note: Notification) {
            guard let clip = note.object as? NSClipView else { return }
            let x = max(0, clip.bounds.origin.x)
#if DEBUG
            let oldX = viewportController.scrollState.hScrollOffset
#endif
            viewportController.syncFromScrollbar(x)
#if DEBUG
            HandleDebugLogger.shared.logScrollChange(old: oldX, new: x, source: "scrollbar")
#endif
        }
    }
}

// MARK: - Status bar

private struct AddTrackLabel: View {
    @AppStorage("appLanguage") private var lang: String = "en"
    var body: some View {
        Text(Str(lang).addTrack)
    }
}

struct StatusBar: View {
    @EnvironmentObject var engine:                    SequencerEngine
    @EnvironmentObject private var ts:                TransportState
    @EnvironmentObject private var clockDiagnostics:  ClockDiagnosticsState
    @EnvironmentObject private var midi:              MIDIManager
    @AppStorage("appLanguage") private var lang: String = "en"
    private var s: Str { Str(lang) }

    var body: some View {
        HStack(spacing: 14) {
            // Play indicator LED
            Circle()
                .fill(ts.isPlaying ? VintageTheme.amberBright : VintageTheme.amberDim)
                .frame(width: 6, height: 6)
                .shadow(color: VintageTheme.amber.opacity(ts.isPlaying ? 0.8 : 0), radius: 4)

            Text(ts.isPlaying ? s.running : s.stopped)
                .font(VintageTheme.monoSmall)
                .foregroundColor(ts.isPlaying ? VintageTheme.textAmber : VintageTheme.textSecondary)

            Text("•")
                .foregroundColor(VintageTheme.textDim)

            Text("BPM \(String(format: "%.1f", ts.bpm))")
                .font(VintageTheme.monoSmall)
                .foregroundColor(VintageTheme.textSecondary)
                .monospacedDigit()

            if ts.isPlaying && clockDiagnostics.avgUs > 0 {
                Text("•")
                    .foregroundColor(VintageTheme.textDim)
                Text("JIT min:\(String(format: "%.0f", clockDiagnostics.minUs)) avg:\(String(format: "%.0f", clockDiagnostics.avgUs)) max:\(String(format: "%.0f", clockDiagnostics.maxUs))µs\(clockDiagnostics.outs > 0 ? " [\(clockDiagnostics.outs)↑]" : "")")
                    .font(VintageTheme.monoSmall)
                    .foregroundColor(clockDiagnostics.maxUs > 500 ? .orange : VintageTheme.textDim)
                    .monospacedDigit()
            }

            // S01: Tick wegen nicht erwerbbarem Snapshot ausgelassen — im Normalbetrieb unsichtbar.
            if clockDiagnostics.snapshotAcquireFailures > 0 {
                Text("•")
                    .foregroundColor(VintageTheme.textDim)
                Text(s.timingDropouts(clockDiagnostics.snapshotAcquireFailures))
                    .font(VintageTheme.monoSmall)
                    .foregroundColor(.orange)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityLabel(s.timingDropoutsA11y(clockDiagnostics.snapshotAcquireFailures))
            }

            Text("•")
                .foregroundColor(VintageTheme.textDim)

            Text("CLK \(ts.clockMode.rawValue)")
                .font(VintageTheme.monoSmall)
                .foregroundColor(VintageTheme.textSecondary)

            Text("•")
                .foregroundColor(VintageTheme.textDim)

            Text("PATTERN \(Pattern.slotNames[ts.currentPatternIndex])")
                .font(VintageTheme.monoSmall)
                .foregroundColor(VintageTheme.textSecondary)

            Spacer()

            // MIDI out name (if selected)
            if let out = midi.outputs
                .first(where: { $0.ref == midi.selectedOutput }) {
                Text("OUT: \(out.name)")
                    .font(VintageTheme.monoSmall)
                    .foregroundColor(VintageTheme.textSecondary)
                    .lineLimit(1)
            } else {
                Text(s.noMidiOutput)
                    .font(VintageTheme.monoSmall)
                    .foregroundColor(VintageTheme.textDim)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(VintageTheme.panelDark)
        .overlay(
            Rectangle()
                .fill(VintageTheme.panelBorder)
                .frame(height: 1),
            alignment: .top
        )
    }
}

// MARK: - GlobalPinchZoomModifier

/// Globaler Pinch-Zoom-Handler für den gesamten Sequencer-Arbeitsbereich.
///
/// **Arch-Slice-20:** Ersetzt N per-Lane `PinchZoomModifier`-Instanzen in `StepGridView`.
/// Wird einmal am `ScrollView`-Container in `MainView` registriert.
///
/// **Anchor-Kompensation:** Delegiert an `InteractionController.updatePinchZoom`,
/// der `ViewportController.adjustScroll` aufruft. Der Scroll-Offset folgt dem
/// Pinch-Zentrum — kein visuelles Wegdriften mehr.
///
/// **anchorX-Koordinatenraum:** `adjustScroll` erwartet Screen-Space-X relativ
/// zum linken Rand des Step-Bereichs (nach TrackHeader + Padding).
/// `stepAreaOffsetX` = VStack-Padding (12) + trackHeaderWidth (224) + Separator (1) = 237 px.
///
/// - `viewWidth`: Breite des ScrollView-Containers, geliefert vom umschließenden
///   `GeometryReader`. Auf macOS 14+ wird `value.startAnchor` genutzt;
///   ältere OS-Versionen fallen auf Mitte des Step-Bereichs zurück.
private struct GlobalPinchZoomModifier: ViewModifier {

    let viewWidth: CGFloat
    /// Gemessener Beginn des Lane-Viewports (G01); nil bis zur ersten Messung.
    let laneMinX: CGFloat?

    @EnvironmentObject private var engine: SequencerEngine
    /// Nur Aufrufe, keine Darstellung → einfache Referenz statt Beobachtung.
    private var interactionController: InteractionController { engine.interactionController }
    @EnvironmentObject private var stepWidthState: StepWidthState

    @State private var pinchActive       = false
    /// Breite zu Beginn der Geste — gespiegelt aus IC.pinchSnapshotStepWidth,
    /// damit wir die Quantisierungs-Vorschau berechnen können, ohne IC aufzurufen.
    @State private var pinchSnapshotWidth: Double = 0

    /// Offset des Step-Bereichs von der linken ScrollView-Kante.
    /// = VStack-Padding + trackHeaderWidth + Separator-Breite.
    private var stepAreaOffsetX: CGFloat {
        laneMinX ?? (12 + VintageTheme.trackHeaderWidth + 1)
    }

    /// Berechnet die erwartete neue Breite aus Snapshot + Magnification.
    /// Spiegelt die Release-Formel von IC.updatePinchZoom (sensitivity = 1.0).
    /// Zweck: Integer-Boundary-Check, bevor IC (inkl. adjustScroll) aufgerufen wird.
    private func previewWidth(magnification: Double) -> Double {
        let spacing = Double(VintageTheme.stepSpacing)
        let raw = (pinchSnapshotWidth + spacing) * magnification - spacing
        return max(30, min(120, raw))
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.simultaneousGesture(
                MagnifyGesture(minimumScaleDelta: 0.01)
                    .onChanged { value in
                        if !pinchActive {
                            pinchActive        = true
                            pinchSnapshotWidth = stepWidthState.size
                            interactionController.beginPinchZoom(
                                currentStepWidth: CGFloat(stepWidthState.size))
                        }
                        let gestureX = CGFloat(value.startAnchor.x) * viewWidth
                        let anchorX  = max(0, gestureX - stepAreaOffsetX)

                        // Vorschau ohne IC-Aufruf: hat sich ein ganzer Pixel geändert?
                        let quantized = previewWidth(magnification: Double(value.magnification)).rounded()
                        guard quantized != stepWidthState.size else { return }

                        // Erst jetzt IC aufrufen — adjustScroll läuft synchron mit dem
                        // Layout-Commit. Kein Frame pumpt mehr den Scroll-Offset ohne
                        // gleichzeitigen Width-Commit.
                        let committed = interactionController.updatePinchZoom(
                            magnification: CGFloat(value.magnification),
                            anchorX: anchorX)
                        stepWidthState.size = committed.rounded()
                    }
                    .onEnded { _ in
                        interactionController.endPinchZoom()
                        pinchActive = false
                    }
            )
        } else {
            content.simultaneousGesture(
                MagnificationGesture(minimumScaleDelta: 0.01)
                    .onChanged { value in
                        if !pinchActive {
                            pinchActive        = true
                            pinchSnapshotWidth = stepWidthState.size
                            interactionController.beginPinchZoom(
                                currentStepWidth: CGFloat(stepWidthState.size))
                        }
                        let anchorX  = max(0, (viewWidth - stepAreaOffsetX) / 2)

                        let quantized = previewWidth(magnification: Double(value)).rounded()
                        guard quantized != stepWidthState.size else { return }

                        let committed = interactionController.updatePinchZoom(
                            magnification: CGFloat(value),
                            anchorX: anchorX)
                        stepWidthState.size = committed.rounded()
                    }
                    .onEnded { _ in
                        interactionController.endPinchZoom()
                        pinchActive = false
                    }
            )
        }
    }
}

// MARK: - TitlebarOverlapReader

/// Misst, wie weit die Fläche dieser View unter die Titelleiste ihres Fensters reicht
/// (0, wenn der Inhalt darunter beginnt oder das Fenster im Vollbild ist).
struct TitlebarOverlapReader: NSViewRepresentable {
    @Binding var overlap: CGFloat

    func makeNSView(context: Context) -> Probe {
        let v = Probe()
        v.report = { value in
            DispatchQueue.main.async { if abs(overlap - value) > 0.5 { overlap = value } }
        }
        return v
    }
    func updateNSView(_ nsView: Probe, context: Context) { nsView.measure() }

    /// Überdeckung aus Oberkante der View und nutzbarem Inhaltsbereich des Fensters.
    static func overlap(viewTopInWindow: CGFloat, contentLayoutTop: CGFloat) -> CGFloat {
        max(0, (viewTopInWindow - contentLayoutTop).rounded())
    }

    final class Probe: NSView {
        var report: ((CGFloat) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            for name in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification,
                         NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main) { [weak self] _ in self?.measure() })
            }
            measure()
        }

        override func layout() { super.layout(); measure() }

        func measure() {
            guard let window else { return }
            // Die Sonde liegt hinter der bereits eingerückten Fläche: ihre Oberkante ist die
            // Oberkante des SwiftUI-Inhalts im Fenster.
            let top = convert(bounds, to: nil).maxY
            report?(TitlebarOverlapReader.overlap(viewTopInWindow: top,
                                                  contentLayoutTop: window.contentLayoutRect.maxY))
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
