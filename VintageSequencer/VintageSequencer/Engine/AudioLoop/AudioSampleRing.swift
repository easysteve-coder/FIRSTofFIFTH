// AudioSampleRing.swift
// FIRSTofFIFTH — Mithör-Ring zwischen Eingangs- und Ausgangs-Engine (v1.15.1, ersetzt die
// lOOper-Übernahme aus v1.15.0).
//
// Lock-freier SPSC-Ring für verschachtelte Float-Samples.
//   Producer: Senke der Eingangs-Engine (eigener Audio-Thread).
//   Consumer: Quelle im Kanalzug der Ausgabe-Engine (anderer Audio-Thread).
//
// Vertrag (Codex-Befund H1):
//   - `writeIndex` schreibt nur der Producer, `readIndex` nur der Consumer; beide sind
//     Atomics. Der Producer veröffentlicht Samples mit Release auf `writeIndex`, der
//     Consumer erwirbt sie mit Acquire; ebenso gibt der Consumer gelesene Plätze mit Release
//     auf `readIndex` zurück, der Producer erwirbt den freien Platz mit Acquire.
//   - Der Producer überschreibt nie Plätze, die der Consumer noch nicht freigegeben hat.
//     Bei vollem Ring verwirft er den Rest des neuen Blocks (Zähler `dropped`).
//   - Die Tiefenbegrenzung (Mithörlatenz) wendet allein der Consumer an, indem er seinen
//     eigenen Leseindex vorzieht.
//   - Samples liegen als atomare 32-Bit-Werte (relaxed): auch der Fall „Consumer liest
//     einen Platz, den der Producer nach Freigabe schon neu beschreibt" ist so kein
//     Datenrennen im Sinne des Speichermodells — durch die Indizes tritt er ohnehin nicht ein.
//
// Speicher vollständig vorab angelegt; keine Locks, kein ARC im Hot-Path.

import Foundation
import Atomics

final class AudioSampleRing {

    private let buffer: UnsafeMutablePointer<UInt32.AtomicRepresentation>
    private let capacitySamples: Int
    private let channelCount: Int
    private let mask: Int
    private let maxDepthSamples: Int

    private let writeIndex = UnsafeAtomic<Int>.create(0)
    private let readIndex  = UnsafeAtomic<Int>.create(0)
    private let droppedA   = UnsafeAtomic<Int>.create(0)

    /// Verworfene Samples (voller Ring), seit dem Anlegen. Diagnose.
    var dropped: Int { droppedA.load(ordering: .relaxed) }

    init(capacityFrames: Int, channelCount: Int, maxDepthFrames: Int = 0) {
        let desired = capacityFrames * channelCount
        var pow2 = 1
        while pow2 < desired { pow2 <<= 1 }
        capacitySamples = pow2
        mask = pow2 - 1
        self.channelCount = channelCount
        maxDepthSamples = maxDepthFrames > 0 ? maxDepthFrames * channelCount : 0
        // Genullt reserviert, real belegt erst mit `prefault` (v1.17.7, Speicher bei 64 Kanälen).
        buffer = ZeroedMemory.allocate(pow2)
    }

    /// Main, vor der ersten Nutzung: Seiten real belegen.
    func prefault() { ZeroedMemory.prefault(buffer, count: capacitySamples) }

    deinit {
        ZeroedMemory.free(buffer, count: capacitySamples)
        writeIndex.destroy(); readIndex.destroy(); droppedA.destroy()
    }

    @inline(__always)
    private func slot(_ i: Int) -> UnsafeAtomic<UInt32> { UnsafeAtomic(at: buffer + (i & mask)) }

    // MARK: - Producer

    /// Schreibt bis zu `frameCount` Frames; bei vollem Ring wird der Rest verworfen.
    /// Rückgabe: geschriebene Frames.
    @discardableResult
    func write(_ src: UnsafePointer<Float>, frameCount: Int) -> Int {
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        let free = capacitySamples - (w &- r)
        let wanted = frameCount * channelCount
        let samples = min(wanted, free - free % channelCount)
        if samples < wanted { droppedA.wrappingIncrement(by: wanted - samples, ordering: .relaxed) }
        guard samples > 0 else { return 0 }
        for i in 0..<samples { slot(w &+ i).store(src[i].bitPattern, ordering: .relaxed) }
        writeIndex.store(w &+ samples, ordering: .releasing)
        return samples / channelCount
    }

    // MARK: - Consumer

    /// Liest bis zu `frameCount` Frames nach `dst`; fehlender Rest wird Stille.
    /// Rückgabe: tatsächlich gelesene Frames.
    @discardableResult
    func read(into dst: UnsafeMutablePointer<Float>, frameCount: Int) -> Int {
        let needed = frameCount * channelCount
        let w = writeIndex.load(ordering: .acquiring)
        var r = readIndex.load(ordering: .relaxed)
        var available = w &- r
        if maxDepthSamples > 0, available > maxDepthSamples {
            r = w &- maxDepthSamples              // nur den eigenen Index vorziehen
            available = maxDepthSamples
        }
        let toRead = min(available, needed)
        for i in 0..<toRead { dst[i] = Float(bitPattern: slot(r &+ i).load(ordering: .relaxed)) }
        if toRead < needed { for i in toRead..<needed { dst[i] = 0 } }
        readIndex.store(r &+ toRead, ordering: .releasing)
        return toRead / channelCount
    }

    /// Verwirft alles Verfügbare. Nur vom Consumer aufzurufen.
    func reset() {
        readIndex.store(writeIndex.load(ordering: .acquiring), ordering: .releasing)
    }

    /// Belegte Samples (Diagnose/Tests; von beiden Seiten aus nur eine Momentaufnahme).
    var fill: Int { writeIndex.load(ordering: .acquiring) &- readIndex.load(ordering: .acquiring) }
}
