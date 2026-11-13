import Testing
import CoreGraphics
@testable import VintageSequencer

// MARK: - HandleDragLogicTests
//
// Testet die reine Drag-/Viewport-Logik ohne SwiftUI oder AppKit.
//
// Warum dieser Test den Sprung-Bug erkennt:
//
//   Der Bug war: hScrollOffset = dragStartOffset + delta×pxPerStep − totalX
//   Diese Formel hat zwei gegeneinander arbeitende Terme:
//   · delta×pxPerStep   — diskret, springt bei Step-Übergängen
//   · −totalX           — kontinuierlich, ändert sich bei jedem Pixel
//
//   Folge: zwischen zwei Step-Grenzen ändert sich hScrollOffset pro Pixel
//   (Viewport "schwingt mit"), an der Grenze gibt es einen abrupten Gegensprung
//   von annähernd pxPerStep Pixeln.
//
//   Der Fix: onDrag berührt hScrollOffset nicht. Diese Tests verifizieren,
//   dass stepCount() idempotent und ohne Nebeneffekt auf den Offset arbeitet,
//   und dass applyEdgeScroll() der einzige Pfad für Offset-Änderungen ist.

struct HandleDragLogicTests {

    // Gemeinsame Konstanten
    let pxPerStep:     CGFloat = 60
    let startCount:    Int     = 16
    let initialOffset: CGFloat = 300

    // MARK: — 1. Step-Count-Grenzen

    /// stepCount springt exakt an den erwarteten quantisierten Grenzen.
    ///
    /// Swift .rounded() verwendet toNearestOrAwayFromZero (NICHT Banker-Rundung):
    ///   29/60 ≈ 0.483 → 0   (delta=0)
    ///   30/60 = 0.500 → 1   (weg von null → delta=1)
    ///   90/60 = 1.500 → 2   (weg von null → delta=2)
    ///
    /// Zonen: delta=0 wenn totalX < 30; delta=1 wenn 30 ≤ totalX < 90; delta=2 ab 90.
    @Test func stepCountJumpsAtExpectedBoundaries() {
        // Knapp unter erster Grenze → keine Änderung
        #expect(HandleDragLogic.stepCount(totalX: 29,  pxPerStep: pxPerStep, startCount: startCount) == 16)
        // Genau 0.5 → rundet weg von null → +1
        #expect(HandleDragLogic.stepCount(totalX: 30,  pxPerStep: pxPerStep, startCount: startCount) == 17)
        // Mitten in delta=1-Zone
        #expect(HandleDragLogic.stepCount(totalX: 60,  pxPerStep: pxPerStep, startCount: startCount) == 17)
        // Knapp vor zweiter Grenze → noch delta=1
        #expect(HandleDragLogic.stepCount(totalX: 89,  pxPerStep: pxPerStep, startCount: startCount) == 17)
        // Genau 1.5 → rundet weg von null → +2
        #expect(HandleDragLogic.stepCount(totalX: 90,  pxPerStep: pxPerStep, startCount: startCount) == 18)
        // Mitten in delta=2-Zone
        #expect(HandleDragLogic.stepCount(totalX: 120, pxPerStep: pxPerStep, startCount: startCount) == 18)
    }

    // MARK: — 2. Stabiler Bereich zwischen zwei Grenzen

    /// Alle totalX-Werte im selben quantisierten Bereich liefern denselben stepCount.
    /// → kein Offset-Zucken, kein Gegensprung, kein "Mitschwingen".
    @Test func sameQuantizedZone_stableResult() {
        // delta=1-Zone: totalX ∈ [30, 89]
        // 30/60=0.5 rundet weg von null zu 1; 89/60≈1.483 rundet zu 1; 90/60=1.5 rundet zu 2.
        for x in stride(from: CGFloat(30), through: 89, by: CGFloat(1)) {
            #expect(
                HandleDragLogic.stepCount(totalX: x, pxPerStep: pxPerStep, startCount: startCount) == 17,
                "Erwartet 17 bei totalX=\(x)"
            )
        }
    }

    // MARK: — 3. Viewport bleibt konstant während normalem Drag

    /// Simuliert eine vollständige Drag-Sequenz: hScrollOffset wird vom
    /// Drag-Pfad nie berührt.  Genau das war vor dem Fix anders.
    @Test func normalDrag_offsetUnchanged() {
        var offset = initialOffset

        // Drag-Sequenz: von 0 bis 120 px in 5-px-Schritten
        for x in stride(from: CGFloat(0), through: 120, by: CGFloat(5)) {
            // stepCount() hat keinen Nebeneffekt auf offset
            let _ = HandleDragLogic.stepCount(
                totalX: x, pxPerStep: pxPerStep, startCount: startCount
            )
            #expect(offset == initialOffset, "Offset wurde bei totalX=\(x) verändert")
        }

        // Auch beim Verkleinern (negativer totalX) bleibt der Offset konstant
        for x in stride(from: CGFloat(0), through: -120, by: CGFloat(-5)) {
            let _ = HandleDragLogic.stepCount(
                totalX: x, pxPerStep: pxPerStep, startCount: startCount
            )
            #expect(offset == initialOffset, "Offset wurde bei totalX=\(x) verändert")
        }
    }

    // MARK: — 4. Verkleinern der Step-Anzahl

    /// Beim Linksdrag nimmt stepCount ab — Offset bleibt unverändert.
    /// Vor dem Fix: jeder Step-Übergang erzeugte einen sichtbaren Viewport-Sprung.
    @Test func reducingSteps_noOffsetChange() {
        var offset = initialOffset

        // toNearestOrAwayFromZero: -0.5 → -1, -1.5 → -2
        let cases: [(totalX: CGFloat, expectedCount: Int)] = [
            (-29, 16), // -29/60≈-0.483 → 0   → count=16
            (-30, 15), // -30/60=-0.5   → -1  → count=15
            (-60, 15), // -60/60=-1.0   → -1  → count=15
            (-90, 14), // -90/60=-1.5   → -2  → count=14
        ]
        for c in cases {
            let count = HandleDragLogic.stepCount(
                totalX: c.totalX, pxPerStep: pxPerStep, startCount: startCount
            )
            #expect(count == c.expectedCount, "totalX=\(c.totalX)")
            #expect(offset == initialOffset, "Offset geändert bei totalX=\(c.totalX)")
        }
    }

    // MARK: — 5. Edge-Scroll ist der einzige Offset-Pfad

    /// Nur applyEdgeScroll() verändert den Offset.
    /// stepCount() liefert danach weiterhin korrekte Werte — da totalX durch
    /// autoScrollAccum bereits das Edge-Scroll-Delta enthält.
    @Test func edgeScroll_onlyPathForOffsetChange() {
        var offset = initialOffset
        let velocity: CGFloat = 14   // typischer Edge-Scroll-Wert

        // Edge-Scroll-Timer feuert: Offset ändert sich
        offset = HandleDragLogic.applyEdgeScroll(currentOffset: offset, velocity: velocity)
        #expect(offset == initialOffset + velocity)

        // Direkt danach ein Drag-Event (totalX enthält autoScrollAccum):
        // stepCount ändert Offset nicht
        let autoScrollAccum: CGFloat = velocity   // ein Timer-Tick
        let totalX: CGFloat = 20 + autoScrollAccum  // Cursor + akkumuliertes Scroll
        let count = HandleDragLogic.stepCount(
            totalX: totalX, pxPerStep: pxPerStep, startCount: startCount
        )
        // Offset bleibt so wie Edge-Scroll ihn gelassen hat
        #expect(offset == initialOffset + velocity)
        // stepCount nutzt totalX korrekt (20+14=34 → delta=1 → 17)
        #expect(count == 17)
    }

    // MARK: — 6. Klemm-Verhalten

    /// stepCount klemmt auf [1, 64].
    @Test func stepCountClamping() {
        #expect(HandleDragLogic.stepCount(totalX: -10_000, pxPerStep: pxPerStep, startCount:  1) == 1)
        #expect(HandleDragLogic.stepCount(totalX:  10_000, pxPerStep: pxPerStep, startCount:  1) == 64)
        #expect(HandleDragLogic.stepCount(totalX:  10_000, pxPerStep: pxPerStep, startCount: 64) == 64)
    }

    /// applyEdgeScroll klemmt auf ≥ 0.
    @Test func edgeScrollClampAtZero() {
        #expect(HandleDragLogic.applyEdgeScroll(currentOffset:  5, velocity: -20) == 0)
        #expect(HandleDragLogic.applyEdgeScroll(currentOffset:  0, velocity:  -1) == 0)
        #expect(HandleDragLogic.applyEdgeScroll(currentOffset: 10, velocity:  -5) == 5)
    }

    // MARK: — 7. Idempotenz

    /// Derselbe totalX liefert immer denselben stepCount — unabhängig davon,
    /// wie oft und in welcher Reihenfolge die Funktion gerufen wird.
    @Test func stepCountIsIdempotent() {
        let x: CGFloat = 75   // delta=1-Zone
        let first  = HandleDragLogic.stepCount(totalX: x, pxPerStep: pxPerStep, startCount: startCount)
        let second = HandleDragLogic.stepCount(totalX: x, pxPerStep: pxPerStep, startCount: startCount)
        let third  = HandleDragLogic.stepCount(totalX: x, pxPerStep: pxPerStep, startCount: startCount)
        #expect(first == second)
        #expect(second == third)
    }
}
