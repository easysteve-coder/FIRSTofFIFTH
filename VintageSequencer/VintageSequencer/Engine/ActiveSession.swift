import Foundation
import CoreGraphics

// MARK: - HandleDragSession

/// Pure value-type session for the step-count corner handle drag.
///
/// No references to Track, no @Published, no async, no UIKit/AppKit.
/// All computation is deterministic given the same inputs.
///
/// **Snapshot:** The step count at drag-start is captured here.
///
/// **Arch-Slice-7 — Scroll-compensated geometry:**
/// The session stores `scrollOffsetAtStart` so that auto-scroll during a
/// drag does not cause the handle to drift away from the pointer.
///
/// Content-space displacement from anchor:
///   `contentDisplacement = translationX + (currentScrollOffset − scrollOffsetAtStart)`
///
/// Proof that handle follows pointer exactly:
///   handleScreenX = proposedStep × pxPerStep − currentScrollOffset
///                 = (snapshot + round(contentDisplacement/px)) × px − S_t
///                 ≈ H_content_0 + translationX + ΔS − S_t
///                 = H_screen_0  + translationX          (ΔS cancels)
///
/// **No accumulator:** `DragGesture.translation.width` (total offset from
/// drag-start) is passed directly. No delta-accumulation in the view.
///
/// **pxPerStep:** Computed once at drag-start from stepWidthSize × ratio.
/// Stable for the session duration (modal invariant).
struct HandleDragSession {

    // MARK: - Identity

    let trackID: UUID

    // MARK: - Snapshot (captured once at drag-start)

    /// Step count at drag-start — base for both delta calculation and undo.
    let snapshotStepCount: Int

    /// Pixels per logical step slot (including spacing), captured at drag-start.
    let pxPerStep: CGFloat

    /// Horizontal scroll offset at drag-start.
    /// Used to compute scroll-compensated content-space displacement.
    let scrollOffsetAtStart: CGFloat

    // MARK: - Pure computation

    /// Content-space displacement from the drag anchor, accounting for auto-scroll.
    ///
    /// When the viewport scrolls by ΔS during the drag, the content moves under
    /// the pointer. Adding ΔS to translationX converts screen-space drag delta
    /// to content-space drag delta — keeping the handle under the pointer.
    private func contentDisplacement(translationX: CGFloat,
                                     currentScrollOffset: CGFloat) -> CGFloat {
        translationX + (currentScrollOffset - scrollOffsetAtStart)
    }

    /// Proposed new step count for the given drag translation and current scroll offset.
    func proposedStepCount(translationX: CGFloat, currentScrollOffset: CGFloat) -> Int {
        HandleDragLogic.stepCount(
            totalX:     contentDisplacement(translationX: translationX,
                                            currentScrollOffset: currentScrollOffset),
            pxPerStep:  pxPerStep,
            startCount: snapshotStepCount
        )
    }

    // MARK: - Command production

    func commitCommand(currentStepCount: Int) -> ModelCommand {
        .setStepCount(
            trackID: trackID,
            old:     snapshotStepCount,
            new:     currentStepCount
        )
    }
}

// MARK: - RatioDragSession

/// Pure value-type session for the ratio corner handle drag.
///
/// Mirrors HandleDragSession's design — no Track references, no @Published,
/// fully deterministic from the same inputs.
///
/// **Arch-Slice-7 — Scroll-compensated geometry:**
/// Same content-space displacement model as `HandleDragSession`:
///   `contentDisplacement = translationX + (currentScrollOffset − scrollOffsetAtStart)`
///
/// This keeps the ratio handle visually stable under the pointer during auto-scroll,
/// by the same geometric argument as HandleDragSession.
struct RatioDragSession {

    // MARK: - Identity

    let trackID: UUID

    // MARK: - Snapshot (captured once at drag-start)

    let snapshotNumerator:   Int
    let snapshotDenominator: Int
    let baseRatioIndex:      Int

    /// Full content unit at drag-start:
    /// = track.stepCount × (stepWidthSize + VintageTheme.stepSpacing).
    let contentUnit: CGFloat

    /// Horizontal scroll offset at drag-start.
    let scrollOffsetAtStart: CGFloat

    // MARK: - Pure computation

    /// Content-space displacement from anchor (same model as HandleDragSession).
    private func contentDisplacement(translationX: CGFloat,
                                     currentScrollOffset: CGFloat) -> CGFloat {
        translationX + (currentScrollOffset - scrollOffsetAtStart)
    }

    func proposedRatioIndex(translationX: CGFloat, currentScrollOffset: CGFloat) -> Int {
        HandleDragLogic.ratioIndex(
            totalX:         contentDisplacement(translationX: translationX,
                                                currentScrollOffset: currentScrollOffset),
            contentUnit:    contentUnit,
            baseRatioIndex: baseRatioIndex,
            ratios:         TrackData.sortedRatios
        )
    }

    func proposedRatio(translationX: CGFloat,
                       currentScrollOffset: CGFloat) -> (num: Int, den: Int) {
        TrackData.sortedRatios[proposedRatioIndex(translationX: translationX,
                                              currentScrollOffset: currentScrollOffset)]
    }

    // MARK: - Command production

    func commitCommand(currentNum: Int, currentDen: Int) -> ModelCommand {
        .setRatio(
            trackID: trackID,
            oldNum:  snapshotNumerator, oldDen: snapshotDenominator,
            newNum:  currentNum,       newDen: currentDen
        )
    }
}

// MARK: - RubberBandSession

/// Pure value-type session for a rubber-band selection drag.
///
/// **Coordinate model:** All positions stored in CONTENT space.
/// `anchorContentX` and `currentContentX` are pixel offsets into the
/// scrollable content (not the viewport). This means the selection is
/// stable regardless of scrolling — no mixed-space conversions inside
/// the session itself.
///
/// **Scroll sync:** `currentScreenX` stores the pointer's viewport-relative
/// X so that `InteractionController` can update `currentContentX` when the
/// viewport auto-scrolls without new pointer movement:
///   `currentContentX = currentScreenX + hScrollOffset`
///
/// **stepWidth / stepCount:** Captured once at drag-start. Both are stable
/// during the session (modal invariant prevents handle drags that would
/// change them while rubber band is active).
struct RubberBandSession {

    // MARK: - Identity

    let trackID: UUID

    // MARK: - Anchor (captured once at drag-start; content-space)

    /// Drag-start X in CONTENT space (= startScreenX + hScrollOffset at begin).
    let anchorContentX: CGFloat

    /// Drag-start Y (screen-space — for future Y-range selection support).
    let anchorY: CGFloat

    // MARK: - Live state (content-space)

    /// Current pointer X in CONTENT space (= currentScreenX + hScrollOffset).
    var currentContentX: CGFloat

    /// Current pointer Y (screen-space; not used for step selection).
    var currentY: CGFloat

    /// Current pointer X in VIEWPORT (screen) space.
    /// Kept in the session so `InteractionController` can recompute
    /// `currentContentX` when auto-scroll changes `hScrollOffset`
    /// without new pointer movement.
    var currentScreenX: CGFloat

    // MARK: - Layout (stable for session duration)

    /// Step slot width including spacing (= stretchedStepWidth + stepSpacing).
    /// Computed once at drag-start; stable while session is active (modal invariant).
    let stepWidth: CGFloat

    /// Track step count at drag-start. Stable for session.
    let stepCount: Int

    // MARK: - Constants

    /// Horizontal padding subtracted from both sides before mapping to step indices.
    static let selectionPadding: CGFloat = 8

    // MARK: - Pure computation

    /// Steps covered by the rubber band rectangle, in CONTENT space.
    ///
    /// - Returns: Set of step indices `[0, stepCount)` whose slot overlaps
    ///   `[lo, hi]` where `lo/hi` = `[min, max](anchorContentX, currentContentX) − padding`.
    func selectedSteps() -> Set<Int> {
        guard stepWidth > 0, stepCount > 0 else { return [] }
        // Ohne Breite ist nichts aufgezogen — ein ruhender Zeiger wählt keinen Step.
        guard anchorContentX != currentContentX else { return [] }
        let lo = min(anchorContentX, currentContentX) - Self.selectionPadding
        let hi = max(anchorContentX, currentContentX) - Self.selectionPadding
        let s  = max(0, Int(lo / stepWidth))
        let e  = min(stepCount - 1, Int(hi / stepWidth))
        guard s <= e else { return [] }
        return Set(s...e)
    }
}

// MARK: - RubberBandPhase

/// Describes the phase of a RubberBandUpdate published by InteractionController.
enum RubberBandPhase {
    /// The drag is in progress — overlay and selection are live.
    case active

    /// The drag ended normally — selection is final; overlay should be hidden.
    case committed

    /// The drag was cancelled — selection should be cleared; overlay hidden.
    case cancelled
}

// MARK: - RubberBandUpdate

/// Snapshot of the rubber band state published by InteractionController
/// on every drag event and on commit/cancel.
///
/// StepGridCoordinator subscribes via Combine (not SwiftUI @Published) so that
/// only the affected track's coordinator — and therefore only that track's view —
/// re-renders on each update.
struct RubberBandUpdate {
    /// Which track owns this rubber band session.
    let trackID:         UUID

    /// Drag-start X in CONTENT space (for overlay rendering).
    let anchorContentX:  CGFloat

    /// Current pointer X in CONTENT space (for overlay rendering).
    let currentContentX: CGFloat

    /// The computed step selection at this update.
    let selectedSteps:   Set<Int>

    /// Phase of the rubber band lifecycle.
    let phase:           RubberBandPhase
}

// MARK: - PitchDragSession

/// Pure value-type session for a per-step pitch drag interaction.
///
/// **Snapshot:** The full steps array is captured once at drag-start so that:
///   - Cancel can fully restore the original state via ModelWriter.
///   - Commit can produce a `.setSteps` command whose `oldSteps` is the
///     snapshot — a single, correct undo entry for the entire drag range.
///
/// **baseNotes:** Computed from `stepsSnapshot[stepIndex].notes` — the
/// notes of the dragged step at drag-start. No separate field needed.
///
/// **Dedup:** `lastAppliedSemitones` tracks the last applied semitone offset
/// so IC can skip redundant model writes when the pointer hasn't crossed a
/// semitone boundary. Reset to `nil` at session begin.
///
/// **Coordinate model:** `totalY` is the DragGesture translation.height
/// (positive = down = lower pitch). `semitones()` inverts the sign so that
/// dragging UP raises pitch.
struct PitchDragSession {

    // MARK: - Identity

    let trackID: UUID

    // MARK: - Snapshot (captured once at drag-start)

    /// Full steps array at drag-start.
    /// Immutable for session duration — used for cancel restore and commit undo.
    let stepsSnapshot: [Step]

    /// Index of the step being pitch-dragged.
    let stepIndex: Int

    // MARK: - Constants

    /// Translation, bei der die Sitzung begann. Die Geste meldet erst nach ihrer
    /// Mindeststrecke (8 pt); ohne diesen Anker spränge der erste Schritt um zwei Halbtöne.
    var anchorY: CGFloat = 0

    /// true: die Sitzung ändert die Velocity statt der Tonhöhe (⌥ beim Ziehen, v1.13.8).
    var editsVelocity: Bool = false

    /// Pixels of vertical drag per semitone change.
    static let pxPerSemitone: CGFloat = 4
    /// Punkte senkrechten Ziehens je Velocity-Stufe.
    static let pxPerVelocity: CGFloat = 1

    // MARK: - Live state

    /// Last semitone offset that was applied to the model.
    /// `nil` before the first update — forces the first event to always apply.
    var lastAppliedSemitones: Int? = nil

    // MARK: - Convenience

    /// Notes of the dragged step at drag-start (from snapshot).
    var baseNotes: [Int] { stepsSnapshot[stepIndex].notes }

    // MARK: - Pure computation

    /// Signed semitone offset for a given vertical drag translation.
    /// Dragging UP (negative translation) → positive semitones.
    func semitones(totalY: CGFloat) -> Int {
        Int((-(totalY - anchorY) / Self.pxPerSemitone).rounded())
    }

    /// Velocity des gezogenen Steps an der Ziehposition (1 … 127), hoch = lauter.
    func proposedVelocity(totalY: CGFloat) -> Int {
        let delta = Int((-(totalY - anchorY) / Self.pxPerVelocity).rounded())
        return max(1, min(127, stepsSnapshot[stepIndex].velocity + delta))
    }

    /// Proposed new notes for the dragged step at the given drag position.
    /// Each note is clamped to [0, 127].
    func proposedNotes(totalY: CGFloat) -> [Int] {
        let s = semitones(totalY: totalY)
        return baseNotes.map { max(0, min(127, $0 + s)) }
    }
}

// MARK: - StepSwapSession

/// Pure value-type session for a step-swap (reorder) drag interaction.
///
/// **Snapshot:** The full steps array is captured once at drag-start.
///   - Commit produces a `.setSteps` command from the snapshot — one undo entry.
///   - Cancel requires NO model restore: the model is never mutated during
///     the drag (unlike PitchDragSession). Only render hints change.
///
/// **targetIndex:** Updated on every drag event. Starts equal to `sourceIndex`
/// (no movement yet). Clamped to `[0, stepCount − 1]`.
///
/// **stepCount:** Derived from `stepsSnapshot.count` — stable for session
/// duration (modal invariant prevents handle drags from changing step count
/// while a swap session is active).
///
/// **isCopy:** Determined at commit time from the modifier key state.
/// Not stored in the session — queried by the caller at `.onEnded`.
struct StepSwapSession {

    // MARK: - Identity

    let trackID: UUID

    // MARK: - Snapshot + source (captured once at drag-start)

    /// Full steps array at drag-start — used for commit command's `oldSteps`.
    let stepsSnapshot: [Step]

    /// Index of the step being dragged.
    let sourceIndex: Int

    /// Step slot width in pixels including spacing (= stretchedStepWidth + stepSpacing).
    /// Captured once at drag-start; stable for session.
    let stepWidth: CGFloat

    // MARK: - Live state

    /// Current drag target index. Initially == sourceIndex.
    /// Updated on every drag event by InteractionController.updateStepSwap.
    var targetIndex: Int

    // MARK: - Convenience

    /// Total number of steps in this track (derived from snapshot).
    var stepCount: Int { stepsSnapshot.count }

    // MARK: - Pure computation

    /// Proposed target index for the given horizontal translation.
    func proposedTargetIndex(translationX: CGFloat) -> Int {
        let delta = Int(round(translationX / stepWidth))
        return max(0, min(stepCount - 1, sourceIndex + delta))
    }

    // MARK: - Command production

    /// Produces the commit command for this swap/copy.
    ///
    /// The `oldSteps` in the command is `stepsSnapshot` — enabling a single
    /// undo entry that perfectly reverses the entire drag operation.
    /// The `newSteps` is computed from the snapshot plus the swap/copy.
    func commitCommand(isCopy: Bool) -> ModelCommand {
        var newSteps = stepsSnapshot
        if isCopy {
            newSteps[targetIndex] = newSteps[sourceIndex]
        } else {
            newSteps.swapAt(sourceIndex, targetIndex)
        }
        return .setSteps(
            trackID:    trackID,
            oldSteps:   stepsSnapshot,
            newSteps:   newSteps,
            actionName: isCopy ? "Copy Step" : "Move Step"
        )
    }
}

// MARK: - StepSwapPhase

/// Phase of a StepSwapUpdate published by InteractionController.
enum StepSwapPhase {
    /// Drag is in progress — source and target indices are live.
    case active

    /// Drag ended normally — model was updated; render hints should be cleared.
    case committed

    /// Drag was cancelled — model is unchanged; render hints should be cleared.
    case cancelled
}

// MARK: - StepSwapUpdate

/// Snapshot of the step-swap render state published by InteractionController.
///
/// StepGridCoordinator subscribes via Combine (not SwiftUI @Published) so that
/// only the dragged track's coordinator — and therefore only that track's view —
/// re-renders on each update.
struct StepSwapUpdate {
    /// Which track owns this session.
    let trackID:     UUID
    let sourceIndex: Int
    let targetIndex: Int
    let phase:       StepSwapPhase
}

// MARK: - StretchRatioDragSession

/// Pure value-type session for the `StretchHandleView` ratio-zone vertical drag.
///
/// **Arch-Slice-8 — StretchHandleView migration:**
/// Replaces the `@State` accumulator pattern in `StretchHandleView` with the
/// same pure-session design used by all other interaction sessions.
///
/// **Vertical drag only:** No scroll compensation — the drag direction (Y) is
/// orthogonal to horizontal scroll. No `scrollOffsetAtStart` field needed.
///
/// **No accumulator:** `DragGesture.translation.height` (total offset from
/// drag-start) is passed directly. The session is never mutated during the drag.
struct StretchRatioDragSession {

    // MARK: - Identity

    let trackID: UUID

    // MARK: - Snapshot (captured once at drag-start)

    let snapshotNumerator:   Int
    let snapshotDenominator: Int

    /// Index of the drag-start ratio in `TrackData.sortedRatios`.
    /// Used as the zero-offset reference for delta calculation.
    let snapshotRatioIndex: Int

    // MARK: - Constants

    /// Vertical pixels required to advance one ratio step.
    /// Matches the `24.0` sensitivity constant in the original StretchHandleView.
    static let pxPerIndex: CGFloat = 24

    // MARK: - Pure computation

    /// Proposed ratio index for the given vertical drag translation.
    /// Dragging UP (negative totalY) increases index (longer step); DOWN decreases.
    func proposedRatioIndex(totalY: CGFloat) -> Int {
        let delta = -Int((totalY / Self.pxPerIndex).rounded())
        return max(0, min(TrackData.sortedRatios.count - 1, snapshotRatioIndex + delta))
    }

    func proposedRatio(totalY: CGFloat) -> (num: Int, den: Int) {
        TrackData.sortedRatios[proposedRatioIndex(totalY: totalY)]
    }

    // MARK: - Command production

    func commitCommand(currentNum: Int, currentDen: Int) -> ModelCommand {
        .setRatio(
            trackID: trackID,
            oldNum:  snapshotNumerator,  oldDen: snapshotDenominator,
            newNum:  currentNum,         newDen: currentDen
        )
    }
}

// MARK: - StretchCountDragSession

/// Pure value-type session for the `StretchHandleView` step-count-zone vertical drag.
///
/// **Arch-Slice-8 — StretchHandleView migration:**
/// Replaces the `@State` accumulator pattern in `StretchHandleView`.
///
/// **Vertical drag only:** No scroll compensation needed.
///
/// **No accumulator:** `DragGesture.translation.height` (total from drag-start)
/// is passed directly. The session is never mutated during the drag.
struct StretchCountDragSession {

    // MARK: - Identity

    let trackID: UUID

    // MARK: - Snapshot (captured once at drag-start)

    let snapshotStepCount: Int

    // MARK: - Constants

    /// Vertical pixels required to advance one step.
    /// Matches `stepSensitivity = 18` constant in original StretchHandleView.
    static let pxPerStep: CGFloat = 18

    // MARK: - Pure computation

    /// Proposed step count for the given vertical drag translation.
    /// Dragging UP (negative totalY) increases count; DOWN decreases.
    func proposedStepCount(totalY: CGFloat) -> Int {
        let delta = -Int((totalY / Self.pxPerStep).rounded())
        return max(1, min(64, snapshotStepCount + delta))
    }

    // MARK: - Command production

    func commitCommand(currentStepCount: Int) -> ModelCommand {
        .setStepCount(trackID: trackID, old: snapshotStepCount, new: currentStepCount)
    }
}

// MARK: - SessionCursorHint

/// Lightweight cursor intent published by `InteractionController`.
///
/// **No session details leak out.** This enum carries only cursor semantics —
/// which NSCursor family to use. `CursorPolicy` maps it to the concrete
/// `NSCursor`; `CursorController` applies it.
///
/// Updated in every `begin*/commit*/cancel*` method in IC.
/// `CursorController` subscribes via Combine — zero SwiftUI renders triggered.
enum SessionCursorHint: Equatable {
    /// No session active — view-layer hover cursors take effect.
    case none
    /// Horizontal-resize intent: step-count handle drag, ratio handle drag.
    case resizeHorizontal
    /// Vertical-resize intent: pitch drag.
    /// Maps to NSCursor.resizeUpDown in CursorPolicy.
    case resizeVertical
    /// Vertical stretch/adjust intent: stretch ratio drag, stretch count drag.
    /// Maps to CustomCursors.stretchVertical — distinct from resizeVertical
    /// to communicate "height stretch" rather than generic vertical resize.
    case stretchVertical
    /// Selection intent: rubber-band drag.
    case selectRegion
    /// Move/copy intent: step-swap drag.
    /// `CursorPolicy` upgrades to `dragCopy` when Option is held.
    case moveStep
}

// MARK: - ActiveSession

/// The currently active interaction session.
///
/// **Modal invariant** (enforced by InteractionController):
/// at most one case is active at any given time.
enum ActiveSession {
    case handleDrag(HandleDragSession)             // Step-count handle (Arch-Slice-1)
    case ratioDrag(RatioDragSession)               // Ratio handle      (Arch-Slice-2)
    case rubberBand(RubberBandSession)             // Selection drag    (Arch-Slice-3)
    case pitchDrag(PitchDragSession)               // Pitch drag        (Arch-Slice-4)
    case stepSwap(StepSwapSession)                 // Step swap         (Arch-Slice-5)
    case stretchRatioDrag(StretchRatioDragSession) // Stretch ratio     (Arch-Slice-8)
    case stretchCountDrag(StretchCountDragSession) // Stretch count     (Arch-Slice-8)
}
