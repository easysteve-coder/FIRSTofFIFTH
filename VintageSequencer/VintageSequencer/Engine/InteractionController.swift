import Foundation
import Combine      // ObservableObject, @Published, AnyCancellable — no transitive import in Xcode 26
import AppKit       // UndoManager
import CoreGraphics

// MARK: - InteractionController

/// Global interaction state machine.
///
/// **Modal invariant:** At most one session is active at any time.
/// `begin…` methods silently no-op if a session is already active —
/// the caller does not need to check first.
///
/// **Ownership:**
///   - Session state              → this object
///   - Viewport scroll            → `ViewportController.scroll(by:)`
///   - Session lock / unlock      → `ViewportController.beginSession()` / `endSession()`
///   - Track mutations (handles)  → `ModelWriter.apply(_:to:undoManager:)`
///   - Selection output           → `rubberBandUpdate` (@Published, consumed by coordinators
///                                  via Combine, NOT read directly from SwiftUI bodies)
///
/// **Observable surface is minimal by design:**
/// - `isSessionActive: Bool` — @Published. Changes only at session begin/end (2× per drag).
///   Views use this to guard conflicting gestures.
/// - `rubberBandUpdate: RubberBandUpdate?` — @Published. Changes on every drag event
///   BUT consumed via Combine in StepGridCoordinator (NOT from SwiftUI body), so it
///   never causes O(N_lanes) SwiftUI re-renders.
/// - `_session: ActiveSession?` — NON-published. Content-X updates (rubber band) do NOT
///   trigger re-renders. Handle sessions never mutate _session during drag (no accumulator).
///
/// **Arch-Slice-7 — AutoScroll + Handle-Geometrie:**
///   - Edge-scroll timer lives here, not in views. `updateEdgeScrollPointer(x:viewWidth:)`
///     starts/updates it; `endEdgeScroll()` stops it. All session-end paths call `endEdgeScroll()`.
///   - Handle sessions (HandleDrag, RatioDrag) store `scrollOffsetAtStart` and receive
///     `currentScrollOffset` on every update — content-space displacement eliminates handle drift.
///
/// **Thread safety:** Must be called on the main thread.
final class InteractionController: ObservableObject {

    // MARK: - Published state

    /// True while any interaction session is active.
    ///
    /// Views observe this to suppress conflicting gestures.
    /// Changes only at begin and end of each session (2 events per drag).
    private(set) var isSessionActive: Bool = false

    /// Lightweight cursor intent — the ONLY cursor channel out of IC.
    ///
    /// Set to the appropriate hint in every `begin*` method;
    /// reset to `.none` in every `commit*` and `cancel*` method.
    /// `CursorController` subscribes via Combine and applies `CursorPolicy`.
    /// No SwiftUI views read this directly.
    @Published private(set) var sessionCursorHint: SessionCursorHint = .none

    /// Current rubber-band state, published on every drag event.
    ///
    /// **NOT read directly from SwiftUI view bodies** — only consumed via
    /// Combine sinks in StepGridCoordinator. This keeps rubber-band updates
    /// from triggering N-lane SwiftUI re-renders.
    ///
    /// Non-nil while the drag is active (phase == .active), and for one
    /// final update at commit (phase == .committed) or cancel (phase == .cancelled).
    @Published private(set) var rubberBandUpdate: RubberBandUpdate? = nil

    /// Current step-swap render state, published on every drag event.
    ///
    /// **NOT read directly from SwiftUI view bodies** — consumed via
    /// Combine sink in StepGridCoordinator, which writes `dragSourceIndex` /
    /// `dragTargetIndex` for step-button overlay rendering.
    ///
    /// Follows the same lifecycle as `rubberBandUpdate`:
    /// non-nil for the session duration plus one final update on commit/cancel.
    @Published private(set) var stepSwapUpdate: StepSwapUpdate? = nil

    // MARK: - Non-published session state

    /// The live session value. NON-@Published: content-X updates during rubber-band
    /// and session reads during handle drag must NOT trigger SwiftUI re-renders.
    private var _session: ActiveSession? = nil

    /// Read-only access for gesture code and tests.
    var activeSession: ActiveSession? { _session }

    // MARK: - Dependencies

    let viewportController: ViewportController   // internal + tests
    private let modelWriter = ModelWriter()

    // MARK: - Scroll sync (rubber band)

    /// Combine subscription to viewport scroll offset.
    /// Active for the lifetime of this controller.
    /// When the offset changes during an active rubber-band session,
    /// `currentContentX` is recomputed from the stored `currentScreenX`.
    private var scrollSink: AnyCancellable?

    // MARK: - IC-owned edge-scroll timer (Arch-Slice-7)

    /// Latest pointer X reported by the dragging view (screen space).
    /// `nil` when no edge scroll is in progress.
    private var edgeScrollPointerX:  CGFloat? = nil

    /// Viewport width reported by the dragging view — used for zone computation.
    private var edgeScrollViewWidth: CGFloat  = 0

    /// 60 Hz timer that polls `EdgeScrollVelocity` and applies scroll via VC.
    /// Created by `updateEdgeScrollPointer`; invalidated by `endEdgeScroll`.
    private var edgeScrollTimer: Timer?

    // MARK: - Init

    init(viewportController: ViewportController) {
        self.viewportController = viewportController
        setupScrollSync()
    }

    deinit {
        endEdgeScroll()
    }

    private func setupScrollSync() {
        scrollSink = viewportController.scrollState.$hScrollOffset
            .receive(on: DispatchQueue.main)
            .sink { [weak self] offset in
                self?.handleScrollOffsetChange(offset)
            }
    }

    /// Called when `scrollState.hScrollOffset` changes.
    /// If a rubber-band session is active, recomputes `currentContentX`
    /// from the stored screen-space pointer position + new offset.
    private func handleScrollOffsetChange(_ offset: CGFloat) {
        guard case .rubberBand(var session) = _session else { return }
        session.currentContentX = session.currentScreenX + offset
        _session = .rubberBand(session)
        publishRubberBandUpdate(from: session, phase: .active)
    }

    // MARK: - Step-Lane Sessions (Lane Slice 5 / CC-Lane Slice 1)

    /// Runtime guard at the interaction boundary for genuinely step-only sessions.
    ///
    /// Ab CC-Lane Slice 1 (v1.8.0) rufen nur noch die step-inhaltlichen
    /// `begin*`-Einstiege (Pitch-Drag, Step-Swap) diese Funktion. Corner-Handle-
    /// Sessions (HandleDrag, RatioDrag, StretchRatioDrag, StretchCountDrag) sind
    /// lane-neutral und dürfen auch auf CC-Lanes geöffnet werden.
    ///
    /// Trifft eine step-only Session trotzdem auf eine CC-Lane, ist das ein
    /// Aufrufer-Fehler (UI-Bug, der Step-Tasten statt CC-Knobs präsentiert hat).
    /// `preconditionFailure` im CC-Zweig zwingt uns, den Fehler sofort zu sehen,
    /// statt ihn als stillen Misshit zu kaschieren.
    private func requireStepLane(_ lane: LaneData) {
        switch lane.kind {
        case .step:
            break
        case .cc:
            preconditionFailure("step-lane-only session opened on cc lane")
        }
    }

    // MARK: - Step-Count Handle Drag API

    /// Begin a step-count handle drag session.
    ///
    /// Captures `scrollOffsetAtStart` so `updateHandleDrag` can compensate
    /// for viewport shifts during auto-scroll (Arch-Slice-7).
    func beginHandleDrag(track: TrackData, pxPerStep: CGFloat) {
        guard _session == nil else { return }   // modal invariant
        _session = .handleDrag(HandleDragSession(
            trackID:             track.id,
            snapshotStepCount:   track.lane.stepCount,
            pxPerStep:           pxPerStep,
            scrollOffsetAtStart: viewportController.scrollState.hScrollOffset
        ))
        isSessionActive = true
        sessionCursorHint = .resizeHorizontal
        viewportController.beginSession()
    }

    /// Update the active step-count handle drag.
    ///
    /// `totalX` is `DragGesture.translation.width` (total offset from drag-start,
    /// never a delta). The session converts it to content-space displacement
    /// using `scrollOffsetAtStart` + current scroll offset.
    func updateHandleDrag(totalX: CGFloat, track: TrackData) {
        guard case .handleDrag(let session) = _session else { return }
        let currentOffset = viewportController.scrollState.hScrollOffset
        let proposed = session.proposedStepCount(translationX: totalX,
                                                 currentScrollOffset: currentOffset)
        guard proposed != track.lane.stepCount else { return }
        modelWriter.apply(
            ModelCommand.setStepCount(trackID: session.trackID,
                                      old:     session.snapshotStepCount,
                                      new:     proposed),
            to: track,
            undoManager: nil
        )
        // _session is NOT mutated — no accumulator field exists.
    }

    /// Commit the active step-count handle drag (registers undo).
    func commitHandleDrag(track: TrackData, undoManager: UndoManager?) {
        guard case .handleDrag(let session) = _session else { return }
        endEdgeScroll()
        let command = session.commitCommand(currentStepCount: track.lane.stepCount)
        modelWriter.apply(command, to: track, undoManager: undoManager)
        _session = nil
        isSessionActive = false
        sessionCursorHint = .none
        viewportController.endSession()
    }

    // MARK: - Generischer Abbruch (v1.12.20)

    /// Bricht die laufende Session ab, gleich welchen Typs — für alle Fälle, in denen die
    /// auslösende View ihr `onEnded` nicht mehr liefern kann (Spur gelöscht, Pattern
    /// gewechselt, Preset geladen, Fenster verliert den Fokus). Ohne diesen Weg bliebe
    /// `_session` gesetzt: jedes weitere `begin…` wäre wirkungslos und der Viewport gesperrt.
    ///
    /// `resolveTrack` liefert die Spur der Session, falls es sie noch gibt; dann wird ihr
    /// Ausgangszustand wiederhergestellt. Gibt es sie nicht mehr, wird nur die Session beendet.
    func cancelActiveSession(resolveTrack: (UUID) -> TrackData?) {
        guard let session = _session else { return }
        switch session {
        case .handleDrag(let s):
            if let t = resolveTrack(s.trackID) { cancelHandleDrag(track: t) }
        case .ratioDrag(let s):
            if let t = resolveTrack(s.trackID) { cancelRatioDrag(track: t) }
        case .rubberBand:
            cancelRubberBand()
        case .pitchDrag(let s):
            if let t = resolveTrack(s.trackID) { cancelPitchDrag(track: t) }
        case .stepSwap:
            cancelStepSwap()
        case .stretchRatioDrag(let s):
            if let t = resolveTrack(s.trackID) { cancelStretchRatioDrag(track: t) }
        case .stretchCountDrag(let s):
            if let t = resolveTrack(s.trackID) { cancelStretchCountDrag(track: t) }
        }
        // Spur nicht mehr auffindbar → Session ohne Modellzugriff beenden.
        if _session != nil {
            endEdgeScroll()
            _session = nil
            isSessionActive = false
            sessionCursorHint = .none
            viewportController.endSession()
        }
    }

    /// Cancel the active step-count handle drag (restores snapshot, no undo).
    func cancelHandleDrag(track: TrackData) {
        guard case .handleDrag(let session) = _session else { return }
        endEdgeScroll()
        modelWriter.apply(
            ModelCommand.setStepCount(trackID: session.trackID,
                                      old:     track.lane.stepCount,
                                      new:     session.snapshotStepCount),
            to: track,
            undoManager: nil
        )
        _session = nil
        isSessionActive = false
        sessionCursorHint = .none
        viewportController.endSession()
    }

    // MARK: - Ratio Handle Drag API

    /// Begin a ratio handle drag session.
    ///
    /// Captures `scrollOffsetAtStart` for scroll-compensated geometry (Arch-Slice-7).
    /// `ratios`: Auswahl der Lane in der Taktart des Projekts (nil = 4/4).
    func beginRatioDrag(track: TrackData, contentUnit: CGFloat, baseRatioIndex: Int,
                        ratios: [(num: Int, den: Int)]? = nil) {
        guard _session == nil else { return }
        _session = .ratioDrag(RatioDragSession(
            trackID:             track.id,
            snapshotNumerator:   track.lane.stepLengthNumerator,
            snapshotDenominator: track.lane.stepLengthDenominator,
            baseRatioIndex:      baseRatioIndex,
            contentUnit:         contentUnit,
            scrollOffsetAtStart: viewportController.scrollState.hScrollOffset,
            ratios:              ratios ?? track.lane.ratioOptions(.common),
            pxPerLongStep:       contentUnit / CGFloat(max(1, track.lane.stepCount))
        ))
        isSessionActive = true
        sessionCursorHint = .resizeHorizontal
        viewportController.beginSession()
    }

    /// Update the active ratio drag.
    ///
    /// `totalX` is `DragGesture.translation.width` (total offset, never a delta).
    func updateRatioDrag(totalX: CGFloat, track: TrackData) {
        guard case .ratioDrag(let session) = _session else { return }
        let currentOffset = viewportController.scrollState.hScrollOffset
        let r = session.proposedRatio(translationX: totalX, currentScrollOffset: currentOffset)
        guard r.num != track.lane.stepLengthNumerator
           || r.den != track.lane.stepLengthDenominator else { return }
        modelWriter.apply(
            ModelCommand.setRatio(trackID: session.trackID,
                                  oldNum:  session.snapshotNumerator,
                                  oldDen:  session.snapshotDenominator,
                                  newNum:  r.num,
                                  newDen:  r.den),
            to: track,
            undoManager: nil
        )
        // _session is NOT mutated — no accumulator field exists.
    }

    /// Commit the active ratio drag (registers undo).
    func commitRatioDrag(track: TrackData, undoManager: UndoManager?) {
        guard case .ratioDrag(let session) = _session else { return }
        endEdgeScroll()
        let command = session.commitCommand(
            currentNum: track.lane.stepLengthNumerator,
            currentDen: track.lane.stepLengthDenominator
        )
        modelWriter.apply(command, to: track, undoManager: undoManager)
        _session = nil
        isSessionActive = false
        sessionCursorHint = .none
        viewportController.endSession()
    }

    /// Cancel the active ratio drag (restores snapshot, no undo).
    func cancelRatioDrag(track: TrackData) {
        guard case .ratioDrag(let session) = _session else { return }
        endEdgeScroll()
        modelWriter.apply(
            ModelCommand.setRatio(trackID: session.trackID,
                                  oldNum:  track.lane.stepLengthNumerator,
                                  oldDen:  track.lane.stepLengthDenominator,
                                  newNum:  session.snapshotNumerator,
                                  newDen:  session.snapshotDenominator),
            to: track,
            undoManager: nil
        )
        _session = nil
        isSessionActive = false
        sessionCursorHint = .none
        viewportController.endSession()
    }

    // MARK: - Rubber Band Selection API

    /// Begin a rubber-band selection session.
    ///
    /// **Coordinate convention:** All X values must be in CONTENT space
    /// (= screenX + hScrollOffset). The session never stores screen-space
    /// coordinates — only `currentScreenX` is kept as a helper for
    /// scroll-sync recomputation.
    ///
    /// Guards modal invariant — silently no-ops if a session is active.
    ///
    /// - Parameters:
    ///   - trackID:    The track being selected.
    ///   - contentX:   Drag-start X in content space (= startScreenX + hScrollOffset).
    ///   - screenX:    Drag-start X in screen space (for scroll-sync).
    ///   - y:          Drag-start Y (screen space).
    ///   - stepWidth:  Step slot width including spacing. Stable for session.
    ///   - stepCount:  Track step count. Stable for session.
    func beginRubberBand(
        trackID:   UUID,
        contentX:  CGFloat,
        screenX:   CGFloat,
        y:         CGFloat,
        stepWidth: CGFloat,
        stepCount: Int
    ) {
        guard _session == nil else { return }   // modal invariant

        let session = RubberBandSession(
            trackID:         trackID,
            anchorContentX:  contentX,
            anchorY:         y,
            currentContentX: contentX,
            currentY:        y,
            currentScreenX:  screenX,
            stepWidth:       stepWidth,
            stepCount:       stepCount
        )
        _session = .rubberBand(session)
        isSessionActive = true
        sessionCursorHint = .selectRegion
        viewportController.beginSession()
        publishRubberBandUpdate(from: session, phase: .active)
    }

    /// Update the active rubber-band session with the latest pointer position.
    ///
    /// - Parameters:
    ///   - contentX:  Current pointer X in CONTENT space.
    ///   - screenX:   Current pointer X in SCREEN space (stored for scroll-sync).
    ///   - y:         Current pointer Y (screen space).
    func updateRubberBand(contentX: CGFloat, screenX: CGFloat, y: CGFloat) {
        guard case .rubberBand(var session) = _session else { return }
        session.currentContentX = contentX
        session.currentScreenX  = screenX
        session.currentY        = y
        _session = .rubberBand(session)
        publishRubberBandUpdate(from: session, phase: .active)
    }

    /// Commit the rubber-band selection.
    func commitRubberBand() {
        guard case .rubberBand(let session) = _session else { return }
        endEdgeScroll()
        publishRubberBandUpdate(from: session, phase: .committed)
        _session = nil
        isSessionActive = false
        sessionCursorHint = .none
        viewportController.endSession()
    }

    /// Cancel the rubber-band selection.
    func cancelRubberBand() {
        guard case .rubberBand(let session) = _session else { return }
        endEdgeScroll()
        publishRubberBandUpdate(from: session, phase: .cancelled)
        _session = nil
        isSessionActive = false
        sessionCursorHint = .none
        viewportController.endSession()
    }

    // MARK: - Pitch Drag API (Arch-Slice-4)

    /// Begin a pitch-drag session for the given step.
    ///
    /// - Parameters:
    ///   - anchorY: Translation der Geste beim Beginn; Änderungen zählen ab hier.
    ///   - velocity: true ändert die Velocity statt der Tonhöhe (⌥ beim Ziehen).
    func beginPitchDrag(track: TrackData, stepIndex: Int, anchorY: CGFloat = 0, velocity: Bool = false) {
        guard _session == nil else { return }
        requireStepLane(track.lane)
        _session = .pitchDrag(PitchDragSession(
            trackID:       track.id,
            stepsSnapshot: track.lane.steps,
            stepIndex:     stepIndex,
            anchorY:       anchorY,
            editsVelocity: velocity
        ))
        isSessionActive = true
        sessionCursorHint = .resizeVertical
        viewportController.beginSession()
    }

    /// Update the active pitch-drag session with a new vertical translation.
    ///
    /// - Returns: The new notes if they changed (for MIDI preview); `nil` if
    ///   the semitone offset is unchanged from the last applied update.
    @discardableResult
    func updatePitchDrag(totalY: CGFloat, track: TrackData) -> [Int]? {
        guard case .pitchDrag(var session) = _session else { return nil }
        if session.editsVelocity {
            // Velocity-Ziehen: derselbe Sitzungsrahmen (Snapshot, Commit, Abbruch); live wird
            // das Step-Array ersetzt. Kein Vorhören — Rückgabe nil.
            let v = session.proposedVelocity(totalY: totalY)
            guard v != session.lastAppliedSemitones,
                  track.lane.steps.indices.contains(session.stepIndex) else { return nil }
            session.lastAppliedSemitones = v
            _session = .pitchDrag(session)
            var steps = track.lane.steps
            steps[session.stepIndex].velocity = v
            modelWriter.apply(.setSteps(trackID: session.trackID, oldSteps: track.lane.steps,
                                        newSteps: steps, actionName: ""),
                              to: track, undoManager: nil)
            return nil
        }
        let semis = session.semitones(totalY: totalY)
        guard semis != session.lastAppliedSemitones else { return nil }
        let newNotes = session.proposedNotes(totalY: totalY)
        session.lastAppliedSemitones = semis
        _session = .pitchDrag(session)
        modelWriter.apply(
            .setPitchNotes(
                trackID:   session.trackID,
                stepIndex: session.stepIndex,
                oldNotes:  session.baseNotes,
                newNotes:  newNotes
            ),
            to: track,
            undoManager: nil
        )
        return newNotes
    }

    /// Commit the active pitch-drag session (registers undo).
    func commitPitchDrag(track: TrackData, undoManager: UndoManager?) {
        guard case .pitchDrag(let session) = _session else { return }
        endEdgeScroll()
        modelWriter.apply(
            .setSteps(
                trackID:    session.trackID,
                oldSteps:   session.stepsSnapshot,
                newSteps:   track.lane.steps,
                actionName: session.editsVelocity ? "Velocity" : "Pitch Drag"
            ),
            to: track,
            undoManager: undoManager
        )
        _session = nil
        isSessionActive = false
        sessionCursorHint = .none
        viewportController.endSession()
    }

    /// Cancel the active pitch-drag session (restores snapshot, no undo).
    func cancelPitchDrag(track: TrackData) {
        guard case .pitchDrag(let session) = _session else { return }
        endEdgeScroll()
        modelWriter.apply(
            .setSteps(
                trackID:    session.trackID,
                oldSteps:   track.lane.steps,
                newSteps:   session.stepsSnapshot,
                actionName: ""
            ),
            to: track,
            undoManager: nil
        )
        _session = nil
        isSessionActive = false
        sessionCursorHint = .none
        viewportController.endSession()
    }

    // MARK: - Step Swap API (Arch-Slice-5)

    /// Begin a step-swap session for the given source step.
    func beginStepSwap(track: TrackData, sourceIndex: Int, stepWidth: CGFloat) {
        guard _session == nil else { return }
        requireStepLane(track.lane)
        let session = StepSwapSession(
            trackID:       track.id,
            stepsSnapshot: track.lane.steps,
            sourceIndex:   sourceIndex,
            stepWidth:     stepWidth,
            targetIndex:   sourceIndex
        )
        _session = .stepSwap(session)
        isSessionActive = true
        sessionCursorHint = .moveStep
        viewportController.beginSession()
        publishStepSwapUpdate(session: session, phase: .active)
    }

    /// Update the active step-swap session with a new horizontal translation.
    func updateStepSwap(translationX: CGFloat, track: TrackData) {
        guard case .stepSwap(var session) = _session else { return }
        let proposed = session.proposedTargetIndex(translationX: translationX)
        guard proposed != session.targetIndex else { return }
        session.targetIndex = proposed
        _session = .stepSwap(session)
        publishStepSwapUpdate(session: session, phase: .active)
    }

    /// Commit the active step-swap session.
    func commitStepSwap(track: TrackData, isCopy: Bool, undoManager: UndoManager?) {
        guard case .stepSwap(let session) = _session else { return }
        endEdgeScroll()
        defer {
            _session = nil
            isSessionActive = false
            sessionCursorHint = .none
            viewportController.endSession()
            publishStepSwapUpdate(session: session, phase: .committed)
        }
        guard session.targetIndex != session.sourceIndex else { return }
        modelWriter.apply(
            session.commitCommand(isCopy: isCopy),
            to: track,
            undoManager: undoManager
        )
    }

    /// Cancel the active step-swap session.
    func cancelStepSwap() {
        guard case .stepSwap(let session) = _session else { return }
        endEdgeScroll()
        _session = nil
        isSessionActive = false
        sessionCursorHint = .none
        viewportController.endSession()
        publishStepSwapUpdate(session: session, phase: .cancelled)
    }

    // MARK: - Stretch Ratio Drag API (Arch-Slice-8)

    /// Begin a stretch-handle ratio-zone drag session.
    ///
    /// Captures the current ratio index as the zero-offset reference for
    /// delta computation. No scroll compensation — vertical drag only.
    ///
    /// Guards modal invariant — silently no-ops if a session is already active.
    func beginStretchRatioDrag(track: TrackData, ratios: [(num: Int, den: Int)]? = nil) {
        guard _session == nil else { return }
        let options = ratios ?? track.lane.ratioOptions(.common)
        let idx = options.firstIndex(where: {
            $0.num == track.lane.stepLengthNumerator && $0.den == track.lane.stepLengthDenominator
        }) ?? (options.count / 2)
        _session = .stretchRatioDrag(StretchRatioDragSession(
            trackID:             track.id,
            snapshotNumerator:   track.lane.stepLengthNumerator,
            snapshotDenominator: track.lane.stepLengthDenominator,
            snapshotRatioIndex:  idx,
            ratios:              options
        ))
        isSessionActive = true
        sessionCursorHint = .stretchVertical   // custom cursor, distinct from pitch drag
        viewportController.beginSession()
    }

    /// Update the active stretch ratio drag with a new vertical translation.
    ///
    /// `totalY` is `DragGesture.translation.height` (total from drag-start; never a delta).
    /// The session computes the proposed ratio index from the total displacement —
    /// no accumulator, no delta.
    func updateStretchRatioDrag(totalY: CGFloat, track: TrackData) {
        guard case .stretchRatioDrag(let session) = _session else { return }
        let r = session.proposedRatio(totalY: totalY)
        guard r.num != track.lane.stepLengthNumerator || r.den != track.lane.stepLengthDenominator else { return }
        modelWriter.apply(
            ModelCommand.setRatio(trackID: session.trackID,
                                  oldNum:  session.snapshotNumerator, oldDen: session.snapshotDenominator,
                                  newNum:  r.num,                     newDen: r.den),
            to: track, undoManager: nil
        )
        // _session is NOT mutated — no accumulator field exists.
    }

    /// Commit the active stretch ratio drag (registers one undo entry for the full drag range).
    func commitStretchRatioDrag(track: TrackData, undoManager: UndoManager?) {
        guard case .stretchRatioDrag(let session) = _session else { return }
        endEdgeScroll()
        let command = session.commitCommand(currentNum: track.lane.stepLengthNumerator,
                                            currentDen: track.lane.stepLengthDenominator)
        modelWriter.apply(command, to: track, undoManager: undoManager)
        _session = nil
        isSessionActive = false
        sessionCursorHint = .none
        viewportController.endSession()
    }

    /// Cancel the active stretch ratio drag (restores snapshot value, no undo entry).
    func cancelStretchRatioDrag(track: TrackData) {
        guard case .stretchRatioDrag(let session) = _session else { return }
        endEdgeScroll()
        modelWriter.apply(
            ModelCommand.setRatio(trackID: session.trackID,
                                  oldNum:  track.lane.stepLengthNumerator, oldDen: track.lane.stepLengthDenominator,
                                  newNum:  session.snapshotNumerator,  newDen: session.snapshotDenominator),
            to: track, undoManager: nil
        )
        _session = nil
        isSessionActive = false
        sessionCursorHint = .none
        viewportController.endSession()
    }

    // MARK: - Stretch Count Drag API (Arch-Slice-8)

    /// Begin a stretch-handle step-count-zone drag session.
    ///
    /// Guards modal invariant — silently no-ops if a session is already active.
    func beginStretchCountDrag(track: TrackData) {
        guard _session == nil else { return }
        _session = .stretchCountDrag(StretchCountDragSession(
            trackID:           track.id,
            snapshotStepCount: track.lane.stepCount
        ))
        isSessionActive = true
        sessionCursorHint = .stretchVertical   // custom cursor, distinct from pitch drag
        viewportController.beginSession()
    }

    /// Update the active stretch count drag with a new vertical translation.
    ///
    /// `totalY` is `DragGesture.translation.height` (total from drag-start; never a delta).
    func updateStretchCountDrag(totalY: CGFloat, track: TrackData) {
        guard case .stretchCountDrag(let session) = _session else { return }
        let proposed = session.proposedStepCount(totalY: totalY)
        guard proposed != track.lane.stepCount else { return }
        modelWriter.apply(
            ModelCommand.setStepCount(trackID: session.trackID, old: session.snapshotStepCount, new: proposed),
            to: track, undoManager: nil
        )
        // _session is NOT mutated — no accumulator field exists.
    }

    /// Commit the active stretch count drag (registers one undo entry).
    func commitStretchCountDrag(track: TrackData, undoManager: UndoManager?) {
        guard case .stretchCountDrag(let session) = _session else { return }
        endEdgeScroll()
        let command = session.commitCommand(currentStepCount: track.lane.stepCount)
        modelWriter.apply(command, to: track, undoManager: undoManager)
        _session = nil
        isSessionActive = false
        sessionCursorHint = .none
        viewportController.endSession()
    }

    /// Cancel the active stretch count drag (restores snapshot value, no undo entry).
    func cancelStretchCountDrag(track: TrackData) {
        guard case .stretchCountDrag(let session) = _session else { return }
        endEdgeScroll()
        modelWriter.apply(
            ModelCommand.setStepCount(trackID: session.trackID, old: track.lane.stepCount, new: session.snapshotStepCount),
            to: track, undoManager: nil
        )
        _session = nil
        isSessionActive = false
        sessionCursorHint = .none
        viewportController.endSession()
    }

    // MARK: - Shared viewport API

    /// Apply edge-scroll velocity during any active session.
    ///
    /// Used by `HandleNSView` (via `CornerHandlesView.onEdgeScroll` callback)
    /// which owns its own edge-scroll timer internally.
    /// Routes through `ViewportController.scroll(by:)` — the only legitimate
    /// scroll write path for interaction code.
    func applyEdgeScroll(velocity: CGFloat) {
        guard _session != nil else { return }
        viewportController.scroll(by: velocity)
    }

    // MARK: - IC-owned edge-scroll API (Arch-Slice-7)

    /// Report the current pointer position for edge-scroll computation.
    ///
    /// Called from `StepGridView` on every rubber-band `DragGesture.onChanged`.
    /// Starts the IC-owned timer on the first call; subsequent calls just update
    /// the pointer position without creating additional timers.
    ///
    /// The timer polls `EdgeScrollVelocity` each frame and calls
    /// `viewportController.scroll(by:)` — the only scroll write path.
    ///
    /// No-op if no session is active (modal invariant guard).
    func updateEdgeScrollPointer(x: CGFloat, viewWidth: CGFloat) {
        guard _session != nil else { return }
        edgeScrollPointerX  = x
        edgeScrollViewWidth = viewWidth
        guard edgeScrollTimer == nil else { return }   // already running — pointer updated above
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            // DispatchQueue.main.async defers the scroll write to the next runloop
            // iteration, outside SwiftUI's render phase — eliminates the
            // "Publishing changes from within view updates" warning.
            DispatchQueue.main.async { [weak self] in
                self?.edgeScrollTick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        edgeScrollTimer = t
    }

    /// Stop the IC-owned edge-scroll timer.
    ///
    /// Called from `StepGridView.onEnded` and from all session commit/cancel paths.
    /// Idempotent — safe to call when no timer is running.
    func endEdgeScroll() {
        edgeScrollTimer?.invalidate()
        edgeScrollTimer    = nil
        edgeScrollPointerX = nil
    }

    /// Timer callback: compute velocity from current pointer position and scroll.
    ///
    /// In DEBUG builds, reads zone widths and maxVelocity from `EdgeScrollDebugConfig.shared`
    /// and writes live readback values (pointerX, velocity, viewWidth) back to the config
    /// for display in `EdgeScrollDebugPanel`.
    private func edgeScrollTick() {
        guard let x = edgeScrollPointerX, _session != nil else {
            endEdgeScroll()
            return
        }
#if DEBUG
        let cfg = EdgeScrollDebugConfig.shared
        cfg.livePointerX    = x
        cfg.liveViewWidth   = edgeScrollViewWidth
        cfg.liveScrollOffset = viewportController.scrollState.hScrollOffset
        let velocity = EdgeScrollVelocity.velocity(
            pointerX:       x,
            viewWidth:      edgeScrollViewWidth,
            leftZoneWidth:  cfg.leftZoneWidth,
            rightZoneWidth: cfg.rightZoneWidth,
            leftInset:      cfg.leftInset,
            rightInset:     cfg.rightInset,
            maxVelocity:    cfg.maxVelocity
        )
        cfg.liveVelocity = velocity
#else
        let velocity = EdgeScrollVelocity.velocity(pointerX: x, viewWidth: edgeScrollViewWidth)
#endif
        guard abs(velocity) > 0.5 else { return }
        viewportController.scroll(by: velocity)
    }

    // MARK: - Private helpers

    private func publishRubberBandUpdate(from session: RubberBandSession,
                                          phase: RubberBandPhase) {
        let steps: Set<Int> = (phase == .cancelled) ? [] : session.selectedSteps()
        rubberBandUpdate = RubberBandUpdate(
            trackID:         session.trackID,
            anchorContentX:  session.anchorContentX,
            currentContentX: session.currentContentX,
            selectedSteps:   steps,
            phase:           phase
        )
    }

    private func publishStepSwapUpdate(session: StepSwapSession,
                                        phase: StepSwapPhase) {
        stepSwapUpdate = StepSwapUpdate(
            trackID:     session.trackID,
            sourceIndex: session.sourceIndex,
            targetIndex: session.targetIndex,
            phase:       phase
        )
    }

    // MARK: - Pinch-Zoom API (Arch-Slice-9)

    /// Step width at the START of the current pinch gesture.
    /// Reset on each `beginPinchZoom` call; never modified during the gesture.
    private var pinchSnapshotStepWidth: CGFloat = 54

    /// Step width applied on the PREVIOUS `updatePinchZoom` call.
    /// Used to compute the incremental ratio for anchor-stable scroll compensation.
    private var pinchPrevStepWidth: CGFloat = 54

    /// Begin a pinch-zoom gesture. Captures the current step width as the zoom origin.
    ///
    /// Unlike modal drag sessions, pinch-zoom does NOT enter the `_session` slot —
    /// it runs in parallel with any existing session or with no session.
    ///
    /// - Parameter currentStepWidth: `engine.stepWidthSize` at gesture start.
    func beginPinchZoom(currentStepWidth: CGFloat) {
        pinchSnapshotStepWidth = currentStepWidth
        pinchPrevStepWidth     = currentStepWidth
    }

    /// Update the pinch-zoom gesture and return the new step width.
    ///
    /// Applies anchor-stable scroll compensation via `ViewportController.adjustScroll`.
    /// The caller is responsible for writing the returned value to `engine.stepWidthSize`.
    ///
    /// In DEBUG builds, reads `minZoomScale` / `maxZoomScale` / `zoomSensitivity` from
    /// `EdgeScrollDebugConfig.shared` for live tuning. In RELEASE, uses hard-coded ranges.
    ///
    /// - Parameters:
    ///   - magnification: `MagnificationGesture.Value` — cumulative from 1.0 at gesture start.
    ///   - anchorX:       Screen-space X anchor (px). Typically the horizontal center of the
    ///                    gesture view. Content at this X-coordinate stays visually fixed.
    /// - Returns: New `stepWidthSize` value, clamped to [30, 120].
    func updatePinchZoom(magnification: CGFloat, anchorX: CGFloat) -> Double {
        // Apply optional sensitivity multiplier in DEBUG
#if DEBUG
        let cfg         = EdgeScrollDebugConfig.shared
        let sensitivity = cfg.zoomSensitivity
        // Die Debug-Skalen dürfen den Produktbereich 30…120 nur einengen, nie verlassen —
        // sonst committet ein DEBUG-Build Breiten, die Release nie erzeugt.
        let lo          = max(30,  pinchSnapshotStepWidth * cfg.minZoomScale)
        let hi          = min(120, max(lo, pinchSnapshotStepWidth * cfg.maxZoomScale))
#else
        let sensitivity: CGFloat = 1.0
        let lo:          CGFloat = 30
        let hi:          CGFloat = 120
#endif
        // Magnification with sensitivity: 1.0 = no change, values above/below compress/expand range
        let effectiveMag = 1.0 + (magnification - 1.0) * sensitivity

        // Slot-basierte Skalierung: scaleEffect skaliert den gesamten Slot
        // (stepWidth + spacing) uniform. Damit der Commit exakt dem visuellen
        // Zustand entspricht, muss newWidth + spacing == (oldWidth + spacing) × mag.
        let spacing  = VintageTheme.stepSpacing
        let rawNew   = (pinchSnapshotStepWidth + spacing) * effectiveMag - spacing
        let newWidth = max(lo, min(hi, rawNew))

        // Anchor-stable scroll compensation (incremental ratio each frame)
        viewportController.adjustScroll(
            oldStepWidth: pinchPrevStepWidth,
            newStepWidth: newWidth,
            anchorX:      anchorX
        )
        pinchPrevStepWidth = newWidth

#if DEBUG
        cfg.liveZoomScale    = viewportController.zoomScale
        cfg.liveScrollOffset = viewportController.scrollState.hScrollOffset
#endif

        return Double(newWidth)
    }

    /// End the pinch-zoom gesture. Resets snapshot to current width.
    ///
    /// Idempotent — safe to call multiple times or when no gesture is active.
    func endPinchZoom() {
        pinchSnapshotStepWidth = pinchPrevStepWidth   // next gesture starts from here
    }
}
