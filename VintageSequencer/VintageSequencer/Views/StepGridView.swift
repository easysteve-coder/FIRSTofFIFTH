import SwiftUI
import AppKit

// MARK: - StepGridView

/// Scrollbarer Step-Grid-Bereich einer Track-Lane.
///
/// Enthält:
///   - Step-Button-Rendering (ForEach mit StepButtonView)
///   - Pitch-Drag- und Step-Swap-Drag-Gesten (simultaneousGesture pro Step)
///   - CornerHandlesView (Ratio- + Step-Count-Handle)
///   - (ehem. TrackCCKnobSectionView — mit Step-Lane-Purify P1 entfernt)
///   - RubberBandOverlayView (sichtbares Auswahlrechteck)
///   - Rubber-Band-Drag-Geste auf dem ZStack
///   - Edge-Auto-Scroll-Logik
///   - StretchHandleView (rechts, außerhalb des scrollbaren Inhalts)
///
/// **State-Zugriff:** Alle transienten Drag-/Selektion-Zustände kommen
/// über `@ObservedObject var grid: StepGridCoordinator` vom Parent.
/// Der Parent (`TrackRowView`) hält die Lifetime via `@StateObject`.
///
/// **Engine-Zugriff:** Über `@EnvironmentObject` — kein Durchreichen als Parameter.
///
/// **Arch-Slice-3 — RubberBand-Migration:**
/// Der Rubber-Band-Pfad läuft vollständig über `InteractionController`:
///   - `.onChanged` startet via `beginRubberBand` oder aktualisiert via `updateRubberBand`.
///   - `.onEnded` committet via `commitRubberBand`.
///   - Step-Button-Gesten canceln via `cancelRubberBand`.
///   - Overlay-Koordinaten kommen aus `grid.rubberAnchorContentX` / `rubberCurrentContentX`
///     (beide Content-Space, kein gemischter Koordinatenraum mehr).
///   - Scroll-Sync läuft intern in IC via Combine-Subscription auf hScrollOffset.
///   - `updateRubberSelection()` und `connectScrollState()` entfernt.
///   - `engine.activeSelectionTrack` nicht mehr gesetzt (Arch-Slice-3).
///
/// Extracted from `TrackRowView` as part of E2 (TrackRowView decomposition, step E2.3b).
struct StepGridView: View {

    @ObservedObject var track: TrackViewModel
    @ObservedObject var grid:  StepGridCoordinator
    var accentColor:    Color
    var trackIndex:     Int

    @EnvironmentObject private var engine:               SequencerEngine
    @EnvironmentObject private var stepWidthState:       StepWidthState
    // v1.12.20 — Beobachtungshygiene: Diese View beobachtet weder Playhead noch Scroll noch
    // den InteractionController. Playhead und Scroll-Offset beobachten nur die Blatt-Views
    // in LaneLeafViews.swift (PlayheadGate, laneScrollShift, RubberBandLayer); sonst liefe
    // der gesamte Lane-Body samt aller Gesten-Closures bei jedem Tick, Scroll-Event und
    // jeder Mausbewegung einer Drag-Session neu.
    // Der InteractionController wird nur aufgerufen, nie dargestellt → einfache Referenz.
    private var interactionController: InteractionController { engine.interactionController }
    /// Scroll-Offset zum Ereigniszeitpunkt (Gesten) — bewusst ohne Beobachtung.
    private var scrollOffsetNow: CGFloat { engine.scrollState.hScrollOffset }
    @Environment(\.undoManager) private var undoManager
    @AppStorage("appLanguage") private var lang: String = "en"
    private var s: Str { Str(lang) }
    /// Step, dessen Edit-Card offen ist (Rechtsklick, ctrl+Klick, ⌥+Klick).
    @State private var editIndex: Int?

    /// Step unter einem Punkt des sichtbaren Lane-Bereichs (Bildschirm-x, Scroll eingerechnet).
    private func stepIndex(at p: CGPoint) -> Int? {
        LaneGeometry.stepIndex(contentX: p.x + scrollOffsetNow, y: p.y,
                               rowHeight: stepRowHeight, cellHeight: CGFloat(engine.stepDisplaySize),
                               stepCount: track.lane.stepCount,
                               num: track.lane.displayNumerator, den: track.lane.displayDenominator,
                               stepWidthSize: stepWidthState.size)
    }

    // isPinching entfernt (P3 — Pinch-Zoom-Fix):
    // Die @Binding-Verbindung zu PinchZoomModifier schrieb im .onChanged-Callback
    // auf @State in StepGridView → SwiftUI-Invalidierung des Parent während Gesture-
    // Verarbeitung → "Publishing changes from within view updates"-Warnung.
    // PinchZoomModifier verwaltet seinen Session-Guard jetzt vollständig intern
    // via pinchStartWidth == 0 (lokaler @State des Modifiers, kein @Binding nötig).

    // MARK: - Layout helpers (gespiegelt aus TrackRowView)

    private var stepRowHeight: CGFloat {
        max(90, CGFloat(engine.stepDisplaySize) + 12)
    }

    // Step-Lane-Purify P1 (v1.10.0): ccRowH / totalScrollHeight entfernt —
    // Step-Lanes rendern keine CC-Knob-Reihen mehr. Die Scroll-Höhe ist
    // jetzt immer `stepRowHeight`.

    // MARK: - Body

    var body: some View {
        #if DEBUG
        let _ = BodyRunCounter.shared.count("StepGrid")
        #endif
        HStack(spacing: 0) {

            // GeometryReader für Rubber-Band-Overlay-Position + Edge-Scroll-Breite
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {

                    // Unsichtbarer Hintergrund der vollen Breite —
                    // macht den leeren Bereich rechts der Steps für die
                    // Rubber-Band-Gesture (outer ZStack) hittestbar.
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)

                    // ── Step Content Container ─────────────────────────────
                    // Enthält alle horizontal-positionsabhängigen Elemente:
                    //   1. StepBeatLinesView  — Beat-Linien im Step-Koordinatenraum
                    //   2. VStack (Steps+CC)  — der eigentliche Step-Content
                    //   3. isCurrentStep in StepButtonView — zellbasiertes LED-Highlight
                    // Arch-Slice-20: Pinch-Zoom läuft global in MainView.GlobalPinchZoomModifier.
                    // RubberBandOverlay liegt bewusst AUSSERHALB (screen-space).
                    ZStack(alignment: .topLeading) {

                    // ── Beat-Linien (P3/Zoom-Fix) ─────────────────────────
                    // Kein Scroll im Canvas selbst — .offset(x:) übernimmt das,
                    // analog zur VStack-Gruppe darunter.
                    StepBeatLinesView(stepWidthSize: stepWidthState.size, meter: engine.timeSignature)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .laneScrollShift()
                        .allowsHitTesting(false)

                    // ── Sync'd via scrollState.hScrollOffset ──────────────
                    // Global scrollbar (MainView) drives this offset;
                    // all lanes clip & shift together — no per-lane scroll.
                    VStack(alignment: .leading, spacing: 0) {

                        // Step buttons row
                        HStack(spacing: VintageTheme.stepSpacing) {
                            ForEach(0..<track.lane.stepCount, id: \.self) { i in
                                stepButtonCell(index: i)
                            }

                            // ── Corner-Handles nach dem letzten Step ─────────
                            // Arch-Slice-2: both handles fully on new architecture.
                            // No Bindings — all session state lives inside InteractionController.
                            CornerHandlesView(
                                track:           track,
                                accentColor:     accentColor,
                                stepWidthSize:   CGFloat(stepWidthState.size),
                                stepDisplaySize: CGFloat(engine.stepDisplaySize)
                            )
                        }
                        .padding(.horizontal, VintageTheme.stepGridLeadingPad)
                        .padding(.vertical, 6)
                        .frame(height: stepRowHeight)
                        #if DEBUG
                        .background(LaneGeometryProbeView(key: "\(track.id)/content"))
                        #endif

                        // Step-Lane-Purify P1 (v1.10.0): TrackCCKnobSectionView
                        // entfernt — Step-Lanes zeigen keine Per-Step-CC-Knob-
                        // Reihen mehr. CC-Verläufe laufen über eigene CC-Lanes.
                    }
                    .laneScrollShift()

                    // Zellbasiertes Highlight: isCurrentStep direkt in StepButtonView.
                    // Kein separates Overlay mehr nötig.

                    } // ── Ende Step Content Container ────────────────────────
                    .frame(width:  LaneGeometry.sane(geo.size.width),
                           height: LaneGeometry.sane(geo.size.height),
                           alignment: .topLeading)
                    // contentShape: gesamte Fläche für RubberBand-Geste hittestbar.
                    // Pinch-Zoom läuft global in MainView (GlobalPinchZoomModifier).
                    .contentShape(Rectangle())

                    // ── Rubber-band overlay (Arch-Slice-3) ───────────────────
                    // Screen-Space-Koordinaten, außerhalb des Step Content Containers.
                    // Non-nil only during phase == .active (coordinator clears on commit/cancel).
                    RubberBandLayer(grid: grid, height: CGFloat(engine.stepDisplaySize))

                }
                // G01: Der scrollende Bereich wird auf die gemessene Größe des GeometryReaders gelayoutet.
                // Ohne festen Rahmen wächst der ZStack auf die Inhaltsbreite; dann clippt `.clipped()`
                // erst an der Inhaltsbreite und Steps malen/treffen in Count-/Ratiozone und Außenrand.
                // Clip und contentShape beziehen sich auf genau diesen Rahmen.
                .frame(width:  LaneGeometry.sane(geo.size.width),
                       height: LaneGeometry.sane(geo.size.height),
                       alignment: .topLeading)
                #if DEBUG
                .background(LaneGeometryProbeView(key: "\(track.id)/clipContainer"))
                #endif
                .clipped()
                // contentShape macht den gesamten geclippten Bereich hittestbar —
                // auch leere Stellen zwischen Steps. Ohne das startet die
                // Rubber-Band-Gesture nicht in Lücken.
                .contentShape(Rectangle())
                // Rechtsklick / ctrl+Klick auf einen Step öffnet direkt dessen Edit-Card.
                .overlay(SecondaryClickCatcher(accepts: { stepIndex(at: $0) != nil },
                                               action:  { editIndex = stepIndex(at: $0) }))

                // ── Rubber-band gesture (Arch-Slice-3) ──────────────────────
                //
                // Koordinatenmodell: ALL X-Werte werden sofort in Content-Space
                // konvertiert (screenX + scrollOffset). IC speichert beide Werte,
                // damit bei Auto-Scroll ohne Pointer-Bewegung currentContentX neu
                // berechnet werden kann (= currentScreenX + neuer Offset).
                //
                // Session-Steuerung:
                //   .rubberBand aktiv → updateRubberBand (kein Re-Start)
                //   kein Session      → beginRubberBand (neue Session)
                //   Handle-Session    → ignorieren (modal-Invariante)
                //
                // Scroll-Sync: IC subscribiert intern auf scrollState.$hScrollOffset.
                // Kein connectScrollState mehr nötig.
                .gesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .local)
                        .onChanged { value in
                            guard value.startLocation.y < stepRowHeight else { return }
                            // Block rubber band while a step session (pitch/swap) is active.
                            // The if/else below already suppresses begin/update, but this
                            // guard also prevents the edge-auto-scroller from firing.
                            let stepSessionActive: Bool = {
                                if case .pitchDrag = interactionController.activeSession { return true }
                                if case .stepSwap  = interactionController.activeSession { return true }
                                return false
                            }()
                            guard !stepSessionActive else { return }

                            if case .rubberBand = interactionController.activeSession {
                                // ── Update laufenden Rubber-Band ──────────────
                                let contentX = value.location.x + scrollOffsetNow
                                interactionController.updateRubberBand(
                                    contentX: contentX,
                                    screenX:  value.location.x,
                                    y:        value.location.y
                                )
                            } else if interactionController.activeSession == nil {
                                // ── Neuen Rubber-Band starten ─────────────────
                                let stepW = (CGFloat(stepWidthState.size) + VintageTheme.stepSpacing)
                                            * CGFloat(track.lane.displayNumerator)
                                            / CGFloat(track.lane.displayDenominator)

                                let contentX = value.startLocation.x + scrollOffsetNow
                                interactionController.beginRubberBand(
                                    trackID:   track.id,
                                    contentX:  contentX,
                                    screenX:   value.startLocation.x,
                                    y:         value.startLocation.y,
                                    stepWidth: stepW,
                                    stepCount: track.lane.stepCount
                                )
                            }
                            // else: Handle-Session aktiv — Rubber-Band blockiert.

                            // ── Edge auto-scroll (Arch-Slice-7) ──────────────
                            // IC owns the timer; view only reports pointer position.
                            // Smoothstep ramp via EdgeScrollVelocity — no local zone math.
                            interactionController.updateEdgeScrollPointer(
                                x: value.location.x,
                                viewWidth: geo.size.width
                            )
                        }
                        .onEnded { _ in
                            interactionController.endEdgeScroll()
                            interactionController.commitRubberBand()
                        }
                )
                // Pinch-Zoom: GlobalPinchZoomModifier in MainView — nicht mehr per Lane.
                // Nur step-positionsabhängige Elemente werden gezoomt.
                // Scroll-sync für Rubber-Band: läuft intern in InteractionController
                // via Combine-Subscription auf scrollState.$hScrollOffset.
                // Kein per-Lane .onChange(of: hScrollOffset) mehr nötig.
            }
            .background(LaneViewportReporter())
            #if DEBUG
            .background(LaneGeometryProbeView(key: "\(track.id)/viewport"))
            #endif
            // GeometryReader height = total scroll column height.
            // Grows when CC rows are expanded.
            .frame(height: stepRowHeight)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())

            // Stretch handle spans the full scroll height
            StretchHandleView(track: track,
                              accentColor: accentColor,
                              baseStepWidth: CGFloat(engine.stepDisplaySize))
                .frame(width: StretchHandleView.width)
                .frame(height: stepRowHeight)
        }
        // Arch-Slice-3: Verbindet StepGridCoordinator mit InteractionController.
        // Empfängt RubberBandUpdate-Werte via Combine und überträgt sie in die
        // Render-State-Properties des Koordinators (rubberAnchorContentX, selectedSteps …).
        // Ersetzt: grid.connectScrollState(scrollState, track: track, engine: engine)
        .onAppear {
            grid.connectInteractionController(interactionController, track: track.data)
        }
        // G01-R1: Topologie dieser Lane (Stepzahl, Ratio) — die Ausdehnung folgt exakt aus WIDTH + Topologie.
        .preference(key: LaneShapesKey.self, value: [LaneShape(track: track.data)])
    }

    // MARK: - Step Cell Helpers

    /// Standard-Zelle: StepButton + equatable + Drag-Gesture (Pitch-Drag / Step-Swap).
    ///
    /// Arch-Slice-4+5: Session-Steuerung ausschließlich über InteractionController.
    /// - `pitchDrag`: vertikale Drag-Richtung → Semitone-Änderung + MIDI-Vorschau.
    /// - `stepSwap`:  horizontale Drag-Richtung → Swap / Copy mit Option-Modifier.
    ///
    /// Diese Methode ist der einzige Ort, an dem DragGesture-Closures erzeugt werden.
    @ViewBuilder
    private func stepButtonCell(index i: Int) -> some View {
        let isSource = grid.dragSourceIndex == i
        let isTarget = grid.dragTargetIndex == i
                      && grid.dragSourceIndex != nil
                      && grid.dragSourceIndex != i

        // Nur das Gate läuft pro Tick neu; `.equatable()` lässt genau die zwei betroffenen
        // Zellen (an/aus) neu rendern. Opacity, Overlay und Geste liegen außerhalb des Gates.
        PlayheadGate(trackIndex: trackIndex, stepIndex: i) { isCurrent in
            StepButtonView(
                track: track,
                index: i,
                trackIndex: trackIndex,
                isCurrentStep: isCurrent,
                isSelected: grid.selectedSteps.contains(i),
                accentColor: accentColor,
                size:  CGFloat(engine.stepDisplaySize),
                width: VintageTheme.distributedStepWidth(
                           index: i,
                           num: track.lane.displayNumerator,
                           den: track.lane.displayDenominator,
                           stepWidthSize: stepWidthState.size),
                onToggleSelect: {
                    if grid.selectedSteps.contains(i) {
                        grid.selectedSteps.remove(i)
                    } else {
                        grid.selectedSteps.insert(i)
                    }
                },
                onEdit: { editIndex = i })
            .equatable()    // P3: nur bei isCurrentStep / isSelected / width re-rendern
            .overlay(alignment: .topTrailing) {
                // Pad-Lane: Länge jedes Steps sichtbar, folgt dem Ziehen live (v1.13.18).
                if track.lane.isLongStep {
                    // „Gruppe": jeder Step zeigt seine eigene Länge (3/8, 4/8 …).
                    Text(track.lane.stepGroup
                         ? s.noteValue(num: Int(track.lane.sixteenths(ofStep: i, meter: engine.timeSignature)),
                                       den: 1, meter: engine.timeSignature)
                         : s.laneLength(track.lane, meter: engine.timeSignature))
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundColor(accentColor.opacity(0.85))
                        .padding(.top, 4)
                        .padding(.trailing, 5)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                // Pad-Lane: lange Steps zeigen, wie weit der laufende Step ist.
                if isCurrent && track.lane.isLongStep {
                    PadProgressBar(seconds: 60.0 / max(1, engine.bpm)
                                            * track.lane.sixteenths(ofStep: i, meter: engine.timeSignature) / 4.0,
                                   color: accentColor)
                }
            }
        }
        .popover(isPresented: Binding(get: { editIndex == i },
                                      set: { if !$0, editIndex == i { editIndex = nil } }),
                 arrowEdge: .bottom) {
            StepDetailView(track: track, index: i, accentColor: accentColor)
        }
        .opacity(isSource ? 0.35 : 1.0)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.85), lineWidth: 2)
                .opacity(isTarget ? 1 : 0)
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    let dx = abs(value.translation.width)
                    let dy = abs(value.translation.height)

                    // ── Session bestimmen (nur beim ersten Event) ─────────
                    // Check if THIS step already owns a pitch or swap session.
                    let hasOwnSession: Bool = {
                        if case .pitchDrag = interactionController.activeSession { return true }
                        if case .stepSwap  = interactionController.activeSession { return true }
                        return false
                    }()

                    if !hasOwnSession {
                        // Cancel a running rubber-band so the session slot is free.
                        if case .rubberBand = interactionController.activeSession {
                            interactionController.cancelRubberBand()
                        }
                        // Begin the appropriate step session.
                        // beginPitchDrag / beginStepSwap guard _session == nil,
                        // so they silently no-op if a handle drag is active.
                        if dy > dx {
                            // ⌥ beim Beginn: Velocity statt Tonhöhe. Der Anker hält den
                            // ersten Schritt bei ±1 (die Geste meldet erst nach 8 pt).
                            interactionController.beginPitchDrag(
                                track: track.data, stepIndex: i,
                                anchorY: value.translation.height,
                                velocity: NSEvent.modifierFlags.contains(.option)
                            )
                        } else {
                            let sw = (CGFloat(stepWidthState.size) + VintageTheme.stepSpacing)
                                     * CGFloat(track.lane.displayNumerator)
                                     / CGFloat(track.lane.displayDenominator)
                            interactionController.beginStepSwap(
                                track: track.data, sourceIndex: i, stepWidth: sw
                            )
                        }
                    }

                    // ── An aktive Session weiterleiten ────────────────────
                    if case .pitchDrag = interactionController.activeSession {
                        // Live notes update → MIDI preview on semitone change.
                        if let newNotes = interactionController.updatePitchDrag(
                            totalY: value.translation.height,
                            track: track.data
                        ) {
                            engine.previewPlay(
                                notes:    newNotes,
                                channel:  track.midiChannel,
                                velocity: track.lane.steps[i].velocity,
                                route:    engine.rack.route(for: track.data.output)
                            )
                        }
                    } else if case .stepSwap = interactionController.activeSession {
                        // Render-hint update only; model is not mutated.
                        interactionController.updateStepSwap(
                            translationX: value.translation.width,
                            track: track.data
                        )
                    }
                }
                .onEnded { _ in
                    if case .pitchDrag = interactionController.activeSession {
                        engine.stopPreview()
                        interactionController.commitPitchDrag(
                            track: track.data, undoManager: undoManager
                        )
                    } else if case .stepSwap = interactionController.activeSession {
                        let isCopy = NSEvent.modifierFlags.contains(.option)
                        interactionController.commitStepSwap(
                            track: track.data, isCopy: isCopy, undoManager: undoManager
                        )
                    }
                }
        )
    }
}

// MARK: - StepBeatLinesView

/// Per-Track Beat-Linien im Step-Koordinatenraum.
///
/// **Warum hier statt in BPMGridView?**
/// `BPMGridView` ist ein globales Overlay in `MainView` — außerhalb jedes `scaleEffect`.
/// Beat-Linien sind step-positionsabhängig und müssen während Pinch-Zoom
/// denselben `scaleEffect` erfahren wie der Step-Content.
/// Daher werden sie pro Track innerhalb des Scaled Content Containers gezeichnet.
///
/// **Koordinatenraum:** Canvas-Koordinaten sind Content-Space ohne Scroll-Korrektur.
/// Der Aufrufer wendet `.offset(x: -hScrollOffset)` auf diese View an (analog zur VStack-Gruppe),
/// sodass Scroll genau einmal und konsistent angewendet wird.
///
/// **Kein Loop-Abbruch bei positivem x nötig:** Canvas clipped sich selbst.
///
/// CC-Lane Slice 1.1 (v1.8.1): nicht mehr `private` — wird von `CCLaneBodyView`
/// wiederverwendet, damit die CC-Lane dieselben Beat-Linien wie die Step-Lane
/// zeigt. Kein Verhalten geändert.
struct StepBeatLinesView: View {

    let stepWidthSize: Double
    /// Taktart (v1.18.12): Linie je Schlag, kräftiger auf dem Taktstrich.
    var meter: TimeSignature = .common

    private var naturalSlotSize: CGFloat {
        CGFloat(stepWidthSize) + VintageTheme.stepSpacing
    }

    var body: some View {
        let slotSize  = naturalSlotSize
        let lineColor = Color(red: 0.55, green: 0.42, blue: 0.20).opacity(0.45)
        let barColor  = Color(red: 0.75, green: 0.56, blue: 0.24).opacity(0.75)
        let style     = StrokeStyle(lineWidth: 1.0)
        let beat      = max(1, meter.sixteenthsPerBeat)
        let bar       = max(beat, meter.sixteenthsPerBar)
        // Gruppierung (v1.18.30): Linien an den Gruppengrenzen statt je Schlag.
        let groups    = meter.grouping == nil ? nil : meter.groupSixteenths

        Canvas { ctx, size in
            // Beat-Linien je Schlag der Taktart (4/4: alle 4 Steps), Taktstrich kräftiger;
            // linksbündig zur HStack-Padding-Grenze (8px).
            // Kein Scroll-Abzug: wird per .offset(x: -hScrollOffset) auf dem Container erledigt.
            var i = 0
            while true {
                // Position identisch zur BPMGridView-Formel, angepasst auf lokalen Koordinatenraum:
                //   BPMGridView: stepAreaX + slotSize*i − stepSpacing/2   (stepAreaX = header + 8)
                //   Hier:        8         + slotSize*i − stepSpacing/2   (bereits im Step-Bereich)
                let x = VintageTheme.stepGridLeadingPad + slotSize * CGFloat(i) - VintageTheme.stepSpacing / 2
                if x > size.width + slotSize { break }
                if x >= 0 {
                    var path = Path()
                    path.move(to:    CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(path, with: .color(i % bar == 0 ? barColor : lineColor), style: style)
                }
                if let groups {
                    // Nächste Gruppengrenze im Takt: Summe der Gruppen bis über die Lage im Takt.
                    let inBar = i % bar
                    var edge = 0
                    for g in groups { edge += max(1, g); if edge > inBar { break } }
                    i += max(1, edge - inBar)
                } else {
                    i += beat
                }
            }
        }
    }
}

// Pinch-Zoom-Handler wurde in Arch-Slice-20 nach MainView.GlobalPinchZoomModifier
// verschoben — ein globaler Handler statt N per-Lane-Instanzen.
