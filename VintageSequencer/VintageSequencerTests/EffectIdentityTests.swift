import Testing
import Foundation
import AVFoundation
@testable import VintageSequencer

// v1.17.8 — Effekt-Identität (Codex A17-04): CC-Ziele binden an die Effekt-Instanz, nicht an
// Reihenfolge; ältere Ordinal-Ziele werden beim Laden einmal zugeordnet.

private let delay = PluginRef(description: AudioComponentDescription(
    componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_Delay,
    componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0),
    name: "AUDelay")

@MainActor @Suite(.serialized) struct EffectIdentityTests {

    private func rackWithTwoDelays() throws -> (InstrumentRack, UUID, UUID, UUID) {
        let rack = InstrumentRack()
        let id = try #require(rack.addChannel(name: "FX")); rack.setMuted(id, true)
        rack.addEffect(delay, to: id); rack.addEffect(delay, to: id)
        let fx = try #require(rack.channel(id)?.effects)
        let a = try #require(fx[0].instance), b = try #require(fx[1].instance)
        #expect(a != b, "jede Einfügung bekommt eine eigene Instanz")
        return (rack, id, a, b)
    }

    /// Zwei gleiche Delays A/B, Ziel auf A: Umordnen hält A; Entfernen von A lässt das Ziel
    /// offen statt auf B zu verrutschen.
    @Test func targetFollowsInstanceNotOrder() throws {
        let (rack, id, a, b) = try rackWithTwoDelays()
        let sources = rack.parameterSources(for: id)
        let srcA = try #require(sources.first { $0.instance == a })
        let ref = InstrumentRack.parameterRef(.init(address: 1, name: "Mix", group: "", min: 0, max: 100), of: srcA)
        #expect(ref.effectInstance == a && ref.effect == 0)

        rack.moveEffect(from: 1, to: 0, in: id)                         // B vor A
        #expect(rack.parameterSource(of: ref, in: id)?.instance == a)
        #expect(rack.parameterSource(of: ref, in: id)?.effectIndex == 1)

        rack.removeEffect(at: 1, from: id)                              // A entfernt
        #expect(rack.channel(id)?.effects.first?.instance == b)
        #expect(rack.parameterSource(of: ref, in: id) == nil, "kein Verrutschen auf B")
        #expect(rack.resolveParameter(ref, in: id) == nil)
    }

    /// Ältere Ziele (nur laufende Nummer) werden einmal an die bezeichnete Instanz gebunden.
    @Test func legacyOrdinalBindsOnce() throws {
        let (rack, id, _, b) = try rackWithTwoDelays()
        let legacy = ParameterRef(address: 1, name: "Mix", component: delay.componentKey, effect: 1)
        let bound = rack.bindEffectInstance(legacy, in: id)
        #expect(bound.effectInstance == b)
        rack.moveEffect(from: 1, to: 0, in: id)
        #expect(rack.parameterSource(of: bound, in: id)?.instance == b, "nach der Zuordnung zählt die Instanz")
        let none = ParameterRef(address: 1, name: "Mix", component: delay.componentKey, effect: 5)
        #expect(rack.bindEffectInstance(none, in: id) == none, "ohne passenden Effekt unverändert")
    }

    /// Presetformat: `instance` optional; fehlende und doppelte Instanzen vergibt das Laden neu.
    @Test func instanceKeyIsOptionalAndUniqueOnLoad() throws {
        var plain = delay
        let old = try JSONDecoder().decode(PluginRef.self, from: JSONEncoder().encode(plain))
        #expect(old.instance == nil)
        plain.instance = UUID()
        let json = String(data: try JSONEncoder().encode(plain), encoding: .utf8) ?? ""
        #expect(json.contains("\"instance\""))
        #expect(try JSONDecoder().decode(PluginRef.self, from: JSONEncoder().encode(plain)).instance == plain.instance)

        var ch = InstrumentChannelData(name: "L")
        ch.effects = [old, plain, plain]                                 // fehlend + doppelt
        let rack = InstrumentRack()
        rack.replaceAll([ch])
        let fx = try #require(rack.channels.first?.effects)
        let ids = fx.compactMap(\.instance)
        #expect(ids.count == 3 && Set(ids).count == 3)
        #expect(fx[1].instance == plain.instance, "vorhandene Instanz bleibt")
        rack.replaceAll([])
    }
}
