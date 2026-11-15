import Foundation

// MARK: - AudioLoopAssets (v1.15.2, Codex M6)
//
// Besitzer des Loop-Materials (Main): PCM-Speicher je Kanal, beim Laden nicht
// wiederhergestellte Originaldaten, Vorkodierung im Hintergrund, Kodieren/Dekodieren fürs
// Preset und die Wellenform. Das Rack bleibt Besitzer von Graph, Kanälen und Kernen und
// bindet Speicher nur noch an Kerne — Medien- und Codec-Arbeit liegt hier.

final class AudioLoopAssets {

    /// Material je Audio-Loop-Kanal (an den Kern des Kanals gebunden).
    private(set) var storage: [UUID: AudioLoopStorage] = [:]
    /// Beim Laden nicht wiederhergestelltes Material, unverändert (Codex H8).
    private var unrestored: [UUID: AudioLoopFile] = [:]

    /// Vorkodiertes Material: gilt nur für genau diesen Speicher in genau dieser Version.
    /// Schwach auf den Speicher: der Zwischenspeicher hält kein abgelöstes PCM am Leben.
    private struct Encoded { weak var storage: AudioLoopStorage?; let version: Int; let file: AudioLoopFile }
    private var encoded: [UUID: Encoded] = [:]
    private var encoding: Set<UUID> = []
    private static let encodeQueue = DispatchQueue(label: "com.firstoffifth.loop-encode", qos: .utility)

    // MARK: Speicher

    subscript(_ id: UUID) -> AudioLoopStorage? { storage[id] }

    /// Neues Material für einen Kanal (ersetzt auch nicht wiederhergestellte Originaldaten).
    func set(_ st: AudioLoopStorage?, for id: UUID) {
        storage[id] = st
        unrestored[id] = nil
    }

    /// Kanal entfernt: alles zu ihm vergessen.
    func remove(_ id: UUID) {
        storage[id] = nil
        unrestored[id] = nil
        encoded[id] = nil
    }

    func frames(_ id: UUID) -> Int { storage[id]?.frames ?? 0 }

    // MARK: Vorkodieren

    /// Kodiert ruhendes Material im Hintergrund. `version` = Materialversion des Kerns;
    /// `current` prüft nach dem Kodieren auf Main, ob Speicher und Version noch gelten.
    func preencode(_ id: UUID, version: Int, current: @escaping (AudioLoopStorage, Int) -> Bool,
                   retry: @escaping () -> Void) {
        guard !encoding.contains(id), let st = storage[id] else { return }
        if let c = encoded[id], c.storage === st, c.version == version { return }
        encoding.insert(id)
        Self.encodeQueue.async { [weak self] in
            // Der Hintergrund liest das PCM atomar; die starke Referenz hält den Speicher.
            let file = AudioLoopCodec.encode(st, channel: id)
            DispatchQueue.main.async {
                guard let self else { return }
                self.encoding.remove(id)
                guard let file, self.storage[id] === st, current(st, version) else { retry(); return }
                self.encoded[id] = Encoded(storage: st, version: version, file: file)
            }
        }
    }

    // MARK: Preset

    /// Datei eines Kanals fürs Preset: vorkodierter Stand, wenn er passt, sonst jetzt
    /// kodieren; ohne Material die unverändert behaltenen Originaldaten.
    /// `.failure`, wenn vorhandenes Material nicht kodiert werden kann.
    enum FileResult { case file(AudioLoopFile), none, failure }

    func file(_ id: UUID, version: Int?) -> FileResult {
        if let st = storage[id], let version {
            if let c = encoded[id], c.storage === st, c.version == version { return .file(c.file) }
            guard let f = AudioLoopCodec.encode(st, channel: id) else { return .failure }
            return .file(f)
        }
        if let kept = unrestored[id] { return .file(kept) }
        return .none
    }

    /// Speichern ohne Kodieren auf Main (v1.16.1, Codex V16-2): fertige Datei, oder der
    /// unveränderliche Speicher dieser Version zum Kodieren im Hintergrund.
    enum SaveJob { case file(AudioLoopFile), encode(AudioLoopStorage, version: Int), none }

    func saveJob(_ id: UUID, version: Int?) -> SaveJob {
        if let st = storage[id], let version {
            if let c = encoded[id], c.storage === st, c.version == version { return .file(c.file) }
            return .encode(st, version: version)
        }
        if let kept = unrestored[id] { return .file(kept) }
        return .none
    }

    /// Hintergrund-Kodierung für einen Speicher-Auftrag (beliebiger Thread).
    static func encodeForSave(_ st: AudioLoopStorage, channel: UUID) -> AudioLoopFile? {
        AudioLoopCodec.encode(st, channel: channel)
    }

    /// Ergebnis eines Speicher-Auftrags übernehmen (Main) — gilt nur, solange Speicher und
    /// Version noch dieselben sind.
    func adopt(_ file: AudioLoopFile, storage st: AudioLoopStorage, version: Int, for id: UUID,
               current: (AudioLoopStorage, Int) -> Bool) {
        guard storage[id] === st, current(st, version) else { return }
        encoded[id] = Encoded(storage: st, version: version, file: file)
    }

    /// Vor dem Wiederherstellen eines Projekts: alte Originaldaten verwerfen.
    func beginRestore() { unrestored.removeAll() }

    /// Dekodiert eine Datei auf `sampleRate` — Größe aus den geprüften Metadaten, Budget
    /// vor dem Dekodieren (Codex R5). Misslingt es, bleiben die Originaldaten erhalten.
    func restore(_ f: AudioLoopFile, sampleRate: Double) -> AudioLoopStorage? {
        guard let frames = AudioLoopCodec.targetFrames(f, sampleRate: sampleRate),
              AudioLoopStorage.fits(frames: frames),
              let st = AudioLoopCodec.decode(f, targetSampleRate: sampleRate)
        else { unrestored[f.channel] = f; return nil }
        storage[f.channel] = st
        return st
    }

    /// Material mit abweichender Rate umrechnen (Codex H6); `canReplace` prüft, ob der Kern
    /// ruht. Rückgabe: neu gebundene Speicher.
    func resample(to sr: Double, canReplace: (UUID) -> Bool) -> [(UUID, AudioLoopStorage)] {
        var out: [(UUID, AudioLoopStorage)] = []
        for (id, st) in storage where abs(st.sampleRate - sr) >= 1 {
            let frames = Int((Double(st.barFrames) * sr / st.sampleRate).rounded()) * st.bars
            guard canReplace(id), AudioLoopStorage.fits(frames: frames),
                  let new = AudioLoopCodec.resample(st, to: sr) else { continue }
            storage[id] = new
            out.append((id, new))
        }
        return out
    }

    // MARK: Anzeige

    /// Wellenform (Min/Max je Abschnitt) des Materials eines Kanals.
    func waveform(_ id: UUID, buckets: Int) -> [AudioLoopDisplay.WaveBucket] {
        guard let st = storage[id], buckets > 0 else { return [] }
        let per = max(1, st.frames / buckets)
        return (0..<buckets).map { b in
            var lo: Float = 0, hi: Float = 0
            let start = b * per, end = min(st.frames, start + per)
            var i = start
            while i < end {
                let v = (st.left[i] + st.right[i]) * 0.5
                lo = min(lo, v); hi = max(hi, v)
                i += max(1, per / 256)   // grob abtasten: Anzeige, keine Messung
            }
            return AudioLoopDisplay.WaveBucket(lo: lo, hi: hi)
        }
    }

    #if DEBUG
    var _preencodedCount: Int { encoded.count }
    var _encodingCount: Int { encoding.count }
    #endif
}
