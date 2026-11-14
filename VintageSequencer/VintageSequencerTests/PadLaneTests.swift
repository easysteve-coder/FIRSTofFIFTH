import Testing
import Foundation
@testable import VintageSequencer

/// Pad-Lane, Halte-Steps und Pad-Akkorde (v1.13.16).
struct PadLaneTests {

    private func drain(_ q: AUEventQueue) -> [(b0: UInt8, b1: UInt8)] {
        var out: [(UInt8, UInt8)] = []
        q.render(hostStart: 0, hostValid: false, frames: 512, ticksPerFrame: 1) { _, packed in
            out.append((UInt8(truncatingIfNeeded: packed), UInt8(truncatingIfNeeded: packed >> 8)))
        }
        return out.map { (b0: $0.0, b1: $0.1) }
    }

    // MARK: Halten

    @Test func holdSpanCountsFollowingActiveHoldStepsCyclically() {
        var steps = (0..<4).map { _ in Step() }
        for i in 0..<4 { steps[i].isActive = true }
        steps[1].isHold = true; steps[2].isHold = true
        #expect(SequencerEngine.holdSpan(after: 0, in: steps, count: 4) == 2)
        #expect(SequencerEngine.holdSpan(after: 1, in: steps, count: 4) == 0, "Halte-Step selbst")
        #expect(SequencerEngine.holdSpan(after: 3, in: steps, count: 4) == 0)
        // Zyklisch: Step 3 wird vom Halte-Step 0 der nächsten Runde verlängert.
        var wrap = steps
        wrap[1].isHold = false; wrap[2].isHold = false; wrap[0].isHold = true
        #expect(SequencerEngine.holdSpan(after: 3, in: wrap, count: 4) == 1)
        // Inaktive Halte-Steps zählen nicht.
        var off = steps; off[2].isActive = false
        #expect(SequencerEngine.holdSpan(after: 0, in: off, count: 4) == 1)
    }

    /// Ein Halte-Step schlägt nicht an und verlängert den Ton des vorherigen Steps um
    /// genau eine Steplänge.
    @MainActor @Test func holdStepExtendsPreviousNoteWithoutRestriking() throws {
        func firstOffAndOns(hold: Bool) throws -> (off: UInt64, ons: Int, start: UInt64, pulse: UInt64) {
            let engine = SequencerEngine()
            let channelID = try #require(engine.rack.addChannel(name: "Test"))
            let route = engine.rack.route(for: channelID)
            engine.rack.queue(route).setActive(true)
            let td = engine.patterns[0].tracks[0]
            td.instrumentID = channelID; td.midiChannel = 1
            td.lane.stepCount = 4
            td.lane.steps[0].isActive = true; td.lane.steps[0].notes = [50]
            td.lane.steps[0].gate = 1.0; td.lane.steps[0].probability = 1
            td.lane.steps[1].isActive = hold; td.lane.steps[1].isHold = hold
            td.lane.steps[1].notes = [50]
            engine.setClockMode(.external)
            engine.play()
            var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
            let pulseNanos = 60.0 / engine.bpm / 24.0 * 1_000_000_000
            let pulse = UInt64(pulseNanos * Double(tb.denom) / Double(tb.numer))
            let start = mach_absolute_time() + 1_000_000
            var t = start
            var off: UInt64 = 0
            for i in 0..<12 {                         // zwei Steps à 6 Pulse
                engine._rt3aDriveOneExternalTick(at: t)
                if i == 0 { off = engine._noteBookPendingOff(channel: 1, note: 50, route: route) }
                t += pulse
            }
            let ons = drain(engine.rack.queue(route)).filter { $0.b1 == 50 && $0.b0 & 0xF0 == 0x90 }.count
            engine.stop()
            return (off, ons, start, pulse)
        }
        let plain = try firstOffAndOns(hold: false)
        let held  = try firstOffAndOns(hold: true)
        #expect(held.ons == 1, "Halte-Step schlägt nicht neu an (Note-Ons: \(held.ons))")
        let plainLen = Int64(plain.off) - Int64(plain.start)
        let heldLen  = Int64(held.off)  - Int64(held.start)
        let step = Int64(6 * held.pulse)
        #expect(abs((heldLen - plainLen) - step) < step / 10,
                "Verlängerung um eine Steplänge (Δ \(heldLen - plainLen), Step \(step))")
    }

    @Test func holdFlagRoundTripsAndIsOnlyWrittenWhenSet() throws {
        var s = Step(); s.isActive = true
        let plain = try JSONEncoder().encode(s)
        #expect(!String(decoding: plain, as: UTF8.self).contains("hold"))
        #expect(try JSONDecoder().decode(Step.self, from: plain).isHold == false)
        s.isHold = true
        #expect(try JSONDecoder().decode(Step.self, from: JSONEncoder().encode(s)).isHold)
    }

    // MARK: Pad-Lane

    @Test func padFlagRoundTripsCopiesAndClamps() throws {
        let lane = LaneData(stepCount: 4)
        let plain = try JSONEncoder().encode(lane)
        #expect(!String(decoding: plain, as: UTF8.self).contains("\"pad\""))
        #expect(try JSONDecoder().decode(LaneData.self, from: plain).isPad == false)

        lane.isPad = true; lane.stepLengthNumerator = 32
        let decoded = try JSONDecoder().decode(LaneData.self, from: JSONEncoder().encode(lane))
        #expect(decoded.isPad && decoded.stepLengthNumerator == 32)

        let td = TrackData(name: "P", lane: lane)
        #expect(td.freshCopy().lane.isPad)

        lane.stepLengthNumerator = 3; lane.stepLengthDenominator = 2   // keine Pad-Länge
        lane.clampToValidRanges()
        #expect(lane.stepLengthNumerator == 16 && lane.stepLengthDenominator == 1)
    }

    @Test func padRatiosAndLabels() {
        #expect(TrackData.padRatios.map { TrackData.ratioLabel(num: $0.num, den: $0.den) }
                == ["1/4", "1/2", "3/4", "1 T", "2 T", "3 T", "4 T", "8 T"])
        #expect(TrackData.ratioLabel(num: 3, den: 2) == "3/2")
        let lane = LaneData(stepCount: 4); lane.isPad = true; lane.stepLengthNumerator = 64
        #expect(lane.displayNumerator == lane.padWidth && lane.displayDenominator == 1)
        #expect(lane.ratioOptions.count == TrackData.padRatios.count)
    }

    @MainActor @Test func addPadTrackCreatesLongLegatoSteps() throws {
        let engine = SequencerEngine()
        let placed = engine.addTrack(kind: .step, pad: true)
        let td = try #require(placed.first?.track)
        #expect(td.lane.isPad && td.lane.stepCount == 4)
        #expect(td.lane.stepLengthNumerator == 16 && td.lane.stepLengthDenominator == 1)
        #expect(td.lane.steps.allSatisfy { $0.gate == 1.0 })
        engine.publishSnapshot()
        let snap = try #require(engine._rt1PublishedBundle()?.snapshot)
        let lane = try #require(snap.tracks.last?.lane)
        #expect(lane.pulsesPerStep == 96, "1 Takt = 4 Viertel × 24 Pulse")
    }

    // MARK: Pad-Akkorde

    @Test func everyFamilyFillsTheRequestedStepCountWithPlayableVoicings() {
        var rng = SystemRandomNumberGenerator()
        for family in PadChords.families {
            for count in [1, 4, 7, 12] {
                let chords = PadChords.progression(family, count: count, using: &rng)
                #expect(chords.count == count, "\(family.id) \(count)")
                let voiced = PadChords.voice(chords, tonic: 2)
                for (c, notes) in zip(chords, voiced) {
                    #expect(notes.count == c.quality.intervals.count + 1, "\(family.id): Bass + Akkord")
                    #expect(notes.allSatisfy { (36...79).contains($0) })
                    #expect(notes.min()! % 12 == (c.root + 2) % 12, "\(family.id): Bass ist Grundton")
                    let pcs = Set(notes.map { $0 % 12 })
                    #expect(pcs == Set(c.quality.intervals.map { (c.root + 2 + $0) % 12 }))
                }
            }
            #expect(family.source.contains("Lizzio") || family.source.contains("Callipari"))
        }
    }

    @Test func andalusianInAIsAmGFE() throws {
        var rng = SystemRandomNumberGenerator()
        let f = try #require(PadChords.family(id: "andalusian"))
        let voiced = PadChords.voice(PadChords.progression(f, count: 4, using: &rng), tonic: 9)
        #expect(voiced.map { $0.min()! } == [45, 43, 41, 40])      // A2, G2, F2, E2
        #expect(Set(voiced[0].map { $0 % 12 }) == [9, 0, 4])           // A-Moll
        #expect(Set(voiced[3].map { $0 % 12 }) == [4, 8, 11])          // E-Dur
    }

    @Test func freeProgressionStaysInTheScale() {
        var rng = SystemRandomNumberGenerator()
        let dorian = TrackData.scales.firstIndex { $0.shortName == "DOR" }!
        let scale = Set(TrackData.scales[dorian].intervals)
        for _ in 0..<20 {
            let chords = PadChords.freeProgression(scaleIndex: dorian, count: 8, using: &rng)
            #expect(chords.count == 8 && chords[0].root == 0)
            for c in chords {
                #expect(c.quality.intervals.allSatisfy { scale.contains((c.root + $0) % 12) },
                        "\(c.root) \(c.quality) leitereigen")
            }
        }
    }

    @MainActor @Test func padRandomizeIsOneUndoStep() throws {
        let engine = SequencerEngine()
        let um = UndoManager(); engine.undoManager = um
        let td = try #require(engine.addTrack(kind: .step, pad: true).first?.track)
        UserDefaults.standard.set(PadChordSource.books.rawValue, forKey: SequencerEngine.padChordSourceKey)
        UserDefaults.standard.set("epic", forKey: SequencerEngine.padChordFamilyKey)
        defer {
            UserDefaults.standard.removeObject(forKey: SequencerEngine.padChordSourceKey)
            UserDefaults.standard.removeObject(forKey: SequencerEngine.padChordFamilyKey)
        }
        let before = td.lane.steps.map(\.notes)
        engine.randomize(track: td)
        let rolled = td.lane.steps.prefix(4)
        #expect(rolled.allSatisfy { $0.isActive && $0.notes.count >= 4 && $0.gate == 1.0 })
        #expect(rolled.first!.notes.min()! % 12 == td.scaleRoot)
        um.undo()
        #expect(td.lane.steps.map(\.notes) == before)
    }

    // MARK: Fester Ton

    /// Fester Ton: der Snapshot spielt ihn auf jedem Step; die Steps behalten ihre Noten;
    /// Setzen ist rückgängig zu machen und übersteht Speichern/Laden.
    @MainActor @Test func fixedNoteReplacesStepNotesInSnapshotAndIsUndoable() throws {
        let engine = SequencerEngine()
        let um = UndoManager(); engine.undoManager = um
        let td = engine.patterns[0].tracks[0]
        td.lane.steps[0].isActive = true; td.lane.steps[0].notes = [60, 64, 67]
        td.lane.steps[1].isActive = true; td.lane.steps[1].notes = [72]
        ModelWriter().apply(.setFixedNote(trackID: td.id, old: nil, new: 36), to: td, undoManager: um)
        engine.publishSnapshot()
        let snap = try #require(engine._rt1PublishedBundle()?.snapshot)
        guard case let .step(steps) = snap.tracks[0].lane.payload else { Issue.record("keine Step-Lane"); return }
        #expect(steps[0].notes == [36] && steps[1].notes == [36])
        #expect(td.lane.steps[0].notes == [60, 64, 67], "Step-Noten bleiben erhalten")

        let decoded = try JSONDecoder().decode(LaneData.self, from: JSONEncoder().encode(td.lane))
        #expect(decoded.fixedNote == 36)

        um.undo()
        #expect(td.lane.fixedNote == nil)
        let plain = try JSONEncoder().encode(td.lane)
        #expect(!String(decoding: plain, as: UTF8.self).contains("fixedNote"))
    }

    // MARK: Länge ziehen

    /// Pad-Lanes: der Anfasser zieht stufenweise (eine Step-Breite je Längenstufe).
    @Test func padRatioDragMovesOneLengthPerStepWidth() {
        let session = RatioDragSession(trackID: UUID(), snapshotNumerator: 16, snapshotDenominator: 1,
                                       baseRatioIndex: 3, contentUnit: 160, scrollOffsetAtStart: 0,
                                       ratios: TrackData.padRatios, pxPerRatioStep: 40)
        #expect(session.proposedRatio(translationX: 0, currentScrollOffset: 0) == (16, 1))
        #expect(session.proposedRatio(translationX: 41, currentScrollOffset: 0) == (32, 1))
        #expect(session.proposedRatio(translationX: -80, currentScrollOffset: 0) == (8, 1))
        #expect(session.proposedRatio(translationX: 4000, currentScrollOffset: 0) == (128, 1))
        #expect(session.proposedRatio(translationX: -4000, currentScrollOffset: 0) == (4, 1))
    }

    // MARK: Pad-Breite

    /// Pad-Breite: bestimmt nur die Rasterbreite, nicht die Steplänge; optionaler Key,
    /// geklemmt auf 1…8, rückgängig zu machen, wird kopiert.
    @MainActor @Test func padWidthDrivesDisplayRoundTripsClampsAndIsUndoable() throws {
        let lane = LaneData(stepCount: 4); lane.isPad = true; lane.stepLengthNumerator = 64
        #expect(!String(decoding: try JSONEncoder().encode(lane), as: UTF8.self).contains("padWidth"))

        let td = TrackData(name: "P", lane: lane)
        let um = UndoManager()
        ModelWriter().apply(.setPadWidth(trackID: td.id, old: 1, new: 3), to: td, undoManager: um)
        #expect(lane.displayNumerator == 3 && lane.displayDenominator == 1)
        #expect(lane.stepLengthNumerator == 64, "Steplänge unberührt")
        #expect(try JSONDecoder().decode(LaneData.self, from: JSONEncoder().encode(lane)).padWidth == 3)
        #expect(td.freshCopy().lane.padWidth == 3)

        um.undo()
        #expect(lane.padWidth == 1)

        lane.padWidth = 99; lane.clampToValidRanges()
        #expect(lane.padWidth == 8)
        lane.padWidth = 0; lane.clampToValidRanges()
        #expect(lane.padWidth == 1)

        let step = LaneData(stepCount: 4); step.padWidth = 5
        #expect(step.displayNumerator == 1, "Step-Lanes ignorieren die Pad-Breite")
        #expect(!String(decoding: try JSONEncoder().encode(step), as: UTF8.self).contains("padWidth"))
    }

    @MainActor @Test func newPadTrackIsTwoStepsWide() throws {
        let engine = SequencerEngine()
        let td = try #require(engine.addTrack(kind: .step, pad: true).first?.track)
        #expect(td.lane.padWidth == 2 && td.lane.displayNumerator == 2)
    }
}
