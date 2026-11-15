import Testing
import Foundation
import AVFoundation
@testable import VintageSequencer

struct DrumMapTests {

    // MARK: Hilfen

    /// Minimales EXS: Kopf, Zonen (Typ 1), Gruppen (Typ 2), little-endian.
    static func exs(groups: [UInt8], zones: [(key: Int, group: Int32, oneShot: Bool)]) -> Data {
        var d = Data()
        func chunk(type: UInt32, payload: [UInt8]) {
            var sig = (type << 24) | 0x0101
            var size = UInt32(payload.count), id: UInt32 = 0, pad: UInt32 = 0
            withUnsafeBytes(of: &sig) { d.append(contentsOf: $0) }
            withUnsafeBytes(of: &size) { d.append(contentsOf: $0) }
            withUnsafeBytes(of: &id) { d.append(contentsOf: $0) }
            withUnsafeBytes(of: &pad) { d.append(contentsOf: $0) }
            d.append(contentsOf: Array("TBOS".utf8))
            d.append(contentsOf: [UInt8](repeating: 0, count: 64))
            d.append(contentsOf: payload)
        }
        chunk(type: 0, payload: [UInt8](repeating: 0, count: 16))
        for z in zones {
            var p = [UInt8](repeating: 0, count: 148)
            p[0] = z.oneShot ? 0x0B : 0x0A
            p[1] = UInt8(z.key); p[6] = UInt8(z.key); p[7] = UInt8(z.key)
            withUnsafeBytes(of: z.group.littleEndian) { for (i, b) in $0.enumerated() { p[88 + i] = b } }
            chunk(type: 1, payload: p)
        }
        for ex in groups {
            var p = [UInt8](repeating: 0, count: 80)
            p[4] = ex; p[6] = 127
            chunk(type: 2, payload: p)
        }
        return d
    }

    static let kit = exs(groups: [0, 1, 1], zones: [(36, 0, true), (42, 1, true), (42, 1, true), (46, 2, true), (60, 0, false)])

    // MARK: Lesen

    @Test func readsGroupsAndOneShot() throws {
        let m = try #require(DrumMap.exs(Self.kit))
        #expect(m.group(36) == 0 && m.isOneShot(36))
        #expect(m.group(42) == 1 && m.isOneShot(42))
        #expect(m.group(46) == 1 && m.isOneShot(46))
        #expect(m.group(60) == 0 && !m.isOneShot(60))
        #expect(m.hasGroups)
    }

    @Test func nothingToDoGivesNil() {
        #expect(DrumMap.exs(Self.exs(groups: [0], zones: [(60, 0, false)])) == nil)
        #expect(DrumMap.exs(Data("kein exs".utf8)) == nil)
        #expect(DrumMap.exs(Data()) == nil)
    }

    @Test func shortensOnlyChokedLayers() throws {
        let m = try #require(DrumMap.exs(Self.kit))
        func layer(_ key: Int) -> [String: Any] {
            ["Zones": [["min key": key, "max key": key]],
             "Envelopes": [["ID": 0, "Stages": [["stage": 4, "level": 1.0], ["stage": 5, "time": 0.89]]],
                           ["ID": 1, "Stages": [["stage": 5, "time": 0.5]]]]]
        }
        let literal: [String: Any] = ["Instrument": ["Layers": [layer(36), layer(42), layer(46)]]]
        // Wie aus dem Sampler: Zahlen als NSNumber (Plist-Rundweg).
        let data = try PropertyListSerialization.data(fromPropertyList: literal, format: .binary, options: 0)
        let state = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let r = m.shortenChokeReleases(state)
        #expect(r.layers == 2)
        let layers = try #require((r.state["Instrument"] as? [String: Any])?["Layers"] as? [[String: Any]])
        func release(_ i: Int, env: Int) -> Double? {
            let envs = layers[i]["Envelopes"] as? [[String: Any]]
            let stages = envs?.first { ($0["ID"] as? Int) == env }?["Stages"] as? [[String: Any]]
            return stages?.first { ($0["stage"] as? Int) == 5 }?["time"] as? Double
        }
        #expect(release(0, env: 0) == 0.89)                 // Bassdrum: One-Shot, keine Gruppe
        #expect(release(1, env: 0) == DrumMap.chokeRelease)
        #expect(release(2, env: 0) == DrumMap.chokeRelease)
        #expect(release(1, env: 1) == 0.5)                  // andere Hüllkurve unberührt
    }

    // MARK: Format

    @Test func presetKeyIsOptional() throws {
        var ref = PluginRef(description: AppleSampler.description, name: "S", state: nil)
        let plain = try JSONEncoder().encode(ref)
        #expect(!String(decoding: plain, as: UTF8.self).contains("drumMap"))
        #expect(try JSONDecoder().decode(PluginRef.self, from: plain).drumMap == nil)
        ref.drumMap = DrumMap.exs(Self.kit)
        let data = try JSONEncoder().encode(ref)
        #expect(try JSONDecoder().decode(PluginRef.self, from: data) == ref)
        // Unlesbarer Satz: Instrument lädt trotzdem, ohne Drum-Gruppen.
        let bad = String(decoding: plain, as: UTF8.self).replacingOccurrences(of: "{", with: "{\"drumMap\":[1,2],", options: [], range: nil)
        #expect(try JSONDecoder().decode(PluginRef.self, from: Data(bad.utf8)).drumMap == nil)
    }

    // MARK: Warteschlange

    private func run(_ q: AUEventQueue) -> [UInt32] {
        var out: [UInt32] = []
        q.render(hostStart: 0, hostValid: false, frames: 256, ticksPerFrame: 1) { _, p in out.append(p) }
        return out
    }

    @Test func queueChokesGroupAndKeepsOneShots() throws {
        let q = AUEventQueue()
        q.setActive(true)
        q.setDrumMap(DrumMap.exs(Self.kit))
        q.pushFromTick(0x99, 46, 100, at: 1)
        #expect(run(q) == [AUEvent.pack(0x89, 42, 0), AUEvent.pack(0x89, 46, 0), AUEvent.pack(0x99, 46, 100)])
        q.pushFromTick(0x89, 46, 0, at: 1)                  // One-Shot: Gate-Off entfällt
        q.pushFromTick(0x99, 46, 0, at: 1)                  // Note-On mit Anschlag 0 = Off
        q.pushFromTick(0x99, 36, 90, at: 1)                 // ohne Gruppe: nur die Note
        q.pushFromTick(0x89, 60, 0, at: 1)                  // kein One-Shot: Off bleibt
        q.pushFromTick(0xB9, 123, 0, at: 1)                 // alle Noten aus bleibt
        #expect(run(q) == [AUEvent.pack(0x99, 36, 90), AUEvent.pack(0x89, 60, 0), AUEvent.pack(0xB9, 123, 0)])
        q.setDrumMap(nil)
        q.pushFromTick(0x89, 46, 0, at: 1)
        #expect(run(q) == [AUEvent.pack(0x89, 46, 0)])
    }

    // MARK: Echtes Kit

    nonisolated static let jazz = NSHomeDirectory().components(separatedBy: "/Library/Containers/").first!
        + "/Music/Audio Music Apps/Sampler Instruments/Battery 3/Acoustic Kits/Jazz Brush Kit.exs"

    @Test(.enabled(if: FileManager.default.fileExists(atPath: DrumMapTests.jazz), "Jazz Brush Kit fehlt"))
    func jazzBrushKitHiHats() async throws {
        let r: Result<AppleSampler.Converted, AppleSampler.Failure> = await withCheckedContinuation { c in
            AppleSampler.convert(URL(fileURLWithPath: Self.jazz)) { c.resume(returning: $0) }
        }
        let conv = try r.get()
        let m = try #require(conv.drumMap)
        #expect(m.group(42) == 1 && m.group(44) == 1 && m.group(46) == 1)
        #expect(m.group(36) == 0 && m.isOneShot(36))
        let plist = try #require(try PropertyListSerialization.propertyList(from: conv.state, format: nil) as? [String: Any])
        let layers = try #require((plist["Instrument"] as? [String: Any])?["Layers"] as? [[String: Any]])
        let open = try #require(layers.first { ($0["name"] as? String)?.contains("Hi-Hat Open") == true })
        let stages = ((open["Envelopes"] as? [[String: Any]])?.first { ($0["ID"] as? Int) == 0 }?["Stages"]) as? [[String: Any]]
        #expect(stages?.first { ($0["stage"] as? Int) == 5 }?["time"] as? Double == DrumMap.chokeRelease)
    }

    /// Hörbar über das Rack (Sampler außerhalb des Prozesses): offenes Hi-Hat, nach 300 ms
    /// geschlossenes. Mit Sperrgruppe ist 600–900 ms nach dem Closed nichts mehr vom offenen Becken
    /// zu hören; ohne Closed klingt es dort noch.
    @MainActor
    @Test(.enabled(if: FileManager.default.fileExists(atPath: DrumMapTests.jazz), "Jazz Brush Kit fehlt"))
    func openHatIsChokedInTheRack() async throws {
        let rack = InstrumentRack()
        let id = try #require(rack.addChannel(name: "Drums"))
        rack.setMuted(id, true)
        let failure: AppleSampler.Failure? = await withCheckedContinuation { c in
            rack.loadSamplerInstrument(URL(fileURLWithPath: Self.jazz), for: id) { c.resume(returning: $0) }
        }
        #expect(failure == nil)
        let deadline = Date().addingTimeInterval(30)
        while rack.instrumentStatus[id] == .loading, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(rack.instrumentStatus[id] == .ready)
        #expect(rack.channels.first { $0.id == id }?.instrument?.drumMap?.group(46) == 1)

        let gain = try #require(rack._liveGain(id))
        final class Meter: @unchecked Sendable {
            let lock = NSLock(); var from: UInt64 = 0; var to: UInt64 = 0; var peak: Float = 0
        }
        let meter = Meter()
        gain.installTap(onBus: 0, bufferSize: 512, format: nil) { b, t in
            let p = b.floatChannelData![0]; var m: Float = 0
            for i in 0..<Int(b.frameLength) { m = max(m, abs(p[i])) }
            meter.lock.lock()
            if t.hostTime >= meter.from, t.hostTime < meter.to { meter.peak = max(meter.peak, m) }
            meter.lock.unlock()
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let q = rack.queue(rack.route(for: id))
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        let ms = UInt64(1_000_000 * Double(tb.denom) / Double(tb.numer))

        func tail(choke: Bool) async throws -> Float {
            let t0 = mach_absolute_time() + 100 * ms
            q.pushFromTick(0x90, 46, 120, at: t0)
            q.pushFromTick(0x80, 46, 0, at: t0 + 50 * ms)               // Gate-Off: One-Shot ignoriert es
            if choke { q.pushFromTick(0x90, 42, 1, at: t0 + 300 * ms); q.pushFromTick(0x80, 42, 0, at: t0 + 350 * ms) }
            meter.lock.lock(); meter.from = t0 + 900 * ms; meter.to = t0 + 1200 * ms; meter.peak = 0; meter.lock.unlock()
            try await Task.sleep(nanoseconds: 1_500_000_000)
            meter.lock.lock(); defer { meter.lock.unlock() }
            return meter.peak
        }
        let ringing = try await tail(choke: false)
        let choked = try await tail(choke: true)
        gain.removeTap(onBus: 0)
        #expect(ringing > 0.003, "offenes Becken klingt nach (Spitze \(ringing))")
        #expect(choked < ringing / 10, "nach Closed still (Spitze \(choked) gegen \(ringing))")
        rack.removeChannel(id)
    }
}
