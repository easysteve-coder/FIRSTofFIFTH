import Foundation
import Combine

// MARK: - MIDILearnState (Pre-Lane Slice D)
//
// Ausgelagert aus SequencerEngine: patternSwitchCC, trackMuteCCs, learnMode,
// learnTarget — damit CC-Remote-Control- und Learn-Writes kein
// engine.objectWillChange feuern und keine engine-weiten View-Invalidierungen
// (StepButton, TrackRow, TrackHeader) auslösen.
//
// Schreiber:
//   - SequencerEngine+MIDILearn.swift (handleIncomingCC, handleLearnNoteOn,
//     setLearnTarget) — via engine Computed-Accessors, transparent für Extensions.
//   - TransportView (learnMode toggle, learnTarget = nil beim Deaktivieren).
//   - SettingsView (patternSwitchCC Stepper, trackMuteCCs Stepper per Index).
//
// Leser:
//   - TransportView (learnMode — LEARN-Button Zustand und Label).
//   - StepButtonView (learnMode + learnTarget — Highlight-Ring, Tap-Handler).
//   - SettingsView (patternSwitchCC, trackMuteCCs — Stepper-Anzeige + Bindings).
//
// learnTarget ist bewusst NICHT @Published:
//   Beim schrittweisen Advance im Learn-Session-Pfad (handleLearnNoteOn) soll
//   kein objectWillChange gefeuert werden — identisch zum bisherigen Verhalten
//   (learnTarget war auch in SequencerEngine plain var). Nur learnMode-Änderungen
//   (Aktivieren/Deaktivieren) lösen StepButton-Re-Renders aus.
//
// Analog zu TransportState, PlaybackDisplayState, ScrollState, StepWidthState,
// ClockDiagnosticsState, PresetEditorState, MIDIManager (direkt).

final class MIDILearnState: ObservableObject {

    // MARK: - CC Remote Control

    /// CC-Nummer für Pattern-Switch (–1 = deaktiviert).
    /// Wertbereich: 0–127 aktiv, –1 = Off.
    /// handleIncomingCC: value 0–31=A, 32–63=B, 64–95=C, 96–127=D.
    @Published var patternSwitchCC: Int = -1

    /// CC-Nummern für Track-Mute pro Spur (–1 = deaktiviert).
    /// 8 Einträge — korrespondieren zu Pattern-Track-Indizes 0–7.
    @Published var trackMuteCCs: [Int] = [-1, -1, -1, -1, -1, -1, -1, -1]

    // MARK: - MIDI Learn

    /// True = Learn-Modus aktiv. LEARN-Button in TransportView spiegelt diesen Zustand.
    @Published var learnMode: Bool = false

    /// Aktuell angesteuerter Step im Learn-Modus (Track-Index, Step-Index).
    /// @Published (v1.12.20): der Markierungsring in StepButtonView muss dem Ziel folgen —
    /// beim Antippen eines Steps und beim automatischen Weiterrücken nach jeder gelernten
    /// Note. Das sind Ereignisse im Bedientempo, kein Invalidierungsproblem.
    @Published var learnTarget: (track: Int, step: Int)? = nil
}
