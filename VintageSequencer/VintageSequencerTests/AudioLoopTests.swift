import Testing
import Foundation
import AVFoundation
@testable import VintageSequencer

// v1.15.0 — Audio-Loop: Taktanker, Aufnahme/Overdub/Ende/Undo im Kern, Wiedergabe,
// Gate, Kodierung, Preset, Tick-Anbindung. Ohne Audiogerät: Anker und Eingangsblöcke werden
// künstlich erzeugt (Abtastrate 1000 Hz, 120 BPM → 2000 Frames je Takt).

private let sr = 1000.0
private let tps = AudioLoopCore.hostTicksPerSecond
private let tpf = tps / sr
private let barTicks = UInt64(2.0 * tps)          // ein Takt bei 120 BPM = 2 s

/// Speist `seconds` Sekunden konstanten Eingang ab `from` in Blöcken zu 100 Frames und
/// veröffentlicht die Taktanker so, wie der Tick-Thread es täte (rechtzeitig voraus).
private final class Feeder {
    let core: AudioLoopCore
    let clock: BarClock
    let h0: UInt64
    var host: UInt64
    var nextBar = 0
    let left = UnsafeMutablePointer<Float>.allocate(capacity: 100)
    let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 1)

    init(core: AudioLoopCore, clock: BarClock, h0: UInt64) {
        self.core = core; self.clock = clock; self.h0 = h0; self.host = h0
        ptrs[0] = left
    }
    deinit { left.deallocate(); ptrs.deallocate() }

    func feed(seconds: Double, value: Float) {
        left.update(repeating: value, count: 100)
        var remaining = Int(seconds * sr)
        while remaining > 0 {
            let end = host + UInt64(100 * tpf)
            while h0 + UInt64(nextBar) * barTicks <= end + barTicks / 100 {
                clock.publish(bar: nextBar, host: h0 + UInt64(nextBar) * barTicks); nextBar += 1
            }
            core.consumeInput(host: host, frames: 100, sampleRate: sr, channels: ptrs, channelCount: 1)
            host = end
            remaining -= 100
        }
    }
}

@Suite(.serialized) struct AudioLoopTests {

    @Test func barClockPicksTheBarAHostTimeLiesIn() {
        let c = BarClock()
        #expect(!c.window().anchor(at: 10).isValid, "ohne Sitzung keine Position")
        c.beginSession()
        #expect(!c.window().anchor(at: 10).isValid, "ohne Anker keine Position")
        c.publish(bar: 0, host: 1000); c.publish(bar: 1, host: 2000); c.publish(bar: 2, host: 3000)
        let w = c.window()
        #expect(w.anchor(at: 999).isValid == false)
        #expect(w.anchor(at: 1500).bar == 0)
        #expect(w.anchor(at: 2000).bar == 1)
        #expect(w.anchor(at: 9999).bar == 2)
        c.publish(bar: 4, host: 5000)                  // überschreibt Platz von Takt 0
        #expect(c.window().anchor(at: 1500).isValid == false)
        c.stop(at: 5500)
        #expect(c.window().anchor(at: 5200).bar == 4, "vor dem Ende gilt der Anker")
        #expect(!c.window().anchor(at: 5500).isValid, "ab dem Ende keine Anker")
        #expect(c.window().isStopped(at: 5500) && !c.window().isStopped(at: 5499))
        c.stop(at: 9000)
        #expect(!c.window().anchor(at: 6000).isValid, "ein späteres Ende verschiebt das frühere nicht")
        c.beginSession()
        #expect(!c.window().anchor(at: 5200).isValid, "neue Sitzung verwirft alte Anker")
    }

    /// Scharf → Beginn am nächsten Takt → Overdub über den Loop-Anfang → Ende am Loop-Ende →
    /// Undo nimmt genau den letzten Durchlauf zurück, Redo stellt ihn wieder her.
    @Test func recordsFromNextBarOverdubsAndStopsAtLoopEnd() throws {
        let clock = BarClock(); clock.beginSession()
        let core = AudioLoopCore(barClock: clock)
        let st = try #require(AudioLoopStorage(bars: 2, sampleRate: sr, bpm: 120))
        #expect(st.barFrames == 2000 && st.frames == 4000)
        core.bind(st)
        core.configure(AudioLoopSettings(), latencyFrames: 0, sampleRate: sr)
        let f = Feeder(core: core, clock: clock, h0: 1_000_000_000)

        core.setRecording(true)
        f.feed(seconds: 1.0, value: 0.5)               // Takt 0: nur scharf
        #expect(core.state == .armed)
        #expect(st.left[2500] == 0)
        f.feed(seconds: 1.0, value: 0.5)               // Rest Takt 0
        f.feed(seconds: 2.0, value: 0.5)               // Takt 1 → Loop-Takt 1 (pos 2000…)
        #expect(core.state == .recording)
        f.feed(seconds: 2.0, value: 0.5)               // Takt 2 → Loop-Takt 0, neuer Durchlauf
        f.feed(seconds: 1.0, value: 0.5)               // Takt 3, erste Hälfte
        core.setRecording(false)                       // Ende am Ende dieses Durchlaufs
        f.feed(seconds: 0.2, value: 0.5)
        #expect(core.state == .finishing)
        f.feed(seconds: 0.8, value: 0.5)               // Takt 3 Rest
        f.feed(seconds: 0.5, value: 0.5)               // Takt 4: Loop-Anfang → Ende
        #expect(core.state == .idle)
        #expect(!core.isRecordRequested)

        #expect(abs(st.left[1000] - 0.5) < 1e-6, "Loop-Takt 0: ein Durchlauf")
        #expect(abs(st.left[3000] - 1.0) < 1e-6, "Loop-Takt 1: zwei Durchläufe übereinander")
        // Frame 2010: erster Durchlauf eingeblendet (10/128) + zweiter voll.
        #expect(abs(st.left[2010] - (0.5 * 10 / 128 + 0.5)) < 1e-4, "Einblenden am Aufnahmebeginn")
        #expect(st.left[3999] < 1.0, "Ausblenden am Ende")
        #expect(st.right[1000] == st.left[1000], "Mono auf beide Seiten")

        // Undo: letzter Durchlauf (Takt 2–3) zurück.
        // Undo ist ein Austausch: der gebundene Speicher bleibt unberührt (v1.15.1).
        #expect(core.canUndo)
        let undone = try #require(core.undoSwapped())
        core.bind(undone, keepUndo: true)
        #expect(abs(st.left[3000] - 1.0) < 1e-6, "veröffentlichter Speicher unverändert")
        #expect(undone.left[1000] == 0)
        #expect(abs(undone.left[3000] - 0.5) < 1e-6)
        #expect(core.canUndo)
        let redone = try #require(core.undoSwapped())   // Redo
        core.bind(redone, keepUndo: true)
        #expect(abs(redone.left[3000] - 1.0) < 1e-6)
        #expect(abs(redone.left[1000] - 0.5) < 1e-6)

        // Nach dem Ende wird nicht mehr geschrieben.
        f.feed(seconds: 2.0, value: 0.5)
        #expect(abs(redone.left[1000] - 0.5) < 1e-6)
    }

    /// Wiedergabe: Ort aus Taktanker und Host-Zeit, nur im Aktivfenster des Tick-Threads.
    @Test func playsBackAtTheBarPositionOnlyWhileActive() throws {
        let clock = BarClock(); clock.beginSession()
        let core = AudioLoopCore(barClock: clock)
        let st = try #require(AudioLoopStorage(bars: 2, sampleRate: sr, bpm: 120))
        for i in 0..<st.frames { st.left[i] = Float(i); st.right[i] = -Float(i) }
        core.bind(st)
        let h0: UInt64 = 5_000_000_000
        for b in 0..<4 { clock.publish(bar: b, host: h0 + UInt64(b) * barTicks) }
        let l = UnsafeMutablePointer<Float>.allocate(capacity: 64); defer { l.deallocate() }
        let r = UnsafeMutablePointer<Float>.allocate(capacity: 64); defer { r.deallocate() }

        // Ohne Aktivfenster: still.
        core.renderOutput(host: h0 + 3 * barTicks, frames: 64, sampleRate: sr, l: l, r: r)
        #expect(l[0] == 0 && core.playFrame == -1)

        core.markActive(tickTime: h0, spanTicks: 10 * barTicks, epoch: core.occupancyEpoch &+ 1)
        core.renderOutput(host: h0 + 3 * barTicks, frames: 64, sampleRate: sr, l: l, r: r)
        #expect(l[0] == 0, "Meldung einer fremden Belegung wird verworfen")
        core.markActive(tickTime: h0, spanTicks: 10 * barTicks, epoch: core.occupancyEpoch)
        // Takt 3 = Loop-Takt 1, 0,5 s hinein → Frame 2000 + 500.
        core.renderOutput(host: h0 + 3 * barTicks + UInt64(0.5 * tps), frames: 64, sampleRate: sr, l: l, r: r)
        #expect(abs(l[0] - 2500) <= 1 && abs(r[0] + 2500) <= 1)
        #expect(abs(l[10] - 2510) <= 1)
        #expect(core.playFrame >= 2500)

        // Fenster exakt geschlossen: ab dort still, davor noch Klang.
        let cut = h0 + 3 * barTicks + UInt64(0.5 * tps) + UInt64(32 * tpf)
        core.closeWindow(at: cut)
        core.renderOutput(host: h0 + 3 * barTicks + UInt64(0.5 * tps), frames: 64, sampleRate: sr, l: l, r: r)
        #expect(l[31] != 0 && l[33] == 0)

        // Größerer Block als maxFrames wird vollständig bedient (Codex M9).
        let big = AudioLoopCore.maxFrames + 500
        let bl = UnsafeMutablePointer<Float>.allocate(capacity: big); defer { bl.deallocate() }
        let br = UnsafeMutablePointer<Float>.allocate(capacity: big); defer { br.deallocate() }
        bl.update(repeating: 7, count: big)
        core.renderOutput(host: h0, frames: big, sampleRate: sr, l: bl, r: br)
        #expect(bl[big - 1] != 7, "auch der Rest jenseits von maxFrames ist geschrieben")

        // Abweichende Rate: still statt falsch schnell (Codex H6).
        core.markActive(tickTime: h0, spanTicks: 10 * barTicks, epoch: core.occupancyEpoch)
        core.renderOutput(host: h0 + 3 * barTicks, frames: 64, sampleRate: 2 * sr, l: l, r: r)
        #expect(l[10] == 0 && core.rateMismatch)
    }

    @Test func gateClosesBelowThresholdAndPassesAbove() {
        let control = GateControl()
        var g = GateSettings(); g.thresholdDB = -20; g.releaseMs = 10; g.holdMs = 0
        control.apply(g, enabled: true)
        var dsp = GateDSP()
        let n = 4000
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: n); defer { buf.deallocate() }
        buf.update(repeating: 0.01, count: n)          // −40 dB: Rauschen
        dsp.process(buf, buf, frames: n, sampleRate: 48_000, control.values())
        #expect(buf[n - 1] < 0.0001)
        buf.update(repeating: 0.5, count: n)           // −6 dB: Signal
        dsp.process(buf, buf, frames: n, sampleRate: 48_000, control.values())
        #expect(buf[n - 1] > 0.49)
        control.apply(g, enabled: false)
        buf.update(repeating: 0.01, count: n)
        dsp.process(buf, buf, frames: n, sampleRate: 48_000, control.values())
        #expect(buf[n - 1] == 0.01, "aus: unverändert")
    }

    /// Die Gate-AU lädt im eigenen Prozess und arbeitet in einer echten Engine (offline).
    @Test func gateAudioUnitProcessesInsideAnEngine() throws {
        GateAudioUnit.register()
        let unit = AVAudioUnitEffect(audioComponentDescription: GateAudioUnit.componentDescription)
        let gate = try #require(unit.auAudioUnit as? GateAudioUnit)
        var g = GateSettings(); g.thresholdDB = -20; g.releaseMs = 10; g.holdMs = 0
        gate.control.apply(g, enabled: true)

        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let level = UnsafeMutablePointer<Float>.allocate(capacity: 1); defer { level.deallocate() }
        level.pointee = 0.01
        let source = AVAudioSourceNode(format: format) { _, _, frames, abl in
            for b in UnsafeMutableAudioBufferListPointer(abl) {
                b.mData!.assumingMemoryBound(to: Float.self).update(repeating: level.pointee, count: Int(frames))
            }
            return noErr
        }
        let e = AVAudioEngine()
        try e.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        e.attach(source); e.attach(unit)
        e.connect(source, to: unit, format: format)
        e.connect(unit, to: e.mainMixerNode, format: format)
        try e.start()
        let out = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        _ = try e.renderOffline(4096, to: out)
        #expect(abs(out.floatChannelData![0][4095]) < 0.0005, "Rauschen unter der Schwelle geschlossen")
        level.pointee = 0.5
        _ = try e.renderOffline(4096, to: out)
        #expect(out.floatChannelData![0][4095] > 0.45, "Signal über der Schwelle offen")
        e.stop()
    }

    @Test func codecRoundTripsLosslesslyAndResamples() throws {
        let st = try #require(AudioLoopStorage(bars: 1, sampleRate: 48_000, bpm: 120))
        for i in 0..<st.frames {
            st.left[i] = 0.5 * sinf(Float(i) * 0.01); st.right[i] = 0.25 * cosf(Float(i) * 0.02)
        }
        let id = UUID()
        let file = try #require(AudioLoopCodec.encode(st, channel: id))
        #expect(file.audio.count < st.frames * 8, "komprimiert")
        let back = try #require(AudioLoopCodec.decode(file, targetSampleRate: 48_000))
        #expect(back.frames == st.frames)
        var maxErr: Float = 0
        for i in stride(from: 0, to: st.frames, by: 97) {
            maxErr = max(maxErr, abs(back.left[i] - st.left[i]), abs(back.right[i] - st.right[i]))
        }
        #expect(maxErr < 1e-5, "24 Bit, Fehler unter der Quantisierungsstufe")
        let resampled = try #require(AudioLoopCodec.decode(file, targetSampleRate: 44_100))
        #expect(resampled.barFrames == AudioLoopStorage.barFrames(bpm: 120, sampleRate: 44_100))
    }

    @Test func settingsAndTrackFlagRoundTrip() throws {
        var s = AudioLoopSettings()
        s.bars = 8; s.monitor = true; s.gate.position = .postFader; s.gate.thresholdDB = -33
        let back = try JSONDecoder().decode(AudioLoopSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        var bad = s; bad.bars = 5; bad.gate.thresholdDB = -500; bad.clamp()
        #expect(bad.bars == 4 && bad.gate.thresholdDB == -80)

        let ch = UUID()
        let td = TrackData(name: "L"); td.output = .audioLoop(ch)
        let json = String(decoding: try JSONEncoder().encode(td), as: UTF8.self)
        #expect(json.contains("\"audioLoop\":\"\(ch.uuidString)\""))
        #expect(!json.contains("\"lane\""), "Loop-Spur speichert keine Steps (v1.16.0)")
        let loaded = try JSONDecoder().decode(TrackData.self, from: JSONEncoder().encode(td))
        #expect(loaded.output == .audioLoop(ch))
        #expect(td.freshCopy().output == .audioLoop(ch))
        // Fest gebunden: ein Instrumentenwechsel wirkt auf Loop-Spuren nicht.
        td.instrumentID = UUID()
        #expect(td.output == .audioLoop(ch))
    }

    /// Presetvertrag v1.16.0: `output` und `source` sind Pflicht; ungültige Fälle werden
    /// abgelehnt; die Route prüft die Quelle des Kanals.
    @MainActor @Test func outputAndSourceAreExplicitCases() throws {
        let midi = TrackData(name: "M")
        let mj = String(decoding: try JSONEncoder().encode(midi), as: UTF8.self)
        #expect(mj.contains("\"output\":{\"midi\":{}}"))
        // Ohne `output` (Format vor v1.16.0): lädt nicht.
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(midi)) as! [String: Any]
        obj["output"] = nil
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(TrackData.self, from: JSONSerialization.data(withJSONObject: obj))
        }
        obj["output"] = ["midi": [String: Any](), "instrument": UUID().uuidString]
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(TrackData.self, from: JSONSerialization.data(withJSONObject: obj))
        }

        var loopCh = InstrumentChannelData(name: "L", source: .audioLoop(AudioLoopSettings()))
        loopCh.instrument = PluginRef(description: AudioComponentDescription(), name: "X")
        #expect(loopCh.instrument == nil, "Loop-Kanal bekommt kein Instrument")
        let empty = InstrumentChannelData(name: "I")
        let back = try JSONDecoder().decode(InstrumentChannelData.self, from: JSONEncoder().encode(empty))
        #expect(back.source == .instrument(nil))
        #expect(try JSONDecoder().decode(InstrumentChannelData.self, from: JSONEncoder().encode(loopCh)).source.isAudioLoop)

        let engine = SequencerEngine()
        let loop = try #require(engine.rack.addAudioLoopChannel(name: "L"))
        let inst = try #require(engine.rack.addChannel(name: "I"))
        #expect(engine.rack.route(for: .instrument(loop)) == -1, "Notenspur erreicht keinen Loop-Kanal")
        #expect(engine.rack.route(for: .audioLoop(inst)) == -1, "Loop-Spur erreicht keinen Instrumentenkanal")
        #expect(engine.rack.route(for: .audioLoop(loop)) >= 0)
        #expect(engine.rack.route(for: .instrument(inst)) >= 0)
    }

    /// Spur anlegen: Kanal + Spur in allen Patterns; Material übersteht Speichern/Laden;
    /// der Tick-Thread meldet das Aktivfenster (gemutet nicht) und setzt Taktanker.
    @MainActor @Test func audioLoopTrackPresetRoundTripAndTickWindow() throws {
        let engine = SequencerEngine()
        let placed = engine.addAudioLoopTrack()
        #expect(placed.count == engine.patterns.count)
        let td = try #require(placed.first { $0.pattern === engine.currentPattern }?.track)
        let ch = try #require(td.instrumentID)
        #expect(td.isAudioLoop && engine.rack.channel(ch)?.audioLoop != nil)
        let core = try #require(engine.rack.loopCore(for: ch))

        let st = try #require(AudioLoopStorage(bars: 1, sampleRate: 48_000, bpm: 120))
        for i in 0..<st.frames { st.left[i] = 0.3; st.right[i] = 0.3 }
        engine.rack._setLoopStorage(st, for: ch)
        #expect(core.hasMaterial)
        let data = try #require(engine.saveData())

        let other = SequencerEngine()
        #expect(other.loadData(data))
        let ch2 = try #require(other.currentPattern.tracks.first { $0.isAudioLoop }?.instrumentID)
        #expect(ch2 == ch)
        let core2 = try #require(other.rack.loopCore(for: ch2))
        #expect(core2.hasMaterial)
        #expect(other.rack.loopFrames(ch2) > 0)

        // Tick: Fenster und Anker.
        engine.setClockMode(.external)
        engine.play()
        defer { engine.stop() }
        let t0 = mach_absolute_time() + 5_000_000_000
        engine._rt3aDriveOneExternalTick(at: t0)
        #expect(core._activeWindow.0 == t0 && core._activeWindow.1 > t0)
        #expect(engine.rack.barClock.window().anchor(at: t0).bar == 0)
        // Gemutet: das Fenster wächst nicht weiter.
        ModelWriter().apply(.setMuted(trackID: td.id, old: false, new: true), to: td, undoManager: nil)
        engine.publishSnapshot()
        let before = core._activeWindow.1
        engine._rt3aDriveOneExternalTick(at: t0 + 20_000_000)
        #expect(core._activeWindow.1 == before)
    }
}
