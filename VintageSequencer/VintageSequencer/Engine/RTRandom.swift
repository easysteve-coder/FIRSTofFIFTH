import Foundation

/// RT-4b: Alloc-freier, RT-sicherer Pseudozufallsgenerator für den Tick-Pfad.
/// xorshift64* — kein Lock, kein Syscall, kein Heap-Zugriff, deterministisch
/// reproduzierbar bei fixem Seed (test-freundlich). Kein kryptografischer
/// Anspruch — nur für musikalische Zufälligkeit (Random-Direction,
/// Step-Probability-Gate), nicht sicherheitsrelevant. Ersetzt
/// Int/Double.random(in:) im Tick-Pfad, deren SystemRandomNumberGenerator
/// auf Darwin über arc4random_buf läuft — ohne dokumentierte Alloc-/
/// Lock-Freiheits-Garantie.
struct RTRandom {
    private var state: UInt64

    init(seed: UInt64) {
        // xorshift64* verlangt einen von 0 verschiedenen State.
        self.state = seed != 0 ? seed : 0x9E3779B97F4A7C15
    }

    @inline(__always)
    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545F4914F6CDD1D
    }

    /// Gleichverteilt in [0, 1) — Standard-Muster: obere 53 Bit / 2^53.
    @inline(__always)
    mutating func nextUnitDouble() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }

    /// Gleichverteilt in [0, bound). bound > 0 wird vom Aufrufer garantiert
    /// (stepCount ist bereits ≥ 1 geclampt). Modulo-Bias ist bei den hier
    /// vorkommenden kleinen bounds (Step-Counts, typ. ≤ 64) vernachlässigbar
    /// — kein kryptografischer Anspruch, nur musikalische Zufälligkeit.
    @inline(__always)
    mutating func nextInt(bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }
}
