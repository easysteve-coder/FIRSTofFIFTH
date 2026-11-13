import Testing
import Foundation
import CoreMIDI
@testable import VintageSequencer

// v1.12.19 — Engine-Kern: Topologie im Snapshot, Patternwechsel im Tick-Thread,
// Notenbuch für Stop-Offs, exklusiver Tick-Zutritt, EXT-Lebenszyklus.
// Beobachtet wird am tatsächlichen Sendekern (`MIDIManager._testSendObserver`).

private struct Sent: Equatable {
    let status: UInt8, d1: UInt8, d2: UInt8
    let ts: MIDITimeStamp
    var isNoteOn:  Bool { status & 0xF0 == 0x90 }
    var isNoteOff: Bool { status & 0xF0 == 0x80 }
}

private final class SendLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Sent] = []
    func add(_ s: Sent) { lock.lock(); items.append(s); lock.unlock() }
    var all: [Sent] { lock.lock(); defer { lock.unlock() }; return items }
    var noteOns: [Sent] { all.filter(\.isNoteOn) }
    func clear() { lock.lock(); items.removeAll(); lock.unlock() }
}

private func attachLog(_ engine: SequencerEngine) -> SendLog {
    let log = SendLog()
    engine.midi._testSendObserver = { b0, b1, b2, _, ts in
        log.add(Sent(status: b0, d1: b1, d2: b2, ts: ts))
    }
    return log
}

/// Aktiviert Step `step` von Track `track` in Pattern `pattern` mit Note `note`.
private func arm(_ engine: SequencerEngine, pattern: Int, track: Int = 0, step: Int = 0, note: Int) {
    let lane = engine.patterns[pattern].tracks[track].lane
    lane.steps[step].isActive = true
    lane.steps[step].notes = [note]
    lane.steps[step].probability = 1.0
}

private func future() -> UInt64 { mach_absolute_time() + 5_000_000_000 }
private let tickGap: UInt64 = 20_000_000

@Suite(.serialized) struct EngineCoreTimingTests {

    /// Der erste Tick nach dem Start löst Step 1 aus und trägt MIDI-Start + Clock —
    /// die Noten liegen auf demselben Puls wie Beat 1 des Empfängers (früher: eine volle
    /// Step-Länge später).
    @Test func firstTickPlaysStepOneTogetherWithStartAndClock() {
        let engine = SequencerEngine()
        arm(engine, pattern: 0, note: 60)
        let log = attachLog(engine)
        engine._rt1SetupRuntimesForTest()
        engine._s01ArmMidiStart()
        let t0 = future()
        engine._rt2DriveOneTick(at: t0)

        #expect(log.noteOns.map(\.d1) == [60])
        #expect(log.noteOns.first?.ts == t0, "Step 1 liegt exakt auf dem ersten Tick")
        #expect(log.all.contains { $0.status == 0xFA }, "MIDI Start")
        #expect(log.all.contains { $0.status == 0xF8 && $0.ts == t0 }, "erster Clock-Puls")
    }

    /// Quantisierter Patternwechsel: an der Track-1-Grenze spielt Step 1 des NEUEN
    /// Patterns — auf demselben Tick, ohne dass Main dazwischen etwas tun muss, und ohne
    /// dass Step 1 des alten Patterns noch einmal erklingt.
    @Test func queuedPatternStartsExactlyOnBoundaryWithoutMainHop() {
        let engine = SequencerEngine()
        engine.patterns[0].tracks[0].lane.stepCount = 2
        arm(engine, pattern: 0, note: 60)
        arm(engine, pattern: 1, note: 72)
        let pps = 6   // Default-Raster: 6 Pulse je Step
        let log = attachLog(engine)
        engine._rt1SetupRuntimesForTest()
        engine.isPlaying = true
        defer { engine.isPlaying = false }

        let base = future()
        engine._rt2DriveOneTick(at: base)                       // Tick 0: A Step 1 (60)
        engine.switchPattern(1)                                 // vormerken
        #expect(engine.queuedPatternIndex == 1)
        for i in 1...(2 * pps) {                                // bis einschließlich Grenze
            engine._rt2DriveOneTick(at: base + UInt64(i) * tickGap)
        }
        let boundary = base + UInt64(2 * pps) * tickGap

        #expect(log.noteOns.map(\.d1) == [60, 72], "alte Step 1 darf an der Grenze nicht erneut spielen")
        #expect(log.noteOns.last?.ts == boundary, "neues Pattern beginnt exakt auf der Grenze")
        #expect(engine.currentPatternIndex == 0, "Main hat noch nicht nachgezogen — der Wechsel ist trotzdem hörbar vollzogen")

        // Main zieht nach (Drain oder nächster Publish): Index, Vormerkung, Aktivierung.
        let serialBefore = engine._patternSerial
        engine.publishSnapshot()
        #expect(engine.currentPatternIndex == 1)
        #expect(engine.queuedPatternIndex == nil)
        #expect(engine._patternSerial == serialBefore + 1)

        // Das Nachziehen startet das Pattern NICHT neu: nach einer weiteren Step-Länge steht Step 2.
        for i in 1...pps { engine._rt2DriveOneTick(at: boundary + UInt64(i) * tickGap) }
        #expect(engine._rt1CurrentStep(track: 0) == 1)
        #expect(log.noteOns.map(\.d1) == [60, 72], "kein Neustart, keine doppelte erste Note")
    }

    /// Das aktuelle Pattern erneut wählen hebt die Vormerkung auf.
    @Test func selectingCurrentPatternCancelsQueue() {
        let engine = SequencerEngine()
        engine._rt1SetupRuntimesForTest()
        engine.isPlaying = true
        defer { engine.isPlaying = false }
        engine.switchPattern(2)
        engine.switchPattern(0)
        #expect(engine.queuedPatternIndex == nil)
        #expect(engine._rt1PublishedBundle()?.queued == nil)
    }
}

@Suite(.serialized) struct EngineCoreStopTests {

    /// stop() sendet für jede Note mit noch ausstehendem Off ein sofortiges Note-Off —
    /// aus der Sendebuchhaltung, unabhängig von UI-Zustand und MIDIFlushOutput.
    @Test func stopSendsImmediateOffForNotesWithPendingOff() {
        let engine = SequencerEngine()
        arm(engine, pattern: 0, track: 0, note: 60)
        arm(engine, pattern: 0, track: 1, note: 67)
        engine.patterns[0].tracks[1].midiChannel = 5
        let log = attachLog(engine)
        engine.setClockMode(.external)
        engine.play()                                    // EXT: kein eigener Clock-Thread
        engine._rt3aDriveOneExternalTick(at: future())   // Ons gesendet, Offs stehen im Buch aus
        #expect(engine._noteBookEntry(channel: 5, note: 67) != 0)
        log.clear()

        engine.stop()

        let offs = log.all.filter(\.isNoteOff)
        #expect(offs.contains { $0.status == 0x80 && $0.d1 == 60 }, "Kanal 1, Note 60")
        #expect(offs.contains { $0.status == 0x84 && $0.d1 == 67 }, "Kanal 5, Note 67 — ursprünglicher Kanal")
        #expect(engine._noteBookEntry(channel: 5, note: 67) == 0, "Buch nach Stop leer")
    }

    /// Nach stop() kann kein Tick mehr eintreten — auch kein bereits unterwegs befindlicher.
    @Test func tickAfterStopIsRefused() {
        let engine = SequencerEngine()
        arm(engine, pattern: 0, note: 60)
        let log = attachLog(engine)
        engine.setClockMode(.external)
        engine.play()
        engine.stop()
        log.clear()
        engine._rt3aDriveOneExternalTick(at: future())
        #expect(log.all.isEmpty)
        #expect(!engine._rt3aActiveTick)
    }

    /// Höchstens ein Thread im Tick-Pfad: ein zweiter Tick während eines laufenden wird
    /// abgewiesen (und gezählt), statt denselben Zustand nebenläufig zu verändern.
    @Test func overlappingTickIsRejected() {
        let engine = SequencerEngine()
        engine.setClockMode(.external)
        engine.play()
        defer { engine.stop() }

        let inside = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        engine._rt3aPausePoint = { inside.signal(); resume.wait() }
        Thread.detachNewThread {
            engine._rt3aDriveOneExternalTick(at: future())
            done.signal()
        }
        inside.wait()                                         // Tick 1 parkt im Tick-Pfad
        let before = engine._rejectedTicks
        engine._rt3aDriveOneExternalTick(at: future())        // Tick 2 von einem anderen Thread
        #expect(engine._rejectedTicks == before + 1)
        resume.signal()
        done.wait()
    }
}

@Suite(.serialized) struct EngineCoreExternalLifecycleTests {

    /// Wiederholtes Start/Continue/Stop vom externen Master: der Display-Lebenszyklus
    /// bleibt ausgeglichen (früher fehlte das resume beim EXT-Start; das folgende stop()
    /// suspendierte doppelt und die Engine stürzte beim Freigeben ab bzw. die Anzeige blieb tot).
    @Test func repeatedExternalStartContinueStopKeepsLifecycleBalanced() {
        var engine: SequencerEngine? = SequencerEngine()
        engine!.setClockMode(.external)
        for _ in 0..<20 {
            engine!.midi.onStart?()
            #expect(engine!.isPlaying)
            engine!.midi.onStart?()        // Start bei laufender Wiedergabe: von vorn, kein zweiter Lebenszyklus
            engine!.midi.onContinue?()     // Continue bei laufender Wiedergabe: ohne Wirkung
            engine!.stop()
            #expect(!engine!.isPlaying)
        }
        engine!.play(); engine!.stop()     // danach funktioniert der normale Pfad
        engine = nil                       // deinit darf nicht an einer suspendierten Quelle scheitern
    }

    /// Start bei laufender Wiedergabe beginnt von vorn.
    @Test func externalStartWhilePlayingRestartsFromStepOne() {
        let engine = SequencerEngine()
        engine.setClockMode(.external)
        engine.midi.onStart?()
        defer { engine.stop() }
        for i in 0..<13 { engine._rt3aDriveOneExternalTick(at: future() + UInt64(i) * tickGap) }
        #expect(engine._rt1CurrentStep(track: 0) == 2)
        engine.midi.onStart?()
        #expect(engine._rt1CurrentStep(track: 0) == -1, "neue Sitzung → frische Runtimes")
        engine._rt3aDriveOneExternalTick(at: future())
        #expect(engine._rt1CurrentStep(track: 0) == 0)
    }

    /// Die BPM-Schätzung der externen Clock markiert das Projekt nicht als geändert.
    @Test func externalClockEstimateDoesNotMarkProjectDirty() async {
        let engine = SequencerEngine()
        engine.setClockMode(.external)
        engine.hasUnsavedChanges = false
        for _ in 0..<60 {                                   // > 2 Beats à 24 Pulse
            engine.midi.onClockPulse?()
            try? await Task.sleep(nanoseconds: 4_000_000)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)     // main.async der Schätzung abwarten
        #expect(!engine.hasUnsavedChanges)
    }
}

@Suite(.serialized) struct EngineCoreNoteOffTests {

    /// Ein 24-PPQ-Tick bei 120 BPM in mach-Einheiten (Engine-Standardtempo).
    private var tick: UInt64 {
        var mb = mach_timebase_info_data_t(); mach_timebase_info(&mb)
        return UInt64((60_000_000_000.0 / (120.0 * 24.0)) * Double(mb.denom) / Double(mb.numer))
    }
    private func near(_ a: UInt64, _ b: UInt64) -> Bool { (a > b ? a - b : b - a) <= 8 }

    private func extEngine() -> (SequencerEngine, SendLog) {
        let engine = SequencerEngine()
        let log = attachLog(engine)
        engine.setClockMode(.external)
        return (engine, log)
    }

    /// Ein Note-Off geht nicht mehr zusammen mit dem On hinaus, sondern mit dem Tick, in
    /// dessen Fenster es fällt — mit seinem eigenen Zeitpunkt.
    @Test func offIsSentByTheTickThatReachesItsTime() {
        let (engine, log) = extEngine()
        arm(engine, pattern: 0, note: 60)                       // Gate 0,5 → Off nach 3 Ticks
        engine.patterns[0].tracks[0].lane.steps[0].gate = 0.5
        engine.play()
        let t0 = future()
        for k in 0..<3 { engine._rt3aDriveOneExternalTick(at: t0 + UInt64(k) * tick) }
        #expect(log.noteOns.count == 1)
        #expect(log.all.filter(\.isNoteOff).isEmpty, "Off vor seinem Tick gesendet")
        #expect(engine._noteBookPendingOff(channel: 1, note: 60) != 0)

        engine._rt3aDriveOneExternalTick(at: t0 + 3 * tick)
        let offs = log.all.filter(\.isNoteOff)
        #expect(offs.count == 1)
        #expect(offs.first.map { near($0.ts, t0 + 3 * tick) } == true, "Off trägt seinen eigenen Zeitpunkt")
        #expect(engine._noteBookPendingOff(channel: 1, note: 60) == 0)
        engine.stop()
    }

    /// Gleiche Note auf zwei Steps in Folge mit Gate 150 %: Das Ende der ersten Note
    /// (nach 9 Ticks) darf die zweite (Beginn nach 6 Ticks) nicht abschneiden. Erwartet:
    /// Neuanschlag auf dem zweiten On, ein einziges weiteres Off am Ende der zweiten Note.
    @Test func overlappingSameNoteIsRetriggeredAndNotCutShort() {
        let (engine, log) = extEngine()
        arm(engine, pattern: 0, step: 0, note: 60)
        arm(engine, pattern: 0, step: 1, note: 60)
        engine.patterns[0].tracks[0].lane.steps[0].gate = 1.5
        engine.patterns[0].tracks[0].lane.steps[1].gate = 1.5
        engine.play()
        let t0 = future()
        for k in 0...16 { engine._rt3aDriveOneExternalTick(at: t0 + UInt64(k) * tick) }

        let ons  = log.noteOns.filter { $0.d1 == 60 }.map(\.ts)
        let offs = log.all.filter { $0.isNoteOff && $0.d1 == 60 }.map(\.ts)
        #expect(ons.count == 2 && offs.count == 2, "ons=\(ons.count) offs=\(offs.count)")
        guard ons.count == 2, offs.count == 2 else { engine.stop(); return }
        #expect(near(ons[1], t0 + 6 * tick))
        #expect(near(offs[0], ons[1]), "erstes Off liegt genau auf dem zweiten On (Neuanschlag)")
        #expect(near(offs[1], t0 + 15 * tick), "zweite Note klingt ihre volle Länge")
        // Reihenfolge im Sendestrom: Off vor dem On desselben Zeitpunkts.
        let stream = log.all.filter { $0.d1 == 60 && ($0.isNoteOn || $0.isNoteOff) }
        #expect(stream.map(\.isNoteOn) == [true, false, true, false])
        engine.stop()
    }

    /// Zwei Spuren auf demselben Kanal: die kurze Note der zweiten Spur beendet die lange
    /// der ersten nicht vorzeitig — die Tonhöhe klingt bis zum späteren Ende.
    @Test func shortNoteOnSecondTrackDoesNotEndLongNoteOfFirst() {
        let (engine, log) = extEngine()
        arm(engine, pattern: 0, track: 0, step: 0, note: 60)
        arm(engine, pattern: 0, track: 1, step: 1, note: 60)
        engine.patterns[0].tracks[0].lane.steps[0].gate = 3.0     // 18 Ticks
        engine.patterns[0].tracks[1].lane.steps[1].gate = 0.5     // Ticks 6…9
        engine.patterns[0].tracks[1].midiChannel = engine.patterns[0].tracks[0].midiChannel
        engine.play()
        let t0 = future()
        for k in 0...19 { engine._rt3aDriveOneExternalTick(at: t0 + UInt64(k) * tick) }
        let offs = log.all.filter { $0.isNoteOff && $0.d1 == 60 }.map(\.ts)
        #expect(offs.count == 2)
        #expect(offs.last.map { near($0, t0 + 18 * tick) } == true, "Ende = späteres der beiden Enden")
        engine.stop()
    }

    /// Bleibt die externe Clock ohne Stop aus, sendet der Off-Wächter überfällige Offs.
    @Test func watchdogSendsOverdueOffsWhenExternalClockStalls() async {
        let (engine, log) = extEngine()
        arm(engine, pattern: 0, note: 60)
        engine.play()
        engine._rt3aDriveOneExternalTick(at: mach_absolute_time() + tick)
        #expect(engine._noteBookPendingOff(channel: 1, note: 60) != 0)
        engine._runOffWatchdogForTest()
        #expect(log.all.filter(\.isNoteOff).isEmpty, "Off noch nicht fällig")

        try? await Task.sleep(nanoseconds: 250_000_000)   // Gate (62 ms) ist abgelaufen, kein Tick kam
        engine._runOffWatchdogForTest()
        #expect(log.all.filter(\.isNoteOff).count == 1)
        #expect(engine._noteBookPendingOff(channel: 1, note: 60) == 0)
        #expect(engine.isPlaying, "Wächter beendet die Wiedergabe nicht")
        engine.stop()
    }

    /// Stop, während das On noch in der Zukunft liegt: das Off wird hinter das On datiert
    /// (die virtuelle Quelle liefert das On noch aus, Befund B5).
    @Test func stopDatesOffBehindAStillPendingOn() {
        let (engine, log) = extEngine()
        arm(engine, pattern: 0, note: 60)
        engine.play()
        engine._rt3aDriveOneExternalTick(at: future())
        let on = log.noteOns.first?.ts ?? 0
        log.clear()
        engine.stop()
        let off = log.all.first { $0.isNoteOff && $0.d1 == 60 }
        #expect(off != nil)
        #expect((off?.ts ?? 0) > on, "Off muss nach dem geplanten On liegen")
    }

    /// Neue Spuren sind auf die Hälfte der Runtime-Slots begrenzt (aktuelles + vorgemerktes
    /// Pattern müssen gleichzeitig Platz haben) — darüber wird nichts mehr angelegt.
    @Test func trackCountIsCappedSoEveryTrackGetsARuntimeSlot() {
        let engine = SequencerEngine()
        var guardCount = 0
        while !engine.addTrack().isEmpty, guardCount < 400 { guardCount += 1 }
        #expect(engine.currentPattern.tracks.count == SequencerEngine.maxTracksPerPattern)
        #expect(engine.duplicateTrack(at: 0).isEmpty)
        #expect(engine.insertTrack(after: 0).isEmpty)
    }
}

@Suite(.serialized) struct EngineCoreRealClockTests {

    /// Echte interne Clock (Echtzeit-Thread) über zwei Start/Stop-Zyklen: jede Sitzung
    /// liefert genau ein MIDI-Start, gleichmäßige Clock-Pulse (additives Raster) und
    /// Step 1 auf dem ersten Puls. Deckt die lock-freie Start-Erkennung der Clock-Quelle ab.
    @Test func internalClockRestartsCleanlyAndTicksUniformly() async {
        let engine = SequencerEngine()
        arm(engine, pattern: 0, note: 60)
        let log = attachLog(engine)
        var mb = mach_timebase_info_data_t(); mach_timebase_info(&mb)
        let tickMach = (60_000_000_000.0 / (120.0 * 24.0)) * Double(mb.denom) / Double(mb.numer)

        for cycle in 0..<2 {
            log.clear()
            engine.play()
            try? await Task.sleep(nanoseconds: 900_000_000)
            engine.stop()
            let sent = log.all
            let clocks = sent.filter { $0.status == 0xF8 }.map(\.ts)
            #expect(sent.filter { $0.status == 0xFA }.count == 1, "Zyklus \(cycle): genau ein MIDI-Start")
            #expect(clocks.count >= 12, "Zyklus \(cycle): nur \(clocks.count) Clock-Pulse")
            let deltas = zip(clocks.dropFirst(), clocks).map { Double($0 - $1) }
            // Verworfene (geclampte) Pulse ergeben ganzzahlige Vielfache; kein Puls darf
            // vom additiven Raster abweichen.
            #expect(deltas.allSatisfy { d in
                let k = (d / tickMach).rounded()
                return k >= 1 && abs(d - k * tickMach) <= 2
            }, "Zyklus \(cycle): Clock-Raster ungleichmäßig")
            if let firstClock = clocks.first, let firstOn = sent.first(where: \.isNoteOn) {
                #expect(firstOn.ts == firstClock, "Zyklus \(cycle): Step 1 liegt auf dem ersten Clock-Puls")
            } else {
                Issue.record("Zyklus \(cycle): kein Note-On oder kein Clock-Puls")
            }
        }
    }

    /// Vorlauf-Vertrag der Clock-Quelle (v1.12.21): jeder Tick wird VOR seinem Zeitpunkt
    /// ausgegeben, mit mindestens einem Tick-Intervall Abstand (die Overshoot-Korrektur im
    /// Tick-Pfad datiert Steps bis knapp ein Intervall zurück), und das Raster ist additiv.
    /// Die oberen Schranken sind großzügig — der Test läuft unter Last neben anderen Suiten.
    @Test func clockSourceEmitsEachTickAheadOfItsTimeOnAnAdditiveGrid() async {
        final class Box: @unchecked Sendable {
            var ticks: [(ts: UInt64, emit: UInt64)] = []
        }
        let box = Box()
        box.ticks.reserveCapacity(512)
        var mb = mach_timebase_info_data_t(); mach_timebase_info(&mb)
        let nsToMach = Double(mb.denom) / Double(mb.numer)
        let tickMach = (60_000_000_000.0 / (120.0 * 24.0)) * nsToMach

        let clock = ClockSource()
        clock.bpm = 120
        clock.onTick = { ts in box.ticks.append((ts, mach_absolute_time())) }
        clock.start()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        clock.stop()
        try? await Task.sleep(nanoseconds: 100_000_000)   // Thread endet beim nächsten Aufwachen
        let ticks = box.ticks

        #expect(ticks.count >= 30, "nur \(ticks.count) Ticks in 1 s bei 120 BPM (erwartet ~48)")
        let deltas = zip(ticks.dropFirst(), ticks).map { Double($0.ts) - Double($1.ts) }
        #expect(deltas.allSatisfy { abs($0 - tickMach) <= 2 }, "Raster nicht additiv")
        let leads = ticks.map { Double($0.ts) - Double($0.emit) }
        let late = leads.filter { $0 < tickMach }.count
        // Regelfall: Vorlauf = Intervall + 10 ms. Einzelne Ausreißer unter Last sind erlaubt,
        // die Mehrheit muss den Vertrag halten.
        #expect(late * 10 <= ticks.count, "\(late) von \(ticks.count) Ticks mit weniger als einem Intervall Vorlauf")
        #expect(leads.allSatisfy { $0 <= tickMach + (ClockSource.emitMarginNs + 1_000_000) * nsToMach },
                "Tick früher als Intervall + Marge ausgegeben")
        #expect(!clock.isRunning)
    }
}
