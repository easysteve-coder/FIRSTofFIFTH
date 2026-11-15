import Testing
import Foundation
import AVFoundation
@testable import VintageSequencer

// v1.18.16 — Apple Sampler als Instrument (Stephan: „also wird zukünftig apple sampler genommen").

@MainActor @Suite(.serialized) struct AppleSamplerTests {
    nonisolated static let kit = NSHomeDirectory().components(separatedBy: "/Library/Containers/").first!
        + "/Music/Audio Music Apps/Sampler Instruments/Battery 3/Battery 2 Kits/Electronic Kits/Apparat.exs"

    private func tempDefaults() -> UserDefaults {
        let name = "fof-sampler-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    /// Samples eines anderen Rechners: Verweise werden auf den freigegebenen Ordner umgebogen,
    /// das gemeinsame Ende entscheidet; nicht Gefundenes bleibt unverändert.
    @Test func relocateToSharedFolder() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("smp-\(UUID().uuidString)")
        let samples = root.appendingPathComponent("Music/Battery 3 Library/Samples/Kit")
        try FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for n in ["bd.wav", "sn.wav"] { try Data([0]).write(to: samples.appendingPathComponent(n)) }
        let folders = SampleFolders(defaults: tempDefaults())
        #expect(folders.add(root.appendingPathComponent("Music")))
        let other = "/Volumes/DATEN/Music/Battery 3 Library/Samples/Kit/"
        let state: [String: Any] = ["name": "x", "file-references": [
            "Sample:1": other + "bd.wav", "Sample:2": other + "sn.wav", "Sample:3": "/nowhere/hh.wav"]]
        let out = AppleSampler.relocate(state, folders: folders)
        let refs = AppleSampler.references(out)
        #expect(refs["Sample:1"] == samples.appendingPathComponent("bd.wav").path)
        #expect(refs["Sample:2"] == samples.appendingPathComponent("sn.wav").path)
        #expect(refs["Sample:3"] == "/nowhere/hh.wav")
        #expect(out["name"] as? String == "x")
        // Vorhandene Pfade bleiben, ohne Verweise kein Umbau.
        let here: [String: Any] = ["file-references": ["Sample:1": samples.appendingPathComponent("bd.wav").path]]
        #expect(AppleSampler.references(AppleSampler.relocate(here, folders: folders)) == AppleSampler.references(here))
        #expect(folders.covers(samples.appendingPathComponent("bd.wav")))
        #expect(!folders.covers(URL(fileURLWithPath: "/Volumes/DATEN/Music")))
    }

    /// Codex R15-05: längstes Pfadende über alle Ordner, Gleichstand = keine Zuordnung,
    /// Präfixe an Komponenten (Kit1 ≠ Kit10), Verzeichnisse zählen nicht.
    @Test func relocateIsUnambiguous() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("smp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        func file(_ rel: String) throws {
            let u = root.appendingPathComponent(rel)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0]).write(to: u)
        }
        try file("A/Kit/bd.wav")                   // nur Ordner + Datei
        try file("B/Library/Kit/bd.wav")           // längeres Ende
        try file("B/Library/Kit10/sn.wav")
        try file("C/X/Kit/hh.wav"); try file("D/Y/Kit/hh.wav")   // Gleichstand
        try fm.createDirectory(at: root.appendingPathComponent("B/Library/Kit/cl.wav"), withIntermediateDirectories: true)
        let folders = SampleFolders(defaults: tempDefaults())
        for f in ["A", "B", "C", "D"] { #expect(folders.add(root.appendingPathComponent(f))) }
        #expect(folders.locate("/old/Library/Kit/bd.wav") == root.appendingPathComponent("B/Library/Kit/bd.wav").path)
        #expect(folders.locate("/old/Kit/hh.wav") == nil, "zwei gleich gute Treffer")
        #expect(folders.locate("/old/Library/Kit/cl.wav") == nil, "Verzeichnis ist keine Datei")
        let state: [String: Any] = ["file-references": [
            "Sample:1": "/old/Library/Kit/bd.wav", "Sample:2": "/old/Library/Kit1/sn.wav"]]
        let refs = AppleSampler.references(AppleSampler.relocate(state, folders: folders))
        #expect(refs["Sample:1"] == root.appendingPathComponent("B/Library/Kit/bd.wav").path)
        #expect(refs["Sample:2"] == "/old/Library/Kit1/sn.wav", "Kit1 wird nicht über das Präfix zu Kit10")
    }

    /// Codex R15-05 (Rest): nach einem eindeutigen Treffer gilt die Gleichstandsregel weiter.
    @Test func tieAfterUniqueHitStaysUnmapped() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("smp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for rel in ["A/Library/Kit/bd.wav", "A/Library/Kit/sn.wav", "B/Library/Kit/sn.wav"] {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0]).write(to: u)
        }
        let folders = SampleFolders(defaults: tempDefaults())
        #expect(folders.add(root.appendingPathComponent("A")) && folders.add(root.appendingPathComponent("B")))
        let state: [String: Any] = ["file-references": [
            "Sample:1": "/old/Library/Kit/bd.wav", "Sample:2": "/old/Library/Kit/sn.wav"]]
        let refs = AppleSampler.references(AppleSampler.relocate(state, folders: folders))
        #expect(refs["Sample:1"] == root.appendingPathComponent("A/Library/Kit/bd.wav").path)
        #expect(refs["Sample:2"] == "/old/Library/Kit/sn.wav", "sn.wav liegt in A und B gleich gut")
    }

    /// Codex R15-06: nur aufgehende Freigaben zählen; übergeordneter Ordner ersetzt innere;
    /// Entfernen schließt.
    @Test func foldersAreBalanced() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("smp-\(UUID().uuidString)")
        let inner = root.appendingPathComponent("Music/Kits")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let d = tempDefaults()
        let folders = SampleFolders(defaults: d)
        #expect(!folders.add(root.appendingPathComponent("does-not-exist")))
        #expect(folders.urls.isEmpty)
        #expect(folders.add(inner))
        #expect(folders.add(root.appendingPathComponent("Music")))
        #expect(folders.urls.count == 1, "innerer Ordner ersetzt")
        #expect((d.array(forKey: SampleFolders.defaultsKey) as? [Data])?.count == 1)
        #expect(SampleFolders(defaults: d).urls.count == 1, "Lesezeichen übersteht Neustart")
        folders.remove(root.appendingPathComponent("Music"))
        #expect(folders.urls.isEmpty && !folders.covers(inner))
    }

    static let dls = "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls"

    /// SoundFont/DLS: Bänke stehen als `file://`-URL in den Verweisen (gemessen). Lesbare URL
    /// gilt als vorhanden; umgebogen wird in derselben Schreibweise.
    @Test func bankReferencesAreURLs() throws {
        #expect(AppleSampler.path(of: "file:///Library/A%20B/x.sf2") == "/Library/A B/x.sf2")
        #expect(AppleSampler.path(of: "/Library/x.wav") == "/Library/x.wav")
        #expect(AppleSampler.reference("/Users/x/A B/y.sf2", like: "file:///old/y.sf2") == "file:///Users/x/A%20B/y.sf2")
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("smp-\(UUID().uuidString)")
        let f = root.appendingPathComponent("Sounds/Banks/kit.sf2")
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0]).write(to: f)
        defer { try? FileManager.default.removeItem(at: root) }
        let folders = SampleFolders(defaults: tempDefaults())
        #expect(folders.add(root.appendingPathComponent("Sounds")))
        let state: [String: Any] = ["file-references": ["Bank:0": "file:///Volumes/DATEN/Sounds/Banks/kit.sf2"]]
        #expect(AppleSampler.references(AppleSampler.relocate(state, folders: folders))["Bank:0"] == f.absoluteString)
    }

    /// Apples DLS-Bank (auf jedem Mac): Umwandlung, Laden über das Rack, hörbar.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: AppleSamplerTests.dls), "gs_instruments.dls fehlt"))
    func loadsDlsIntoRack() async throws {
        try await loadAndHear(Self.dls, name: "Apple Sampler · gs_instruments", notes: [60, 64, 67], minRefs: 1)
    }

    private func loadAndHear(_ path: String, name: String, notes: [Int], minRefs: Int) async throws {
        let rack = InstrumentRack()
        let id = try #require(rack.addChannel(name: "Sampler"))
        rack.setMuted(id, true)
        let failure: AppleSampler.Failure? = await withCheckedContinuation { c in
            rack.loadSamplerInstrument(URL(fileURLWithPath: path), for: id) { c.resume(returning: $0) }
        }
        #expect(failure == nil, "\(String(describing: failure))")
        let deadline = Date().addingTimeInterval(30)
        while rack.instrumentStatus[id] == .loading, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(rack.instrumentStatus[id] == .ready)
        #expect(rack.channels.first { $0.id == id }?.instrument?.name == name)
        try await Task.sleep(nanoseconds: 300_000_000)
        rack.captureStates()
        let data = try #require(rack.channels.first { $0.id == id }?.instrument?.state)
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(AppleSampler.references(plist).count >= minRefs)
        let gain = try #require(rack._liveGain(id))
        final class Peak: @unchecked Sendable { var v: Float = 0 }
        let peak = Peak()
        gain.installTap(onBus: 0, bufferSize: 1024, format: nil) { b, _ in
            let p = b.floatChannelData![0]; var m: Float = 0
            for i in 0..<Int(b.frameLength) { m = max(m, abs(p[i])) }
            DispatchQueue.main.async { peak.v = max(peak.v, m) }
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let q = rack.queue(rack.route(for: id))
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        let ms = UInt64(1_000_000 * Double(tb.denom) / Double(tb.numer))
        let t0 = mach_absolute_time() + 50 * ms
        for (k, note) in notes.enumerated() {
            q.pushFromTick(0x90, UInt8(note), 110, at: t0 + UInt64(k) * 200 * ms)
            q.pushFromTick(0x80, UInt8(note), 0, at: t0 + UInt64(k) * 200 * ms + 150 * ms)
        }
        try await Task.sleep(nanoseconds: 900_000_000)
        gain.removeTap(onBus: 0)
        #expect(peak.v > 0.05, "klingt (Spitze \(peak.v))")
        rack.removeChannel(id)
    }

    @Test func folderSuggestionPrefersMusic() {
        let u = URL(fileURLWithPath: "/Volumes/DATEN/Music/Audio Music Apps/Sampler Instruments/Battery 3/Kit.exs")
        #expect(SamplerPanels.suggestion(for: u).path == "/Volumes/DATEN/Music")
        let v = URL(fileURLWithPath: "/Users/x/Kits/Drums/Kit.exs")
        #expect(SamplerPanels.suggestion(for: v).path == "/Users/x/Kits")
    }

    @Test func unsupportedFileType() async {
        let f: AppleSampler.Failure? = await withCheckedContinuation { c in
            AppleSampler.convert(URL(fileURLWithPath: "/tmp/kit.wav")) { r in
                if case .failure(let f) = r { c.resume(returning: f) } else { c.resume(returning: nil) }
            }
        }
        #expect(f == .unsupported)
    }

    /// Echtes EXS-Kit (nur wenn vorhanden): Umwandlung, Laden über das Rack außerhalb des
    /// Prozesses, Zustand mit allen Samples, Speichern/Laden im Kanal.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: AppleSamplerTests.kit), "EXS-Kit fehlt"))
    func loadsExsIntoRack() async throws {
        let rack = InstrumentRack()
        let id = try #require(rack.addChannel(name: "Drums"))
        rack.setMuted(id, true)
        let failure: AppleSampler.Failure? = await withCheckedContinuation { c in
            rack.loadSamplerInstrument(URL(fileURLWithPath: Self.kit), for: id) { c.resume(returning: $0) }
        }
        #expect(failure == nil)
        let deadline = Date().addingTimeInterval(30)
        while rack.instrumentStatus[id] == .loading, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(rack.instrumentStatus[id] == .ready)
        let ch = try #require(rack.channels.first { $0.id == id })
        #expect(ch.instrument?.name == "Apple Sampler · Apparat")
        #expect(AppleSampler.isSampler(ch.instrument))
        try await Task.sleep(nanoseconds: 300_000_000)
        rack.captureStates()
        let data = try #require(rack.channels.first { $0.id == id }?.instrument?.state)
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(AppleSampler.references(plist).count == 63, "alle Samples im Zustand der Instanz außerhalb")
        // Hörbar (Codex): Noten über die Warteschlange, Pegel am Kanal vor dem Fader.
        let gain = try #require(rack._liveGain(id))
        final class Peak: @unchecked Sendable { var v: Float = 0 }
        let peak = Peak()
        gain.installTap(onBus: 0, bufferSize: 1024, format: nil) { b, _ in
            let p = b.floatChannelData![0]; var m: Float = 0
            for i in 0..<Int(b.frameLength) { m = max(m, abs(p[i])) }
            DispatchQueue.main.async { peak.v = max(peak.v, m) }
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let q = rack.queue(rack.route(for: id))
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        let ms = UInt64(1_000_000 * Double(tb.denom) / Double(tb.numer))
        let t0 = mach_absolute_time() + 50 * ms
        for (k, note) in [36, 38, 42].enumerated() {
            q.pushFromTick(0x90, UInt8(note), 110, at: t0 + UInt64(k) * 200 * ms)
            q.pushFromTick(0x80, UInt8(note), 0, at: t0 + UInt64(k) * 200 * ms + 150 * ms)
        }
        try await Task.sleep(nanoseconds: 900_000_000)
        gain.removeTap(onBus: 0)
        #expect(peak.v > 0.05, "Kit klingt (Spitze \(peak.v))")
        rack.removeChannel(id)
    }
}
