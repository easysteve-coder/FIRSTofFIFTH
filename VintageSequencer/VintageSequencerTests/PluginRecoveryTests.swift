import Testing
import Foundation
import AVFoundation
@testable import VintageSequencer

// v1.18.32 — Wiederanlauf nach Absturz des Plug-in-Prozesses. Gemessen (Bericht
// `.agent_handoff/latest_claude_shortcircuit_test.md`): Shortcircuit XT 0.9.316 bringt beim Abbau
// den gemeinsamen AU-Host-Prozess zum Absturz; ein unbeteiligter Kanal (DLSMusicDevice) blieb
// danach still. Hier: die Invalidierungsmeldung eines geladenen Plug-ins lädt genau diesen Platz
// neu, mit dem Zustand aus dem Modell; ein erneuter Absturz kurz danach gibt auf.

@MainActor @Suite(.serialized) struct PluginRecoveryTests {

    static let instrument = PluginRef(description: AudioComponentDescription(
        componentType: kAudioUnitType_MusicDevice, componentSubType: 0x52435652,      // 'RCVR'
        componentManufacturer: 0x54455354, componentFlags: 0, componentFlagsMask: 0),
        name: "Recover", state: Data([1, 2, 3]))
    static let effect = PluginRef(description: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: 0x52434658,          // 'RCFX'
        componentManufacturer: 0x54455354, componentFlags: 0, componentFlagsMask: 0), name: "RecoverFX")

    /// Meldung wie vom System: von einer fremden Warteschlange, Main bekommt sie danach.
    /// Main wartet nie blockierend (v1.18.20): ein anderer Beobachter könnte Main brauchen.
    private func invalidate(_ unit: AVAudioUnit) async throws {
        let au = unit.auAudioUnit
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                NotificationCenter.default.post(name: InstrumentRack.invalidationName, object: au)
                c.resume()
            }
        }
    }

    /// Wartet auf Main, bis `done` gilt (Volllauf: Main kann Sekunden belegt sein).
    /// Frist in Prüfschritten, nicht in Uhrzeit (v1.18.37): war Main länger belegt als eine
    /// Uhrzeitfrist, lief sie ab, ohne dass der fällige Wiederanlauf-Durchlauf je drankam.
    private func waitUntil(_ done: () -> Bool) async throws {
        for _ in 0..<1000 {
            if done() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Gibt Main Gelegenheit, eine bereits gestellte Meldung abzuarbeiten (für „nichts passiert").
    private func drainMain() async {
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
    }

    @Test func instrumentIsReloadedOnceThenGivesUp() async throws {
        let rack = InstrumentRack()
        rack.recoveryLockout = 3600
        var loads: [PluginRef] = []
        rack._instantiateOverride = { ref, done in loads.append(ref); done(AVAudioUnitSampler()) }
        defer { rack._instantiateOverride = nil }
        let id = try #require(rack.addChannel(name: "A"))
        rack.setMuted(id, true)
        rack.setInstrument(Self.instrument, for: id)
        let first = try #require(rack._liveInstrument(id))
        #expect(loads.count == 1)

        try await invalidate(first)
        try await waitUntil { loads.count == 2 }
        let second = try #require(rack._liveInstrument(id))
        #expect(second !== first, "neue Instanz")
        #expect(loads.count == 2 && loads[1].state == Self.instrument.state, "Zustand aus dem Modell")
        #expect(rack.instrumentStatus[id] == .ready)
        #expect(rack.channel(id)?.instrument?.name == "Recover", "Kanalbelegung unverändert")

        // Eine späte zweite Meldung der alten Instanz trifft nichts mehr.
        try await invalidate(first)
        await drainMain()
        #expect(rack._liveInstrument(id) === second && loads.count == 2)

        // Stürzt die neue Instanz gleich wieder ab: aufgeben statt Schleife.
        try await invalidate(second)
        try await waitUntil { rack.instrumentStatus[id] == .missing }
        #expect(loads.count == 2)
        #expect(rack._liveInstrument(id) == nil && rack.instrumentStatus[id] == .missing)
        #expect(rack.channel(id)?.instrument != nil, "Belegung bleibt für Speichern/Neuladen")
    }

    @Test func effectIsReloadedInPlace() async throws {
        let rack = InstrumentRack()
        var loads: [String] = []
        rack._instantiateOverride = { ref, done in
            loads.append(ref.name)
            done(ref.name == "RecoverFX" ? AVAudioUnitDelay() : AVAudioUnitSampler())
        }
        defer { rack._instantiateOverride = nil }
        let id = try #require(rack.addChannel(name: "B"))
        rack.setMuted(id, true)
        rack.setInstrument(Self.instrument, for: id)
        rack.addEffect(Self.effect, to: id)
        rack.addEffect(Self.effect, to: id)
        let inst = try #require(rack._liveInstrument(id))
        let fx0 = try #require(rack._liveEffect(id, at: 0))
        let fx1 = try #require(rack._liveEffect(id, at: 1))

        try await invalidate(fx1)
        try await waitUntil { loads.count == 4 }
        let fx1b = try #require(rack._liveEffect(id, at: 1))
        #expect(fx1b !== fx1 && rack._liveEffect(id, at: 0) === fx0, "nur der betroffene Platz")
        #expect(rack._liveInstrument(id) === inst)
        #expect(rack.effectStatus[id] == [.ready, .ready])
        #expect(rack.channel(id)?.effects.count == 2)
        #expect(loads == ["Recover", "RecoverFX", "RecoverFX", "RecoverFX"])
    }

    /// Absturz des gemeinsamen Prozesses: alle Kanäle melden sich, alle laufen wieder.
    @Test func allChannelsOfTheHostProcessRecover() async throws {
        let rack = InstrumentRack()
        rack._instantiateOverride = { _, done in done(AVAudioUnitSampler()) }
        defer { rack._instantiateOverride = nil }
        let a = try #require(rack.addChannel(name: "A")), b = try #require(rack.addChannel(name: "B"))
        for id in [a, b] { rack.setMuted(id, true); rack.setInstrument(Self.instrument, for: id) }
        let ua = try #require(rack._liveInstrument(a)), ub = try #require(rack._liveInstrument(b))
        try await invalidate(ua)
        try await invalidate(ub)
        // Nach dem sofortigen Abbau sind beide nil: auf zwei neue Instanzen warten (Codex R2-02).
        try await waitUntil {
            rack._liveInstrument(a).map { $0 !== ua } == true && rack._liveInstrument(b).map { $0 !== ub } == true
        }
        #expect(rack._liveInstrument(a) != nil && rack._liveInstrument(a) !== ua)
        #expect(rack._liveInstrument(b) != nil && rack._liveInstrument(b) !== ub)
        #expect(rack.instrumentStatus[a] == .ready && rack.instrumentStatus[b] == .ready)
    }

    /// v1.18.38 — Fehlergrenze: wirft `connect` (tote Einheit, Meldung noch aus), endet FoF nicht.
    /// Der Kanal wird abgebaut, alle seine Plug-ins laden im Durchlauf nach.
    @Test func connectFaultTearsDownTheChannelAndReloads() async throws {
        let rack = InstrumentRack()
        rack.recoveryLockout = 3600
        rack.recoveryQuietTime = 0.05
        var units: [AVAudioUnit] = []
        rack._instantiateOverride = { ref, done in
            let u: AVAudioUnit = ref.name == "RecoverFX" ? AVAudioUnitDelay() : AVAudioUnitSampler()
            units.append(u); done(u)
        }
        var faulty: AVAudioNode?
        FoFConnectFaultHook = { $0 === faulty }             // wirft im @try von FoFEngineConnect
        defer { rack._instantiateOverride = nil; FoFConnectFaultHook = nil }
        let id = try #require(rack.addChannel(name: "A"))
        rack.setMuted(id, true)
        rack.setInstrument(Self.instrument, for: id)
        let inst = try #require(rack._liveInstrument(id))
        faulty = inst                                       // Instrument „stirbt" unbemerkt
        rack.addEffect(Self.effect, to: id)                 // Effekt verbindet den Kanal neu → wirft

        try await waitUntil { units.count == 4 }            // Instrument + Effekt neu geladen
        // Der Durchlauf lädt erst die Effekte, dann das Instrument.
        #expect(rack._liveEffect(id, at: 0) === units[2] && rack._liveInstrument(id) === units[3])
        #expect(inst.engine == nil, "tote Einheit abgebaut")
        #expect(rack.instrumentStatus[id] == .ready && rack.effectStatus[id] == [.ready])
        #expect(!rack.isRecoveringPlugins)
    }

    /// Scheitert das Verbinden gleich wieder: Sperre greift, Platz „fehlt", keine Schleife.
    @Test func repeatedConnectFaultGivesUp() async throws {
        let rack = InstrumentRack()
        rack.recoveryLockout = 3600
        rack.recoveryQuietTime = 0.05
        var loads = 0
        var samplers: [AVAudioNode] = []
        rack._instantiateOverride = { _, done in loads += 1; let u = AVAudioUnitSampler(); samplers.append(u); done(u) }
        FoFConnectFaultHook = { n in samplers.contains { $0 === n } }
        defer { rack._instantiateOverride = nil; FoFConnectFaultHook = nil }
        let id = try #require(rack.addChannel(name: "A"))
        rack.setMuted(id, true)
        rack.setInstrument(Self.instrument, for: id)
        try await waitUntil { rack.instrumentStatus[id] == .missing }
        #expect(rack.instrumentStatus[id] == .missing)
        #expect(loads == 2, "ein Nachladen, dann Sperre")
        #expect(rack._liveInstrument(id) == nil)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(loads == 2)
    }

    /// Scheitert nach der Ausnahme auch das Aufräumen, ist der Zustand der Engine unbekannt:
    /// der Graph geht außer Betrieb, kein Nachladen, kein Start, Fehler sichtbar (Codex R38-02).
    @Test func failedCleanupTakesTheGraphOutOfService() async throws {
        let rack = InstrumentRack()
        rack.recoveryLockout = 3600
        rack.recoveryQuietTime = 0.05
        var loads = 0
        var faulty: [AVAudioNode] = []
        rack._instantiateOverride = { _, done in loads += 1; let u = AVAudioUnitSampler(); faulty.append(u); done(u) }
        FoFConnectFaultHook = { n in faulty.contains { $0 === n } }
        FoFCleanupFaultHook = { n in faulty.contains { $0 === n } }      // Lösen der toten Einheit wirft
        defer { rack._instantiateOverride = nil; FoFConnectFaultHook = nil; FoFCleanupFaultHook = nil }
        let id = try #require(rack.addChannel(name: "A"))
        rack.setMuted(id, true)
        rack.setInstrument(Self.instrument, for: id)
        #expect(rack.engineError != nil, "Fehler sichtbar")
        #expect(!rack.isRecoveringPlugins, "kein Wiederanlauf auf unbekanntem Zustand")
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(loads == 1, "nichts nachgeladen")
        #expect(!rack.isAudioRunning)
    }

    /// Außer Betrieb heißt: kein Weg baut mehr um — auch kein Geräte-Neuaufbau und kein
    /// Durchlauf, und ein gesunder Kanal hält niemanden zu neuem Verbinden an (Codex R38-R2-01).
    @Test func outOfServiceGraphIsNeverRebuilt() async throws {
        let rack = InstrumentRack()
        rack.recoveryLockout = 3600
        rack.recoveryQuietTime = 0.05
        var faulty: AVAudioNode?
        rack._instantiateOverride = { _, done in done(AVAudioUnitSampler()) }
        var connectsAfter = 0, cleanupsAfter = 0
        var faulted = false
        FoFConnectFaultHook = { n in if faulted { connectsAfter += 1 }; return n === faulty }
        FoFCleanupFaultHook = { n in if faulted { cleanupsAfter += 1 }; return n === faulty }
        defer { rack._instantiateOverride = nil; FoFConnectFaultHook = nil; FoFCleanupFaultHook = nil }
        let b = try #require(rack.addChannel(name: "B")), a = try #require(rack.addChannel(name: "A"))
        for id in [a, b] { rack.setMuted(id, true) }
        rack.setInstrument(Self.instrument, for: b)                     // gesunder Kanal
        let engine = try #require(rack._liveInstrument(b)?.engine)
        rack._instantiateOverride = { _, done in let u = AVAudioUnitSampler(); faulty = u; done(u) }
        rack.setInstrument(Self.instrument, for: a)                     // Verbinden und Lösen werfen
        #expect(rack.engineError != nil)
        faulted = true
        let startsBefore = rack._graphStarts
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(connectsAfter == 0 && cleanupsAfter == 0, "kein Umbau nach der Stilllegung")
        #expect(rack._graphStarts == startsBefore, "kein Start")
        #expect(!rack.isRecoveringPlugins)
        #expect(rack.instrumentStatus[a] == .missing, "kein „lädt“ ohne künftigen Abschluss")
    }

    /// Mehrere Effekte, das Lösen des ersten scheitert: die übrigen werden nicht mehr vorgemerkt,
    /// kein Durchlauf, keine Ladeversuche (Codex R38-R2-02).
    @Test func failedCleanupMidChannelStopsRecovery() async throws {
        let rack = InstrumentRack()
        rack.recoveryLockout = 3600
        rack.recoveryQuietTime = 0.05
        var loads = 0
        rack._instantiateOverride = { ref, done in
            loads += 1
            done(ref.name == "RecoverFX" ? AVAudioUnitDelay() : AVAudioUnitSampler())
        }
        var faulty: AVAudioNode?
        FoFConnectFaultHook = { $0 === faulty }
        FoFCleanupFaultHook = { $0 === faulty }
        defer { rack._instantiateOverride = nil; FoFConnectFaultHook = nil; FoFCleanupFaultHook = nil }
        let id = try #require(rack.addChannel(name: "A"))
        rack.setMuted(id, true)
        rack.setInstrument(Self.instrument, for: id)
        rack.addEffect(Self.effect, to: id)
        rack.addEffect(Self.effect, to: id)
        faulty = try #require(rack._liveEffect(id, at: 0))
        rack.addEffect(Self.effect, to: id)                             // verbindet neu → wirft
        let loadsAtFault = loads
        #expect(rack.engineError != nil)
        #expect(!rack.isRecoveringPlugins)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(loads == loadsAtFault, "keine Ladeversuche nach der Stilllegung")
        #expect(!(rack.effectStatus[id] ?? []).contains(.loading))
        #expect(rack.instrumentStatus[id] != .loading)
    }

    /// Scheitert auch das Anhalten, sagt die Meldung es, und die Anzeige folgt dem echten Zustand.
    @Test func failedStopIsReportedNotHidden() async throws {
        let rack = InstrumentRack()
        rack.recoveryQuietTime = 0.05
        var faulty: AVAudioNode?
        rack._instantiateOverride = { _, done in done(AVAudioUnitSampler()) }
        FoFConnectFaultHook = { $0 === faulty }
        FoFCleanupFaultHook = { $0 === faulty }
        FoFStopFaultHook = { true }
        defer { rack._instantiateOverride = nil; FoFConnectFaultHook = nil; FoFCleanupFaultHook = nil; FoFStopFaultHook = nil }
        let b = try #require(rack.addChannel(name: "B")), a = try #require(rack.addChannel(name: "A"))
        for id in [a, b] { rack.setMuted(id, true) }
        rack.setInstrument(Self.instrument, for: b)
        // Ohne laufende Engine prüft der Test den Stop-Fehler nicht: dann rot statt still grün.
        try #require(rack.isAudioRunning, "Test braucht eine laufende Engine (Ausgabegerät)")
        rack._instantiateOverride = { _, done in let u = AVAudioUnitSampler(); faulty = u; done(u) }
        rack.setInstrument(Self.instrument, for: a)
        let error = try #require(rack.engineError)
        #expect(error.contains("stop"), "gescheitertes Anhalten genannt")
        #expect(rack.isAudioRunning == rack._graphIsRunning, "Anzeige = echter Zustand")
        FoFStopFaultHook = nil
    }

    /// Stilllegung mitten im Nachladen: der erste Ladeabschluss legt still, die übrigen Plätze
    /// laden nicht mehr und bleiben nicht auf „lädt" (Codex R38-R3-03).
    @Test func outOfServiceDuringReloadStopsTheLoop() async throws {
        let rack = InstrumentRack()
        rack.recoveryLockout = 3600
        rack.recoveryQuietTime = 0.05
        var loads = 0
        var poison = false
        var faulty: [AVAudioNode] = []
        rack._instantiateOverride = { ref, done in
            loads += 1
            let u: AVAudioUnit = ref.name == "RecoverFX" ? AVAudioUnitDelay() : AVAudioUnitSampler()
            if poison { faulty.append(u) }
            done(u)
        }
        FoFConnectFaultHook = { n in faulty.contains { $0 === n } }
        FoFCleanupFaultHook = { n in faulty.contains { $0 === n } }
        defer { rack._instantiateOverride = nil; FoFConnectFaultHook = nil; FoFCleanupFaultHook = nil }
        let id = try #require(rack.addChannel(name: "A"))
        rack.setMuted(id, true)
        rack.setInstrument(Self.instrument, for: id)
        rack.addEffect(Self.effect, to: id)
        rack.addEffect(Self.effect, to: id)
        let fx0 = try #require(rack._liveEffect(id, at: 0)), fx1 = try #require(rack._liveEffect(id, at: 1))
        poison = true                                           // jede neue Instanz ist „tot"
        try await invalidate(fx0)
        try await invalidate(fx1)
        try await waitUntil { rack.engineError != nil }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(loads == 4, "nur der erste Nachladeauftrag, dann Stillstand")
        #expect(!(rack.effectStatus[id] ?? []).contains(.loading))
        #expect(!rack.isRecoveringPlugins)
    }

    /// Kanal entfernen, das Lösen seines Plug-ins scheitert: Stilllegung, kein Absturz, und
    /// danach baut nichts mehr (Codex R38-R3-01).
    @Test func removingAChannelWithAnUnremovablePluginStopsAtTheFault() async throws {
        let rack = InstrumentRack()
        var faulty: AVAudioNode?
        rack._instantiateOverride = { _, done in done(AVAudioUnitSampler()) }
        var cleanupsAfter = 0, faulted = false
        FoFCleanupFaultHook = { n in if faulted { cleanupsAfter += 1 }; return n === faulty }
        defer { rack._instantiateOverride = nil; FoFCleanupFaultHook = nil }
        let a = try #require(rack.addChannel(name: "A")), b = try #require(rack.addChannel(name: "B"))
        for id in [a, b] { rack.setMuted(id, true); rack.setInstrument(Self.instrument, for: id) }
        faulty = try #require(rack._liveInstrument(a))
        let gainA = try #require(rack._liveGain(a))
        #expect(gainA.engine != nil)
        rack.removeChannel(a)
        #expect(rack.engineError != nil)
        #expect(gainA.engine != nil, "nach dem Fehler keine direkten Detaches über die gespeicherte Engine")
        faulted = true
        rack.removeChannel(b)                                   // nur noch Modell, kein Umbau
        #expect(cleanupsAfter == 0)
        #expect(rack.channel(b) == nil)
    }

    /// v1.18.37 — iMac-Absturz: die Meldung eines Effekts kam vor der seines Instruments; der
    /// Wiederanlauf verband den Effekt mit dem toten Instrument, `connect` warf, FoF war weg.
    /// Jetzt löst jede Meldung ihre Einheit sofort; verbunden und geladen wird erst nach der
    /// Ruhezeit, und nie mit einer gemeldeten Einheit. Eine in der Zwischenzeit geladene
    /// Instanz bleibt unberührt (Codex-Review 1.18.37, Befund 1).
    @Test func deadUnitsLeaveTheEngineAtOnceAndAreNeverWired() async throws {
        let rack = InstrumentRack()
        rack.recoveryLockout = 3600
        rack.recoveryQuietTime = 1.0
        var loads: [String] = []
        rack._instantiateOverride = { ref, done in
            loads.append(ref.name)
            done(ref.name == "RecoverFX" ? AVAudioUnitDelay() : AVAudioUnitSampler())
        }
        var dead: [AVAudioNode] = []
        var wiredDead = false
        rack._rewireObserver = { chain in
            if chain.contains(where: { n in dead.contains { $0 === n } }) { wiredDead = true }
        }
        defer { rack._instantiateOverride = nil; rack._rewireObserver = nil }
        let a = try #require(rack.addChannel(name: "A")), c = try #require(rack.addChannel(name: "C"))
        for id in [a, c] { rack.setMuted(id, true) }
        rack.setInstrument(Self.instrument, for: a)
        rack.addEffect(Self.effect, to: a)
        let ia = try #require(rack._liveInstrument(a)), fx = try #require(rack._liveEffect(a, at: 0))
        dead = [ia, fx]

        try await invalidate(fx)                        // Effekt meldet sich zuerst
        try await waitUntil { rack._liveEffect(a, at: 0) == nil }
        #expect(fx.engine == nil, "toter Effekt sofort gelöst")
        #expect(rack.effectStatus[a] == [.loading], "Status sofort zutreffend (R2-03)")
        #expect(rack.isRecoveringPlugins)

        // Zwischen den beiden Meldungen lädt der Nutzer ein Instrument in C (Codex R2, B1).
        rack.setInstrument(Self.instrument, for: c)
        let ic = try #require(rack._liveInstrument(c))

        try await invalidate(ia)
        try await waitUntil { rack._liveInstrument(a) == nil }
        #expect(ia.engine == nil, "totes Instrument sofort abgebaut")
        #expect(rack.instrumentStatus[a] == .loading)

        try await waitUntil { loads.count == 5 }
        #expect(!wiredDead, "keine tote Einheit verbunden")
        #expect(rack._liveInstrument(a) != nil && rack._liveInstrument(a) !== ia)
        #expect(rack._liveEffect(a, at: 0) != nil && rack._liveEffect(a, at: 0) !== fx)
        #expect(rack._liveInstrument(c) === ic, "gesunde Instanz unberührt")
        #expect(rack.instrumentStatus[a] == .ready && rack.instrumentStatus[c] == .ready)
        #expect(rack.effectStatus[a] == [.ready])
        #expect(!rack.isRecoveringPlugins)

        // Späte Meldungen der alten Instanzen treffen nichts mehr.
        try await invalidate(ia)
        try await invalidate(fx)
        try await Task.sleep(nanoseconds: UInt64(rack.recoveryQuietTime * 2e9))
        #expect(loads.count == 5)
    }
}
