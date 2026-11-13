import Combine
import SwiftUI

/// Separater Observable-Container für den horizontalen Scroll-Offset aller Lanes.
///
/// Ausgelagert aus `SequencerEngine` damit Scroll-Änderungen keine Engine-weite
/// SwiftUI-Re-Render-Kaskade auslösen: `@Published var hScrollOffset` auf dem
/// globalen `SequencerEngine`-Objekt feuerte bei jedem Scroll-Event `objectWillChange`
/// auf dem Engine, was alle beobachtenden Views (TrackHeader, StepButtons,
/// TransportView, …) neu evaluierte — obwohl nur der `.offset()`-Layer
/// in `StepGridView` und der `BPMGridView`-Canvas tatsächlich reagieren müssen.
///
/// Injektion: `engine.scrollState` wird in `VintageSequencerApp` als eigenes
/// `.environmentObject(engine.scrollState)` weitergegeben.
final class ScrollState: ObservableObject {
    @Published var hScrollOffset: CGFloat = 0

    /// True while any CornerHandlesView handle is being dragged.
    /// Used to suppress scrollbar-bridge writes and onChange rubber-band
    /// updates on ALL track lanes during handle drag, not just the dragged one.
    var isAnyHandleDragging: Bool = false
}
