import Testing
import CoreGraphics
@testable import VintageSequencer

/// Treffer-Zuordnung Punkt → Step (Rechtsklick öffnet die Edit-Card, v1.13.4).
struct StepHitTests {

    private static func hit(_ x: CGFloat, y: CGFloat = 45, count: Int = 16, num: Int = 1, den: Int = 1,
                            width: Double = 54) -> Int? {
        LaneGeometry.stepIndex(contentX: x, y: y, rowHeight: 90, cellHeight: 54,
                               stepCount: count, num: num, den: den, stepWidthSize: width)
    }

    /// Jeder Punkt jeder Zelle trifft genau diese Zelle — für gerade und krumme Verhältnisse.
    /// Referenz ist das Layout selbst: Zellbreiten aus `distributedStepWidth` + Abstand.
    @Test func everyPointOfEveryCellMapsToThatCell() {
        for (num, den) in [(1, 1), (3, 4), (4, 7), (9, 8), (2, 1), (1, 2)] {
            for width in [20.0, 54.0, 71.5] {
                var x = VintageTheme.stepGridLeadingPad
                for i in 0..<16 {
                    let w = VintageTheme.distributedStepWidth(index: i, num: num, den: den, stepWidthSize: width)
                    if w >= 1 {
                        #expect(Self.hit(x, num: num, den: den, width: width) == i)
                        #expect(Self.hit(x + w / 2, num: num, den: den, width: width) == i)
                        #expect(Self.hit(x + w - 0.01, num: num, den: den, width: width) == i)
                    }
                    // Die Lücke hinter der Zelle gehört keinem Step.
                    #expect(Self.hit(x + w + VintageTheme.stepSpacing / 2, num: num, den: den, width: width) == nil)
                    x += w + VintageTheme.stepSpacing
                }
            }
        }
    }

    /// Ränder: vor dem ersten Step, hinter dem letzten, ober- und unterhalb der Tasten.
    @Test func outsideTheCellsNothingIsHit() {
        #expect(Self.hit(VintageTheme.stepGridLeadingPad - 1) == nil)
        #expect(Self.hit(-50) == nil)
        #expect(Self.hit(VintageTheme.stepGridLeadingPad + 58 * 16 + 5) == nil, "hinter dem letzten Step")
        #expect(Self.hit(30, y: 17) == nil, "oberhalb der Taste")
        #expect(Self.hit(30, y: 18) == 0)
        #expect(Self.hit(30, y: 71.9) == 0)
        #expect(Self.hit(30, y: 72) == nil, "unterhalb der Taste")
        #expect(Self.hit(30, count: 0) == nil)
    }
}
