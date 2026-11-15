import Testing
import Foundation
@testable import VintageSequencer

/// Gruppierung ungerader Takte und Steplänge „Gruppe" (v1.18.30, Konzept §10 L5/L6).
@Suite(.serialized) struct GroupingTests {

    static let seven = TimeSignature(numerator: 7, denominator: 8, grouping: [3, 4])

    // MARK: Modell

    @Test func groupingIsValidatedParsedAndOffered() {
        #expect(TimeSignature.isValidGrouping([5, 2], numerator: 7))
        #expect(!TimeSignature.isValidGrouping([3, 3], numerator: 7))
        #expect(!TimeSignature.isValidGrouping([7], numerator: 7), "eine Gruppe ist keine Gruppierung")
        #expect(TimeSignature.parseGrouping(" 2 + 2+3 ") == [2, 2, 3])
        #expect(TimeSignature.parseGrouping("3+x") == nil)
        #expect(TimeSignature(numerator: 7, denominator: 8, grouping: [3, 3]).clamped.grouping == nil)
        let c = TimeSignature.groupingChoices(numerator: 7)
        for g in [[5, 2], [4, 3], [3, 4], [2, 5], [2, 2, 3], [2, 3, 2], [3, 2, 2]] { #expect(c.contains(g)) }
        #expect(c.allSatisfy { TimeSignature.isValidGrouping($0, numerator: 7) })
        #expect(TimeSignature.groupingChoices(numerator: 3).isEmpty)
        #expect(Self.seven.displayLabel == "7/8 (3+4)" && Self.seven.label == "7/8")
        #expect(Self.seven.groupSixteenths == [6, 8])
        #expect(TimeSignature(numerator: 7, denominator: 8).groupSixteenths == [14], "ohne Gruppierung ein Takt")
        #expect(Self.seven != TimeSignature(numerator: 7, denominator: 8, grouping: [4, 3]))
    }

    /// `timeSignature` bleibt „7/8" (ältere Versionen), die Gruppierung steht in `grouping`.
    @Test func patternKeepsGroupingInItsOwnKey() throws {
        let p = Pattern(name: "A", trackCount: 1)
        p.timeSignature = Self.seven
        let json = String(decoding: try JSONEncoder().encode(p), as: UTF8.self)
        #expect(json.contains("\"timeSignature\":\"7\\/8\"") && json.contains("\"grouping\":\"3+4\""))
        let back = try JSONDecoder().decode(Pattern.self, from: Data(json.utf8))
        #expect(back.timeSignature == Self.seven)
        let plain = Pattern(name: "B", trackCount: 1)
        #expect(!String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("grouping"))
        let bad = json.replacingOccurrences(of: "\"3+4\"", with: "\"3+3\"")
        #expect(try JSONDecoder().decode(Pattern.self, from: Data(bad.utf8)).timeSignature.grouping == nil)
    }

    @MainActor @Test func stepGroupLengthsKeyAndUndo() throws {
        let lane = LaneData(stepCount: 4)
        let td = TrackData(name: "G", lane: lane)
        let um = UndoManager(); um.groupsByEvent = false
        // Ohne eigene Gruppen: Vorgabe aus der Taktart (in Achteln).
        #expect(lane.effectiveGroups(Self.seven) == [3, 4])
        #expect(lane.effectiveGroups(.common) == [8], "ohne Gruppierung ein Takt")
        um.beginUndoGrouping()
        ModelWriter().apply(.setLength(trackID: td.id, old: lane.lengthState,
                                       new: .init(num: 6, den: 1, group: true, groups: nil)), to: td, undoManager: um)
        um.endUndoGrouping()
        #expect(lane.stepGroup && lane.isLongStep && lane.stepLengthNumerator == 6)
        #expect((0..<4).map { lane.sixteenths(ofStep: $0, meter: Self.seven) } == [6, 8, 6, 8])
        let json = String(decoding: try JSONEncoder().encode(lane), as: UTF8.self)
        #expect(json.contains("\"stepGroup\":true") && !json.contains("\"groups\""))
        #expect(try JSONDecoder().decode(LaneData.self, from: Data(json.utf8)).stepGroup)
        #expect(TrackData(name: "G", lane: lane).freshCopy().lane.stepGroup)
        // Eine feste Länge beendet „Gruppe", Undo stellt sie wieder her.
        um.beginUndoGrouping()
        ModelWriter().apply(.setRatio(trackID: td.id, oldNum: 6, oldDen: 1, newNum: 16, newDen: 1), to: td, undoManager: um)
        um.endUndoGrouping()
        #expect(!lane.stepGroup && lane.stepLengthNumerator == 16)
        um.undo()
        #expect(lane.stepGroup && lane.stepLengthNumerator == 6)
        um.undo()
        #expect(!lane.stepGroup && lane.stepLengthNumerator == 1)
    }

    /// Gruppen je Spur (v1.18.31): eigene Aufteilung, Summe frei, Schlüssel `groups`.
    @MainActor @Test func groupsPerTrack() throws {
        let lane = LaneData(stepCount: 3)
        let td = TrackData(name: "G", lane: lane)
        ModelWriter().apply(.setLength(trackID: td.id, old: lane.lengthState,
                                       new: .init(num: 6, den: 1, group: true, groups: [3, 3, 2])), to: td, undoManager: nil)
        // 3+3+2 Achtel in 4/4 = Tresillo, ein Takt.
        #expect((0..<3).map { lane.sixteenths(ofStep: $0, meter: .common) } == [6, 6, 4])
        #expect(Str("de").groupsFit([3, 3, 2], meter: .common) == "passt in einen Takt")
        #expect(Str("de").groupsFit([3, 3, 3], meter: .common).hasPrefix("läuft gegen den Takt"))
        #expect(Str("en").groupsFit([4, 4, 4, 4], meter: .common) == "fits 2 bars")
        let json = String(decoding: try JSONEncoder().encode(lane), as: UTF8.self)
        #expect(json.contains("\"groups\":\"3+3+2\""))
        let back = try JSONDecoder().decode(LaneData.self, from: Data(json.utf8))
        #expect(back.groups == [3, 3, 2] && back.stepGroup)
        #expect(TrackData(name: "G", lane: lane).freshCopy().lane.groups == [3, 3, 2])
        let bad = json.replacingOccurrences(of: "3+3+2", with: "3+0")
        #expect(try JSONDecoder().decode(LaneData.self, from: Data(bad.utf8)).groups == nil)
        #expect(LaneData.isValidGroups([5]) && !LaneData.isValidGroups([]) && !LaneData.isValidGroups(Array(repeating: 1, count: 9)))
    }

    @Test func stepGroupsTupleIsCyclic() {
        let g = StepGroups([36, 48])
        #expect(g.count == 2 && g.pulses(at: 0) == 36 && g.pulses(at: 3) == 48 && g.pulses(at: -1) == 48)
        let many = StepGroups((1...10).map(Double.init))
        #expect(many.count == 8 && many.pulses(at: 7) == 8)
    }

    /// Taktartwechsel: die Ersatzlänge folgt der ersten Gruppe der neuen Taktart.
    @MainActor @Test func meterChangeUpdatesFallbackLength() {
        let engine = SequencerEngine()
        let lane = engine.patterns[0].tracks[0].lane
        lane.stepGroup = true; lane.stepLengthNumerator = 8
        engine.setTimeSignatureUndoable(TimeSignature(numerator: 7, denominator: 8, grouping: [5, 2]), actionName: "T")
        #expect(lane.stepGroup && lane.stepLengthNumerator == 10)
        // Eigene Gruppen bleiben (Achtel), die Ersatzlänge folgt ihnen.
        lane.groups = [3, 3, 2]
        engine.setTimeSignatureUndoable(.common, actionName: "T")
        #expect(lane.groups == [3, 3, 2] && lane.stepLengthNumerator == 6)
    }

    // MARK: Tick

    private func drainOns(_ q: AUEventQueue) -> [UInt8] {
        var out: [UInt8] = []
        q.render(hostStart: 0, hostValid: false, frames: 512, ticksPerFrame: 1) { _, p in
            if UInt8(truncatingIfNeeded: p) & 0xF0 == 0x90, UInt8(truncatingIfNeeded: p >> 16) > 0 {
                out.append(UInt8(truncatingIfNeeded: p >> 8))
            }
        }
        return out
    }

    /// 7/8 als 3+4, Länge „Gruppe": Anschläge auf Puls 0, 36, 84, 120 (3/8 = 36, 4/8 = 48).
    /// Ein Halte-Step verlängert um die Länge SEINER Gruppe.
    @MainActor @Test func tickPlaysGroupLengthsAndHoldsByGroup() throws {
        let engine = SequencerEngine()
        let channelID = try #require(engine.rack.addChannel(name: "Test"))
        let route = engine.rack.route(for: channelID)
        engine.rack.queue(route).setActive(true)
        engine.replaceTimeSignature(Self.seven)
        let td = engine.patterns[0].tracks[0]
        for t in engine.patterns[0].tracks.dropFirst() { for i in t.lane.steps.indices { t.lane.steps[i].isActive = false } }
        td.instrumentID = channelID; td.midiChannel = 1
        td.lane.stepCount = 2
        td.lane.stepGroup = true; td.lane.stepLengthNumerator = 6
        for (i, n) in [50, 51].enumerated() {
            td.lane.steps[i].isActive = true; td.lane.steps[i].notes = [n]
            td.lane.steps[i].gate = 1.0; td.lane.steps[i].probability = 1; td.lane.steps[i].ratchet = .x1
        }
        engine.setClockMode(.external)
        engine.play()
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        let pulse = UInt64(60.0 / engine.bpm / 24.0 * 1_000_000_000 * Double(tb.denom) / Double(tb.numer))
        var t = mach_absolute_time() + 1_000_000
        var hits: [(tick: Int, note: UInt8)] = []
        for i in 0..<130 {
            engine._rt3aDriveOneExternalTick(at: t)
            for n in drainOns(engine.rack.queue(route)) { hits.append((i, n)) }
            t += pulse
        }
        engine.stop()
        #expect(hits.map(\.tick) == [0, 36, 84, 120], "Anschläge \(hits)")
        #expect(hits.map(\.note) == [50, 51, 50, 51])

        // Halten über den 4/8-Step: Off nach 36 + 48 Pulsen.
        let e2 = SequencerEngine()
        let ch2 = try #require(e2.rack.addChannel(name: "Test"))
        let r2 = e2.rack.route(for: ch2)
        e2.rack.queue(r2).setActive(true)
        e2.replaceTimeSignature(Self.seven)
        let h = e2.patterns[0].tracks[0]
        h.instrumentID = ch2; h.midiChannel = 1
        h.lane.stepCount = 2; h.lane.stepGroup = true; h.lane.stepLengthNumerator = 6
        h.lane.steps[0].isActive = true; h.lane.steps[0].notes = [50]; h.lane.steps[0].gate = 1.0
        h.lane.steps[0].probability = 1
        h.lane.steps[1].isActive = true; h.lane.steps[1].isHold = true; h.lane.steps[1].notes = [50]
        e2.setClockMode(.external)
        e2.play()
        let start = mach_absolute_time() + 1_000_000
        e2._rt3aDriveOneExternalTick(at: start)
        let off = e2._noteBookPendingOff(channel: 1, note: 50, route: r2)
        e2.stop()
        let len = Double(Int64(off) - Int64(start)) / Double(pulse)
        #expect(abs(len - 84) < 1.5, "gehalten über 3/8 + 4/8 = 84 Pulse (gemessen \(len))")
    }
}
