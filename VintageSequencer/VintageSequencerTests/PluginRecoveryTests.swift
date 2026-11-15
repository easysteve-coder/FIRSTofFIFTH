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
    private func waitUntil(_ done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !done(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
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
        try await waitUntil { rack._liveInstrument(a) !== ua && rack._liveInstrument(b) !== ub }
        #expect(rack._liveInstrument(a) !== ua && rack._liveInstrument(b) !== ub)
        #expect(rack.instrumentStatus[a] == .ready && rack.instrumentStatus[b] == .ready)
    }
}
