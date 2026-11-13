import CoreMIDI

// MARK: - AdvanceRuntimeSource

/// Minimales Protocol für die Step-Advance-Logik des Sequenzers.
///
/// Abstrahiert `advanceRuntime(_:snap:)` so, dass Unit-Tests eine
/// deterministische Mock-Implementierung bereitstellen können —
/// ohne ClockSource oder Echtzeit-Kontext.
///
/// Die einzige produktive Konformität ist `SequencerEngine`.
/// Die Mock-Implementierung (`MockAdvanceRuntimeSource`) folgt in E4-next.2.
///
/// Design-Entscheidungen:
///   - Keine `AnyObject`-Einschränkung: Der Mock kann ein struct sein.
///   - Kein throwing: Die Funktion ist fehlerlos und deterministisch (außer .random).
///   - Kein async: Der RT-Pfad ist synchron, Tests sind ebenfalls synchron.
///
/// E4-next — Protocol-Abstraktion (Schritt 1 von 3).
protocol AdvanceRuntimeSource {

    /// Rückt einen TrackRuntime-Step entsprechend der Playback-Richtung weiter.
    ///
    /// Die Funktion mutiert `runtime.currentStep` in-place und gibt denselben
    /// Wert als Rückgabe zurück (Convenience für `advanceSteps`).
    ///
    /// - Parameters:
    ///   - runtime: Mutabler Laufzeitzustand des Tracks
    ///              (currentStep, pulseAccumulator, pingPongForward)
    ///   - snap:    Unveränderlicher Track-Snapshot (direction, stepCount)
    /// - Returns:   Neuer Step-Index, garantiert im Bereich 0 …< snap.stepCount
    func advanceRuntime(_ runtime: inout TrackRuntime, snap: TrackSnapshot) -> Int
}
