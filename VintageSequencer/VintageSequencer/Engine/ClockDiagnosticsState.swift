import Combine
import Foundation

/// Isolierter ObservableObject-Container für Clock-Jitter-Diagnosewerte.
///
/// Ausgelagert aus `SequencerEngine` (Arch-Slice-A / Pre-Lane-Umbau),
/// damit Jitter-Writes keine engine-weite SwiftUI-Re-Render-Kaskade auslösen.
///
/// Die Jitter-Felder werden ausschließlich von `SequencerEngine` (via Clock-Sampling-
/// Fenster, ~1×/s während Playback) geschrieben. Kein View-Code schreibt hier.
///
/// **Konsumenten:** `StatusBar` in `MainView` (Jitter-Anzeige).
/// **Debug-Subscriber:** `BodyRunCounter` (zählt Jitter-Update-Events).
///
/// Injektion: `engine.clockDiagnostics` wird in `VintageSequencerApp` als
/// eigenes `.environmentObject(engine.clockDiagnostics)` weitergegeben —
/// analog zu `playbackDisplay`, `transportState` und `scrollState`.
final class ClockDiagnosticsState: ObservableObject {

    // MARK: - Published diagnostics

    /// Durchschnittlicher Tick-Jitter im letzten Messfenster (µs).
    /// 0 = kein Messwert vorhanden (vor dem ersten Playback oder wenn nicht aktiv).
    @Published var avgUs:  Double = 0

    /// Minimaler Tick-Jitter im letzten Messfenster (µs).
    @Published var minUs:  Double = 0

    /// Maximaler Tick-Jitter im letzten Messfenster (µs).
    @Published var maxUs:  Double = 0

    /// Anzahl Ticks > 500 µs (Outlier) im letzten Messfenster.
    @Published var outs:   Int    = 0

    /// S01: Anzahl Ticks seit dem letzten Start, die ganz abgebrochen wurden, weil der
    /// Snapshot-Erwerb nach dem Maximum an Publish-Wechseln nicht gelang. Die StatusBar
    /// zeigt den Wert, sobald er > 0 ist. Engine spiegelt den Atomic des Readers hierher
    /// (erster Fehler sofort, danach höchstens 1×/s).
    @Published var snapshotAcquireFailures: Int = 0
}
