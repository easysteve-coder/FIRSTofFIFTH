import SwiftUI
import AppKit

// MARK: - Positionsanzeige (v1.18.21, Tempo und Taktart darin seit v1.18.22)
//
// Wie in Logic: Takt.Schlag.Teil.Tick oder Laufzeit, Taktart und Tempo in EINER Anzeige. Das
// Tempo wird dort bedient (Ziehen, Doppelklick zum Eintippen, ▲▼, TAP) — der frühere
// BPM-Drehregler entfällt (Stephan: „der analoge drehregler für bpm wirkt jetzt ästhetisch
// deplatziert").
//
// Quelle der Position ist `HostSync.state(at: jetzt)` — dieselbe Musikposition, die Plug-ins
// bekommen. Die Anker liegen schon auf den geplanten Ausgabezeiten, daher kein weiterer
// Vorlaufabzug (Codex KT-04): angezeigt wird die nominelle FoF-Ausgabe, bei EXT die verzögerte
// FoF-Ausgabe, nicht die Position des Masters. Nach Stop bleibt die Endposition stehen.
//
// Nur die Positionsziffern laufen mit 30 Hz neu (TimelineView, nur bei laufendem Transport);
// sie lesen Atomics, kein `@Published` der Engine.

struct PositionDisplayView: View {
    let hostSync: HostSync
    @EnvironmentObject private var engine: SequencerEngine
    @EnvironmentObject private var ts: TransportState
    @AppStorage("positionShowsTime") private var showsTime = false
    @AppStorage("showTooltips") private var showTooltips = true
    @AppStorage("appLanguage") private var lang = "en"
    @State private var showGrouping = false
    private var s: Str { Str(lang) }
    private func tip(_ text: String) -> String { showTooltips ? text : "" }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Button { showsTime.toggle() } label: {
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !ts.isPlaying)) { _ in
                        let st = hostSync.state(at: mach_absolute_time())
                        HStack(alignment: .top, spacing: 10) {
                            position(st)
                            section(st)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.fullArea)
                .help(tip(showsTime ? s.positionTimeHelp : s.positionBarsHelp))
                .accessibilityIdentifier("positionDisplay")

                HStack(alignment: .center, spacing: 10) {
                    meterKey
                    TempoField(bpm: ts.bpm, set: { engine.setBPM($0) }, help: tip(s.tempoFieldHelp))
                    VStack(spacing: 0) {
                        Button("▲") { engine.setBPM(ts.bpm.rounded(.down) + 1) }
                            .buttonStyle(.fullArea)
                        Button("▼") { engine.setBPM(ts.bpm.rounded(.up) - 1) }
                            .buttonStyle(.fullArea)
                    }
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(VintageTheme.textSecondary)
                    .fixedSize()
                }
            }
            TapButton(set: { engine.setBPM($0) })
                .help(tip(s.tapTempoTooltip))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(GlassDisplayBackground())
    }

    // MARK: Position

    private func position(_ st: HostSync.State) -> some View {
        // Takt, Taktbeginn und Taktart aus demselben Anker (Abschnitt, v1.18.23).
        let meter = TimeSignature(numerator: st.numerator, denominator: st.denominator)
        let f = showsTime ? timeFields(st.seconds) : barFields(st, meter)
        let legend = (showsTime ? s.positionTimeLegend : s.positionBarsLegend)
            .split(separator: " ").map(String.init)
        return HStack(alignment: .top, spacing: 1) {
            ForEach(f.indices, id: \.self) { i in
                if i > 0 { Text(showsTime && i < 3 ? ":" : ".").font(Self.digits) }
                VStack(spacing: 0) {
                    Text(f[i]).font(Self.digits)
                    Text(i < legend.count ? legend[i] : "")
                        .font(.system(size: 7, design: .monospaced))
                        .foregroundColor(VintageTheme.textSecondary)
                }
                .fixedSize()
            }
        }
        .foregroundColor(VintageTheme.textAmber)
        .monospacedDigit()
    }

    /// Laufendes Pattern und nächster Wechsel — aus demselben Anker wie die Position, nicht aus
    /// Main-Zustand (Codex KT-04). Im Stillstand: das gewählte bzw. vorgemerkte Pattern.
    private func section(_ st: HostSync.State) -> some View {
        let running = st.moving && st.pattern >= 0
        let current = running ? st.pattern : ts.currentPatternIndex
        let next = running ? st.nextPattern : (ts.queuedPatternIndex ?? -1)
        let bars = running ? TimingInfo.barsUntil(pulse: st.nextSwitchPulse, from: st.pulse,
                                                  pulsesPerBar: st.pulsesPerBar) : nil
        return VStack(alignment: .leading, spacing: 0) {
            Text(name(current)).font(Self.digits)
            if next >= 0, next != current || bars != nil {
                Text("▸ " + name(next) + (bars.map { " · \($0)" } ?? ""))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
            } else {
                Text(s.positionPatternLegend)
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundColor(VintageTheme.textSecondary)
            }
        }
        .foregroundColor(VintageTheme.textAmber)
        .fixedSize()
        .help(s.positionPatternHelp)
    }

    private func name(_ i: Int) -> String { Pattern.slotNames.indices.contains(i) ? Pattern.slotNames[i] : "–" }

    private static let digits = Font.system(size: 19, weight: .semibold, design: .monospaced)

    private func barFields(_ st: HostSync.State, _ m: TimeSignature) -> [String] {
        let p = TimingInfo.position(bar: st.bar, quartersIntoBar: st.beat - st.barStart, meter: m)
        return [String(format: "%3d", p.bar), "\(p.beat)", "\(p.division)", String(format: "%3d", p.tick)]
    }

    private func timeFields(_ seconds: Double) -> [String] {
        let c = TimingInfo.clock(seconds: seconds)
        return ["\(c.h)", String(format: "%02d", c.m), String(format: "%02d", c.s), String(format: "%03d", c.ms)]
    }

    // MARK: Taktart

    /// Taktart des aktuellen Patterns (v1.18.24). Während der Wiedergabe wird eine Änderung am
    /// laufenden Pattern vorgemerkt und gilt beim nächsten Start dieses Patterns (E2).
    private var meterKey: some View {
        let pending = ts.pendingTimeSignature
        let base = pending ?? ts.timeSignature
        func set(_ m: TimeSignature) { engine.setTimeSignatureUndoable(m, actionName: s.undoTimeSignature) }
        return MenuKey(menu: {
            var items: [NSMenuItem] = TimeSignature.choices.map { m in
                ClosureMenuItem(title: m.label,
                                checked: m.numerator == base.numerator && m.denominator == base.denominator) { set(m) }
            }
            // Gruppierung (v1.18.30, Konzept §10 L5): gängige Aufteilungen, sonst „Eigene…".
            let choices = TimeSignature.groupingChoices(numerator: base.numerator)
            if base.numerator >= 4 {
                items += [.separator(), .note(s.groupingHeader),
                          ClosureMenuItem(title: s.groupingNone, checked: base.grouping == nil) {
                              var m = base; m.grouping = nil; set(m)
                          }]
                items += choices.map { g in
                    ClosureMenuItem(title: TimeSignature.groupingText(g), checked: base.grouping == g) {
                        var m = base; m.grouping = g; set(m)
                    }
                }
                let custom = base.grouping.map { g in !choices.contains(g) } ?? false
                items.append(ClosureMenuItem(title: s.groupingCustom, checked: custom) { showGrouping = true })
            }
            return .of(items)
        }) {
            HStack(spacing: 3) {
                Text(ts.timeSignature.displayLabel)
                if let pending {
                    Text("▸ " + pending.displayLabel).foregroundColor(VintageTheme.textSecondary)
                }
            }
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundColor(VintageTheme.textAmber)
            .padding(.horizontal, 4)
            .overlay(RoundedRectangle(cornerRadius: 2)
                .stroke(VintageTheme.textAmber.opacity(0.35), lineWidth: 1))
        }
        .fixedSize()
        .popover(isPresented: $showGrouping, arrowEdge: .bottom) {
            GroupingPopover(meter: base, s: s) { g in var m = base; m.grouping = g; set(m) }
        }
        .help(tip(pending.map { s.timeSignaturePending(ts.timeSignature, $0) }
                  ?? s.timeSignatureHelp + " — " + s.meterBeatUnit(ts.timeSignature)))
        .accessibilityLabel(s.undoTimeSignature)
        .accessibilityValue(ts.timeSignature.label)
    }
}

// MARK: - Gruppierung

/// Eigene Gruppierung eingeben, z. B. „5+2" (v1.18.30). Gültig, wenn die Summe den Zähler
/// ergibt (2…8 Gruppen); sonst bleibt das Feld offen mit Hinweis.
private struct GroupingPopover: View {
    let meter: TimeSignature
    let s: Str
    let apply: ([Int]) -> Void
    @State private var text = ""
    @State private var invalid = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(s.groupingHeader).font(VintageTheme.monoBold).foregroundColor(VintageTheme.textAmber)
            TextField(meter.grouping.map(TimeSignature.groupingText) ?? "3+4", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                .frame(width: 160)
                .onSubmit(commit)
            Text(invalid ? s.groupingInvalid(meter.numerator) : s.groupingHint(meter.numerator))
                .font(VintageTheme.monoSmall)
                .foregroundColor(invalid ? .red : VintageTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 200, alignment: .leading)
            HStack {
                Spacer()
                Button("OK", action: commit).keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .onAppear { text = meter.grouping.map(TimeSignature.groupingText) ?? "" }
    }

    private func commit() {
        guard let g = TimeSignature.parseGrouping(text),
              TimeSignature.isValidGrouping(g, numerator: meter.numerator) else { invalid = true; return }
        apply(g)
        dismiss()
    }
}

// MARK: - Tempofeld

/// Tempo wie in Logic: senkrecht ziehen ändert um 1 BPM je 4 Punkte (⇧: 0,1), Doppelklick
/// öffnet die Eingabe. 20…300 BPM (`SequencerEngine.setBPM` begrenzt).
private struct TempoField: View {
    let bpm: Double
    let set: (Double) -> Void
    let help: String
    @State private var dragStart: Double?
    @State private var editing = false
    @State private var text = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(String(format: "%.2f", bpm))
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
            Text("BPM").font(.system(size: 8, design: .monospaced))
        }
        .foregroundColor(VintageTheme.textAmber)
        .monospacedDigit()
        .fixedSize()
        .contentShape(Rectangle())
        .onHover { inside in inside ? NSCursor.resizeUpDown.push() : NSCursor.pop() }
        .gesture(DragGesture(minimumDistance: 2)
            .onChanged { v in
                let start = dragStart ?? bpm
                if dragStart == nil { dragStart = bpm }
                let fine = NSEvent.modifierFlags.contains(.shift)
                let delta = -Double(v.translation.height) / 4 * (fine ? 0.1 : 1)
                set(((start + delta) * (fine ? 10 : 1)).rounded() / (fine ? 10 : 1))
            }
            .onEnded { _ in dragStart = nil })
        .onTapGesture(count: 2) { text = String(format: "%.2f", bpm); editing = true }
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            TextField("", text: $text, onCommit: {
                if let v = Double(text.replacingOccurrences(of: ",", with: ".")) { set(v) }
                editing = false
            })
            .font(.system(size: 13, design: .monospaced))
            .frame(width: 80)
            .padding(8)
        }
        .help(help)
        .accessibilityLabel("BPM")
        .accessibilityValue(String(format: "%.2f", bpm))
    }
}

// MARK: - TAP

private struct TapButton: View {
    let set: (Double) -> Void
    @State private var taps: [Date] = []

    var body: some View {
        Button("TAP") {
            let now = Date()
            taps = (taps + [now]).filter { now.timeIntervalSince($0) < 3.0 }
            guard taps.count >= 2 else { return }
            let intervals = zip(taps, taps.dropFirst()).map { $1.timeIntervalSince($0) }
            set(60.0 / (intervals.reduce(0, +) / Double(intervals.count)))
        }
        .buttonStyle(VintageSmallButtonStyle(isActive: false, accent: VintageTheme.amber))
        .fixedSize()
    }
}
