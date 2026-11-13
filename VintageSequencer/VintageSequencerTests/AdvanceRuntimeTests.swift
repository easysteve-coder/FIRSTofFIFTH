import Testing
@testable import VintageSequencer

// MARK: - AdvanceRuntimeTests
//
// Testet die Step-Advance-Logik aller vier Playback-Richtungen.
// Grundlage: MockAdvanceRuntimeSource + TrackRuntime/TrackSnapshot-Helfer
// aus MockAdvanceRuntimeSource.swift.
//
// Scope bewusst begrenzt auf advanceRuntime():
//   — kein advanceSteps()-Test
//   — kein Pattern-Switch
//   — kein Note-Fire
//   — kein Timing/MIDI
//
// E4-next.3 — advanceRuntime-Tests (Schritt 3 von 3).

// MARK: - Forward

struct AdvanceRuntimeForwardTests {

    let mock = MockAdvanceRuntimeSource()
    let snap4 = TrackSnapshot.forTest(direction: .forward, stepCount: 4)

    // Startzustand -1 → erster ausgelöster Step ist 0.
    @Test func startsAtStep0() {
        var rt = TrackRuntime.fresh
        #expect(mock.advanceRuntime(&rt, snap: snap4) == 0)
        #expect(rt.currentStep == 0)
    }

    // Rückgabewert und runtime.currentStep sind nach jedem Aufruf identisch.
    @Test func returnValueMatchesCurrentStep() {
        var rt = TrackRuntime.fresh
        for _ in 0..<8 {
            let returned = mock.advanceRuntime(&rt, snap: snap4)
            #expect(returned == rt.currentStep)
        }
    }

    // Sequenz: 0 → 1 → 2 → 3 → 0 → 1 (n=4, 6 Ticks)
    @Test func advancesSequentially() {
        var rt = TrackRuntime.fresh
        let result = (0..<6).map { _ in mock.advanceRuntime(&rt, snap: snap4) }
        #expect(result == [0, 1, 2, 3, 0, 1])
    }

    // Letzter Step → Wrap auf Step 0.
    @Test func wrapsAtLastStep() {
        var rt = TrackRuntime.at(3)   // n-1 für n=4
        #expect(mock.advanceRuntime(&rt, snap: snap4) == 0)
    }

    // stepCount = 1: immer Step 0, kein Wrap-Problem.
    @Test func stepCountOne() {
        let snap1 = TrackSnapshot.forTest(direction: .forward, stepCount: 1)
        var rt = TrackRuntime.fresh
        for _ in 0..<5 {
            #expect(mock.advanceRuntime(&rt, snap: snap1) == 0)
        }
    }

    // stepCount = 2: 0 → 1 → 0 → 1 …
    @Test func stepCountTwo() {
        let snap2 = TrackSnapshot.forTest(direction: .forward, stepCount: 2)
        var rt = TrackRuntime.fresh
        let result = (0..<6).map { _ in mock.advanceRuntime(&rt, snap: snap2) }
        #expect(result == [0, 1, 0, 1, 0, 1])
    }

    // Ergebnis liegt immer im gültigen Bereich.
    @Test func resultAlwaysInRange() {
        var rt = TrackRuntime.fresh
        for _ in 0..<64 {
            let s = mock.advanceRuntime(&rt, snap: snap4)
            #expect(s >= 0 && s < 4)
        }
    }
}

// MARK: - Reverse

struct AdvanceRuntimeReverseTests {

    let mock = MockAdvanceRuntimeSource()
    let snap4 = TrackSnapshot.forTest(direction: .reverse, stepCount: 4)

    // Startzustand -1 → erster ausgelöster Step ist n-1 (B2-Fix).
    @Test func startsAtLastStep() {
        var rt = TrackRuntime.fresh
        #expect(mock.advanceRuntime(&rt, snap: snap4) == 3)
        #expect(rt.currentStep == 3)
    }

    // Sequenz: 3 → 2 → 1 → 0 → 3 → 2 (n=4, 6 Ticks ab Startzustand)
    @Test func advancesBackward() {
        var rt = TrackRuntime.fresh
        let result = (0..<6).map { _ in mock.advanceRuntime(&rt, snap: snap4) }
        #expect(result == [3, 2, 1, 0, 3, 2])
    }

    // Step 0 → Wrap auf n-1 (0 <= 0 Bedingung).
    @Test func wrapsAtStep0() {
        var rt = TrackRuntime.at(0)
        #expect(mock.advanceRuntime(&rt, snap: snap4) == 3)
    }

    // stepCount = 1: immer Step 0.
    @Test func stepCountOne() {
        let snap1 = TrackSnapshot.forTest(direction: .reverse, stepCount: 1)
        var rt = TrackRuntime.fresh
        for _ in 0..<5 {
            #expect(mock.advanceRuntime(&rt, snap: snap1) == 0)
        }
    }

    // stepCount = 2: Start -1 → 1, dann 1 → 0, dann 0 → 1 …
    @Test func stepCountTwo() {
        let snap2 = TrackSnapshot.forTest(direction: .reverse, stepCount: 2)
        var rt = TrackRuntime.fresh
        let result = (0..<5).map { _ in mock.advanceRuntime(&rt, snap: snap2) }
        #expect(result == [1, 0, 1, 0, 1])
    }

    // Ergebnis liegt immer im gültigen Bereich.
    @Test func resultAlwaysInRange() {
        var rt = TrackRuntime.fresh
        for _ in 0..<64 {
            let s = mock.advanceRuntime(&rt, snap: snap4)
            #expect(s >= 0 && s < 4)
        }
    }
}

// MARK: - PingPong

struct AdvanceRuntimePingPongTests {

    let mock = MockAdvanceRuntimeSource()
    let snap4 = TrackSnapshot.forTest(direction: .pingPong, stepCount: 4)

    // Startzustand -1 → erster ausgelöster Step ist 0.
    @Test func startsAtStep0() {
        var rt = TrackRuntime.fresh
        #expect(mock.advanceRuntime(&rt, snap: snap4) == 0)
        #expect(rt.currentStep == 0)
        #expect(rt.pingPongForward == true)
    }

    // Vollständige Sequenz für n=4:
    // 0,1,2,3 → flip → 2,1,0 → flip → 1,2,3 → flip → 2,1 …
    @Test func fullSequenceN4() {
        var rt = TrackRuntime.fresh
        let result = (0..<10).map { _ in mock.advanceRuntime(&rt, snap: snap4) }
        #expect(result == [0, 1, 2, 3, 2, 1, 0, 1, 2, 3])
    }

    // Richtungswechsel am oberen Ende: Step n-1 → pingPongForward wird false.
    @Test func flipsDirectionAtUpperBound() {
        var rt = TrackRuntime.at(2)   // einen vor dem Umkehrpunkt
        _ = mock.advanceRuntime(&rt, snap: snap4)   // → 3
        #expect(rt.currentStep == 3)
        #expect(rt.pingPongForward == true)
        _ = mock.advanceRuntime(&rt, snap: snap4)   // → 2, flip
        #expect(rt.currentStep == 2)
        #expect(rt.pingPongForward == false)
    }

    // Richtungswechsel am unteren Ende: Step 0 → pingPongForward wird true.
    @Test func flipsDirectionAtLowerBound() {
        var rt = TrackRuntime.at(1, pingPongForward: false)
        _ = mock.advanceRuntime(&rt, snap: snap4)   // → 0
        #expect(rt.currentStep == 0)
        #expect(rt.pingPongForward == false)
        _ = mock.advanceRuntime(&rt, snap: snap4)   // → 1, flip
        #expect(rt.currentStep == 1)
        #expect(rt.pingPongForward == true)
    }

    // stepCount = 1: immer Step 0, kein Flip möglich.
    @Test func stepCountOne() {
        let snap1 = TrackSnapshot.forTest(direction: .pingPong, stepCount: 1)
        var rt = TrackRuntime.fresh
        for _ in 0..<6 {
            #expect(mock.advanceRuntime(&rt, snap: snap1) == 0)
        }
    }

    // stepCount = 2: 0,1,0,1 — max(0,-1)=0 und min(1,1)=1 greifen korrekt.
    @Test func stepCountTwo() {
        let snap2 = TrackSnapshot.forTest(direction: .pingPong, stepCount: 2)
        var rt = TrackRuntime.fresh
        let result = (0..<6).map { _ in mock.advanceRuntime(&rt, snap: snap2) }
        #expect(result == [0, 1, 0, 1, 0, 1])
    }

    // stepCount = 3: 0,1,2,1,0,1,2,1,0 …
    @Test func stepCountThree() {
        let snap3 = TrackSnapshot.forTest(direction: .pingPong, stepCount: 3)
        var rt = TrackRuntime.fresh
        let result = (0..<9).map { _ in mock.advanceRuntime(&rt, snap: snap3) }
        #expect(result == [0, 1, 2, 1, 0, 1, 2, 1, 0])
    }

    // Ergebnis liegt immer im gültigen Bereich.
    @Test func resultAlwaysInRange() {
        var rt = TrackRuntime.fresh
        for _ in 0..<64 {
            let s = mock.advanceRuntime(&rt, snap: snap4)
            #expect(s >= 0 && s < 4)
        }
    }
}

// MARK: - Random

struct AdvanceRuntimeRandomTests {

    let mock = MockAdvanceRuntimeSource()

    // Ergebnis liegt immer im gültigen Bereich — deterministisch prüfbar
    // auch bei nicht-deterministischer Reihenfolge.
    @Test func resultAlwaysInRange() {
        let snap = TrackSnapshot.forTest(direction: .random, stepCount: 8)
        var rt = TrackRuntime.fresh
        for _ in 0..<200 {
            let s = mock.advanceRuntime(&rt, snap: snap)
            #expect(s >= 0 && s < 8)
        }
    }

    // stepCount = 1: auch Random muss immer Step 0 liefern.
    @Test func stepCountOneAlwaysStep0() {
        let snap1 = TrackSnapshot.forTest(direction: .random, stepCount: 1)
        var rt = TrackRuntime.fresh
        for _ in 0..<20 {
            #expect(mock.advanceRuntime(&rt, snap: snap1) == 0)
        }
    }

    // Rückgabewert und runtime.currentStep stimmen überein.
    @Test func returnValueMatchesCurrentStep() {
        let snap = TrackSnapshot.forTest(direction: .random, stepCount: 16)
        var rt = TrackRuntime.fresh
        for _ in 0..<50 {
            let returned = mock.advanceRuntime(&rt, snap: snap)
            #expect(returned == rt.currentStep)
        }
    }
}

// MARK: - B2 Startzustand (Querschnitt über alle Richtungen)

struct AdvanceRuntimeInitialStateTests {

    let mock = MockAdvanceRuntimeSource()

    // B2: alle vier Richtungen starten von currentStep = -1 korrekt.
    @Test func forwardStartsAt0() {
        var rt = TrackRuntime.fresh
        #expect(mock.advanceRuntime(&rt, snap: .forTest(direction: .forward,  stepCount: 8)) == 0)
    }

    @Test func reverseStartsAtNMinus1() {
        var rt = TrackRuntime.fresh
        #expect(mock.advanceRuntime(&rt, snap: .forTest(direction: .reverse,  stepCount: 8)) == 7)
    }

    @Test func pingPongStartsAt0() {
        var rt = TrackRuntime.fresh
        #expect(mock.advanceRuntime(&rt, snap: .forTest(direction: .pingPong, stepCount: 8)) == 0)
    }

    @Test func randomStartsInRange() {
        var rt = TrackRuntime.fresh
        let s = mock.advanceRuntime(&rt, snap: .forTest(direction: .random, stepCount: 8))
        #expect(s >= 0 && s < 8)
    }

    // Zweiter Tick nach dem Start: Runtime-State wurde korrekt fortgeschrieben.
    @Test func forwardSecondTickIsStep1() {
        var rt = TrackRuntime.fresh
        let snap = TrackSnapshot.forTest(direction: .forward, stepCount: 8)
        _ = mock.advanceRuntime(&rt, snap: snap)
        #expect(mock.advanceRuntime(&rt, snap: snap) == 1)
    }

    @Test func reverseSecondTickIsNMinus2() {
        var rt = TrackRuntime.fresh
        let snap = TrackSnapshot.forTest(direction: .reverse, stepCount: 8)
        _ = mock.advanceRuntime(&rt, snap: snap)          // → 7
        #expect(mock.advanceRuntime(&rt, snap: snap) == 6) // → 6
    }
}

// MARK: - Zustandslosigkeit des Mocks

struct AdvanceRuntimeMockStatelessTests {

    // Zwei unabhängige Runtimes, ein Mock: kein Cross-Contamination.
    @Test func twoIndependentRuntimes() {
        let mock = MockAdvanceRuntimeSource()
        let snap = TrackSnapshot.forTest(direction: .forward, stepCount: 4)

        var rtA = TrackRuntime.fresh
        var rtB = TrackRuntime.at(2)

        _ = mock.advanceRuntime(&rtA, snap: snap)   // A: -1 → 0
        _ = mock.advanceRuntime(&rtB, snap: snap)   // B:  2 → 3
        _ = mock.advanceRuntime(&rtA, snap: snap)   // A:  0 → 1

        #expect(rtA.currentStep == 1)
        #expect(rtB.currentStep == 3)
    }

    // Gleicher Mock, gleiche Inputs: Ergebnis identisch (außer .random).
    @Test func deterministicForForward() {
        let mock = MockAdvanceRuntimeSource()
        let snap = TrackSnapshot.forTest(direction: .forward, stepCount: 4)

        var rt1 = TrackRuntime.fresh
        var rt2 = TrackRuntime.fresh

        for _ in 0..<8 {
            let s1 = mock.advanceRuntime(&rt1, snap: snap)
            let s2 = mock.advanceRuntime(&rt2, snap: snap)
            #expect(s1 == s2)
        }
    }
}
