import Foundation
import Combine

// MARK: - TrackViewModel
//
// View-layer wrapper for TrackData + its LaneData.
//
// Ownership:
//   - One TrackViewModel exists per TrackData in the live session.
//   - Created lazily by SequencerEngine.viewModel(for:) and cached in vmCache.
//
// Change propagation (Lane-Modell v1):
//   - TrackData container mutations          → trackData.changed.send()
//   - LaneData sequence mutations            → laneData.changed.send()
//   - This VM subscribes to BOTH subjects and forwards each into its own
//     objectWillChange so observing views see a single coherent invalidation
//     regardless of whether a container- or a lane-field changed.
//
// Sequence-field access is lane-explicit: views read `track.lane.steps`,
// `track.lane.stepCount`, `track.lane.direction`, etc.  TrackViewModel does
// not forward lane fields — the only lane accessor it exposes is `lane`.
final class TrackViewModel: ObservableObject, Identifiable {

    // MARK: - Data

    let data: TrackData
    var lane: LaneData { data.lane }

    // MARK: - Runtime-only state

    /// Notes fired on the last step tick. Written exclusively by SequencerEngine on the
    /// Main Thread and read only there (Note-Offs bei Stop/Remove/Patternwechsel).
    /// Bewusst NICHT @Published: keine View liest das Feld; als @Published invalidierte
    /// jede gespielte Note zweimal die gesamte Track-Zeile samt aller Step-Buttons.
    var lastFiredNotes: [Int] = []

    // MARK: - Subscriptions

    private var dataSub: AnyCancellable?
    private var laneSub: AnyCancellable?

    // MARK: - Init

    init(data: TrackData) {
        self.data = data
        // Forward container-field mutations.
        dataSub = data.changed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.objectWillChange.send() }
        // Forward lane-field mutations.
        laneSub = data.lane.changed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.objectWillChange.send() }
    }

    // MARK: - Identifiable

    var id: UUID { data.id }

    // MARK: - Forwarding: container fields (read-only)

    var name:         String        { data.name }
    var midiChannel:  Int           { data.midiChannel }
    var isDrum:       Bool          { data.isDrum }
    var instrumentID: UUID?         { data.instrumentID }
    var isMuted:      Bool          { data.isMuted }
    var isSolo:       Bool          { data.isSolo }
    var timingOffset: Double        { data.timingOffset }
    var scaleRoot:    Int           { data.scaleRoot }
    var scaleIndex:   Int           { data.scaleIndex }

    // MARK: - Delegating instance helpers

    func noteInScale(_ note: Int) -> Bool { data.noteInScale(note) }
    func quantizedNote(_ note: Int) -> Int { data.quantizedNote(note) }

    // MARK: - Static forwards

    static var scales:       [ScaleDefinition]      { TrackData.scales }
    static var noteNames:    [String]               { TrackData.noteNames }
    static var quantTable:   [[[Int]]]              { TrackData.quantTable }
    static var sortedRatios: [(num: Int, den: Int)] { TrackData.sortedRatios }
}
