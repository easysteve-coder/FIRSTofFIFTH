import SwiftUI

// MARK: - TrackSideHeaderView
//
// Dispatch-Shell für die linke Spurkopf-Spalte (CC-Lane Slice 1 — vierter
// Exhaustiveness-Anker neben `buildPatternSnapshot`, `advanceSteps`,
// `LaneBodyView`).
//
// Für `.step`-Lanes wird die bestehende Kombination aus `TrackHeaderView`
// und darunter gestapeltem `TrackCCSectionView` gerendert. Für `.cc`-Lanes
// übernimmt `CCLaneHeaderView` die volle Spurkopfhöhe — CC-Lanes kennen
// weder CC-Panel noch Expand-Chevron.
//
// Invariante: genau ein `switch track.lane.kind` — kein `default`. Jeder
// zukünftige `LaneKind`-Case wird vom Compiler hier mechanisch erzwungen.
struct TrackSideHeaderView: View {

    @ObservedObject var track: TrackViewModel
    var accentColor:     Color
    var stepRowHeight:   CGFloat
    @Binding var ccLaneDrawMode: Bool
    var onRandomize:  (() -> Void)?
    var onClear:      (() -> Void)?
    var onDelete:     (() -> Void)?
    var onDuplicate:  (() -> Void)?
    var headerContextMenu: () -> AnyView

    var body: some View {
        switch track.lane.kind {
        case .step:
            // Step-Lane-Purify P1 (v1.10.0): TrackCCSectionView entfernt.
            // Step-Lanes zeigen im Spurkopf nur noch den reinen
            // TrackHeaderView — keine CC1/CC2-Label-Reihen mehr.
            TrackHeaderView(track: track,
                            accentColor: accentColor,
                            onRandomize: onRandomize,
                            onClear:     onClear,
                            onDelete:    onDelete,
                            onDuplicate: onDuplicate)
                .frame(height: stepRowHeight)
                .contextMenu { headerContextMenu() }

        case .cc:
            CCLaneHeaderView(
                track:       track,
                accentColor: accentColor,
                drawMode:    $ccLaneDrawMode,
                onDelete:    onDelete,
                onDuplicate: onDuplicate
            )
            .contextMenu { headerContextMenu() }
        }
    }
}
