import SwiftUI
import Combine   // ObservableObject, @Published — Xcode 26: kein transitive import mehr via SwiftUI

// MARK: - StepGridCoordinator

/// Bündelt alle transienten UI-Interaktionszustände des Step-Grids.
///
/// **Arch-Slice-4+5 — PitchDrag / StepSwap-Migration:**
/// Alle alten Pitch-Drag- und Step-Swap-Zustände wurden entfernt.
/// `connectInteractionController` setzt jetzt zwei Combine-Sinks:
///   - Rubber-Band-Sink: wie bisher (Arch-Slice-3).
///   - Step-Swap-Sink: empfängt `StepSwapUpdate` aus IC und schreibt
///     `dragSourceIndex` / `dragTargetIndex` für das Step-Button-Overlay.
///
/// Was entfernt wurde (Arch-Slice-4+5):
/// - `isPitchDrag: Bool`         — lebte in PitchDragSession (IC)
/// - `pitchDragStepIndex: Int?`  — lebte in PitchDragSession.stepIndex
/// - `pitchStepsSnapshot: [Step]?` — lebte in PitchDragSession.stepsSnapshot
/// - `pitchDragBaseNotes: [Int]?` — lebte in PitchDragSession.baseNotes
/// - `pitchDragLastSemis: Int?`  — lebte in PitchDragSession.lastAppliedSemitones
/// - `dragSourceIndex` direkte View-Mutation — jetzt durch icStepSwapSink geschrieben
/// - `dragTargetIndex` direkte View-Mutation — jetzt durch icStepSwapSink geschrieben
///
/// Was bleibt (Arch-Slice-3):
/// - `selectedSteps` — Rubber-Band-Ergebnis, geschrieben durch icRubberBandSink
/// - `rubberAnchorContentX`, `rubberCurrentContentX` — Overlay-Koordinaten (Content-Space)
///
/// Was bleibt (Render-State, jetzt IC-getrieben):
/// - `dragSourceIndex: Int?` — Source-Step-Highlight; geschrieben durch icStepSwapSink
/// - `dragTargetIndex: Int?` — Target-Step-Highlight;  geschrieben durch icStepSwapSink
final class StepGridCoordinator: ObservableObject {

    // MARK: - Step selection (Render-State — geschrieben durch icRubberBandSink)

    /// Aktuell ausgewählte Step-Indizes (Rubber-Band-Ergebnis + Toggle).
    @Published var selectedSteps: Set<Int> = []

    // MARK: - RubberBand overlay state (Render-State — Content-Space)

    /// X-Koordinate des Drag-Starts in CONTENT-Space (für Overlay-Rendering).
    @Published var rubberAnchorContentX:  CGFloat? = nil

    /// X-Koordinate des aktuellen Pointer-Stands in CONTENT-Space.
    @Published var rubberCurrentContentX: CGFloat? = nil

    // MARK: - Step swap render hints (Render-State — geschrieben durch icStepSwapSink)

    /// Source-Step-Index während eines aktiven Step-Swap-Drags.
    /// Non-nil nur während Phase .active; wird auf nil gesetzt bei .committed / .cancelled.
    @Published var dragSourceIndex: Int? = nil

    /// Aktueller Ziel-Step-Index während eines Step-Swap-Drags.
    /// Non-nil nur während Phase .active; wird auf nil gesetzt bei .committed / .cancelled.
    @Published var dragTargetIndex: Int? = nil

    // Auto-scroll timer moved to InteractionController (Arch-Slice-7).
    // EdgeAutoScroller removed — IC.updateEdgeScrollPointer / endEdgeScroll replace it.

    // MARK: - InteractionController Combine bridge (Arch-Slice-3 + 4/5)

    /// Combine-Subscription auf `InteractionController.$rubberBandUpdate`.
    private var icRubberBandSink: AnyCancellable?

    /// Combine-Subscription auf `InteractionController.$stepSwapUpdate`.
    private var icStepSwapSink: AnyCancellable?

    // MARK: - Connect

    /// Verbindet den Koordinator mit `InteractionController`.
    ///
    /// Einmalig aus `StepGridView.onAppear` aufzurufen.
    /// Richtet zwei Combine-Sinks ein:
    ///
    /// **Rubber-Band-Sink:** Empfängt `RubberBandUpdate`-Werte:
    ///   - `.active` + eigene Track-ID → Overlay-Koordinaten + `selectedSteps`
    ///   - `.committed` + eigene ID   → Overlay weg, Selektion behalten
    ///   - `.cancelled` + eigene ID   → Overlay weg, Selektion löschen
    ///   - andere Track-ID            → eigene Selektion + Overlay löschen
    ///
    /// **Step-Swap-Sink:** Empfängt `StepSwapUpdate`-Werte:
    ///   - `.active` + eigene Track-ID    → `dragSourceIndex` + `dragTargetIndex` setzen
    ///   - `.committed` / `.cancelled`    → beide auf nil setzen
    ///   - andere Track-ID               → beide auf nil setzen (kein eigener Drag aktiv)
    func connectInteractionController(_ ic: InteractionController, track: TrackData) {

        // ── Rubber-Band-Sink ──────────────────────────────────────────
        icRubberBandSink = ic.$rubberBandUpdate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] update in
                guard let self else { return }

                guard let upd = update else {
                    rubberAnchorContentX  = nil
                    rubberCurrentContentX = nil
                    return
                }

                if upd.trackID == track.id {
                    switch upd.phase {
                    case .active:
                        rubberAnchorContentX  = upd.anchorContentX
                        rubberCurrentContentX = upd.currentContentX
                        selectedSteps         = upd.selectedSteps
                    case .committed:
                        rubberAnchorContentX  = nil
                        rubberCurrentContentX = nil
                        // selectedSteps bleibt unverändert
                    case .cancelled:
                        rubberAnchorContentX  = nil
                        rubberCurrentContentX = nil
                        selectedSteps         = []
                    }
                } else {
                    // Anderer Track hat Rubber-Band gestartet → eigene Selektion löschen.
                    rubberAnchorContentX  = nil
                    rubberCurrentContentX = nil
                    selectedSteps         = []
                }
            }

        // ── Step-Swap-Sink ────────────────────────────────────────────
        icStepSwapSink = ic.$stepSwapUpdate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] update in
                guard let self else { return }

                guard let upd = update, upd.trackID == track.id,
                      upd.phase == .active else {
                    // Kein Update, andere Track-ID, oder committed/cancelled →
                    // Render-Hints löschen.
                    dragSourceIndex = nil
                    dragTargetIndex = nil
                    return
                }

                dragSourceIndex = upd.sourceIndex
                dragTargetIndex = upd.targetIndex
            }
    }
}
