import Testing
import Foundation
@testable import VintageSequencer

/// Pad-Lane, Halte-Steps und Pad-Akkorde (v1.13.16).
@Suite(.serialized) struct PadLaneTests {

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

    // MARK: Lange Steps (v1.18.29, vorher Pad-Lane)

    /// Frühere Pad-Spuren laden als normale Spur: Länge, Breite und Akkord-RND bleiben; der
    /// Schlüssel `pad` wird nicht mehr geschrieben.
    @Test func legacyPadLoadsAsLongStepLane() throws {
        let lane = LaneData(stepCount: 4)
        lane.stepLengthNumerator = 32
        var json = String(decoding: try JSONEncoder().encode(lane), as: UTF8.self)
        json = json.replacingOccurrences(of: "{", with: "{\"pad\":true,\"padWidth\":3,", options: [], range: json.range(of: "{"))
        let old = try JSONDecoder().decode(LaneData.self, from: Data(json.utf8))
        #expect(old.isLongStep && old.stepLengthNumerator == 32)
        #expect(old.stepWidth == 3 && old.rndMode == .chords)
        let again = String(decoding: try JSONEncoder().encode(old), as: UTF8.self)
        #expect(!again.contains("\"pad\"") && !again.contains("padWidth"))
        #expect(again.contains("\"width\":3") && again.contains("\"rnd\":\"chords\""))
        // Pad ohne padWidth: Breite 1 wie bisher.
        var bare = String(decoding: try JSONEncoder().encode(lane), as: UTF8.self)
        bare = bare.replacingOccurrences(of: "{", with: "{\"pad\":true,", options: [], range: bare.range(of: "{"))
        #expect(try JSONDecoder().decode(LaneData.self, from: Data(bare.utf8)).stepWidth == 1)
    }

    @Test func plainLaneWritesNoNewKeysAndCopies() throws {
        let lane = LaneData(stepCount: 4)
        let plain = String(decoding: try JSONEncoder().encode(lane), as: UTF8.self)
        #expect(!plain.contains("\"width\"") && !plain.contains("\"rnd\"") && !plain.contains("\"pad\""))
        lane.stepWidth = 2; lane.rndMode = .mixed; lane.stepLengthNumerator = 16
        let td = TrackData(name: "P", lane: lane)
        let copy = td.freshCopy().lane
        #expect(copy.stepWidth == 2 && copy.rndMode == .mixed && copy.stepLengthNumerator == 16)
        lane.stepLengthNumerator = 99_999; lane.clampToValidRanges()
        #expect(lane.stepLengthNumerator == TrackData.maxLongSixteenths)
    }

    /// v1.18.31: Längen als Bruch der ganzen Note, Zeilen gerade/punktiert/Tolen, Takte.
    @Test func stepRatiosAndLabels() {
        let de = Str("de"), en = Str("en")
        let m = TimeSignature.common
        #expect(TrackData.ratio(whole: 1, 12) == (4, 3))            // Achteltriole = bisher 4:3
        #expect(TrackData.ratio(whole: 3, 8) == (6, 1))
        #expect(TrackData.wholeFraction(num: 1, den: 1) == (1, 16))
        #expect(TrackData.wholeFraction(num: 5, den: 4) == (5, 64))   // frühere Zwischenwerte bleiben lesbar
        #expect(en.noteValue(num: 1, den: 1, meter: m) == "1/16")
        #expect(en.noteValue(num: 4, den: 3, meter: m) == "1/12")
        #expect(de.noteValue(num: 32, den: 1, meter: m) == "2 T")
        let seven = TimeSignature(numerator: 7, denominator: 8)
        #expect(en.noteValue(num: 16, den: 1, meter: seven) == "1/1", "eine Ganze ist in 7/8 kein Takt")
        #expect(en.noteValue(num: 14, den: 1, meter: seven) == "1 bar")
        #expect(TrackData.barRatios(seven).map(\.num) == [14, 28, 42, 56, 112])
        #expect(en.noteValueHelp(p: 1, q: 12).contains("3 steps fill a quarter"))
        #expect(de.noteValueHelp(p: 1, q: 20).contains("5 Steps füllen eine Viertel"))
        // Eigener Bruch
        #expect(TrackData.parseFraction("5/16")! == (5, 1))
        #expect(TrackData.parseFraction(" 1 / 9 ")! == (16, 9))
        #expect(TrackData.parseFraction("2")! == (32, 1))
        #expect(TrackData.parseFraction("1/200") == nil && TrackData.parseFraction("x") == nil)
        #expect(TrackData.parseFraction("200") == nil)
        // Liste des Anfassers: aufsteigend, ohne Doppelte (1/1 = 1 Takt in 4/4).
        let all = LaneData(stepCount: 4).ratioOptions(m)
        let values = all.map { Double($0.num) / Double($0.den) }
        #expect(values == values.sorted() && Set(values).count == values.count)
        #expect(all.first! == (1, 2) && all.last! == (128, 1))
        // Breite: kurze Steps zeitgetreu, lange in eigener Breite (Auto nach Länge).
        let lane = LaneData(stepCount: 4)
        lane.stepLengthNumerator = 3; lane.stepLengthDenominator = 2
        #expect(!lane.isLongStep && lane.displayNumerator == 3 && lane.displayDenominator == 2)
        lane.stepLengthNumerator = 2; lane.stepLengthDenominator = 1
        #expect(!lane.isLongStep, "Achtel bleibt zeitgetreu")
        lane.stepLengthNumerator = 16; lane.stepLengthDenominator = 3        // 1/3, kein ganzes Vielfaches
        #expect(lane.isLongStep && lane.displayNumerator == 1)
        lane.stepLengthNumerator = 16; lane.stepLengthDenominator = 1
        #expect(lane.displayNumerator == 2)
        lane.stepLengthNumerator = 64
        #expect(lane.displayNumerator == 3)
        lane.stepWidth = 5
        #expect(lane.displayNumerator == 5)
    }

    /// Der Anfasser zieht kurze Längen zeitgetreu, lange stufenweise (eine Step-Breite je Stufe).
    @Test func ratioDragIsTrueToTimeThenStepwise() {
        let ratios = TrackData.stepRatios(.common)
        let unit: CGFloat = 160, px: CGFloat = 40                    // 4 Steps à 40 px
        let one = ratios.firstIndex { $0 == (1, 1) }!
        let eighth = ratios.firstIndex { $0 == (2, 1) }!
        let bar = ratios.firstIndex { $0 == (16, 1) }!
        func session(_ base: Int) -> RatioDragSession {
            RatioDragSession(trackID: UUID(), snapshotNumerator: ratios[base].num, snapshotDenominator: ratios[base].den,
                             baseRatioIndex: base, contentUnit: unit, scrollOffsetAtStart: 0,
                             ratios: ratios, pxPerLongStep: px)
        }
        let s1 = session(one)
        #expect(s1.proposedRatio(translationX: 0, currentScrollOffset: 0) == (1, 1))
        #expect(s1.proposedRatio(translationX: unit, currentScrollOffset: 0) == (2, 1))       // zeitgetreu
        #expect(s1.proposedRatioIndex(translationX: unit + px, currentScrollOffset: 0) == eighth + 1)  // erste lange Stufe
        #expect(s1.proposedRatio(translationX: 9_000, currentScrollOffset: 0) == (128, 1))
        let s2 = session(bar)
        #expect(s2.proposedRatioIndex(translationX: px + 1, currentScrollOffset: 0) == bar + 1)
        #expect(s2.proposedRatioIndex(translationX: -2 * px, currentScrollOffset: 0) == bar - 2)
        #expect(s2.proposedRatio(translationX: -9_000, currentScrollOffset: 0) == (1, 2))
    }

    // MARK: Breite und RND je Spur

    @MainActor @Test func stepWidthAndRndModeAreUndoable() throws {
        let lane = LaneData(stepCount: 4); lane.stepLengthNumerator = 64
        let td = TrackData(name: "P", lane: lane)
        let um = UndoManager()
        ModelWriter().apply(.setStepWidth(trackID: td.id, old: 0, new: 3), to: td, undoManager: um)
        #expect(lane.displayNumerator == 3 && lane.stepLengthNumerator == 64)
        um.undo()
        #expect(lane.stepWidth == 0)
        ModelWriter().apply(.setRndMode(trackID: td.id, old: nil, new: .chords), to: td, undoManager: um)
        #expect(lane.rndMode == .chords)
        um.undo()
        #expect(lane.rndMode == nil)
        lane.stepWidth = 99; lane.clampToValidRanges()
        #expect(lane.stepWidth == 8)
    }

    /// RND auf langen Steps: jeder Step klingt, legato; auf kurzen wie bisher zufällig.
    @MainActor @Test func randomizeLongStepsPlaysEveryStepLegato() {
        let engine = SequencerEngine()
        let td = engine.patterns[0].tracks[0]
        td.lane.stepCount = 4; td.lane.stepLengthNumerator = 16; td.lane.rndMode = .chords
        engine.randomize(track: td)
        for i in 0..<4 {
            #expect(td.lane.steps[i].isActive && td.lane.steps[i].gate == 1.0)
            #expect(td.lane.steps[i].notes.count >= 2, "Akkord")
        }
    }

    @MainActor @Test func newTrackHasNoPadOption() {
        let engine = SequencerEngine()
        let td = engine.addTrack(kind: .step).first!.track
        #expect(td.lane.stepCount == 16 && !td.lane.isLongStep && td.lane.rndMode == nil)
    }
}
