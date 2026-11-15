import Foundation
import Combine

// MARK: - PresetEditorState (Pre-Lane Slice C)
//
// Ausgelagert aus SequencerEngine in PresetEditorState, damit Preset-I/O-Writes
// (currentPresetURL, hasUnsavedChanges, recentFiles, lastErrorMessage, clipboard,
// stepClipboard, swing) kein engine.objectWillChange feuern und keine engine-weiten
// View-Invalidierungen auslösen.
//
// Schreiber:
//   - SequencerEngine+PresetIO.swift (loadData, savePreset, newProject, …)
//   - SequencerEngine.rebuildAllTrackSubs() → hasUnsavedChanges = true (via Track-Sink)
//   - SequencerEngine.setupTransportSinks() → hasUnsavedChanges = true bei BPM-Änderung
//   - StretchHandleView.swift → hasUnsavedChanges = true bei Step-Ratio-Änderung
//
// Leser:
//   - TransportView (hasUnsavedChanges, currentPresetURL, swing)
//   - StepSelectionToolbar (stepClipboard)
//   - VintageSequencerApp Commands (recentFiles, clipboard) — via engine computed properties
//     + gezielte Forwarding-Sinks (recentFiles, clipboard → engine.objectWillChange)
//   - AppDelegate (hasUnsavedChanges) — via engine.hasUnsavedChanges computed property
//
// Analog zu TransportState, PlaybackDisplayState, ScrollState, StepWidthState,
// ClockDiagnosticsState, MIDIManager (direkt).

final class PresetEditorState: ObservableObject {

    // MARK: - Swing (50 = gerade, 75 = maximales Triplet-Feeling)
    //
    // Lebt hier statt in TransportState, weil swing ein Preset-Attribut ist (wird
    // serialisiert) und bei Load/Save/Reset dieselben Pfade wie currentPresetURL und
    // hasUnsavedChanges durchläuft.
    @Published var swing: Double = 50.0 {
        didSet { hasUnsavedChanges = true }
    }

    // MARK: - Unsaved-Indikator
    //
    // True sobald patterns/bpm/swing seit dem letzten Save/Load geändert wurden.
    // Wird von TransportView als oranger Punkt neben dem Dateinamen angezeigt.
    @Published var hasUnsavedChanges: Bool = false {
        didSet { if hasUnsavedChanges { changeEpoch &+= 1 } }
    }
    /// Zählt jede Änderungsmeldung (v1.16.1): ein asynchrones Speichern setzt den
    /// Indikator nur zurück, wenn seit seinem Beginn keine Änderung kam.
    private(set) var changeEpoch = 0
    /// Änderung melden, ohne `objectWillChange` erneut auszulösen, wenn schon markiert.
    func markChanged() {
        if hasUnsavedChanges { changeEpoch &+= 1 } else { hasUnsavedChanges = true }
    }

    // MARK: - Aktuell geladene/gespeicherte Datei
    //
    // nil = neues Projekt ohne Datei-URL.
    // TransportView zeigt lastPathComponent oder "—".
    @Published var currentPresetURL: URL? = nil

    // MARK: - Recent Files
    //
    // Zuletzt geöffnete/gespeicherte Presets (max. 10).
    // VintageSequencerApp Commands (Open Recent) liest dieses Feld.
    @Published var recentFiles: [URL] = []

    // MARK: - Letzter Fehler aus Preset-I/O (B3)
    //
    // Wird bei jedem neuen Fehler überschrieben; nil = kein ausstehender Fehler.
    // Bleibt hier statt in einer eigenen ErrorState — gehört zum Preset-I/O-Pfad.
    @Published var lastErrorMessage: String? = nil

    // MARK: - Pattern Clipboard
    //
    // Quelle: copyCurrentPattern() — vollständige Pattern-Kopie.
    // Ziel:   pasteToCurrentPattern() — überschreibt currentPattern (Name behalten).
    @Published var clipboard: Pattern? = nil

    // MARK: - Step Clipboard
    //
    // Quelle: copySteps(from:at:) — Teilkopie einzelner Steps.
    // Ziel:   pasteSteps(to:at:) — schreibt Steps an ausgewählte Positionen.
    @Published var stepClipboard: [Step] = []
}
