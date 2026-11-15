import SwiftUI

// MARK: - CornerHandlesView

/// Vertikaler Handle-Bereich nach dem letzten Step-Button.
///
/// **Drag-Modell (Arch-Slice-2 — beide Handles auf neuer Architektur):**
///
/// Beide Handles delegieren vollständig an `InteractionController`:
///   onStart       → `begin…Drag(track:…)`
///   onDrag        → `update…Drag(totalX:track:)`
///   onEnd         → `commit…Drag(track:undoManager:)`
///   onEdgeScroll  → `applyEdgeScroll(velocity:)`
///
/// **Keine Bindings mehr:**
/// `isHandleDragging`, `ratioHandleSnapshot`, `ratioHandleBaseIndex` wurden
/// vollständig aus diesem View entfernt. Die jeweiligen Snapshots leben in
/// `HandleDragSession` bzw. `RatioDragSession` innerhalb des `InteractionController`.
///
/// **Alte StepGridCoordinator-Felder entfernt (Arch-Slice-2):**
///   • `isHandleDragging`      → `ViewportController.sessionActive`
///   • `ratioHandleSnapshot`   → `RatioDragSession.snapshotNumerator/Denominator`
///   • `ratioHandleBaseIndex`  → `RatioDragSession.baseRatioIndex`
struct CornerHandlesView: View {

    @ObservedObject var track: TrackViewModel
    var accentColor:     Color
    var stepWidthSize:   CGFloat
    var stepDisplaySize: CGFloat

    @EnvironmentObject private var engine: SequencerEngine
    /// Nur Aufrufe, keine Darstellung → einfache Referenz statt Beobachtung.
    private var interactionController: InteractionController { engine.interactionController }
    @Environment(\.undoManager) private var undoManager
    @AppStorage("appLanguage") private var lang: String = "en"
    private var s: Str { Str(lang) }

    /// Ziehen am Längen-Anfasser läuft (nur Anzeige): bei Pad-Lanes erscheint die Länge
    /// am Anfasser, weil sich die Breite im kompakten Raster nicht ändert (v1.13.18).
    @State private var isDraggingLength = false

    private var currentRatioIndex: Int {
        let options = track.lane.ratioOptions(engine.timeSignature)
        // Nächstliegender Wert (v1.18.31: eigene Brüche stehen nicht in der Liste).
        let v = track.lane.stepSixteenths
        return options.indices.min(by: {
            abs(Double(options[$0].num) / Double(options[$0].den) - v)
                < abs(Double(options[$1].num) / Double(options[$1].den) - v)
        }) ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {

            // v1.18.25 (Stephan: „Die anfasser sind falsch rum: der obere muss die Step-Anzahl, der
            // untere die Step-Length beeinflussen"): oben Anzahl, unten Länge — wie die Angabe am
            // rechten Rand der Lane (StretchHandleView: oben Anzahl, unten Länge).

            // ── Oben: Step-Anzahl (Arch-Slice-1) ─────────────────────────────
            //
            // Vollständig über InteractionController:
            //   onStart  → beginHandleDrag captures pxPerStep + snapshot
            //   onDrag   → updateHandleDrag applies via ModelWriter (no undo)
            //   onEnd    → commitHandleDrag writes final value + registers undo
            //   edge     → applyEdgeScroll routes through ViewportController
            CornerDotHandle(
                dotAtTop: true,
                onStart: {
                    let pxPerStep = (stepWidthSize + VintageTheme.stepSpacing)
                                   * CGFloat(track.lane.displayNumerator)
                                   / CGFloat(track.lane.displayDenominator)
                    interactionController.beginHandleDrag(
                        track:     track.data,
                        pxPerStep: pxPerStep
                    )
                },
                onDrag: { totalX in
                    interactionController.updateHandleDrag(totalX: totalX, track: track.data)
                },
                onEnd: {
                    interactionController.commitHandleDrag(
                        track:       track.data,
                        undoManager: undoManager
                    )
                },
                onEdgeScroll: { velocity in
                    interactionController.applyEdgeScroll(velocity: velocity)
                }
            )

            Spacer()

            // ── Unten: Step-Länge (Ratio, Arch-Slice-2) ───────────────────────
            //
            // onStart: Berechnet contentUnit einmalig bei Drag-Start und übergibt
            //          sie zusammen mit baseRatioIndex an InteractionController.
            //          Die Werte landen in RatioDragSession — kein Binding nötig.
            //
            // onDrag:  updateRatioDrag leitet totalX weiter; der Controller
            //          berechnet den nächstgelegenen Ratio-Index via
            //          HandleDragLogic.ratioIndex und schreibt über ModelWriter.
            //
            // onEnd:   commitRatioDrag registriert einen einzelnen Undo-Eintrag
            //          (snapshot → final) und gibt die Session frei.
            //
            // onEdgeScroll: Identisch zum Count-Handle — routed über
            //          ViewportController.scroll(by:).
            CornerDotHandle(
                color: accentColor.opacity(0.7),
                dotAtTop: false,
                onStart: {
                    isDraggingLength = true
                    let contentUnit = CGFloat(track.lane.stepCount)
                                    * (stepWidthSize + VintageTheme.stepSpacing)
                    interactionController.beginRatioDrag(
                        track:          track.data,
                        contentUnit:    contentUnit,
                        baseRatioIndex: currentRatioIndex,
                        ratios:         track.lane.ratioOptions(engine.timeSignature)
                    )
                },
                onDrag: { totalX in
                    interactionController.updateRatioDrag(totalX: totalX, track: track.data)
                },
                onEnd: {
                    isDraggingLength = false
                    interactionController.commitRatioDrag(
                        track:       track.data,
                        undoManager: undoManager
                    )
                },
                onEdgeScroll: { velocity in
                    interactionController.applyEdgeScroll(velocity: velocity)
                }
            )
            .overlay(alignment: .bottomTrailing) {
                if isDraggingLength && track.lane.isLongStep {
                    Text(s.laneLength(track.lane, meter: engine.timeSignature))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.black)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3).fill(accentColor))
                        .fixedSize()
                        .offset(x: 6, y: 18)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: VintageTheme.cornerHandlesWidth, height: stepDisplaySize)
    }
}
