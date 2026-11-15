import Foundation
import Atomics

// MARK: - GateControl (v1.15.0)
//
// Einstellungen eines Gates, von Main geschrieben, vom Audio-Thread je Block gelesen
// (Float-Bitmuster in Atomics, kein Lock). Ein Objekt je Einsatzort; es lebt so lange wie
// der Audio-Knoten bzw. Loop-Kern, der es benutzt.

final class GateControl {
    private let enabledFlag   = UnsafeAtomic<Bool>.create(false)
    private let thresholdBits = UnsafeAtomic<UInt32>.create(0)
    private let releaseBits   = UnsafeAtomic<UInt32>.create(0)
    private let holdBits      = UnsafeAtomic<UInt32>.create(0)

    init() { apply(GateSettings(), enabled: false) }

    deinit {
        enabledFlag.destroy(); thresholdBits.destroy(); releaseBits.destroy(); holdBits.destroy()
    }

    /// Main: Einstellungen übernehmen (`enabled` = dieses Gate ist am gewählten Ort aktiv).
    func apply(_ s: GateSettings, enabled: Bool) {
        var c = s; c.clamp()
        thresholdBits.store(powf(10, c.thresholdDB / 20).bitPattern, ordering: .relaxed)
        releaseBits.store(c.releaseMs.bitPattern, ordering: .relaxed)
        holdBits.store(c.holdMs.bitPattern, ordering: .relaxed)
        enabledFlag.store(enabled, ordering: .releasing)
    }

    struct Values { var enabled: Bool; var threshold: Float; var releaseMs: Float; var holdMs: Float }

    /// Audio-Thread: aktuelle Werte (RT-sicher).
    @inline(__always)
    func values() -> Values {
        Values(enabled: enabledFlag.load(ordering: .acquiring),
               threshold: Float(bitPattern: thresholdBits.load(ordering: .relaxed)),
               releaseMs: Float(bitPattern: releaseBits.load(ordering: .relaxed)),
               holdMs: Float(bitPattern: holdBits.load(ordering: .relaxed)))
    }
}

// MARK: - GateDSP

/// Rauschgate: Hüllkurve aus der lauteren Seite (Spitze, schneller Abfall), Öffnen ab der
/// Schwelle, Schließen 3 dB darunter nach der Haltezeit, Verstärkung gleitet (1 ms auf,
/// `releaseMs` zu) — kein Knacken. Reiner Wertetyp, Zustand je Einsatzort.
struct GateDSP {
    private(set) var gain: Float = 0
    private var env: Float = 0
    private var holdLeft = 0
    private var open = false

    mutating func reset() { gain = 0; env = 0; holdLeft = 0; open = false }

    /// Bearbeitet `frames` Samples in place (rechts darf gleich links sein: Mono). RT-sicher.
    mutating func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>,
                          frames: Int, sampleRate: Double, _ v: GateControl.Values) {
        guard v.enabled, sampleRate > 0 else { return }
        let sr = Float(sampleRate)
        let envFall   = expf(-1 / (0.010 * sr))                 // Hüllkurve fällt in ~10 ms
        let attack    = 1 - expf(-1 / (0.001 * sr))             // Öffnen in ~1 ms
        let release   = 1 - expf(-1 / (max(v.releaseMs, 1) * 0.001 * sr))
        let holdFrames = Int(v.holdMs * 0.001 * sr)
        let closeAt   = v.threshold * 0.708                     // −3 dB Hysterese
        let mono = l == r
        for i in 0..<frames {
            let x = mono ? abs(l[i]) : max(abs(l[i]), abs(r[i]))
            env = x > env ? x : env * envFall
            if env >= v.threshold {
                open = true; holdLeft = holdFrames
            } else if open, env < closeAt {
                if holdLeft > 0 { holdLeft -= 1 } else { open = false }
            }
            let target: Float = open ? 1 : 0
            gain += (target - gain) * (target > gain ? attack : release)
            l[i] *= gain
            if !mono { r[i] *= gain }
        }
    }
}
