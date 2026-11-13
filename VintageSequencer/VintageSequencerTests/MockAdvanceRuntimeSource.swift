@testable import VintageSequencer

// MARK: - MockAdvanceRuntimeSource
//
// Leichtgewichtiger Test-Double für `AdvanceRuntimeSource`.
//
// Implementiert dieselbe Richtungslogik wie `SequencerEngine.advanceRuntime`,
// ohne AVAudioEngine, CoreMIDI oder eine SequencerEngine-Instanz zu benötigen.
// Alle Inputs und Outputs sind reine Value Types — vollständig deterministisch.
//
// E4-next.2 — Test-Infrastruktur (Schritt 2 von 3).
// Eigentliche Tests folgen in E4-next.3.

// MARK: - MockAdvanceRuntimeSource

/// Test-Double für `AdvanceRuntimeSource`.
///
/// Spiegelt die Implementierung von `SequencerEngine.advanceRuntime` exakt wider,
/// damit Tests das Verhalten in Isolation prüfen können — ohne den vollen
/// SequencerEngine-Lifecycle (AVAudio-Setup, MIDI-Ports, Pattern-Subscription).
///
/// Als `struct` instanziierbar — kein init-Overhead, keine versteckten
/// Abhängigkeiten. `pingPong`-Zustand liegt ausschließlich in `TrackRuntime`,
/// der Mock selbst ist zustandslos.
struct MockAdvanceRuntimeSource: AdvanceRuntimeSource {

    func advanceRuntime(_ runtime: inout TrackRuntime, snap: TrackSnapshot) -> Int {
        let n = snap.lane.stepCount   // geclampt ≥ 1, kein % 0 möglich
        switch snap.lane.direction {

        case .forward:
            runtime.currentStep = (runtime.currentStep + 1) % n

        case .reverse:
            // <= 0 fängt auch den Startzustand -1 ab: erster Step = n-1 (B2-Parität).
            runtime.currentStep = runtime.currentStep <= 0 ? n - 1
                                                           : runtime.currentStep - 1

        case .pingPong:
            if runtime.pingPongForward {
                if runtime.currentStep >= n - 1 {
                    runtime.pingPongForward = false
                    runtime.currentStep     = max(0, n - 2)
                } else {
                    runtime.currentStep += 1
                }
            } else {
                if runtime.currentStep <= 0 {
                    runtime.pingPongForward = true
                    runtime.currentStep     = min(1, n - 1)
                } else {
                    runtime.currentStep -= 1
                }
            }

        case .random:
            runtime.currentStep = Int.random(in: 0..<n)
        }
        return runtime.currentStep
    }
}

// MARK: - TrackSnapshot Test-Convenience

extension TrackSnapshot {

    /// Minimaler Snapshot für Tests: nur `direction` und `stepCount` relevant.
    /// Alle anderen Felder auf sichere Defaults gesetzt.
    static func forTest(direction: PlayDirection, stepCount: Int) -> TrackSnapshot {
        let count = max(1, stepCount)
        let steps = Array(repeating: StepSnapshot.testDefault, count: count)
        let lane = LaneSnapshot(
            kind:          .step,
            stepCount:     count,
            direction:     direction,
            pulsesPerStep: 6.0,
            payload:       .step(steps: steps)
        )
        return TrackSnapshot(
            lane:          lane,
            midiChannel:   1,
            isMuted:       false,
            isSolo:        false,
            timingOffset:  0.0
        )
    }
}

// MARK: - StepSnapshot Test-Convenience

extension StepSnapshot {

    /// Inaktiver Default-Step für Tests — `isActive: false` verhindert ungewolltes
    /// Note-Firing wenn der Snapshot versehentlich in advanceSteps landet.
    static var testDefault: StepSnapshot {
        StepSnapshot(
            isActive:    false,
            notes:       [60],
            velocity:    100,
            gate:        0.5,
            probability: 1.0,
            ratchet:     .x1
        )
    }
}

// MARK: - TrackRuntime Test-Convenience

extension TrackRuntime {

    /// Frischer Runtime-State wie nach `play()` — currentStep = -1.
    static var fresh: TrackRuntime { TrackRuntime() }

    /// Runtime mit voreingestelltem Step (für Tests, die mitten in einer Sequenz starten).
    static func at(_ step: Int, pingPongForward: Bool = true) -> TrackRuntime {
        TrackRuntime(currentStep: step,
                     pulseAccumulator: 0.0,
                     pingPongForward: pingPongForward)
    }
}
