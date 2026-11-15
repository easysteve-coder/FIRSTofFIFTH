import AVFoundation

// MARK: - Audio-Loop im Preset (v1.15.0)

/// Material eines Audio-Loop-Kanals im Preset (Schlüssel `audioLoops`). Das Audio steht
/// komprimiert (Apple Lossless, 24 Bit, CAF) als Base64 im JSON — das Projekt bleibt eine
/// Datei, auch in der Sandbox.
///
/// Speichervertrag (v1.15.1, Codex M7): Das Material ist Float mit additivem Overdub und kann
/// über ±1 liegen. Vor der 24-Bit-Quantisierung wird es mit `scale` (≤ 1) so skaliert, dass der
/// Spitzenwert ±1 nicht übersteigt; beim Laden wird durch `scale` geteilt. Verlust: nur die
/// 24-Bit-Quantisierung relativ zum Spitzenwert (≈ −144 dBFS), kein Clipping. NaN/∞ werden als
/// 0 gespeichert. Ältere Versionen ignorieren `scale` und spielen skaliertes Material leiser.
struct AudioLoopFile: Codable, Equatable {
    var channel:     UUID
    var bars:        Int
    var barFrames:   Int
    var sampleRate:  Double
    var recordedBPM: Double
    var audio:       Data
    /// Skalierung vor der Quantisierung (1 = keine). Optional seit v1.15.1.
    var scale:       Float?
}

enum AudioLoopCodec {

    /// Obergrenze der Audiodaten einer Datei (roh, vor dem Dekodieren): 120 s Stereo-Float
    /// bei der höchsten zugelassenen Rate. Größere Daten werden nicht angefasst.
    static let maxAudioBytes = Int(AudioLoopSettings.maxSeconds * AudioLoopStorage.sampleRateRange.upperBound) * 8

    /// Kodiert das Material (Main). nil bei Fehlern.
    static func encode(_ s: AudioLoopStorage, channel: UUID) -> AudioLoopFile? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: s.sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(s.frames)),
              let ch = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(s.frames)
        s.left.read(into: ch[0], from: 0, count: s.frames)
        s.right.read(into: ch[1], from: 0, count: s.frames)
        var peak: Float = 0
        for c in 0..<2 {
            for i in 0..<s.frames {
                if !ch[c][i].isFinite { ch[c][i] = 0 }
                peak = max(peak, abs(ch[c][i]))
            }
        }
        // Knapp unter Vollaussteuerung, damit die Integer-Quantisierung nicht clippt.
        let scale: Float = peak > 0.999 ? 0.999 / peak : 1
        if scale != 1 {
            for c in 0..<2 { for i in 0..<s.frames { ch[c][i] *= scale } }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fof-loop-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: s.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitDepthHintKey: 24,
        ]
        do {
            // Eigener Gültigkeitsbereich: die Datei wird beim Freigeben des Objekts geschlossen.
            do {
                let file = try AVAudioFile(forWriting: url, settings: settings,
                                           commonFormat: .pcmFormatFloat32, interleaved: false)
                try file.write(from: buffer)
            }
            let data = try Data(contentsOf: url)
            return AudioLoopFile(channel: channel, bars: s.bars, barFrames: s.barFrames,
                                 sampleRate: s.sampleRate, recordedBPM: s.recordedBPM, audio: data,
                                 scale: scale == 1 ? nil : scale)
        } catch {
            return nil
        }
    }

    /// Wandelt einen Puffer in Stereo-Float mit Rate `sr` (Main). nil bei Fehlern.
    static func convert(_ src: AVAudioPCMBuffer, to sr: Double) -> AVAudioPCMBuffer? {
        let ratio = sr / src.format.sampleRate
        guard let dstFormat = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2),
              let conv = AVAudioConverter(from: src.format, to: dstFormat),
              let dst = AVAudioPCMBuffer(pcmFormat: dstFormat,
                                         frameCapacity: AVAudioFrameCount(Double(src.frameLength) * ratio) + 1024)
        else { return nil }
        var given = false
        var err: NSError?
        conv.convert(to: dst, error: &err) { _, status in
            if given { status.pointee = .endOfStream; return nil }
            given = true; status.pointee = .haveData; return src
        }
        return err == nil ? dst : nil
    }

    /// Material auf eine andere Abtastrate umrechnen (Gerätewechsel, Codex H6). Taktlänge in
    /// Frames passt sich an; der Undo-Stand entfällt. nil bei Fehlern.
    static func resample(_ s: AudioLoopStorage, to sr: Double) -> AudioLoopStorage? {
        guard sr > 0, abs(sr - s.sampleRate) >= 1,
              let format = AVAudioFormat(standardFormatWithSampleRate: s.sampleRate, channels: 2),
              let src = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(s.frames)),
              let ch = src.floatChannelData else { return nil }
        src.frameLength = AVAudioFrameCount(s.frames)
        s.left.read(into: ch[0], from: 0, count: s.frames)
        s.right.read(into: ch[1], from: 0, count: s.frames)
        let barFrames = Int((Double(s.barFrames) * sr / s.sampleRate).rounded())
        guard let dst = convert(src, to: sr), let out = dst.floatChannelData,
              let st = AudioLoopStorage(bars: s.bars, sampleRate: sr, bpm: s.recordedBPM, barFrames: barFrames)
        else { return nil }
        let n = min(Int(dst.frameLength), st.frames)
        st.left.write(from: out[0], at: 0, count: n)
        st.right.write(from: out[1], at: 0, count: n)
        return st
    }

    /// Dekodiert das Material. Weicht die Abtastrate der Anlage ab, wird umgerechnet
    /// (Taktlänge in Frames passt sich an). nil bei Fehlern.
    /// Länge in Frames, die `decode` bei der Zielrate anlegen würde (aus geprüften
    /// Metadaten, vor jedem Dekodieren — fürs Speicherbudget). nil bei ungültigen Werten.
    static func targetFrames(_ f: AudioLoopFile, sampleRate target: Double) -> Int? {
        guard AudioLoopStorage.barRange.contains(f.bars), f.barFrames > 0, f.sampleRate.isFinite,
              AudioLoopStorage.sampleRateRange.contains(f.sampleRate) else { return nil }
        let sr = target > 0 ? target : f.sampleRate
        let bf = Double(f.barFrames) * sr / f.sampleRate
        guard bf.isFinite, bf < Double(Int.max / 32) else { return nil }
        let (n, overflow) = Int(bf.rounded()).multipliedReportingOverflow(by: f.bars)
        return overflow ? nil : n
    }

    static func decode(_ f: AudioLoopFile, targetSampleRate: Double) -> AudioLoopStorage? {
        // Metadaten vor jeder Allokation prüfen (Codex H9): Länge, Rate, Tempo, Skalierung.
        guard f.audio.count <= maxAudioBytes,
              AudioLoopStorage.barRange.contains(f.bars), f.barFrames > 0,
              f.sampleRate.isFinite, AudioLoopStorage.sampleRateRange.contains(f.sampleRate),
              f.recordedBPM.isFinite, AudioLoopStorage.bpmRange.contains(f.recordedBPM)
        else { return nil }
        let (srcFrames, overflow) = f.barFrames.multipliedReportingOverflow(by: f.bars)
        guard !overflow, Double(srcFrames) <= AudioLoopSettings.maxSeconds * f.sampleRate else { return nil }
        let scale = f.scale ?? 1
        guard scale.isFinite, scale > 0, scale <= 1 else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fof-loop-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try f.audio.write(to: url)
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let srcFormat = file.processingFormat
            // Datei und Metadaten müssen übereinstimmen (Codex R4): gleiche Abtastrate und die
            // Länge in beide Richtungen nur um eine kleine Kodierungstoleranz verschieden —
            // sonst Wiederherstellungsfehler statt falscher Tonhöhe oder aufgefüllter Stille.
            guard abs(srcFormat.sampleRate - f.sampleRate) < 1,
                  abs(Int(file.length) - srcFrames) <= 4096,
                  srcFormat.channelCount >= 1, srcFormat.channelCount <= 2 else { return nil }
            guard let src = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
            try file.read(into: src)
            let sr = targetSampleRate > 0 ? targetSampleRate : f.sampleRate
            let ratio = sr / srcFormat.sampleRate   // tatsächliche Rate der Datei
            let barFrames = Int((Double(f.barFrames) * ratio).rounded())
            guard let st = AudioLoopStorage(bars: f.bars, sampleRate: sr, bpm: f.recordedBPM,
                                            barFrames: barFrames) else { return nil }
            var buffer = src
            if abs(ratio - 1) > 1e-9 || srcFormat.channelCount != 2 {
                guard let dst = convert(src, to: sr) else { return nil }
                buffer = dst
            }
            guard let ch = buffer.floatChannelData else { return nil }
            let n = min(Int(buffer.frameLength), st.frames)
            let rc = buffer.format.channelCount > 1 ? 1 : 0
            let inv = 1 / scale
            for i in 0..<n {
                let l = ch[0][i] * inv, r = ch[rc][i] * inv
                st.left[i] = l.isFinite ? l : 0
                st.right[i] = r.isFinite ? r : 0
            }
            return st
        } catch {
            return nil
        }
    }
}
