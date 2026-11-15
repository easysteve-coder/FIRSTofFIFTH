import Foundation
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - PresetManager

/// Handles preset serialization, file-panel I/O, and recent-files bookmark management.
/// Owns no published state — all @Published properties remain on SequencerEngine.
/// SequencerEngine holds one instance: `private let presetManager = PresetManager()`.
final class PresetManager {

    // MARK: - Constants

    static let recentFilesKey = "recentPresetBookmarks"
    static let maxRecent      = 10

    // MARK: - Preset File Format

    struct PresetFile: Codable {
        var bpm:      Double
        var swing:    Double
        var patterns: [Pattern]
        /// Instrumentenkanäle (v1.13.0). Optional: fehlt in Presets bis v1.12.23 und
        /// in Projekten ohne gehostete Instrumente.
        var instruments: [InstrumentChannelData]?
        /// Summenpegel des Racks (v1.13.1), 0 … 1. Optional; fehlt → 1.
        var masterVolume: Float?
        /// Song (v1.14.0). Optional; fehlt → leerer Song, Song-Modus aus.
        var song: Song?
        /// Material der Audio-Loop-Kanäle (v1.15.0). Optional.
        var audioLoops: [AudioLoopFile]?
        /// Taktart (v1.18.12), z. B. "7/8". Optional; fehlt → 4/4 (nur geschrieben, wenn ≠ 4/4).
        /// Seit v1.18.24 Vorgabe für Patterns ohne eigenen Schlüssel (ältere Dateien); geschrieben
        /// wird die Taktart des aktuellen Patterns (für ältere FoF-Versionen).
        var timeSignature: TimeSignature?
        /// Patternwechsel ohne Song (v1.18.24, Entscheidung E3): "bar" = nächster Taktstrich,
        /// "track1" = Ende von Spur 1. Optional; fehlt → "track1" (bisheriges Verhalten).
        var patternSwitch: String?
    }

    // MARK: - Decode Result

    enum DecodeResult {
        /// Full wrapper format — bpm, swing, and patterns are all present.
        case modern(PresetFile)
        /// Legacy format (pre-wrapper) — only patterns were serialized.
        /// Callers should preserve the current bpm and swing values.
        case legacy(patterns: [Pattern])
    }

    // MARK: - Encode

    /// Encodes engine state into JSON data.
    /// Returns nil on encoding failure; caller is responsible for setting an error message.
    func encode(bpm: Double, swing: Double, patterns: [Pattern],
                instruments: [InstrumentChannelData] = [], masterVolume: Float = 1,
                song: Song = Song(), audioLoops: [AudioLoopFile] = [],
                timeSignature: TimeSignature = .common, switchOnBar: Bool = false) -> Data? {
        try? JSONEncoder().encode(PresetFile(bpm: bpm, swing: swing, patterns: patterns,
                                             instruments: instruments.isEmpty ? nil : instruments,
                                             masterVolume: instruments.isEmpty ? nil : masterVolume,
                                             song: song == Song() ? nil : song,
                                             audioLoops: audioLoops.isEmpty ? nil : audioLoops,
                                             timeSignature: timeSignature == .common ? nil : timeSignature,
                                             patternSwitch: switchOnBar ? "bar" : "track1"))
    }

    // MARK: - Decode

    /// Decodes preset JSON; supports the modern wrapper format and the legacy [Pattern] array.
    /// Returns nil if the data cannot be parsed in either format.
    /// Im Fehlerfall wird der Decode-Fehler des zum Dokument passenden Formats geliefert
    /// (Top-Level-Array → Legacy, sonst Wrapper), damit der Nutzer den Grund sieht.
    func decode(_ data: Data) -> Result<DecodeResult, Error> {
        let decoder = JSONDecoder()
        let looksLegacy = data.first(where: { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }) == UInt8(ascii: "[")
        do {
            if looksLegacy {
                return .success(.legacy(patterns: try decoder.decode([Pattern].self, from: data)))
            }
            return .success(.modern(try decoder.decode(PresetFile.self, from: data)))
        } catch {
            return .failure(error)
        }
    }

    /// Kurze, lesbare Beschreibung eines Decode-Fehlers (fehlender Key samt Pfad usw.).
    static func describe(_ error: Error) -> String {
        func path(_ ctx: DecodingError.Context) -> String {
            let p = ctx.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
                .joined(separator: ".")
            return p.isEmpty ? "root" : p
        }
        guard let e = error as? DecodingError else { return error.localizedDescription }
        switch e {
        case .keyNotFound(let key, let ctx):  return "missing key '\(key.stringValue)' at \(path(ctx))"
        case .typeMismatch(_, let ctx):       return "wrong type at \(path(ctx))"
        case .valueNotFound(_, let ctx):      return "missing value at \(path(ctx))"
        case .dataCorrupted(let ctx):         return "invalid data at \(path(ctx))"
        @unknown default:                     return error.localizedDescription
        }
    }

    // MARK: - Recent Files (security-scoped bookmarks)

    /// Loads the recent-files list from UserDefaults. Silently drops stale or missing entries.
    func loadBookmarks() -> [URL] {
        guard let list = UserDefaults.standard.array(forKey: Self.recentFilesKey) as? [Data] else {
            return []
        }
        return list.compactMap { data in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data,
                                     options: .withSecurityScope,
                                     relativeTo: nil,
                                     bookmarkDataIsStale: &stale)
            else { return nil }
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    /// Persists a URL to the front of the recent-files list, deduplicating by path.
    func addToBookmarks(_ url: URL) {
        guard let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
        else { return }

        var list = UserDefaults.standard.array(forKey: Self.recentFilesKey) as? [Data] ?? []
        // Remove existing entry for the same path (move-to-front on re-open).
        list = list.filter { data in
            var stale = false
            guard let existing = try? URL(resolvingBookmarkData: data,
                                          options: .withSecurityScope,
                                          relativeTo: nil,
                                          bookmarkDataIsStale: &stale)
            else { return false }
            return existing.path != url.path
        }
        list.insert(bookmark, at: 0)
        if list.count > Self.maxRecent { list = Array(list.prefix(Self.maxRecent)) }
        UserDefaults.standard.set(list, forKey: Self.recentFilesKey)
    }

    /// Removes all recent-files bookmarks from UserDefaults.
    func clearBookmarks() {
        UserDefaults.standard.removeObject(forKey: Self.recentFilesKey)
    }

    // MARK: - File Panels

    /// Shows NSSavePanel and writes data to the chosen location on confirmation.
    /// Returns the saved URL, or nil if the user cancelled. Throws on write failure.
    func chooseSaveURL(title: String, suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title                = title
        panel.allowedContentTypes  = [UTType.json]
        panel.nameFieldStringValue = suggestedName
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    /// Setzt kodierte Loops in ein ohne Loops kodiertes Preset ein (Hintergrund, v1.16.1).
    /// Gleicher Schlüssel und gleiche Kodierung wie `encode`; nil bei Fehler.
    static func merge(_ base: Data, audioLoops: [AudioLoopFile]) -> Data? {
        guard !audioLoops.isEmpty else { return base }
        guard var obj = (try? JSONSerialization.jsonObject(with: base)) as? [String: Any],
              let loops = try? JSONEncoder().encode(audioLoops),
              let loopsObj = try? JSONSerialization.jsonObject(with: loops) else { return nil }
        obj["audioLoops"] = loopsObj   // Schlüssel von `PresetFile.audioLoops`
        return try? JSONSerialization.data(withJSONObject: obj)
    }

    /// Shows NSOpenPanel and reads the selected file.
    /// Returns (data, url), or nil if the user cancelled. Throws on read failure.
    func runOpenPanel(title: String) throws -> (data: Data, url: URL)? {
        let panel = NSOpenPanel()
        panel.title                   = title
        panel.allowedContentTypes     = [UTType.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let data = try Data(contentsOf: url)
        return (data, url)
    }
}
