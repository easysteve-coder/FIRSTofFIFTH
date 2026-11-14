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

    private var currentRatioIndex: Int {
        track.lane.ratioOptions.firstIndex(where: {
            $0.num == track.lane.stepLengthNumerator && $0.den == track.lane.stepLengthDenominator
        }) ?? (track.lane.ratioOptions.count / 2)
    }

    var body: some View {
        VStack(spacing: 0) {

            // ── Top: Ratio Handle (Arch-Slice-2 — neue Architektur) ──────────
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
                dotAtTop: true,
                onStart: {
                    let contentUnit = CGFloat(track.lane.stepCount)
                                    * (stepWidthSize + VintageTheme.stepSpacing)
                    interactionController.beginRatioDrag(
                        track:          track.data,
                        contentUnit:    contentUnit,
                        baseRatioIndex: currentRatioIndex
                    )
                },
                onDrag: { totalX in
                    interactionController.updateRatioDrag(totalX: totalX, track: track.data)
                },
                onEnd: {
                    interactionController.commitRatioDrag(
                        track:       track.data,
                        undoManager: undoManager
                    )
                },
                onEdgeScroll: { velocity in
                    interactionController.applyEdgeScroll(velocity: velocity)
                }
            )

            Spacer()

            // ── Bottom: Step-Count Handle (Arch-Slice-1 — unverändert) ───────
            //
            // Vollständig über InteractionController:
            //   onStart  → beginHandleDrag captures pxPerStep + snapshot
            //   onDrag   → updateHandleDrag applies via ModelWriter (no undo)
            //   onEnd    → commitHandleDrag writes final value + registers undo
            //   edge     → applyEdgeScroll routes through ViewportController
            CornerDotHandle(
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
        }
        .frame(width: VintageTheme.cornerHandlesWidth, height: stepDisplaySize)
    }
}
