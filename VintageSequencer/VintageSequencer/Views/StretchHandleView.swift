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
        // Nächstliegender Wert (v1.18.31: eigene Brüche stehen nicht in der Liste).
        let options = track.lane.ratioOptions(engine.timeSignature)
        let v = track.lane.stepSixteenths
        return options.indices.min(by: {
            abs(Double(options[$0].num) / Double(options[$0].den) - v)
                < abs(Double(options[$1].num) / Double(options[$1].den) - v)
        }) ?? 0
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
                // Notenwert als Bruch der ganzen Note (v1.18.31; vorher Verhältnis zur 16tel).
                Text(s.laneLength(track.lane, meter: engine.timeSignature))
                    .font(.system(size: isRatioDragging ? 11 : 10, weight: .medium, design: .monospaced))
                    .foregroundColor(accentColor)
                    .opacity(isRatioDragging || isStretched || track.lane.isLongStep ? 1.0 : 0.6)
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
                            interactionController.beginStretchRatioDrag(track: track.data,
                                                                        ratios: track.lane.ratioOptions(engine.timeSignature))
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
        .onValueChange(of: track.lane.stepCount) { n in text = "\(n)" }
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

    @State private var groupsText = ""
    @State private var groupsInvalid = false
    @State private var fractionText = ""
    @State private var fractionInvalid = false

    private var meter: TimeSignature { engine.timeSignature }

    private func setLength(_ new: LaneData.LengthState) {
        writer.apply(.setLength(trackID: track.id, old: track.lane.lengthState, new: new),
                     to: track.data, undoManager: engine.undoManager)
    }
    private func setRatio(_ r: (num: Int, den: Int)) {
        setLength(.init(num: r.num, den: r.den, group: false, groups: track.lane.groups))
    }
    private func isCurrent(_ r: (num: Int, den: Int)) -> Bool {
        !track.lane.stepGroup
            && track.lane.stepLengthNumerator * r.den == r.num * track.lane.stepLengthDenominator
    }

    /// Eine Zeile Notenwerte (v1.18.31): Bezeichnung links, Brüche als Tasten.
    private func row(_ label: String, _ items: [(title: String, r: (num: Int, den: Int), help: String)]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundColor(VintageTheme.textSecondary)
                .frame(width: 66, alignment: .leading)
            ForEach(items.indices, id: \.self) { k in
                let it = items[k]
                Button(it.title) { setRatio(it.r) }
                    .buttonStyle(VintageSmallButtonStyle(isActive: isCurrent(it.r), accent: accentColor))
                    .help(it.help)
            }
            Spacer(minLength: 0)
        }
    }

    private func commitGroups() {
        guard let g = TimeSignature.parseGrouping(groupsText), LaneData.isValidGroups(g) else { groupsInvalid = true; return }
        groupsInvalid = false
        setLength(.init(num: g[0] * 2, den: 1, group: true, groups: g))
    }
    private func commitFraction() {
        guard let r = TrackData.parseFraction(fractionText) else { fractionInvalid = true; return }
        fractionInvalid = false
        setRatio(r)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(s.ratioHeader)
                .font(VintageTheme.monoBold)
                .foregroundColor(VintageTheme.textAmber)

            // Länge als Notenwert (v1.18.31: Bruch der ganzen Note, Takte, „Gruppe 3+4").
            Text(s.laneLength(track.lane, meter: meter))
                .font(.system(size: track.lane.stepGroup ? 22 : 30, weight: .bold, design: .monospaced))
                .foregroundColor(accentColor)
                .frame(maxWidth: .infinity)

            // Was der Wert bedeutet (v1.18.21): Notenwert, Dauer, Spurlänge beim aktuellen Tempo.
            TrackTimingInfo(track: track, accentColor: accentColor)

            ForEach(TrackData.noteRows.indices, id: \.self) { k in
                let r = TrackData.noteRows[k]
                row(s.noteRowLabel(r.row), r.values.map { v in
                    ("\(v.p)/\(v.q)", TrackData.ratio(whole: v.p, v.q), s.noteValueHelp(p: v.p, q: v.q))
                })
            }
            // Takte als Zahl — die Zeile sagt schon „TAKTE".
            row(s.barsRowLabel, TrackData.barRatios(meter).map { r in
                ("\(r.num / max(1, meter.sixteenthsPerBar))", r, s.padLengthHelp)
            })

            // Gruppe je Spur (v1.18.31): Steps reihum so lang wie die Gruppen (in Achteln).
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(s.groupRowLabel)
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(VintageTheme.textSecondary)
                    .frame(width: 66, alignment: .leading)
                Button(s.stepGroupLabel) {
                    let g = track.lane.effectiveGroups(meter)
                    setLength(.init(num: g[0] * 2, den: 1, group: true, groups: track.lane.groups ?? g))
                }
                .buttonStyle(VintageSmallButtonStyle(isActive: track.lane.stepGroup, accent: accentColor))
                .help(s.stepGroupHelp)
                TextField("3+4", text: $groupsText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 80)
                    .onSubmit(commitGroups)
                    .help(s.groupsFieldHelp)
                Spacer(minLength: 0)
            }
            Text(groupsInvalid ? s.groupsInvalid :
                 s.groupsFit(track.lane.effectiveGroups(meter), meter: meter))
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(groupsInvalid ? .red : VintageTheme.textSecondary)
                .padding(.leading, 70)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(s.customFractionLabel)
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(VintageTheme.textSecondary)
                    .frame(width: 66, alignment: .leading)
                TextField("5/16", text: $fractionText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 80)
                    .onSubmit(commitFraction)
                    .help(s.customFractionHelp)
                if fractionInvalid {
                    Text(s.customFractionInvalid).font(.system(size: 8, design: .monospaced)).foregroundColor(.red)
                }
                Spacer(minLength: 0)
            }

            Button(s.ratioReset) { setRatio((1, 1)) }
                .buttonStyle(VintageSmallButtonStyle(isActive: false, accent: .gray))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(14)
        .frame(width: 330)
        .background(VintageTheme.panelDark)
        .preferredColorScheme(.dark)
        .onAppear {
            groupsText = TimeSignature.groupingText(track.lane.effectiveGroups(meter))
            let f = TrackData.wholeFraction(num: track.lane.stepLengthNumerator, den: track.lane.stepLengthDenominator)
            fractionText = "\(f.p)/\(f.q)"
        }
    }
}

/// Notenwert, Step-Dauer und Spurlänge beim aktuellen Tempo (v1.18.21). Beobachtet das Tempo
/// selbst — nur im Popover sichtbar, nicht in der Lane.
private struct TrackTimingInfo: View {
    @ObservedObject var track: TrackViewModel
    var accentColor: Color
    @EnvironmentObject private var engine: SequencerEngine
    @EnvironmentObject private var ts: TransportState
    @AppStorage("appLanguage") private var lang: String = "en"
    private var s: Str { Str(lang) }

    var body: some View {
        let n = track.lane.stepLengthNumerator, d = track.lane.stepLengthDenominator
        let meter = ts.timeSignature
        let step = TimingInfo.stepSeconds(num: n, den: d, bpm: ts.bpm)
        let v = TimingInfo.noteValue(num: n, den: d)
        let named = s.laneLength(track.lane, meter: meter)
        let span = TimingInfo.spanSixteenths(steps: track.lane.stepCount, num: n, den: d)
        VStack(alignment: .leading, spacing: 3) {
            row(s.infoNoteValue, (named == "\(v.num)/\(v.den)" ? named : "\(named) · \(v.num)/\(v.den)")
                + " · \(s.seconds(step))")
            row(s.infoTrackLength, "\(s.stepsCount(track.lane.stepCount)) = \(s.span(span, meter: meter)) · "
                + s.seconds(step * Double(track.lane.stepCount)))
            Text(s.infoAtTempo + String(format: " (%.1f BPM, %@)", ts.bpm, meter.label))
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(VintageTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.25)))
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 8, design: .monospaced)).foregroundColor(VintageTheme.textSecondary)
            Text(value).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundColor(accentColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
