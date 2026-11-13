import SwiftUI

// MARK: - LaneBodyView
//
// View-Shell für lane-kind-abhängiges Body-Rendering (Lane Slice 4).
//
// Rolle im Track-Aufbau:
//   - `TrackRowView` liefert den lane-kind-neutralen Rahmen einer Track-Zeile
//     (Header, CC-Panels, Expand-Button, Selection-Toolbar).
//   - `LaneBodyView` ist der einzige Punkt im UI-Pfad, an dem sich die
//     Darstellung nach `track.lane.kind` entscheidet.
//
// Heute existiert genau ein Case (`.step`) und genau ein Body (`StepGridView`).
// Die Shell ist dennoch bereits eingeführt, damit:
//
//   - der Track-Rahmen die Annahme „Body == Step-Grid" nicht mehr implizit
//     trifft — die Zuordnung `case .step → StepGridView` ist benannt und
//     dokumentiert;
//   - künftige Lane-Typen einen natürlichen, lokal begrenzten Einstiegspunkt
//     auf der UI-Seite haben (weiterer Case in diesem Switch);
//   - der Compiler alle zukünftigen Kind-Erweiterungen hier mechanisch
//     markiert — kein stilles Durchrutschen über einen Default-Pfad.
//
// Invarianten dieser Shell:
//   - Exakt ein `switch track.lane.kind` — kein `default`.
//   - Pass-Through: die Parameterliste ist identisch mit `StepGridView`;
//     `LaneBodyView` reicht State, Bindings, Coordinator unverändert durch.
//   - Kein eigener State, keine Gesten, keine Environment-Objekt-Aufhebungen.
//     Environment-Werte (engine, playbackDisplay, interactionController,
//     stepWidthState, scrollState, undoManager) propagieren transitiv zum
//     konkreten Body-View.
//
// Slice-4-Grenzen (siehe ENGINEERING.md — „UI-Dispatch (ab Slice 4)"):
//   - Kein `LaneViewModel`, kein `LaneBodyProtocol`, kein `AnyView`.
//   - Kein Umbau von `StepGridView`, keine Interaction-Shell.
//   - Kein zweiter `LaneKind`-Case — Enum bleibt einelementig.
struct LaneBodyView: View {

    @ObservedObject var track: TrackViewModel
    @ObservedObject var grid:  StepGridCoordinator
    var accentColor:    Color
    var trackIndex:     Int
    @Binding var ccLaneDrawMode: Bool

    var body: some View {
        switch track.lane.kind {
        case .step:
            StepGridView(
                track:        track,
                grid:         grid,
                accentColor:  accentColor,
                trackIndex:   trackIndex
            )
        case .cc:
            CCLaneBodyView(
                track:       track,
                accentColor: accentColor,
                trackIndex:  trackIndex,
                drawMode:    $ccLaneDrawMode
            )
        }
    }
}
