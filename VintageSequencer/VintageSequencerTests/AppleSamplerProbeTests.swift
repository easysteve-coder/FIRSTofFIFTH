import Testing
import Foundation
import AVFoundation
import AudioToolbox
import CoreAudioKit
@testable import VintageSequencer

// Messung (v1.18.16): Apples AUSampler als Instrument. Läuft nur, wenn im Container-tmp
// `fof-sampler-probe` liegt (Inhalt: Pfad einer .exs-Datei); schreibt nach `sampler-report.txt`.
// (c) verlangt die Samples unter `FOF_SMP_ALT/smp-moved/` (vorher per Shell kopiert; der
// Hostprozess liest das Container-tmp nicht). Der frühere kombinierte Lauf (im und außerhalb des
// Prozesses in einem Test) stürzte reproduzierbar ab und ist entfernt.
// Fragen: Ausgangsbusse (Multi-Out), eigene Oberfläche, Laden über kAUSamplerProperty_LoadInstrument
// im App-Prozess und außerhalb, Klang nach dem Laden, Zustand (fullState) mit Dateiverweis.

@MainActor @Suite(.serialized) struct AppleSamplerProbeTests {
    static let desc = AudioComponentDescription(componentType: kAudioUnitType_MusicDevice,
        componentSubType: kAudioUnitSubType_Sampler, componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0, componentFlagsMask: 0)
    nonisolated static let dir = NSTemporaryDirectory()
    nonisolated static var exsPath: String? {
        (try? String(contentsOfFile: dir + "fof-sampler-probe", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func instantiate(_ options: AudioComponentInstantiationOptions) async throws -> AVAudioUnit {
        try await withCheckedThrowingContinuation { c in
            AVAudioUnit.instantiate(with: desc, options: options) { u, e in
                if let u { c.resume(returning: u) } else { c.resume(throwing: e ?? NSError(domain: "smp", code: 1)) }
            }
        }
    }

    /// Nur das Anlegen außerhalb des Prozesses, Schritt für Schritt.
    @Test(.enabled(if: AppleSamplerProbeTests.exsPath != nil, "Messung nur mit fof-sampler-probe"))
    func outOfProcessOnly() async throws {
        try? FileManager.default.removeItem(atPath: Self.dir + "sampler-report.txt")
        Self.log("oop: start\n")
        let u: AVAudioUnit? = await withCheckedContinuation { c in
            AVAudioUnit.instantiate(with: Self.desc, options: .loadOutOfProcess) { u, e in
                Self.log("oop: callback unit \(u != nil) error \(String(describing: e))\n")
                c.resume(returning: u)
            }
        }
        Self.log("oop: got \(u.map { "\(type(of: $0))" } ?? "nil")\n")
        guard let u else { return }
        Self.log("oop: outputs \(u.auAudioUnit.outputBusses.count)\n")
        let e = AVAudioEngine(); e.attach(u)
        Self.log("oop: attached\n")
        e.connect(u, to: e.mainMixerNode, format: nil)
        Self.log("oop: connected\n")
        e.mainMixerNode.outputVolume = 0
        try e.start()
        Self.log("oop: running\n")
        let au = u.auAudioUnit
        var peak: Float = 0
        u.installTap(onBus: 0, bufferSize: 1024, format: nil) { b, _ in
            let p = b.floatChannelData![0]; var m: Float = 0
            for i in 0..<Int(b.frameLength) { m = max(m, abs(p[i])) }
            DispatchQueue.main.async { peak = max(peak, m) }
        }
        func hit() async throws -> Float {
            peak = 0
            try await Task.sleep(nanoseconds: 200_000_000)
            for note: UInt8 in [36, 38, 42] {
                var on: (UInt8, UInt8, UInt8) = (0x90, note, 110)
                withUnsafeBytes(of: &on) { au.scheduleMIDIEventBlock?(AUEventSampleTimeImmediate, 0, 3, $0.bindMemory(to: UInt8.self).baseAddress!) }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            try await Task.sleep(nanoseconds: 300_000_000)
            return peak
        }
        Self.log("oop: default peak \(try await hit())\n")
        // (a) LoadInstrument über die Eigenschaft
        let cfURL = URL(fileURLWithPath: Self.exsPath!) as CFURL
        var data = AUSamplerInstrumentData(fileURL: Unmanaged.passUnretained(cfURL),
                                           instrumentType: UInt8(kInstrumentType_EXS24), bankMSB: 0, bankLSB: 0, presetID: 0)
        let st = AudioUnitSetProperty(u.audioUnit, kAUSamplerProperty_LoadInstrument, kAudioUnitScope_Global, 0,
                                      &data, UInt32(MemoryLayout<AUSamplerInstrumentData>.size))
        withExtendedLifetime(cfURL) {}
        Self.log("oop: (a) LoadInstrument status \(st)\n")
        Self.log("oop: (a) peak \(try await hit()) refs \((au.fullState?["file-references"] as? [String: Any])?.count ?? -1)\n")
        // (b) Zustand aus einer Instanz im App-Prozess
        let ip: AVAudioUnit = try await Self.instantiate([])
        var d2 = AUSamplerInstrumentData(fileURL: Unmanaged.passUnretained(cfURL),
                                         instrumentType: UInt8(kInstrumentType_EXS24), bankMSB: 0, bankLSB: 0, presetID: 0)
        let st2 = AudioUnitSetProperty(ip.audioUnit, kAUSamplerProperty_LoadInstrument, kAudioUnitScope_Global, 0,
                                       &d2, UInt32(MemoryLayout<AUSamplerInstrumentData>.size))
        withExtendedLifetime(cfURL) {}
        let state = ip.auAudioUnit.fullState
        Self.log("oop: (b) in-process load \(st2), state \(state != nil)\n")
        // erst Standardzustand wiederherstellen, damit (a) nicht zählt
        if let state {
            au.fullState = state
            Self.log("oop: (b) peak \(try await hit()) refs \((au.fullState?["file-references"] as? [String: Any])?.count ?? -1)\n")
        }
        // (c) Zustand mit verschobenen Pfaden (Dateien kopiert in einen anderen Ordner)
        if var state, let refs = state["file-references"] as? [String: String] {
            let alt = (ProcessInfo.processInfo.environment["FOF_SMP_ALT"] ?? Self.dir) + "/smp-moved/"
            var moved: [String: String] = [:]
            for (k, v) in refs { moved[k] = alt + (v as NSString).lastPathComponent }
            state["file-references"] = moved
            let fresh: AVAudioUnit = try await Self.instantiate(.loadOutOfProcess)
            let e2 = AVAudioEngine(); e2.attach(fresh); e2.connect(fresh, to: e2.mainMixerNode, format: nil)
            e2.mainMixerNode.outputVolume = 0
            try e2.start()
            fresh.auAudioUnit.fullState = state
            let backRefs = fresh.auAudioUnit.fullState?["file-references"] as? [String: String] ?? [:]
            Self.log("oop: (c) moved refs \(backRefs.count) → \(backRefs.values.first ?? "-")\n")
            // (d) verschobene Pfade, die es nicht gibt: was meldet der Sampler?
            var missing = state
            missing["file-references"] = refs.mapValues { "/nonexistent/" + ($0 as NSString).lastPathComponent }
            fresh.auAudioUnit.fullState = missing
            let mRefs = fresh.auAudioUnit.fullState?["file-references"] as? [String: String] ?? [:]
            Self.log("oop: (d) missing refs \(mRefs.count) → \(mRefs.values.first ?? "-")\n")
            e2.stop()
        }
        u.removeTap(onBus: 0)
        e.stop()
        Self.log("oop: done\n")
    }

    static func log(_ s: String) {
        let path = dir + "sampler-report.txt"
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(s.data(using: .utf8)!); h.closeFile() }
        else { try? s.write(toFile: path, atomically: true, encoding: .utf8) }
    }
}
