import Foundation
import AVFoundation
import AudioToolbox

// MARK: - Apple-Sampler als Instrument (v1.18.16)
//
// Stephan: „Battery ist gestorben, das muss mit anderen samplern gehen. also wird zukünftig apple
// sampler genommen." Gemessen (AppleSamplerProbeTests):
// - Der AUSampler läuft wie jedes Plug-in außerhalb des App-Prozesses. Ein Instrument (EXS,
//   SoundFont, DLS, aupreset) lädt er dort aber nicht über `kAUSamplerProperty_LoadInstrument`
//   (−10879: die Eigenschaft trägt einen CFURL-Zeiger und geht nicht über die Prozessgrenze).
// - Deshalb wandelt FoF ein Instrument im App-Prozess mit einer kurzlebigen Sampler-Instanz um
//   (Systembestandteil, lädt keinen fremden Code) und übergibt den Zustand (`fullState`) wie
//   jeden Plug-in-Zustand. Der Zustand nennt die Samples mit absoluten Pfaden
//   (`file-references`); der Hostprozess liest sie selbst.
// - Fehlen die Dateien unter diesen Pfaden, meldet der Sampler keine Verweise. Auf einem anderen
//   Rechner (iMac: `/Volumes/DATEN/Music/…` statt `~/Music/…`) biegt FoF die Pfade vor dem Setzen
//   des Zustands auf freigegebene Sample-Ordner um (`SampleFolders.locate`).
// - Die Sandbox lässt FoF nur in freigegebene Ordner sehen; zum Umwandeln braucht FoF die
//   Samples lesbar (Freigabe als Lesezeichen, einmal je Rechner).

enum AppleSampler {
    static let description = AudioComponentDescription(
        componentType: kAudioUnitType_MusicDevice, componentSubType: kAudioUnitSubType_Sampler,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)

    static func isSampler(_ d: AudioComponentDescription) -> Bool {
        d.componentType == description.componentType && d.componentSubType == description.componentSubType
            && d.componentManufacturer == description.componentManufacturer
    }
    static func isSampler(_ ref: PluginRef?) -> Bool { ref.map { isSampler($0.componentDescription) } ?? false }

    /// Instrumentdateien, die der Sampler laden kann.
    static let fileTypes: [String: Int] = [
        "exs": Int(kInstrumentType_EXS24), "sf2": Int(kInstrumentType_SF2Preset),
        "dls": Int(kInstrumentType_DLSPreset), "aupreset": Int(kInstrumentType_AUPreset),
    ]

    enum Failure: Error, Equatable {
        case unsupported
        case unavailable
        case loadFailed(OSStatus)
        /// Keine oder nicht alle Samples lesbar (Sandbox: Ordner nicht freigegeben, oder fehlend).
        case missingSamples(found: Int, missing: Int)
    }

    /// Ergebnis der Umwandlung: Zustand (Plist-Daten wie `PluginRef.state`) und, bei EXS mit
    /// Sperrgruppen/One-Shot, die Drum-Gruppen (v1.18.28).
    struct Converted {
        let state: Data
        let drumMap: DrumMap?
    }

    /// Umwandlungen nacheinander (v1.18.28): zwei gleichzeitige `LoadInstrument` auf getrennten
    /// Sampler-Instanzen im selben Prozess brechen in CoreAudio ab (CAVerboseAbort, gesehen
    /// bei zwei parallelen Tests).
    private static let loadQueue = DispatchQueue(label: "fof.appleSampler.load", qos: .userInitiated)

    /// Wandelt eine Instrumentdatei in einen Sampler-Zustand. Abschluss auf Main.
    static func convert(_ url: URL, completion: @escaping (Result<Converted, Failure>) -> Void) {
        guard let type = fileTypes[url.pathExtension.lowercased()] else {
            completion(.failure(.unsupported)); return
        }
        // Im App-Prozess: nur dieser Systembestandteil, nie fremde Plug-ins (v1.13.7).
        AVAudioUnit.instantiate(with: description, options: []) { unit, _ in
            guard let unit else { DispatchQueue.main.async { completion(.failure(.unavailable)) }; return }
            loadQueue.async {
                let result = load(url, type: type, into: unit)
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    private static func load(_ url: URL, type: Int, into unit: AVAudioUnit) -> Result<Converted, Failure> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let cf = url as CFURL
        var data = AUSamplerInstrumentData(fileURL: Unmanaged.passUnretained(cf), instrumentType: UInt8(type),
                                           bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
                                           bankLSB: UInt8(kAUSampler_DefaultBankLSB), presetID: 0)
        let status = withExtendedLifetime(cf) {
            AudioUnitSetProperty(unit.audioUnit, kAUSamplerProperty_LoadInstrument, kAudioUnitScope_Global, 0,
                                 &data, UInt32(MemoryLayout<AUSamplerInstrumentData>.size))
        }
        guard status == noErr else { return .failure(.loadFailed(status)) }
        guard var state = unit.auAudioUnit.fullState else { return .failure(.loadFailed(-1)) }
        // Import mit alten absoluten Pfaden im Instrument (Codex): gelistete, hier nicht lesbare
        // Verweise auf freigegebene Ordner umbiegen und dem Sampler erneut geben.
        let moved = relocate(state)
        if references(moved) != references(state) {
            unit.auAudioUnit.fullState = moved
            if let again = unit.auAudioUnit.fullState { state = again }
        }
        let refs = references(state)
        let missing = refs.values.filter { !SampleFolders.isReadableFile(path(of: $0)) }.count
        if refs.isEmpty || missing > 0 { return .failure(.missingSamples(found: refs.count - missing, missing: missing)) }
        // Drum-Gruppen: der Import verwirft Exclusive und One-Shot des EXS (v1.18.28).
        var drums: DrumMap?
        if type == Int(kInstrumentType_EXS24), let raw = try? Data(contentsOf: url), let map = DrumMap.exs(raw) {
            drums = map
            state = map.shortenChokeReleases(state).state
        }
        guard let plist = try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
        else { return .failure(.loadFailed(-2)) }
        return .success(Converted(state: plist, drumMap: drums))
    }

    static func references(_ state: [String: Any]) -> [String: String] {
        state["file-references"] as? [String: String] ?? [:]
    }

    /// Dateipfad eines Verweises: EXS-Samples stehen als Pfad, SoundFont-/DLS-Bänke (`Bank:n`)
    /// als `file://`-URL (gemessen, v1.18.17).
    static func path(of reference: String) -> String {
        reference.hasPrefix("file://") ? (URL(string: reference)?.path ?? reference) : reference
    }

    /// Neuer Verweis in derselben Schreibweise wie `original`.
    static func reference(_ path: String, like original: String) -> String {
        original.hasPrefix("file://") ? URL(fileURLWithPath: path).absoluteString : path
    }

    /// Verweise, die hier nicht lesbar sind, auf freigegebene Ordner umbiegen (eindeutiges,
    /// längstes Pfadende über alle Ordner, je Verweis, Codex R15-05). Nicht oder nicht eindeutig gefundene
    /// bleiben unverändert (der Hostprozess versucht sie selbst). Beliebiger Thread.
    static func relocate(_ state: [String: Any], folders: SampleFolders = .shared) -> [String: Any] {
        var refs = references(state)
        guard !refs.isEmpty else { return state }
        var changed = false
        // Jeder Verweis einzeln über die globale Eindeutigkeitsregel (Codex R15-05: keine
        // Abkürzung über ein schon gefundenes Präfix, die einen Gleichstand übergehen könnte).
        for (key, ref) in refs where !SampleFolders.isReadableFile(path(of: ref)) {
            guard let found = folders.locate(path(of: ref)) else { continue }
            refs[key] = reference(found, like: ref); changed = true
        }
        guard changed else { return state }
        var out = state
        out["file-references"] = refs
        return out
    }
}

// MARK: - Freigegebene Sample-Ordner (Lesezeichen, je Rechner)

/// Security-Scoped-Bookmarks (nur lesen). Ein Zugriff gilt nur, wenn er tatsächlich aufgeht
/// (Codex R15-06); offene Zugriffe bleiben für die Sitzung offen und werden beim Entfernen
/// oder Ersetzen durch einen übergeordneten Ordner ausgeglichen geschlossen. Thread-sicher.
final class SampleFolders {
    static let shared = SampleFolders()
    static let defaultsKey = "samplerFolders"

    private let defaults: UserDefaults
    private let lock = NSLock()
    /// `scoped`: Zugriff geöffnet (wird ausgeglichen geschlossen). Ohne Scope zählt ein Ordner
    /// nur, wenn er ohnehin lesbar ist.
    private var entries: [(url: URL, bookmark: Data, scoped: Bool)] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for data in defaults.array(forKey: Self.defaultsKey) as? [Data] ?? [] {
            if let e = Self.open(data) { entries.append(e) }   // unauflösbare fallen weg
        }
        save()   // erneuerte (veraltete) Lesezeichen sichern
    }

    deinit { for e in entries where e.scoped { e.url.stopAccessingSecurityScopedResource() } }

    /// Lesezeichen auflösen und Zugriff öffnen; nil, wenn der Ordner danach nicht lesbar ist.
    private static func open(_ data: Data) -> (url: URL, bookmark: Data, scoped: Bool)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        guard scoped || FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        return (url, stale ? (bookmark(url) ?? data) : data, scoped)
    }

    private static func bookmark(_ url: URL) -> Data? {
        try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                              includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func save() { defaults.set(entries.map(\.bookmark), forKey: Self.defaultsKey) }

    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return entries.map(\.url) }

    /// Ordner freigeben (aus einem Auswahldialog). false, wenn kein Lesezeichen entsteht oder der
    /// Zugriff nicht aufgeht. Darin liegende, schon freigegebene Ordner werden ersetzt.
    @discardableResult
    func add(_ url: URL) -> Bool {
        if covers(url) { return true }
        guard let data = Self.bookmark(url), let e = Self.open(data) else { return false }
        lock.lock()
        let inner = entries.filter { Self.path($0.url, isInside: e.url) }
        entries.removeAll { Self.path($0.url, isInside: e.url) }
        entries.append(e)
        lock.unlock()
        for i in inner where i.scoped { i.url.stopAccessingSecurityScopedResource() }
        save()
        return true
    }

    func remove(_ url: URL) {
        lock.lock()
        let gone = entries.filter { $0.url.standardizedFileURL == url.standardizedFileURL }
        entries.removeAll { $0.url.standardizedFileURL == url.standardizedFileURL }
        lock.unlock()
        for e in gone where e.scoped { e.url.stopAccessingSecurityScopedResource() }
        save()
    }

    private static func path(_ inner: URL, isInside outer: URL) -> Bool {
        let p = inner.standardizedFileURL.path, f = outer.standardizedFileURL.path
        return p == f || p.hasPrefix(f + "/")
    }

    func covers(_ url: URL) -> Bool { urls.contains { Self.path(url, isInside: $0) } }

    static func isReadableFile(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && !dir.boolValue
            && FileManager.default.isReadableFile(atPath: path)
    }

    /// Lesbare Datei unter einem freigegebenen Ordner mit dem längsten zu `path` passenden
    /// Pfadende (mindestens Ordner + Datei). nil, wenn keiner passt oder zwei gleich gut passen.
    func locate(_ path: String) -> String? {
        let parts = path.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        var best: (len: Int, path: String)?
        var tie = false
        for folder in urls {
            let base = folder.standardizedFileURL.path
            for i in 0...(parts.count - 2) {          // längstes Ende zuerst
                let len = parts.count - i
                if let b = best, len < b.len { break }
                let candidate = base + "/" + parts[i...].joined(separator: "/")
                guard Self.isReadableFile(candidate) else { continue }
                if let b = best, b.len == len { tie = tie || b.path != candidate }
                else { best = (len, candidate); tie = false }
                break
            }
        }
        return tie ? nil : best?.path
    }
}
