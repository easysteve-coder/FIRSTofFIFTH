import SwiftUI
import AppKit
import Combine

// Bedienelemente des Kanalzugs (v1.13.5). Kennlinien, Gesten und Zustände sind aus
// Planariums Kanalzug übernommen (`Sick/Sources/SickPLSMonitor/HelmutChannelSurface.swift`,
// `SickPLSMonitorKit/FaderLaw.swift` u. a.), damit sich beide Programme gleich bedienen:
// gleiche Faderskala bis +6 dB, Ziehen relativ zum Greifpunkt, ⌥ = fein, Doppelklick =
// Grundstellung, Scrollrad, Esc bricht ab; Plätze mit Ein/Aus · Editor · Auswahl.

// MARK: - Kennlinien

/// Faderstellung 0 … 1 ↔ dB. Stützpunkte wie aufgedruckt; 0 dB bei 0,75, oben +6 dB.
enum FaderLaw {
    struct ScaleMark: Equatable {
        let position: Double
        let dB: Double
        var label: String { dB <= -60 ? "−∞" : String(format: dB > 0 ? "+%.0f" : "%.0f", dB) }
    }
    static let unityPosition = 0.75
    static let maximumDecibels = 6.0
    static let scaleMarks: [ScaleMark] = [
        .init(position: 0, dB: -60), .init(position: 0.08, dB: -40), .init(position: 0.16, dB: -30),
        .init(position: 0.28, dB: -20), .init(position: 0.36, dB: -15), .init(position: 0.46, dB: -10),
        .init(position: 0.56, dB: -6), .init(position: 0.65, dB: -3), .init(position: unityPosition, dB: 0),
        .init(position: 0.875, dB: 3), .init(position: 1, dB: maximumDecibels),
    ]

    static func decibels(forPosition position: Double) -> Double {
        guard position.isFinite else { return -60 }
        let p = min(max(position, 0), 1)
        for (lower, upper) in zip(scaleMarks, scaleMarks.dropFirst()) where p <= upper.position {
            let fraction = (p - lower.position) / (upper.position - lower.position)
            return lower.dB + fraction * (upper.dB - lower.dB)
        }
        return maximumDecibels
    }
    static func position(forDecibels decibels: Double) -> Double {
        guard decibels.isFinite, decibels > -60 else { return 0 }
        if decibels >= maximumDecibels { return 1 }
        for (lower, upper) in zip(scaleMarks, scaleMarks.dropFirst()) where decibels <= upper.dB {
            let fraction = (decibels - lower.dB) / (upper.dB - lower.dB)
            return lower.position + fraction * (upper.position - lower.position)
        }
        return 0
    }
    static func gain(forPosition position: Double) -> Double {
        let dB = decibels(forPosition: position)
        return dB <= -60 ? 0 : pow(10, dB / 20)
    }
    static func position(forGain gain: Double) -> Double {
        guard gain > 0, gain.isFinite else { return 0 }
        return position(forDecibels: 20 * log10(gain))
    }
    static func decibelLabel(forPosition position: Double) -> String {
        let dB = decibels(forPosition: position)
        guard dB > -60 else { return "−∞" }
        let rounded = (dB * 10).rounded() / 10
        // Typ ausdrücklich: als `CVarArg` würde das Literal 0 sonst als Int übergeben.
        let value: Double = rounded == 0 ? 0 : rounded
        return String(format: rounded > 0 ? "+%.1f" : "%.1f", value)
            .replacingOccurrences(of: "-", with: "−")
    }
}

/// Ziehen ist relativ zum Greifpunkt (der Fader springt beim Anfassen nicht); Tastatur und
/// Bedienhilfen verstellen in festen Schritten.
enum FaderMath {
    static let step = 0.05
    static func dragged(startValue: Double, translationY: Double, travel: Double) -> Double {
        guard travel > 0, travel.isFinite, translationY.isFinite else { return clamp(startValue) }
        return clamp(startValue - translationY / travel)
    }
    static func stepped(_ value: Double, up: Bool) -> Double { clamp(value + (up ? step : -step)) }
    private static func clamp(_ value: Double) -> Double { max(0, min(1, value)) }
}

/// Pegelanzeige in dBFS über 60 dB; Farbe hängt an der Höhe im Balken, nicht am Pegel.
enum MeterLaw {
    static let decayDecibelsPerSecond = 20.0
    static let clipHoldSeconds = 2.0
    static func position(forDecibels decibels: Double) -> Double {
        guard decibels.isFinite else { return 0 }
        return min(1, max(0, (decibels + 60) / 60))
    }
    static func position(forGain gain: Double) -> Double {
        guard gain.isFinite, gain > 0 else { return 0 }
        return position(forDecibels: 20 * log10(gain))
    }
    /// Grün bis −12 dBFS, orange ab −6, rot ab −3 — dazwischen stufenlos.
    static let colorStops: [(decibels: Double, color: Color)] = [
        (-60, MixerChrome.meter), (-12, MixerChrome.meter), (-6, .orange), (-3, .orange), (0, .red),
    ]
}

enum PanDisplay {
    /// Zugweg in Punkten für den ganzen Bereich von links nach rechts.
    static let dragTravel = 120.0
    /// „C" in der Mitte, sonst „L37" bzw. „R37" in Prozent.
    static func label(_ pan: Double) -> String {
        let percent = Int((min(max(pan, -1), 1) * 100).rounded())
        if percent == 0 { return "C" }
        return percent < 0 ? "L\(-percent)" : "R\(percent)"
    }
    /// Nach oben ziehen dreht nach rechts.
    static func dragged(startPan: Double, translationY: Double) -> Double {
        let start = min(max(startPan, -1), 1)
        guard translationY.isFinite else { return start }
        return min(max(start - translationY * 2 / dragTravel, -1), 1)
    }
    /// Zeigerwinkel: −135° ganz links, 0° Mitte, +135° ganz rechts.
    static func indicatorAngle(_ pan: Double) -> Double { min(max(pan, -1), 1) * 135 }
}

enum MixerChrome {
    static let controlRaised = Color(red: 0.22, green: 0.225, blue: 0.24)
    static let meter  = Color(red: 0.41, green: 0.82, blue: 0.48)
    static let purple = Color(red: 0.57, green: 0.31, blue: 0.75)   // Instrument
    static let blue   = Color(red: 0.25, green: 0.43, blue: 0.72)   // Insert
    static let labelSize: CGFloat = 10
}

// MARK: - ControlDragSession

/// Zugsitzung eines Reglers: zeichnet aus eigenem Zustand (der Griff hängt nie hinter der
/// Maus), schreibt gebündelt höchstens alle 40 ms ins Modell, ⌥ verfeinert auf ein Zehntel,
/// Esc stellt den Anfangswert wieder her.
@MainActor final class ControlDragSession: ObservableObject {
    @Published private(set) var displayed: Double?
    private(set) var initial: Double?
    private var cancelledUntilRelease = false
    private var lastTranslation = 0.0
    private var translation = 0.0
    private var pending: Task<Void, Never>?
    private var escapeMonitor: Any?
    private var write: ((Double) -> Void)?
    private var lastWritten: Double?
    var isActive: Bool { initial != nil }

    func begin(_ value: Double, write: @escaping (Double) -> Void) {
        guard !isActive, !cancelledUntilRelease else { return }
        initial = value; displayed = value; lastWritten = value
        lastTranslation = 0; translation = 0
        self.write = write
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, self?.isActive == true else { return event }
            self?.cancel(); return nil
        }
    }
    func translated(_ total: Double, fine: Bool) -> Double {
        translation += (total - lastTranslation) * (fine ? 0.1 : 1)
        lastTranslation = total
        return translation
    }
    func change(_ value: Double) {
        guard isActive else { return }
        displayed = value
        guard pending == nil else { return }
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard !Task.isCancelled, let self else { return }
            self.pending = nil; self.flush()
        }
    }
    private func flush() {
        guard let displayed, displayed != lastWritten else { return }
        write?(displayed); lastWritten = displayed
    }
    func finish() {
        cancelledUntilRelease = false
        guard isActive else { return }
        pending?.cancel(); pending = nil; flush(); clear()
    }
    func cancel() {
        guard let initial else { return }
        pending?.cancel(); pending = nil
        if lastWritten != initial { write?(initial) }
        clear(); cancelledUntilRelease = true
    }
    private func clear() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil; write = nil
        initial = nil; displayed = nil; lastWritten = nil
    }
}

/// Scrollrad über einem Regler verstellt ihn (⌥ = fein). Der Monitor lebt nur, solange
/// der Zeiger über dem Regler steht.
struct ControlScrollAction: ViewModifier {
    let action: (Double, Bool) -> Void
    @MainActor final class Handler { var action: ((Double, Bool) -> Void)? }
    @State private var handler = Handler()
    @State private var monitor: Any?
    func body(content: Content) -> some View {
        let _ = { handler.action = action }()
        return content.onHover { [handler] inside in
            remove()
            if inside {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak handler] event in
                    guard event.scrollingDeltaY != 0 else { return event }
                    handler?.action?(event.scrollingDeltaY, event.modifierFlags.contains(.option)); return nil
                }
            }
        }.onDisappear { remove() }
    }
    private func remove() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
}

/// Menüeintrag mit Häkchen; auch die Wahl des schon gewählten Eintrags löst aus.
struct SelectionMenuItem: View {
    let title: String
    let selected: Bool
    let choose: () -> Void
    init(_ title: String, selected: Bool, choose: @escaping () -> Void) {
        self.title = title; self.selected = selected; self.choose = choose
    }
    var body: some View {
        Toggle(title, isOn: Binding(get: { selected }, set: { _ in choose() }))
    }
}

// MARK: - Platz (Instrument / Insert)

struct MixerSlotChoice: Identifiable {
    let id: String
    let title: String
    let selected: Bool
    let action: () -> Void
}

/// Ein Platz im Kanalzug. In Ruhe steht der Name; unter dem Mauszeiger teilt er sich in
/// drei Felder: Ein/Aus (links) · Editor öffnen (Mitte) · Auswahl (rechts).
struct MixerSlotRow: View {
    static let height: CGFloat = 24
    private enum Part { case power, editor, choice }

    let title: String
    let tint: Color
    let isOn: Bool
    let canToggle: Bool
    let canOpen: Bool
    let toggle: () -> Void
    let open: () -> Void
    let choices: [MixerSlotChoice]
    let s: Str

    @State private var hoveredPart: Part?
    @State private var isHovered = false

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                Button(action: toggle) { part("power", .power, width: 20) }
                    .buttonStyle(.fullArea)
                    .disabled(!canToggle)
                    .help(isOn ? s.mixerSlotOffHelp : s.mixerSlotOnHelp)
                    .accessibilityLabel(s.mixerSlotPower(title))
                Button(action: open) { part("slider.horizontal.3", .editor, width: nil) }
                    .buttonStyle(.fullArea)
                    .disabled(!canOpen)
                    .help(s.mixerOpenEditorHelp(title))
                    .accessibilityLabel(s.mixerOpenEditorHelp(title))
                Menu {
                    if choices.isEmpty {
                        Text(s.mixerNoAudioUnits)
                    } else {
                        ForEach(choices) { choice in
                            SelectionMenuItem(choice.title, selected: choice.selected, choose: choice.action)
                        }
                    }
                } label: {
                    part("chevron.up.chevron.down", .choice, width: 20)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 20, height: Self.height)
                .contentShape(Rectangle())
                .help(s.mixerChooseHelp)
                .accessibilityLabel(s.mixerChooseHelp)
            }
            if !isHovered {
                Text(title)
                    .font(.system(size: MixerChrome.labelSize, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.horizontal, 2)
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .background(PlasticKeyBackground(tint: isOn ? tint : nil, tintStrength: 0.85, cornerRadius: 3, pressed: !isOn))
        .foregroundColor(.white)
        .overlay {
            if isHovered {
                HStack(spacing: 0) {
                    Color.clear.frame(width: 20)
                    Color.white.opacity(0.34).frame(width: 0.5)
                    Spacer(minLength: 0)
                    Color.white.opacity(0.34).frame(width: 0.5)
                    Color.clear.frame(width: 20)
                }
                .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .onHover { inside in
            isHovered = inside
            if !inside { hoveredPart = nil }
        }
        .help(title)
        .accessibilityElement(children: .contain)
        .accessibilityValue(isOn ? "on" : "off")
    }

    private func part(_ symbol: String, _ part: Part, width: CGFloat?) -> some View {
        Group {
            if isHovered { Image(systemName: symbol).font(.system(size: 9)) } else { Color.clear }
        }
        .frame(width: width, height: Self.height)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .background(hoveredPart == part ? Color.white.opacity(0.16) : .clear)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hoveredPart = part } else if hoveredPart == part { hoveredPart = nil }
        }
    }
}

// MARK: - Panorama

/// Pan-Regler: senkrecht ziehen (⌥ = fein), Doppelklick stellt auf Mitte, Scrollrad.
struct MixerPanKnob: View {
    let pan: Double
    let setPan: (Double) -> Void
    var diameter: CGFloat = 32
    let s: Str
    @StateObject private var drag = ControlDragSession()

    var body: some View {
        let shown = drag.displayed ?? pan
        ZStack {
            Circle().fill(Color.black.opacity(0.34))
            Circle().stroke(Color.black.opacity(0.8), style: StrokeStyle(lineWidth: 3, dash: [1, 2]))
            Circle().trim(from: 0.12, to: 0.88).stroke(Mat.inkOnLightSecondary, lineWidth: 1)
                .rotationEffect(.degrees(90)).padding(-2)
            Circle()
                .fill(LinearGradient(colors: [Color(white: 0.36), Color(white: 0.06)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .padding(diameter * 0.12)
                .shadow(color: .black.opacity(0.75), radius: 2, y: 1)
            Capsule()
                .fill(Color.white.opacity(0.70))
                .frame(width: 1.5, height: diameter * 0.18)
                .offset(y: -diameter * 0.26)
                .rotationEffect(.degrees(PanDisplay.indicatorAngle(shown)))
            Text(PanDisplay.label(shown))
                .font(.system(size: max(9, diameter * 0.23), weight: .medium).monospacedDigit())
                .foregroundColor(.white)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { event in
                    drag.begin(pan, write: setPan)
                    let t = drag.translated(Double(event.translation.height), fine: NSEvent.modifierFlags.contains(.option))
                    drag.change(PanDisplay.dragged(startPan: drag.initial ?? pan, translationY: t))
                }
                .onEnded { _ in drag.finish() }
        )
        .onDisappear { drag.cancel(); drag.finish() }
        .simultaneousGesture(TapGesture(count: 2).onEnded { drag.cancel(); drag.finish(); setPan(0) })
        .modifier(ControlScrollAction { delta, fine in
            setPan(min(1, max(-1, pan + (delta > 0 ? 0.05 : -0.05) * (fine ? 0.1 : 1))))
        })
        .help(s.mixerPanHelp)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pan")
        .accessibilityValue(PanDisplay.label(shown))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: setPan(min(pan + 0.05, 1))
            case .decrement: setPan(max(pan - 0.05, -1))
            @unknown default: break
            }
        }
    }
}

// MARK: - Fader

/// Aufgedruckte Faderskala; jede Marke sitzt auf der Griffmitte der Stellung, die ihren
/// dB-Wert setzt.
struct MixerFaderScale: View {
    var body: some View {
        GeometryReader { geometry in
            let travel = max(1, geometry.size.height - MixerFader.capHeight)
            ForEach(FaderLaw.scaleMarks, id: \.dB) { mark in
                HStack(spacing: 1) {
                    Text(mark.label)
                        .font(.system(size: 7).monospacedDigit())
                        .foregroundColor(Mat.inkOnLight)
                        .lineLimit(1)
                        .fixedSize()
                    Rectangle().fill(Mat.inkOnLightSecondary).frame(width: 3, height: 1)
                }
                .frame(width: geometry.size.width, alignment: .trailing)
                .position(x: geometry.size.width / 2,
                          y: MixerFader.capHeight / 2 + travel * CGFloat(1 - mark.position))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Senkrechter Fader, Stellung 0 … 1 nach `FaderLaw`. Ziehen relativ zum Greifpunkt
/// (⌥ = fein, Esc bricht ab), Doppelklick = 0 dB, Scrollrad, Pfeiltasten.
struct MixerFader: View {
    static let capHeight: CGFloat = 35
    @Binding var value: Double
    let label: String
    let help: String
    @StateObject private var drag = ControlDragSession()

    var body: some View {
        GeometryReader { geometry in
            let travel = max(1, geometry.size.height - Self.capHeight)
            let clamped = max(0, min(1, drag.displayed ?? value))
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.black.opacity(0.58))
                    .frame(width: 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                MixerFaderCap().offset(y: travel * (1 - clamped))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { event in
                        drag.begin(value, write: { value = $0 })
                        let t = drag.translated(Double(event.translation.height), fine: NSEvent.modifierFlags.contains(.option))
                        drag.change(FaderMath.dragged(startValue: drag.initial ?? value, translationY: t, travel: Double(travel)))
                    }
                    .onEnded { _ in drag.finish() }
            )
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { drag.cancel(); drag.finish(); value = FaderLaw.unityPosition })
        .modifier(ControlScrollAction { delta, fine in
            value = min(1, max(0, value + (delta > 0 ? 0.01 : -0.01) * (fine ? 0.1 : 1)))
        })
        .onDisappear { drag.cancel(); drag.finish() }
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .up:   value = FaderMath.stepped(value, up: true)
            case .down: value = FaderMath.stepped(value, up: false)
            default: break
            }
        }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(FaderLaw.decibelLabel(forPosition: drag.displayed ?? value)) dB")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = FaderMath.stepped(value, up: true)
            case .decrement: value = FaderMath.stepped(value, up: false)
            @unknown default: break
            }
        }
    }
}

/// Fadergriff 17 × 35 pt: hochkant, zwei Riffelzonen, durchgehender dunkler Mittelindex.
private struct MixerFaderCap: View {
    private struct Band { let y: CGFloat; let height: CGFloat; let tone: Double }
    private static let bands: [Band] = {
        var result: [Band] = []
        for i in 0..<10 { result.append(Band(y: CGFloat(i) * 0.5, height: 0.5, tone: 0.82 + Double(i) * 0.008)) }
        let tones = [0.624, 0.655, 0.694, 0.745, 0.796, 0.820, 0.839, 0.859, 0.875, 0.890]
        var y: CGFloat = 5
        for i in 0..<5 {
            result.append(Band(y: y, height: 2, tone: tones[i])); y += 2
            if i < 4 { result.append(Band(y: y, height: 0.5, tone: tones[i] - 0.09)); y += 0.5 }
        }
        result.append(Band(y: 17, height: 1, tone: 0.325))
        y = 18
        for i in 5..<10 {
            result.append(Band(y: y, height: 2, tone: tones[i])); y += 2
            if i < 9 { result.append(Band(y: y, height: 0.5, tone: tones[i] - 0.09)); y += 0.5 }
        }
        for i in 0..<10 { result.append(Band(y: 30 + CGFloat(i) * 0.5, height: 0.5, tone: 0.72 - Double(i) * 0.01)) }
        return result
    }()

    var body: some View {
        Canvas { context, size in
            for band in Self.bands {
                context.fill(Path(CGRect(x: 0, y: band.y, width: size.width, height: band.height)),
                             with: .color(Color(white: band.tone)))
            }
        }
        .frame(width: 17, height: MixerFader.capHeight)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.black.opacity(0.65), lineWidth: 0.5))
        .overlay(alignment: .topLeading) {
            Color.white.opacity(0.55).frame(width: 7, height: 1).padding(.leading, 2).allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.7), radius: 2, y: 3)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }
}

// MARK: - Pegelanzeige

/// Stereo-Pegelanzeige nach dem Fader, in dBFS: Übersteuerungsfeld oben (hält 2 s, Klick
/// löscht sofort), dB-Ziffern, zwei Balken. Abfall 20 dB/s, Anzeige in halben dB.
///
/// Liest die Atomics des `LevelMeter` im eigenen 30-Hz-Takt (`TimelineView`) und zeichnet
/// in einem `Canvas` — nur diese Blatt-View läuft pro Bild, kein `@Published` je Pegelwert.
struct MixerStereoMeter: View {
    let meter: LevelMeter
    let running: Bool
    let s: Str

    /// Anzeigezustand zwischen den Bildern (Referenztyp: wird beim Zeichnen fortgeschrieben).
    final class Ballistics {
        var left: Float = 0, right: Float = 0
        var clipRemaining = 0.0
        var last: Date?
        func step(_ sample: (left: Float, right: Float), now: Date) {
            let elapsed = max(0, min(0.5, last.map { now.timeIntervalSince($0) } ?? 0)); last = now
            let factor = Float(pow(10, -MeterLaw.decayDecibelsPerSecond * elapsed / 20))
            left  = max(sample.left,  left  * factor)
            right = max(sample.right, right * factor)
            clipRemaining = max(sample.left, sample.right) > 1 ? MeterLaw.clipHoldSeconds : max(0, clipRemaining - elapsed)
        }
        func clear() { left = 0; right = 0; clipRemaining = 0; last = nil }
        /// Balkenanteil 0 … 1, auf halbe dB gerundet, höchstens 0 dBFS.
        static func level(_ gain: Float) -> Double {
            guard gain.isFinite, gain > 0 else { return 0 }
            let db = min(0, (20 * log10(Double(gain)) * 2).rounded() / 2)
            return db > -60 ? MeterLaw.position(forDecibels: db) : 0
        }
    }
    @State private var ballistics = Ballistics()

    private static let gradient = Gradient(stops: MeterLaw.colorStops.map {
        .init(color: $0.color, location: MeterLaw.position(forDecibels: $0.decibels))
    })
    private static let clipHeight: CGFloat = 5
    private static let labelWidth: CGFloat = 10

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !running)) { timeline in
            Canvas { ctx, size in
                if running { ballistics.step(meter.take(), now: timeline.date) } else { ballistics.clear() }
                // Übersteuerungsfeld
                ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: Self.clipHeight)),
                         with: .color(ballistics.clipRemaining > 0 ? .red : Color.black.opacity(0.38)))
                let top = Self.clipHeight + 2
                let area = CGRect(x: Self.labelWidth + 1, y: top, width: size.width - Self.labelWidth - 1,
                                  height: max(1, size.height - top))
                // dB-Ziffern
                for db in stride(from: 0, through: -60, by: -6) {
                    let y = area.minY + 3 + (area.height - 6) * (1 - MeterLaw.position(forDecibels: Double(db)))
                    ctx.draw(Text(String(-db)).font(.system(size: 6).monospacedDigit())
                                .foregroundColor(Color.white.opacity(0.58)),
                             at: CGPoint(x: Self.labelWidth / 2, y: y))
                }
                // Balken
                let w = (area.width - 1) / 2
                for (i, gain) in [ballistics.left, ballistics.right].enumerated() {
                    let bar = CGRect(x: area.minX + CGFloat(i) * (w + 1), y: area.minY, width: w, height: area.height)
                    ctx.fill(Path(roundedRect: bar, cornerRadius: 1), with: .color(Color.black.opacity(0.38)))
                    let h = (bar.height - 2) * Ballistics.level(gain)
                    guard h > 0 else { continue }
                    ctx.fill(Path(CGRect(x: bar.minX + 1, y: bar.maxY - 1 - h, width: bar.width - 2, height: h)),
                             with: .linearGradient(Self.gradient,
                                                   startPoint: CGPoint(x: 0, y: bar.maxY - 1),
                                                   endPoint: CGPoint(x: 0, y: bar.minY + 1)))
                }
            }
        }
        .background(GlassDisplayBackground(cornerRadius: 2))
        .contentShape(Rectangle())
        .onTapGesture { ballistics.clipRemaining = 0 }
        .help(s.mixerMeterHelp)
        .accessibilityHidden(true)
    }
}

// MARK: - Taster und Name

/// Mute/Solo-Taster mit Symbol; aktiv in der Signalfarbe.
struct MixerChannelButton: View {
    let symbol: String
    let isOn: Bool
    let activeColor: Color
    let label: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: MixerChrome.labelSize, weight: .semibold))
                .foregroundColor(isOn ? .black : .white)
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .background(PlasticKeyBackground(tint: isOn ? activeColor : nil, tintStrength: 0.9,
                                                 cornerRadius: 3, pressed: isOn))
                .contentShape(Rectangle())
        }
        .buttonStyle(.fullArea)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "on" : "off")
    }
}

/// Textfeld zum Umbenennen: übernimmt mit Eingabetaste oder beim Verlassen, Esc verwirft.
/// Der vorhandene Name ist beim Öffnen ganz markiert (Verhalten des Systemfelds).
struct RenameEntryField: View {
    let initial: String
    let commit: (String) -> Void
    let end: () -> Void
    @State private var draft = ""
    @State private var done = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft)
            .focused($focused)
            .onSubmit { finish(save: true) }
            .onExitCommand { finish(save: false) }
            .onChange(of: focused) { _, isFocused in if !isFocused { finish(save: true) } }
            .onAppear {
                draft = initial
                DispatchQueue.main.async { focused = true }
            }
    }
    private func finish(save: Bool) {
        guard !done else { return }
        done = true
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if save, !value.isEmpty, value != initial { commit(value) }
        end()
    }
}
