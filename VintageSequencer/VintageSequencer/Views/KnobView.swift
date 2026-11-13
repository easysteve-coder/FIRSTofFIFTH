import SwiftUI

// MARK: - KnobView

// MARK: - Knob-Editing-Hook
//
// Meldet Beginn (true) und Ende (false) eines Knob-Drags an den umgebenden Editor.
// Damit kann der Editor einen ganzen Drag als EINEN Undo-Schritt registrieren statt
// eines Eintrags pro Mausbewegung. Default nil: Knobs ohne Hook verhalten sich wie bisher.
private struct KnobEditingChangedKey: EnvironmentKey {
    static let defaultValue: ((Bool) -> Void)? = nil
}
extension EnvironmentValues {
    var knobEditingChanged: ((Bool) -> Void)? {
        get { self[KnobEditingChangedKey.self] }
        set { self[KnobEditingChangedKey.self] = newValue }
    }
}

struct KnobView: View {
    @Environment(\.knobEditingChanged) private var editingChanged
    let label: String
    @Binding var value: Double
    var range:       ClosedRange<Double> = 0...127
    var size:        CGFloat             = VintageTheme.knobSize
    var accentColor: Color               = VintageTheme.amber
    /// GUI-01: Knopf sitzt auf hellem Aluminium → dunkle Beschriftung und dunkle Bogenspur.
    var onLight:     Bool                = false
    /// GUI-01-R1: Zahl unter dem Label anzeigen (Standard an). Rein visuell; Accessibility behält den Wert.
    var showsValue:  Bool                = true
    /// Wert für den Doppelklick-Reset. nil = Bereichsmitte (bisheriges Verhalten).
    var resetValue:  Double?             = nil

    @State private var dragging:      Bool    = false
    @State private var dragStartY:    CGFloat = 0
    @State private var dragStartVal:  Double  = 0

    private var normalized:    Double { (value - range.lowerBound) / (range.upperBound - range.lowerBound) }
    private var indicatorDeg:  Double { -135 + normalized * 270 }

    var body: some View {
        if showsValue {
            content
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityValue("\(Int(value))")
        }
    }

    private var content: some View {
        VStack(spacing: 3) {
            ZStack {
                // Range arc (dim background track)
                KnobArc(fromDeg: -135, toDeg: 135)
                    .stroke(onLight ? Color.black.opacity(0.35) : VintageTheme.amberDim,
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: size + 10, height: size + 10)

                // Value arc (bright fill)
                KnobArc(fromDeg: -135, toDeg: -135 + normalized * 270)
                    .stroke(accentColor,
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: size + 10, height: size + 10)

                // GUI-01: Face (geriffelter Rand, Metallkappe, Zeiger) — nur Darstellung
                KnobFace(size: size, indicatorDeg: indicatorDeg, accent: accentColor, dragging: dragging)
            }
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !dragging {
                            editingChanged?(true)
                            dragging     = true
                            dragStartY   = g.startLocation.y
                            dragStartVal = value
                        }
                        let delta = (dragStartY - g.location.y) / 140.0
                        value = (dragStartVal + delta * (range.upperBound - range.lowerBound))
                            .clamped(to: range)
                    }
                    .onEnded { _ in dragging = false; editingChanged?(false) }
            )
            .onTapGesture(count: 2) {
                // Doppelklick setzt auf den Standardwert (oder die Bereichsmitte) zurück
                value = (resetValue ?? (range.lowerBound + range.upperBound) / 2).clamped(to: range)
            }

            Text(label)
                .font(VintageTheme.monoSmall)
                .foregroundColor(onLight ? Mat.inkOnLightSecondary : VintageTheme.textSecondary)

            if showsValue {
                Text("\(Int(value))")
                    .font(VintageTheme.monoSmall)
                    .foregroundColor(onLight ? Mat.inkOnLight : VintageTheme.textAmber)
                    .monospacedDigit()
            }
        }
    }
}

// MARK: - Arc shape
// 0° = 12 o'clock, positive = clockwise (screen coords)

private struct KnobArc: Shape {
    var fromDeg: Double
    var toDeg:   Double

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2 - 1
        // SwiftUI: 0° = 3 o'clock, clockwise on screen = clockwise: false (flipped y)
        // Subtract 90° so our 0° = 12 o'clock
        p.addArc(center: c, radius: r,
                 startAngle: .degrees(fromDeg - 90),
                 endAngle:   .degrees(toDeg   - 90),
                 clockwise:  false)
        return p
    }
}

// MARK: - GateKnobView
// Knob that snaps to the 12 musical gate steps defined in Step.gateSteps.
// Displays the label ("stac", "1/32", "1/16", "1/8.", …) instead of a number.

struct GateKnobView: View {
    @Environment(\.knobEditingChanged) private var editingChanged
    @Binding var gate: Double
    var accentColor: Color
    var size: CGFloat = 44

    @State private var dragging       = false
    @State private var dragStartY:    CGFloat = 0
    @State private var dragStartIndex: Int    = 0

    private var steps: [Step.GateStep] { Step.gateSteps }

    private var currentIndex: Int {
        steps.indices.min(by: { abs(steps[$0].value - gate) < abs(steps[$1].value - gate) }) ?? 0
    }

    private var normalized: Double { Double(currentIndex) / Double(steps.count - 1) }
    private var indicatorDeg: Double { -135 + normalized * 270 }

    // Pixels to drag for one gate-step increment (~same total throw as KnobView)
    private let pxPerStep: CGFloat = 13

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                KnobArc(fromDeg: -135, toDeg: 135)
                    .stroke(VintageTheme.amberDim,
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: size + 10, height: size + 10)

                KnobArc(fromDeg: -135, toDeg: -135 + normalized * 270)
                    .stroke(accentColor,
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: size + 10, height: size + 10)

                KnobFace(size: size, indicatorDeg: indicatorDeg, accent: accentColor, dragging: dragging)
            }
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !dragging {
                            editingChanged?(true)
                            dragging       = true
                            dragStartY     = g.startLocation.y
                            dragStartIndex = currentIndex
                        }
                        let delta  = (dragStartY - g.location.y) / pxPerStep
                        let newIdx = Swift.max(0, Swift.min(steps.count - 1,
                                                            dragStartIndex + Int(delta.rounded())))
                        gate = steps[newIdx].value
                    }
                    .onEnded { _ in dragging = false; editingChanged?(false) }
            )

            Text("GATE")
                .font(VintageTheme.monoSmall)
                .foregroundColor(VintageTheme.textSecondary)

            Text(steps[currentIndex].label)
                .font(VintageTheme.monoSmall)
                .foregroundColor(VintageTheme.textAmber)
                .monospacedDigit()
        }
    }
}

// MARK: - Helpers

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}
