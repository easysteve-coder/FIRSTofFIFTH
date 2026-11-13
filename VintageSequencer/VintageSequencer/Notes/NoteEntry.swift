import Foundation

// MARK: - NoteKind

/// Type tag for a note entry.
///
/// Deliberately simple — drives the kind picker in Quick Capture and the Reader.
enum NoteKind: String, Codable, CaseIterable, Identifiable {
    case note = "note"
    case idea = "idea"
    case bug  = "bug"

    var id: String { rawValue }

    /// Short display label (CAPS, consistent with app style).
    var label: String {
        switch self {
        case .note: return "NOTE"
        case .idea: return "IDEA"
        case .bug:  return "BUG"
        }
    }

    /// SF Symbol name.
    var icon: String {
        switch self {
        case .note: return "doc.text"
        case .idea: return "lightbulb"
        case .bug:  return "ant"
        }
    }
}

// MARK: - NoteEntry

/// A single note, idea, or bug report.
///
/// `id` and `createdAt` are immutable after creation.
/// `updatedAt` is refreshed by `NotesStore.update(_:)`.
/// `kind` and `text` are mutable via the Notes Reader.
struct NoteEntry: Identifiable, Codable {
    let id:        UUID
    let createdAt: Date
    var updatedAt: Date
    var kind:      NoteKind
    var text:      String

    /// Creates a fresh entry. `updatedAt` equals `createdAt` initially.
    init(kind: NoteKind, text: String) {
        let now      = Date()
        self.id        = UUID()
        self.createdAt = now
        self.updatedAt = now
        self.kind      = kind
        self.text      = text
    }
}
