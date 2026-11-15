import Foundation
import Combine

// MARK: - TransportState

/// Transport-Zustand des Sequencers: BPM, Play/Stop, ClockMode, Pattern-Index.
///
/// Arch-Slice-19: Ausgelagert aus SequencerEngine, damit BPM-/Transport-Änderungen
/// kein engine.objectWillChange auslösen. Views, die keinen Transport-Bezug haben
/// (StepGrid, StepButton, TrackRow), erhalten keine Subscription auf dieses Objekt
/// → kein Rebuild bei BPM-Drehung (war: bis zu ~6.700 StepButton body/s).
///
/// **Schreibregel:** Ausschließlich SequencerEngine schreibt auf TransportState.
/// Views rufen Engine-Methoden auf:
///   `engine.play()`, `engine.stop()`, `engine.setBPM(_:)`, `engine.setClockMode(_:)`
final class TransportState: ObservableObject {
    @Published var bpm:                 Double    = 120.0
    /// Taktart des aktuellen Patterns (v1.18.24; bis v1.18.23 des Projekts). Schreibweg
    /// `SequencerEngine.setTimeSignatureUndoable`; Raster, Pad-Längen und Anzeige folgen ihr.
    @Published var timeSignature:       TimeSignature = .common
    /// Während der Wiedergabe für das laufende Pattern vorgemerkte Taktart (Entscheidung E2):
    /// gilt, sobald dieses Pattern nicht mehr läuft (Wechsel, Stop). nil = keine.
    @Published var pendingTimeSignature: TimeSignature? = nil
    /// Patternwechsel ohne Song auf dem nächsten Taktstrich statt am Ende von Spur 1 (E3).
    /// Neue Projekte: an; Dateien ohne Schlüssel `patternSwitch`: aus.
    @Published var switchOnBar:         Bool      = true
    @Published var isPlaying:           Bool      = false
    @Published var clockMode:           ClockMode = .internal
    @Published var currentPatternIndex: Int       = 0
    @Published var queuedPatternIndex:  Int?      = nil
}
