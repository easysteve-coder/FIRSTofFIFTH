import Testing
@testable import VintageSequencer

// MARK: - RTRandomTests
//
// RT-4b: Struct-Tests für den alloc-freien xorshift64*-PRNG, der
// Int/Double.random(in:) im Tick-Pfad ersetzt (SequencerEngine.advanceRuntime/
// advanceSteps). Reine Wert-Tests — kein SequencerEngine nötig, siehe
// RT4bSeededRandomTests (WorkflowEngineTests.swift) für die Engine-Integration.

struct RTRandomTests {

    @Test func nextIntStaysInBound() {
        for bound in [1, 2, 7, 64] {
            var rng = RTRandom(seed: 12345)
            for _ in 0..<1000 {
                let v = rng.nextInt(bound: bound)
                #expect(v >= 0 && v < bound)
            }
        }
    }

    @Test func nextIntBoundOneAlwaysZero() {
        var rng = RTRandom(seed: 999)
        for _ in 0..<50 {
            #expect(rng.nextInt(bound: 1) == 0)
        }
    }

    @Test func nextUnitDoubleStaysInUnitRange() {
        var rng = RTRandom(seed: 42)
        for _ in 0..<1000 {
            let v = rng.nextUnitDouble()
            #expect(v >= 0.0 && v < 1.0)
        }
    }

    @Test func sameSeedProducesSameSequence() {
        var rngA = RTRandom(seed: 777)
        var rngB = RTRandom(seed: 777)
        for _ in 0..<50 {
            #expect(rngA.next() == rngB.next())
        }
    }

    @Test func differentSeedsProduceDifferentSequences() {
        var rngA = RTRandom(seed: 1)
        var rngB = RTRandom(seed: 2)
        let seqA = (0..<10).map { _ in rngA.next() }
        let seqB = (0..<10).map { _ in rngB.next() }
        #expect(seqA != seqB)
    }

    // Seed 0 ist für xorshift ein Fixpunkt (state ^= state >> n bleibt 0) —
    // der Konstruktor muss ihn auf einen Nicht-Null-Startwert abbilden.
    @Test func zeroSeedDoesNotStall() {
        var rng = RTRandom(seed: 0)
        let values = Set((0..<20).map { _ in rng.next() })
        #expect(values.count > 1, "Seed 0 darf nicht in einer konstanten Folge hängen bleiben")
    }
}
