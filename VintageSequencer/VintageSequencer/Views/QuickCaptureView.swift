import SwiftUI

// MARK: - QuickCaptureView

/// Lightweight popover for rapid note entry.
///
/// Design goal: capture a thought without interrupting the workflow.
///   - Text field focused on appear
///   - ⌘↩ saves and clears — popover stays open for follow-up entries
///   - No navigation to the reader — that is intentionally separate
struct QuickCaptureView: View {

    @ObservedObject var store: NotesStore
    @AppStorage("appLanguage") private var lang: String = "en"
    private var s: Str { Str(lang) }

    @State private var text: String    = ""
    @State private var kind: NoteKind  = .note
    @FocusState private var textFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // ── Header ──────────────────────────────────────────────────────
            HStack(spacing: 6) {
                Image(systemName: "pencil.circle.fill")
                    .foregroundColor(VintageTheme.textAmber)
                Text(s.quickCaptureTitle)
                    .font(VintageTheme.monoBold)
                    .foregroundColor(VintageTheme.textAmber)
            }

            // ── Kind picker ──────────────────────────────────────────────────
            HStack(spacing: 6) {
                ForEach(NoteKind.allCases) { k in
                    Button {
                        kind = k
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: k.icon)
                                .font(.system(size: 9))
                            Text(k.label)
                        }
                        .font(VintageTheme.monoSmall)
                    }
                    .buttonStyle(VintageSmallButtonStyle(isActive: kind == k,
                                                         accent: k.accentColor))
                }
            }

            // ── Text input ──────────────────────────────────────────────────
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(VintageTheme.stepInactive)

                if text.isEmpty {
                    Text(s.quickCapturePlaceholder)
                        .font(VintageTheme.monoMedium)
                        .foregroundColor(VintageTheme.textDim)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $text)
                    .font(VintageTheme.monoMedium)
                    .foregroundColor(VintageTheme.textPrimary)
                    .hiddenScrollBackground()
                    .background(.clear)
                    .focused($textFocused)
                    .padding(4)
            }
            .frame(minHeight: 80, maxHeight: 120)

            // ── Action row ──────────────────────────────────────────────────
            HStack {
                Text(s.quickCaptureSaveHint)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(VintageTheme.textDim)
                Spacer()
                Button(s.notesSave) { commit() }
                    .buttonStyle(VintageSmallButtonStyle(
                        isActive: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        accent:   VintageTheme.amber))
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(16)
        .frame(width: 300)
        .background(VintageTheme.panelDark)
        .preferredColorScheme(.dark)
        .onAppear { textFocused = true }
    }

    // MARK: - Actions

    private func commit() {
        store.add(kind: kind, text: text)
        text        = ""
        textFocused = true   // keep focus for rapid follow-up entry
    }
}

// MARK: - NoteKind accent color (view layer only)

extension NoteKind {
    var accentColor: Color {
        switch self {
        case .note: return VintageTheme.amber
        case .idea: return Color(red: 0.25, green: 0.75, blue: 0.40)
        case .bug:  return Color(red: 0.85, green: 0.28, blue: 0.28)
        }
    }
}
