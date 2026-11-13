import AppKit   // UndoManager
import Combine  // PassthroughSubject.send()

// MARK: - Reversible Undo Helper
//
// Registers a symmetric undo closure. When UndoManager invokes it during
// undo, the closure restores the previous state AND re-registers itself
// with forward/backward swapped — Cocoa automatically routes that new
// registration onto the redo stack (because `isUndoing == true`). On redo,
// the same mechanism flips back to undo. This is the canonical AppKit
// pattern for a working undo/redo cycle.
//
// Caller contract: the "forward" mutation (→ new state) has already been
// applied before this helper is called. `forward`/`backward` must be pure
// state-setters (idempotent restores), not user-facing actions with side
// effects, otherwise redo semantics can diverge (e.g. re-running a
// randomize would produce different values than the first invocation).
func registerReversibleUndo<T: AnyObject>(
    um: UndoManager,
    target: T,
    actionName: String,
    forward: @escaping (T) -> Void,
    backward: @escaping (T) -> Void
) {
    um.registerUndo(withTarget: target) { t in
        backward(t)
        registerReversibleUndo(um: um,
                               target: t,
                               actionName: actionName,
                               forward: backward,
                               backward: forward)
    }
    um.setActionName(actionName)
}

// MARK: - ModelWriter
//
// Single legitimate model-write authority for interaction-driven mutations.
//
// Sequence commands (setSteps, setStepCount, setRatio, setPitchNotes,
// setDirection) mutate `td.lane` and call `lane.changed.send()`.
// Container commands (setName, setMuted, setSolo, setMIDIChannel,
// setTimingOffset, setScaleRoot, setScaleIndex, setCC*Muted) mutate `td`
// and call `td.changed.send()`. The caller passes the TrackData; the writer
// selects the correct target internally (Lane-Modell v1).
//
// Thread safety: main thread only.
struct ModelWriter {

    func apply(_ command: ModelCommand,
               to td: TrackData,
               undoManager: UndoManager? = nil) {
        switch command {

        // MARK: - Sequence commands → LaneData

        case let .setStepCount(trackID, old, new):
            assert(td.id == trackID,
                   "ModelWriter: trackID mismatch — command targets \(trackID), got \(td.id)")
            let lane = td.lane
            lane.stepCount = new
            lane.changed.send()
            if let um = undoManager {
                registerReversibleUndo(
                    um: um,
                    target: lane,
                    actionName: command.undoActionName,
                    forward:  { l in l.stepCount = new; l.changed.send() },
                    backward: { l in l.stepCount = old; l.changed.send() }
                )
            }

        case let .setRatio(trackID, oldNum, oldDen, newNum, newDen):
            assert(td.id == trackID,
                   "ModelWriter: trackID mismatch — command targets \(trackID), got \(td.id)")
            let lane = td.lane
            lane.stepLengthNumerator   = newNum
            lane.stepLengthDenominator = newDen
            lane.changed.send()
            if let um = undoManager {
                registerReversibleUndo(
                    um: um,
                    target: lane,
                    actionName: command.undoActionName,
                    forward: { l in
                        l.stepLengthNumerator   = newNum
                        l.stepLengthDenominator = newDen
                        l.changed.send()
                    },
                    backward: { l in
                        l.stepLengthNumerator   = oldNum
                        l.stepLengthDenominator = oldDen
                        l.changed.send()
                    }
                )
            }

        case let .setPitchNotes(trackID, stepIndex, oldNotes, newNotes):
            assert(td.id == trackID,
                   "ModelWriter: trackID mismatch — command targets \(trackID), got \(td.id)")
            let lane = td.lane
            var steps = lane.steps
            steps[stepIndex].notes = newNotes
            if !steps[stepIndex].isActive { steps[stepIndex].isActive = true }
            lane.steps = steps
            lane.changed.send()
            if let um = undoManager {
                registerReversibleUndo(
                    um: um,
                    target: lane,
                    actionName: command.undoActionName,
                    forward: { l in
                        var s = l.steps
                        s[stepIndex].notes = newNotes
                        if !s[stepIndex].isActive { s[stepIndex].isActive = true }
                        l.steps = s
                        l.changed.send()
                    },
                    backward: { l in
                        var s = l.steps
                        s[stepIndex].notes = oldNotes
                        l.steps = s
                        l.changed.send()
                    }
                )
            }

        case let .setSteps(trackID, oldSteps, newSteps, _):
            assert(td.id == trackID,
                   "ModelWriter: trackID mismatch — command targets \(trackID), got \(td.id)")
            let lane = td.lane
            lane.steps = newSteps
            lane.changed.send()
            if let um = undoManager {
                registerReversibleUndo(
                    um: um,
                    target: lane,
                    actionName: command.undoActionName,
                    forward:  { l in l.steps = newSteps; l.changed.send() },
                    backward: { l in l.steps = oldSteps; l.changed.send() }
                )
            }

        case let .setDirection(trackID, _, new):
            assert(td.id == trackID,
                   "ModelWriter: trackID mismatch — command targets \(trackID), got \(td.id)")
            let lane = td.lane
            lane.direction = new
            lane.changed.send()
            // No undo — mirrors pre-Slice-E behaviour.

        // MARK: - Container commands → TrackData

        case let .setName(trackID, old, new):
            assert(td.id == trackID,
                   "ModelWriter: trackID mismatch — command targets \(trackID), got \(td.id)")
            td.name = new
            td.changed.send()
            if let um = undoManager {
                registerReversibleUndo(
                    um: um,
                    target: td,
                    actionName: command.undoActionName,
                    forward:  { t in t.name = new; t.changed.send() },
                    backward: { t in t.name = old; t.changed.send() }
                )
            }

        case let .setMuted(trackID, _, new):
            assert(td.id == trackID,
                   "ModelWriter: trackID mismatch — command targets \(trackID), got \(td.id)")
            td.isMuted = new
            td.changed.send()

        case let .setSolo(trackID, _, new):
            assert(td.id == trackID,
                   "ModelWriter: trackID mismatch — command targets \(trackID), got \(td.id)")
            td.isSolo = new
            td.changed.send()

        case let .setMIDIChannel(trackID, _, new):
            assert(td.id == trackID,
                   "ModelWriter: trackID mismatch — command targets \(trackID), got \(td.id)")
            td.midiChannel = new
            td.changed.send()

        case let .setDrumMode(trackID, old, new):
            assert(td.id == trackID,
                   "ModelWriter: trackID mismatch — command targets \(trackID), got \(td.id)")
            td.isDrum = new
            td.changed.send()
            if let um = undoManager {
                registerReversibleUndo(
                    um: um,
                    target: td,
                    actionName: command.undoActionName,
                    forward:  { t in t.isDrum = new; t.changed.send() },
                    backward: { t in t.isDrum = old; t.changed.send() }
                )
            }

        case let .setInstrument(trackID, old, new):
            assert(td.id == trackID,
                   "ModelWriter: trackID mismatch — command targets \(trackID), got \(td.id)")
            td.instrumentID = new
            td.changed.send()
            if let um = undoManager {
                registerReversibleUndo(
                    um: um,
                    target: td,
                    actionName: command.undoActionName,
                    forward:  { t in t.instrumentID = new; t.changed.send() },
                    backward: { t in t.instrumentID = old; t.changed.send() }
                )
            }

        case let .setTimingOffset(trackID, _, new):
            assert(td.id == trackID,
                   "ModelWriter: trackID mismatch — command targets \(trackID), got \(td.id)")
            td.timingOffset = new
            td.changed.send()

        case let .setScaleRoot(trackID, _, new):
            assert(td.id == trackID,
                   "ModelWriter: trackID mismatch — command targets \(trackID), got \(td.id)")
            td.scaleRoot = new
            td.changed.send()

        case let .setScaleIndex(trackID, _, new):
            assert(td.id == trackID,
                   "ModelWriter: trackID mismatch — command targets \(trackID), got \(td.id)")
            td.scaleIndex = new
            td.changed.send()

        case let .setTrackColorIndex(trackID, old, new):
            assert(td.id == trackID,
                   "ModelWriter: trackID mismatch — command targets \(trackID), got \(td.id)")
            td.colorIndex = new
            td.changed.send()
            if let um = undoManager {
                registerReversibleUndo(
                    um: um,
                    target: td,
                    actionName: command.undoActionName,
                    forward:  { t in t.colorIndex = new; t.changed.send() },
                    backward: { t in t.colorIndex = old; t.changed.send() }
                )
            }

        // MARK: - CC-Lane commands → LaneData (CC-Lane Slice 1)

        case let .setCCLaneValue(trackID, index, old, new):
            assert(td.id == trackID,
                   "ModelWriter: trackID mismatch — command targets \(trackID), got \(td.id)")
            let lane = td.lane
            guard index >= 0, index < lane.ccValues.count else { return }
            lane.ccValues[index] = new
            lane.changed.send()
            if let um = undoManager {
                registerReversibleUndo(
                    um: um, target: lane,
                    actionName: command.undoActionName,
                    forward:  { l in
                        guard index < l.ccValues.count else { return }
                        l.ccValues[index] = new; l.changed.send()
                    },
                    backward: { l in
                        guard index < l.ccValues.count else { return }
                        l.ccValues[index] = old; l.changed.send()
                    }
                )
            }

        case let .setCCLaneValues(trackID, oldValues, newValues, _):
            assert(td.id == trackID,
                   "ModelWriter: trackID mismatch — command targets \(trackID), got \(td.id)")
            let lane = td.lane
            lane.ccValues = newValues
            lane.changed.send()
            if let um = undoManager {
                registerReversibleUndo(
                    um: um, target: lane,
                    actionName: command.undoActionName,
                    forward:  { l in l.ccValues = newValues; l.changed.send() },
                    backward: { l in l.ccValues = oldValues; l.changed.send() }
                )
            }

        case let .setCCLaneNumber(trackID, old, new):
            assert(td.id == trackID,
                   "ModelWriter: trackID mismatch — command targets \(trackID), got \(td.id)")
            let lane = td.lane
            lane.ccNumber = new
            lane.changed.send()
            if let um = undoManager {
                registerReversibleUndo(
                    um: um, target: lane,
                    actionName: command.undoActionName,
                    forward:  { l in l.ccNumber = new; l.changed.send() },
                    backward: { l in l.ccNumber = old; l.changed.send() }
                )
            }

        case let .setCCLaneParameter(trackID, old, new):
            assert(td.id == trackID,
                   "ModelWriter: trackID mismatch — command targets \(trackID), got \(td.id)")
            let lane = td.lane
            lane.ccParameter = new
            lane.changed.send()
            if let um = undoManager {
                registerReversibleUndo(
                    um: um, target: lane,
                    actionName: command.undoActionName,
                    forward:  { l in l.ccParameter = new; l.changed.send() },
                    backward: { l in l.ccParameter = old; l.changed.send() }
                )
            }

        case let .setCCLaneLabel(trackID, old, new):
            assert(td.id == trackID,
                   "ModelWriter: trackID mismatch — command targets \(trackID), got \(td.id)")
            let lane = td.lane
            lane.ccLabel = new
            lane.changed.send()
            if let um = undoManager {
                registerReversibleUndo(
                    um: um, target: lane,
                    actionName: command.undoActionName,
                    forward:  { l in l.ccLabel = new; l.changed.send() },
                    backward: { l in l.ccLabel = old; l.changed.send() }
                )
            }

        case let .setCCLaneMuted(trackID, _, new):
            assert(td.id == trackID,
                   "ModelWriter: trackID mismatch — command targets \(trackID), got \(td.id)")
            let lane = td.lane
            lane.ccIsMuted = new
            lane.changed.send()
            // No undo — Mute-Commands tragen heute kein Undo.
        }
    }
}
