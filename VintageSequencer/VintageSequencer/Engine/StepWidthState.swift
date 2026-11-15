import Combine
import Foundation

/// Isolierter ObservableObject-Container für die Step-Breite.
///
/// Ausgelagert aus `SequencerEngine`, damit Width-/Pinch-Änderungen keine
/// Engine-weite SwiftUI-Re-Render-Kaskade auslösen: `@Published var stepWidthSize`
/// auf dem globalen `SequencerEngine`-Objekt feuerte bei jeder Slider-/Pinch-Änderung
/// `objectWillChange` auf der Engine — alle beobachtenden Views (TransportView,
/// TrackRowView ×8, StepButtonView ×128, SettingsView, …) wurden neu evaluiert,
/// obwohl ausschließlich StepGridView und zugehörige Views die Step-Breite lesen.
///
/// Injektion: `engine.stepWidthState` wird in `VintageSequencerApp` als eigenes
/// `.environmentObject(engine.stepWidthState)` weitergegeben — analog zu
/// `playbackDisplay` und `scrollState`.
///
/// **Schreiber:** GlobalPinchZoomModifier (MainView), Width-Slider (TransportView).
/// **Leser:** StepGridView, MainView, CCLaneBodyView.
final class StepWidthState: ObservableObject {

    /// Breite der Step-Buttons in Pixeln (30–120).
    /// Der Bereich wird hier durchgesetzt — unabhängig davon, welcher Schreiber (Fader,
    /// Pinch, gespeicherter Wert) einen Wert liefert.
    static let range: ClosedRange<Double> = 30...120

    /// Startwert: Mitte des Bereichs (50 % des Schiebers). Seit v1.16.2 wird der zuletzt
    /// benutzte Wert nicht mehr übernommen — jeder Start beginnt hier.
    static let startSize: Double = (range.lowerBound + range.upperBound) / 2

    @Published var size: Double = StepWidthState.startSize {
        didSet {
            let clamped = min(max(size, Self.range.lowerBound), Self.range.upperBound)
            if clamped != size { size = clamped }   // didSet läuft für den geklemmten Wert erneut
        }
    }
}
