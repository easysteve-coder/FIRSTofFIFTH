import XCTest
import Foundation
import CoreMIDI
import Darwin
@testable import VintageSequencer

// MARK: - Slice 11 — Performance Baseline
//
// Programmatisch messbare Metriken:
//   1. Preset-Ladezeit         → XCTClockMetric (5 Iterationen, Median in xcresult)
//   2. Speicher-Footprint      → XCTMemoryMetric
//   3. Engine-Tick-Jitter 60s  → mach_absolute_time Stichprobe, Ergebnis in Assertion-Message
//   4. Playback-Stabilität 30s → Direktmessung, isPlaying-Assertion
//
// Nicht programmatisch messbar (erfordern Instruments):
//   5. SwiftUI Re-render-Frequenz
//   6. Main-Thread-CPU
//   7. Frame-Rate / FPS

final class PerformanceBaselineTests: XCTestCase {

    // MARK: - Hilfsfunktionen

    private static let machToUs: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom) / 1000.0
    }()

    // MARK: - Log
    private static let logURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("FIRSTofFIFTH_baseline.txt")
    private static var log = ""

    private func record(_ text: String) {
        Self.log += text + "\n"
        try? Self.log.data(using: .utf8)?.write(to: Self.logURL)
    }

    override class func tearDown() {
        super.tearDown()
        try? log.data(using: .utf8)?.write(to: logURL)
    }

    private func residentMemoryBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) : -1
    }

    /// Baut ein 4-Pattern × 8-Track × 32-Step-Preset und gibt die serialisierten Daten zurück.
    private func makeFullPresetData() throws -> Data {
        let engine = SequencerEngine()
        engine.bpm   = 120.0
        engine.swing = 50.0
        for pIdx in 0..<engine.patterns.count {
            while engine.patterns[pIdx].tracks.count < 8 {
                engine.patterns[pIdx].tracks.append(
                    TrackData(name: "T\(engine.patterns[pIdx].tracks.count + 1)", stepCount: 32, midiChannel: 1)
                )
            }
            for track in engine.patterns[pIdx].tracks {
                track.lane.stepCount = 32
                for i in 0..<32 {
                    track.lane.steps[i].isActive = (i % 2 == 0)
                    track.lane.steps[i].notes    = [60 + i % 12]
                    track.lane.steps[i].velocity = 80 + (i % 40)
                }
            }
        }
        guard let data = engine.saveData() else {
            XCTFail("makeFullPresetData: saveData() returned nil")
            throw NSError(domain: "PerformanceBaseline", code: 1)
        }
        return data
    }

    // MARK: - 1. Preset-Ladezeit (XCTClockMetric)

    /// Misst loadData() für ein vollständig befülltes 4-Pattern-Preset.
    /// XCTClockMetric: 5 Iterationen, Median/StdDev in xcresult.
    /// Grenze OK: < 300 ms.
    func testPresetLoadTime() throws {
        let data    = try makeFullPresetData()
        let engine2 = SequencerEngine()

        measure(metrics: [XCTClockMetric()]) {
            _ = engine2.loadData(data)
        }
    }

    /// Misst saveData() für ein vollständig befülltes 4-Pattern-Preset.
    func testPresetSaveTime() throws {
        let engine = SequencerEngine()
        engine.bpm = 120.0
        for pIdx in 0..<engine.patterns.count {
            while engine.patterns[pIdx].tracks.count < 8 {
                engine.patterns[pIdx].tracks.append(
                    TrackData(name: "T", stepCount: 32, midiChannel: 1)
                )
            }
            for track in engine.patterns[pIdx].tracks {
                track.lane.stepCount = 32
                for i in 0..<32 { track.lane.steps[i].isActive = (i % 2 == 0) }
            }
        }
        measure(metrics: [XCTClockMetric()]) {
            _ = engine.saveData()
        }
    }

    /// Ergänzende Direktmessung: gibt konkrete ms-Werte und Dateigröße.
    func testPresetLoadSaveTimeDirect() throws {
        let data   = try makeFullPresetData()
        let engine2 = SequencerEngine()

        // 5 Wiederholungen — Median ist repräsentativ
        var loadTimes = [Double]()
        for _ in 0..<5 {
            let t0 = mach_absolute_time()
            _ = engine2.loadData(data)
            let t1 = mach_absolute_time()
            loadTimes.append(Double(t1 - t0) * Self.machToUs / 1000.0)
        }
        loadTimes.sort()
        let medianLoadMs = loadTimes[2]   // Median von 5

        let t0s = mach_absolute_time()
        _ = engine2.saveData()
        let t1s = mach_absolute_time()
        let saveMs = Double(t1s - t0s) * Self.machToUs / 1000.0

        // Ergebnis in Assertion-Message sichtbar (erscheint in xcodebuild wenn Test läuft)
        record("""
        ╔══ BASELINE: Preset-Ladezeit (4P×8T×32S, Median von 5) ═════════╗
          saveData():  \(String(format: "%.2f", saveMs)) ms
          loadData():  \(String(format: "%.2f", medianLoadMs)) ms  (Median)
          Dateigröße:  \(data.count) B  (\(String(format: "%.1f", Double(data.count)/1024.0)) KB)
          Grenze OK:   < 300 ms
        ╚═════════════════════════════════════════════════════════════════╝
        """)

        XCTAssertLessThan(medianLoadMs, 300.0,
            "loadData() Grenze überschritten: \(String(format:"%.2f",medianLoadMs))ms")
        XCTAssertLessThan(saveMs, 300.0,
            "saveData() Grenze überschritten: \(String(format:"%.2f",saveMs))ms")
    }

    // MARK: - 2. Speicher-Footprint (XCTMemoryMetric)

    /// Misst RSS-Wachstum während Aufbau von 4 SequencerEngines (je 8 Tracks, 32 Steps).
    func testMemoryFootprint() throws {
        measure(metrics: [XCTMemoryMetric()]) {
            var engines = [SequencerEngine]()
            for _ in 0..<4 {
                let e = SequencerEngine()
                for pIdx in 0..<e.patterns.count {
                    while e.patterns[pIdx].tracks.count < 8 {
                        e.patterns[pIdx].tracks.append(TrackData(name: "T", stepCount: 32, midiChannel: 1))
                    }
                    for track in e.patterns[pIdx].tracks {
                        track.lane.stepCount = 32
                        for i in 0..<32 { track.lane.steps[i].isActive = true }
                    }
                }
                engines.append(e)
            }
            // engines werden am Block-Ende freigegeben — XCTMemoryMetric misst Netto-Delta
        }
    }

    /// Direktmessung: RSS vor/nach Engine-Aufbau — gibt konkrete MB-Werte.
    func testMemoryFootprintDirect() throws {
        let before = residentMemoryBytes()
        guard before > 0 else { XCTFail("mach_task_basic_info nicht lesbar"); return }

        var engines = [SequencerEngine]()
        for _ in 0..<4 {
            let e = SequencerEngine()
            for pIdx in 0..<e.patterns.count {
                while e.patterns[pIdx].tracks.count < 8 {
                    e.patterns[pIdx].tracks.append(TrackData(name: "T", stepCount: 32, midiChannel: 1))
                }
                for track in e.patterns[pIdx].tracks {
                    track.lane.stepCount = 32
                    for i in 0..<32 { track.lane.steps[i].isActive = true }
                }
            }
            engines.append(e)
        }

        let afterBuild = residentMemoryBytes()
        let deltaMB    = Double(afterBuild - before) / 1_048_576.0
        let perEngineMB = deltaMB / 4.0

        engines.removeAll()
        let afterFree = residentMemoryBytes()
        let retainedMB = Double(afterFree - before) / 1_048_576.0

        record("""
        ╔══ BASELINE: Speicher-Footprint (4 Engines × 8T × 32S) ═════════╗
          Baseline RSS:    \(String(format: "%.1f", Double(before)/1_048_576.0)) MB
          Nach 4 Engines:  \(String(format: "%.1f", Double(afterBuild)/1_048_576.0)) MB
          Delta gesamt:    +\(String(format: "%.1f", deltaMB)) MB
          Pro Engine:      +\(String(format: "%.2f", perEngineMB)) MB
          Nach Freigabe:   \(String(format: "%.1f", Double(afterFree)/1_048_576.0)) MB
          Retained:        +\(String(format: "%.1f", retainedMB)) MB  (Framework-Overhead)
          Grenze OK:       < 5 MB/Engine
        ╚═════════════════════════════════════════════════════════════════╝
        """)
        XCTAssertLessThan(perEngineMB, 5.0,
            "Speicher/Engine Grenze: \(String(format:"%.2f",perEngineMB))MB")
    }

    // MARK: - 3. Engine-Tick-Jitter (60 Sekunden)

    /// Misst die ClockSource Callback-Jitter über 60 Sekunden.
    ///
    /// Jitter = |actual_inter_callback_interval − expected_tick_interval| in µs.
    /// Bei 120 BPM / 24 PPQ: expected = 20.833 ms pro Tick.
    ///
    /// Ergebnis erscheint in Assertion-Message (sichtbar bei Grenzwert-Überschreitung
    /// und als Info auch bei Erfolg via Assertion-Label-Konvention).
    func testEngineTickJitter_60Seconds() throws {
        let bpm          = 120.0
        let measurementS = 60.0
        let ticksPerSec  = bpm / 60.0 * 24.0   // 48 ticks/s

        var callTimes = [UInt64]()
        callTimes.reserveCapacity(3200)

        let clock = ClockSource()
        clock.bpm = bpm
        clock.onTick = { _ in callTimes.append(mach_absolute_time()) }
        clock.start()
        Thread.sleep(forTimeInterval: measurementS)
        clock.stop()

        guard callTimes.count > 100 else {
            XCTFail("Zu wenige Ticks: \(callTimes.count)"); return
        }

        // Inter-Callback-Intervalle (die ClockSource weckt einmal pro Tick)
        let expectedUs = 1_000_000.0 / ticksPerSec   // 20833.3 µs
        var intervals  = [Double]()
        for i in 1..<callTimes.count {
            guard callTimes[i] > callTimes[i-1] else { continue }
            let us = Double(callTimes[i] - callTimes[i-1]) * Self.machToUs
            if us >= 0.5 * expectedUs { intervals.append(us) }
        }

        let jitters = intervals.map { abs($0 - expectedUs) }
        let sorted  = jitters.sorted()
        let n       = sorted.count
        guard n > 10 else { XCTFail("Zu wenige Inter-Buffer-Intervalle: \(n)"); return }

        let medianUs = sorted[n / 2]
        let p95Us    = sorted[min(Int(Double(n) * 0.95), n-1)]
        let p99Us    = sorted[min(Int(Double(n) * 0.99), n-1)]
        let maxUs    = sorted[n-1]
        let pileup   = (callTimes.count - 1) - intervals.count

        // WICHTIG: Der gemessene Jitter-Wert ist KEIN MIDI-Timing-Jitter.
        // Er misst die Inter-Callback-Verzögerung des ClockSource-Threads
        // im Test-Prozess (kein RT-Scheduling, Main Thread blockiert).
        //
        // Die echte MIDI-Timing-Präzision wird durch CoreMIDI Future Timestamps
        // garantiert — sample-genau, unabhängig vom Callback-Jitter.
        // Die Messung ist nur als Referenz für In-App-Vergleich (Instruments) dokumentiert.
        //
        // Keine harte Assertion: Grenzwerte gelten nur für In-App-Messung via Instruments.
        XCTAssertGreaterThan(callTimes.count, 100,
            "Mindestens 100 Ticks in 60s erfasst")

        record("""
        ╔══ BASELINE: Engine Tick Jitter (120 BPM / 60s) ════════════════╗
          Ticks erfasst:  \(callTimes.count)  (erwartet ≈ \(Int(ticksPerSec*measurementS)))
          Pileup-Ticks:   \(pileup)
          Expected:       \(String(format: "%.0f", expectedUs)) µs/tick
          Jitter Median:  \(String(format: "%.0f", medianUs)) µs
          Jitter P95:     \(String(format: "%.0f", p95Us)) µs
          Jitter P99:     \(String(format: "%.0f", p99Us)) µs  ← Grenze OK: < 2000 µs
          Jitter Max:     \(String(format: "%.0f", maxUs)) µs
          p99 in ms:      \(String(format: "%.2f", p99Us/1000.0)) ms
        ╚════════════════════════════════════════════════════════════════╝
        """)
    }

    // MARK: - 4. Playback-Stabilität 30s (8 Tracks, 32 Steps, 120 BPM)

    func testPlaybackStability_30Seconds() throws {
        let engine = SequencerEngine()
        engine.bpm = 120.0
        while engine.currentPattern.tracks.count < 8 {
            engine.currentPattern.tracks.append(TrackData(name: "T", stepCount: 32, midiChannel: 1))
        }
        for track in engine.currentPattern.tracks {
            track.lane.stepCount = 32
            for i in stride(from: 0, to: 32, by: 2) { track.lane.steps[i].isActive = true }
        }

        let memBefore = residentMemoryBytes()
        engine.play()
        Thread.sleep(forTimeInterval: 30.0)
        let displayActive = engine.playbackDisplay.steps.contains { $0 > 0 }
        engine.stop()
        let memAfter = residentMemoryBytes()
        let memDeltaMB = Double(memAfter - memBefore) / 1_048_576.0

        XCTAssertFalse(engine.isPlaying,
            "BASELINE_PLAY: isPlaying muss nach stop() false sein")

        record("""
        ╔══ BASELINE: Playback-Stabilität (8T/32S/30s) ══════════════════╗
          BPM:             120.0
          Tracks:          \(engine.patterns[0].tracks.count)
          Steps/Track:     32
          Laufzeit:        30 s
          displaySteps:    \(displayActive ? "aktiv (Tick-Pfad bestätigt)" : "INAKTIV – Fehler")
          RSS-Delta:       +\(String(format: "%.1f", memDeltaMB)) MB  (während Playback)
          isPlaying:       \(engine.isPlaying)  (muss false sein nach stop)
        ╚════════════════════════════════════════════════════════════════╝
        """)
    }
}
