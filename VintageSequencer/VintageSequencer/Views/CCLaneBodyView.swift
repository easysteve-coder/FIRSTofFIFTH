import SwiftUI
import AppKit

// MARK: - CCLaneBodyView
//
// Lane-Body-Implementierung für `.cc`-Lanes.
//
// CC-Lane Slice 1.1 (UI-Refinement, v1.8.1):
// Die Geometrie spiegelt jetzt `StepGridView`:
//   - Outer `HStack { GeometryReader { ZStack … }.clipped(); StretchHandleView }`
//   - Horizontales Scrolling via `scrollState.hScrollOffset` (wie Step-Lane)
//   - CornerHandlesView liegt INNERHALB der gescrollten Knob-Row (rechts nach
//     dem letzten Knob) — sie sitzt damit am echten Content-Edge und bewegt
//     sich mit Scroll und Step-Count-Drag, genau wie in der Step-Lane.
//   - StretchHandleView (80 pt) liegt AUSSERHALB der gescrollten Fläche als
//     stabiler rechter Griff für Ratio- und Step-Length-Anpassung.
//   - `StepBeatLinesView` als Hintergrund — dieselben Beat-Linien wie Step-Lane
//     machen Raster, Ratio und Step-Count visuell erfahrbar.
//   - Playback-Highlight ist pro Zelle als LED oberhalb des Knobs realisiert
//     (amberBright + Glow, identisches Muster zu `StepButtonView`).
//     Kein springendes Overlay-Rechteck mehr.
//
// Unverändert aus Slice 1:
//   - Kein Rubber-Band / kein Pitch-Drag / kein Step-Swap (CC-Lanes senden keine Notes).
//   - Knob-Drag-Live-Writes ohne Undo — Draw-Undo läuft beim Gesture-End.
//   - Datenmodell und Audio/Snapshot-Pfade unverändert.
struct CCLaneBodyView: View {

    @ObservedObject var track: TrackViewModel
    var accentColor: Color
    var trackIndex:  Int
    @Binding var drawMode: Bool

    @EnvironmentObject private var engine:          SequencerEngine
    @EnvironmentObject private var stepWidthState:  StepWidthState
    // v1.12.20: Playhead und Scroll werden nur in Blatt-Views beobachtet (LaneLeafViews.swift).
    @Environment(\.undoManager) private var undoManager
    @AppStorage("appLanguage") private var lang:        String = "en"
    @AppStorage("showCCCurve") private var showCCCurve: Bool   = true
    private var s: Str { Str(lang) }
    private let writer = ModelWriter()

    @State private var drawSnapshot: [Int]? = nil
    @State private var lastDrawLoc:  CGPoint? = nil

    private var rowHeight: CGFloat {
        max(120, CGFloat(engine.stepDisplaySize) + 40)
    }

    // Breite des Draw-Overlays = Knob-Bereich inkl. linkes hPad, aber OHNE
    // CornerHandles rechts. So bleiben Ratio- und Step-Count-Handle im
    // Zeichen-Modus anfassbar (1.8.2).
    private var drawOverlayWidth: CGFloat {
        let slotSize = (CGFloat(stepWidthState.size) + VintageTheme.stepSpacing)
                      * CGFloat(track.lane.stepLengthNumerator)
                      / CGFloat(track.lane.stepLengthDenominator)
        let knobsWidth = slotSize * CGFloat(track.lane.stepCount) - VintageTheme.stepSpacing
        return VintageTheme.stepGridLeadingPad + max(0, knobsWidth)
    }

    // Knob size, abgeleitet aus stretched step width.
    private var knobSize: CGFloat {
        let sw = VintageTheme.stretchedStepWidth(num: track.lane.stepLengthNumerator,
                                                  den: track.lane.stepLengthDenominator,
                                                  stepWidthSize: stepWidthState.size)
        let base = CGFloat(engine.stepDisplaySize) - 16
        return max(12, min(base, sw - 10))
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 0) {

            // Scrollender Content-Bereich — Struktur spiegelt StepGridView.
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {

                    // Hittestbarer Hintergrund der vollen Breite.
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)

                    // ── Beat-Linien (lane-neutral, identisch zur Step-Lane) ──
                    StepBeatLinesView(stepWidthSize: stepWidthState.size, meter: engine.timeSignature)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .laneScrollShift()
                        .allowsHitTesting(false)

                    // ── Knob-Reihe + LEDs + CornerHandles (gescrollt) ───────
                    knobRow
                        .laneScrollShift()

                    // ── CC-Kurve (gescrollt, nicht hittestbar) ──────────────
                    if showCCCurve {
                        curveCanvas
                            .frame(height: rowHeight)
                            .laneScrollShift()
                            .allowsHitTesting(false)
                    }

                    // ── Draw-Overlay (gescrollt, nur im drawMode aktiv) ─────
                    // Breite = exakt der Knob-Bereich (keine Überdeckung der
                    // CornerHandles rechts). Start bei x=0 inkl. hPad — das
                    // matcht `applyDraw`, das location.x − hPad zum Index-
                    // Mapping verwendet.
                    if drawMode {
                        drawOverlay
                            .frame(width: drawOverlayWidth,
                                   height: rowHeight,
                                   alignment: .leading)
                            .laneScrollShift()
                    }
                }
                // G01: wie StepGridView — scrollender Bereich auf die gemessene Viewport-Größe layouten,
                // damit Clip und contentShape nicht an der Inhaltsbreite enden.
                .frame(width:  LaneGeometry.sane(geo.size.width),
                       height: LaneGeometry.sane(geo.size.height),
                       alignment: .topLeading)
                #if DEBUG
                .background(LaneGeometryProbeView(key: "\(track.id)/clipContainer"))
                #endif
                .clipped()
                .contentShape(Rectangle())
            }
            .background(LaneViewportReporter())
            #if DEBUG
            .background(LaneGeometryProbeView(key: "\(track.id)/viewport"))
            #endif
            .frame(height: rowHeight)
            .frame(maxWidth: .infinity)

            // Stretch-Handle — außerhalb des gescrollten Bereichs, wie Step-Lane.
            StretchHandleView(track: track,
                              accentColor: accentColor,
                              baseStepWidth: CGFloat(engine.stepDisplaySize))
                .frame(width: StretchHandleView.width)
                .frame(height: rowHeight)
        }
        // G01-R1: Topologie dieser Lane (Stepzahl, Ratio) — die Ausdehnung folgt exakt aus WIDTH + Topologie.
        .preference(key: LaneShapesKey.self, value: [LaneShape(track: track.data)])
    }

    // MARK: - Knob row (inkl. zellbasierter LED und Corner-Handles)

    private var knobRow: some View {
        HStack(spacing: VintageTheme.stepSpacing) {
            ForEach(0..<track.lane.stepCount, id: \.self) { i in
                knobCell(index: i)
            }

            // CornerHandles im Content-Fluss — wandern mit Scroll und Step-Count.
            CornerHandlesView(
                track:           track,
                accentColor:     accentColor,
                stepWidthSize:   CGFloat(stepWidthState.size),
                stepDisplaySize: CGFloat(engine.stepDisplaySize)
            )
        }
        .padding(.horizontal, VintageTheme.stepGridLeadingPad)
        .padding(.vertical, 5)
        .frame(height: rowHeight)
        #if DEBUG
        .background(LaneGeometryProbeView(key: "\(track.id)/content"))
        #endif
    }

    @ViewBuilder
    private func knobCell(index i: Int) -> some View {
        let binding = Binding<Double>(
            get: { Double(track.lane.ccValues[safe: i] ?? 0) },
            set: { v in
                let old = track.lane.ccValues[safe: i] ?? 0
                let new = max(0, min(127, Int(v)))
                guard new != old else { return }
                writer.apply(.setCCLaneValue(trackID: track.id,
                                              index: i,
                                              old: old,
                                              new: new),
                             to: track.data,
                             undoManager: nil)
            }
        )

        VStack(spacing: 3) {
            // LED-Farben/Glow identisch zu StepButtonView; nur die LED folgt dem Playhead.
            PlayheadGate(trackIndex: trackIndex, stepIndex: i) { isCurrent in
                let ledColor: Color = isCurrent
                    ? VintageTheme.amberBright
                    : VintageTheme.amberDim.opacity(0.4)
                Circle()
                    .fill(ledColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: ledColor.opacity(isCurrent ? 1.0 : 0), radius: isCurrent ? 8 : 4)
            }

            KnobView(
                label: "\(i + 1)",
                value: binding,
                range: 0...127,
                size:  knobSize,
                accentColor: accentColor
            )
        }
        .frame(width: VintageTheme.distributedStepWidth(
            index: i,
            num:   track.lane.stepLengthNumerator,
            den:   track.lane.stepLengthDenominator,
            stepWidthSize: stepWidthState.size))
    }

    // MARK: - CC Curve

    private var curveCanvas: some View {
        Canvas { ctx, size in
            // CC-Lane Slice 1.2 (Visual-Refinement, v1.8.2):
            // Kurve semantisch als „Wert-pro-Zeitfenster" (step-hold) gerendert:
            //   - Geometrie verankert an Slot-KANTEN, nicht an Knob-Mitten.
            //   - Erste Stützstelle beginnt am linken Rand des ersten Slots,
            //     letzte Stützstelle endet am rechten Rand des letzten Slots.
            //   - Marker pro Step = kurze horizontale Linie auf dem Wertniveau
            //     (nicht mehr als isolierter Punkt).
            //   - Übergänge zwischen Slots = dünne Diagonalen vom rechten Ende
            //     von Slot i zum linken Anfang von Slot i+1.
            // Draw-Verhalten, Knob-Logik und Daten bleiben unverändert.
            let hPad: CGFloat = VintageTheme.stepGridLeadingPad
            let n    = track.lane.stepCount
            guard n > 0 else { return }
            let values = (0..<n).map { track.lane.ccValues[safe: $0] ?? 0 }
            let slotSize = (CGFloat(stepWidthState.size) + VintageTheme.stepSpacing)
                          * CGFloat(track.lane.stepLengthNumerator)
                          / CGFloat(track.lane.stepLengthDenominator)

            // Slot-Innenkanten (linke / rechte Kante der sichtbaren Knob-Zelle).
            func leftX (_ i: Int) -> CGFloat {
                hPad + (slotSize * CGFloat(i)).rounded(.toNearestOrEven)
            }
            func rightX(_ i: Int) -> CGFloat {
                hPad + (slotSize * CGFloat(i + 1)).rounded(.toNearestOrEven)
                     - VintageTheme.stepSpacing
            }
            func yFor(_ v: Int) -> CGFloat {
                size.height * (1 - CGFloat(v) / 127)
            }

            // ── Flächen-Fill (step-hold, inkl. Überbrückung der Slot-Gaps) ──
            var area = Path()
            area.move(to: CGPoint(x: leftX(0), y: size.height))
            area.addLine(to: CGPoint(x: leftX(0), y: yFor(values[0])))
            for i in 0..<n {
                let y_i = yFor(values[i])
                area.addLine(to: CGPoint(x: rightX(i), y: y_i))
                if i < n - 1 {
                    // waagerecht über den Slot-Gap auf gleichem Wertniveau …
                    area.addLine(to: CGPoint(x: leftX(i + 1), y: y_i))
                    // … dann senkrechter Sprung auf den nächsten Wert.
                    area.addLine(to: CGPoint(x: leftX(i + 1), y: yFor(values[i + 1])))
                }
            }
            area.addLine(to: CGPoint(x: rightX(n - 1), y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .color(accentColor.opacity(0.12)))

            // ── Übergangs-Diagonalen (dünn) von Slot-Ende zu Slot-Anfang ──
            if n >= 2 {
                var bridges = Path()
                for i in 0..<(n - 1) {
                    bridges.move(to:    CGPoint(x: rightX(i    ), y: yFor(values[i    ])))
                    bridges.addLine(to: CGPoint(x: leftX (i + 1), y: yFor(values[i + 1])))
                }
                ctx.stroke(bridges,
                           with: .color(accentColor.opacity(0.40)),
                           lineWidth: 1.0)
            }

            // ── Marker pro Step: kurze waagerechte Linie auf dem Wertniveau ──
            // Liegt exakt auf der Slot-Innenbreite — ersetzt die früheren Punkte.
            var markers = Path()
            for i in 0..<n {
                let y_i = yFor(values[i])
                markers.move(to:    CGPoint(x: leftX(i),  y: y_i))
                markers.addLine(to: CGPoint(x: rightX(i), y: y_i))
            }
            ctx.stroke(markers,
                       with: .color(accentColor.opacity(0.85)),
                       lineWidth: 2.0)
        }
    }

    // MARK: - Draw overlay

    private var drawOverlay: some View {
        GeometryReader { geo in
            accentColor.opacity(0.06)
                .contentShape(Rectangle())
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(accentColor.opacity(0.35),
                                style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .local)
                        .onChanged { value in
                            if drawSnapshot == nil { drawSnapshot = track.lane.ccValues }
                            applyDraw(at: value.location, size: geo.size)
                        }
                        .onEnded { _ in
                            if let snapshot = drawSnapshot {
                                writer.apply(.setCCLaneValues(trackID: track.id,
                                                               oldValues: snapshot,
                                                               newValues: track.lane.ccValues,
                                                               actionName: s.undoCCLaneDraw),
                                             to: track.data,
                                             undoManager: undoManager)
                            }
                            drawSnapshot = nil
                            lastDrawLoc  = nil
                        }
                )
        }
    }

    // MARK: - Draw helper

    private func applyDraw(at location: CGPoint, size: CGSize) {
        let hPad: CGFloat = VintageTheme.stepGridLeadingPad
        let sw = VintageTheme.stretchedStepWidth(num: track.lane.stepLengthNumerator,
                                                  den: track.lane.stepLengthDenominator,
                                                  stepWidthSize: stepWidthState.size)
                + VintageTheme.stepSpacing
        let x = location.x - hPad
        let stepIdx = max(0, min(track.lane.stepCount - 1, Int(x / sw)))
        let value   = max(0, min(127, Int((1.0 - location.y / size.height) * 127)))

        var values = track.lane.ccValues

        if let last = lastDrawLoc {
            let lastX    = last.x - hPad
            let lastIdx  = max(0, min(track.lane.stepCount - 1, Int(lastX / sw)))
            let lastVal  = max(0, min(127, Int((1.0 - last.y / size.height) * 127)))
            if lastIdx != stepIdx {
                let lo = min(lastIdx, stepIdx)
                let hi = max(lastIdx, stepIdx)
                let (startVal, endVal) = lastIdx < stepIdx ? (lastVal, value) : (value, lastVal)
                let span = hi - lo
                for idx in lo...hi {
                    guard idx < values.count else { continue }
                    let t = span > 0 ? Double(idx - lo) / Double(span) : 0
                    let v = Int(Double(startVal) + t * Double(endVal - startVal))
                    values[idx] = v
                }
            }
        }

        if stepIdx < values.count {
            values[stepIdx] = value
        }
        lastDrawLoc = location

        // Live-Write ohne Undo — Undo wird im onEnded gesetzt.
        writer.apply(.setCCLaneValues(trackID: track.id,
                                       oldValues: track.lane.ccValues,
                                       newValues: values,
                                       actionName: s.undoCCLaneDraw),
                     to: track.data,
                     undoManager: nil)
    }
}

// Small safe-index helper scoped to this file.
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
