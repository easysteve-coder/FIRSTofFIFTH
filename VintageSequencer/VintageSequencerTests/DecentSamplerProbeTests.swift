import Testing
import Foundation
import AVFoundation
import Atomics
@testable import VintageSequencer

// Messung (v1.18.9): Decent Sampler unter FoF. Läuft nur, wenn DS installiert ist und im
// Container-tmp die Datei `fof-ds-probe` liegt; schreibt Befunde nach `ds-report.txt`.
// Vergleich: dieselbe Note über (A) eine nackte AVAudioEngine und (B) das FoF-Rack. Gemessen
// wird gegen das Quell-Sample, hochwertig auf die Engine-Rate umgerechnet: Restfehler nach
// Ausrichtung und Pegelanpassung (dB unter dem Signal).

@MainActor @Suite(.serialized) struct DecentSamplerProbeTests {
    static let desc = AudioComponentDescription(componentType: kAudioUnitType_MusicDevice,
        componentSubType: 0x44736d70 /* Dsmp */, componentManufacturer: 0x446c6479 /* Dldy */,
        componentFlags: 0, componentFlagsMask: 0)
    static let dir = NSTemporaryDirectory()
    static var enabled: Bool { FileManager.default.fileExists(atPath: dir + "fof-ds-probe") }

    static func instantiate() async throws -> AVAudioUnit {
        try await withCheckedThrowingContinuation { c in
            AVAudioUnit.instantiate(with: desc, options: .loadOutOfProcess) { u, e in
                if let u { c.resume(returning: u) } else { c.resume(throwing: e ?? NSError(domain: "ds", code: 1)) }
            }
        }
    }

    /// Quelle: 44,1 kHz mono, 0,6 s: Sinus 1 kHz + 5 kHz, abklingend.
    static func makeSource() throws -> (url: URL, samples: [Float]) {
        let sr = 44_100.0, n = Int(sr * 0.6)
        var s = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sr
            s[i] = Float((0.35 * sin(2 * .pi * 1000 * t) + 0.15 * sin(2 * .pi * 5000 * t)) * exp(-t * 3))
        }
        let url = URL(fileURLWithPath: dir + "ds-probe-src.wav")
        try? FileManager.default.removeItem(at: url)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sr, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false])
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        for i in 0..<n { buf.floatChannelData![0][i] = s[i] }
        try file.write(from: buf)
        return (url, s)
    }

    static func state(for unit: AVAudioUnit, sample: URL) -> [String: Any] {
        var st = unit.auAudioUnit.fullState ?? [:]
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?> <DecentSampler _presetName="FoF Probe" _samplePath="\(sample.deletingLastPathComponent().path)/"><groups attack="0.0" decay="0.0" sustain="1.0" release="5.0"><group><sample path="\(sample.path)" rootNote="60" loNote="0" hiNote="127" loVel="1" hiVel="127" pitchKeyTrack="0" loopEnabled="false"/></group></groups></DecentSampler>
        """
        var d = Data("VC2!".utf8)
        var len = UInt32(xml.utf8.count).littleEndian
        d.append(Data(bytes: &len, count: 4))
        d.append(Data(xml.utf8)); d.append(0)
        st["jucePluginState"] = d
        return st
    }

    /// Hochwertig umgerechnete Quelle.
    static func ideal(_ src: [Float], to rate: Double) -> [Float] {
        let inF = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let outF = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let conv = AVAudioConverter(from: inF, to: outF)!
        conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        conv.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        let inB = AVAudioPCMBuffer(pcmFormat: inF, frameCapacity: AVAudioFrameCount(src.count + 4096))!
        inB.frameLength = AVAudioFrameCount(src.count + 4096)
        for i in 0..<Int(inB.frameLength) { inB.floatChannelData![0][i] = i < src.count ? src[i] : 0 }
        let outB = AVAudioPCMBuffer(pcmFormat: outF, frameCapacity: AVAudioFrameCount(Double(src.count + 8192) * rate / 44_100))!
        var fed = false
        _ = conv.convert(to: outB, error: nil) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return inB
        }
        return Array(UnsafeBufferPointer(start: outB.floatChannelData![0], count: Int(outB.frameLength)))
    }

    /// Restfehler (dB) nach Ausrichtung (ganze Samples, ±2000) und Pegelanpassung über `len`.
    static func residualDB(_ got: [Float], _ ref: [Float], len: Int) -> (db: Double, lag: Int, gain: Double) {
        guard let on = got.firstIndex(where: { abs($0) > 1e-4 }) else { return (0, 0, 0) }
        var best = (score: -Double.infinity, lag: 0)
        let win = min(len, ref.count)
        for lag in max(0, on - 2000)...(on + 200) where lag + win <= got.count {
            var c = 0.0
            for i in stride(from: 0, to: 4096, by: 1) { c += Double(got[lag + i]) * Double(ref[i]) }
            if c > best.score { best = (c, lag) }
        }
        let g = Array(got[best.lag..<min(got.count, best.lag + win)]), r = Array(ref[0..<g.count])
        var gr = 0.0, rr = 0.0
        for i in g.indices { gr += Double(g[i]) * Double(r[i]); rr += Double(r[i]) * Double(r[i]) }
        let gain = gr / max(rr, 1e-12)
        var err = 0.0, sig = 0.0
        for i in g.indices { let e = Double(g[i]) - gain * Double(r[i]); err += e * e; sig += gain * gain * Double(r[i]) * Double(r[i]) }
        return (10 * log10(max(err, 1e-20) / max(sig, 1e-20)), best.lag, gain)
    }

    /// Quelle analytisch (bandbegrenzt bis auf den Einsatz): s(t) wie `makeSource`.
    static func s(_ t: Double) -> Double {
        t < 0 ? 0 : (0.35 * sin(2 * .pi * 1000 * t) + 0.15 * sin(2 * .pi * 5000 * t)) * exp(-t * 3)
    }

    /// Restfehler gegen die analytische Quelle mit feiner Verzögerung (Bruchteile eines
    /// Samples); Einsatz (erste 3 ms) ausgenommen. Rückgabe dB, Verzögerung in Samples.
    static func analyticResidual(_ got: [Float], rate: Double, short: Bool = false) -> (db: Double, delay: Double) {
        guard let on = got.firstIndex(where: { abs($0) > 1e-4 }) else { return (0, 0) }
        let from = Int(rate * 0.003), len = Int(rate * (short ? 0.05 : 0.3))
        func fit(_ d: Double) -> (err: Double, sig: Double) {
            var gr = 0.0, rr = 0.0
            for i in from..<len where on + i < got.count {
                let r = s((Double(i) - d) / rate); gr += Double(got[on + i]) * r; rr += r * r
            }
            let g = gr / max(rr, 1e-12)
            var err = 0.0, sig = 0.0
            for i in from..<len where on + i < got.count {
                let r = g * s((Double(i) - d) / rate); let e = Double(got[on + i]) - r
                err += e * e; sig += r * r
            }
            return (err, sig)
        }
        var best = (d: 0.0, e: Double.infinity, s: 1.0)
        for k in -20...200 {                  // grob: Vorschwinger eines Umrechners vor dem Einsatz
            let d = Double(k)
            let f = fit(d); if f.err < best.e { best = (d, f.err, f.sig) }
        }
        let c = best.d
        for k in -100...100 {                 // fein: ±1 Sample in 1/100
            let d = c + Double(k) / 100
            let f = fit(d); if f.err < best.e { best = (d, f.err, f.sig) }
        }
        return (10 * log10(max(best.e, 1e-20) / max(best.s, 1e-20)), Double(on) + best.d)
    }

    final class Capture { var l: [Float] = []; var stamps: [(index: Int, host: UInt64)] = [] }

    static func tapTimed(_ node: AVAudioNode, into cap: Capture) {
        node.installTap(onBus: 0, bufferSize: 512, format: nil) { b, when in
            let n = Int(b.frameLength); let p = b.floatChannelData![0]
            let chunk = Array(UnsafeBufferPointer(start: p, count: n))
            let host = when.isHostTimeValid ? when.hostTime : 0
            DispatchQueue.main.async { cap.stamps.append((cap.l.count, host)); cap.l += chunk }
        }
    }

    /// Timing über das Rack: Noten zu Future-Zeitstempeln, Einsatz je Note gegen Plan (ms).
    func timing(rate: Double?, src: URL, report: inout String) async throws {
        let rack = InstrumentRack()
        let id = try #require(rack.addChannel(name: "DS"))
        rack.setMuted(id, true)
        let probe = try await Self.instantiate()
        let data = try PropertyListSerialization.data(fromPropertyList: Self.state(for: probe, sample: src),
                                                      format: .binary, options: 0)
        rack.setInstrument(PluginRef(description: Self.desc, name: "DecentSampler", state: data), for: id)
        let deadline = Date().addingTimeInterval(15)
        while rack.instrumentStatus[id] == .loading, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        try #require(rack.instrumentStatus[id] == .ready)
        rack.setRenderRate(rate, for: id)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let gain = try #require(rack._liveGain(id))
        let outRate = gain.outputFormat(forBus: 0).sampleRate
        let cap = Capture(); Self.tapTimed(gain, into: cap)
        try await Task.sleep(nanoseconds: 300_000_000)
        let q = rack.queue(rack.route(for: id))
        let t0 = mach_absolute_time() + UInt64(50_000_000.0 * Self.ticksPerNs)
        var planned: [UInt64] = []
        for k in 0..<12 {
            // 250 ms Abstand plus ungerader Versatz: Einsätze fallen in verschiedene Blockstellen.
            let t = t0 + UInt64((Double(k) * 250_000_000.0 + Double(k * 1_337 % 997) * 11_000) * Self.ticksPerNs)
            planned.append(t)
            q.pushFromTick(0x90, 60, 100, at: t)
            q.pushFromTick(0x80, 60, 0, at: t + UInt64(200_000_000.0 * Self.ticksPerNs))
        }
        try await Task.sleep(nanoseconds: 3_600_000_000)
        gain.removeTap(onBus: 0)
        // Abstände der Einsätze gegen die geplanten Abstände — unabhängig von Zeitstempeln.
        var errs: [Double] = []
        guard let first = cap.l.firstIndex(where: { abs($0) > 1e-4 }) else { return }
        func onset(near idx: Int) -> Double? {
            let from = max(0, idx - 400), to = min(cap.l.count, idx + Int(outRate * 0.12))
            guard to - from > Int(outRate * 0.1) else { return nil }
            let slice = Array(cap.l[from..<to])
            guard let on = slice.firstIndex(where: { abs($0) > 1e-4 }) else { return nil }
            let r = Self.analyticResidual(Array(slice[max(0, on - 50)...]), rate: outRate, short: true)
            return Double(from + max(0, on - 50)) + r.delay
        }
        guard let o0 = onset(near: first) else { return }
        for (k, t) in planned.enumerated() {
            let expect = o0 + Double(t - planned[0]) / (1_000_000_000.0 * Self.ticksPerNs) * outRate
            guard let ok = onset(near: Int(expect)) else { continue }
            if k > 0 { errs.append((ok - expect) / outRate * 1000) }
        }
        let mean = errs.reduce(0, +) / Double(max(1, errs.count))
        let sd = sqrt(errs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(max(1, errs.count)))
        report += "E Rack rate \(rate.map { "\(Int($0))" } ?? "Gerät") (Instrument \(Int(rack.instrumentRenderRate(id) ?? 0))): Abstand − Plan Mittel \(String(format: "%.3f", mean)) ms, Streuung \(String(format: "%.3f", sd)) ms, n \(errs.count), min \(String(format: "%.3f", errs.min() ?? 0)) max \(String(format: "%.3f", errs.max() ?? 0))\n"
        rack.removeChannel(id)
    }

    /// Einsatzabstände gegen Plan (ms) für Noten 2…n, relativ zur ersten Note.
    static func spacingErrors(_ l: [Float], planned: [Double], rate: Double) -> [Double] {
        guard let first = l.firstIndex(where: { abs($0) > 1e-4 }) else { return [] }
        func onset(near idx: Int) -> Double? {
            let from = max(0, idx - 400), to = min(l.count, idx + Int(rate * 0.12))
            guard to - from > Int(rate * 0.1) else { return nil }
            let slice = Array(l[from..<to])
            guard let on = slice.firstIndex(where: { abs($0) > 1e-4 }) else { return nil }
            let r = analyticResidual(Array(slice[max(0, on - 50)...]), rate: rate, short: true)
            return Double(from + max(0, on - 50)) + r.delay
        }
        guard let o0 = onset(near: first) else { return [] }
        return planned.dropFirst().compactMap { t in
            let expect = o0 + (t - planned[0]) * rate
            return onset(near: Int(expect)).map { ($0 - expect) / rate * 1000 }
        }
    }

    /// (v1.18.15) Dieselbe Notenfolge wie `timing`, aber ohne FoF: nackte Engine, Noten mit
    /// absoluter Sample-Zeit über `scheduleMIDIEventBlock`. Zeigt, ob die späte erste Note vom
    /// Plug-in kommt oder vom Rack.
    @Test func bareFirstNote() async throws {
        guard Self.enabled else { return }
        var src = try Self.makeSource()
        if let alt = try? String(contentsOfFile: Self.dir + "fof-ds-probe", encoding: .utf8),
           !alt.isEmpty { src.url = URL(fileURLWithPath: alt) }
        let e = AVAudioEngine()
        let u = try await Self.instantiate()
        u.auAudioUnit.fullState = Self.state(for: u, sample: src.url)
        e.attach(u)
        let rate = e.outputNode.outputFormat(forBus: 0).sampleRate
        e.connect(u, to: e.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!)
        e.mainMixerNode.outputVolume = 0
        try e.start()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let cap = Capture(); Self.tap(u, into: cap)
        try await Task.sleep(nanoseconds: 300_000_000)
        let now = try #require(u.lastRenderTime?.sampleTime)
        let base = Double(now) + 0.1 * rate
        var planned: [Double] = []
        let block = try #require(u.auAudioUnit.scheduleMIDIEventBlock)
        for k in 0..<12 {
            let t = Double(k) * 0.25 + Double(k * 1_337 % 997) * 11e-6
            planned.append(t)
            var on: (UInt8, UInt8, UInt8) = (0x90, 60, 100), off: (UInt8, UInt8, UInt8) = (0x80, 60, 0)
            withUnsafeBytes(of: &on) { block(AUEventSampleTime(base + t * rate), 0, 3, $0.bindMemory(to: UInt8.self).baseAddress!) }
            withUnsafeBytes(of: &off) { block(AUEventSampleTime(base + (t + 0.2) * rate), 0, 3, $0.bindMemory(to: UInt8.self).baseAddress!) }
        }
        try await Task.sleep(nanoseconds: 3_600_000_000)
        u.removeTap(onBus: 0); e.stop()
        let errs = Self.spacingErrors(cap.l, planned: planned, rate: rate)
        let mean = errs.reduce(0, +) / Double(max(1, errs.count))
        let line = "F nackt, Sample-Zeit: Abstand − Plan Mittel \(String(format: "%.3f", mean)) ms, min \(String(format: "%.3f", errs.min() ?? 0)) max \(String(format: "%.3f", errs.max() ?? 0)), n \(errs.count)\n"
        try line.write(toFile: Self.dir + "ds-report-bare.txt", atomically: true, encoding: .utf8)
    }

    static func tap(_ node: AVAudioNode, into cap: Capture) {
        node.installTap(onBus: 0, bufferSize: 512, format: nil) { b, _ in
            let n = Int(b.frameLength); let p = b.floatChannelData![0]
            let chunk = Array(UnsafeBufferPointer(start: p, count: n))
            DispatchQueue.main.async { cap.l += chunk }
        }
    }

    @Test func compareHosts() async throws {
        guard Self.enabled else { return }
        var src = try Self.makeSource()
        // Liest das Plug-in (eigener Prozess) das Container-tmp nicht, nennt die Steuerdatei
        // eine Kopie außerhalb.
        if let alt = try? String(contentsOfFile: Self.dir + "fof-ds-probe", encoding: .utf8),
           !alt.isEmpty { src.url = URL(fileURLWithPath: alt) }
        var report = ""

        // (A) nackte Engine
        do {
            let e = AVAudioEngine()
            let u = try await Self.instantiate()
            u.auAudioUnit.fullState = Self.state(for: u, sample: src.url)
            e.attach(u)
            let rate = e.outputNode.outputFormat(forBus: 0).sampleRate
            let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            e.connect(u, to: e.mainMixerNode, format: fmt)
            e.mainMixerNode.outputVolume = 0
            try e.start()
            try await Task.sleep(nanoseconds: 1_500_000_000)          // Laden des Samples
            if let d = u.auAudioUnit.fullState?["jucePluginState"] as? Data {
                report += "A state back: " + String(decoding: d.dropFirst(8), as: UTF8.self).prefix(1500) + "\n"
            }
            let cap = Capture(); Self.tap(u, into: cap)
            try await Task.sleep(nanoseconds: 200_000_000)
            var on: (UInt8, UInt8, UInt8) = (0x90, 60, 100)
            withUnsafeBytes(of: &on) { u.auAudioUnit.scheduleMIDIEventBlock?(AUEventSampleTimeImmediate, 0, 3, $0.bindMemory(to: UInt8.self).baseAddress!) }
            try await Task.sleep(nanoseconds: 900_000_000)
            u.removeTap(onBus: 0); e.stop()
            let r = Self.residualDB(cap.l, Self.ideal(src.samples, to: rate), len: Int(rate * 0.4))
            let ra = Self.analyticResidual(cap.l, rate: rate)
            report += "A analytisch \(String(format: "%.1f", ra.db)) dB\n"
            report += "A nackt   rate \(rate) maxFrames \(u.auAudioUnit.maximumFramesToRender) captured \(cap.l.count) residual \(String(format: "%.1f", r.db)) dB gain \(String(format: "%.3f", r.gain))\n"
            try Self.write(cap.l, rate: rate, name: "ds-A.wav")
        }

        // (C) nackte Engine, DS rendert mit 44,1 kHz (Rate des Samples); die Engine rechnet um.
        for rateC in [44_100.0, 96_000.0] {
            let e = AVAudioEngine()
            let u = try await Self.instantiate()
            u.auAudioUnit.fullState = Self.state(for: u, sample: src.url)
            e.attach(u)
            let fmt = AVAudioFormat(standardFormatWithSampleRate: rateC, channels: 2)!
            let mixer = AVAudioMixerNode(); e.attach(mixer)
            e.connect(u, to: mixer, format: fmt)
            let devRate = e.outputNode.outputFormat(forBus: 0).sampleRate
            e.connect(mixer, to: e.mainMixerNode,
                      format: AVAudioFormat(standardFormatWithSampleRate: devRate, channels: 2)!)
            e.mainMixerNode.outputVolume = 0
            try e.start()
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let cap = Capture(); Self.tap(u, into: cap)
            let capM = Capture(); Self.tap(mixer, into: capM)
            try await Task.sleep(nanoseconds: 200_000_000)
            var on: (UInt8, UInt8, UInt8) = (0x90, 60, 100)
            withUnsafeBytes(of: &on) { u.auAudioUnit.scheduleMIDIEventBlock?(AUEventSampleTimeImmediate, 0, 3, $0.bindMemory(to: UInt8.self).baseAddress!) }
            try await Task.sleep(nanoseconds: 900_000_000)
            u.removeTap(onBus: 0); mixer.removeTap(onBus: 0); e.stop()
            let outRate = mixer.outputFormat(forBus: 0).sampleRate
            let rm = Self.residualDB(capM.l, Self.ideal(src.samples, to: outRate), len: Int(outRate * 0.4))
            let rma = Self.analyticResidual(capM.l, rate: outRate)
            let rua = Self.analyticResidual(cap.l, rate: rateC)
            report += "C DS@\(Int(rateC)): DS \(String(format: "%.1f", rua.db)) dB · → Engine-SRC → \(Int(outRate)): \(String(format: "%.1f", rma.db)) dB (int-Ausrichtung \(String(format: "%.1f", rm.db)))\n"
            let ref = rateC == 44_100 ? src.samples : Self.ideal(src.samples, to: rateC)
            let r = Self.residualDB(cap.l, ref, len: Int(rateC * 0.4))
            report += "C DS@\(Int(rateC)) residual \(String(format: "%.1f", r.db)) dB gain \(String(format: "%.3f", r.gain))\n"
        }

        // (B) FoF-Rack, Note über die Kanal-Warteschlange (Render-Observer, Sample-Offset)
        do {
            let rack = InstrumentRack()
            let id = try #require(rack.addChannel(name: "DS"))
            rack.setMuted(id, true)
            let probe = try await Self.instantiate()
            let st = Self.state(for: probe, sample: src.url)
            let data = try PropertyListSerialization.data(fromPropertyList: st, format: .binary, options: 0)
            rack.setInstrument(PluginRef(description: Self.desc, name: "DecentSampler", state: data), for: id)
            let deadline = Date().addingTimeInterval(15)
            while rack.instrumentStatus[id] == .loading, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
            try #require(rack.instrumentStatus[id] == .ready)
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let u = try #require(rack._liveInstrument(id))
            let rate = u.outputFormat(forBus: 0).sampleRate
            let cap = Capture(); Self.tap(u, into: cap)
            try await Task.sleep(nanoseconds: 200_000_000)
            let route = rack.route(for: id)
            let q = rack.queue(route)
            // Future-Zeitstempel wie der Tick-Pfad: 30 ms voraus.
            let ahead = mach_absolute_time() + UInt64(30_000_000.0 * Self.ticksPerNs)
            q.pushFromTick(0x90, 60, 100, at: ahead)
            try await Task.sleep(nanoseconds: 900_000_000)
            u.removeTap(onBus: 0)
            let r = Self.residualDB(cap.l, Self.ideal(src.samples, to: rate), len: Int(rate * 0.4))
            let rb = Self.analyticResidual(cap.l, rate: rate)
            report += "B analytisch \(String(format: "%.1f", rb.db)) dB\n"
            report += "B FoF     rate \(rate) maxFrames \(u.auAudioUnit.maximumFramesToRender) captured \(cap.l.count) residual \(String(format: "%.1f", r.db)) dB gain \(String(format: "%.3f", r.gain)) renderErrors \(q.renderErrors.load(ordering: .relaxed)) pre \(q.preRenders.load(ordering: .relaxed))\n"
            try Self.write(cap.l, rate: rate, name: "ds-B.wav")
            rack.removeChannel(id)
        }
        try await timing(rate: nil, src: src.url, report: &report)
        try await timing(rate: 44_100, src: src.url, report: &report)
        try report.write(toFile: Self.dir + "ds-report.txt", atomically: true, encoding: .utf8)
    }

    static let ticksPerNs: Double = {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        return Double(tb.denom) / Double(tb.numer)
    }()

    static func write(_ s: [Float], rate: Double, name: String) throws {
        let url = URL(fileURLWithPath: dir + name)
        try? FileManager.default.removeItem(at: url)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let f = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(max(1, s.count)))!
        b.frameLength = AVAudioFrameCount(s.count)
        for i in s.indices { b.floatChannelData![0][i] = s[i] }
        try f.write(from: b)
    }
}
