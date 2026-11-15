import SwiftUI

// MARK: - StepSelectionToolbar

/// Action bar that appears above the step grid whenever one or more steps are selected.
///
/// Lives outside the horizontal ScrollView so it never scrolls with step content.
///
/// Responsibilities:
///   - Display "N STEPS" count label
///   - EDIT / COPY / PASTE / CLR / ✕ action buttons
///   - Invisible Escape-key handler (zero-size button, disabled when nothing selected)
///
/// All mutations go through the parent's `@Binding` properties or directly via
/// `@ObservedObject track` — no independent state is introduced.
///
/// Extracted from `TrackRowView` as part of E2 (TrackRowView decomposition, step 1).
struct StepSelectionToolbar: View {

    /// Currently selected step indices. Cleared by CLR, ✕, and Escape.
    @Binding var selectedSteps: Set<Int>

    /// true, solange das Rubberband noch aufgezogen wird. Die Leiste erscheint erst nach
    /// dem Loslassen — vorher verschob sie die Lane unter dem Zeiger (v1.12.23).
    var isSelecting: Bool = false

    /// Drives the `MultiStepEditView` sheet in the parent view.
    @Binding var showMultiEdit: Bool

    /// The track whose steps are acted on.
    @ObservedObject var track: TrackViewModel

    /// Accent color for active button highlights.
    var accentColor: Color

    @EnvironmentObject private var engine: SequencerEngine
    @EnvironmentObject private var pes: PresetEditorState
    @Environment(\.undoManager) private var undoManager
    @AppStorage("appLanguage") private var lang: String = "en"
    private let writer = ModelWriter()
    private var s: Str { Str(lang) }

    var body: some View {
        VStack(spacing: 0) {

            // ── Visible bar — only shown when a selection exists ─────────
            if !selectedSteps.isEmpty && !isSelecting {
                HStack(spacing: 6) {
                    Text(s.stepsSelected(selectedSteps.count))
                        .font(VintageTheme.monoSmall)
                        .foregroundColor(Color(red: 0.3, green: 0.6, blue: 1.0))

                    Button(s.editStepsLabel) { showMultiEdit = true }
                        .buttonStyle(VintageSmallButtonStyle(isActive: true,
                            accent: Color(red: 0.3, green: 0.6, blue: 1.0)))
                        .help(s.editStepsTip)

                    Button(s.copyStepsLabel) {
                        engine.copySteps(from: track.data, at: Array(selectedSteps))
                    }
                    .buttonStyle(VintageSmallButtonStyle(isActive: false, accent: accentColor))
                    .keyboardShortcut("c", modifiers: .command)
                    .help(s.copyStepsTip)

                    if !pes.stepClipboard.isEmpty {
                        Button(s.pasteStepsLabel) {
                            engine.pasteSteps(to: track.data, at: Array(selectedSteps).sorted())
                            selectedSteps = []
                        }
                        .buttonStyle(VintageSmallButtonStyle(isActive: false, accent: accentColor))
                        .keyboardShortcut("v", modifiers: .command)
                        .help(s.pasteStepsTip)
                    }

                    Button(s.clearStepsLabel) {
                        let old = track.lane.steps
                        var steps = track.lane.steps
                        for i in selectedSteps where steps.indices.contains(i) { steps[i] = Step() }
                        writer.apply(.setSteps(trackID: track.id,
                                               oldSteps: old,
                                               newSteps: steps,
                                               actionName: s.undoClear),
                                     to: track.data,
                                     undoManager: undoManager)
                        selectedSteps = []
                    }
                    .buttonStyle(VintageSmallButtonStyle(isActive: false, accent: .red))
                    .help(s.clearSelTip)

                    Spacer()

                    Button("✕") { selectedSteps = [] }
                        .buttonStyle(VintageSmallButtonStyle(isActive: false, accent: .gray))
                        .help(s.deselectTip)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(red: 0.10, green: 0.14, blue: 0.22))
            }

            // ── Invisible Escape-key handler ────────────────────────────
            // Zero-size button captures ⎋ globally while this view is in
            // the hierarchy. Disabled when nothing is selected so it does
            // not steal focus from other Escape consumers.
            Button("") { selectedSteps = [] }
                .keyboardShortcut(.escape, modifiers: [])
                .frame(width: 0, height: 0)
                .opacity(0)
                .disabled(selectedSteps.isEmpty)
        }
        // Wird die Spur kürzer, fallen nicht mehr vorhandene Steps aus der Auswahl.
        .onValueChange(of: track.lane.stepCount) { count in
            let valid = selectedSteps.filter { $0 < count }
            if valid.count != selectedSteps.count { selectedSteps = valid }
        }
    }
}
