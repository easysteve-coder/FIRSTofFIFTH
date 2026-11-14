import SwiftUI

/// Compact stretch handle — two zones stacked (v1.13.14):
///
///    16      ← step count:  drag → count · tap → StepCountPopover
///   ────
///    3/2     ← step length: drag → ratio · tap → StepLengthPopover
///
/// **Arch-Slice-8 — IC migration:**
/// All drag mutations flow through `InteractionController` + `ModelWriter`.
/// No `@State` accumulators, no direct track mutations, no manual undo registration.
/// `isRatioDragging` and `isCountDragging` are pure UI-only session tracking flags.
///
/// **Cursor Phase 2 — Hover unification:**
/// Idle hover cursor (`resizeUpDown`) is provided by `.background(StretchCursorArea())`
/// — an AppKit cursor-rect view — replacing the former SwiftUI `.onHover` approach.
/// This ensures `CursorController.disableCursorRects()` suppresses it during sessions
/// and `resetCursorRects()` restores it immediately on session end (even when the
/// pointer is already over the handle), matching `HandleNSView`'s mechanism exactly.
struct StretchHandleView: View {
    @ObservedObject var track: TrackViewModel
    var accentColor:   Color
    var baseStepWidth: CGFloat
    @EnvironmentObject private var engine:               SequencerEngine
    /// Nur Aufrufe, keine Darstellung → einfache Referenz statt Beobachtung.
    private var interactionController: InteractionController { engine.interactionController }

    @Environment(\.undoManager) private var undoManager
    @AppStorage("appLanguage")  private var lang: String = "en"
    private var s: Str { Str(lang) }

    /// Visual-only flag for ratio zone — controls fraction vs. grip rendering.
    /// Pure UI state: set true on first drag event, false on drag end.
    /// NOT model state — no snapshot stored here.
    @State private var isRatioDragging: Bool = false

    /// Session-tracking flag for count zone — guards the IC.begin call.
    /// Prevents re-entering beginStretchCountDrag on subsequent onChanged events.
    @State private var isCountDragging: Bool = false

    @State private var showRatioPopover: Bool = false
    @State private var showCountPopover: Bool = false

    private var currentRatioIndex: Int {
        track.lane.ratioOptions.firstIndex(where: {
            $0.num == track.lane.stepLengthNumerator && $0.den == track.lane.stepLengthDenominator
        }) ?? (track.lane.ratioOptions.count / 2)
    }

    private func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }

    private var reducedRatio: (num: Int, den: Int) {
        let n = track.lane.stepLengthNumerator
        let d = track.lane.stepLengthDenominator
        let g = gcd(n, d)
        return (n / g, d / g)
    }

    private var isStretched: Bool {
        track.lane.stepLengthNumerator != 1 || track.lane.stepLengthDenominator != 1
    }

    /// Breite der Spalte rechts neben jeder Lane (v1.13.14: schmal, vorher 80).
    static let width: CGFloat = 40

    var body: some View {
        // Oben Step-Anzahl, unten Step-Länge — schmal und zurückhaltend; beide Felder
        // bleiben volle Klick-/Zieh-Flächen.
        VStack(spacing: 0) {

            // ── Oben: Step-Anzahl ─────────────────────────────────────────
            // Tap  → StepCountPopover (direkte Eingabe, ±)
            // Drag → IC.beginStretchCountDrag / update / commit (Arch-Slice-8)
            Button(action: { showCountPopover = true }) {
                Text("\(track.lane.stepCount)")
                    .font(.system(size: isCountDragging ? 12 : 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(VintageTheme.textAmber.opacity(isCountDragging ? 1 : 0.85))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.fullArea)
            .popover(isPresented: $showCountPopover, arrowEdge: .leading) {
                StepCountPopover(track: track, accentColor: accentColor)
                    .environmentObject(engine)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if !isCountDragging {
                            isCountDragging = true
                            interactionController.beginStretchCountDrag(track: track.data)
                        }
                        interactionController.updateStretchCountDrag(
                            totalY: value.translation.height,
                            track:  track.data
                        )
                    }
                    .onEnded { _ in
                        isCountDragging = false
                        interactionController.commitStretchCountDrag(
                            track:       track.data,
                            undoManager: undoManager
                        )
                    }
            )
            .help(s.stepCountHelp)

            Rectangle()
                .fill(VintageTheme.panelBorder)
                .frame(height: 1)
                .padding(.horizontal, 8)

            // ── Unten: Step-Länge (Verhältnis) ────────────────────────────
            // Tap  → StepLengthPopover
            // Drag → IC.beginStretchRatioDrag / update / commit (Arch-Slice-8)
            Button(action: { showRatioPopover = true }) {
                // Immer als Zahl (1/1 gedämpft) — ein namenloser Griff verriet nicht,
                // was hier einstellbar ist.
                Text(track.lane.isPad
                     ? TrackData.ratioLabel(num: track.lane.stepLengthNumerator,
                                            den: track.lane.stepLengthDenominator)
                     : "\(reducedRatio.num)/\(reducedRatio.den)")
                    .font(.system(size: isRatioDragging ? 11 : 10, weight: .medium, design: .monospaced))
                    .foregroundColor(accentColor)
                    .opacity(isRatioDragging || isStretched || track.lane.isPad ? 1.0 : 0.45)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.fullArea)
            .popover(isPresented: $showRatioPopover, arrowEdge: .leading) {
                StepLengthPopover(track: track, accentColor: accentColor)
                    .environmentObject(engine)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if !isRatioDragging {
                            isRatioDragging = true
                            interactionController.beginStretchRatioDrag(track: track.data)
                        }
                        interactionController.updateStretchRatioDrag(
                            totalY: value.translation.height,
                            track:  track.data
                        )
                    }
                    .onEnded { _ in
                        isRatioDragging = false
                        interactionController.commitStretchRatioDrag(
                            track:       track.data,
                            undoManager: undoManager
                        )
                    }
            )
            .help(isStretched ? s.ratioTapHelp : s.ratioStretchHelp)
        }
        .padding(.vertical, 4)
        // Idle hover cursor via AppKit cursor rects (unified with HandleNSView).
        // StretchCursorArea registers resizeUpDown over its entire bounds via
        // resetCursorRects(), so disableCursorRects() / enableCursorRects() from
        // CursorController suppresses and restores it correctly during sessions.
        .background(StretchCursorArea())
        .frame(width: Self.width)
    }
}

// MARK: - Step count popover

/// Direkte Eingabe der Step-Anzahl (1…64): Zahlenfeld mit ±. Jede Änderung ist ein
/// eigener Undo-Schritt über den Undo-Manager des Hauptfensters.
private struct StepCountPopover: View {
    @ObservedObject var track: TrackViewModel
    var accentColor: Color
    @EnvironmentObject private var engine: SequencerEngine
    @AppStorage("appLanguage") private var lang: String = "en"
    private var s: Str { Str(lang) }
    private let writer = ModelWriter()
    @State private var text: String = ""
    @FocusState private var fieldFocused: Bool

    private func set(_ raw: Int) {
        let new = max(1, min(64, raw))
        text = "\(new)"
        guard new != track.lane.stepCount else { return }
        writer.apply(.setStepCount(trackID: track.id, old: track.lane.stepCount, new: new),
                     to: track.data, undoManager: engine.undoManager)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(s.stepCountHeader)
                .font(VintageTheme.monoBold)
                .foregroundColor(VintageTheme.textAmber)
            HStack(spacing: 6) {
                Button("−") { set(track.lane.stepCount - 1) }
                    .buttonStyle(VintageSmallButtonStyle(isActive: false, accent: accentColor))
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .frame(width: 56)
                    .focused($fieldFocused)
                    .onSubmit { set(Int(text) ?? track.lane.stepCount) }
                Button("+") { set(track.lane.stepCount + 1) }
                    .buttonStyle(VintageSmallButtonStyle(isActive: false, accent: accentColor))
            }
            HStack(spacing: 4) {
                ForEach([4, 8, 12, 16, 24, 32, 64], id: \.self) { n in
                    Button("\(n)") { set(n) }
                        .buttonStyle(VintageSmallButtonStyle(isActive: track.lane.stepCount == n,
                                                             accent: accentColor))
                }
            }
        }
        .padding(14)
        .background(VintageTheme.panelDark)
        .preferredColorScheme(.dark)
        .onAppear { text = "\(track.lane.stepCount)"; fieldFocused = true }
        .onChange(of: track.lane.stepCount) { _, n in text = "\(n)" }
    }
}

// MARK: - Step length popover

private struct StepLengthPopover: View {
    @ObservedObject var track: TrackViewModel
    var accentColor: Color
    @EnvironmentObject private var engine: SequencerEngine
    @AppStorage("appLanguage") private var lang: String = "en"
    private var s: Str { Str(lang) }
    private let writer = ModelWriter()

    private func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }

    private var reducedRatio: (num: Int, den: Int) {
        let n = track.lane.stepLengthNumerator
        let d = track.lane.stepLengthDenominator
        let g = gcd(n, d)
        return (n / g, d / g)
    }

    // Schnellwahl-Verhältnisse; Namen und Erklärungen kommen aus Str (EN/DE).
    private static let ratioPairs: [(num: Int, den: Int)] = [
        (1, 2), (4, 7), (2, 3), (3, 4), (4, 5), (8, 9), (1, 1),
        (9, 8), (5, 4), (4, 3), (3, 2), (7, 4), (2, 1),
    ]
    private var ratioOptions: [(label: String, num: Int, den: Int, tooltip: String)] {
        if track.lane.isPad {
            return TrackData.padRatios.map { p in
                (TrackData.ratioLabel(num: p.num, den: p.den), p.num, p.den, s.padLengthHelp)
            }
        }
        return Self.ratioPairs.map { p in
            let o = s.ratioOption(num: p.num, den: p.den)
            return (o.label, p.num, p.den, o.tooltip)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(s.ratioHeader)
                .font(VintageTheme.monoBold)
                .foregroundColor(VintageTheme.textAmber)

            // Fraction display (Pad-Lane: Länge in Takten/Notenwerten)
            let r = reducedRatio
            if track.lane.isPad {
                Text(TrackData.ratioLabel(num: track.lane.stepLengthNumerator,
                                          den: track.lane.stepLengthDenominator))
                    .font(.system(size: 30, weight: .bold, design: .monospaced))
                    .foregroundColor(accentColor)
                    .frame(maxWidth: .infinity)
            } else {
            VStack(spacing: 3) {
                Text("\(r.num)")
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .foregroundColor(accentColor)
                Rectangle()
                    .fill(accentColor)
                    .frame(height: 2)
                    .padding(.horizontal, 20)
                Text("\(r.den)")
                    .font(.system(size: 30, weight: .bold, design: .monospaced))
                    .foregroundColor(accentColor)
            }
            .frame(maxWidth: .infinity)
            }

            Text(s.ratioQuickSelect)
                .font(VintageTheme.monoSmall)
                .foregroundColor(VintageTheme.textSecondary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                      alignment: .leading, spacing: 4) {
                ForEach(ratioOptions, id: \.label) { opt in
                    let isCurrent = track.lane.stepLengthNumerator == opt.num
                                 && track.lane.stepLengthDenominator == opt.den
                    Button(opt.label) {
                        writer.apply(.setRatio(trackID: track.id,
                                               oldNum: track.lane.stepLengthNumerator,
                                               oldDen: track.lane.stepLengthDenominator,
                                               newNum: opt.num,
                                               newDen: opt.den),
                                     to: track.data, undoManager: engine.undoManager)
                    }
                    .buttonStyle(VintageSmallButtonStyle(isActive: isCurrent, accent: accentColor))
                    .help(opt.tooltip)
                }
            }

            Button(s.ratioReset) {
                let base = track.lane.isPad ? (num: 16, den: 1) : (num: 1, den: 1)
                writer.apply(.setRatio(trackID: track.id,
                                       oldNum: track.lane.stepLengthNumerator,
                                       oldDen: track.lane.stepLengthDenominator,
                                       newNum: base.num,
                                       newDen: base.den),
                             to: track.data, undoManager: engine.undoManager)
            }
            .buttonStyle(VintageSmallButtonStyle(isActive: false, accent: .gray))
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(14)
        .frame(width: 260)
        .background(VintageTheme.panelDark)
        .preferredColorScheme(.dark)
    }
}
