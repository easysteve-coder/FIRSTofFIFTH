import Testing
import Foundation
import Combine
@testable import VintageSequencer

// v1.15.1 — Nachweise zu den Codex-Befunden des Architekturreviews (14.11.2026):
//   K1  Speicherfreigabe nur ohne Hazard (deterministisch + Last),
//   H1  Mithör-Ring: echter SPSC-Vertrag unter Überlauf, zwei Threads,
//   H11 Undo-Kopie: Arbeit je Block begrenzt, Sprünge kopieren keine Lücken,
//   H7  Belegungsepoche: Meldungen/Zustände einer alten Belegung wirken nicht,
//   H8/H9/M7 Persistenz: Überpegel, ungültige Metadaten, nicht ladbares Material bleibt erhalten,
//   H4/H5 Transport: MIDI-Start, Taktanker je Sitzung, Songende zur geplanten Zeit.

private let sr = 1000.0
private let tps = AudioLoopCore.hostTicksPerSecond
private let tpf = tps / sr
private let barTicks = UInt64(2.0 * tps)

@Suite(.serialized) struct AudioLoopSafetyTests {

    // MARK: K1

    /// Hält der Ausgangs-Leser den Hazard, wird der abgelöste Speicher nicht freigegeben;
    /// danach schon.
    @Test func retiredStorageSurvivesWhileHazardIsHeld() throws {
        let core = AudioLoopCore(barClock: BarClock())
        weak var weakOld: AudioLoopStorage?
        do {
            let old = try #require(AudioLoopStorage(bars: 1, sampleRate: 8_000, bpm: 120))
            weakOld = old
            core.bind(old)
        }
        core._withOutputHazardHeld {
            core.bind(AudioLoopStorage(bars: 1, sampleRate: 8_000, bpm: 120))
            #expect(core._retiredCount == 1)
            #expect(weakOld != nil, "Leser hält den Hazard: nicht freigeben")
        }
        core.reclaim()
        #expect(core._retiredCount == 0)
        #expect(weakOld == nil, "nach dem Hazard freigegeben")
    }

    /// Last: ein Thread rendert ununterbrochen, Main tauscht den Speicher 2000-mal.
    @Test func concurrentRenderAndRebindDoesNotTouchFreedMemory() throws {
        let clock = BarClock(); clock.beginSession()
        let core = AudioLoopCore(barClock: clock)
        let h0: UInt64 = 1_000_000_000
        for b in 0..<4 { clock.publish(bar: b, host: h0 + UInt64(b) * barTicks) }
        core.markActive(tickTime: h0, spanTicks: 4 * barTicks, epoch: core.occupancyEpoch)
        let stop = ManagedFlag()
        let done = DispatchSemaphore(value: 0)
        let reader = Thread {
            let l = UnsafeMutablePointer<Float>.allocate(capacity: 256)
            let r = UnsafeMutablePointer<Float>.allocate(capacity: 256)
            var n = 0
            while !stop.value {
                core.renderOutput(host: h0 + UInt64(n % 4000) * UInt64(tpf), frames: 256,
                                  sampleRate: sr, l: l, r: r)
                n += 1
            }
            l.deallocate(); r.deallocate()
            done.signal()
        }
        reader.start()
        for i in 0..<2000 {
            let st = try #require(AudioLoopStorage(bars: 2, sampleRate: sr, bpm: 120))
            st.left[i % st.frames] = 1
            core.bind(st)
        }
        stop.value = true
        done.wait()
        core.reclaim()
        #expect(core._retiredCount == 0)
    }

    // MARK: H1

    /// Zwei Threads: Producer schreibt fortlaufende Frame-Nummern, Consumer liest. Gelesen
    /// wird nie rückwärts, nie doppelt, nie ein halber Frame — auch wenn der Ring überläuft.
    @Test func monitorRingKeepsSPSCContractUnderOverflow() {
        let ring = AudioSampleRing(capacityFrames: 512, channelCount: 2, maxDepthFrames: 256)
        let total = 200_000
        let done = DispatchSemaphore(value: 0)
        let producer = Thread {
            let buf = UnsafeMutablePointer<Float>.allocate(capacity: 128)
            var next = 1
            while next <= total {
                let n = min(64, total - next + 1)
                for f in 0..<n { buf[2 * f] = Float(next + f); buf[2 * f + 1] = Float(next + f) }
                ring.write(buf, frameCount: n)
                next += n
            }
            buf.deallocate()
            done.signal()
        }
        let dst = UnsafeMutablePointer<Float>.allocate(capacity: 100); defer { dst.deallocate() }
        var last: Float = 0, frames = 0, torn = 0, backwards = 0
        producer.start()
        var producerDone = false
        while true {
            let got = ring.read(into: dst, frameCount: 50)
            for f in 0..<got {
                let l = dst[2 * f], r = dst[2 * f + 1]
                if l != r { torn += 1 }
                if l <= last { backwards += 1 }
                last = l; frames += 1
            }
            if producerDone && got == 0 { break }
            if !producerDone, done.wait(timeout: .now()) == .success { producerDone = true }
        }
        #expect(torn == 0)
        #expect(backwards == 0)
        #expect(frames > 0 && frames + ring.dropped / 2 <= total)
    }

    // MARK: H11

    /// Nach einem Sprung der Aufnahmeposition (Eingangsaussetzer) wird die Lücke weder kopiert
    /// noch beim Undo getauscht; je Block nur ein begrenzter Kopieraufwand.
    @Test func undoCopyIsBoundedAndSkipsGaps() throws {
        let clock = BarClock(); clock.beginSession()
        let core = AudioLoopCore(barClock: clock)
        let st = try #require(AudioLoopStorage(bars: 8, sampleRate: sr, bpm: 120))   // 16000 Frames
        for i in 0..<st.frames { st.left[i] = 0.1; st.right[i] = 0.1; st.undoLeft[i] = 0.9; st.undoRight[i] = 0.9 }
        core.bind(st)
        core.configure(AudioLoopSettings(), latencyFrames: 0, sampleRate: sr)
        let h0: UInt64 = 1_000_000_000
        var nextBar = 0
        let input = UnsafeMutablePointer<Float>.allocate(capacity: 100); defer { input.deallocate() }
        input.update(repeating: 0.5, count: 100)
        let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 1); defer { ptrs.deallocate() }
        ptrs[0] = input
        func feed(from s: Double, to e: Double) {
            // Ganzzahlige Blockschritte (100 ms), damit kein Block über eine Taktgrenze rutscht.
            for k in Int((s * 10).rounded())..<Int((e * 10).rounded()) {
                let t = Double(k) / 10
                // Anker wie der Tick-Thread: höchstens einen Takt voraus (vier Plätze).
                while Double(nextBar) * 2.0 <= t + 0.2 {
                    clock.publish(bar: nextBar, host: h0 + UInt64(nextBar) * barTicks); nextBar += 1
                }
                core.consumeInput(host: h0 + UInt64(k) * UInt64(100 * tpf), frames: 100, sampleRate: sr,
                                  channels: ptrs, channelCount: 1)
            }
        }
        core.setRecording(true)
        feed(from: 0, to: 2.5)            // scharf in Takt 0, Aufnahme ab Takt 1 (Frame 2000)
        #expect(core.state == .recording)
        feed(from: 6.0, to: 16.0)         // Aussetzer 2.5 s → 6.0 s, dann bis zum Loop-Ende
        core.setRecording(false)
        feed(from: 16.0, to: 16.5)        // Loop-Anfang: Ende
        #expect(core.state == .idle)
        #expect(core.skippedFrames == 0)
        // Lücke Frames 2500…5999: unberührt, unmarkiert.
        #expect(abs(st.left[4000] - 0.1) < 1e-6)
        let gapChunk = 4000 / AudioLoopStorage.chunkFrames
        #expect(st.chunkPass(gapChunk) == 0)
        let undone = try #require(core.undoSwapped())
        #expect(abs(undone.left[4000] - 0.1) < 1e-6, "Lücke beim Undo nicht getauscht (sonst 0.9)")
        #expect(abs(undone.left[7000] - 0.1) < 1e-6, "Aufgenommenes zurückgenommen")
        #expect(abs(undone.left[2200] - 0.1) < 1e-6)
    }

    // MARK: H7

    /// Neue Belegung: ein scharf geschalteter Kern verliert den Auftrag, alte Tick-Meldungen
    /// öffnen kein Fenster mehr.
    @Test func newOccupancyInvalidatesOldRecordingAndTickReports() throws {
        let clock = BarClock(); clock.beginSession()
        let core = AudioLoopCore(barClock: clock)
        core.bind(AudioLoopStorage(bars: 1, sampleRate: sr, bpm: 120))
        let input = UnsafeMutablePointer<Float>.allocate(capacity: 10); defer { input.deallocate() }
        input.update(repeating: 0.5, count: 10)
        let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 1); defer { ptrs.deallocate() }
        ptrs[0] = input
        clock.publish(bar: 0, host: 1_000_000_000)
        core.setRecording(true)
        core.consumeInput(host: 1_000_000_000, frames: 10, sampleRate: sr, channels: ptrs, channelCount: 1)
        #expect(core.state == .armed)
        let old = core.occupancyEpoch
        core.beginOccupancy(old &+ 1)
        core.consumeInput(host: 1_000_100_000, frames: 10, sampleRate: sr, channels: ptrs, channelCount: 1)
        #expect(core.state == .idle && !core.isRecordRequested)
        core.markActive(tickTime: 1_000_000_000, spanTicks: barTicks, epoch: old)
        #expect(core._activeWindow.1 == 0, "Meldung der alten Belegung verworfen")
    }

    // MARK: R3

    /// Belegungswechsel genau zwischen Epochen-Lesen und Speichererwerb eines laufenden
    /// Eingangsblocks: die alte Aufnahme schreibt nicht in den Speicher der neuen Belegung.
    @Test func inFlightInputBlockDoesNotWriteIntoTheNextOccupancy() throws {
        let clock = BarClock(); clock.beginSession()
        let core = AudioLoopCore(barClock: clock)
        core.bind(AudioLoopStorage(bars: 2, sampleRate: sr, bpm: 120))
        core.configure(AudioLoopSettings(), latencyFrames: 0, sampleRate: sr)
        let h0: UInt64 = 1_000_000_000
        for b in 0..<3 { clock.publish(bar: b, host: h0 + UInt64(b) * barTicks) }
        let input = UnsafeMutablePointer<Float>.allocate(capacity: 100); defer { input.deallocate() }
        input.update(repeating: 0.5, count: 100)
        let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 1); defer { ptrs.deallocate() }
        ptrs[0] = input
        core.setRecording(true)
        for k in 0..<25 {   // scharf in Takt 0, Aufnahme ab Takt 1
            core.consumeInput(host: h0 + UInt64(k) * UInt64(100 * tpf), frames: 100, sampleRate: sr,
                              channels: ptrs, channelCount: 1)
        }
        #expect(core.state == .recording)
        let fresh = try #require(AudioLoopStorage(bars: 2, sampleRate: sr, bpm: 120))
        core._inputPausePoint = {
            // Main: Slot neu belegt und neuer Speicher gebunden, während der Block läuft.
            core.beginOccupancy(core.occupancyEpoch &+ 1)
            core.bind(fresh)
        }
        core.consumeInput(host: h0 + 25 * UInt64(100 * tpf), frames: 100, sampleRate: sr,
                          channels: ptrs, channelCount: 1)
        #expect(fresh.peak() == 0, "nichts in den Speicher der neuen Belegung geschrieben")
        #expect(core.state == .idle)
    }

    // MARK: R4

    /// Gültige CAF, aber widersprechende Metadaten (andere Rate, verkürzte Datei): Fehler
    /// statt falscher Tonhöhe oder aufgefüllter Stille.
    @Test func cafContradictingItsMetadataIsRejected() throws {
        let st = try #require(AudioLoopStorage(bars: 1, sampleRate: 48_000, bpm: 120))
        for i in 0..<st.frames { st.left[i] = 0.2; st.right[i] = 0.2 }
        let good = try #require(AudioLoopCodec.encode(st, channel: UUID()))
        #expect(AudioLoopCodec.decode(good, targetSampleRate: 96_000) != nil, "korrekt: umgerechnet")
        var wrongRate = good; wrongRate.sampleRate = 96_000; wrongRate.barFrames = 2 * good.barFrames
        #expect(AudioLoopCodec.decode(wrongRate, targetSampleRate: 96_000) == nil, "CAF 48 kHz, JSON 96 kHz")
        var truncated = good; truncated.bars = 2
        #expect(AudioLoopCodec.decode(truncated, targetSampleRate: 48_000) == nil, "Datei halb so lang wie angegeben")
    }

    // MARK: R5

    /// Budget zählt jeden lebenden Speicher (auch abgelöste/zurückgehaltene) und wird vor der
    /// Allokation geprüft.
    @Test func budgetLedgerCountsEveryLiveStorage() throws {
        let before = AudioLoopStorage.liveBytes
        var st: AudioLoopStorage? = try #require(AudioLoopStorage(bars: 1, sampleRate: 48_000, bpm: 120))
        let bytes = AudioLoopStorage.bytes(frames: st!.frames)
        #expect(AudioLoopStorage.liveBytes - before >= bytes)
        var copy: AudioLoopStorage? = st?.copy(includingUndo: true)
        #expect(AudioLoopStorage.liveBytes - before >= 2 * bytes, "Kopie zählt mit")
        st = nil
        #expect(AudioLoopStorage.liveBytes - before >= bytes)
        copy = nil
        _ = copy
        #expect(!AudioLoopStorage.fits(frames: AudioLoopSettings.maxProjectBytes / 16 + 1))
        #expect(AudioLoopCodec.targetFrames(AudioLoopFile(channel: UUID(), bars: 2, barFrames: 96_000,
                                                          sampleRate: 48_000, recordedBPM: 120, audio: Data()),
                                            sampleRate: 96_000) == 384_000, "Größe vor dem Dekodieren")
    }

    // MARK: H8 / H9 / M7

    @Test func codecPreservesOverdubAbovFullScaleAndSanitizes() throws {
        let st = try #require(AudioLoopStorage(bars: 1, sampleRate: 48_000, bpm: 120))
        for i in 0..<st.frames { st.left[i] = 2.5 * sinf(Float(i) * 0.01); st.right[i] = -1.7 }
        st.left[10] = .nan; st.right[11] = .infinity
        var copy = st
        for round in 0..<3 {   // wiederholter Roundtrip
            let file = try #require(AudioLoopCodec.encode(copy, channel: UUID()))
            #expect(file.scale != nil && file.scale! < 1)
            copy = try #require(AudioLoopCodec.decode(file, targetSampleRate: 48_000))
            #expect(abs(copy.right[100] + 1.7) < 1e-4, "Überpegel bleibt erhalten (Runde \(round))")
            #expect(abs(copy.left[157] - st.left[157]) < 1e-4)
            #expect(copy.left[10] == 0 && copy.right[11] == 0, "NaN/∞ → 0")
        }
    }

    @Test func invalidLoopMetadataIsRejectedWithoutTrapping() throws {
        let st = try #require(AudioLoopStorage(bars: 1, sampleRate: 8_000, bpm: 120))
        let good = try #require(AudioLoopCodec.encode(st, channel: UUID()))
        var a = good; a.bars = Int.max
        var b = good; b.barFrames = Int.max / 2; b.bars = 4
        var c = good; c.sampleRate = .nan
        var d = good; d.recordedBPM = -1
        var e = good; e.scale = 0
        var f = good; f.audio = Data(repeating: 7, count: 1000)
        for bad in [a, b, c, d, e, f] { #expect(AudioLoopCodec.decode(bad, targetSampleRate: 8_000) == nil) }
        #expect(AudioLoopStorage(bars: 16, sampleRate: 48_000, bpm: 120, barFrames: Int.max / 8) == nil)
        #expect(AudioLoopStorage(bars: 1, sampleRate: .infinity, bpm: 120) == nil)
    }

    /// Nicht ladbares Material: Laden meldet es, Speichern schreibt es unverändert zurück.
    @MainActor @Test func unrestorableLoopIsKeptAndSavedBack() throws {
        let engine = SequencerEngine()
        let placed = engine.addAudioLoopTrack()
        let ch = try #require(placed.first?.track.instrumentID)
        let st = try #require(AudioLoopStorage(bars: 1, sampleRate: 48_000, bpm: 120))
        for i in 0..<st.frames { st.left[i] = 0.3; st.right[i] = 0.3 }
        engine.rack._setLoopStorage(st, for: ch)
        let data = try #require(engine.saveData())
        // Audiodaten im JSON beschädigen.
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var loops = try #require(json["audioLoops"] as? [[String: Any]])
        loops[0]["audio"] = Data(repeating: 1, count: 64).base64EncodedString()
        json["audioLoops"] = loops
        let broken = try JSONSerialization.data(withJSONObject: json)

        let other = SequencerEngine()
        #expect(other.loadData(broken))
        #expect(other.loadWarning != nil)
        #expect(other.rack.loopCore(for: ch)?.hasMaterial == false)
        let resaved = try #require(other.saveData())
        let back = try #require(try JSONSerialization.jsonObject(with: resaved) as? [String: Any])
        let backLoops = try #require(back["audioLoops"] as? [[String: Any]])
        #expect(backLoops.count == 1)
        #expect(backLoops[0]["audio"] as? String == Data(repeating: 1, count: 64).base64EncodedString(),
                "Originaldaten unverändert zurückgeschrieben")
    }

    // MARK: M5 — Anzeige je Kanal

    /// Fader eines anderen Kanals invalidiert die Loop-Zeile nicht; Fehler bleiben beim
    /// Kanal; ohne aktiven Loop wird nichts abgefragt.
    @MainActor @Test func loopDisplayIsPerChannelAndIdleDoesNotPoll() throws {
        let engine = SequencerEngine()
        let a = try #require(engine.addAudioLoopTrack().first?.track.instrumentID)
        let b = try #require(engine.addAudioLoopTrack().first?.track.instrumentID)
        let other = try #require(engine.rack.addChannel(name: "X"))
        let da = try #require(engine.rack.loopDisplay(a))
        let db = try #require(engine.rack.loopDisplay(b))
        var changes = 0
        let sub = da.objectWillChange.sink { changes += 1 }
        defer { sub.cancel() }
        engine.rack.setVolume(other, 0.5)
        engine.rack.setVolume(b, 0.5)
        engine.rack.setPan(a, 0.3)            // Mixer des eigenen Kanals: auch kein Loop-Zustand
        #expect(changes == 0, "Mixeränderungen invalidieren die Loop-Anzeige nicht")
        #expect(!engine.rack._loopStatusPolling, "ruhende Loops werden nicht abgefragt")

        var settings = da.settings; settings.bars = 2
        engine.rack.setAudioLoopSettings(settings, for: a)
        #expect(da.settings.bars == 2 && changes > 0)
        #expect(db.settings.bars != 2)

        // Speicherbudget voll → Fehler nur am betroffenen Kanal.
        let st = try #require(AudioLoopStorage(bars: 1, sampleRate: 48_000, bpm: 120))
        engine.rack._setLoopStorage(st, for: b)
        engine.rack.undoLoop(b)               // keine Undo-Stufe: kein Fehler, nichts passiert
        #expect(da.error == nil && db.error == nil)

        // Scharf geschalteter Kern (ohne echten Eingang) → Abfrage läuft, bis er ruht.
        da.core.setRecording(true)
        engine.rack.kickLoopDisplays()
        #expect(da.status.requested && da.status.inputActive && !db.status.inputActive)
        #expect(engine.rack._loopStatusPolling)
        da.core.setRecording(false)
        #expect(!engine.rack.refreshLoopDisplays(), "nichts mehr aktiv")
        #expect(!da.status.inputActive)
    }

    /// Positionskopf bei Play (v1.16.1): beim Start hat der erste Tick den Wiedergabeort noch
    /// nicht gesetzt — die Abfrage muss trotzdem starten und bis zum Stopp laufen.
    @MainActor @Test func playheadPollingRunsWhileTransportPlays() throws {
        let engine = SequencerEngine()
        let a = try #require(engine.addAudioLoopTrack().first?.track.instrumentID)
        let st = try #require(AudioLoopStorage(bars: 1, sampleRate: 48_000, bpm: 120))
        for i in 0..<st.frames { st.left[i] = 0.3; st.right[i] = 0.3 }
        engine.rack._setLoopStorage(st, for: a)
        #expect(try #require(engine.rack.loopDisplay(a)).status.hasMaterial)
        engine.rack.refreshLoopDisplays()
        #expect(!engine.rack._loopStatusPolling, "gestoppt: keine Abfrage")
        engine.setClockMode(.external)
        engine.play()
        #expect(engine.rack._loopStatusPolling, "Play: Abfrage läuft, auch vor dem ersten Tick")
        engine.stop()
        #expect(!engine.rack.refreshLoopDisplays(), "nach dem Stopp ruht die Anzeige wieder")
    }

    // MARK: Vorkodieren

    /// Ruhendes Material wird im Hintergrund kodiert; Speichern nimmt diesen Stand.
    @MainActor @Test func idleLoopsArePreencodedInTheBackground() async throws {
        let engine = SequencerEngine()
        let placed = engine.addAudioLoopTrack()
        let ch = try #require(placed.first?.track.instrumentID)
        let st = try #require(AudioLoopStorage(bars: 1, sampleRate: 48_000, bpm: 120))
        for i in 0..<st.frames { st.left[i] = 0.25; st.right[i] = 0.25 }
        engine.rack._setLoopStorage(st, for: ch)
        engine.rack.preencodeIdleLoops()
        #expect(engine.rack._encodingCount == 1)
        for _ in 0..<200 where engine.rack._preencodedCount == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(engine.rack._preencodedCount == 1, "im Hintergrund kodiert")
        let data = try #require(engine.saveData())
        let other = SequencerEngine()
        #expect(other.loadData(data))
        #expect(other.rack.loopCore(for: ch)?.hasMaterial == true)
    }

    // MARK: M3

    /// Undo von „Audio-Loop-Spur hinzufügen" entfernt auch den Kanal; Redo bringt Kanal
    /// (gleiche Identität) samt Material zurück.
    @MainActor @Test func undoingAnAddedLoopTrackRemovesItsChannel() throws {
        let engine = SequencerEngine()
        let um = UndoManager(); um.groupsByEvent = false
        engine.undoManager = um
        let before = engine.rack.channels.count
        um.beginUndoGrouping(); engine.addAudioLoopTrackUndoable(actionName: "add"); um.endUndoGrouping()
        let td = try #require(engine.currentPattern.tracks.last)
        let ch = try #require(td.instrumentID)
        let st = try #require(AudioLoopStorage(bars: 1, sampleRate: 48_000, bpm: 120))
        st.left[5] = 0.4
        engine.rack._setLoopStorage(st, for: ch)
        um.undo()
        #expect(engine.rack.channels.count == before, "kein verwaister Kanal")
        #expect(!engine.currentPattern.tracks.contains { $0 === td })
        um.redo()
        #expect(engine.rack.channel(ch) != nil, "gleiche Kanal-Identität")
        #expect(engine.currentPattern.tracks.last === td && td.instrumentID == ch)
        #expect(engine.rack.loopCore(for: ch)?.hasMaterial == true, "Material zurück")
    }

    // MARK: M2 — Material als Dokumentbefehl

    /// Löschen ist über den Dokument-UndoManager rückgängig zu machen (derselbe Speicher
    /// kommt zurück); ein Undo-Eintrag greift nicht mehr, wenn inzwischen anderes Material
    /// gebunden ist.
    @MainActor @Test func loopClearIsVersionBoundDocumentUndo() throws {
        let engine = SequencerEngine()
        let um = UndoManager(); um.groupsByEvent = false
        engine.undoManager = um
        let ch = try #require(engine.addAudioLoopTrack().first?.track.instrumentID)
        let st = try #require(AudioLoopStorage(bars: 1, sampleRate: 48_000, bpm: 120))
        st.left[3] = 0.7
        engine.rack._setLoopStorage(st, for: ch)
        let core = try #require(engine.rack.loopCore(for: ch))

        um.beginUndoGrouping(); engine.clearAudioLoopUndoable(ch, actionName: "clear"); um.endUndoGrouping()
        #expect(!core.hasMaterial)
        um.undo()
        #expect(core.hasMaterial, "Löschen rückgängig")
        #expect(engine.rack.loopFrames(ch) == st.frames)
        um.redo()
        #expect(!core.hasMaterial)
        um.undo()
        #expect(core.hasMaterial)

        // Anderes Material gebunden → der alte Eintrag (Redo: löschen) wirkt nicht mehr.
        let other = try #require(AudioLoopStorage(bars: 2, sampleRate: 48_000, bpm: 120))
        other.left[0] = 0.1
        engine.rack._setLoopStorage(other, for: ch)
        um.redo()
        #expect(core.hasMaterial && engine.rack.loopFrames(ch) == other.frames, "versionsgebunden")
    }

    // MARK: H4 / H5

    /// Externer Neustart während der Wiedergabe: Taktanker beginnen wieder bei Takt 0, obwohl
    /// die alte Sitzung höhere Taktnummern hinterlassen hat.
    @MainActor @Test func externalRestartBeginsANewAnchorSession() throws {
        let engine = SequencerEngine()
        engine.setClockMode(.external)
        engine.play()
        defer { engine.stop() }
        let gap: UInt64 = 1_000_000
        let t0 = mach_absolute_time() + 5_000_000_000
        for p in 0..<(96 * 3 + 1) { engine._rt3aDriveOneExternalTick(at: t0 + UInt64(p) * gap) }
        #expect(engine.rack.barClock.window().anchor(at: t0 + 290 * gap).bar == 3)
        engine.midi.onStart?()                                   // MIDI-Start vom Master
        let t1 = t0 + 400 * gap
        engine._rt3aDriveOneExternalTick(at: t1)
        #expect(engine.rack.barClock.window().anchor(at: t1).bar == 0, "neue Sitzung: Takt 0")
        #expect(engine.rack.barClock.window().anchor(at: t1).host == t1)
    }

    /// EXT-Clock (Codex T1): Zeitbezug ist der Paketzeitstempel; jeder Puls, auch der erste,
    /// liegt um denselben Vorlauf dahinter — gebündelte Zustellung ändert die Phase nicht.
    @MainActor @Test func externalClockUsesPacketTimeWithConstantLead() throws {
        let engine = SequencerEngine()
        let lane = engine.currentPattern.tracks[0].lane
        for i in 0..<lane.stepCount { lane.steps[i].isActive = true; lane.steps[i].probability = 1 }
        var stamps: [UInt64] = []
        let lock = NSLock()
        engine.midi._testSendObserver = { b0, _, b2, _, ts in
            if b0 & 0xF0 == 0x90, b2 > 0 { lock.lock(); stamps.append(ts); lock.unlock() }
        }
        engine.setClockMode(.external)
        engine.play()
        defer { engine.stop() }
        let lead = engine._extLookaheadMach
        #expect(lead > SequencerEngine.nanosToMachTime(10_000_000))
        let pulse = SequencerEngine.nanosToMachTime(20_833_333)
        let t0 = mach_absolute_time() + SequencerEngine.nanosToMachTime(50_000_000)
        // 13 Pulse „gebündelt": alle sofort hintereinander zugestellt, Paketzeiten im Pulsabstand.
        for p in 0..<13 { engine.midi.onClockPulse?(t0 + UInt64(p) * pulse) }
        lock.lock(); let got = stamps; lock.unlock()
        #expect(got.count == 3, "Steps auf Puls 0, 6, 12")
        if got.count == 3 {
            #expect(got[0] == t0 + lead, "erster Puls mit demselben Vorlauf")
            #expect(got[1] == t0 + 6 * pulse + lead)
            #expect(got[2] == t0 + 12 * pulse + lead)
        }
    }

    /// MIDI-Start aus dem Stopp beginnt einen aktiven Song wie Play (Szene 1, Wechsel vorgemerkt).
    @MainActor @Test func midiStartFromStopBeginsTheSong() throws {
        let engine = SequencerEngine()
        engine.replaceSong(Song(scenes: [SongScene(pattern: 2, bars: 1), SongScene(pattern: 3, bars: 1)],
                                enabled: true, loops: true))
        engine.setClockMode(.external)
        engine.midi.onStart?()
        defer { engine.stop() }
        #expect(engine.isPlaying)
        #expect(engine.currentPatternIndex == 2)
        #expect(engine.queuedPatternIndex == 3)
        #expect(engine._rt1PublishedBundle()?.switchAtPulse == 96)
    }

    /// Songende: Loop-Fenster schließen exakt auf dem Endpuls, die Taktanker enden dort —
    /// nicht zur Reaktionszeit von Main.
    @MainActor @Test func songEndClosesLoopsAtTheScheduledPulse() throws {
        let engine = SequencerEngine()
        let placed = engine.addAudioLoopTrack()
        let ch = try #require(placed.first { $0.pattern === engine.currentPattern }?.track.instrumentID)
        let core = try #require(engine.rack.loopCore(for: ch))
        engine.replaceSong(Song(scenes: [SongScene(pattern: engine.currentPatternIndex, bars: 1)],
                                enabled: true, loops: false))
        engine.setClockMode(.external)
        engine.play()
        // Tickabstand kürzer als die Fensterreserve (1,25 Pulse), damit das Fenster offen ist.
        let gap = SequencerEngine.nanosToMachTime(10_000_000)
        let t0 = mach_absolute_time() + 5_000_000_000
        for p in 0...96 { engine._rt3aDriveOneExternalTick(at: t0 + UInt64(p) * gap) }
        let end = t0 + 96 * gap
        #expect(core._activeWindow.1 == end, "Fenster endet exakt auf dem Endpuls")
        engine._stopIfSongEnded(now: end)   // Main reagiert zum Endpuls (R2: nicht früher)
        #expect(!engine.isPlaying)
        let w = engine.rack.barClock.window()
        #expect(w.anchor(at: end - 1).isValid, "bis zum Endpuls gelten die Anker")
        #expect(!w.anchor(at: end).isValid)
    }

    /// Stummschalten schließt das Fenster auf dem Tick, der die Stummschaltung sieht.
    @MainActor @Test func muteClosesTheLoopWindowOnTheTick() throws {
        let engine = SequencerEngine()
        let placed = engine.addAudioLoopTrack()
        let td = try #require(placed.first { $0.pattern === engine.currentPattern }?.track)
        let core = try #require(engine.rack.loopCore(for: td.instrumentID))
        engine.setClockMode(.external)
        engine.play()
        defer { engine.stop() }
        let t0 = mach_absolute_time() + 5_000_000_000
        engine._rt3aDriveOneExternalTick(at: t0)
        let open = core._activeWindow.1
        #expect(open > t0)
        let mid = t0 + (open - t0) / 2
        ModelWriter().apply(.setMuted(trackID: td.id, old: false, new: true), to: td, undoManager: nil)
        engine.publishSnapshot()
        engine._rt3aDriveOneExternalTick(at: mid)
        #expect(core._activeWindow.1 == mid)
    }
}

// MARK: - Messung

@Suite(.serialized) struct AudioLoopRenderCostTests {

    /// Renderkosten bei Volllast: 16 Kerne nehmen gleichzeitig auf (Overdub, Gate am Eingang,
    /// Mithören) und spielen ab, 512-Frame-Blöcke bei 48 kHz. Gemessen wird ein kompletter
    /// Eingangs- plus Ausgangsdurchlauf über alle Kerne; Ergebnis in eine Datei im tmp des
    /// Test-Containers (`fof-loop-render-cost.txt`).
    @Test func renderCostOfSixteenRecordingLoops() throws {
        let rate = 48_000.0, frames = 512, blocks = 2000
        let ticksPerFrame = AudioLoopCore.hostTicksPerSecond / rate
        let clock = BarClock(); clock.beginSession()
        let bar = UInt64(2.0 * AudioLoopCore.hostTicksPerSecond)
        let h0: UInt64 = 10_000_000_000
        var settings = AudioLoopSettings(); settings.monitor = true; settings.gate.position = .input
        let cores = (0..<16).map { _ in AudioLoopCore(barClock: clock) }
        for c in cores {
            c.bind(AudioLoopStorage(bars: 4, sampleRate: rate, bpm: 120))
            c.configure(settings, latencyFrames: 0, sampleRate: rate)
            c.markActive(tickTime: h0, spanTicks: 100 * bar, epoch: c.occupancyEpoch)
            c.setRecording(true)
        }
        let input = UnsafeMutablePointer<Float>.allocate(capacity: frames); defer { input.deallocate() }
        for i in 0..<frames { input[i] = 0.3 * sinf(Float(i) * 0.05) }
        let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 1); defer { ptrs.deallocate() }
        ptrs[0] = input
        let l = UnsafeMutablePointer<Float>.allocate(capacity: frames); defer { l.deallocate() }
        let r = UnsafeMutablePointer<Float>.allocate(capacity: frames); defer { r.deallocate() }
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        var costs: [Double] = []; costs.reserveCapacity(blocks)
        // Arbeitskosten als Thread-CPU-Zeit (ohne Preemption), Wandzeit nur berichtet (v1.16.1).
        var cpu: [Double] = []; cpu.reserveCapacity(blocks)
        var nextBar = 0
        for k in 0..<blocks {
            let host = h0 + UInt64(Double(k * frames) * ticksPerFrame)
            while h0 + UInt64(nextBar) * bar <= host + bar / 2 {
                clock.publish(bar: nextBar, host: h0 + UInt64(nextBar) * bar); nextBar += 1
            }
            let c0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let t0 = mach_absolute_time()
            for c in cores {
                c.consumeInput(host: host, frames: frames, sampleRate: rate, channels: ptrs, channelCount: 1)
            }
            for c in cores {
                c.renderOutput(host: host, frames: frames, sampleRate: rate, l: l, r: r)
            }
            costs.append(Double(mach_absolute_time() - t0) * Double(tb.numer) / Double(tb.denom) / 1_000)
            cpu.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - c0) / 1_000)
        }
        #expect(cores.allSatisfy { $0.state == .recording })
        let sorted = costs.sorted()
        let median = sorted[blocks / 2], p99 = sorted[blocks * 99 / 100], worst = sorted.last!
        let cpuSorted = cpu.sorted()
        let cpuMedian = cpuSorted[blocks / 2], cpuP99 = cpuSorted[blocks * 99 / 100], cpuMax = cpuSorted.last!
        let blockMicros = Double(frames) / rate * 1_000_000
        let build = _isDebugAssertConfiguration() ? "unoptimiert (-Onone)" : "optimiert (-O)"
        let report = String(format: "Loop-Renderkosten 16 Kerne, %d Frames @ %.0f Hz, %@: CPU median %.0f µs, p99 %.0f µs, max %.0f µs; Wand median %.0f µs, p99 %.0f µs, max %.0f µs; Blockzeit %.0f µs\n",
                            frames, rate, build, cpuMedian, cpuP99, cpuMax, median, p99, worst, blockMicros)
        try? report.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("fof-loop-render-cost.txt"),
                          atomically: true, encoding: .utf8)
        // Abnahme gilt für den optimierten Build (so läuft die App). Unoptimiert sind die
        // atomaren Samplezugriffe Funktionsaufrufe; dort nur grobe Plausibilität.
        // Grenzen auf Arbeitskosten; die Wandzeit enthält Preemption durch parallele Tests.
        if _isDebugAssertConfiguration() {
            #expect(cpuP99 < blockMicros * 4, "\(report)")
        } else {
            #expect(cpuP99 < blockMicros / 4, "\(report)")
            #expect(cpuMax < blockMicros / 2, "\(report)")
        }
    }
}

/// Einfache Thread-übergreifende Flagge für Testschleifen.
private final class ManagedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}
