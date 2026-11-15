import Testing
import Foundation
import CoreGraphics
import AppKit
@testable import VintageSequencer

// MARK: - InteractionArchitectureTests
//
// Tests for the UI interaction architecture (Arch-Slice-1–9 + Cursor/Modifier Phase 1).
//
// Scope:
//   • HandleDragSession      — scroll-compensated step-count (Arch-Slice-7)
//   • RatioDragSession       — scroll-compensated ratio (Arch-Slice-7)
//   • HandleDragLogic        — stepCount + ratioIndex pure functions
//   • RubberBandSession      — selection pure value type (Arch-Slice-3)
//   • PitchDragSession       — per-step pitch-drag pure value type (Arch-Slice-4)
//   • StepSwapSession        — step reorder/copy pure value type (Arch-Slice-5)
//   • StretchRatioDragSession — stretch-handle ratio drag pure value type (Arch-Slice-8)
//   • StretchCountDragSession — stretch-handle count drag pure value type (Arch-Slice-8)
//   • EdgeScrollVelocity     — smoothstep ramp + inset policy (Arch-Slice-7, 9)
//   • ViewportController     — scrollTrackpad, syncFromScrollbar, maxScrollOffset
//                              clamping, session guard, re-entrancy guard (Arch-Slice-6)
//                              + adjustScroll anchor-stable zoom (Arch-Slice-9)
//   • ModelWriter            — setStepCount + setRatio + setPitchNotes + setSteps
//   • InteractionController  — modal invariant, full lifecycle for all 7 session types
//   • CursorStateReducer     — pure ownership state machine (Cursor Phase 2)
//   • CursorPolicy           — pure hint→NSCursor mapping (Cursor Phase 1)
//   • IC.sessionCursorHint   — set in begin* / reset in commit* & cancel* (Cursor Phase 1)
//
// Explicitly NOT tested here:
//   • NSEvent / AppKit input layer (verified manually)
//   • SwiftUI view rendering (snapshot tests — future)
//   • StepGridCoordinator Combine sinks (verified manually; require MainActor)
//   • NativeHScrollbar NSViewRepresentable bridge (AppKit UI — verified manually)
//   • IC-owned edge-scroll Timer (requires RunLoop; verified manually + integration)
//   • CursorController Combine sink, flagsChanged monitor, NotificationCenter observers
//     (AppKit event loop + window required — verified manually)
//   • StretchCursorNSView.resetCursorRects (AppKit cursor rect — verified manually)

// MARK: - HandleDragSession Tests (Arch-Slice-7: scroll-compensated geometry)

struct HandleDragSessionTests {

    // Shared fixture
    let trackID   = UUID()
    let pxPerStep = CGFloat(60)
    let snapshot  = 16

    /// Creates a session. `scrollOffsetAtStart` defaults to 0 (no initial scroll).
    private func makeSession(scrollOffsetAtStart: CGFloat = 0) -> HandleDragSession {
        HandleDragSession(
            trackID:             trackID,
            snapshotStepCount:   snapshot,
            pxPerStep:           pxPerStep,
            scrollOffsetAtStart: scrollOffsetAtStart
        )
    }

    // MARK: — 1. proposedStepCount delegates to HandleDragLogic (no scroll change)

    @Test func proposedStepCount_matchesHandleDragLogic() {
        let session = makeSession()
        // translationX=60, ΔS=0 → contentDisplacement=60 → delta=1 → 16+1=17
        #expect(session.proposedStepCount(translationX: 60, currentScrollOffset: 0) == 17)
    }

    @Test func proposedStepCount_zeroTranslation_returnsSnapshot() {
        let session = makeSession()
        #expect(session.proposedStepCount(translationX: 0, currentScrollOffset: 0) == snapshot)
    }

    @Test func proposedStepCount_negativeTranslation_reducesCount() {
        let session = makeSession()
        // translationX=-60, ΔS=0 → delta=-1 → 16-1=15
        #expect(session.proposedStepCount(translationX: -60, currentScrollOffset: 0) == 15)
    }

    @Test func proposedStepCount_clampsToMinimum() {
        let session = makeSession()
        #expect(session.proposedStepCount(translationX: -100_000, currentScrollOffset: 0) == 1)
    }

    @Test func proposedStepCount_clampsToMaximum() {
        let session = makeSession()
        #expect(session.proposedStepCount(translationX: 100_000, currentScrollOffset: 0) == 64)
    }

    // MARK: — 2. Snapshot is immutable — pure function, no side effects

    @Test func snapshot_isImmutable() {
        let session = makeSession()
        // Multiple calls with different parameters must not change snapshotStepCount
        _ = session.proposedStepCount(translationX: 120, currentScrollOffset: 0)
        #expect(session.snapshotStepCount == snapshot)
        _ = session.proposedStepCount(translationX: -60, currentScrollOffset: 50)
        #expect(session.snapshotStepCount == snapshot)
    }

    // MARK: — 3. Idempotency — same inputs → same result

    @Test func proposedStepCount_isIdempotent() {
        let session = makeSession()
        let first   = session.proposedStepCount(translationX: 75, currentScrollOffset: 0)
        let second  = session.proposedStepCount(translationX: 75, currentScrollOffset: 0)
        let third   = session.proposedStepCount(translationX: 75, currentScrollOffset: 0)
        #expect(first == second)
        #expect(second == third)
    }

    // MARK: — 4. Scroll compensation (Arch-Slice-7) — ΔS makes handle follow pointer

    @Test func proposedStepCount_scrollCompensated_positiveScroll() {
        // scrollOffsetAtStart=0; drag translationX=0; viewport scrolled right by 60 px.
        // Without compensation: proposedStepCount = 16 (no movement).
        // With compensation: contentDisplacement = 0 + (60 - 0) = 60 → +1 step → 17.
        // This is correct: the handle moves right by 60 px in content space to follow the pointer.
        let session = makeSession(scrollOffsetAtStart: 0)
        #expect(session.proposedStepCount(translationX: 0, currentScrollOffset: 60) == 17)
    }

    @Test func proposedStepCount_scrollCompensated_negativeScroll() {
        // scrollOffsetAtStart=100; drag translationX=60; viewport scrolled back to 40.
        // contentDisplacement = 60 + (40 - 100) = 0 → delta=0 → 16.
        // Handle stays at snapshot when scroll exactly cancels translation.
        let session = makeSession(scrollOffsetAtStart: 100)
        #expect(session.proposedStepCount(translationX: 60, currentScrollOffset: 40) == snapshot)
    }

    @Test func proposedStepCount_noScrollChange_equalsPlainTranslation() {
        // When currentScrollOffset == scrollOffsetAtStart, compensation is zero.
        // Behavior must be identical to pre-Arch-Slice-7.
        let session = makeSession(scrollOffsetAtStart: 200)
        #expect(session.proposedStepCount(translationX: 60, currentScrollOffset: 200) == 17)
        #expect(session.proposedStepCount(translationX: 0,  currentScrollOffset: 200) == snapshot)
    }

    // MARK: — 5. commitCommand carries currentStepCount as new

    @Test func commitCommand_usesCurrentStepCount() {
        let session = makeSession()
        let cmd = session.commitCommand(currentStepCount: 18)
        guard case .setStepCount(_, let old, let new) = cmd else {
            Issue.record(Comment("Expected setStepCount command"))
            return
        }
        #expect(old == snapshot)
        #expect(new == 18)
    }
}

// MARK: - HandleDragLogic.ratioIndex Tests

struct HandleDragLogicRatioTests {

    // TrackData.sortedRatios has 13 entries; index 6 = (1,1) = neutral.
    let ratios = TrackData.sortedRatios          // 13 entries
    let neutralIndex = 6                      // (1,1)
    let contentUnit: CGFloat = 1000           // arbitrary unit

    // MARK: — 1. At accumulator=0, result equals baseRatioIndex

    @Test func ratioIndex_zeroAccumulator_returnsBase() {
        let idx = HandleDragLogic.ratioIndex(
            totalX:         0,
            contentUnit:    contentUnit,
            baseRatioIndex: neutralIndex,
            ratios:         ratios
        )
        #expect(idx == neutralIndex)
    }

    // MARK: — 2. Large positive totalX picks the largest ratio

    @Test func ratioIndex_largePositive_picksMaxRatio() {
        let idx = HandleDragLogic.ratioIndex(
            totalX:         1_000_000,
            contentUnit:    contentUnit,
            baseRatioIndex: neutralIndex,
            ratios:         ratios
        )
        // Largest ratio is (2,1) at the last index (12)
        #expect(idx == ratios.count - 1)
    }

    // MARK: — 3. Large negative totalX picks the smallest ratio

    @Test func ratioIndex_largeNegative_picksMinRatio() {
        let idx = HandleDragLogic.ratioIndex(
            totalX:         -1_000_000,
            contentUnit:    contentUnit,
            baseRatioIndex: neutralIndex,
            ratios:         ratios
        )
        // Smallest ratio is (1,2) at index 0
        #expect(idx == 0)
    }

    // MARK: — 4. Idempotency

    @Test func ratioIndex_isIdempotent() {
        let first  = HandleDragLogic.ratioIndex(totalX: 300, contentUnit: contentUnit,
                                                baseRatioIndex: neutralIndex, ratios: ratios)
        let second = HandleDragLogic.ratioIndex(totalX: 300, contentUnit: contentUnit,
                                                baseRatioIndex: neutralIndex, ratios: ratios)
        #expect(first == second)
    }

    // MARK: — 5. Non-neutral base: zero accumulator still returns base

    @Test func ratioIndex_nonNeutralBase_zeroAccumulator_returnsBase() {
        let baseIdx = 3   // (3,4)
        let idx = HandleDragLogic.ratioIndex(
            totalX:         0,
            contentUnit:    contentUnit,
            baseRatioIndex: baseIdx,
            ratios:         ratios
        )
        #expect(idx == baseIdx)
    }
}

// MARK: - RatioDragSession Tests (Arch-Slice-7: scroll-compensated geometry)

struct RatioDragSessionTests {

    // TrackData.sortedRatios[6] = (1,1) — neutral ratio
    let neutralIndex = 6
    let trackID      = UUID()
    let contentUnit: CGFloat = 1000

    /// Creates a session. `scrollOffsetAtStart` defaults to 0.
    private func makeSession(scrollOffsetAtStart: CGFloat = 0,
                             baseIndex: Int = 6) -> RatioDragSession {
        RatioDragSession(
            trackID:             trackID,
            snapshotNumerator:   TrackData.sortedRatios[baseIndex].num,
            snapshotDenominator: TrackData.sortedRatios[baseIndex].den,
            baseRatioIndex:      baseIndex,
            contentUnit:         contentUnit,
            scrollOffsetAtStart: scrollOffsetAtStart
        )
    }

    // MARK: — 1. proposedRatioIndex at zero translation returns base

    @Test func proposedRatioIndex_zeroTranslation_returnsBase() {
        let session = makeSession()
        #expect(session.proposedRatioIndex(translationX: 0, currentScrollOffset: 0) == neutralIndex)
    }

    // MARK: — 2. Large positive translation picks last ratio

    @Test func proposedRatioIndex_largePositive_picksLastRatio() {
        let session = makeSession()
        #expect(session.proposedRatioIndex(translationX: 1_000_000, currentScrollOffset: 0) == TrackData.sortedRatios.count - 1)
    }

    // MARK: — 3. Large negative translation picks first ratio

    @Test func proposedRatioIndex_largeNegative_picksFirstRatio() {
        let session = makeSession()
        #expect(session.proposedRatioIndex(translationX: -1_000_000, currentScrollOffset: 0) == 0)
    }

    // MARK: — 4. Snapshot is immutable — pure function, no side effects

    @Test func snapshot_isImmutable() {
        let session = makeSession(baseIndex: neutralIndex)
        let snapNum = session.snapshotNumerator
        let snapDen = session.snapshotDenominator
        _ = session.proposedRatioIndex(translationX: 500_000, currentScrollOffset: 0)
        #expect(session.snapshotNumerator   == snapNum)
        #expect(session.snapshotDenominator == snapDen)
        _ = session.proposedRatioIndex(translationX: -500_000, currentScrollOffset: 100)
        #expect(session.snapshotNumerator   == snapNum)
        #expect(session.snapshotDenominator == snapDen)
    }

    // MARK: — 5. proposedRatioIndex is idempotent

    @Test func proposedRatioIndex_isIdempotent() {
        let session = makeSession()
        let a = session.proposedRatioIndex(translationX: 350, currentScrollOffset: 0)
        let b = session.proposedRatioIndex(translationX: 350, currentScrollOffset: 0)
        let c = session.proposedRatioIndex(translationX: 350, currentScrollOffset: 0)
        #expect(a == b)
        #expect(b == c)
    }

    // MARK: — 6. Scroll compensation (Arch-Slice-7)

    @Test func proposedRatioIndex_scrollCompensated_scrollEqualsTranslation() {
        // scrollOffsetAtStart=0; translationX=0; currentScrollOffset=1_000_000.
        // contentDisplacement = 0 + 1_000_000 = large → last ratio.
        let session = makeSession(scrollOffsetAtStart: 0)
        #expect(session.proposedRatioIndex(translationX: 0, currentScrollOffset: 1_000_000)
                == TrackData.sortedRatios.count - 1)
    }

    @Test func proposedRatioIndex_noScrollChange_equalsPlainTranslation() {
        // When currentScrollOffset == scrollOffsetAtStart, compensation is zero.
        let session = makeSession(scrollOffsetAtStart: 500)
        let withoutCompensation = session.proposedRatioIndex(translationX: 350, currentScrollOffset: 500)
        let baseline            = makeSession(scrollOffsetAtStart: 0)
                                      .proposedRatioIndex(translationX: 350, currentScrollOffset: 0)
        #expect(withoutCompensation == baseline)
    }

    // MARK: — 7. commitCommand uses the passed current ratio

    @Test func commitCommand_usesCurrentRatio() {
        let session = makeSession()
        let cmd = session.commitCommand(currentNum: 3, currentDen: 2)
        guard case .setRatio(_, let oldNum, let oldDen, let newNum, let newDen) = cmd else {
            Issue.record(Comment("Expected setRatio command"))
            return
        }
        #expect(oldNum == TrackData.sortedRatios[neutralIndex].num)
        #expect(oldDen == TrackData.sortedRatios[neutralIndex].den)
        #expect(newNum == 3)
        #expect(newDen == 2)
    }
}

// MARK: - ViewportController Tests

struct ViewportControllerTests {

    private func makeViewport() -> (ViewportController, ScrollState) {
        let ss = ScrollState()
        let vc = ViewportController(scrollState: ss)
        return (vc, ss)
    }

    // MARK: — 1. scroll(by:) updates scrollState

    @Test func scroll_positiveVelocity_updatesScrollState() {
        let (vc, ss) = makeViewport()
        vc.scroll(by: 100)
        #expect(ss.hScrollOffset == 100)
    }

    @Test func scroll_negativeVelocity_clampsToZero() {
        let (vc, ss) = makeViewport()
        ss.hScrollOffset = 50
        vc.scroll(by: -100)
        #expect(ss.hScrollOffset == 0)
    }

    @Test func scroll_multipleDeltas_accumulate() {
        let (vc, ss) = makeViewport()
        vc.scroll(by: 40)
        vc.scroll(by: 30)
        vc.scroll(by: 20)
        #expect(ss.hScrollOffset == 90)
    }

    // MARK: — 2. Session lifecycle

    @Test func beginSession_setsFlags() {
        let (vc, ss) = makeViewport()
        #expect(vc.sessionActive == false)
        #expect(ss.isAnyHandleDragging == false)
        vc.beginSession()
        #expect(vc.sessionActive == true)
        #expect(ss.isAnyHandleDragging == true)
    }

    @Test func endSession_clearsFlags() {
        let (vc, ss) = makeViewport()
        vc.beginSession()
        vc.endSession()
        #expect(vc.sessionActive == false)
        #expect(ss.isAnyHandleDragging == false)
    }

    @Test func beginSession_isIdempotent() {
        let (vc, ss) = makeViewport()
        vc.beginSession()
        vc.beginSession()   // second call must not cause issues
        #expect(vc.sessionActive == true)
        #expect(ss.isAnyHandleDragging == true)
    }

    @Test func endSession_isIdempotent() {
        let (vc, ss) = makeViewport()
        vc.endSession()     // calling without prior beginSession
        #expect(vc.sessionActive == false)
        #expect(ss.isAnyHandleDragging == false)
    }
}

// MARK: - ModelWriter Tests

struct ModelWriterTests {

    private func makeTrack(stepCount: Int = 16) -> TrackData {
        let t = TrackData(name: "Test")
        t.lane.stepCount = stepCount
        return t
    }

    // MARK: — setStepCount

    @Test func apply_setStepCount_updatesTrack() {
        let track  = makeTrack(stepCount: 16)
        let writer = ModelWriter()
        let cmd    = ModelCommand.setStepCount(trackID: track.id, old: 16, new: 20)
        writer.apply(cmd, to: track)
        #expect(track.lane.stepCount == 20)
    }

    @Test func apply_setStepCount_withoutUndo_noUndoRegistered() {
        let track  = makeTrack()
        let writer = ModelWriter()
        let cmd    = ModelCommand.setStepCount(trackID: track.id, old: 16, new: 8)
        writer.apply(cmd, to: track, undoManager: nil)
        #expect(track.lane.stepCount == 8)
    }

    @Test func apply_restoresSnapshot_onCancel() {
        let track  = makeTrack(stepCount: 20)
        let writer = ModelWriter()
        let cmd = ModelCommand.setStepCount(trackID: track.id, old: 20, new: 16)
        writer.apply(cmd, to: track, undoManager: nil)
        #expect(track.lane.stepCount == 16)
    }

    // MARK: — setRatio

    @Test func apply_setRatio_updatesTrack() {
        let track  = makeTrack()
        track.lane.stepLengthNumerator   = 1
        track.lane.stepLengthDenominator = 1
        let writer = ModelWriter()
        let cmd = ModelCommand.setRatio(trackID: track.id,
                                        oldNum: 1, oldDen: 1,
                                        newNum: 3, newDen: 2)
        writer.apply(cmd, to: track)
        #expect(track.lane.stepLengthNumerator   == 3)
        #expect(track.lane.stepLengthDenominator == 2)
    }

    @Test func apply_setRatio_withoutUndo_noUndoRegistered() {
        let track  = makeTrack()
        let writer = ModelWriter()
        let cmd = ModelCommand.setRatio(trackID: track.id,
                                        oldNum: 1, oldDen: 1,
                                        newNum: 2, newDen: 1)
        writer.apply(cmd, to: track, undoManager: nil)
        #expect(track.lane.stepLengthNumerator   == 2)
        #expect(track.lane.stepLengthDenominator == 1)
    }

    @Test func apply_setRatio_restoresSnapshot_onCancel() {
        let track = makeTrack()
        track.lane.stepLengthNumerator   = 3
        track.lane.stepLengthDenominator = 2
        let writer = ModelWriter()
        let cmd = ModelCommand.setRatio(trackID: track.id,
                                        oldNum: 3, oldDen: 2,
                                        newNum: 1, newDen: 1)
        writer.apply(cmd, to: track, undoManager: nil)
        #expect(track.lane.stepLengthNumerator   == 1)
        #expect(track.lane.stepLengthDenominator == 1)
    }
}

// MARK: - InteractionController Tests

struct InteractionControllerTests {

    private func makeController() -> (InteractionController, TrackData) {
        let ss  = ScrollState()
        let vc  = ViewportController(scrollState: ss)
        let ic  = InteractionController(viewportController: vc)
        let track = TrackData(name: "Test")
        track.lane.stepCount = 16
        return (ic, track)
    }

    // MARK: — 1. Modal invariant: only one session at a time

    @Test func modalInvariant_secondBeginIsIgnored() {
        let (ic, track) = makeController()
        let pxPerStep: CGFloat = 60

        ic.beginHandleDrag(track: track, pxPerStep: pxPerStep)
        guard case .handleDrag(let firstSession) = ic.activeSession else {
            Issue.record(Comment("Expected handleDrag session after first begin"))
            return
        }
        let firstSnapshot = firstSession.snapshotStepCount

        track.lane.stepCount = 20
        ic.beginHandleDrag(track: track, pxPerStep: pxPerStep)

        guard case .handleDrag(let stillFirst) = ic.activeSession else {
            Issue.record(Comment("Expected handleDrag session still active"))
            return
        }
        #expect(stillFirst.snapshotStepCount == firstSnapshot)
    }

    @Test func modalInvariant_ratioDragBlocksCountDrag() {
        let (ic, track) = makeController()
        // Start a ratio drag
        let contentUnit: CGFloat = CGFloat(track.lane.stepCount) * 60
        ic.beginRatioDrag(track: track, contentUnit: contentUnit, baseRatioIndex: 6)
        #expect(ic.isSessionActive == true)

        // Attempt to start a count drag — must be ignored
        ic.beginHandleDrag(track: track, pxPerStep: 60)
        // Must still be ratioDrag
        guard case .ratioDrag = ic.activeSession else {
            Issue.record(Comment("Expected ratioDrag session to survive modal check"))
            return
        }
    }

    @Test func modalInvariant_countDragBlocksRatioDrag() {
        let (ic, track) = makeController()
        ic.beginHandleDrag(track: track, pxPerStep: 60)
        #expect(ic.isSessionActive == true)

        // Attempt to start a ratio drag — must be ignored
        ic.beginRatioDrag(track: track, contentUnit: 960, baseRatioIndex: 6)
        // Must still be handleDrag
        guard case .handleDrag = ic.activeSession else {
            Issue.record(Comment("Expected handleDrag session to survive modal check"))
            return
        }
    }

    // MARK: — 2. beginHandleDrag captures snapshot

    @Test func beginHandleDrag_capturesStepCountSnapshot() {
        let (ic, track) = makeController()
        track.lane.stepCount = 12
        ic.beginHandleDrag(track: track, pxPerStep: 60)

        guard case .handleDrag(let session) = ic.activeSession else {
            Issue.record(Comment("Expected handleDrag session"))
            return
        }
        #expect(session.snapshotStepCount == 12)
        #expect(session.trackID == track.id)
    }

    // MARK: — 3. updateHandleDrag applies model change

    @Test func updateHandleDrag_appliesProposedStepCount() {
        let (ic, track) = makeController()
        track.lane.stepCount = 16
        ic.beginHandleDrag(track: track, pxPerStep: 60)
        // totalX = 60 → delta = 1 → new count = 17
        ic.updateHandleDrag(totalX: 60, track: track)
        #expect(track.lane.stepCount == 17)
    }

    @Test func updateHandleDrag_doesNotApplyIfValueUnchanged() {
        let (ic, track) = makeController()
        track.lane.stepCount = 16
        ic.beginHandleDrag(track: track, pxPerStep: 60)
        track.lane.stepCount = 16
        ic.updateHandleDrag(totalX: 0, track: track)
        #expect(track.lane.stepCount == 16)   // no spurious change
    }

    // MARK: — 4. commitHandleDrag ends session

    @Test func commitHandleDrag_clearsActiveSession() {
        let (ic, track) = makeController()
        ic.beginHandleDrag(track: track, pxPerStep: 60)
        ic.commitHandleDrag(track: track, undoManager: nil)
        #expect(ic.activeSession == nil)
        #expect(ic.isSessionActive == false)
    }

    @Test func commitHandleDrag_releasesViewportSession() {
        let ss  = ScrollState()
        let vc  = ViewportController(scrollState: ss)
        let ic  = InteractionController(viewportController: vc)
        let track = TrackData(name: "Test")
        track.lane.stepCount = 16

        ic.beginHandleDrag(track: track, pxPerStep: 60)
        #expect(vc.sessionActive == true)
        #expect(ss.isAnyHandleDragging == true)

        ic.commitHandleDrag(track: track, undoManager: nil)
        #expect(vc.sessionActive == false)
        #expect(ss.isAnyHandleDragging == false)
    }

    // MARK: — 5. cancelHandleDrag restores snapshot

    @Test func cancelHandleDrag_restoresSnapshotAndClearsSession() {
        let (ic, track) = makeController()
        track.lane.stepCount = 16
        ic.beginHandleDrag(track: track, pxPerStep: 60)
        ic.updateHandleDrag(totalX: 120, track: track)   // count = 18
        #expect(track.lane.stepCount == 18)

        ic.cancelHandleDrag(track: track)
        #expect(track.lane.stepCount == 16)   // restored to snapshot
        #expect(ic.activeSession == nil)
        #expect(ic.isSessionActive == false)
    }

    // MARK: — 6. applyEdgeScroll routes through viewport

    @Test func applyEdgeScroll_updatesScrollStateViaViewport() {
        let ss  = ScrollState()
        let vc  = ViewportController(scrollState: ss)
        let ic  = InteractionController(viewportController: vc)
        let track = TrackData(name: "Test")
        track.lane.stepCount = 16

        ic.beginHandleDrag(track: track, pxPerStep: 60)
        ss.hScrollOffset = 100
        ic.applyEdgeScroll(velocity: 14)
        #expect(ss.hScrollOffset == 114)
    }

    @Test func applyEdgeScroll_noOp_whenNoSession() {
        let ss  = ScrollState()
        let vc  = ViewportController(scrollState: ss)
        let ic  = InteractionController(viewportController: vc)
        ss.hScrollOffset = 100
        ic.applyEdgeScroll(velocity: 14)
        #expect(ss.hScrollOffset == 100)   // unchanged — no active session
    }

    // MARK: — 7. isSessionActive reflects begin/commit lifecycle

    @Test func isSessionActive_trueAfterBegin_falseAfterCommit() {
        let (ic, track) = makeController()
        #expect(ic.isSessionActive == false)
        ic.beginHandleDrag(track: track, pxPerStep: 60)
        #expect(ic.isSessionActive == true)
        ic.commitHandleDrag(track: track, undoManager: nil)
        #expect(ic.isSessionActive == false)
    }

    // MARK: — 8. New count session possible after commit

    @Test func newSession_possibleAfterCommit() {
        let (ic, track) = makeController()
        ic.beginHandleDrag(track: track, pxPerStep: 60)
        ic.commitHandleDrag(track: track, undoManager: nil)
        track.lane.stepCount = 20
        ic.beginHandleDrag(track: track, pxPerStep: 60)
        guard case .handleDrag(let session) = ic.activeSession else {
            Issue.record(Comment("Expected a new handleDrag session after commit"))
            return
        }
        #expect(session.snapshotStepCount == 20)
    }

    // MARK: — 9. Ratio drag: beginRatioDrag captures snapshot

    @Test func beginRatioDrag_capturesRatioSnapshot() {
        let (ic, track) = makeController()
        track.lane.stepLengthNumerator   = 3
        track.lane.stepLengthDenominator = 2
        let contentUnit = CGFloat(track.lane.stepCount) * 60
        ic.beginRatioDrag(track: track, contentUnit: contentUnit, baseRatioIndex: 10)

        guard case .ratioDrag(let session) = ic.activeSession else {
            Issue.record(Comment("Expected ratioDrag session"))
            return
        }
        #expect(session.snapshotNumerator   == 3)
        #expect(session.snapshotDenominator == 2)
        #expect(session.baseRatioIndex      == 10)
        #expect(session.trackID             == track.id)
    }

    // MARK: — 10. Ratio drag: updateRatioDrag applies ratio change

    @Test func updateRatioDrag_appliesProposedRatio() {
        let (ic, track) = makeController()
        // Start from neutral (1,1) at index 6
        track.lane.stepLengthNumerator   = 1
        track.lane.stepLengthDenominator = 1
        let contentUnit: CGFloat = 1000
        ic.beginRatioDrag(track: track, contentUnit: contentUnit, baseRatioIndex: 6)

        // Large positive drag → longest length (v1.18.29: lange Steps, 8 Takte = 128/1)
        ic.updateRatioDrag(totalX: 1_000_000, track: track)
        #expect(track.lane.stepLengthNumerator   == 128)
        #expect(track.lane.stepLengthDenominator == 1)
    }

    // MARK: — 11. Ratio drag: commitRatioDrag ends session

    @Test func commitRatioDrag_clearsActiveSession() {
        let (ic, track) = makeController()
        track.lane.stepLengthNumerator   = 1
        track.lane.stepLengthDenominator = 1
        ic.beginRatioDrag(track: track, contentUnit: 960, baseRatioIndex: 6)
        ic.commitRatioDrag(track: track, undoManager: nil)
        #expect(ic.activeSession == nil)
        #expect(ic.isSessionActive == false)
    }

    @Test func commitRatioDrag_releasesViewportSession() {
        let ss  = ScrollState()
        let vc  = ViewportController(scrollState: ss)
        let ic  = InteractionController(viewportController: vc)
        let track = TrackData(name: "Test")
        track.lane.stepLengthNumerator   = 1
        track.lane.stepLengthDenominator = 1

        ic.beginRatioDrag(track: track, contentUnit: 960, baseRatioIndex: 6)
        #expect(vc.sessionActive         == true)
        #expect(ss.isAnyHandleDragging   == true)

        ic.commitRatioDrag(track: track, undoManager: nil)
        #expect(vc.sessionActive         == false)
        #expect(ss.isAnyHandleDragging   == false)
    }

    // MARK: — 12. Ratio drag: cancelRatioDrag restores snapshot

    @Test func cancelRatioDrag_restoresSnapshotAndClearsSession() {
        let (ic, track) = makeController()
        track.lane.stepLengthNumerator   = 1
        track.lane.stepLengthDenominator = 1
        let contentUnit: CGFloat = 1000
        ic.beginRatioDrag(track: track, contentUnit: contentUnit, baseRatioIndex: 6)

        // Drag to large ratio
        ic.updateRatioDrag(totalX: 1_000_000, track: track)
        #expect(track.lane.stepLengthNumerator == 128)

        ic.cancelRatioDrag(track: track)
        #expect(track.lane.stepLengthNumerator   == 1)   // restored
        #expect(track.lane.stepLengthDenominator == 1)
        #expect(ic.activeSession == nil)
        #expect(ic.isSessionActive == false)
    }

    // MARK: — 13. New ratio session possible after commit

    @Test func newRatioSession_possibleAfterCommit() {
        let (ic, track) = makeController()
        track.lane.stepLengthNumerator   = 1
        track.lane.stepLengthDenominator = 1
        ic.beginRatioDrag(track: track, contentUnit: 960, baseRatioIndex: 6)
        ic.commitRatioDrag(track: track, undoManager: nil)

        // Start a second ratio session
        track.lane.stepLengthNumerator   = 3
        track.lane.stepLengthDenominator = 2
        ic.beginRatioDrag(track: track, contentUnit: 960, baseRatioIndex: 10)
        guard case .ratioDrag(let session) = ic.activeSession else {
            Issue.record(Comment("Expected a new ratioDrag session after commit"))
            return
        }
        #expect(session.snapshotNumerator   == 3)
        #expect(session.snapshotDenominator == 2)
    }

    // MARK: — 14. applyEdgeScroll works during ratio drag too

    @Test func applyEdgeScroll_worksDuringRatioDrag() {
        let ss  = ScrollState()
        let vc  = ViewportController(scrollState: ss)
        let ic  = InteractionController(viewportController: vc)
        let track = TrackData(name: "Test")
        track.lane.stepLengthNumerator   = 1
        track.lane.stepLengthDenominator = 1

        ic.beginRatioDrag(track: track, contentUnit: 960, baseRatioIndex: 6)
        ss.hScrollOffset = 200
        ic.applyEdgeScroll(velocity: 20)
        #expect(ss.hScrollOffset == 220)
    }

    // MARK: — Fast-drag model-staleness fix (Arch-Slice-9 regression)
    //
    // Verifies the math that `HandleNSView.startEdgeScrollTimer` now exploits:
    // when the pointer is STATIONARY at the edge, calling `updateHandleDrag` with
    // the same `totalX` but an increased `scrollOffset` correctly advances the model.
    // The bug: without the timer's `onDrag?()` call, the model froze.

    @Test func updateHandleDrag_stationaryPointer_scrollIncreases_advancesStepCount() {
        // Setup: 16-step track, pxPerStep=60, scrollOffset starts at 0.
        let ss    = ScrollState()
        let vc    = ViewportController(scrollState: ss)
        let ic    = InteractionController(viewportController: vc)
        let track = TrackData(name: "FastDrag")
        track.lane.stepCount = 16

        ic.beginHandleDrag(track: track, pxPerStep: 60)

        // Phase 1: pointer moves 60 px right → +1 step
        ic.updateHandleDrag(totalX: 60, track: track)
        #expect(track.lane.stepCount == 17)

        // Phase 2: pointer STATIONARY (totalX still 60), auto-scroll adds 60 px.
        // contentDisplacement = 60 + (60 − 0) = 120 → +2 steps from snapshot(16) → 18.
        ss.hScrollOffset = 60
        ic.updateHandleDrag(totalX: 60, track: track)
        #expect(track.lane.stepCount == 18)

        // Phase 3: scroll adds another 60 px (total 120), pointer still at 60.
        // contentDisplacement = 60 + (120 − 0) = 180 → +3 steps → 19.
        ss.hScrollOffset = 120
        ic.updateHandleDrag(totalX: 60, track: track)
        #expect(track.lane.stepCount == 19)

        ic.commitHandleDrag(track: track, undoManager: nil)
        #expect(ic.activeSession == nil)
    }

    @Test func updateHandleDrag_scrollWithoutPointerMove_isIdempotentAtMax() {
        // Once stepCount hits the maximum (64), further scroll+update calls must
        // not crash or produce out-of-range values.
        let ss    = ScrollState()
        let vc    = ViewportController(scrollState: ss)
        let ic    = InteractionController(viewportController: vc)
        let track = TrackData(name: "MaxTest")
        track.lane.stepCount = 64   // already at max

        ic.beginHandleDrag(track: track, pxPerStep: 60)

        // Large totalX + large scroll → still clamped at 64
        ss.hScrollOffset = 10_000
        ic.updateHandleDrag(totalX: 10_000, track: track)
        #expect(track.lane.stepCount == 64)

        ic.commitHandleDrag(track: track, undoManager: nil)
    }
}

// MARK: - RubberBandSession Tests

struct RubberBandSessionTests {

    // Shared fixture: 16 steps, 60 px each (incl. spacing)
    let trackID:   UUID      = UUID()
    let stepWidth: CGFloat   = 60    // step slot width (= stretchedStepWidth + stepSpacing)
    let stepCount: Int       = 16

    private func makeSession(
        anchorX:  CGFloat = 0,
        currentX: CGFloat = 0,
        screenX:  CGFloat = 0
    ) -> RubberBandSession {
        var s = RubberBandSession(
            trackID:         trackID,
            anchorContentX:  anchorX,
            anchorY:         0,
            currentContentX: currentX,
            currentY:        0,
            currentScreenX:  screenX,
            stepWidth:       stepWidth,
            stepCount:       stepCount
        )
        return s
    }

    // MARK: — 1. Zero-width rubber band selects nothing

    @Test func selectedSteps_zeroWidth_isEmpty() {
        let session = makeSession(anchorX: 100, currentX: 100)
        // anchor == current → width 0 → after padding subtraction, no steps
        #expect(session.selectedSteps().isEmpty)
    }

    // MARK: — 2. Left-to-right selection

    @Test func selectedSteps_leftToRight_correctRange() {
        // anchor at content 8 (just inside step 0: 0-60 px),
        // current at content 188 (step 3: 180-240 px)
        // After padding (8 px): lo = 0, hi = 180 → steps 0..2 (≤ Int(180/60) = 3, but Int(180/60)=3)
        // lo = min(8,188) - 8 = 0, hi = max(8,188) - 8 = 180
        // s = max(0, Int(0/60)) = 0, e = min(15, Int(180/60)) = min(15,3) = 3
        let session = makeSession(anchorX: 8, currentX: 188)
        let selected = session.selectedSteps()
        #expect(selected == Set([0, 1, 2, 3]))
    }

    // MARK: — 3. Right-to-left selection (reverse drag)

    @Test func selectedSteps_rightToLeft_correctRange() {
        // Same range as above, but anchor > current
        let session = makeSession(anchorX: 188, currentX: 8)
        let selected = session.selectedSteps()
        #expect(selected == Set([0, 1, 2, 3]))
    }

    // MARK: — 4. Clamp to valid step range (lower bound)

    @Test func selectedSteps_clampsToZero() {
        // anchor at negative content, current at step 0
        let session = makeSession(anchorX: -200, currentX: 70)
        let selected = session.selectedSteps()
        #expect(selected.min() == 0)
        // Clamps: s = max(0, Int((-208)/60)) = 0
    }

    // MARK: — 5. Clamp to valid step range (upper bound)

    @Test func selectedSteps_clampsToLastStep() {
        // current way beyond last step
        let session = makeSession(anchorX: 0, currentX: 10_000)
        let selected = session.selectedSteps()
        #expect(selected.max() == stepCount - 1)
    }

    // MARK: — 6. Single step selection

    @Test func selectedSteps_singleStep() {
        // Step 5: content 300-360; anchor and current both inside step 5
        let session = makeSession(anchorX: 310, currentX: 350)
        let selected = session.selectedSteps()
        // lo = 310 - 8 = 302, hi = 350 - 8 = 342
        // s = Int(302/60) = 5, e = Int(342/60) = 5
        #expect(selected == Set([5]))
    }

    // MARK: — 7. All steps selected

    @Test func selectedSteps_fullContent_selectsAll() {
        let totalContent = CGFloat(stepCount) * stepWidth + 8   // just past last step + padding
        let session = makeSession(anchorX: 8, currentX: totalContent)
        let selected = session.selectedSteps()
        #expect(selected.count == stepCount)
        #expect(selected.min() == 0)
        #expect(selected.max() == stepCount - 1)
    }

    // MARK: — 8. Idempotency

    @Test func selectedSteps_isIdempotent() {
        let session = makeSession(anchorX: 50, currentX: 350)
        let a = session.selectedSteps()
        let b = session.selectedSteps()
        let c = session.selectedSteps()
        #expect(a == b)
        #expect(b == c)
    }

    // MARK: — 9. Snapshot fields never change through live updates

    @Test func anchor_neverChanges_throughCurrentUpdates() {
        var session = makeSession(anchorX: 100, currentX: 100)
        let originalAnchor = session.anchorContentX
        session.currentContentX = 500
        #expect(session.anchorContentX == originalAnchor)
        session.currentContentX = 0
        #expect(session.anchorContentX == originalAnchor)
    }

    // MARK: — 10. Zero stepWidth guard (no crash)

    @Test func selectedSteps_zeroStepWidth_isEmpty() {
        var s = RubberBandSession(
            trackID: trackID,
            anchorContentX: 0, anchorY: 0,
            currentContentX: 500, currentY: 0,
            currentScreenX: 0,
            stepWidth: 0,   // degenerate — must not crash or divide by zero
            stepCount: 16
        )
        #expect(s.selectedSteps().isEmpty)
    }
}

// MARK: - InteractionController Rubber Band Tests

struct InteractionControllerRubberBandTests {

    private func makeIC() -> (InteractionController, ScrollState) {
        let ss  = ScrollState()
        let vc  = ViewportController(scrollState: ss)
        let ic  = InteractionController(viewportController: vc)
        return (ic, ss)
    }

    private func makeTrack() -> TrackData {
        let t = TrackData(name: "Test")
        t.lane.stepCount = 16
        return t
    }

    // Helper — step width for 16 steps, ratio 1:1, stepWidthSize 60
    private let stepW: CGFloat = 60 + VintageTheme.stepSpacing

    // MARK: — 1. beginRubberBand starts session + sets isSessionActive

    @Test func beginRubberBand_startsSession() {
        let (ic, _) = makeIC()
        ic.beginRubberBand(
            trackID: UUID(), contentX: 0, screenX: 0, y: 0,
            stepWidth: stepW, stepCount: 16
        )
        guard case .rubberBand = ic.activeSession else {
            Issue.record(Comment("Expected rubberBand session"))
            return
        }
        #expect(ic.isSessionActive == true)
    }

    // MARK: — 2. beginRubberBand publishes initial .active update

    @Test func beginRubberBand_publishesActiveUpdate() {
        let (ic, _) = makeIC()
        let trackID = UUID()
        ic.beginRubberBand(
            trackID: trackID, contentX: 100, screenX: 100, y: 0,
            stepWidth: stepW, stepCount: 16
        )
        guard let upd = ic.rubberBandUpdate else {
            Issue.record(Comment("Expected rubberBandUpdate to be non-nil after begin"))
            return
        }
        #expect(upd.trackID == trackID)
        #expect(upd.anchorContentX == 100)
        #expect(upd.currentContentX == 100)
        #expect(upd.phase == .active)
    }

    // MARK: — 3. updateRubberBand moves current position

    @Test func updateRubberBand_movesCurrentPosition() {
        let (ic, _) = makeIC()
        let trackID = UUID()
        ic.beginRubberBand(
            trackID: trackID, contentX: 0, screenX: 0, y: 0,
            stepWidth: stepW, stepCount: 16
        )
        ic.updateRubberBand(contentX: 300, screenX: 300, y: 0)

        guard let upd = ic.rubberBandUpdate else {
            Issue.record(Comment("Expected update after updateRubberBand"))
            return
        }
        #expect(upd.anchorContentX  == 0)
        #expect(upd.currentContentX == 300)
        #expect(upd.phase == .active)
    }

    // MARK: — 4. updateRubberBand computes correct selection

    @Test func updateRubberBand_computesSelection() {
        let (ic, _) = makeIC()
        // Anchor at content 8, current at content 188 → steps 0..3
        let trackID = UUID()
        ic.beginRubberBand(
            trackID: trackID, contentX: 8, screenX: 8, y: 0,
            stepWidth: CGFloat(60), stepCount: 16
        )
        ic.updateRubberBand(contentX: 188, screenX: 188, y: 0)

        guard let upd = ic.rubberBandUpdate else {
            Issue.record(Comment("Expected update"))
            return
        }
        #expect(upd.selectedSteps == Set([0, 1, 2, 3]))
    }

    // MARK: — 5. commitRubberBand ends session + publishes .committed

    @Test func commitRubberBand_publishesCommitted() {
        let (ic, _) = makeIC()
        ic.beginRubberBand(
            trackID: UUID(), contentX: 0, screenX: 0, y: 0,
            stepWidth: stepW, stepCount: 16
        )
        ic.updateRubberBand(contentX: 300, screenX: 300, y: 0)
        ic.commitRubberBand()

        guard let upd = ic.rubberBandUpdate else {
            Issue.record(Comment("Expected rubberBandUpdate to remain after commit"))
            return
        }
        #expect(upd.phase == .committed)
        #expect(ic.activeSession == nil)
        #expect(ic.isSessionActive == false)
    }

    // MARK: — 6. cancelRubberBand ends session + publishes .cancelled with empty steps

    @Test func cancelRubberBand_publishesCancelled_withEmptySteps() {
        let (ic, _) = makeIC()
        ic.beginRubberBand(
            trackID: UUID(), contentX: 8, screenX: 8, y: 0,
            stepWidth: CGFloat(60), stepCount: 16
        )
        ic.updateRubberBand(contentX: 188, screenX: 188, y: 0)
        // At this point selection is non-empty (steps 0..3)

        ic.cancelRubberBand()

        guard let upd = ic.rubberBandUpdate else {
            Issue.record(Comment("Expected rubberBandUpdate after cancel"))
            return
        }
        #expect(upd.phase == .cancelled)
        #expect(upd.selectedSteps.isEmpty)
        #expect(ic.activeSession == nil)
        #expect(ic.isSessionActive == false)
    }

    // MARK: — 7. Modal invariant: rubber band blocks handle drag

    @Test func modalInvariant_rubberBandBlocksHandleDrag() {
        let (ic, _) = makeIC()
        let track = makeTrack()
        ic.beginRubberBand(
            trackID: track.id, contentX: 0, screenX: 0, y: 0,
            stepWidth: stepW, stepCount: 16
        )
        // Attempt to start handle drag while rubber band is active
        ic.beginHandleDrag(track: track, pxPerStep: 60)
        // Must still be rubberBand
        guard case .rubberBand = ic.activeSession else {
            Issue.record(Comment("Expected rubber band to survive modal check"))
            return
        }
    }

    // MARK: — 8. Modal invariant: handle drag blocks rubber band

    @Test func modalInvariant_handleDragBlocksRubberBand() {
        let (ic, _) = makeIC()
        let track = makeTrack()
        ic.beginHandleDrag(track: track, pxPerStep: 60)
        // Attempt to start rubber band while handle drag is active
        ic.beginRubberBand(
            trackID: track.id, contentX: 0, screenX: 0, y: 0,
            stepWidth: stepW, stepCount: 16
        )
        // Must still be handleDrag
        guard case .handleDrag = ic.activeSession else {
            Issue.record(Comment("Expected handleDrag to survive modal check"))
            return
        }
    }

    // MARK: — 9. Viewport session locked during rubber band

    @Test func rubberBand_locksViewportSession() {
        let ss  = ScrollState()
        let vc  = ViewportController(scrollState: ss)
        let ic  = InteractionController(viewportController: vc)
        ic.beginRubberBand(
            trackID: UUID(), contentX: 0, screenX: 0, y: 0,
            stepWidth: 60, stepCount: 16
        )
        #expect(vc.sessionActive         == true)
        #expect(ss.isAnyHandleDragging   == true)

        ic.commitRubberBand()
        #expect(vc.sessionActive         == false)
        #expect(ss.isAnyHandleDragging   == false)
    }

    // MARK: — 10. applyEdgeScroll works during rubber band

    @Test func applyEdgeScroll_worksDuringRubberBand() {
        let (ic, ss) = makeIC()
        ss.hScrollOffset = 100
        ic.beginRubberBand(
            trackID: UUID(), contentX: 0, screenX: 0, y: 0,
            stepWidth: 60, stepCount: 16
        )
        ic.applyEdgeScroll(velocity: 30)
        #expect(ss.hScrollOffset == 130)
    }

    // MARK: — 11. New session possible after commit

    @Test func newRubberBand_possibleAfterCommit() {
        let (ic, _) = makeIC()
        let trackID = UUID()
        ic.beginRubberBand(
            trackID: trackID, contentX: 0, screenX: 0, y: 0,
            stepWidth: 60, stepCount: 16
        )
        ic.commitRubberBand()

        // Start a second rubber band session
        ic.beginRubberBand(
            trackID: trackID, contentX: 100, screenX: 100, y: 0,
            stepWidth: 60, stepCount: 16
        )
        guard case .rubberBand(let session) = ic.activeSession else {
            Issue.record(Comment("Expected new rubberBand session after commit"))
            return
        }
        #expect(session.anchorContentX == 100)
    }

    // MARK: — 12. Committed update has correct selection (not empty)

    @Test func commitRubberBand_keepsSelection() {
        let (ic, _) = makeIC()
        ic.beginRubberBand(
            trackID: UUID(), contentX: 8, screenX: 8, y: 0,
            stepWidth: CGFloat(60), stepCount: 16
        )
        ic.updateRubberBand(contentX: 188, screenX: 188, y: 0)
        let expectedSteps = Set([0, 1, 2, 3])

        ic.commitRubberBand()
        guard let upd = ic.rubberBandUpdate else {
            Issue.record(Comment("Expected update after commit"))
            return
        }
        #expect(upd.phase == .committed)
        #expect(upd.selectedSteps == expectedSteps)
    }

    // MARK: — 13. cancelRubberBand is a no-op if no session active

    @Test func cancelRubberBand_noOp_whenNoSession() {
        let (ic, _) = makeIC()
        let prevUpdate = ic.rubberBandUpdate
        ic.cancelRubberBand()   // no active session — must not crash
        #expect(ic.activeSession == nil)
    }
}

// MARK: - PitchDragSession Tests

struct PitchDragSessionTests {

    /// Returns a Track with known notes at step 0, plus the session created from it.
    private func makeSession(notes: [Int] = [60, 64, 67]) -> (PitchDragSession, TrackData) {
        let track = TrackData(name: "Test")
        var steps = track.lane.steps
        steps[0].notes = notes
        track.lane.steps = steps
        let session = PitchDragSession(
            trackID:       track.id,
            stepsSnapshot: track.lane.steps,
            stepIndex:     0
        )
        return (session, track)
    }

    // MARK: — 1. semitones: zero Y → zero offset

    @Test func semitones_zeroY_isZero() {
        let (session, _) = makeSession()
        #expect(session.semitones(totalY: 0) == 0)
    }

    // MARK: — 2. semitones: drag up (negative Y) → positive semitones

    @Test func semitones_negativeY_raisesNotes() {
        let (session, _) = makeSession()
        // -4 px / 4 pxPerSemitone = +1 semitone
        #expect(session.semitones(totalY: -4) == 1)
        // -16 px → +4 semitones
        #expect(session.semitones(totalY: -16) == 4)
    }

    // MARK: — 3. semitones: drag down (positive Y) → negative semitones

    @Test func semitones_positiveY_lowersNotes() {
        let (session, _) = makeSession()
        // +8 px → -2 semitones
        #expect(session.semitones(totalY: 8) == -2)
    }

    // MARK: — 4. proposedNotes: simple shift

    @Test func proposedNotes_shiftChord() {
        let (session, _) = makeSession(notes: [60, 64, 67])
        // -8 px → +2 semitones → [62, 66, 69]
        #expect(session.proposedNotes(totalY: -8) == [62, 66, 69])
    }

    // MARK: — 5. proposedNotes: clamps to 0

    @Test func proposedNotes_clampsToMinimum() {
        let (session, _) = makeSession(notes: [2])
        // Large downward drag → note can't go below 0
        #expect(session.proposedNotes(totalY: 10000) == [0])
    }

    // MARK: — 6. proposedNotes: clamps to 127

    @Test func proposedNotes_clampsToMaximum() {
        let (session, _) = makeSession(notes: [125])
        // Large upward drag → note can't exceed 127
        #expect(session.proposedNotes(totalY: -10000) == [127])
    }

    // MARK: — 7. stepsSnapshot is immutable (baseNotes unchanged by external track mutation)

    @Test func stepsSnapshot_immutableAfterTrackChange() {
        let (session, track) = makeSession(notes: [60])
        // Mutate the track externally
        var steps = track.lane.steps
        steps[0].notes = [72]
        track.lane.steps = steps
        // Session snapshot must still reflect the original notes
        #expect(session.baseNotes == [60])
        #expect(session.stepsSnapshot[0].notes == [60])
    }

    // MARK: — 8. lastAppliedSemitones starts nil

    @Test func lastAppliedSemitones_initiallyNil() {
        let (session, _) = makeSession()
        #expect(session.lastAppliedSemitones == nil)
    }

    // MARK: — 9. zero translation: proposedNotes equals baseNotes

    @Test func proposedNotes_zeroTranslation_equalsBaseNotes() {
        let (session, _) = makeSession(notes: [60, 64])
        #expect(session.proposedNotes(totalY: 0) == [60, 64])
    }
}

// MARK: - StepSwapSession Tests

struct StepSwapSessionTests {

    private func makeSession(
        sourceIndex: Int = 2,
        targetIndex: Int = 2,
        stepWidth:   CGFloat = 60,
        notes:       [[Int]] = []
    ) -> (StepSwapSession, TrackData) {
        let track = TrackData(name: "Test")
        if !notes.isEmpty {
            var steps = track.lane.steps
            for (idx, n) in notes.enumerated() where idx < steps.count {
                steps[idx].notes = n
            }
            track.lane.steps = steps
        }
        let session = StepSwapSession(
            trackID:       track.id,
            stepsSnapshot: track.lane.steps,
            sourceIndex:   sourceIndex,
            stepWidth:     stepWidth,
            targetIndex:   targetIndex
        )
        return (session, track)
    }

    // MARK: — 1. proposedTargetIndex: no movement → sourceIndex

    @Test func proposedTarget_noMovement_equalsSource() {
        let (session, _) = makeSession(sourceIndex: 3)
        #expect(session.proposedTargetIndex(translationX: 0) == 3)
    }

    // MARK: — 2. proposedTargetIndex: rightward movement

    @Test func proposedTarget_rightward() {
        let (session, _) = makeSession(sourceIndex: 2, stepWidth: 60)
        // 180 px / 60 px = delta 3 → target = 2 + 3 = 5
        #expect(session.proposedTargetIndex(translationX: 180) == 5)
    }

    // MARK: — 3. proposedTargetIndex: leftward movement

    @Test func proposedTarget_leftward() {
        let (session, _) = makeSession(sourceIndex: 4, stepWidth: 60)
        // -120 px / 60 px = delta -2 → target = 4 - 2 = 2
        #expect(session.proposedTargetIndex(translationX: -120) == 2)
    }

    // MARK: — 4. proposedTargetIndex: clamps to 0

    @Test func proposedTarget_clampsToZero() {
        let (session, _) = makeSession(sourceIndex: 2, stepWidth: 60)
        #expect(session.proposedTargetIndex(translationX: -100_000) == 0)
    }

    // MARK: — 5. proposedTargetIndex: clamps to stepCount − 1

    @Test func proposedTarget_clampsToMax() {
        let (session, _) = makeSession(sourceIndex: 2, stepWidth: 60)
        // stepCount is track.lane.steps.count (likely 16 or 64 by default)
        let max = session.stepCount - 1
        #expect(session.proposedTargetIndex(translationX: 100_000) == max)
    }

    // MARK: — 6. stepCount derived from snapshot

    @Test func stepCount_derivedFromSnapshot() {
        let track = TrackData(name: "Test")
        let session = StepSwapSession(
            trackID: track.id, stepsSnapshot: track.lane.steps,
            sourceIndex: 0, stepWidth: 60, targetIndex: 0
        )
        #expect(session.stepCount == track.lane.steps.count)
    }

    // MARK: — 7. commitCommand(swap): steps are exchanged

    @Test func commitCommand_swap_exchangesSteps() {
        var (session, track) = makeSession(
            sourceIndex: 1,
            targetIndex: 1,
            notes: [[60], [67], [72], [55]]   // indices 0-3
        )
        session.targetIndex = 3
        let cmd = session.commitCommand(isCopy: false)
        guard case let .setSteps(_, _, newSteps, _) = cmd else {
            Issue.record(Comment("Expected .setSteps command"))
            return
        }
        // Steps 1 and 3 should be swapped
        #expect(newSteps[1].notes == [55])   // was index 3
        #expect(newSteps[3].notes == [67])   // was index 1
        // Other steps unchanged
        #expect(newSteps[0].notes == [60])
        #expect(newSteps[2].notes == [72])
    }

    // MARK: — 8. commitCommand(copy): source is duplicated at target

    @Test func commitCommand_copy_duplicatesSource() {
        var (session, _) = makeSession(
            sourceIndex: 0,
            targetIndex: 0,
            notes: [[60], [67], [72]]
        )
        session.targetIndex = 2
        let cmd = session.commitCommand(isCopy: true)
        guard case let .setSteps(_, _, newSteps, _) = cmd else {
            Issue.record(Comment("Expected .setSteps command"))
            return
        }
        // Step 2 should be a copy of step 0; step 0 is unchanged
        #expect(newSteps[0].notes == [60])
        #expect(newSteps[2].notes == [60])   // copy of source
        #expect(newSteps[1].notes == [67])   // untouched
    }

    // MARK: — 9. commitCommand preserves snapshot (snapshot itself unchanged)

    @Test func commitCommand_snapshotIsImmutable() {
        var (session, _) = makeSession(
            sourceIndex: 0,
            targetIndex: 0,
            notes: [[60], [67]]
        )
        session.targetIndex = 1
        let snapshotBefore = session.stepsSnapshot
        _ = session.commitCommand(isCopy: false)
        // snapshot must remain unchanged after producing a command
        #expect(session.stepsSnapshot[0].notes == snapshotBefore[0].notes)
        #expect(session.stepsSnapshot[1].notes == snapshotBefore[1].notes)
    }
}

// MARK: - ModelWriter Pitch + Swap Tests

struct ModelWriterPitchSwapTests {

    private let writer = ModelWriter()

    // MARK: — 1. setPitchNotes: new notes applied

    @Test func setPitchNotes_appliesNewNotes() {
        let track = TrackData(name: "Test")
        var steps = track.lane.steps
        steps[2].notes = [60]
        track.lane.steps = steps

        writer.apply(
            .setPitchNotes(trackID: track.id, stepIndex: 2, oldNotes: [60], newNotes: [65]),
            to: track, undoManager: nil
        )
        #expect(track.lane.steps[2].notes == [65])
    }

    // MARK: — 2. setPitchNotes: inactive step becomes active

    @Test func setPitchNotes_activatesInactiveStep() {
        let track = TrackData(name: "Test")
        var steps = track.lane.steps
        steps[0].isActive = false
        steps[0].notes    = [60]
        track.lane.steps = steps

        writer.apply(
            .setPitchNotes(trackID: track.id, stepIndex: 0, oldNotes: [60], newNotes: [62]),
            to: track, undoManager: nil
        )
        #expect(track.lane.steps[0].isActive == true)
    }

    // MARK: — 3. setPitchNotes: already active stays active

    @Test func setPitchNotes_activeStepRemainsActive() {
        let track = TrackData(name: "Test")
        var steps = track.lane.steps
        steps[1].isActive = true
        steps[1].notes    = [60]
        track.lane.steps = steps

        writer.apply(
            .setPitchNotes(trackID: track.id, stepIndex: 1, oldNotes: [60], newNotes: [64]),
            to: track, undoManager: nil
        )
        #expect(track.lane.steps[1].isActive == true)
    }

    // MARK: — 4. setSteps: full steps array replaced

    @Test func setSteps_replacesFullArray() {
        let track = TrackData(name: "Test")
        let originalSteps = track.lane.steps
        var modified = originalSteps
        modified[0].notes = [99]

        writer.apply(
            .setSteps(trackID: track.id, oldSteps: originalSteps, newSteps: modified, actionName: "Test"),
            to: track, undoManager: nil
        )
        #expect(track.lane.steps[0].notes == [99])
    }

    // MARK: — 5. setSteps: undo restores oldSteps

    @Test func setSteps_undoRestoresOld() {
        let track = TrackData(name: "Test")
        let snapshot = track.lane.steps
        var modified = snapshot
        modified[0].notes = [88]

        let um = UndoManager()
        writer.apply(
            .setSteps(trackID: track.id, oldSteps: snapshot, newSteps: modified, actionName: "Move Step"),
            to: track, undoManager: um
        )
        #expect(track.lane.steps[0].notes == [88])

        um.undo()
        #expect(track.lane.steps[0].notes == snapshot[0].notes)
    }

    // MARK: — 6. setSteps: actionName propagated (undo registration completes)

    @Test func setSteps_actionNameDoesNotCrash() {
        let track = TrackData(name: "Test")
        let um = UndoManager()
        writer.apply(
            .setSteps(trackID: track.id, oldSteps: track.lane.steps, newSteps: track.lane.steps, actionName: "Move Step"),
            to: track, undoManager: um
        )
        #expect(um.canUndo == true)
    }
}

// MARK: - InteractionController Pitch Drag Tests

struct InteractionControllerPitchDragTests {

    private func makeIC() -> (InteractionController, TrackData) {
        let ss  = ScrollState()
        let vc  = ViewportController(scrollState: ss)
        let ic  = InteractionController(viewportController: vc)
        let track = TrackData(name: "Test")
        return (ic, track)
    }

    // MARK: — 1. beginPitchDrag starts session

    @Test func beginPitchDrag_startsSession() {
        let (ic, track) = makeIC()
        ic.beginPitchDrag(track: track, stepIndex: 3)
        guard case .pitchDrag = ic.activeSession else {
            Issue.record(Comment("Expected .pitchDrag session"))
            return
        }
        #expect(ic.isSessionActive == true)
    }

    // MARK: — 2. beginPitchDrag captures snapshot

    @Test func beginPitchDrag_capturesSnapshot() {
        let (ic, track) = makeIC()
        var steps = track.lane.steps
        steps[0].notes = [48, 52, 55]
        track.lane.steps = steps

        ic.beginPitchDrag(track: track, stepIndex: 0)
        guard case .pitchDrag(let session) = ic.activeSession else {
            Issue.record(Comment("Expected pitchDrag session"))
            return
        }
        #expect(session.stepsSnapshot[0].notes == [48, 52, 55])
        #expect(session.baseNotes == [48, 52, 55])
    }

    // MARK: — 3. updatePitchDrag applies notes when semitones change

    @Test func updatePitchDrag_appliesNotesOnChange() {
        let (ic, track) = makeIC()
        var steps = track.lane.steps
        steps[0].notes = [60]
        track.lane.steps = steps

        ic.beginPitchDrag(track: track, stepIndex: 0)
        // totalY = -4 → +1 semitone → note 61
        let result = ic.updatePitchDrag(totalY: -4, track: track)
        #expect(result == [61])
        #expect(track.lane.steps[0].notes == [61])
    }

    /// Die Geste meldet erst nach 8 pt: ab dem Anker gezählt ist der erste Schritt ein
    /// Halbton, nicht zwei (v1.13.8).
    @Test func updatePitchDrag_countsFromAnchor() {
        let (ic, track) = makeIC()
        var steps = track.lane.steps
        steps[0].notes = [60]
        track.lane.steps = steps

        ic.beginPitchDrag(track: track, stepIndex: 0, anchorY: -8)
        #expect(ic.updatePitchDrag(totalY: -8, track: track) == [60])
        #expect(ic.updatePitchDrag(totalY: -12, track: track) == [61])
        #expect(track.lane.steps[0].notes == [61])
    }

    /// ⌥+Ziehen ändert die Velocity, nicht die Tonhöhe; ein Undo-Schritt, Abbruch stellt her.
    @Test func velocityDrag_changesVelocityOnly() {
        let (ic, track) = makeIC()
        var steps = track.lane.steps
        steps[0].notes = [60]; steps[0].velocity = 100
        track.lane.steps = steps
        let undo = UndoManager()

        ic.beginPitchDrag(track: track, stepIndex: 0, anchorY: 8, velocity: true)
        #expect(ic.updatePitchDrag(totalY: 28, track: track) == nil)
        #expect(track.lane.steps[0].velocity == 80 && track.lane.steps[0].notes == [60])
        _ = ic.updatePitchDrag(totalY: -500, track: track)
        #expect(track.lane.steps[0].velocity == 127)
        ic.commitPitchDrag(track: track, undoManager: undo)
        undo.undo()
        #expect(track.lane.steps[0].velocity == 100)

        ic.beginPitchDrag(track: track, stepIndex: 0, velocity: true)
        _ = ic.updatePitchDrag(totalY: 500, track: track)
        #expect(track.lane.steps[0].velocity == 1)
        ic.cancelPitchDrag(track: track)
        #expect(track.lane.steps[0].velocity == 100)
    }

    // MARK: — 4. updatePitchDrag returns nil when semitones unchanged (dedup)

    @Test func updatePitchDrag_returnsNil_whenUnchanged() {
        let (ic, track) = makeIC()
        var steps = track.lane.steps
        steps[0].notes = [60]
        track.lane.steps = steps

        ic.beginPitchDrag(track: track, stepIndex: 0)
        _ = ic.updatePitchDrag(totalY: -4, track: track)   // apply +1 semitone
        let second = ic.updatePitchDrag(totalY: -3, track: track) // still +1 (rounds to 1)
        #expect(second == nil)                               // deduped
    }

    // MARK: — 5. updatePitchDrag activates inactive step

    @Test func updatePitchDrag_activatesStep() {
        let (ic, track) = makeIC()
        var steps = track.lane.steps
        steps[0].isActive = false
        steps[0].notes    = [60]
        track.lane.steps = steps

        ic.beginPitchDrag(track: track, stepIndex: 0)
        _ = ic.updatePitchDrag(totalY: -8, track: track)
        #expect(track.lane.steps[0].isActive == true)
    }

    // MARK: — 6. commitPitchDrag clears session

    @Test func commitPitchDrag_clearsSession() {
        let (ic, track) = makeIC()
        ic.beginPitchDrag(track: track, stepIndex: 0)
        _ = ic.updatePitchDrag(totalY: -4, track: track)
        ic.commitPitchDrag(track: track, undoManager: nil)
        #expect(ic.activeSession == nil)
        #expect(ic.isSessionActive == false)
    }

    // MARK: — 7. commitPitchDrag keeps model change

    @Test func commitPitchDrag_keepsChangedNotes() {
        let (ic, track) = makeIC()
        var steps = track.lane.steps
        steps[0].notes = [60]
        track.lane.steps = steps

        ic.beginPitchDrag(track: track, stepIndex: 0)
        _ = ic.updatePitchDrag(totalY: -4, track: track)   // → [61]
        ic.commitPitchDrag(track: track, undoManager: nil)
        #expect(track.lane.steps[0].notes == [61])
    }

    // MARK: — 8. cancelPitchDrag restores snapshot

    @Test func cancelPitchDrag_restoresSnapshot() {
        let (ic, track) = makeIC()
        var steps = track.lane.steps
        steps[0].notes = [60]
        track.lane.steps = steps

        ic.beginPitchDrag(track: track, stepIndex: 0)
        _ = ic.updatePitchDrag(totalY: -20, track: track)   // → [65]
        #expect(track.lane.steps[0].notes == [65])

        ic.cancelPitchDrag(track: track)
        #expect(track.lane.steps[0].notes == [60])    // restored
        #expect(ic.activeSession == nil)
        #expect(ic.isSessionActive == false)
    }

    // MARK: — 9. Modal invariant: pitch drag blocks rubber band

    @Test func modalInvariant_pitchBlocksRubberBand() {
        let (ic, track) = makeIC()
        ic.beginPitchDrag(track: track, stepIndex: 0)
        ic.beginRubberBand(
            trackID: UUID(), contentX: 0, screenX: 0, y: 0,
            stepWidth: 60, stepCount: 16
        )
        // Still pitch drag — rubber band must not have started
        guard case .pitchDrag = ic.activeSession else {
            Issue.record(Comment("Expected .pitchDrag to survive modal check"))
            return
        }
    }

    // MARK: — 10. Modal invariant: pitch drag blocks step swap

    @Test func modalInvariant_pitchBlocksStepSwap() {
        let (ic, track) = makeIC()
        ic.beginPitchDrag(track: track, stepIndex: 0)
        ic.beginStepSwap(track: track, sourceIndex: 3, stepWidth: 60)
        guard case .pitchDrag = ic.activeSession else {
            Issue.record(Comment("Expected .pitchDrag to survive modal check"))
            return
        }
    }

    // MARK: — 11. New pitch session possible after commit

    @Test func newPitchSession_possibleAfterCommit() {
        let (ic, track) = makeIC()
        ic.beginPitchDrag(track: track, stepIndex: 0)
        ic.commitPitchDrag(track: track, undoManager: nil)

        // Second session on step 2
        var steps = track.lane.steps
        steps[2].notes = [48]
        track.lane.steps = steps
        ic.beginPitchDrag(track: track, stepIndex: 2)
        guard case .pitchDrag(let session) = ic.activeSession else {
            Issue.record(Comment("Expected new pitchDrag session"))
            return
        }
        #expect(session.stepIndex == 2)
    }
}

// MARK: - InteractionController Step Swap Tests

struct InteractionControllerStepSwapTests {

    private func makeIC() -> (InteractionController, TrackData) {
        let ss  = ScrollState()
        let vc  = ViewportController(scrollState: ss)
        let ic  = InteractionController(viewportController: vc)
        let track = TrackData(name: "Test")
        return (ic, track)
    }

    // MARK: — 1. beginStepSwap starts session

    @Test func beginStepSwap_startsSession() {
        let (ic, track) = makeIC()
        ic.beginStepSwap(track: track, sourceIndex: 4, stepWidth: 60)
        guard case .stepSwap(let session) = ic.activeSession else {
            Issue.record(Comment("Expected .stepSwap session"))
            return
        }
        #expect(session.sourceIndex == 4)
        #expect(session.targetIndex == 4)    // no movement yet
        #expect(ic.isSessionActive == true)
    }

    // MARK: — 2. beginStepSwap captures snapshot

    @Test func beginStepSwap_capturesSnapshot() {
        let (ic, track) = makeIC()
        var steps = track.lane.steps
        steps[3].notes = [72]
        track.lane.steps = steps

        ic.beginStepSwap(track: track, sourceIndex: 3, stepWidth: 60)
        guard case .stepSwap(let session) = ic.activeSession else {
            Issue.record(Comment("Expected .stepSwap session"))
            return
        }
        #expect(session.stepsSnapshot[3].notes == [72])
    }

    // MARK: — 3. updateStepSwap updates targetIndex

    @Test func updateStepSwap_updatesTargetIndex() {
        let (ic, track) = makeIC()
        ic.beginStepSwap(track: track, sourceIndex: 2, stepWidth: 60)
        // 180 px / 60 px = delta 3 → target 5
        ic.updateStepSwap(translationX: 180, track: track)
        guard case .stepSwap(let session) = ic.activeSession else {
            Issue.record(Comment("Expected .stepSwap session"))
            return
        }
        #expect(session.targetIndex == 5)
    }

    // MARK: — 4. updateStepSwap does not mutate model

    @Test func updateStepSwap_doesNotMutateModel() {
        let (ic, track) = makeIC()
        var steps = track.lane.steps
        steps[2].notes = [60]
        steps[5].notes = [67]
        track.lane.steps = steps
        let originalSteps = track.lane.steps

        ic.beginStepSwap(track: track, sourceIndex: 2, stepWidth: 60)
        ic.updateStepSwap(translationX: 180, track: track)
        // Model must not have changed during drag
        #expect(track.lane.steps[2].notes == originalSteps[2].notes)
        #expect(track.lane.steps[5].notes == originalSteps[5].notes)
    }

    // MARK: — 5. updateStepSwap publishes stepSwapUpdate

    @Test func updateStepSwap_publishesUpdate() {
        let (ic, track) = makeIC()
        ic.beginStepSwap(track: track, sourceIndex: 1, stepWidth: 60)
        ic.updateStepSwap(translationX: 60, track: track)

        guard let upd = ic.stepSwapUpdate else {
            Issue.record(Comment("Expected stepSwapUpdate"))
            return
        }
        #expect(upd.phase == .active)
        #expect(upd.sourceIndex == 1)
        #expect(upd.targetIndex == 2)
    }

    // MARK: — 6. commitStepSwap applies swap to model

    @Test func commitStepSwap_swap_appliesSwap() {
        let (ic, track) = makeIC()
        var steps = track.lane.steps
        steps[2].notes = [60]
        steps[5].notes = [67]
        track.lane.steps = steps

        ic.beginStepSwap(track: track, sourceIndex: 2, stepWidth: 60)
        ic.updateStepSwap(translationX: 180, track: track)   // target → 5
        ic.commitStepSwap(track: track, isCopy: false, undoManager: nil)

        #expect(track.lane.steps[2].notes == [67])   // was index 5
        #expect(track.lane.steps[5].notes == [60])   // was index 2
        #expect(ic.activeSession == nil)
        #expect(ic.isSessionActive == false)
    }

    // MARK: — 7. commitStepSwap applies copy to model

    @Test func commitStepSwap_copy_duplicatesSource() {
        let (ic, track) = makeIC()
        var steps = track.lane.steps
        steps[0].notes = [48]
        steps[4].notes = [55]
        track.lane.steps = steps

        ic.beginStepSwap(track: track, sourceIndex: 0, stepWidth: 60)
        ic.updateStepSwap(translationX: 240, track: track)   // target → 4
        ic.commitStepSwap(track: track, isCopy: true, undoManager: nil)

        #expect(track.lane.steps[0].notes == [48])   // source unchanged
        #expect(track.lane.steps[4].notes == [48])   // copy of source
    }

    // MARK: — 8. commitStepSwap: source == target is a no-op

    @Test func commitStepSwap_noOp_whenSourceEqualsTarget() {
        let (ic, track) = makeIC()
        var steps = track.lane.steps
        steps[3].notes = [60]
        track.lane.steps = steps
        let originalSteps = track.lane.steps

        ic.beginStepSwap(track: track, sourceIndex: 3, stepWidth: 60)
        // No movement
        ic.commitStepSwap(track: track, isCopy: false, undoManager: nil)
        #expect(track.lane.steps[3].notes == originalSteps[3].notes)
        #expect(ic.activeSession == nil)
    }

    // MARK: — 9. cancelStepSwap clears session without model change

    @Test func cancelStepSwap_clearsSessionNoModelChange() {
        let (ic, track) = makeIC()
        var steps = track.lane.steps
        steps[2].notes = [60]
        steps[6].notes = [67]
        track.lane.steps = steps
        let originalSteps = track.lane.steps

        ic.beginStepSwap(track: track, sourceIndex: 2, stepWidth: 60)
        ic.updateStepSwap(translationX: 240, track: track)
        ic.cancelStepSwap()

        // Model unchanged (no mutations during drag)
        #expect(track.lane.steps[2].notes == originalSteps[2].notes)
        #expect(track.lane.steps[6].notes == originalSteps[6].notes)
        #expect(ic.activeSession == nil)
        #expect(ic.isSessionActive == false)
    }

    // MARK: — 10. cancelStepSwap publishes .cancelled

    @Test func cancelStepSwap_publishesCancelled() {
        let (ic, track) = makeIC()
        ic.beginStepSwap(track: track, sourceIndex: 1, stepWidth: 60)
        ic.cancelStepSwap()

        guard let upd = ic.stepSwapUpdate else {
            Issue.record(Comment("Expected stepSwapUpdate after cancel"))
            return
        }
        #expect(upd.phase == .cancelled)
    }

    // MARK: — 11. Modal invariant: step swap blocks pitch drag

    @Test func modalInvariant_stepSwapBlocksPitchDrag() {
        let (ic, track) = makeIC()
        ic.beginStepSwap(track: track, sourceIndex: 2, stepWidth: 60)
        ic.beginPitchDrag(track: track, stepIndex: 5)
        guard case .stepSwap = ic.activeSession else {
            Issue.record(Comment("Expected .stepSwap to survive modal check"))
            return
        }
    }

    // MARK: — 12. Modal invariant: step swap blocks rubber band

    @Test func modalInvariant_stepSwapBlocksRubberBand() {
        let (ic, track) = makeIC()
        ic.beginStepSwap(track: track, sourceIndex: 0, stepWidth: 60)
        ic.beginRubberBand(
            trackID: UUID(), contentX: 0, screenX: 0, y: 0,
            stepWidth: 60, stepCount: 16
        )
        guard case .stepSwap = ic.activeSession else {
            Issue.record(Comment("Expected .stepSwap to survive modal check"))
            return
        }
    }

    // MARK: — 13. New swap session possible after commit

    @Test func newSwapSession_possibleAfterCommit() {
        let (ic, track) = makeIC()
        ic.beginStepSwap(track: track, sourceIndex: 0, stepWidth: 60)
        ic.commitStepSwap(track: track, isCopy: false, undoManager: nil)

        ic.beginStepSwap(track: track, sourceIndex: 7, stepWidth: 60)
        guard case .stepSwap(let session) = ic.activeSession else {
            Issue.record(Comment("Expected new .stepSwap session after commit"))
            return
        }
        #expect(session.sourceIndex == 7)
    }
}

// MARK: - EdgeScrollVelocity Tests (Arch-Slice-7, updated Arch-Slice-9)

struct EdgeScrollVelocityTests {

    let viewWidth:   CGFloat = 800
    let zoneWidth:   CGFloat = EdgeScrollVelocity.defaultZoneWidth   // 300 (tuned Arch-Slice-9)
    let maxVelocity: CGFloat = EdgeScrollVelocity.defaultMaxVelocity // 20  (tuned Arch-Slice-9)

    // MARK: — 1. Centre of viewport → zero velocity

    @Test func velocity_inCentre_isZero() {
        // viewWidth=800, pointerX=400. With default insets (50 px each):
        //   rightBound = 800-50 = 750; right zone starts at 750-300 = 450 → 400 < 450, outside.
        //   leftBound  = 50;    left  zone ends   at 50+300  = 350 → 400 > 350, outside.
        // Zero regardless of insets.
        let v = EdgeScrollVelocity.velocity(pointerX: viewWidth / 2, viewWidth: viewWidth)
        #expect(v == 0)
    }

    @Test func velocity_justInsideLeftZone_isZero() {
        // Exactly at zone boundary (insets=0) → t=0 → smoothstep(0)=0
        let v = EdgeScrollVelocity.velocity(pointerX: zoneWidth, viewWidth: viewWidth,
                                             leftInset: 0, rightInset: 0)
        #expect(v == 0)
    }

    @Test func velocity_justInsideRightZone_isZero() {
        let v = EdgeScrollVelocity.velocity(pointerX: viewWidth - zoneWidth, viewWidth: viewWidth,
                                             leftInset: 0, rightInset: 0)
        #expect(v == 0)
    }

    // MARK: — 2. Sign convention (insets=0 to test pure zone behaviour)

    @Test func velocity_leftEdge_isNegative() {
        // Pointer at 0 (left edge) → scroll left → negative
        let v = EdgeScrollVelocity.velocity(pointerX: 0, viewWidth: viewWidth,
                                             leftInset: 0, rightInset: 0)
        #expect(v < 0)
    }

    @Test func velocity_rightEdge_isPositive() {
        // Pointer at viewWidth (right edge) → scroll right → positive
        let v = EdgeScrollVelocity.velocity(pointerX: viewWidth, viewWidth: viewWidth,
                                             leftInset: 0, rightInset: 0)
        #expect(v > 0)
    }

    // MARK: — 3. Maximum velocity at edges (insets=0)

    @Test func velocity_atLeftEdge_equalsNegativeMax() {
        let v = EdgeScrollVelocity.velocity(pointerX: 0, viewWidth: viewWidth,
                                             leftInset: 0, rightInset: 0)
        // t=1 at edge → smoothstep(1)=1 → velocity=-maxVelocity
        #expect(abs(v - (-maxVelocity)) < 0.001)
    }

    @Test func velocity_atRightEdge_equalsPositiveMax() {
        let v = EdgeScrollVelocity.velocity(pointerX: viewWidth, viewWidth: viewWidth,
                                             leftInset: 0, rightInset: 0)
        #expect(abs(v - maxVelocity) < 0.001)
    }

    // MARK: — 4. Smoothstep mid-zone value (t=0.5, insets=0)

    @Test func velocity_midZone_matchesSmoothstep() {
        // Pointer at zoneWidth/2 from left edge → t = 0.5
        // smoothstep(0.5) = 0.5² × (3 - 2×0.5) = 0.25 × 2 = 0.5
        let pointerX = zoneWidth / 2
        let v = EdgeScrollVelocity.velocity(pointerX: pointerX, viewWidth: viewWidth,
                                             leftInset: 0, rightInset: 0)
        let expected = -maxVelocity * 0.5
        #expect(abs(v - expected) < 0.001)
    }

    // MARK: — 5. Clamp — pointer beyond edge does not exceed maxVelocity

    @Test func velocity_beyondRightEdge_doesNotExceedMax() {
        let v = EdgeScrollVelocity.velocity(pointerX: viewWidth + 1000, viewWidth: viewWidth)
        #expect(abs(v) <= maxVelocity + 0.001)
    }

    @Test func velocity_beyondLeftEdge_doesNotExceedMax() {
        let v = EdgeScrollVelocity.velocity(pointerX: -1000, viewWidth: viewWidth)
        #expect(abs(v) <= maxVelocity + 0.001)
    }

    // MARK: — 6. Monotonicity — velocity increases toward edge (insets=0)

    @Test func velocity_rightZone_isMonotonicallyIncreasing() {
        let x1 = viewWidth - zoneWidth + 10   // closer to centre
        let x2 = viewWidth - zoneWidth + 40   // closer to edge
        let x3 = viewWidth                    // at edge
        let v1 = EdgeScrollVelocity.velocity(pointerX: x1, viewWidth: viewWidth,
                                              leftInset: 0, rightInset: 0)
        let v2 = EdgeScrollVelocity.velocity(pointerX: x2, viewWidth: viewWidth,
                                              leftInset: 0, rightInset: 0)
        let v3 = EdgeScrollVelocity.velocity(pointerX: x3, viewWidth: viewWidth,
                                              leftInset: 0, rightInset: 0)
        #expect(v1 <= v2)
        #expect(v2 <= v3)
    }

    // MARK: — 7. Custom parameters respected (explicit insets=0)

    @Test func velocity_customZoneAndMax() {
        // Pointer at left edge (0), custom zone, max velocity, no insets
        let v = EdgeScrollVelocity.velocity(pointerX: 0, viewWidth: viewWidth,
                                             leftZoneWidth: 100, rightZoneWidth: 100,
                                             leftInset: 0, rightInset: 0,
                                             maxVelocity: 20)
        #expect(abs(v - (-20)) < 0.001)
    }

    // MARK: — 8. Zero / degenerate inputs do not crash

    @Test func velocity_zeroViewWidth_returnsZero() {
        let v = EdgeScrollVelocity.velocity(pointerX: 0, viewWidth: 0)
        #expect(v == 0)
    }

    @Test func velocity_zeroZoneWidth_returnsZero() {
        // Both zones zero → no ramp → zero velocity at any position
        let v = EdgeScrollVelocity.velocity(pointerX: 0, viewWidth: viewWidth,
                                             leftZoneWidth: 0, rightZoneWidth: 0)
        #expect(v == 0)
    }

    // MARK: — 9. Inset behaviour (Arch-Slice-9)

    @Test func velocity_insideLeftInset_isFullSpeed() {
        // Im Inset (und jenseits der Kante) gilt volle Geschwindigkeit — ein über den Rand
        // hinaus gezogener Zeiger darf das Scrollen nicht anhalten.
        let v = EdgeScrollVelocity.velocity(pointerX: 25, viewWidth: viewWidth, leftInset: 50, rightInset: 50)
        #expect(abs(v - (-maxVelocity)) < 0.001)
    }

    @Test func velocity_insideRightInset_isFullSpeed() {
        let v = EdgeScrollVelocity.velocity(pointerX: viewWidth - 25, viewWidth: viewWidth, leftInset: 50, rightInset: 50)
        #expect(abs(v - maxVelocity) < 0.001)
    }

    /// Codex-Befund GUI-Revision 1: in einer schmalen Lane (551 px) scrollte ein ruhender
    /// Zeiger in der Mitte. Die mittlere Hälfte jedes Viewports muss scrollfrei sein.
    @Test func velocity_middleHalfOfNarrowViewport_isZero() {
        for width in [120, 300, 551, 800] as [CGFloat] {
            for f in [0.26, 0.4, 0.5, 0.6, 0.74] as [CGFloat] {
                #expect(EdgeScrollVelocity.velocity(pointerX: width * f, viewWidth: width) == 0,
                        "Breite \(width), Position \(f)")
            }
        }
    }

    @Test func velocity_pastLeftInset_scrollsLeft() {
        // Pointer just past the left inset (inset+1) and well inside zone → should scroll left
        let inset: CGFloat = 50
        let v = EdgeScrollVelocity.velocity(pointerX: inset + 1, viewWidth: viewWidth, leftInset: inset, rightInset: inset)
        #expect(v < 0)
    }

    @Test func velocity_pastRightInset_scrollsRight() {
        // Pointer just past the right inset (viewWidth-inset-1) and well inside zone → should scroll right
        let inset = EdgeScrollVelocity.defaultRightInset
        let v = EdgeScrollVelocity.velocity(pointerX: viewWidth - inset - 1, viewWidth: viewWidth)
        #expect(v > 0)
    }
}

// MARK: - ViewportController Scroll-Bridge Tests (Arch-Slice-6)
//
// Covers: scrollTrackpad, syncFromScrollbar, maxScrollOffset clamping,
//         session guard, re-entrancy guard.

struct ViewportControllerScrollBridgeTests {

    private func makeVC(initialOffset: CGFloat = 0) -> (ViewportController, ScrollState) {
        let ss = ScrollState()
        ss.hScrollOffset = initialOffset
        let vc = ViewportController(scrollState: ss)
        return (vc, ss)
    }

    // MARK: — 1. scrollTrackpad applies offset − delta (macOS sign convention)

    @Test func scrollTrackpad_positivedelta_scrollsRight() {
        let (vc, ss) = makeVC(initialOffset: 200)
        vc.scrollTrackpad(delta: 30)
        // offset = 200 - 30 = 170
        #expect(ss.hScrollOffset == 170)
    }

    @Test func scrollTrackpad_negativeDelta_scrollsLeft() {
        let (vc, ss) = makeVC(initialOffset: 100)
        vc.scrollTrackpad(delta: -20)
        // offset = 100 - (-20) = 120
        #expect(ss.hScrollOffset == 120)
    }

    // MARK: — 2. scrollTrackpad clamps to [0, maxScrollOffset]

    @Test func scrollTrackpad_clampsToZero() {
        let (vc, ss) = makeVC(initialOffset: 10)
        vc.scrollTrackpad(delta: 10_000)
        #expect(ss.hScrollOffset == 0)
    }

    @Test func scrollTrackpad_clampsToMaxScrollOffset() {
        let (vc, ss) = makeVC(initialOffset: 500)
        vc.maxScrollOffset = 600
        vc.scrollTrackpad(delta: -10_000)
        #expect(ss.hScrollOffset == 600)
    }

    @Test func scrollTrackpad_exactlyAtMax_doesNotExceed() {
        let (vc, ss) = makeVC(initialOffset: 595)
        vc.maxScrollOffset = 600
        vc.scrollTrackpad(delta: -10)
        #expect(ss.hScrollOffset == 600)
    }

    // MARK: — 3. scrollBy clamps to [0, maxScrollOffset]

    @Test func scrollBy_clampsToZero() {
        let (vc, ss) = makeVC(initialOffset: 5)
        vc.scroll(by: -100)
        #expect(ss.hScrollOffset == 0)
    }

    @Test func scrollBy_clampsToMax() {
        let (vc, ss) = makeVC(initialOffset: 580)
        vc.maxScrollOffset = 600
        vc.scroll(by: 100)
        #expect(ss.hScrollOffset == 600)
    }

    // MARK: — 4. maxScrollOffset defaults to .greatestFiniteMagnitude (effectively unclamped)

    @Test func maxScrollOffset_defaultIsUnclamped() {
        let (vc, ss) = makeVC(initialOffset: 0)
        // A very large positive value should not be clamped by the default max.
        vc.scroll(by: 1_000_000)
        #expect(ss.hScrollOffset == 1_000_000)
    }

    // MARK: — 5. syncFromScrollbar writes offset when guards allow

    @Test func syncFromScrollbar_writesOffset_whenGuardsOff() {
        let (vc, ss) = makeVC(initialOffset: 0)
        vc.syncFromScrollbar(150)
        #expect(ss.hScrollOffset == 150)
    }

    @Test func syncFromScrollbar_clampsToZero() {
        let (vc, ss) = makeVC(initialOffset: 10)
        vc.syncFromScrollbar(-50)
        #expect(ss.hScrollOffset == 0)
    }

    @Test func syncFromScrollbar_clampsToMax() {
        let (vc, ss) = makeVC(initialOffset: 100)
        vc.maxScrollOffset = 300
        vc.syncFromScrollbar(10_000)
        #expect(ss.hScrollOffset == 300)
    }

    // MARK: — 6. syncFromScrollbar: session guard suppresses write while active

    @Test func syncFromScrollbar_noOp_duringActiveSession() {
        let (vc, ss) = makeVC(initialOffset: 200)
        // Simulate an active interaction session by beginning one via IC.
        let ic = InteractionController(viewportController: vc)
        let track = TrackData(name: "Test")
        ic.beginHandleDrag(track: track, pxPerStep: 60)   // sets vc.sessionActive = true
        #expect(vc.sessionActive == true)

        vc.syncFromScrollbar(500)
        #expect(ss.hScrollOffset == 200)   // unchanged — session is active
    }

    // MARK: — 7. syncFromScrollbar: re-entrancy guard suppresses write while isSyncingScrollbar

    @Test func syncFromScrollbar_noOp_whileIsSyncingScrollbar() {
        let (vc, ss) = makeVC(initialOffset: 100)
        vc.isSyncingScrollbar = true      // simulates updateNSView outward-push in progress
        vc.syncFromScrollbar(400)
        #expect(ss.hScrollOffset == 100)  // unchanged — re-entrancy guard active
        vc.isSyncingScrollbar = false
    }

    // MARK: — 8. syncFromScrollbar: isSyncingScrollbar resets to false after call

    @Test func syncFromScrollbar_resetsSyncingFlag_afterWrite() {
        let (vc, _) = makeVC()
        vc.syncFromScrollbar(50)
        #expect(vc.isSyncingScrollbar == false)
    }

    // MARK: — 9. syncFromScrollbar allowed again after session ends

    @Test func syncFromScrollbar_allowedAfterSessionEnds() {
        let (vc, ss) = makeVC(initialOffset: 200)
        let ic = InteractionController(viewportController: vc)
        let track = TrackData(name: "Test")
        ic.beginHandleDrag(track: track, pxPerStep: 60)
        ic.commitHandleDrag(track: track, undoManager: nil)   // ends session

        vc.syncFromScrollbar(350)
        #expect(ss.hScrollOffset == 350)   // write goes through
    }

    // MARK: — 10. maxScrollOffset update is respected by subsequent scrolls

    @Test func maxScrollOffset_updatedAtRuntime_clampsCorrectly() {
        let (vc, ss) = makeVC(initialOffset: 100)
        vc.maxScrollOffset = .greatestFiniteMagnitude  // unclamped initially
        vc.scroll(by: 500)                             // → 600
        #expect(ss.hScrollOffset == 600)

        vc.maxScrollOffset = 400                       // tighten the bound
        vc.scroll(by: 0)                               // offset stays at 600 (no delta)
        // Next scroll write will clamp at 400 when we explicitly move past it.
        vc.scroll(by: 50)
        #expect(ss.hScrollOffset == 400)               // clamped
    }

    // MARK: — 11. adjustScroll — anchor-stable zoom (Arch-Slice-9)

    @Test func adjustScroll_doubling_halfsDistanceBeyondAnchor() {
        // Setup: scrollOffset=0, anchorX=200, step width doubles 54→108.
        // P-korrigierte Formel: S' = m×S + (m−1)×(A−P)
        // Slot-Ratio m = (108+4)/(54+4) = 112/58, P = 8.
        // contentX = (200−8) + 0 = 192. newOffset = 192 × 112/58 + 8 − 200.
        // = 192 × 54/58 = 10368/58 = 5184/29 ≈ 178.759
        let (vc, ss) = makeVC(initialOffset: 0)
        vc.adjustScroll(oldStepWidth: 54, newStepWidth: 108, anchorX: 200)
        let expected = 5184.0 / 29.0
        #expect(abs(ss.hScrollOffset - expected) < 0.001)
    }

    @Test func adjustScroll_anchorAtOrigin_clampsToZero() {
        // anchorX=0, P=8: contentX = (0−8)+0 = −8. newOffset = −8×ratio + 8 − 0.
        // = −8 × 112/58 + 8 = −7.448... → clamped to 0.
        // Korrekt: am linken Rand liegt Padding, nicht Step-Content.
        let (vc, ss) = makeVC(initialOffset: 0)
        vc.adjustScroll(oldStepWidth: 54, newStepWidth: 108, anchorX: 0)
        #expect(ss.hScrollOffset == 0)
    }

    @Test func adjustScroll_withScrollOffset_anchorsContentCorrectly() {
        // scrollOffset=300, anchorX=100, oldW=54, newW=108.
        // P-korrigierte Formel: contentX = (100−8) + 300 = 392.
        // newOffset = 392 × 112/58 + 8 − 100 = 392×112/58 − 92.
        // = (392×112 − 92×58) / 58 = (43904−5336)/58 = 38568/58 = 19284/29 ≈ 665.0
        let (vc, ss) = makeVC(initialOffset: 300)
        vc.adjustScroll(oldStepWidth: 54, newStepWidth: 108, anchorX: 100)
        let expected = 19284.0 / 29.0
        #expect(abs(ss.hScrollOffset - expected) < 0.001)
    }

    @Test func adjustScroll_sameWidth_isNoOp() {
        // old == new → guard returns early → no change
        let (vc, ss) = makeVC(initialOffset: 500)
        vc.adjustScroll(oldStepWidth: 54, newStepWidth: 54, anchorX: 200)
        #expect(ss.hScrollOffset == 500)
    }

    @Test func adjustScroll_clampsToZero() {
        // Shrink from large offset: newOffset could go negative → clamped to 0.
        // scrollOffset=10, anchorX=500, newW=27 (scale=0.5).
        // contentX=510. newOffset=510×0.5−500=255−500=−245 → clamped to 0.
        let (vc, ss) = makeVC(initialOffset: 10)
        vc.adjustScroll(oldStepWidth: 54, newStepWidth: 27, anchorX: 500)
        #expect(ss.hScrollOffset == 0)
    }

    @Test func adjustScroll_updatesZoomScale() {
        // zoomScale = newStepWidth / 54.
        let (vc, _) = makeVC()
        vc.adjustScroll(oldStepWidth: 54, newStepWidth: 108, anchorX: 0)
        #expect(abs(vc.zoomScale - 2.0) < 0.001)
    }

    @Test func adjustScroll_zeroOldWidth_isNoOp() {
        // Guard: oldStepWidth == 0 → no crash, no change.
        let (vc, ss) = makeVC(initialOffset: 200)
        vc.adjustScroll(oldStepWidth: 0, newStepWidth: 54, anchorX: 100)
        #expect(ss.hScrollOffset == 200)
    }
}

// MARK: - StretchRatioDragSession Tests (Arch-Slice-8)

struct StretchRatioDragSessionTests {

    /// Builds a session with the 1:1 ratio (midpoint of sortedRatios).
    private func makeSession(ratioIndex: Int? = nil) -> StretchRatioDragSession {
        let idx = ratioIndex ?? (TrackData.sortedRatios.firstIndex(where: { $0.num == 1 && $0.den == 1 }) ?? 6)
        let r   = TrackData.sortedRatios[idx]
        return StretchRatioDragSession(
            trackID:             UUID(),
            snapshotNumerator:   r.num,
            snapshotDenominator: r.den,
            snapshotRatioIndex:  idx
        )
    }

    // MARK: — 1. No movement → snapshot index unchanged

    @Test func proposedRatioIndex_noMovement_returnsSnapshotIndex() {
        let session = makeSession()
        let idx     = session.proposedRatioIndex(totalY: 0)
        #expect(idx == session.snapshotRatioIndex)
    }

    // MARK: — 2. Upward drag → higher index (longer step)

    @Test func proposedRatioIndex_upDrag_incrementsIndex() {
        let baseIdx = 4   // middle of the table
        let session = makeSession(ratioIndex: baseIdx)
        // 24px up → delta = -(-1) = +1 → index += 1
        let idx = session.proposedRatioIndex(totalY: -StretchRatioDragSession.pxPerIndex)
        #expect(idx == baseIdx + 1)
    }

    // MARK: — 3. Downward drag → lower index (shorter step)

    @Test func proposedRatioIndex_downDrag_decrementsIndex() {
        let baseIdx = 4
        let session = makeSession(ratioIndex: baseIdx)
        let idx = session.proposedRatioIndex(totalY: StretchRatioDragSession.pxPerIndex)
        #expect(idx == baseIdx - 1)
    }

    // MARK: — 4. Clamp to min (index 0)

    @Test func proposedRatioIndex_clampsToMin() {
        let session = makeSession(ratioIndex: 0)
        let idx = session.proposedRatioIndex(totalY: 10_000)   // large down drag
        #expect(idx == 0)
    }

    // MARK: — 5. Clamp to max

    @Test func proposedRatioIndex_clampsToMax() {
        let maxIdx  = TrackData.sortedRatios.count - 1
        let session = makeSession(ratioIndex: maxIdx)
        let idx = session.proposedRatioIndex(totalY: -10_000)  // large up drag
        #expect(idx == maxIdx)
    }

    // MARK: — 6. proposedRatio returns the correct ratio tuple

    @Test func proposedRatio_returnsCorrectTuple() {
        let baseIdx = 3
        let session = makeSession(ratioIndex: baseIdx)
        let r       = session.proposedRatio(totalY: 0)
        let expected = TrackData.sortedRatios[baseIdx]
        #expect(r.num == expected.num)
        #expect(r.den == expected.den)
    }

    // MARK: — 7. commitCommand uses snapshot as old values

    @Test func commitCommand_usesSnapshotAsOld() {
        let session = makeSession()
        let cmd     = session.commitCommand(currentNum: 3, currentDen: 2)
        guard case .setRatio(_, let oldNum, let oldDen, let newNum, let newDen) = cmd else {
            Issue.record("Expected .setRatio command")
            return
        }
        #expect(oldNum == session.snapshotNumerator)
        #expect(oldDen == session.snapshotDenominator)
        #expect(newNum == 3)
        #expect(newDen == 2)
    }
}

// MARK: - StretchCountDragSession Tests (Arch-Slice-8)

struct StretchCountDragSessionTests {

    private func makeSession(startCount: Int = 16) -> StretchCountDragSession {
        StretchCountDragSession(trackID: UUID(), snapshotStepCount: startCount)
    }

    // MARK: — 1. No movement → snapshot count unchanged

    @Test func proposedStepCount_noMovement_returnsSnapshot() {
        let session = makeSession(startCount: 16)
        #expect(session.proposedStepCount(totalY: 0) == 16)
    }

    // MARK: — 2. Upward drag → higher step count

    @Test func proposedStepCount_upDrag_increases() {
        let session = makeSession(startCount: 16)
        // 18px up → delta = +1
        let count = session.proposedStepCount(totalY: -StretchCountDragSession.pxPerStep)
        #expect(count == 17)
    }

    // MARK: — 3. Downward drag → lower step count

    @Test func proposedStepCount_downDrag_decreases() {
        let session = makeSession(startCount: 16)
        let count = session.proposedStepCount(totalY: StretchCountDragSession.pxPerStep)
        #expect(count == 15)
    }

    // MARK: — 4. Clamp to minimum (1)

    @Test func proposedStepCount_clampsToMin() {
        let session = makeSession(startCount: 1)
        let count = session.proposedStepCount(totalY: 10_000)
        #expect(count == 1)
    }

    // MARK: — 5. Clamp to maximum (64)

    @Test func proposedStepCount_clampsToMax() {
        let session = makeSession(startCount: 64)
        let count = session.proposedStepCount(totalY: -10_000)
        #expect(count == 64)
    }

    // MARK: — 6. commitCommand uses snapshot as old value

    @Test func commitCommand_usesSnapshotAsOld() {
        let session = makeSession(startCount: 16)
        let cmd     = session.commitCommand(currentStepCount: 24)
        guard case .setStepCount(_, let old, let new) = cmd else {
            Issue.record("Expected .setStepCount command")
            return
        }
        #expect(old == 16)
        #expect(new == 24)
    }

    // MARK: — 7. Snapshot is immutable — session not mutated during drag

    @Test func snapshotIsImmutable_duringDrag() {
        let session = makeSession(startCount: 16)
        _ = session.proposedStepCount(totalY: -180)   // large drag
        #expect(session.snapshotStepCount == 16)        // snapshot unchanged
    }
}

// MARK: - InteractionController Stretch Tests (Arch-Slice-8)

struct InteractionControllerStretchTests {

    private func makeIC() -> (InteractionController, TrackData) {
        let ss    = ScrollState()
        let vc    = ViewportController(scrollState: ss)
        let ic    = InteractionController(viewportController: vc)
        let track = TrackData(name: "Stretch Test")
        return (ic, track)
    }

    // MARK: — Stretch Ratio Drag

    @Test func beginStretchRatioDrag_setsSessionActive() {
        let (ic, track) = makeIC()
        ic.beginStretchRatioDrag(track: track)
        #expect(ic.isSessionActive == true)
        guard case .stretchRatioDrag = ic.activeSession else {
            Issue.record("Expected .stretchRatioDrag session")
            return
        }
    }

    @Test func beginStretchRatioDrag_modalInvariant_blockedByExistingSession() {
        let (ic, track) = makeIC()
        ic.beginStretchRatioDrag(track: track)
        ic.beginStretchCountDrag(track: track)   // should be silently rejected
        guard case .stretchRatioDrag = ic.activeSession else {
            Issue.record("Modal invariant violated: second begin replaced first session")
            return
        }
    }

    @Test func updateStretchRatioDrag_appliesModelChange() {
        let (ic, track) = makeIC()
        // Set track to 1:1 ratio
        track.lane.stepLengthNumerator   = 1
        track.lane.stepLengthDenominator = 1
        ic.beginStretchRatioDrag(track: track)
        // Drag up by 24px → should advance to next ratio
        ic.updateStretchRatioDrag(totalY: -24, track: track)
        let isChanged = track.lane.stepLengthNumerator != 1 || track.lane.stepLengthDenominator != 1
        #expect(isChanged == true)
    }

    @Test func commitStretchRatioDrag_clearsSession() {
        let (ic, track) = makeIC()
        ic.beginStretchRatioDrag(track: track)
        ic.commitStretchRatioDrag(track: track, undoManager: nil)
        #expect(ic.isSessionActive == false)
        #expect(ic.activeSession.isNil)
    }

    @Test func commitStretchRatioDrag_registersUndo() throws {
        let (ic, track) = makeIC()
        track.lane.stepLengthNumerator   = 1
        track.lane.stepLengthDenominator = 1
        ic.beginStretchRatioDrag(track: track)
        ic.updateStretchRatioDrag(totalY: -24, track: track)

        let um = UndoManager()
        ic.commitStretchRatioDrag(track: track, undoManager: um)
        #expect(um.canUndo == true)
    }

    @Test func cancelStretchRatioDrag_restoresSnapshot() {
        let (ic, track) = makeIC()
        track.lane.stepLengthNumerator   = 1
        track.lane.stepLengthDenominator = 1
        ic.beginStretchRatioDrag(track: track)
        ic.updateStretchRatioDrag(totalY: -24, track: track)
        // Ratio has changed; cancel should restore
        ic.cancelStretchRatioDrag(track: track)
        #expect(track.lane.stepLengthNumerator   == 1)
        #expect(track.lane.stepLengthDenominator == 1)
        #expect(ic.isSessionActive == false)
    }

    // MARK: — Stretch Count Drag

    @Test func beginStretchCountDrag_setsSessionActive() {
        let (ic, track) = makeIC()
        ic.beginStretchCountDrag(track: track)
        #expect(ic.isSessionActive == true)
        guard case .stretchCountDrag = ic.activeSession else {
            Issue.record("Expected .stretchCountDrag session")
            return
        }
    }

    @Test func updateStretchCountDrag_appliesModelChange() {
        let (ic, track) = makeIC()
        let initial = track.lane.stepCount
        ic.beginStretchCountDrag(track: track)
        ic.updateStretchCountDrag(totalY: -18, track: track)   // up → +1
        #expect(track.lane.stepCount == initial + 1)
    }

    @Test func commitStretchCountDrag_clearsSession() {
        let (ic, track) = makeIC()
        ic.beginStretchCountDrag(track: track)
        ic.commitStretchCountDrag(track: track, undoManager: nil)
        #expect(ic.isSessionActive == false)
        #expect(ic.activeSession.isNil)
    }

    @Test func cancelStretchCountDrag_restoresSnapshot() {
        let (ic, track) = makeIC()
        let original = track.lane.stepCount
        ic.beginStretchCountDrag(track: track)
        ic.updateStretchCountDrag(totalY: -36, track: track)   // move +2 steps
        #expect(track.lane.stepCount == original + 2)
        ic.cancelStretchCountDrag(track: track)
        #expect(track.lane.stepCount == original)
        #expect(ic.isSessionActive == false)
    }

    @Test func modalInvariant_stretchCountBlockedDuringHandleDrag() {
        let (ic, track) = makeIC()
        ic.beginHandleDrag(track: track, pxPerStep: 40)
        ic.beginStretchCountDrag(track: track)   // must be rejected
        guard case .handleDrag = ic.activeSession else {
            Issue.record("Modal invariant violated: stretchCountDrag replaced handleDrag")
            return
        }
    }
}

// MARK: - CursorStateReducerTests (Cursor Phase 2 — Robustheit)
//
// CursorStateReducer is a pure struct — no AppKit, no side effects, no async.
// Tests cover all ownership transitions, idempotency guarantees, and the return
// values that drive the caller's AppKit calls.

struct CursorStateReducerTests {

    // MARK: — Initial state

    @Test func initialOwnership_isIdle() {
        let r = CursorStateReducer()
        #expect(r.ownership == .idle)
    }

    @Test func initialIsOwningCursor_isFalse() {
        let r = CursorStateReducer()
        #expect(r.isOwningCursor == false)
    }

    // MARK: — acquireIfNeeded (idle → session)

    @Test func acquireIfNeeded_fromIdle_returnsTrue() {
        var r = CursorStateReducer()
        let changed = r.acquireIfNeeded()
        #expect(changed == true)
    }

    @Test func acquireIfNeeded_fromIdle_setsSession() {
        var r = CursorStateReducer()
        r.acquireIfNeeded()
        #expect(r.ownership == .session)
    }

    @Test func acquireIfNeeded_fromIdle_isOwningCursorBecomesTrue() {
        var r = CursorStateReducer()
        r.acquireIfNeeded()
        #expect(r.isOwningCursor == true)
    }

    // MARK: — acquireIfNeeded idempotency (session → session)

    @Test func acquireIfNeeded_alreadySession_returnsFalse() {
        // Second acquisition must not signal a new transition.
        var r = CursorStateReducer()
        r.acquireIfNeeded()
        let changed = r.acquireIfNeeded()
        #expect(changed == false)
    }

    @Test func acquireIfNeeded_alreadySession_staysSession() {
        var r = CursorStateReducer()
        r.acquireIfNeeded()
        r.acquireIfNeeded()
        #expect(r.ownership == .session)
    }

    // MARK: — releaseIfNeeded (session → idle)

    @Test func releaseIfNeeded_fromSession_returnsTrue() {
        var r = CursorStateReducer()
        r.acquireIfNeeded()
        let changed = r.releaseIfNeeded()
        #expect(changed == true)
    }

    @Test func releaseIfNeeded_fromSession_setsIdle() {
        var r = CursorStateReducer()
        r.acquireIfNeeded()
        r.releaseIfNeeded()
        #expect(r.ownership == .idle)
    }

    @Test func releaseIfNeeded_fromSession_isOwningCursorBecomesFalse() {
        var r = CursorStateReducer()
        r.acquireIfNeeded()
        r.releaseIfNeeded()
        #expect(r.isOwningCursor == false)
    }

    // MARK: — releaseIfNeeded idempotency (idle → idle)

    @Test func releaseIfNeeded_alreadyIdle_returnsFalse() {
        // Release on idle must not signal a transition.
        var r = CursorStateReducer()
        let changed = r.releaseIfNeeded()
        #expect(changed == false)
    }

    @Test func releaseIfNeeded_alreadyIdle_staysIdle() {
        var r = CursorStateReducer()
        r.releaseIfNeeded()
        #expect(r.ownership == .idle)
    }

    // MARK: — Round-trip sequences

    @Test func acquireRelease_cycleRestoresIdle() {
        var r = CursorStateReducer()
        r.acquireIfNeeded()
        r.releaseIfNeeded()
        #expect(r.ownership == .idle)
        #expect(r.isOwningCursor == false)
    }

    @Test func multipleAcquireRelease_cyclesAreStable() {
        // Simulates rapid session start → end → start → end sequences.
        var r = CursorStateReducer()
        for _ in 0..<5 {
            r.acquireIfNeeded()
            #expect(r.isOwningCursor == true)
            r.releaseIfNeeded()
            #expect(r.isOwningCursor == false)
        }
    }

    @Test func modifierChangesDuringSession_doNotChangeOwnership() {
        // Modifier changes cause acquireIfNeeded() to be called again (already in session).
        // The reducer must stay in .session and return false (no new disableCursorRects call).
        var r = CursorStateReducer()
        r.acquireIfNeeded()   // session starts
        let changed1 = r.acquireIfNeeded()  // modifier change → same session
        let changed2 = r.acquireIfNeeded()  // another modifier change
        #expect(changed1 == false)
        #expect(changed2 == false)
        #expect(r.ownership == .session)
    }

    @Test func focusLost_thenFocusRegained_withSessionStillActive() {
        // Simulates: session active → focus lost (release) → focus regained (re-acquire).
        var r = CursorStateReducer()
        r.acquireIfNeeded()                     // session start
        let lostChanged = r.releaseIfNeeded()   // focus lost: forced release
        #expect(lostChanged == true)
        #expect(r.ownership == .idle)
        let gainedChanged = r.acquireIfNeeded() // focus regained, session still active
        #expect(gainedChanged == true)
        #expect(r.ownership == .session)
    }
}

// MARK: - CursorPolicyTests (Arch-Slice-9 Cursor/Modifier Phase 1)
//
// CursorPolicy is a pure, stateless enum — all inputs (hint + modifiers) are
// passed as arguments, so every case is fully deterministic without AppKit state.
//
// NSCursor standard cursors (arrow, crosshair, etc.) are AppKit singletons;
// identity comparison (===) is valid and consistent on macOS.

struct CursorPolicyTests {

    // MARK: — hint .none

    @Test func cursorPolicy_none_returnsArrow() {
        let cursor = CursorPolicy.cursor(hint: .none, modifiers: [])
        #expect(cursor === NSCursor.arrow)
    }

    @Test func cursorPolicy_none_withModifiers_returnsArrow() {
        // Modifier state is irrelevant for .none — always arrow.
        let cursor = CursorPolicy.cursor(hint: .none, modifiers: [.option, .command])
        #expect(cursor === NSCursor.arrow)
    }

    // MARK: — hint .resizeHorizontal

    @Test func cursorPolicy_resizeHorizontal_returnsResizeLeftRight() {
        let cursor = CursorPolicy.cursor(hint: .resizeHorizontal, modifiers: [])
        #expect(cursor === NSCursor.resizeLeftRight)
    }

    @Test func cursorPolicy_resizeHorizontal_withOption_returnsResizeLeftRight() {
        // Modifier does not change horizontal-resize semantics.
        let cursor = CursorPolicy.cursor(hint: .resizeHorizontal, modifiers: .option)
        #expect(cursor === NSCursor.resizeLeftRight)
    }

    // MARK: — hint .resizeVertical

    @Test func cursorPolicy_resizeVertical_returnsResizeUpDown() {
        let cursor = CursorPolicy.cursor(hint: .resizeVertical, modifiers: [])
        #expect(cursor === NSCursor.resizeUpDown)
    }

    @Test func cursorPolicy_resizeVertical_withOption_returnsResizeUpDown() {
        // Modifier does not change vertical-resize semantics.
        let cursor = CursorPolicy.cursor(hint: .resizeVertical, modifiers: .option)
        #expect(cursor === NSCursor.resizeUpDown)
    }

    // MARK: — hint .stretchVertical

    @Test func cursorPolicy_stretchVertical_returnsCustomCursor() {
        // CustomCursors.stretchVertical is a static let — pointer equality holds.
        let cursor = CursorPolicy.cursor(hint: .stretchVertical, modifiers: [])
        #expect(cursor === CustomCursors.stretchVertical)
    }

    @Test func cursorPolicy_stretchVertical_withOption_returnsCustomCursor() {
        // Modifier does not change stretch semantics (no copy/move distinction here).
        let cursor = CursorPolicy.cursor(hint: .stretchVertical, modifiers: .option)
        #expect(cursor === CustomCursors.stretchVertical)
    }

    // MARK: — hint .selectRegion

    @Test func cursorPolicy_selectRegion_returnsCrosshair() {
        let cursor = CursorPolicy.cursor(hint: .selectRegion, modifiers: [])
        #expect(cursor === NSCursor.crosshair)
    }

    @Test func cursorPolicy_selectRegion_withOption_returnsCrosshair() {
        // Modifier does not affect rubber-band selection cursor.
        let cursor = CursorPolicy.cursor(hint: .selectRegion, modifiers: .option)
        #expect(cursor === NSCursor.crosshair)
    }

    // MARK: — hint .moveStep (modifier-sensitive)

    @Test func cursorPolicy_moveStep_noModifiers_returnsClosedHand() {
        // No modifier → move semantics.
        let cursor = CursorPolicy.cursor(hint: .moveStep, modifiers: [])
        #expect(cursor === NSCursor.closedHand)
    }

    @Test func cursorPolicy_moveStep_commandOnly_returnsClosedHand() {
        // Command alone does not trigger copy semantics.
        let cursor = CursorPolicy.cursor(hint: .moveStep, modifiers: .command)
        #expect(cursor === NSCursor.closedHand)
    }

    @Test func cursorPolicy_moveStep_shiftOnly_returnsClosedHand() {
        // Shift alone does not trigger copy semantics.
        let cursor = CursorPolicy.cursor(hint: .moveStep, modifiers: .shift)
        #expect(cursor === NSCursor.closedHand)
    }

    @Test func cursorPolicy_moveStep_withOption_returnsDragCopy() {
        // Option held → copy semantics (macOS standard drag-copy badge).
        let cursor = CursorPolicy.cursor(hint: .moveStep, modifiers: .option)
        #expect(cursor === NSCursor.dragCopy)
    }

    @Test func cursorPolicy_moveStep_withOptionAndShift_returnsDragCopy() {
        // Option takes precedence; Shift is irrelevant.
        let cursor = CursorPolicy.cursor(hint: .moveStep, modifiers: [.option, .shift])
        #expect(cursor === NSCursor.dragCopy)
    }

    @Test func cursorPolicy_moveStep_withOptionAndCommand_returnsDragCopy() {
        // Option + Command → still copy semantics.
        let cursor = CursorPolicy.cursor(hint: .moveStep, modifiers: [.option, .command])
        #expect(cursor === NSCursor.dragCopy)
    }
}

// MARK: - ICCursorHintTests (Arch-Slice-9 Cursor/Modifier Phase 1)
//
// Verifies that IC.sessionCursorHint is set to the correct value by each begin* method
// and reset to .none by each commit* / cancel* method.
//
// These are the thinnest meaningful tests: one begin + one commit/cancel per session type.
// Full lifecycle coverage (update*, modal invariant) is already in the per-session structs above.

struct ICCursorHintTests {

    private func makeIC() -> (InteractionController, TrackData) {
        let ss    = ScrollState()
        let vc    = ViewportController(scrollState: ss)
        let ic    = InteractionController(viewportController: vc)
        let track = TrackData(name: "Test")
        return (ic, track)
    }

    // MARK: — handleDrag (resizeHorizontal)

    @Test func beginHandleDrag_setsResizeHorizontalHint() {
        let (ic, track) = makeIC()
        ic.beginHandleDrag(track: track, pxPerStep: 40)
        #expect(ic.sessionCursorHint == .resizeHorizontal)
    }

    @Test func commitHandleDrag_resetsHintToNone() {
        let (ic, track) = makeIC()
        ic.beginHandleDrag(track: track, pxPerStep: 40)
        ic.commitHandleDrag(track: track, undoManager: nil)
        #expect(ic.sessionCursorHint == .none)
    }

    @Test func cancelHandleDrag_resetsHintToNone() {
        let (ic, track) = makeIC()
        ic.beginHandleDrag(track: track, pxPerStep: 40)
        ic.cancelHandleDrag(track: track)
        #expect(ic.sessionCursorHint == .none)
    }

    // MARK: — ratioDrag (resizeHorizontal)

    @Test func beginRatioDrag_setsResizeHorizontalHint() {
        let (ic, track) = makeIC()
        ic.beginRatioDrag(track: track, contentUnit: 40, baseRatioIndex: 0)
        #expect(ic.sessionCursorHint == .resizeHorizontal)
    }

    @Test func commitRatioDrag_resetsHintToNone() {
        let (ic, track) = makeIC()
        ic.beginRatioDrag(track: track, contentUnit: 40, baseRatioIndex: 0)
        ic.commitRatioDrag(track: track, undoManager: nil)
        #expect(ic.sessionCursorHint == .none)
    }

    @Test func cancelRatioDrag_resetsHintToNone() {
        let (ic, track) = makeIC()
        ic.beginRatioDrag(track: track, contentUnit: 40, baseRatioIndex: 0)
        ic.cancelRatioDrag(track: track)
        #expect(ic.sessionCursorHint == .none)
    }

    // MARK: — rubberBand (selectRegion)

    @Test func beginRubberBand_setsSelectRegionHint() {
        let (ic, track) = makeIC()
        ic.beginRubberBand(
            trackID:   track.id,
            contentX:  100,
            screenX:   100,
            y:         0,
            stepWidth: 40,
            stepCount: track.lane.stepCount
        )
        #expect(ic.sessionCursorHint == .selectRegion)
    }

    @Test func commitRubberBand_resetsHintToNone() {
        let (ic, track) = makeIC()
        ic.beginRubberBand(
            trackID:   track.id,
            contentX:  100,
            screenX:   100,
            y:         0,
            stepWidth: 40,
            stepCount: track.lane.stepCount
        )
        ic.commitRubberBand()
        #expect(ic.sessionCursorHint == .none)
    }

    @Test func cancelRubberBand_resetsHintToNone() {
        let (ic, track) = makeIC()
        ic.beginRubberBand(
            trackID:   track.id,
            contentX:  100,
            screenX:   100,
            y:         0,
            stepWidth: 40,
            stepCount: track.lane.stepCount
        )
        ic.cancelRubberBand()
        #expect(ic.sessionCursorHint == .none)
    }

    // MARK: — pitchDrag (resizeVertical)

    @Test func beginPitchDrag_setsResizeVerticalHint() {
        let (ic, track) = makeIC()
        ic.beginPitchDrag(track: track, stepIndex: 0)
        #expect(ic.sessionCursorHint == .resizeVertical)
    }

    @Test func commitPitchDrag_resetsHintToNone() {
        let (ic, track) = makeIC()
        ic.beginPitchDrag(track: track, stepIndex: 0)
        ic.commitPitchDrag(track: track, undoManager: nil)
        #expect(ic.sessionCursorHint == .none)
    }

    @Test func cancelPitchDrag_resetsHintToNone() {
        let (ic, track) = makeIC()
        ic.beginPitchDrag(track: track, stepIndex: 0)
        ic.cancelPitchDrag(track: track)
        #expect(ic.sessionCursorHint == .none)
    }

    // MARK: — stepSwap (moveStep)

    @Test func beginStepSwap_setsMoveStepHint() {
        let (ic, track) = makeIC()
        ic.beginStepSwap(track: track, sourceIndex: 0, stepWidth: 40)
        #expect(ic.sessionCursorHint == .moveStep)
    }

    @Test func commitStepSwap_resetsHintToNone() {
        let (ic, track) = makeIC()
        ic.beginStepSwap(track: track, sourceIndex: 0, stepWidth: 40)
        ic.commitStepSwap(track: track, isCopy: false, undoManager: nil)
        #expect(ic.sessionCursorHint == .none)
    }

    @Test func cancelStepSwap_resetsHintToNone() {
        let (ic, track) = makeIC()
        ic.beginStepSwap(track: track, sourceIndex: 0, stepWidth: 40)
        ic.cancelStepSwap()
        #expect(ic.sessionCursorHint == .none)
    }

    // MARK: — stretchRatioDrag (stretchVertical)

    @Test func beginStretchRatioDrag_setsStretchVerticalHint() {
        let (ic, track) = makeIC()
        ic.beginStretchRatioDrag(track: track)
        #expect(ic.sessionCursorHint == .stretchVertical)
    }

    @Test func commitStretchRatioDrag_resetsHintToNone() {
        let (ic, track) = makeIC()
        ic.beginStretchRatioDrag(track: track)
        ic.commitStretchRatioDrag(track: track, undoManager: nil)
        #expect(ic.sessionCursorHint == .none)
    }

    @Test func cancelStretchRatioDrag_resetsHintToNone() {
        let (ic, track) = makeIC()
        ic.beginStretchRatioDrag(track: track)
        ic.cancelStretchRatioDrag(track: track)
        #expect(ic.sessionCursorHint == .none)
    }

    // MARK: — stretchCountDrag (stretchVertical)

    @Test func beginStretchCountDrag_setsStretchVerticalHint() {
        let (ic, track) = makeIC()
        ic.beginStretchCountDrag(track: track)
        #expect(ic.sessionCursorHint == .stretchVertical)
    }

    @Test func commitStretchCountDrag_resetsHintToNone() {
        let (ic, track) = makeIC()
        ic.beginStretchCountDrag(track: track)
        ic.commitStretchCountDrag(track: track, undoManager: nil)
        #expect(ic.sessionCursorHint == .none)
    }

    @Test func cancelStretchCountDrag_resetsHintToNone() {
        let (ic, track) = makeIC()
        ic.beginStretchCountDrag(track: track)
        ic.cancelStretchCountDrag(track: track)
        #expect(ic.sessionCursorHint == .none)
    }

    // MARK: — hint is .none before any session

    @Test func initialHint_isNone() {
        let (ic, _) = makeIC()
        #expect(ic.sessionCursorHint == .none)
    }
}

// MARK: - ActiveSession Equatable helpers (for test assertions)
// ActiveSession is not Equatable by default because HandleDragSession and
// RatioDragSession contain UUIDs. Adding a local nil-check helper instead.

extension Optional where Wrapped == ActiveSession {
    var isNil: Bool { self == nil }
}
