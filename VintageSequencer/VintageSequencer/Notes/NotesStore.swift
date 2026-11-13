import Foundation
import Combine

// MARK: - NotesStore

/// Standalone service for persisting and managing note entries.
///
/// **Decoupling guarantee:**
///   - No reference to SequencerEngine, TrackData, Pattern, or any audio type.
///   - No influence on Playback, Snapshot, or TransportState.
///   - Lives entirely in its own JSON file in Application Support.
///
/// **Persistence:**
///   ~/Library/Application Support/FIRSTofFIFTH/notes.json
///   Written atomically after every mutation — no data loss on crash.
///
/// **Threading:**
///   All public methods must be called on the main thread.
///   `@Published entries` is read by SwiftUI views on the main thread.
///   `save()` captures a value-type snapshot on Main and performs
///   JSON-encode + file-write on a private serial IO queue — Main is
///   never blocked by disk operations.
final class NotesStore: ObservableObject {

    // MARK: - Published state

    /// All entries, sorted newest-first. Read-only from outside.
    @Published private(set) var entries: [NoteEntry] = []

    // MARK: - Persistence URL

    private let fileURL: URL

    // MARK: - IO queue

    /// Serial queue: guarantees FIFO write order — a later snapshot can
    /// never overtake an earlier one even if the caller mutates rapidly.
    private let ioQueue = DispatchQueue(label: "com.firstoffifth.NotesStore.IO", qos: .utility)

    // MARK: - Init

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("FIRSTofFIFTH", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        self.fileURL = dir.appendingPathComponent("notes.json")
        load()
    }

    // MARK: - CRUD

    /// Appends a new entry. Trims whitespace; silently ignores empty text.
    func add(kind: NoteKind, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = NoteEntry(kind: kind, text: trimmed)
        entries.insert(entry, at: 0)   // newest first
        save()
    }

    /// Replaces the matching entry and refreshes `updatedAt`.
    ///
    /// Ignores the call if no entry with `updated.id` is found.
    func update(_ updated: NoteEntry) {
        guard let idx = entries.firstIndex(where: { $0.id == updated.id }) else { return }
        var e        = updated
        e.updatedAt  = Date()
        entries[idx] = e
        save()
    }

    /// Removes the entry with the given id. No-op if not found.
    func delete(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    // MARK: - Persistence

    private func save() {
        // Capture a value-type snapshot here on Main — safe, instantaneous.
        // Struct arrays are copy-on-write: this copy is O(1) until the background
        // closure actually reads it (at which point it materialises cheaply).
        let snapshot = entries
        let url      = fileURL          // URL is a value type — safe to capture

        ioQueue.async {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                // Logging only — no state mutation (we're off-Main here).
                print("NotesStore: save failed — \(error.localizedDescription)")
            }
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let decoder        = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let data           = try Data(contentsOf: fileURL)
            entries            = try decoder.decode([NoteEntry].self, from: data)
        } catch {
            print("NotesStore: load failed — \(error.localizedDescription)")
            entries = []
        }
    }
}
