import SwiftUI

// MARK: - Blatt-Views für hochfrequente Lane-Zustände (v1.12.20)
//
// Playhead (`PlaybackDisplayState`) und horizontaler Scroll (`ScrollState`) ändern sich
// im Playback bzw. beim Scrollen viele Male pro Sekunde. Die Lane-Views (StepGridView,
// CCLaneBodyView) beobachten diese Objekte bewusst NICHT selbst — sonst liefe bei jedem
// Tick und jedem Scroll-Event der komplette Lane-Body samt aller Gesten-Closures neu.
// Stattdessen beobachten nur die kleinen Views/Modifier in dieser Datei.
//
// Regel: Wer in einer Lane Playhead oder Scroll-Offset für die DARSTELLUNG braucht, nutzt
// einen dieser Bausteine. Wer den Scroll-Offset nur in einer Geste (zum Ereigniszeitpunkt)
// braucht, liest ihn über `engine.scrollState.hScrollOffset` — ohne Beobachtung.

/// Verschiebt den Inhalt um den globalen horizontalen Scroll-Offset.
struct LaneScrollShift: ViewModifier {
    @EnvironmentObject private var scrollState: ScrollState
    func body(content: Content) -> some View {
        content.offset(x: -scrollState.hScrollOffset)
    }
}

extension View {
    /// Scrollt diese View mit dem globalen Lane-Offset (siehe `LaneScrollShift`).
    func laneScrollShift() -> some View { modifier(LaneScrollShift()) }
}

/// Liefert seinem Inhalt, ob `stepIndex` der aktuell gespielte Step des Tracks ist.
/// Nur dieser Wrapper läuft pro Tick neu; der Inhalt entscheidet per `.equatable()`
/// bzw. Wertvergleich, ob er tatsächlich neu rendert.
struct PlayheadGate<Content: View>: View {
    @EnvironmentObject private var playbackDisplay: PlaybackDisplayState
    let trackIndex: Int
    let stepIndex:  Int
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        let steps = playbackDisplay.steps
        content(trackIndex >= 0 && trackIndex < steps.count && steps[trackIndex] == stepIndex)
    }
}

/// Sichtbares Rubber-Band-Rechteck einer Lane (Screen-Space = Content-Space − Scroll).
struct RubberBandLayer: View {
    @ObservedObject var grid: StepGridCoordinator
    @EnvironmentObject private var scrollState: ScrollState
    let height: CGFloat

    var body: some View {
        if let anchorContent  = grid.rubberAnchorContentX,
           let currentContent = grid.rubberCurrentContentX {
            let anchorScreen  = anchorContent  - scrollState.hScrollOffset
            let currentScreen = currentContent - scrollState.hScrollOffset
            RubberBandOverlayView(
                left:   min(anchorScreen, currentScreen),
                width:  max(4, abs(currentScreen - anchorScreen)),
                height: height
            )
        }
    }
}
