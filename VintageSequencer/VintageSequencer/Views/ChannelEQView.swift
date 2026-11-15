import SwiftUI
import AppKit
import Combine

// MARK: - Kanal-EQ: Kurvenbild im Kanalzug und Editor (v1.18.11)
//
// Bedienung nach Logic Channel EQ (Planarium hat keinen EQ): Kurvenbild im Zug, Klick öffnet
// den Editor. Im Editor Punkte ziehen (waagerecht Frequenz, senkrecht Pegel), ⌘-Ziehen = Güte,
// ⌥ = fein, Doppelklick = Band ein/aus, ⌥-Klick = Band zurücksetzen. Werte darunter: ziehen,
// Scrollrad, Doppelklick = Grundwert. Schreibweg Rack, gebündelt höchstens alle 40 ms.

enum EQChrome {
    static let colors: [Color] = [
        Color(red: 0.62, green: 0.66, blue: 0.72),   // Low Cut
        Color(red: 0.93, green: 0.33, blue: 0.30),   // Low Shelf
        Color(red: 0.98, green: 0.60, blue: 0.22),
        Color(red: 0.96, green: 0.84, blue: 0.25),
        Color(red: 0.42, green: 0.84, blue: 0.40),
        Color(red: 0.30, green: 0.78, blue: 0.92),
        Color(red: 0.62, green: 0.48, blue: 0.95),   // High Shelf
        Color(red: 0.62, green: 0.66, blue: 0.72),   // High Cut
    ]
    static let curve = Color(red: 0.55, green: 0.86, blue: 1.0)
    static let displayRange = 24.0

    /// Frequenz ↔ x (logarithmisch 20 Hz … 20 kHz).
    static func x(_ f: Double, width: CGFloat) -> CGFloat {
        CGFloat(log(f / ChannelEQ.minFrequency) / log(ChannelEQ.maxFrequency / ChannelEQ.minFrequency)) * width
    }
    static func frequency(_ x: CGFloat, width: CGFloat) -> Double {
        ChannelEQ.minFrequency * pow(ChannelEQ.maxFrequency / ChannelEQ.minFrequency, Double(x / max(1, width)))
    }
    static func y(_ db: Double, height: CGFloat, range: Double = displayRange) -> CGFloat {
        height / 2 - CGFloat(max(-range, min(range, db)) / range) * height / 2
    }

    static func curvePath(_ eq: ChannelEQ, size: CGSize, sampleRate: Double, range: Double = displayRange,
                          band: Int? = nil) -> Path {
        var p = Path()
        let steps = max(24, Int(size.width / 2))
        for i in 0...steps {
            let x = size.width * CGFloat(i) / CGFloat(steps)
            let f = frequency(x, width: size.width)
            let db = band.map { ChannelEQ.response(eq.bands[$0], at: f, sampleRate: sampleRate) }
                ?? eq.response(at: f, sampleRate: sampleRate)
            let pt = CGPoint(x: x, y: y(db, height: size.height, range: range))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}

// MARK: - Kurvenbild im Kanalzug

struct ChannelEQThumbnail: View {
    static let height: CGFloat = 30
    let rack: InstrumentRack
    let channelID: UUID
    let eq: ChannelEQ
    let s: Str
    @State private var showEditor = false

    var body: some View {
        Button { showEditor = true } label: {
            Canvas { ctx, size in
                let rate = rack.outputSampleRate ?? 48_000
                var mid = Path(); mid.move(to: CGPoint(x: 0, y: size.height / 2))
                mid.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                ctx.stroke(mid, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
                guard eq.isOn else { return }
                ctx.stroke(EQChrome.curvePath(eq, size: size, sampleRate: rate, range: 18),
                           with: .color(EQChrome.curve.opacity(eq.isNeutral ? 0.45 : 0.95)), lineWidth: 1.2)
            }
            .overlay(alignment: .topLeading) {
                Text("EQ").font(.system(size: 7, weight: .bold))
                    .foregroundColor(eq.isOn ? .white.opacity(0.55) : .white.opacity(0.3))
                    .padding(.leading, 3).padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .background(GlassDisplayBackground(cornerRadius: 3))
            .contentShape(Rectangle())
        }
        .buttonStyle(.fullArea)
        .help(s.eqOpenHelp)
        .accessibilityLabel(s.eqTitle)
        .accessibilityValue(eq.isOn ? (eq.isNeutral ? s.eqFlat : "on") : "off")
        .popover(isPresented: $showEditor, arrowEdge: .trailing) {
            ChannelEQEditor(rack: rack, channelID: channelID, s: s)
        }
    }
}

// MARK: - Gebündeltes Schreiben

/// Hält den gezogenen EQ lokal (die Kurve hängt nie hinter der Maus) und schreibt höchstens
/// alle 40 ms ins Rack; am Ende sofort.
@MainActor final class EQDraft: ObservableObject {
    @Published var eq: ChannelEQ?
    private var pending: Task<Void, Never>?
    var write: ((ChannelEQ) -> Void)?

    func set(_ e: ChannelEQ) {
        eq = e
        guard pending == nil else { return }
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            if let e = self.eq { self.write?(e) }
        }
    }
    func finish() {
        pending?.cancel(); pending = nil
        if let e = eq { write?(e) }
        eq = nil
    }
}

// MARK: - Editor

struct ChannelEQEditor: View {
    @ObservedObject var rack: InstrumentRack
    let channelID: UUID
    let s: Str
    @StateObject private var draft = EQDraft()
    @State private var selected = 3

    private var stored: ChannelEQ { rack.channel(channelID)?.eq ?? ChannelEQ() }
    private var eq: ChannelEQ { draft.eq ?? stored }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { rack.setEQOn(!stored.isOn, for: channelID) } label: {
                    Image(systemName: "power").font(.system(size: 11, weight: .bold))
                        .foregroundColor(stored.isOn ? EQChrome.curve : .white.opacity(0.4))
                        .frame(width: 22, height: 20)
                }
                .buttonStyle(.fullArea)
                .help(stored.isOn ? s.eqOffHelp : s.eqOnHelp)
                Text("\(s.eqTitle) · \(rack.channel(channelID)?.name ?? "")")
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                Spacer()
                Button(s.eqReset) {
                    var e = stored; e.bands = ChannelEQ.defaultBands
                    rack.setEQ(e, for: channelID)
                }
                .buttonStyle(VintageSmallButtonStyle(isActive: false))
                .help(s.eqResetHelp)
            }
            EQGraph(eq: eq, selected: $selected, sampleRate: rack.outputSampleRate ?? 48_000, s: s,
                    change: { draft.set($0) }, end: { draft.finish() })
                .frame(width: 600, height: 240)
                .opacity(stored.isOn ? 1 : 0.55)
            HStack(spacing: 4) {
                ForEach(0..<ChannelEQ.bandCount, id: \.self) { i in
                    EQBandColumn(band: eq.bands[i], index: i, isSelected: selected == i, s: s,
                                 select: { selected = i },
                                 toggle: { rack.setEQBandOn(!eq.bands[i].isOn, band: i, for: channelID) },
                                 change: { b in var e = eq; e.bands[i] = b; draft.set(e) },
                                 end: { draft.finish() })
                }
            }
            .frame(width: 600)
            Text(s.eqGestureHint)
                .font(.system(size: 9)).foregroundColor(.white.opacity(0.5))
        }
        .padding(12)
        .background(Mat.glass)
        .onAppear { draft.write = { [rack, channelID] e in rack.setEQ(e, for: channelID) } }
        .onDisappear { draft.finish() }
    }
}

// MARK: Kurvenfläche

private struct EQGraph: View {
    let eq: ChannelEQ
    @Binding var selected: Int
    let sampleRate: Double
    let s: Str
    let change: (ChannelEQ) -> Void
    let end: () -> Void

    @State private var drag: (index: Int, start: ChannelEQ.Band)?
    @State private var lastClick: (index: Int, time: Date)?

    static let gridFrequencies: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Canvas { ctx, size in
                drawGrid(ctx, size)
                for i in eq.bands.indices where eq.bands[i].isOn && eq.isOn {
                    ctx.stroke(EQChrome.curvePath(eq, size: size, sampleRate: sampleRate, band: i),
                               with: .color(EQChrome.colors[i].opacity(i == selected ? 0.55 : 0.22)), lineWidth: 1)
                }
                let total = EQChrome.curvePath(eq, size: size, sampleRate: sampleRate)
                var fill = total
                fill.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                fill.addLine(to: CGPoint(x: 0, y: size.height / 2))
                fill.closeSubpath()
                ctx.fill(fill, with: .color(EQChrome.curve.opacity(0.12)))
                ctx.stroke(total, with: .color(EQChrome.curve), lineWidth: 1.8)
                for i in eq.bands.indices {
                    let p = handle(i, size)
                    let r: CGFloat = i == selected ? 6 : 5
                    let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
                    let c = EQChrome.colors[i]
                    if eq.bands[i].isOn {
                        ctx.fill(Path(ellipseIn: rect), with: .color(c))
                    } else {
                        ctx.stroke(Path(ellipseIn: rect), with: .color(c.opacity(0.6)), lineWidth: 1)
                    }
                    if i == selected {
                        ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -2.5, dy: -2.5)), with: .color(.white.opacity(0.8)), lineWidth: 1)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { v in dragChanged(v, size) }
                .onEnded { v in dragEnded(v) })
        }
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.55)))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityLabel(s.eqTitle)
    }

    /// Lage eines Punkts: Cuts auf der Nulllinie, sonst auf ihrem Pegel.
    private func handle(_ i: Int, _ size: CGSize) -> CGPoint {
        let b = eq.bands[i]
        return CGPoint(x: EQChrome.x(b.frequency, width: size.width),
                       y: EQChrome.y(b.usesGain ? b.gain : 0, height: size.height))
    }

    private func drawGrid(_ ctx: GraphicsContext, _ size: CGSize) {
        for f in Self.gridFrequencies {
            let x = EQChrome.x(f, width: size.width)
            var p = Path(); p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(p, with: .color(.white.opacity(0.08)), lineWidth: 0.5)
            ctx.draw(Text(s.eqFrequencyShort(f)).font(.system(size: 8)).foregroundColor(.white.opacity(0.4)),
                     at: CGPoint(x: min(size.width - 12, max(10, x)), y: size.height - 7))
        }
        for db in stride(from: -18.0, through: 18.0, by: 6.0) {
            let y = EQChrome.y(db, height: size.height)
            var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(p, with: .color(.white.opacity(db == 0 ? 0.25 : 0.08)), lineWidth: db == 0 ? 0.8 : 0.5)
            if db != 0 {
                ctx.draw(Text(db > 0 ? "+\(Int(db))" : "\(Int(db))").font(.system(size: 8)).foregroundColor(.white.opacity(0.4)),
                         at: CGPoint(x: 12, y: y - 6))
            }
        }
    }

    private func nearest(_ p: CGPoint, _ size: CGSize) -> Int? {
        var best: (Int, CGFloat)?
        for i in eq.bands.indices {
            let h = handle(i, size)
            let d = hypot(h.x - p.x, h.y - p.y)
            if d < 16, best == nil || d < best!.1 { best = (i, d) }
        }
        return best?.0
    }

    private func dragChanged(_ v: DragGesture.Value, _ size: CGSize) {
        let flags = NSEvent.modifierFlags
        if drag == nil {
            guard let i = nearest(v.startLocation, size) else { return }
            selected = i
            drag = (i, eq.bands[i])
        }
        guard let d = drag, hypot(v.translation.width, v.translation.height) > 2 else { return }
        let fine = flags.contains(.option) ? 0.1 : 1.0
        var b = d.start
        if !b.isOn { b.isOn = true }                         // Ziehen schaltet ein (wie Logic)
        if flags.contains(.command) {
            if b.usesQ { b.q = d.start.q * pow(2, Double(-v.translation.height) / 40 * fine) }
        } else {
            let octavesPerPoint = log2(ChannelEQ.maxFrequency / ChannelEQ.minFrequency) / Double(max(1, size.width))
            b.frequency = d.start.frequency * pow(2, Double(v.translation.width) * octavesPerPoint * fine)
            if b.usesGain {
                b.gain = d.start.gain - Double(v.translation.height) / Double(size.height / 2) * EQChrome.displayRange * fine
            }
        }
        b.clamp()
        var e = eq; e.bands[d.index] = b
        change(e)
    }

    private func dragEnded(_ v: DragGesture.Value) {
        defer { drag = nil }
        guard let d = drag else { return }
        if hypot(v.translation.width, v.translation.height) <= 2 {
            // Klick: ⌥ = Grundeinstellung, Doppelklick = ein/aus.
            var e = eq
            if NSEvent.modifierFlags.contains(.option) {
                e.bands[d.index] = ChannelEQ.defaultBand(d.index)
                change(e); end(); lastClick = nil; return
            }
            if let last = lastClick, last.index == d.index, Date().timeIntervalSince(last.time) < NSEvent.doubleClickInterval {
                e.bands[d.index].isOn.toggle()
                change(e); end(); lastClick = nil; return
            }
            lastClick = (d.index, Date())
            return
        }
        end()
    }
}

// MARK: Werte je Band

private struct EQBandColumn: View {
    let band: ChannelEQ.Band
    let index: Int
    let isSelected: Bool
    let s: Str
    let select: () -> Void
    let toggle: () -> Void
    let change: (ChannelEQ.Band) -> Void
    let end: () -> Void

    var body: some View {
        VStack(spacing: 3) {
            Button(action: toggle) {
                Text(s.eqBandShort(band.kind, index: index))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(band.isOn ? .black : .white.opacity(0.7))
                    .frame(maxWidth: .infinity).frame(height: 18)
                    .background(RoundedRectangle(cornerRadius: 3)
                        .fill(band.isOn ? EQChrome.colors[index] : Color.white.opacity(0.08)))
            }
            .buttonStyle(.fullArea)
            .help(band.isOn ? s.eqBandOffHelp : s.eqBandOnHelp)
            EQValueField(text: s.eqFrequency(band.frequency), help: s.eqFrequencyHelp,
                         reset: { var b = band; b.frequency = ChannelEQ.defaultBand(index).frequency; change(b); end() },
                         step: { delta, fine in
                             var b = band; b.frequency *= pow(2, delta / 60 * (fine ? 0.1 : 1)); b.clamp(); change(b) },
                         end: end)
            if band.usesGain {
                EQValueField(text: s.eqGain(band.gain), help: s.eqGainHelp,
                             reset: { var b = band; b.gain = 0; change(b); end() },
                             step: { delta, fine in
                                 var b = band; b.gain += delta / 8 * (fine ? 0.1 : 1); b.clamp(); change(b) },
                             end: end)
            } else {
                MenuKey(menu: {
                    .of(ChannelEQ.slopes.map { sl in
                        ClosureMenuItem(title: s.eqSlope(sl), checked: sl == band.slope) {
                            var b = band; b.slope = sl; change(b); end()
                        }
                    })
                }) {
                    Text(s.eqSlope(band.slope)).font(.system(size: 9).monospacedDigit())
                        .foregroundColor(.white).frame(maxWidth: .infinity).frame(height: 18)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.06)))
                }
                .frame(height: 18)
                .help(s.eqSlopeHelp)
            }
            if band.usesQ {
                EQValueField(text: s.eqQ(band.q), help: s.eqQHelp,
                             reset: { var b = band; b.q = ChannelEQ.defaultBand(index).q; change(b); end() },
                             step: { delta, fine in
                                 var b = band; b.q *= pow(2, delta / 60 * (fine ? 0.1 : 1)); b.clamp(); change(b) },
                             end: end)
            } else {
                Color.clear.frame(height: 18)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 4)
            .stroke(isSelected ? EQChrome.colors[index].opacity(0.8) : Color.white.opacity(0.1), lineWidth: 1))
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { select() })
    }
}

/// Wertfeld: senkrecht ziehen (⌥ = fein), Scrollrad, Doppelklick = Grundwert.
private struct EQValueField: View {
    let text: String
    let help: String
    let reset: () -> Void
    let step: (Double, Bool) -> Void
    let end: () -> Void
    @State private var last: CGFloat?

    var body: some View {
        Text(text)
            .font(.system(size: 9).monospacedDigit())
            .foregroundColor(.white)
            .lineLimit(1)
            .frame(maxWidth: .infinity).frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.06)))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { v in
                    let dy = -(v.translation.height - (last ?? 0))
                    last = v.translation.height
                    step(Double(dy), NSEvent.modifierFlags.contains(.option))
                }
                .onEnded { _ in last = nil; end() })
            .onTapGesture(count: 2) { reset() }
            .modifier(ControlScrollAction { delta, fine in step(delta, fine); end() })
            .help(help)
    }
}
