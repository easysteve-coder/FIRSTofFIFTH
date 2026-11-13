import Combine
import Foundation

/// Separater Observable-Container für den hochfrequenten Playback-Anzeigezustand.
///
/// Ausgelagert aus `SequencerEngine`, damit Playback-Drain-Schreiboperationen keine
/// Engine-weite SwiftUI-Re-Render-Kaskade auslösen: `@Published var displaySteps` auf
/// dem globalen `SequencerEngine`-Objekt feuerte bei jedem Drain-Event `objectWillChange`
/// auf der Engine — alle beobachtenden Views (StepButtonView ×256, TransportView,
/// BPMGridView, TrackRowView, …) wurden neu evaluiert, obwohl ausschließlich
/// `StepGridView` die aktuellen Step-Positionen tatsächlich liest.
///
/// Injektion: `engine.playbackDisplay` wird in `VintageSequencerApp` als eigenes
/// `.environmentObject(engine.playbackDisplay)` weitergegeben — analog zu `scrollState`.
///
/// **Zuständigkeit:** Rein visueller Playback-Anzeigezustand. Keine Playback-Logik,
/// kein Scheduling, kein Modell. Nur hochfrequente UI-Positionsdaten.
///
/// **Schreiber:** Ausschließlich `SequencerEngine` (displayDrainTimer, play, stop,
/// applyPatternSwitch, startFromExternal) — immer auf dem Main-Thread.
///
/// **Leser:** `StepGridView` — berechnet `isCurrentStep`-Bool und reicht ihn
/// als Parameter an `StepButtonView` weiter. Kein weiterer View-Zugriff nötig.
final class PlaybackDisplayState: ObservableObject {

    /// Aktuell beleuchteter Step-Index pro Track.
    ///
    /// Index entspricht dem Track-Index in `SequencerEngine.currentPattern.tracks`.
    /// Wert -1 bedeutet kein aktiver Highlight (Stop-Zustand).
    @Published var steps: [Int] = []
}
