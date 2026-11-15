import SwiftUI

// MARK: - NotesReaderView

/// Full reader and editor for all stored note entries.
///
/// Presented as a sheet — intentionally separate from Quick Capture.
/// Left panel: scrollable entry list, sorted newest-first.
/// Right panel: in-place editor for the selected entry.
struct NotesReaderView: View {
    @AppStorage("appLanguage") private var lang: String = "en"
    private var s: Str { Str(lang) }

    @ObservedObject var store: NotesStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedID: UUID?    = nil
    @State private var editText:   String   = ""
    @State private var editKind:   NoteKind = .note
    @State private var isDirty:    Bool     = false

    private var selectedEntry: NoteEntry? {
        store.entries.first { $0.id == selectedID }
    }

    var body: some View {
        HSplitView {
            listPanel
                .frame(minWidth: 230, maxWidth: 300)

            detailPanel
                .frame(minWidth: 340)
        }
        .frame(width: 700, height: 500)
        .background(VintageTheme.background)
        .preferredColorScheme(.dark)
    }

    // MARK: - List panel

    private var listPanel: some View {
        VStack(spacing: 0) {

            // Header
            HStack {
                Text(s.notesTitle)
                    .font(VintageTheme.monoBold)
                    .foregroundColor(VintageTheme.textAmber)
                Spacer()
                Text("\(store.entries.count)")
                    .font(VintageTheme.monoSmall)
                    .foregroundColor(VintageTheme.textSecondary)
                    .monospacedDigit()
                Button(s.close) { dismiss() }
                    .buttonStyle(VintageSmallButtonStyle(isActive: false, accent: .gray))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(VintageTheme.panelDark)

            Rectangle().fill(VintageTheme.panelBorder).frame(height: 1)

            if store.entries.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "note.text")
                        .font(.system(size: 28))
                        .foregroundColor(VintageTheme.textDim)
                    Text(s.notesEmpty)
                        .font(VintageTheme.monoSmall)
                        .foregroundColor(VintageTheme.textDim)
                        .padding(.top, 6)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.entries) { entry in
                            NoteRowView(
                                entry:      entry,
                                isSelected: entry.id == selectedID
                            ) {
                                selectEntry(entry)
                            }
                            Rectangle()
                                .fill(VintageTheme.panelBorder)
                                .frame(height: 1)
                        }
                    }
                }
            }
        }
        .background(VintageTheme.panel)
    }

    // MARK: - Detail panel

    @ViewBuilder
    private var detailPanel: some View {
        if let entry = selectedEntry {
            VStack(spacing: 0) {

                // Kind picker + metadata
                HStack(spacing: 6) {
                    ForEach(NoteKind.allCases) { k in
                        Button {
                            editKind = k
                            isDirty  = true
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: k.icon).font(.system(size: 9))
                                Text(k.label)
                            }
                            .font(VintageTheme.monoSmall)
                        }
                        .buttonStyle(VintageSmallButtonStyle(isActive: editKind == k,
                                                              accent: k.accentColor))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(s.notesCreated(entry.createdAt.noteDate))
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(VintageTheme.textDim)
                        if entry.updatedAt > entry.createdAt {
                            Text(s.notesEdited(entry.updatedAt.noteDate))
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundColor(VintageTheme.textDim)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(VintageTheme.panelDark)

                Rectangle().fill(VintageTheme.panelBorder).frame(height: 1)

                // Editor
                TextEditor(text: $editText)
                    .font(VintageTheme.monoMedium)
                    .foregroundColor(VintageTheme.textPrimary)
                    .hiddenScrollBackground()
                    .background(VintageTheme.background)
                    .padding(10)
                    .onValueChange(of: editText) { _ in isDirty = true }

                Rectangle().fill(VintageTheme.panelBorder).frame(height: 1)

                // Action bar
                HStack(spacing: 8) {
                    Button(s.notesDelete) {
                        store.delete(id: entry.id)
                        selectedID = nil
                        editText   = ""
                        isDirty    = false
                    }
                    .buttonStyle(VintageSmallButtonStyle(isActive: false, accent: .red))

                    Spacer()

                    if isDirty {
                        Text(s.notesUnsaved)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(Color.orange.opacity(0.8))
                    }

                    Button(s.notesSave) { saveEdit(entry) }
                        .buttonStyle(VintageSmallButtonStyle(
                            isActive: isDirty,
                            accent:   VintageTheme.amber))
                        .disabled(!isDirty || editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .keyboardShortcut("s", modifiers: .command)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(VintageTheme.panelDark)
            }
        } else {
            // Empty state
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "note.text")
                    .font(.system(size: 34))
                    .foregroundColor(VintageTheme.textDim)
                Text(s.notesSelectHint)
                    .font(VintageTheme.monoSmall)
                    .foregroundColor(VintageTheme.textDim)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Helpers

    private func selectEntry(_ entry: NoteEntry) {
        selectedID = entry.id
        editText   = entry.text
        editKind   = entry.kind
        isDirty    = false
    }

    private func saveEdit(_ entry: NoteEntry) {
        guard isDirty else { return }
        var updated      = entry
        updated.text     = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.kind     = editKind
        store.update(updated)
        isDirty = false
    }
}

// MARK: - NoteRowView

private struct NoteRowView: View {
    let entry:      NoteEntry
    let isSelected: Bool
    let onSelect:   () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: entry.kind.icon)
                    .font(.system(size: 9))
                    .foregroundColor(entry.kind.accentColor)
                    .frame(width: 14)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.text)
                        .font(VintageTheme.monoSmall)
                        .foregroundColor(VintageTheme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(entry.createdAt.noteDate)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(VintageTheme.textDim)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isSelected
                ? Color.white.opacity(0.06)
                : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.fullArea)
    }
}

// MARK: - Date formatting helper

private extension Date {
    /// Short date+time string for compact display in the notes list.
    var noteDate: String {
        let f        = DateFormatter()
        f.dateStyle  = .short
        f.timeStyle  = .short
        return f.string(from: self)
    }
}
