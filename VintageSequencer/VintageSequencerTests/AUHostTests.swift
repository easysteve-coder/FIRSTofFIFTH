import Testing
import AppKit
import Foundation
import AVFoundation
import AudioToolbox
@testable import VintageSequencer

// MARK: - Ereigniswarteschlange (rein, ohne Audio)

struct AUEventQueueTests {

    private struct Out: Equatable { let offset: Int; let b0: UInt8; let b1: UInt8 }

    private func render(_ q: AUEventQueue, start: UInt64, frames: Int = 512, tpf: Double = 10,
                        valid: Bool = true) -> [Out] {
        var out: [Out] = []
        q.render(hostStart: start, hostValid: valid, frames: frames, ticksPerFrame: tpf) { offset, packed in
            out.append(Out(offset: offset, b0: UInt8(truncatingIfNeeded: packed),
                           b1: UInt8(truncatingIfNeeded: packed >> 8)))
        }
        return out
    }

    private func activeQueue() -> AUEventQueue { let q = AUEventQueue(); q.setActive(true); return q }

    /// Routenlatenz (Codex T7): mit Ausgleich geht das Tick-Ereignis um die Latenz früher in
    /// den Renderweg; Vorhören von Main („sofort") bleibt unberührt.
    @Test func routeLatencyAdvancesTickEventsOnly() {
        let q = activeQueue()
        q.setLatencyAdvance(2_000)
        q.pushFromTick(0x90, 60, 100, at: 12_000)          // → 10_000
        #expect(render(q, start: 0).isEmpty)
        #expect(render(q, start: 5_120) == [Out(offset: 488, b0: 0x90, b1: 60)], "(10000 − 5120) / 10")
        q.setLatencyAdvance(50_000)
        q.pushFromTick(0x90, 61, 100, at: 12_000)          // läge vor 0 → sofort fällig, nie 0
        #expect(render(q, start: 15_360) == [Out(offset: 0, b0: 0x90, b1: 61)])
    }

    /// Ein Ereignis erscheint in dem Block, in dessen Fenster seine Host-Zeit fällt, am
    /// passenden Sample-Offset — nicht früher.
    @Test func eventLandsInItsBlockAtTheRightSampleOffset() {
        let q = activeQueue()
        // Block = 512 Frames × 10 Ticks = 5120 Ticks. Ereignis bei 10_000 + 2_000 Ticks.
        q.pushFromTick(0x90, 60, 100, at: 12_000)
        #expect(render(q, start: 0).isEmpty, "liegt hinter Block 1 (0 ..< 5120)")
        #expect(render(q, start: 5_120).isEmpty, "liegt hinter Block 2 (5120 ..< 10240)")
        let out = render(q, start: 10_240)
        #expect(out == [Out(offset: 176, b0: 0x90, b1: 60)], "(12000 − 10240) / 10 = 176")
        #expect(render(q, start: 15_360).isEmpty, "nur einmal ausgegeben")
    }

    /// Überfällige und „sofort"-Ereignisse gehen mit Offset 0 in den nächsten Block.
    @Test func lateAndImmediateEventsGoOutAtOffsetZero() {
        let q = activeQueue()
        q.pushFromTick(0x90, 60, 100, at: 90_000)    // schon vorbei (unter der Verwurfsgrenze, v1.18.36)
        q.pushFromMain(0x80, 61, 0)                   // hostTime 0 = sofort
        let out = render(q, start: 100_000)
        #expect(Set(out.map(\.b1)) == [60, 61])
        #expect(out.allSatisfy { $0.offset == 0 })
    }

    /// Ereignisse kommen nicht in Zeitfolge an (späteres On zuerst, früheres Off danach):
    /// jedes wird nach seiner eigenen Zeit ausgegeben; bei gleichem Zeitpunkt bleibt die
    /// Ankunftsreihenfolge (Off vor On beim Neuanschlag).
    @Test func outOfOrderArrivalIsScheduledByTimeAndStableForEqualTimes() {
        let q = activeQueue()
        q.pushFromTick(0x90, 72, 100, at: 20_000)     // weit voraus
        q.pushFromTick(0x80, 60, 0,   at: 1_000)      // Neuanschlag: Off …
        q.pushFromTick(0x90, 60, 100, at: 1_000)      // … dann On, gleiche Zeit
        let first = render(q, start: 0)
        #expect(first == [Out(offset: 100, b0: 0x80, b1: 60), Out(offset: 100, b0: 0x90, b1: 60)])
        #expect(render(q, start: 5_120).isEmpty)
        #expect(render(q, start: 10_240).isEmpty)
        #expect(render(q, start: 15_360) == [Out(offset: 464, b0: 0x90, b1: 72)])
    }

    /// invalidate() verwirft alles Eingereihte — auch was schon in der Warteliste liegt.
    @Test func invalidateDropsQueuedAndPendingEvents() {
        let q = activeQueue()
        q.pushFromTick(0x90, 60, 100, at: 50_000)
        #expect(render(q, start: 0).isEmpty)          // wandert in die Warteliste
        q.pushFromTick(0x90, 62, 100, at: 50_000)     // noch im Ring
        q.invalidate()
        q.pushFromMain(0x80, 60, 0)                   // nach dem Ungültigmachen: gilt
        let out = render(q, start: 48_000, frames: 512)
        #expect(out == [Out(offset: 0, b0: 0x80, b1: 60)])
        #expect(q._pendingCount == 0)
    }

    /// Ohne geladenes Instrument verwerfen die Produzenten sofort (kein Ring-Überlauf).
    @Test func inactiveQueueAcceptsNothing() {
        let q = AUEventQueue()
        for _ in 0..<5_000 { q.pushFromTick(0x90, 60, 100, at: 1) }
        q.setActive(true)
        #expect(render(q, start: 0).isEmpty)
        #expect(q._rejectedCount == 0)
    }

    /// Überlast (H1, v1.13.13): Mehr Zukunftsereignisse als Warteliste und Ring fassen —
    /// keines wird vor seiner Zeit ausgegeben, der volle Ring weist ab und meldet es, und
    /// alles Übernommene kommt zu seiner Zeit an.
    @Test func overloadNeverEmitsEarlyAndReportsRejection() {
        let q = activeQueue()
        let future: UInt64 = 1_000_000_000
        var accepted = 0, refused = 0
        for i in 0..<(AUEventRing.capacity + 100) {
            if q.pushFromTick(0x80, UInt8(i % 128), 0, at: future) { accepted += 1 } else { refused += 1 }
        }
        #expect(accepted == AUEventRing.capacity && refused == 100 && q._rejectedCount == 100)
        // Mehrere Blöcke vor der Zeit: nichts kommt heraus, die Warteliste ist voll, der Rest
        // wartet im Ring.
        for k in 0..<4 { #expect(render(q, start: UInt64(k) * 5_120).isEmpty) }
        #expect(q._pendingCount == AUEventQueue.pendingCapacity)
        #expect(q._backlogCount >= 1)
        // Zur Zeit: alles Übernommene, in Ankunftsreihenfolge, nichts doppelt.
        var delivered = 0
        for k in 0..<4 { delivered += render(q, start: future + UInt64(k) * 5_120).count }
        #expect(delivered == accepted)
    }

    /// Arbeitsgrenze (H7): Füllt der Produzent während des Leerens nach, entnimmt ein Block
    /// trotzdem höchstens `pendingCapacity` Ereignisse — auch wenn sie alle veraltet sind.
    @Test func renderWorkIsBoundedWhileTheProducerRefills() {
        let q = activeQueue()
        for i in 0..<AUEventRing.capacity { q.pushFromMain(0x90, UInt8(i % 128), 1, at: 1) }
        q.invalidate()                                    // alles Eingereihte veraltet
        q._afterCountersLoaded = {
            for i in 0..<300 { q.pushFromTick(0x90, UInt8(i % 128), 1, at: 1) }
        }
        _ = render(q, start: 0)
        #expect(q._lastDrainCount <= AUEventQueue.pendingCapacity)
        q._afterCountersLoaded = nil
    }

    /// Kosten eines Blocks bei voller Warteliste und vollen Ringen (v1.16.1, Codex V16-4).
    /// Zwei getrennte Größen: Arbeitskosten als Thread-CPU-Zeit (ohne Preemption) und
    /// Wandzeit (mit Scheduler-Störungen). Grenzen: CPU p95 < 500 µs und CPU-Maximum unter
    /// der Blockzeit (64 Frames bei 48 kHz = 1333 µs) — eigene langsame Arbeit fällt damit
    /// auch als einzelner Ausreißer auf. Wandzeit-Überschreitungen der Blockzeit werden
    /// gezählt und mit p95/p99/max immer als Messdatei abgelegt (`fof-render-cost.txt`).
    @Test func renderCostAtFullLoad() {
        let q = activeQueue()
        var wall: [UInt64] = [], cpu: [UInt64] = []
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        for round in 0..<200 {
            for i in 0..<AUEventRing.capacity {
                _ = q.pushFromTick(0x90, UInt8(i % 128), 1, at: round % 2 == 0 ? 1 : 1_000_000_000)
                _ = q.pushFromMain(0x80, UInt8(i % 128), 0, at: 1_000_000_000)
            }
            let c0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let t0 = mach_absolute_time()
            q.render(hostStart: 0, hostValid: true, frames: 64, ticksPerFrame: 10, emit: { _, _ in })
            wall.append(mach_absolute_time() - t0)
            cpu.append(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - c0)
        }
        let deadline = 1_333.0
        let wallUs = wall.map { Double($0) * Double(tb.numer) / Double(tb.denom) / 1_000 }.sorted()
        let cpuUs  = cpu.map { Double($0) / 1_000 }.sorted()
        func pct(_ v: [Double], _ p: Int) -> Double { v[min(v.count - 1, v.count * p / 100)] }
        let overruns = wallUs.filter { $0 > deadline }.count
        let report = String(format: "blocks=%d cpu_p95=%.1f cpu_p99=%.1f cpu_max=%.1f wall_p95=%.1f wall_p99=%.1f wall_max=%.1f wall_overruns=%d deadline_us=%.0f\n",
                            wall.count, pct(cpuUs, 95), pct(cpuUs, 99), cpuUs.last!,
                            pct(wallUs, 95), pct(wallUs, 99), wallUs.last!, overruns, deadline)
        try? report.write(to: FileManager.default.temporaryDirectory
            .appendingPathComponent("fof-render-cost.txt"), atomically: true, encoding: .utf8)
        #expect(pct(cpuUs, 95) < 500, "Arbeitskosten p95: \(report)")
        #expect(cpuUs.last! < deadline, "Arbeitskosten einzelner Block über der Blockzeit: \(report)")
    }

    /// Leeren während eines laufenden Blocks (H2): Aufräumen, das nach `invalidate` eingereiht
    /// wird, während der Konsument noch die alte Generation hält, geht nicht verloren; die
    /// alten Ereignisse fallen weg.
    @Test func cleanupQueuedAfterMidBlockInvalidateSurvives() {
        let q = activeQueue()
        q.pushFromTick(0x90, 60, 100, at: 1)              // alt
        q._afterCountersLoaded = {
            q.invalidate()
            q.pushFromMain(0xB0, 123, 0)                  // All Notes Off, neue Generation
        }
        let out = render(q, start: 0)
        q._afterCountersLoaded = nil
        #expect(out == [Out(offset: 0, b0: 0xB0, b1: 123)])
    }

    /// Belegung (H3): Ereignisse, die für eine frühere Belegung geplant wurden, erreichen die
    /// neue nie — weder beim Einreihen noch aus der Warteliste. Ereignisse der neuen Belegung
    /// gehen auch dann durch, wenn der Wechsel während eines Blocks geschieht.
    @Test func eventsForAnEarlierOccupancyNeverReachTheNewOne() {
        let q = activeQueue()
        let old = q.occupancyEpoch
        q.pushFromTick(0x90, 60, 100, at: 50_000, epoch: old)
        #expect(render(q, start: 0).isEmpty)              // liegt in der Warteliste
        let new = q.beginOccupancy()
        #expect(q.pushFromTick(0x90, 61, 100, at: 1, epoch: old), "verworfen gilt als erledigt")
        #expect(q.pushFromMain(0x80, 62, 0, epoch: old))
        q.pushFromTick(0x90, 63, 100, at: 40_000, epoch: new)   // knapp überfällig, nicht verworfen
        let out = render(q, start: 50_000)
        #expect(out.map(\.b1) == [63])
        // Wechsel mitten im Block: Ereignis der neuen Belegung kommt durch.
        q._afterCountersLoaded = { let e = q.beginOccupancy(); q.pushFromMain(0x90, 64, 1, epoch: e) }
        #expect(render(q, start: 60_000).map(\.b1) == [64])
        q._afterCountersLoaded = nil
    }

    /// Offline-Rendering trägt keine Host-Zeit: alles Eingereihte gilt als fällig.
    @Test func withoutHostTimeEverythingIsDue() {
        let q = activeQueue()
        q.pushFromTick(0x90, 60, 100, at: 999_999_999)
        #expect(render(q, start: 0, valid: false).count == 1)
    }
}

// MARK: - Routing im Tick-Pfad

@Suite(.serialized) struct AUHostRoutingTests {

    private final class SendLog: @unchecked Sendable {
        private let lock = NSLock(); private var items: [(UInt8, UInt8)] = []
        func add(_ a: UInt8, _ b: UInt8) { lock.lock(); items.append((a, b)); lock.unlock() }
        var all: [(UInt8, UInt8)] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private func drain(_ q: AUEventQueue) -> [(b0: UInt8, b1: UInt8)] {
        var out: [(UInt8, UInt8)] = []
        q.render(hostStart: 0, hostValid: false, frames: 512, ticksPerFrame: 1) { _, packed in
            out.append((UInt8(truncatingIfNeeded: packed), UInt8(truncatingIfNeeded: packed >> 8)))
        }
        return out.map { (b0: $0.0, b1: $0.1) }
    }

    /// Eine Spur mit Instrumentenkanal sendet ihre Noten in dessen Warteschlange und
    /// nicht an CoreMIDI; die Nachbarspur ohne Kanal bleibt bei CoreMIDI.
    @MainActor @Test func routedTrackFeedsItsInstrumentQueueAndNotCoreMIDI() throws {
        let engine = SequencerEngine()
        let log = SendLog()
        engine.midi._testSendObserver = { b0, b1, _, _, _ in log.add(b0, b1) }
        let channelID = try #require(engine.rack.addChannel(name: "Test"))
        let route = engine.rack.route(for: channelID)
        #expect(route >= 0)
        engine.rack.queue(route).setActive(true)          // als wäre ein Instrument geladen

        let tracks = engine.patterns[0].tracks
        for (i, note) in [(0, 60), (1, 67)] {
            tracks[i].lane.steps[0].isActive = true
            tracks[i].lane.steps[0].notes = [note]
            tracks[i].lane.steps[0].probability = 1
        }
        tracks[0].instrumentID = channelID
        tracks[0].midiChannel  = 3

        engine.setClockMode(.external)
        engine.play()
        #expect(engine._rt1PublishedBundle()?.snapshot.tracks[0].route == route)
        #expect(engine._rt1PublishedBundle()?.snapshot.tracks[1].route == -1)
        engine._rt3aDriveOneExternalTick(at: mach_absolute_time() + 1_000_000)

        let au = drain(engine.rack.queue(route))
        #expect(au.contains { $0.b0 == 0x90 && $0.b1 == 60 }, "Note-On im Instrument auf Kanal 1, Spurkanal 3 gilt nur für MIDI (v1.18.33)")
        let midiOns = log.all.filter { $0.0 & 0xF0 == 0x90 }
        #expect(midiOns.contains { $0.1 == 67 }, "ungeroutete Spur → CoreMIDI")
        #expect(!midiOns.contains { $0.1 == 60 }, "geroutete Spur darf nicht an CoreMIDI gehen")
        #expect(engine._noteBookPendingOff(channel: 1, note: 60, route: route) != 0, "Off im Buchabschnitt des Instruments")
        #expect(engine._noteBookPendingOff(channel: 3, note: 60) == 0)

        // Stop: geplante Ereignisse verworfen, Note beendet, Buch leer.
        engine.stop()
        let after = drain(engine.rack.queue(route))
        #expect(after.contains { $0.b0 == 0x80 && $0.b1 == 60 }, "Note-Off nach Stop")
        #expect(after.contains { $0.b0 & 0xF0 == 0xB0 && $0.b1 == 123 }, "All Notes Off nach Stop")
        #expect(!after.contains { $0.b0 & 0xF0 == 0x90 })
        #expect(engine._noteBookEntry(channel: 1, note: 60, route: route) == 0)
    }

    /// CC-Lane mit Instrument-Parameter als Ziel (v1.13.9): der Tick-Pfad reiht ein
    /// Parameter-Ereignis mit dem auf den Wertebereich abgebildeten Wert ein, kein MIDI-CC.
    /// Ohne Ziel bleibt es beim CC auf dem Kanal der Spur.
    @MainActor @Test func ccLaneWithParameterTargetSchedulesParameterEvents() throws {
        let engine = SequencerEngine()
        let channelID = try #require(engine.rack.addChannel(name: "Test"))
        let route = engine.rack.route(for: channelID)
        engine.rack.queue(route).setActive(true)
        engine.rack._markInstrumentReady(channelID, as: Self.fakeInstrument)
        engine.rack._setParameters([.init(address: 42, name: "Cutoff", group: "", min: 20, max: 147)],
                                   for: channelID)
        _ = engine.addTrack(kind: .cc)
        let td = try #require(engine.currentPattern.tracks.last)
        #expect(td.lane.kind == .cc)
        td.instrumentID = channelID
        td.midiChannel = 5
        td.lane.ccNumber = 74
        td.lane.ccValues[0] = 127
        td.lane.ccParameter = ParameterRef(address: 42, name: "Cutoff",
                                           component: Self.fakeInstrument.componentKey)

        engine.setClockMode(.external)
        engine.play()
        #expect(engine._rt1PublishedBundle()?.snapshot.tracks.last?.parameter
                == ParameterTarget(address: 42, min: 20, max: 147))
        engine._rt3aDriveOneExternalTick(at: mach_absolute_time() + 1_000_000)
        var midi: [UInt32] = []; var params: [(UInt64, Float)] = []
        engine.rack.queue(route).render(hostStart: 0, hostValid: false, frames: 512, ticksPerFrame: 1,
                                        emit: { _, p in midi.append(p) },
                                        emitParameter: { _, a, v in params.append((a, v)) })
        #expect(params.count == 1 && params.first?.0 == 42 && params.first?.1 == 147)
        #expect(!midi.contains { $0 & 0xF0 == 0xB0 && ($0 >> 8) & 0x7F == 74 })
        engine.stop()

        // Ziel entfernt → wieder MIDI-CC im Instrument, auf Kanal 1 (Spurkanal 5 gilt nur für MIDI, v1.18.33).
        ModelWriter().apply(.setCCLaneParameter(trackID: td.id, old: td.lane.ccParameter, new: nil),
                            to: td, undoManager: nil)
        engine.play()
        engine._rt3aDriveOneExternalTick(at: mach_absolute_time() + 1_000_000)
        midi = []; params = []
        engine.rack.queue(route).render(hostStart: 0, hostValid: false, frames: 512, ticksPerFrame: 1,
                                        emit: { _, p in midi.append(p) },
                                        emitParameter: { _, a, v in params.append((a, v)) })
        #expect(params.isEmpty)
        #expect(midi.contains { $0 & 0xFF == 0xB0 && ($0 >> 8) & 0x7F == 74 && ($0 >> 16) & 0x7F == 127 })
        engine.stop()
    }

    static let fakeInstrument = PluginRef(description: AudioComponentDescription(
        componentType: kAudioUnitType_MusicDevice, componentSubType: 0x46414B45,      // 'FAKE'
        componentManufacturer: 0x54455354, componentFlags: 0, componentFlagsMask: 0), name: "Fake")

    /// Unaufgelöstes Parameterziel (H5, v1.13.13): Ist ein anderes Instrument geladen (oder
    /// noch keins bereit), sendet die Lane nichts — weder Parameter noch Ersatz-MIDI-CC.
    @MainActor @Test func unresolvedParameterTargetSendsNothing() throws {
        let engine = SequencerEngine()
        let channelID = try #require(engine.rack.addChannel(name: "Test"))
        let route = engine.rack.route(for: channelID)
        engine.rack.queue(route).setActive(true)
        _ = engine.addTrack(kind: .cc)
        let td = try #require(engine.currentPattern.tracks.last)
        td.instrumentID = channelID
        td.lane.ccNumber = 74
        td.lane.ccParameter = ParameterRef(address: 42, name: "Cutoff", component: "1-2-3")
        func playOnce() -> (midi: Int, params: Int, unresolved: Bool?) {
            engine.play()
            let unresolved = engine._rt1PublishedBundle()?.snapshot.tracks.last?.ccUnresolved
            engine._rt3aDriveOneExternalTick(at: mach_absolute_time() + 1_000_000)
            var m = 0, p = 0
            engine.rack.queue(route).render(hostStart: 0, hostValid: false, frames: 512, ticksPerFrame: 1,
                                            emit: { _, b in if b & 0xF0 == 0xB0, (b >> 8) & 0x7F == 74 { m += 1 } },
                                            emitParameter: { _, _, _ in p += 1 })
            engine.stop()
            return (m, p, unresolved)
        }
        // Instrument lädt noch (nicht bereit).
        var r = playOnce()
        #expect(r.unresolved == true && r.midi == 0 && r.params == 0)
        // Anderes Plug-in bereit, gleiche Adresse vorhanden: trotzdem nicht aufgelöst.
        engine.rack._markInstrumentReady(channelID, as: Self.fakeInstrument)
        engine.rack._setParameters([.init(address: 42, name: "X", group: "", min: 0, max: 1)], for: channelID)
        r = playOnce()
        #expect(r.unresolved == true && r.midi == 0 && r.params == 0)
        // Ohne Bindung (Datei aus v1.13.9 … v1.13.12): löst gegen das geladene Instrument auf.
        td.lane.ccParameter = ParameterRef(address: 42, name: "Cutoff")
        r = playOnce()
        #expect(r.unresolved == false && r.params == 1 && r.midi == 0)
    }

    /// Zielwahl der CC-Lane ist ein Undo-Schritt.
    @MainActor @Test func ccParameterChoiceIsUndoable() {
        let td = TrackData(name: "CC", lane: LaneData(stepCount: 8, kind: .cc))
        let undo = UndoManager()
        let ref = ParameterRef(address: 9, name: "Res", component: "a-b-c")
        ModelWriter().apply(.setCCLaneParameter(trackID: td.id, old: nil, new: ref), to: td, undoManager: undo)
        #expect(td.lane.ccParameter == ref)
        undo.undo()
        #expect(td.lane.ccParameter == nil)
        undo.redo()
        #expect(td.lane.ccParameter == ref)
    }

    /// Volle Warteschlange (H1, v1.13.13): Ein abgewiesenes Off gilt nicht als gesendet; es
    /// bleibt im Notenbuch und geht im nächsten Tick hinaus, sobald wieder Platz ist.
    @MainActor @Test func rejectedNoteOffStaysInTheBookAndIsRetried() throws {
        let engine = SequencerEngine()
        let channelID = try #require(engine.rack.addChannel(name: "Test"))
        let route = engine.rack.route(for: channelID)
        let q = engine.rack.queue(route)
        q.setActive(true)
        let td = engine.patterns[0].tracks[0]
        td.instrumentID = channelID; td.midiChannel = 1
        for i in td.lane.steps.indices { td.lane.steps[i].isActive = false }
        td.lane.steps[0].isActive = true; td.lane.steps[0].notes = [50]
        td.lane.steps[0].probability = 1; td.lane.steps[0].gate = 0.25

        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        let pulse = UInt64(60.0 / engine.bpm / 24.0 * 1_000_000_000 * Double(tb.denom) / Double(tb.numer))
        var t = mach_absolute_time() + 1_000_000
        engine.setClockMode(.external)
        engine.play()
        engine._rt3aDriveOneExternalTick(at: t)                                    // On
        #expect(engine._noteBookPendingOff(channel: 1, note: 50, route: route) != 0)
        // Ring füllen (für dieselbe Belegung), dann bis über das Gate-Ende ticken.
        while q.pushFromTick(0xB0, 1, 1, at: 1) {}
        for _ in 0..<4 { t += pulse; engine._rt3aDriveOneExternalTick(at: t) }
        #expect(engine._noteBookPendingOff(channel: 1, note: 50, route: route) != 0,
                "abgewiesenes Off bleibt im Buch")
        // Platz schaffen: Ring leeren. Nächster Tick sendet das Off.
        var offs = 0
        for _ in 0..<4 {
            q.render(hostStart: 0, hostValid: false, frames: 512, ticksPerFrame: 1) { _, b in
                if b & 0xF0 == 0x80, (b >> 8) & 0x7F == 50 { offs += 1 }
            }
        }
        t += pulse; engine._rt3aDriveOneExternalTick(at: t)
        #expect(engine._noteBookPendingOff(channel: 1, note: 50, route: route) == 0)
        q.render(hostStart: 0, hostValid: false, frames: 512, ticksPerFrame: 1) { _, b in
            if b & 0xF0 == 0x80, (b >> 8) & 0x7F == 50 { offs += 1 }
        }
        #expect(offs == 1, "Off genau einmal ausgegeben")
        engine.stop()
    }

    /// Belegungswechsel (H3, v1.13.13): Der Snapshot trägt die Belegung; Ereignisse aus einem
    /// Snapshot für die vorige Belegung erreichen das neue Instrument nicht, und ein
    /// verspätetes Vorhör-Off mit alter Belegung wird verworfen.
    @MainActor @Test func staleSnapshotEventsDoNotReachANewOccupant() throws {
        let engine = SequencerEngine()
        let channelID = try #require(engine.rack.addChannel(name: "Test"))
        let route = engine.rack.route(for: channelID)
        let q = engine.rack.queue(route)
        q.setActive(true)
        let td = engine.patterns[0].tracks[0]
        td.instrumentID = channelID
        td.lane.steps[0].isActive = true; td.lane.steps[0].notes = [60]; td.lane.steps[0].probability = 1
        engine.setClockMode(.external)
        engine.play()
        let snapEpoch = try #require(engine._rt1PublishedBundle()?.snapshot.tracks[0].routeEpoch)
        #expect(snapEpoch == q.occupancyEpoch)
        _ = q.beginOccupancy()                       // Instrument getauscht, Snapshot noch alt
        engine._rt3aDriveOneExternalTick(at: mach_absolute_time() + 1_000_000)
        var got = 0
        q.render(hostStart: 0, hostValid: false, frames: 512, ticksPerFrame: 1) { _, _ in got += 1 }
        #expect(got == 0, "nichts aus dem alten Snapshot beim neuen Instrument")
        #expect(engine.rack.sendFromMain(route: route, epoch: snapEpoch, 0x80, 60, 0))
        q.render(hostStart: 0, hostValid: false, frames: 512, ticksPerFrame: 1) { _, _ in got += 1 }
        #expect(got == 0, "verspätetes Off für die alte Belegung verworfen")
        engine.stop()
    }

    /// Verspäteter Ladeabschluss (H4, v1.13.13): Nach dem Ersetzen des Projekts trägt der Kanal
    /// dieselbe UUID, aber eine neue Live-Instanz. Der Abschluss des alten Ladeauftrags darf
    /// dort kein Instrument einsetzen; der neue Auftrag schon.
    @MainActor @Test func staleLoadCompletionIsIgnoredAfterReplaceAll() throws {
        let rack = InstrumentRack()
        var completions: [(AVAudioUnit?) -> Void] = []
        rack._instantiateOverride = { _, done in completions.append(done) }
        let id = try #require(rack.addChannel(name: "A"))
        rack.setMuted(id, true)
        rack.setInstrument(Self.fakeInstrument, for: id)
        #expect(completions.count == 1)
        let data = try #require(rack.channel(id))
        rack.replaceAll([data])                      // gleiche UUID, neue Live-Instanz, neuer Auftrag
        #expect(completions.count == 2)
        completions[0](AVAudioUnitSampler())         // alter Auftrag kommt spät an
        #expect(rack._liveInstrument(id) == nil && rack.instrumentStatus[id] == .loading)
        completions[1](AVAudioUnitSampler())
        #expect(rack._liveInstrument(id) != nil && rack.instrumentStatus[id] == .ready)
        rack._instantiateOverride = nil
    }

    /// Das Parameter-Ziel einer CC-Lane übersteht Speichern/Laden; Dateien ohne den
    /// Schlüssel laden mit MIDI-CC.
    @Test func ccParameterRoundTripsAndIsOptional() throws {
        let lane = LaneData(kind: .cc)
        lane.ccParameter = ParameterRef(address: 7, name: "Res", component: "1635085685-1684828960-1634758764")
        let data = try JSONEncoder().encode(lane)
        #expect(try JSONDecoder().decode(LaneData.self, from: data).ccParameter == lane.ccParameter)
        var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj["ccParameter"] = nil
        let old = try JSONDecoder().decode(LaneData.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(old.ccParameter == nil)
    }

    /// Zielwahl (v1.17.1): alphabetisch mit natürlicher Zahlenfolge, gleicher Name nach
    /// Gruppe; Suche mit mehreren Wörtern in Name oder Gruppe, ohne Groß-/Klein-/Akzent.
    @Test func parameterPickerSortsAndFilters() {
        func p(_ i: Int, _ n: String, _ g: String = "") -> InstrumentRack.ParameterInfo {
            .init(address: UInt64(i), name: n, group: g, min: 0, max: 1)
        }
        let all = [p(0, "Osc 10 Level", "Osc"), p(1, "Cutoff", "Filter 2"), p(2, "Osc 2 Level", "Osc"),
                   p(3, "Cutoff", "Filter 1"), p(4, "Résonance", "Filter 1"), p(5, "attack")]
        #expect(CCTargetPicker.filtered(all, query: "").map(\.address) == [5, 3, 1, 2, 0, 4])
        #expect(CCTargetPicker.filtered(all, query: "cut").map(\.address) == [3, 1])
        #expect(CCTargetPicker.filtered(all, query: "filter 2").map(\.address) == [1])
        #expect(CCTargetPicker.filtered(all, query: "reso").map(\.address) == [4])
        #expect(CCTargetPicker.filtered(all, query: "xyz").isEmpty)
    }

    static let fakeEffect = PluginRef(description: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: 0x46584658,          // 'FXFX'
        componentManufacturer: 0x54455354, componentFlags: 0, componentFlagsMask: 0), name: "FakeFX")

    /// Effekt als CC-Ziel (v1.17.1): der Wert geht in die Warteschlange des Effekts mit
    /// dessen Belegung, nicht an das Instrument; die laufende Nummer wählt unter gleichen
    /// Effekten; Entfernen gibt den Platz frei, das Ziel löst danach nicht mehr auf.
    @MainActor @Test func effectParameterTargetReachesTheEffectQueue() throws {
        let engine = SequencerEngine()
        let channelID = try #require(engine.rack.addChannel(name: "Test"))
        let route = engine.rack.route(for: channelID)
        engine.rack.queue(route).setActive(true)
        engine.rack._markInstrumentReady(channelID, as: Self.fakeInstrument)
        let free = engine.rack._freeEffectQueueCount
        let params: [InstrumentRack.ParameterInfo] = [.init(address: 7, name: "Mix", group: "", min: 0, max: 100)]
        let first  = try #require(engine.rack._addReadyEffect(Self.fakeEffect, parameters: params, to: channelID))
        let second = try #require(engine.rack._addReadyEffect(Self.fakeEffect, parameters: params, to: channelID))
        #expect(first != second && engine.rack._freeEffectQueueCount == free - 2)
        #expect(engine.rack.parameterSources(for: channelID).map(\.ordinal) == [nil, 0, 1])

        _ = engine.addTrack(kind: .cc)
        let td = try #require(engine.currentPattern.tracks.last)
        td.instrumentID = channelID
        td.lane.ccNumber = 74
        td.lane.ccValues[0] = 127
        td.lane.ccParameter = ParameterRef(address: 7, name: "Mix", component: Self.fakeEffect.componentKey, effect: 1)

        engine.setClockMode(.external)
        engine.play()
        let target = try #require(engine._rt1PublishedBundle()?.snapshot.tracks.last?.parameter)
        #expect(target.queue == second && target.epoch == engine.rack.effectQueue(second).occupancyEpoch)
        engine._rt3aDriveOneExternalTick(at: mach_absolute_time() + 1_000_000)
        var fx: [(UInt64, Float)] = [], inst = 0, other = 0
        engine.rack.effectQueue(second).render(hostStart: 0, hostValid: false, frames: 512, ticksPerFrame: 1,
                                               emit: { _, _ in }, emitParameter: { _, a, v in fx.append((a, v)) })
        engine.rack.effectQueue(first).render(hostStart: 0, hostValid: false, frames: 512, ticksPerFrame: 1,
                                              emit: { _, _ in }, emitParameter: { _, _, _ in other += 1 })
        engine.rack.queue(route).render(hostStart: 0, hostValid: false, frames: 512, ticksPerFrame: 1,
                                        emit: { _, _ in }, emitParameter: { _, _, _ in inst += 1 })
        #expect(fx.count == 1 && fx.first?.0 == 7 && fx.first?.1 == 100)
        #expect(other == 0 && inst == 0)
        engine.stop()

        // Zweiten Effekt entfernen: Platz frei, Ziel nicht mehr auflösbar (kein Ersatz).
        let oldEpoch = engine.rack.effectQueue(second).occupancyEpoch
        engine.rack.removeEffect(at: 1, from: channelID)
        #expect(engine.rack._freeEffectQueueCount == free - 1)
        #expect(engine.rack.effectQueue(second).occupancyEpoch != oldEpoch)
        #expect(engine.rack.resolveParameter(td.lane.ccParameter!, in: channelID) == nil)
        engine.play()
        #expect(engine._rt1PublishedBundle()?.snapshot.tracks.last?.ccUnresolved == true)
        engine.stop()
        // Ziel auf den verbliebenen (ersten) Effekt: löst auf dessen Platz auf.
        td.lane.ccParameter = ParameterRef(address: 7, name: "Mix", component: Self.fakeEffect.componentKey, effect: 0)
        #expect(engine.rack.resolveParameter(td.lane.ccParameter!, in: channelID)?.queue == first)
        engine.rack.removeChannel(channelID)
        #expect(engine.rack._freeEffectQueueCount == free, "Kanal entfernt: alle Effekt-Plätze frei")
    }

    /// Format: `effect` wird nur für Effekt-Ziele geschrieben und gelesen.
    @Test func effectParameterRefRoundTrips() throws {
        let fx = ParameterRef(address: 3, name: "Mix", component: "a-b-c", effect: 2)
        #expect(try JSONDecoder().decode(ParameterRef.self, from: JSONEncoder().encode(fx)) == fx)
        let inst = ParameterRef(address: 3, name: "Cut", component: "a-b-c")
        #expect(!String(decoding: try JSONEncoder().encode(inst), as: UTF8.self).contains("effect"))
    }

    /// Ein Parameter-Ereignis erreicht einen echten Effekt (Apple AUDelay, ausgelagert) über
    /// dessen Render-Observer und Schedule-Block (v1.17.1).
    @MainActor @Test func parameterEventReachesTheRealEffect() async throws {
        let rack = InstrumentRack()
        let id = try #require(rack.addChannel(name: "FX")); rack.setMuted(id, true)
        let dls = PluginRef(description: AudioComponentDescription(
            componentType: kAudioUnitType_MusicDevice, componentSubType: kAudioUnitSubType_DLSSynth,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0),
            name: "DLSMusicDevice")
        let delay = PluginRef(description: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_Delay,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0),
            name: "AUDelay")
        rack.setInstrument(dls, for: id)
        rack.addEffect(delay, to: id)
        let deadline = Date().addingTimeInterval(60)
        while (rack.instrumentStatus[id] == .loading || rack.effectStatus[id]?.first == .loading), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try #require(rack.instrumentStatus[id] == .ready && rack.effectStatus[id]?.first == .ready, "DLS/AUDelay nicht ladbar")
        guard rack._engineIsRunning else { Issue.record("Audio-Engine läuft nicht"); return }
        let src = try #require(rack.parameterSources(for: id).first { $0.effectIndex == 0 })
        let info = try #require(rack.parameters(for: id, source: src).first, "AUDelay meldet keine Parameter")
        let ref = InstrumentRack.parameterRef(info, of: src)
        let target = try #require(rack.resolveParameter(ref, in: id))
        #expect(target.queue >= 0)
        let unit = try #require(rack._liveEffect(id, at: 0))
        let param = try #require(unit.auAudioUnit.parameterTree?.parameter(withAddress: info.address))
        let value = info.min + (info.max - info.min) * 0.25
        try #require(abs(param.value - value) > 0.001)
        rack.effectQueue(target.queue).pushParameterFromTick(address: info.address, value: value, at: 0,
                                                             epoch: target.epoch)
        var reached = false
        for _ in 0..<60 where !reached {
            try await Task.sleep(nanoseconds: 50_000_000)
            reached = abs(param.value - value) < 0.001
        }
        #expect(reached, "Parameter \(info.name) steht auf \(param.value), erwartet \(value)")
    }

    /// Wächter (v1.13.11): Entscheidungstabelle.
    @Test func watchdogDecisions() {
        typealias R = InstrumentRack
        #expect(R.watchdogFinding(needed: false, running: false, tapInstalled: true, stalledTicks: 9, nonFinite: true) == nil)
        #expect(R.watchdogFinding(needed: true, running: false, tapInstalled: true, stalledTicks: 0, nonFinite: false) == .stopped)
        #expect(R.watchdogFinding(needed: true, running: true, tapInstalled: true, stalledTicks: R.stallTicks - 1, nonFinite: false) == nil)
        #expect(R.watchdogFinding(needed: true, running: true, tapInstalled: true, stalledTicks: R.stallTicks, nonFinite: false) == .stalled)
        #expect(R.watchdogFinding(needed: true, running: true, tapInstalled: false, stalledTicks: 5, nonFinite: false) == nil)
        #expect(R.watchdogFinding(needed: true, running: true, tapInstalled: true, stalledTicks: 0, nonFinite: true) == .nonFinite)
    }

    /// Ungültige Samples werden gemeldet und nicht als Pegel angezeigt; jeder Block zählt.
    @Test func levelMeterFlagsNonFiniteSamples() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
        buffer.frameLength = 8
        let meter = LevelMeter()
        buffer.floatChannelData![0][3] = 0.5
        meter.feed(buffer)
        #expect(meter.blockCount == 1 && !meter.takeNonFinite() && meter.take().left == 0.5)
        buffer.floatChannelData![1][2] = .nan
        meter.feed(buffer)
        #expect(meter.blockCount == 2 && meter.takeNonFinite() && !meter.takeNonFinite())
        #expect(meter.take().left == 0)
    }

    /// Diagnose-Rohwerte (v1.13.14): Spitze über 1 bleibt erhalten, Samples über 1,0 und
    /// NaN/∞ werden gezählt, Abholung setzt zurück — unabhängig von der Anzeige.
    @Test func levelMeterDiagnosticsKeepRawPeakAndCount() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
        buffer.frameLength = 8
        let meter = LevelMeter()
        buffer.floatChannelData![0][1] = 3.5e6
        buffer.floatChannelData![1][2] = 2
        buffer.floatChannelData![1][4] = .infinity
        meter.feed(buffer)
        _ = meter.take()                                   // Anzeige holt ab …
        let d = meter.takeDiagnostics()                    // … die Diagnose bekommt trotzdem alles
        #expect(d.peak == 3.5e6 && d.over == 2 && d.over16 == 1 && d.nonFinite == 1)
        #expect(d.dc > 0 && d.rms > 0)
        let again = meter.takeDiagnostics()
        #expect(again.peak == 0 && again.over == 0 && again.nonFinite == 0)
    }

    /// Die Aufzeichnung schreibt Kopf, Messprobe mit Kanal, Markierung und Ende als JSON Lines.
    @MainActor @Test func diagnosticsRecorderWritesJSONLines() throws {
        let key = "audioDiagnosticsOn"
        let before = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(before, forKey: key) }
        let rack = InstrumentRack()
        _ = try #require(rack.addChannel(name: "Diag"))
        rack.diagnostics.start()
        let url = try #require(rack.diagnostics.fileURL)
        defer { try? FileManager.default.removeItem(at: url) }
        rack._watchdogTick()
        rack.diagnostics.mark()
        rack.diagnostics.stop()
        #expect(!rack.diagnostics.isRecording && UserDefaults.standard.bool(forKey: key) == false)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        let objs = try lines.map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        #expect(objs.map { $0["k"] as? String } == ["start", "s", "mark", "stop"])
        #expect(objs.map { $0["n"] as? Int } == [1, 2, 3, 4])
        let channels = (objs[1]["ch"] as? [[String: Any]]) ?? []
        #expect(channels.first?["name"] as? String == "Diag")
        #expect((objs[0]["channels"] as? [[String: Any]])?.count == 1)
        #expect(objs[1]["device"] is [String: Any])
    }

    /// 0 dB wird als Gleitkommazahl formatiert (vorher Int als CVarArg).
    @Test func decibelLabelAtZero() {
        #expect(FaderLaw.decibelLabel(forPosition: FaderLaw.position(forDecibels: 0)) == "0.0")
    }

    /// Hält die Engine an, ohne dass das Rack es veranlasst hat, bringt der Wächter sie zurück
    /// und das Instrument rendert wieder.
    @MainActor @Test func watchdogRestartsAStoppedEngine() async throws {
        let rack = InstrumentRack()
        let id = try #require(rack.addChannel(name: "DLS")); rack.setMuted(id, true)
        let dls = PluginRef(description: AudioComponentDescription(
            componentType: kAudioUnitType_MusicDevice, componentSubType: kAudioUnitSubType_DLSSynth,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0),
            name: "DLSMusicDevice")
        rack.setInstrument(dls, for: id)
        let deadline = Date().addingTimeInterval(60)
        while rack.instrumentStatus[id] == .loading, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        try #require(rack.instrumentStatus[id] == .ready, "DLS-Synthesizer nicht ladbar")
        guard rack._engineIsRunning else { Issue.record("Audio-Engine läuft nicht"); return }
        rack._stopEngineBehindTheRacksBack()
        #expect(!rack._engineIsRunning)
        rack._watchdogTick()
        #expect(rack._engineIsRunning)
        #expect(rack.audioRecoveries == 1 && rack.lastRecoveryFinding == .stopped)
        #expect(rack._liveInstrument(id)?.auAudioUnit.renderResourcesAllocated == true)
    }

    /// Ein Parameter-Ereignis erreicht das echte Instrument über Render-Observer und
    /// Schedule-Block (Apple DLS, ausgelagerter Prozess).
    @MainActor @Test func parameterEventReachesTheRealInstrument() async throws {
        let rack = InstrumentRack()
        let id = try #require(rack.addChannel(name: "DLS")); rack.setMuted(id, true)
        let dls = PluginRef(description: AudioComponentDescription(
            componentType: kAudioUnitType_MusicDevice, componentSubType: kAudioUnitSubType_DLSSynth,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0),
            name: "DLSMusicDevice")
        rack.setInstrument(dls, for: id)
        let deadline = Date().addingTimeInterval(60)
        while rack.instrumentStatus[id] == .loading, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        try #require(rack.instrumentStatus[id] == .ready, "DLS-Synthesizer nicht ladbar")
        guard rack._engineIsRunning else { Issue.record("Audio-Engine läuft nicht"); return }
        let info = try #require(rack.parameters(for: id).first, "DLS meldet keine schreibbaren Parameter")
        let unit = try #require(rack._liveInstrument(id))
        let param = try #require(unit.auAudioUnit.parameterTree?.parameter(withAddress: info.address))
        let target = info.min + (info.max - info.min) * 0.25
        try #require(abs(param.value - target) > 0.001)
        rack.queue(rack.route(for: id)).pushParameterFromTick(address: info.address, value: target, at: 0)
        var reached = false
        for _ in 0..<60 where !reached {
            try await Task.sleep(nanoseconds: 50_000_000)
            reached = abs(param.value - target) < 0.001
        }
        #expect(reached, "Parameter \(info.name) steht auf \(param.value), erwartet \(target)")
    }

    /// Drone-Step (v1.13.12): ein Anschlag, das Off steht einen ganzen Durchlauf plus einen
    /// halben Step später aus; kommt der Step wieder, wird verlängert statt neu angeschlagen.
    /// Ohne Drone endet der Ton nach seinem Gate.
    @MainActor @Test func droneStepHoldsForTheWholeTrackAndIsNotRestruck() throws {
        let engine = SequencerEngine()
        let channelID = try #require(engine.rack.addChannel(name: "Test"))
        let route = engine.rack.route(for: channelID)
        engine.rack.queue(route).setActive(true)
        let td = engine.patterns[0].tracks[0]
        td.instrumentID = channelID; td.midiChannel = 1
        td.lane.stepCount = 4
        td.lane.steps[0].isActive = true; td.lane.steps[0].notes = [48]
        td.lane.steps[0].probability = 1; td.lane.steps[0].isDrone = true
        td.lane.steps[0].ratchet = .x4                      // gilt bei Drone nicht

        engine.setClockMode(.external)
        engine.play()
        #expect(engine._rt1PublishedBundle()?.snapshot.tracks[0].lane.stepCount == 4)
        var ons = 0, offs = 0
        func drainCounts() {
            for e in drain(engine.rack.queue(route)) where e.b1 == 48 {
                if e.b0 & 0xF0 == 0x90 { ons += 1 } else if e.b0 & 0xF0 == 0x80 { offs += 1 }
            }
        }
        // Zwei volle Durchläufe (4 Steps × 6 Pulse) und ein Stück des dritten.
        var t = mach_absolute_time() + 1_000_000
        // Pulsabstand passend zum Tempo der Engine (24 Pulse je Viertel), in Host-Zeit.
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        let pulseNanos = 60.0 / engine.bpm / 24.0 * 1_000_000_000
        let pulse = UInt64(pulseNanos * Double(tb.denom) / Double(tb.numer))
        var firstOff: UInt64 = 0
        for i in 0..<60 {
            engine._rt3aDriveOneExternalTick(at: t)
            if i == 0 { firstOff = engine._noteBookPendingOff(channel: 1, note: 48, route: route) }
            t += pulse
        }
        drainCounts()
        #expect(ons == 1, "Drone wird nicht neu angeschlagen (Note-Ons: \(ons))")
        #expect(offs == 0, "Drone endet nicht, solange der Step wiederkommt")
        let later = engine._noteBookPendingOff(channel: 1, note: 48, route: route)
        #expect(firstOff != 0 && later > firstOff, "Ende wird je Durchlauf hinausgeschoben")
        engine.stop()
        drainCounts()
        #expect(offs >= 1, "Stop beendet den Drone")
    }

    /// Das Drone-Kennzeichen übersteht Speichern/Laden und fehlt in Dateien ohne Drone.
    @Test func droneFlagRoundTripsAndIsOnlyWrittenWhenSet() throws {
        var s = Step(); s.isActive = true
        let plain = try JSONEncoder().encode(s)
        #expect(!String(decoding: plain, as: UTF8.self).contains("drone"))
        #expect(try JSONDecoder().decode(Step.self, from: plain).isDrone == false)
        s.isDrone = true
        #expect(try JSONDecoder().decode(Step.self, from: JSONEncoder().encode(s)).isDrone)
    }

    /// Wird ein Kanal entfernt, fallen seine Spuren auf externe MIDI-Ausgabe zurück.
    @MainActor @Test func removingAChannelReturnsItsTracksToExternalMIDI() throws {
        let engine = SequencerEngine()
        let id = try #require(engine.rack.addChannel(name: "X"))
        engine.patterns[0].tracks[0].instrumentID = id
        engine.patterns[2].tracks[1].instrumentID = id
        engine.rack.removeChannel(id)
        #expect(engine.patterns[0].tracks[0].instrumentID == nil)
        #expect(engine.patterns[2].tracks[1].instrumentID == nil)
        #expect(engine.rack.route(for: id) == -1)
        #expect(engine.hasUnsavedChanges)
    }

    @MainActor @Test func trackOutputChangeIsUndoable() {
        let track = TrackData(name: "T", stepCount: 4, midiChannel: 1)
        let id = UUID(); let um = UndoManager()
        ModelWriter().apply(.setInstrument(trackID: track.id, old: nil, new: id), to: track, undoManager: um)
        #expect(track.instrumentID == id)
        um.undo()
        #expect(track.instrumentID == nil)
    }
}

// MARK: - Projektformat

@Suite(.serialized) struct AUHostPersistenceTests {

    /// Ein Preset ohne Instrumentenkanäle sieht aus wie bisher (kein neuer Key).
    @MainActor @Test func presetWithoutRackHasNoInstrumentsKey() throws {
        let engine = SequencerEngine()
        let data = try #require(engine.saveData())
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["instruments"] == nil)
    }

    /// Kanäle, Routing und der Zustand eines NICHT installierten Plug-ins überleben
    /// Speichern → Laden → Speichern unverändert; der Kanal meldet „fehlt".
    @MainActor @Test func missingPlugInKeepsIdentityAndStateAcrossSaveLoadSave() async throws {
        let bogus = PluginRef(description: AudioComponentDescription(
            componentType: kAudioUnitType_MusicDevice, componentSubType: 0x7A7A7A31,
            componentManufacturer: 0x7A7A7A32, componentFlags: 0, componentFlagsMask: 0),
            name: "Nicht installiert", state: Data([1, 2, 3, 4, 5]))
        var channel = InstrumentChannelData(name: "Bass")
        channel.instrument = bogus
        channel.volume = 0.42; channel.pan = -0.5

        let first = SequencerEngine()
        first.rack.replaceAll([channel])
        first.patterns[1].tracks[0].instrumentID = channel.id
        let saved = try #require(first.saveData())

        let second = SequencerEngine()
        #expect(second.loadData(saved))
        #expect(second.rack.channels.count == 1)
        #expect(second.patterns[1].tracks[0].instrumentID == channel.id)
        #expect(second.rack.route(for: channel.id) >= 0)
        for _ in 0..<100 where second.rack.instrumentStatus[channel.id] == .loading {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(second.rack.instrumentStatus[channel.id] == .missing)

        let again = try #require(second.saveData())
        let file = try JSONDecoder().decode(PresetManager.PresetFile.self, from: again)
        let restored = try #require(file.instruments?.first)
        #expect(restored.instrument == bogus, "Identität, Name und Zustand unverändert")
        #expect(restored.volume == 0.42 && restored.pan == -0.5 && restored.name == "Bass")

        // Neues Projekt leert das Rack.
        second.rack.replaceAll([])
        #expect(second.rack.channels.isEmpty && second.rack.route(for: channel.id) == -1)
    }
}

// MARK: - Echtes Instrument (Apple DLS-Synthesizer)

@Suite(.serialized) struct AUHostRealInstrumentTests {

    /// Misst am Instrumentenausgang: Spitzenpegel seit der letzten Abfrage und die Host-Zeit
    /// des ersten Samples über der Schwelle (aus dem Zeitstempel des Tap-Puffers).
    private final class Meter: @unchecked Sendable {
        private let lock = NSLock()
        private var peak: Float = 0
        private var onset: UInt64 = 0
        var hostTicksPerSecond: Double = 0
        func feed(_ buffer: AVAudioPCMBuffer, _ when: AVAudioTime) {
            guard let ch = buffer.floatChannelData else { return }
            var m: Float = 0; var first = -1
            for i in 0..<Int(buffer.frameLength) {
                let v = abs(ch[0][i])
                if v > m { m = v }
                if first < 0, v > 0.002 { first = i }
            }
            lock.lock(); defer { lock.unlock() }
            peak = max(peak, m)
            if onset == 0, first >= 0, when.isHostTimeValid {
                onset = when.hostTime + UInt64(Double(first) / buffer.format.sampleRate * hostTicksPerSecond)
            }
        }
        func takePeak() -> Float { lock.lock(); defer { lock.unlock() }; let v = peak; peak = 0; return v }
        var onsetHostTime: UInt64 { lock.lock(); defer { lock.unlock() }; return onset }
    }

    private func wait(upTo seconds: Double, until done: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while await !done(), Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    /// Mehrfach installierte Plug-ins erscheinen in der Auswahl nur einmal (v1.13.7).
    @MainActor @Test func componentListsHaveNoDuplicates() {
        let rack = InstrumentRack()
        for list in [rack.availableInstruments(), rack.availableEffects()] {
            #expect(Set(list.map(\.id)).count == list.count)
        }
    }

    /// Ein Kanal, der bei laufender Engine dazukommt, muss in den Renderweg aufgenommen
    /// werden (v1.13.7): ohne das blieb er stumm, und Plug-ins, die ihre Freischaltung bis
    /// zum Anlegen der Render-Ressourcen aufschieben (UADx), zeigten einen unscharfen Editor.
    @MainActor @Test func channelAddedWhileEngineRunsIsRendered() async throws {
        let rack = InstrumentRack()
        let dls = PluginRef(description: AudioComponentDescription(
            componentType: kAudioUnitType_MusicDevice, componentSubType: kAudioUnitSubType_DLSSynth,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0),
            name: "DLSMusicDevice")
        let a = try #require(rack.addChannel(name: "A")); rack.setMuted(a, true)
        rack.setInstrument(dls, for: a)
        await wait(upTo: 60) { rack.instrumentStatus[a] != .loading }
        try #require(rack.instrumentStatus[a] == .ready, "DLS-Synthesizer nicht ladbar")
        guard rack._engineIsRunning else {
            Issue.record("Audio-Engine läuft nicht: \(rack.engineError ?? "kein Ausgabegerät?")")
            return
        }
        let b = try #require(rack.addChannel(name: "B")); rack.setMuted(b, true)
        rack.setInstrument(dls, for: b)
        await wait(upTo: 60) { rack.instrumentStatus[b] != .loading }
        let unit = try #require(rack._liveInstrument(b))
        #expect(rack._engineIsRunning)
        #expect(unit.auAudioUnit.renderResourcesAllocated, "zweiter Kanal hat keine Render-Ressourcen")
        #expect(rack._liveInstrument(a)?.auAudioUnit.renderResourcesAllocated == true)
    }

    /// Durchstich mit einem echten AU: laden, Note über Warteschlange und Render-Observer
    /// einplanen, am Instrumentenausgang messen, WANN der Klang einsetzt, Stop beendet den
    /// Klang, der Klangzustand lässt sich sichern. Der Kanal ist stummgeschaltet — gemessen
    /// wird vor dem Kanal-Mixer, zu hören ist nichts.
    ///
    /// Die Zeitprüfung ist eine Messung, kein Schlafen-und-Hoffen: sie bleibt auch gültig,
    /// wenn der Test unter Last langsam läuft.
    @MainActor @Test func appleDLSSynthPlaysScheduledNoteAtItsHostTime() async throws {
        let rack = InstrumentRack()
        let id = try #require(rack.addChannel(name: "DLS"))
        rack.setMuted(id, true)
        let dls = PluginRef(description: AudioComponentDescription(
            componentType: kAudioUnitType_MusicDevice, componentSubType: kAudioUnitSubType_DLSSynth,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0),
            name: "DLSMusicDevice")
        rack.setInstrument(dls, for: id)
        await wait(upTo: 60) { rack.instrumentStatus[id] != .loading }
        try #require(rack.instrumentStatus[id] == .ready, "DLS-Synthesizer nicht ladbar")
        guard rack._engineIsRunning else {
            Issue.record("Audio-Engine läuft nicht: \(rack.engineError ?? "kein Ausgabegerät?")")
            return
        }
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        let ticksPerMs = 1_000_000.0 * Double(tb.denom) / Double(tb.numer)
        let unit = try #require(rack._liveInstrument(id))
        let meter = Meter()
        meter.hostTicksPerSecond = ticksPerMs * 1000
        unit.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, when in meter.feed(buffer, when) }

        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(meter.takePeak() < 0.0005, "vor der Note ist das Instrument still")
        #expect(meter.onsetHostTime == 0)

        // Note 250 ms in der Zukunft einplanen — wie der Tick-Pfad es tut.
        let route = rack.route(for: id)
        let scheduled = mach_absolute_time() + UInt64(250 * ticksPerMs)
        rack.queue(route).pushFromTick(0x90, 60, 110, at: scheduled)
        await wait(upTo: 20) { meter.onsetHostTime != 0 }
        let onset = meter.onsetHostTime
        try #require(onset != 0, "eingeplante Note erzeugt kein Audio am Instrument")
        let deltaMs = (Double(onset) - Double(scheduled)) / ticksPerMs
        // Früher als geplant darf sie nie klingen (2 ms Messtoleranz); die obere Schranke
        // deckt Einschwingen des Klangs und die Latenz des ausgelagerten Plug-in-Prozesses.
        #expect(deltaMs > -2, "Note klingt \(deltaMs) ms VOR ihrem Zeitpunkt")
        #expect(deltaMs < 60, "Note klingt \(deltaMs) ms nach ihrem Zeitpunkt")

        // Stop-Pfad: alles verwerfen, klingende Note beenden — danach wird es still.
        rack.silenceAll()
        rack.sendFromMain(route: route, 0x80, 60, 0)
        var quiet = false
        for _ in 0..<40 where !quiet {
            _ = meter.takePeak()
            try await Task.sleep(nanoseconds: 400_000_000)
            quiet = meter.takePeak() < 0.005
        }
        #expect(quiet, "nach dem Stop klingt die Note aus")

        rack.captureStates()
        #expect(rack.channels.first?.instrument?.state?.isEmpty == false, "Klangzustand gesichert")

        // Tap abbauen, solange der Knoten noch an der Engine hängt (danach wirft AVFAudio).
        unit.removeTap(onBus: 0)
        rack.setInstrument(nil, for: id)
        #expect(rack.instrumentStatus[id] == .empty)
        #expect(!rack._engineIsRunning, "ohne Instrument läuft kein Audiogerät")
    }
}

// MARK: - Mixer (v1.13.1)

@Suite(.serialized) struct MixerTests {

    private static func bogusEffect(_ n: UInt32, name: String) -> PluginRef {
        PluginRef(description: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: 0x7A7A7A40 + n,
            componentManufacturer: 0x7A7A7A32, componentFlags: 0, componentFlagsMask: 0),
            name: name, state: Data([UInt8(n)]))
    }

    /// Solo: sobald ein Kanal auf Solo steht, sind nur Solo-Kanäle hörbar; Mute gewinnt.
    @MainActor @Test func soloSilencesOthersAndMuteWins() throws {
        let rack = InstrumentRack()
        let a = try #require(rack.addChannel(name: "A"))
        let b = try #require(rack.addChannel(name: "B"))
        rack.setVolume(a, 0.5); rack.setVolume(b, 0.7)
        func level(_ id: UUID) -> Float { rack._liveOutputVolume(id) ?? -1 }
        func near(_ x: Float, _ y: Float) -> Bool { abs(x - y) < 0.001 }
        #expect(near(level(a), 0.5) && near(level(b), 0.7))

        rack.setSoloed(a, true)
        #expect(near(level(a), 0.5))
        #expect(level(b) == 0, "nicht auf Solo → stumm")

        rack.setMuted(a, true)
        #expect(level(a) == 0, "Mute gewinnt gegen Solo")

        rack.setMuted(a, false); rack.setSoloed(a, false)
        #expect(near(level(a), 0.5) && near(level(b), 0.7))

        // Löschen des Solo-Kanals gibt die übrigen wieder frei.
        rack.setSoloed(a, true)
        rack.removeChannel(a)
        #expect(near(level(b), 0.7))

        // Fader über 0 dB: bis +6 dB, darüber begrenzt; ganz unten stumm.
        rack.setVolume(b, 1.5)
        #expect(near(level(b), 1.5))
        rack.setVolume(b, 9)
        #expect(near(level(b), InstrumentRack.maxGain))
        rack.setVolume(b, 0)
        #expect(level(b) == 0)
    }

    /// Platzbelegung wie im Kanalzug: Wahl ersetzt den Effekt an dieser Stelle, „Leer"
    /// entfernt ihn, ein hinterer leerer Platz hängt hinten an.
    @MainActor @Test func assigningASlotReplacesInPlace() throws {
        let rack = InstrumentRack()
        let id = try #require(rack.addChannel(name: "A"))
        func names() -> [String] { rack.channel(id)?.effects.map(\.name) ?? [] }
        rack.assignEffect(Self.bogusEffect(1, name: "Eins"), at: 0, in: id)
        rack.assignEffect(Self.bogusEffect(2, name: "Zwei"), at: 3, in: id)     // leerer Platz 4 → ans Ende
        #expect(names() == ["Eins", "Zwei"])
        rack.assignEffect(Self.bogusEffect(3, name: "Drei"), at: 0, in: id)     // ersetzt an Ort und Stelle
        #expect(names() == ["Drei", "Zwei"])
        rack.assignEffect(nil, at: 0, in: id)
        #expect(names() == ["Zwei"])
        #expect(rack.effectStatus[id]?.count == 1)
        rack.assignEffect(nil, at: 3, in: id)                                   // leerer Platz: nichts
        #expect(names() == ["Zwei"])
    }

    /// Instrument aus/ein lebt im Projekt (Ein/Aus-Feld des Instrument-Platzes).
    @MainActor @Test func instrumentPowerIsStoredOnTheChannel() throws {
        var channel = InstrumentChannelData(name: "A")
        channel.instrument = PluginRef(description: AudioComponentDescription(
            componentType: kAudioUnitType_MusicDevice, componentSubType: 0x7A7A7A31,
            componentManufacturer: 0x7A7A7A32, componentFlags: 0, componentFlagsMask: 0), name: "Fehlt")
        let rack = InstrumentRack()
        rack.replaceAll([channel])
        rack.setInstrumentEnabled(false, for: channel.id)
        #expect(rack.channel(channel.id)?.instrument?.bypassed == true)
        rack.setInstrumentEnabled(true, for: channel.id)
        #expect(rack.channel(channel.id)?.instrument?.bypassed == false)
    }

    /// Editor-Fenster von Apple-Effekten: mit eigener Oberfläche (AUDelay) und ohne
    /// (AUMatrixReverb liefert out-of-process einen 1 × 1 pt großen Editor → Parameteransicht).
    @MainActor @Test func appleEffectEditorsOpenWithUsableSize() async throws {
        let rack = InstrumentRack()
        let id = try #require(rack.addChannel(name: "A"))
        func apple(_ code: String, _ name: String) -> PluginRef {
            PluginRef(description: AudioComponentDescription(
                componentType: kAudioUnitType_Effect,
                componentSubType: code.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) },
                componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0), name: name)
        }
        rack.addEffect(apple("dely", "AUDelay"), to: id)
        rack.addEffect(apple("mrev", "AUMatrixReverb"), to: id)
        for _ in 0..<100 where rack.effectStatus[id]?.allSatisfy({ $0 == .ready }) != true {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try #require(rack.effectStatus[id] == [.ready, .ready])
        for i in 0..<2 {
            rack.openEffectEditor(id, index: i)
            for _ in 0..<50 where rack._editorWindow(id, effect: i) == nil {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let window = try #require(rack._editorWindow(id, effect: i))
            let size = window.contentLayoutRect.size
            #expect(size.width >= 200 && size.height >= 80, "Editor \(i) zu klein: \(size)")
            window.close()
        }
        rack.removeChannel(id)
    }

    /// Effekte: Reihenfolge und Bypass leben im Modell, auch wenn das Plug-in fehlt.
    @MainActor @Test func effectOrderAndBypassLiveInTheModel() throws {
        let rack = InstrumentRack()
        let id = try #require(rack.addChannel(name: "A"))
        let one = Self.bogusEffect(1, name: "Eins"), two = Self.bogusEffect(2, name: "Zwei")
        let three = Self.bogusEffect(3, name: "Drei")
        rack.addEffect(one, to: id); rack.addEffect(two, to: id); rack.addEffect(three, to: id)

        rack.moveEffect(from: 2, to: 0, in: id)
        #expect(rack.channel(id)?.effects.map(\.name) == ["Drei", "Eins", "Zwei"])
        rack.moveEffect(from: 0, to: 5, in: id)          // außerhalb: keine Wirkung
        #expect(rack.channel(id)?.effects.map(\.name) == ["Drei", "Eins", "Zwei"])

        rack.setEffectBypassed(true, at: 1, in: id)
        #expect(rack.channel(id)?.effects.map(\.bypassed) == [false, true, false])
        rack.moveEffect(from: 1, to: 2, in: id)
        #expect(rack.channel(id)?.effects.map(\.bypassed) == [false, false, true], "Bypass wandert mit")
        #expect(rack.effectStatus[id]?.count == 3)
    }

    /// Duplizieren: gleiche Einstellungen, eigene Identität, kein Solo; Grenze 16 Kanäle.
    @MainActor @Test func duplicateCopiesSettingsWithFreshIdentity() throws {
        let rack = InstrumentRack()
        let id = try #require(rack.addChannel(name: "A"))
        rack.setVolume(id, 0.3); rack.setPan(id, 0.25); rack.setSoloed(id, true)
        rack.addEffect(Self.bogusEffect(1, name: "Eins"), to: id)

        let copyID = try #require(rack.duplicateChannel(id, name: "A 2"))
        let copy = try #require(rack.channel(copyID))
        #expect(copyID != id && copy.name == "A 2")
        #expect(copy.volume == 0.3 && copy.pan == 0.25 && copy.effects.map(\.name) == ["Eins"])
        #expect(!copy.isSoloed)
        #expect(rack.route(for: copyID) >= 0 && rack.route(for: copyID) != rack.route(for: id))

        while rack.canAddChannel { rack.addChannel(name: "x") }
        #expect(rack.channels.count == InstrumentRack.maxChannels)
        #expect(rack.duplicateChannel(id, name: "zu viel") == nil)
    }

    /// Summenpegel, Solo und Bypass überleben Speichern → Laden.
    @MainActor @Test func masterVolumeSoloAndBypassRoundTrip() throws {
        var channel = InstrumentChannelData(name: "Bass")
        channel.isSoloed = true
        var fx = Self.bogusEffect(1, name: "Eins"); fx.bypassed = true
        channel.effects = [fx]

        let first = SequencerEngine()
        first.rack.replaceAll([channel], masterVolume: 0.6)
        let saved = try #require(first.saveData())

        let second = SequencerEngine()
        #expect(second.loadData(saved))
        #expect(second.rack.masterVolume == 0.6)
        let restored = try #require(second.rack.channels.first)
        #expect(restored.isSoloed && restored.effects.first?.bypassed == true)

        second.rack.setMasterVolume(7)
        #expect(second.rack.masterVolume == InstrumentRack.maxGain, "begrenzt auf +6 dB")
    }

    /// Projekte aus v1.13.0 (ohne masterVolume, isSoloed, bypassed) laden mit Vorgaben.
    @MainActor @Test func v1_13_0FileWithoutNewKeysLoadsWithDefaults() throws {
        var channel = InstrumentChannelData(name: "Alt")
        channel.effects = [Self.bogusEffect(1, name: "Eins")]
        let source = SequencerEngine()
        source.rack.replaceAll([channel], masterVolume: 0.5)
        let saved = try #require(source.saveData())

        var obj = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
        obj["masterVolume"] = nil
        var chans = try #require(obj["instruments"] as? [[String: Any]])
        chans[0]["isSoloed"] = nil
        var effects = try #require(chans[0]["effects"] as? [[String: Any]])
        effects[0]["bypassed"] = nil
        chans[0]["effects"] = effects
        obj["instruments"] = chans
        let old = try JSONSerialization.data(withJSONObject: obj)

        let engine = SequencerEngine()
        #expect(engine.loadData(old))
        #expect(engine.rack.masterVolume == 1)
        let restored = try #require(engine.rack.channels.first)
        #expect(!restored.isSoloed && restored.effects.first?.bypassed == false)
    }

    /// Ausgangswahl aus Spurkopf/Kontextmenü: rücknehmbar, hebt den Kanal im Mixer hervor.
    @MainActor @Test func setOutputIsUndoableAndHighlightsChannel() throws {
        let engine = SequencerEngine()
        let id = try #require(engine.rack.addChannel(name: "A"))
        let undo = UndoManager()
        engine.undoManager = undo
        let td = engine.currentPattern.tracks[0]
        engine.setOutput(of: td, to: id)
        #expect(td.instrumentID == id && engine.rack.highlightedChannel == id)
        undo.undo()
        #expect(td.instrumentID == nil)
    }

    /// „Neuer Instrumentenkanal" aus der Ausgangswahl: Kanal entsteht und ist Ausgang der Spur;
    /// Undo löst nur die Zuweisung.
    @MainActor @Test func setOutputToNewChannelCreatesAndRoutes() throws {
        let engine = SequencerEngine()
        let undo = UndoManager()
        engine.undoManager = undo
        let td = engine.currentPattern.tracks[0]
        let id = try #require(engine.setOutputToNewChannel(of: td, name: "Inst 1"))
        #expect(engine.rack.channels.map(\.id) == [id])
        #expect(td.instrumentID == id && engine.rack.highlightedChannel == id)
        #expect(engine.rack.directory.entries.map(\.id) == [id])
        undo.undo()
        #expect(td.instrumentID == nil && engine.rack.channels.count == 1)
    }

    /// Fader-Kennlinie wie Planarium: 0 dB bei 0,75, oben +6 dB, unten stumm; umkehrbar.
    @Test func faderLawMatchesThePrintedScale() {
        for mark in FaderLaw.scaleMarks {
            #expect(abs(FaderLaw.decibels(forPosition: mark.position) - mark.dB) < 1e-9)
        }
        for p in stride(from: 0.05, through: 1.0, by: 0.05) {
            #expect(abs(FaderLaw.position(forGain: FaderLaw.gain(forPosition: p)) - p) < 1e-9)
        }
        #expect(FaderLaw.gain(forPosition: 0) == 0)
        #expect(abs(FaderLaw.gain(forPosition: FaderLaw.unityPosition) - 1) < 1e-12)
        #expect(abs(FaderLaw.gain(forPosition: 1) - Double(InstrumentRack.maxGain)) < 1e-5)
        #expect(FaderLaw.decibelLabel(forPosition: 0.75) == "0.0")
        #expect(FaderLaw.decibelLabel(forPosition: 1) == "+6.0")
        #expect(FaderLaw.decibelLabel(forPosition: 0) == "−∞")
        #expect(FaderLaw.decibelLabel(forPosition: 0.56) == "−6.0")
        #expect(FaderLaw.scaleMarks.map(\.label) == ["−∞", "-40", "-30", "-20", "-15", "-10", "-6", "-3", "0", "+3", "+6"])
    }

    /// Ziehen relativ zum Greifpunkt; Pan-Anzeige und -Zugweg.
    @Test func dragAndPanMath() {
        #expect(FaderMath.dragged(startValue: 0.5, translationY: -50, travel: 100) == 1.0)
        #expect(FaderMath.dragged(startValue: 0.5, translationY: 25, travel: 100) == 0.25)
        #expect(FaderMath.dragged(startValue: 0.5, translationY: 500, travel: 100) == 0)
        #expect(PanDisplay.label(0) == "C" && PanDisplay.label(-0.37) == "L37" && PanDisplay.label(1) == "R100")
        #expect(PanDisplay.dragged(startPan: 0, translationY: -60) == 1)
        #expect(PanDisplay.dragged(startPan: 0, translationY: 30) == -0.5)
    }

    /// Pegelanzeige: Abfall 20 dB/s, Übersteuerung hält 2 s.
    @Test func meterBallistics() {
        let b = MixerStereoMeter.Ballistics()
        let t0 = Date(timeIntervalSince1970: 1000)
        b.step((left: 1.2, right: 0.5), now: t0)
        #expect(b.clipRemaining == MeterLaw.clipHoldSeconds && b.left == 1.2)
        b.step((left: 0, right: 0), now: t0.addingTimeInterval(0.5))
        #expect(abs(20 * log10(Double(b.right) / 0.5) + 10) < 0.01, "0,5 s → −10 dB")
        #expect(abs(b.clipRemaining - 1.5) < 1e-9)
        for i in 1...4 { b.step((left: 0, right: 0), now: t0.addingTimeInterval(0.5 + Double(i) * 0.4)) }
        #expect(b.clipRemaining == 0)
        #expect(MixerStereoMeter.Ballistics.level(1) == 1 && MixerStereoMeter.Ballistics.level(2) == 1)
        #expect(MixerStereoMeter.Ballistics.level(0.0005) == 0)
    }
}
