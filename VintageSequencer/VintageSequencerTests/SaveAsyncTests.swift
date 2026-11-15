import Testing
import Foundation
@testable import VintageSequencer

// v1.16.1 — Codex V16-2: Speichern kodiert fehlendes Loop-Material nicht auf Main.

@MainActor
private func engineWithLoops(_ count: Int, bars: Int) throws -> SequencerEngine {
    let engine = SequencerEngine()
    for k in 0..<count {
        let placed = engine.addAudioLoopTrack()
        let td = try #require(placed.first { $0.pattern === engine.currentPattern }?.track)
        let ch = try #require(td.instrumentID)
        let st = try #require(AudioLoopStorage(bars: bars, sampleRate: 48_000, bpm: 120))
        for i in 0..<st.frames {
            let v = Float(sin(Double(i) * 0.01 + Double(k)))
            st.left[i] = v * 0.5; st.right[i] = v * 0.4
        }
        engine.rack._setLoopStorage(st, for: ch)
    }
    return engine
}

@MainActor
private func saveAsync(_ engine: SequencerEngine) async -> Data? {
    await withCheckedContinuation { c in engine.saveDataAsync { c.resume(returning: $0) } }
}

@Suite(.serialized) struct SaveAsyncTests {

    /// Ohne Vorkodierung: der Main-Anteil des Speicherns ist ein Bruchteil der Kodierzeit;
    /// das Ergebnis lädt mit allem Material. Zahlen landen in einer Messdatei.
    @MainActor @Test func cacheMissEncodesOffMain() async throws {
        let engine = try engineWithLoops(4, bars: 4)
        let t0 = mach_absolute_time()
        let syncData = try #require(engine.saveData())        // Referenz: alles auf dem Aufrufer
        let syncNs = SequencerEngine.machToNanos(mach_absolute_time() - t0)

        let fresh = try engineWithLoops(4, bars: 4)            // gleicher Stand, nichts vorkodiert
        var mainNs: UInt64 = 0
        let data: Data? = await withCheckedContinuation { c in
            let s = mach_absolute_time()
            fresh.saveDataAsync { c.resume(returning: $0) }
            mainNs = SequencerEngine.machToNanos(mach_absolute_time() - s)
        }
        let saved = try #require(data)
        let report = "syncSave_ms=\(Double(syncNs) / 1e6) asyncMainPart_ms=\(Double(mainNs) / 1e6) bytes=\(saved.count) syncBytes=\(syncData.count)\n"
        try? report.write(to: FileManager.default.temporaryDirectory
            .appendingPathComponent("fof-save-async.txt"), atomically: true, encoding: .utf8)
        #expect(mainNs * 4 < syncNs, "Main-Anteil < 25 % der synchronen Speicherzeit: \(report)")

        let other = SequencerEngine()
        #expect(other.loadData(saved))
        let loops = other.currentPattern.tracks.filter(\.isAudioLoop)
        #expect(loops.count == 4)
        for td in loops {
            let ch = try #require(td.instrumentID)
            #expect(other.rack.loopCore(for: ch)?.hasMaterial == true)
        }
    }

    /// Das Ergebnis des Hintergrunds füllt den Vorkodier-Speicher: das nächste Speichern
    /// ist synchron fertig (kein Hintergrundauftrag mehr).
    @MainActor @Test func backgroundResultIsReused() async throws {
        let engine = try engineWithLoops(2, bars: 1)
        _ = try #require(await saveAsync(engine))
        var finishedSynchronously = false
        engine.saveDataAsync { _ in finishedSynchronously = true }
        #expect(finishedSynchronously)
    }

    /// Speichern hält den Stand beim Aufruf fest; eine Änderung während des Kodierens bleibt
    /// als ungespeichert markiert und landet nicht in der Datei.
    @MainActor @Test func editsDuringEncodeStayUnsaved() async throws {
        let engine = try engineWithLoops(2, bars: 4)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fof-save-async-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        engine.currentPresetURL = url
        engine.bpm = 100
        #expect(engine.hasUnsavedChanges)
        let ok: Bool = await withCheckedContinuation { c in
            engine.savePresetInPlace { c.resume(returning: $0) }
            engine.bpm = 140                       // während der Hintergrund kodiert
        }
        #expect(ok)
        #expect(engine.hasUnsavedChanges, "Änderung nach dem Speicherbeginn bleibt markiert")
        let other = SequencerEngine()
        #expect(other.loadData(try Data(contentsOf: url)))
        #expect(other.bpm == 100, "Datei enthält den Stand beim Speicherbeginn")
    }

    /// Ohne Änderung während des Speicherns ist danach alles gespeichert.
    @MainActor @Test func cleanSaveClearsTheIndicator() async throws {
        let engine = try engineWithLoops(1, bars: 1)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fof-save-async-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        engine.currentPresetURL = url
        engine.bpm = 101
        let ok: Bool = await withCheckedContinuation { c in engine.savePresetInPlace { c.resume(returning: $0) } }
        #expect(ok && !engine.hasUnsavedChanges)
    }
}
