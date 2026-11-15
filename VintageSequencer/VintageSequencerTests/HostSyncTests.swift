import Testing
import Foundation
import AVFoundation
import Atomics
@testable import VintageSequencer

// v1.17.2 — Host-Takt für Plug-ins: Tempo, Position und Transport über
// `musicalContextBlock`/`transportStateBlock`.
// v1.17.6 — Zeitvertrag (Codex A17-01–03, A17-09): Ende im Tick, Sample-Zeitleiste unabhängig
// vom Tempo, Anker gelten ab ihrem Zeitpunkt, Sitzungsbindung, Nutzungsbeleg im Renderpfad.

private let ticksPerSecond: Double = {
    var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
    return 1_000_000_000.0 * Double(tb.denom) / Double(tb.numer)
}()
private func secs(_ s: Double) -> UInt64 { UInt64(s * ticksPerSecond) }
private func near(_ a: Double, _ b: Double, _ eps: Double = 1e-6) -> Bool { abs(a - b) < eps }

struct HostSyncTests {

    /// Position folgt den Pulsankern; vor dem ersten Puls und nach dem Ende steht der
    /// Transport, die Position bleibt am Ende stehen; im Stillstand gilt das Leerlauftempo.
    @Test func beatPositionFollowsAnchorsAndStops() {
        let sync = HostSync()
        sync.setIdleTempo(90)
        #expect(sync.state(at: 1_000) == .init(tempo: 90, beat: 0, moving: false), "vor jeder Sitzung")

        let t0: UInt64 = secs(100)
        sync.beginSession(1)
        sync.publish(pulse: 0, host: t0, bpm: 120)
        #expect(sync.state(at: t0 - secs(0.01)).moving == false, "erster Puls noch nicht erreicht")
        #expect(sync.state(at: t0).moving && sync.state(at: t0).beat == 0)
        #expect(near(sync.state(at: t0 + secs(0.5)).beat, 1.0), "120 BPM: 0,5 s = 1 Viertel")

        sync.publish(pulse: 24, host: t0 + secs(0.5), bpm: 60)          // Tempowechsel auf dem Puls
        #expect(near(sync.state(at: t0 + secs(1.0)).beat, 1.5), "60 BPM ab Viertel 1")
        #expect(sync.state(at: t0 + secs(1.0)).tempo == 60)

        sync.stop(at: t0 + secs(1.5))
        let after = sync.state(at: t0 + secs(3))
        #expect(near(after.beat, 2.0) && !after.moving && after.tempo == 90)

        sync.beginSession(2)                                              // neue Sitzung: von vorn
        sync.publish(pulse: 0, host: t0 + secs(10), bpm: 120)
        let fresh = sync.state(at: t0 + secs(10))
        #expect(fresh.beat == 0 && fresh.moving && fresh.seconds == 0 && fresh.session == 2)
    }

    /// A17-02: Die Sample-Zeitleiste ist verstrichene Zeit seit dem Start — ein Tempowechsel
    /// rechnet die Vergangenheit nicht um, der Tempo-Regler im Stillstand verschiebt nichts.
    @Test func sampleTimelineIgnoresTempo() {
        let sync = HostSync()
        let t0: UInt64 = secs(300)
        sync.beginSession(1)
        sync.publish(pulse: 0, host: t0, bpm: 120)
        sync.publish(pulse: 24, host: t0 + secs(0.5), bpm: 60)          // nach 1 Viertel auf 60 BPM
        let s = sync.state(at: t0 + secs(0.5))
        #expect(near(s.seconds, 0.5) && near(s.beat, 1.0), "0,5 s = 24 000 Samples bei 48 kHz, nicht 48 000")
        sync.stop(at: t0 + secs(0.75))
        let frozen = sync.state(at: t0 + secs(5)).seconds
        sync.setIdleTempo(200)
        #expect(near(frozen, 0.75) && near(sync.state(at: t0 + secs(9)).seconds, 0.75))
    }

    /// A17-03: Vorausgeplante Anker gelten erst ab ihrem Zeitpunkt; vor dem Start steht der
    /// Transport auch dann, wenn schon mehrere Pulse vorausgeplant sind.
    @Test func advanceAnchorsApplyAtTheirBoundary() {
        let sync = HostSync()
        let t0: UInt64 = secs(500)
        sync.beginSession(1)
        let pulse = secs(0.5) / 24                                        // 120 BPM
        for p in 0..<4 { sync.publish(pulse: p, host: t0 + UInt64(p) * pulse, bpm: 120) }
        sync.publish(pulse: 4, host: t0 + 4 * pulse, bpm: 60)            // Tempowechsel bei Puls 4
        let before = sync.state(at: t0 - 1)
        #expect(!before.moving && before.beat == 0, "vor dem Start trotz Vorlauf")
        let mid = sync.state(at: t0 + 2 * pulse + pulse / 2)
        #expect(mid.moving && mid.tempo == 120 && near(mid.beat, 2.5 / 24, 1e-4), "Anker 2 gilt, nicht 4")
        #expect(sync.state(at: t0 + 4 * pulse).tempo == 60, "ab der Grenze das neue Tempo")
    }

    /// A17-01/Akzeptanz 5: Das Ende wird nur früher; ein Stop für eine andere Sitzung wirkt nicht.
    @Test func endOnlyMovesEarlierAndIsSessionBound() {
        let sync = HostSync()
        let t0: UInt64 = secs(700)
        sync.beginSession(7)
        sync.publish(pulse: 0, host: t0, bpm: 120)
        sync.end(at: t0 + secs(1))
        sync.stop(at: t0 + secs(2))                                       // später: ändert nichts
        #expect(near(sync.state(at: t0 + secs(3)).seconds, 1.0))
        sync.beginSession(8)
        sync.publish(pulse: 0, host: t0 + secs(10), bpm: 120)
        sync.stop(at: t0 + secs(1), session: 7)                           // verspätete Nachbereitung
        #expect(sync.state(at: t0 + secs(11)).moving, "alte Sitzung stoppt die neue nicht")
        sync.stop(at: t0 + secs(12), session: 8)
        #expect(!sync.state(at: t0 + secs(12)).moving)
    }

    /// Die Blöcke rechnen mit der Blockzeit des Render-Observers plus Latenzausgleich;
    /// `changed` meldet Lauf- und Sitzungswechsel; Nutzung wird gezählt.
    @Test func hostBlocksReportTempoBeatAndTransport() {
        let sync = HostSync()
        let binding = HostBinding()
        binding.ticksPerFrame.store((ticksPerSecond / 48_000).bitPattern, ordering: .relaxed)
        let advance = ManagedAtomic<UInt64>(0)
        let (music, transport) = sync.blocks(binding: binding, advance: { advance.load(ordering: .relaxed) })
        let t0: UInt64 = secs(200)
        sync.beginSession(1)
        sync.publish(pulse: 0, host: t0, bpm: 120)
        binding.renderHost.store(t0 + secs(0.25), ordering: .relaxed)    // halbe Viertel

        var tempo = 0.0, num = 0.0, den = 0, beat = 0.0, toNext = 0, downbeat = -1.0
        #expect(music(&tempo, &num, &den, &beat, &toNext, &downbeat))
        #expect(tempo == 120 && num == 4 && den == 4 && near(beat, 0.5) && downbeat == 0)
        #expect(abs(toNext - 12_000) <= 1, "0,5 Viertel bei 120 BPM = 0,25 s = 12 000 Samples")

        advance.store(secs(0.25), ordering: .relaxed)                    // Latenzausgleich
        #expect(music(&tempo, &num, &den, &beat, &toNext, &downbeat) && near(beat, 1.0))

        var flags: AUHostTransportStateFlags = [], pos = 0.0, cs = 0.0, ce = 0.0
        #expect(transport(&flags, &pos, &cs, &ce))
        #expect(flags.contains(.moving) && flags.contains(.changed) && abs(pos - 24_000) <= 1)
        _ = transport(&flags, &pos, &cs, &ce)
        #expect(flags.contains(.moving) && !flags.contains(.changed))
        sync.stop(at: t0 + secs(0.1))
        _ = transport(&flags, &pos, &cs, &ce)
        #expect(!flags.contains(.moving) && flags.contains(.changed) && abs(pos - 4_800) <= 1)
        sync.beginSession(2)                                              // neue Sitzung: .changed
        sync.publish(pulse: 0, host: t0 + secs(0.4), bpm: 120)
        _ = transport(&flags, &pos, &cs, &ce)
        #expect(flags.contains(.changed) && flags.contains(.moving) && abs(pos - 4_800) <= 1)
        // Nil-Zeiger (Plug-in fragt nur einen Teil ab) sind erlaubt.
        #expect(music(nil, nil, nil, nil, nil, nil) && transport(nil, nil, nil, nil))
        #expect(binding.musicCalls.load(ordering: .relaxed) == 3 && binding.transportCalls.load(ordering: .relaxed) == 5)
    }

    /// Der Tick veröffentlicht jeden Puls auf seinem geplanten Zeitpunkt; Stop beendet den
    /// Lauf; das Leerlauftempo folgt dem Tempo-Regler.
    @MainActor @Test func tickPublishesPulsesForPlugins() {
        let engine = SequencerEngine()
        engine.bpm = 100
        engine.publishSnapshot()
        #expect(engine.rack.hostSync.state(at: mach_absolute_time()).tempo == 100)
        engine.setClockMode(.external)
        engine.play()
        let t0 = mach_absolute_time() + secs(0.2)
        engine._rt3aDriveOneExternalTick(at: t0)
        engine._rt3aDriveOneExternalTick(at: t0 + secs(0.025))
        let st = engine.rack.hostSync.state(at: t0 + secs(0.025))
        #expect(st.moving && near(st.beat, 1.0 / 24) && st.tempo == 100)
        engine.stop()
        #expect(!engine.rack.hostSync.state(at: mach_absolute_time() + secs(1)).moving)
    }

    /// A17-01: Songende ohne Main — der Tick stoppt den Plug-in-Transport auf dem Endpuls;
    /// weitere Ticks (Main hängt 250 ms/1 s) bewegen ihn nicht weiter; Main stoppt danach nichts
    /// Neues; ein neuer Start beginnt bei null und wird von der alten Nachbereitung nicht gestoppt.
    @MainActor @Test(arguments: [250, 1000])
    func songEndStopsPluginTransportInTick(stallMs: Int) {
        let engine = SequencerEngine()
        engine.replaceSong(Song(scenes: [SongScene(pattern: 0, bars: 1)], enabled: true, loops: false))
        engine.setClockMode(.external)
        engine.play()
        let gap: UInt64 = 20_000_000
        let t0 = mach_absolute_time() + 5_000_000_000
        let end = t0 + 96 * gap
        let extra = UInt64(stallMs) * 1_000_000 / gap + 1
        for p in 0...(96 + Int(extra)) { engine._rt3aDriveOneExternalTick(at: t0 + UInt64(p) * gap) }
        let sync = engine.rack.hostSync
        let beforeEnd = sync.state(at: end - 1), atEnd = sync.state(at: end)
        let later = sync.state(at: end + UInt64(stallMs) * 1_000_000)
        #expect(beforeEnd.moving && !atEnd.moving && !later.moving)
        // Letzter Anker ist Puls 95; das Ende liegt eine Pulslänge dahinter (Tempo des Ankers).
        let gapSeconds = Double(gap) / ticksPerSecond
        let expected = 95.0 / 24 + gapSeconds * beforeEnd.tempo / 60
        #expect(near(atEnd.beat, expected, 1e-6) && near(later.beat, atEnd.beat) && near(later.seconds, atEnd.seconds),
                "Position bleibt am Ende: \(later.beat) statt \(expected)")
        engine._stopIfSongEnded(now: end + UInt64(stallMs) * 1_000_000)
        #expect(!engine.isPlaying)
        #expect(near(sync.state(at: end + secs(5)).beat, later.beat))

        engine.play()                                                     // neue Sitzung
        let t1 = mach_absolute_time() + 5_000_000_000
        engine._rt3aDriveOneExternalTick(at: t1)
        engine._rt3aDriveOneExternalTick(at: t1 + gap)
        sync.stop(at: end, session: sync.currentSession &- 1)            // verspätete alte Nachbereitung
        let fresh = sync.state(at: t1 + gap)
        #expect(fresh.moving && near(fresh.beat, 1.0 / 24, 1e-3))
        engine.stop()
    }
}

/// Echte Plug-ins (Apple DLS, AUDelay, ausgelagert): beide tragen die Host-Blöcke, und ihr
/// Renderpfad ruft sie auf (A17-09: Nutzungsbeleg statt Getter-Prüfung).
@Suite(.serialized) struct HostSyncRealPluginTests {
    @MainActor @Test func loadedInstrumentAndEffectUseHostBlocks() async throws {
        let rack = InstrumentRack()
        let id = try #require(rack.addChannel(name: "Sync")); rack.setMuted(id, true)
        rack.setInstrument(PluginRef(description: AudioComponentDescription(
            componentType: kAudioUnitType_MusicDevice, componentSubType: kAudioUnitSubType_DLSSynth,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0),
            name: "DLSMusicDevice"), for: id)
        rack.addEffect(PluginRef(description: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_Delay,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0),
            name: "AUDelay"), to: id)
        let deadline = Date().addingTimeInterval(60)
        while (rack.instrumentStatus[id] == .loading || rack.effectStatus[id]?.first == .loading), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try #require(rack.instrumentStatus[id] == .ready && rack.effectStatus[id]?.first == .ready, "DLS/AUDelay nicht ladbar")
        // Rendern lassen; die Zähler belegen Aufrufe aus dem Renderpfad.
        let t0 = Date()
        var calls = rack.hostBindingCalls(id)
        while (calls?.instrument ?? 0) == 0 || (calls?.effects.first ?? 0) == 0, Date().timeIntervalSince(t0) < 10 {
            try await Task.sleep(nanoseconds: 50_000_000)
            calls = rack.hostBindingCalls(id)
        }
        let inst = rack._liveInstrument(id)?.auAudioUnit
        let report = "calls=\(String(describing: calls)) waited_s=\(Date().timeIntervalSince(t0))"
            + " instPreRenders=\(rack._instrumentPreRenders(id) ?? -1)"
            + " instReinstalls=\(rack._instrumentHostReinstalls(id) ?? -1)"
            + " instGetterNil=\(inst?.musicalContextBlock == nil) inProcess=\(inst?.isLoadedInProcess ?? false)"
            + " rr=\(inst?.renderResourcesAllocated ?? false) maxFrames=\(inst?.maximumFramesToRender ?? 0)\n"
        try? report.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("fof-hostsync-real.txt"),
                          atomically: true, encoding: .utf8)
        #expect((calls?.instrument ?? 0) > 0, "Instrument ruft die Host-Blöcke nicht auf: \(report)")
        #expect((calls?.effects.first ?? 0) > 0, "Effekt ruft die Host-Blöcke nicht auf: \(report)")
    }
}
