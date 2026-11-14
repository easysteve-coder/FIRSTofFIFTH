import SwiftUI

struct TransportView: View {
    @EnvironmentObject var engine: SequencerEngine
    @EnvironmentObject private var ts: TransportState
    @EnvironmentObject private var pes: PresetEditorState
    @EnvironmentObject private var mls: MIDILearnState
    @EnvironmentObject private var stepWidthState: StepWidthState
    @EnvironmentObject private var notesStore: NotesStore
    @State private var showSettings     = false
    @AppStorage("showMixer") private var showMixer: Bool = false
    @State private var showQuickCapture = false
    @State private var showNotesReader  = false
    @State private var tapTimes: [Date] = []

    @AppStorage("showTooltips")  private var showTooltips: Bool   = true
    @AppStorage("appLanguage")   private var lang:         String = "en"
    private var s: Str { Str(lang) }
    private func tip(_ text: String) -> String { showTooltips ? text : "" }

    /// GUI-01-R1: gemeinsame sichtbare Außenhöhe der drei hellen Transportplatten (BPM/SWING/WIDTH).
    private static let plateHeight: CGFloat = 84

    private var bpmBinding: Binding<Double> {
        Binding(get: { ts.bpm },
                set: { engine.setBPM($0) })
    }
    // Maps internal 50–75 range to display 0–100%
    private var swingBinding: Binding<Double> {
        Binding(
            get: { (pes.swing - 50.0) * 4.0 },
            set: { pes.swing = ($0 / 4.0) + 50.0 }
        )
    }

    var body: some View {
        HStack(spacing: 0) {

            // ── Logo ─────────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 1) {
                // GUI-01-R1: Produktname hat Vorrang vor Untertitel/Dateiname und wird nie gekürzt.
                Text("FIRSTofFIFTH")
                    .font(VintageTheme.monoTitle)
                    .foregroundColor(VintageTheme.textAmber)
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(3)
                Text("Polyrhythmic Step Sequencer  v\(VintageTheme.appVersion)")
                    .font(VintageTheme.monoSmall)
                    .foregroundColor(VintageTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // Dateiname + Unsaved-Indicator
                HStack(spacing: 3) {
                    if pes.hasUnsavedChanges {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 5, height: 5)
                    }
                    Text(pes.currentPresetURL?.lastPathComponent ?? "—")
                        .font(VintageTheme.monoMedium)
                        .foregroundColor(pes.hasUnsavedChanges
                            ? Color.orange.opacity(0.9)
                            : VintageTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 160, alignment: .leading)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .layoutPriority(3)

            sep

            // ── Play / Stop ───────────────────────────────────────────────
            HStack(spacing: 10) {
                Button {
                    ts.isPlaying ? engine.stop() : engine.play()
                } label: {
                    Image(systemName: ts.isPlaying ? "stop.fill" : "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 36, height: 36)
                        .foregroundColor(ts.isPlaying ? .black : VintageTheme.textAmber)
                        .background(
                            ZStack {
                                PlasticKeyBackground(tint: nil, cornerRadius: 5, pressed: ts.isPlaying)
                                if ts.isPlaying {
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(LinearGradient(colors: [VintageTheme.amberBright, VintageTheme.amber],
                                                             startPoint: .top, endPoint: .bottom))
                                        .padding(1)
                                }
                            }
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.fullArea)
                .help(tip(ts.isPlaying ? s.stopTooltip : s.playTooltip))
                // Slice 12b: XCUI-Smoke-Test-Anker.
                // accessibilityValue spiegelt isPlaying für XCUIElement.value-Assertions.
                .accessibilityIdentifier("playStopButton")
                .accessibilityValue(ts.isPlaying ? "playing" : "stopped")

                // Running LED
                Circle()
                    .fill(ts.isPlaying ? VintageTheme.amberBright : VintageTheme.amberDim)
                    .frame(width: 10, height: 10)
                    .shadow(color: VintageTheme.amber.opacity(ts.isPlaying ? 0.9 : 0),
                            radius: 7)
                    .animation(.easeInOut(duration: 0.12), value: ts.isPlaying)
            }
            .padding(.horizontal, 8)

            sep

            // ── BPM: Knopf + Anzeigeglas + TAP auf hellem Aluminium (GUI-01) ──
            MetalPlate(tone: .lightAluminium, cornerRadius: 6) {
                HStack(spacing: 0) {
                    KnobView(label: "BPM", value: bpmBinding,
                             range: 20...300, size: 48,
                             accentColor: VintageTheme.amber, onLight: true, showsValue: false,
                             resetValue: 120)
                        .fixedSize()                 // Label unter dem Knopf nie auf „…“ kürzen
                        .padding(.horizontal, 2)

                    VStack(spacing: 2) {
                        Button("▲") { engine.setBPM(ts.bpm + 1) }
                            .buttonStyle(.fullArea)
                            .fixedSize()
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(Mat.inkOnLightSecondary)

                        Text(String(format: "%.1f", ts.bpm))
                            .font(VintageTheme.monoLarge)
                            .foregroundColor(VintageTheme.textAmber)
                            .frame(width: 46)
                            .padding(.vertical, 2)
                            .background(GlassDisplayBackground())
                            .monospacedDigit()

                        Button("▼") { engine.setBPM(ts.bpm - 1) }
                            .buttonStyle(.fullArea)
                            .fixedSize()
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(Mat.inkOnLightSecondary)
                    }
                    .padding(.trailing, 3)

                    Button("TAP") { tapTempo() }
                        .buttonStyle(VintageSmallButtonStyle(isActive: false, accent: VintageTheme.amber))
                        .fixedSize()                 // bei Mindestbreite nicht auf einen Streifen quetschen
                        .padding(.trailing, 4)
                        .help(tip(s.tapTempoTooltip))
                }
                .frame(height: Self.plateHeight)
            }
            .padding(.horizontal, 2)

            sep

            // ── Swing ─────────────────────────────────────────────────────
            MetalPlate(tone: .lightAluminium, cornerRadius: 6) {
                KnobView(label: "SWING", value: swingBinding,
                         range: 0...100, size: 36,
                         accentColor: VintageTheme.amber, onLight: true, showsValue: false)
                    .fixedSize()
                    .padding(.horizontal, 4)
                    .frame(height: Self.plateHeight)
                    .help(tip(s.swingTooltip))
            }
            .padding(.horizontal, 2)

            sep

            // ── Patterns ──────────────────────────────────────────────────
            VStack(spacing: 3) {
                Text("PATTERN")
                    .font(VintageTheme.monoSmall)
                    .foregroundColor(VintageTheme.textSecondary)
                    .fixedSize()
                // 16 Patterns (v1.14.0) in zwei Reihen A–H / I–P.
                VStack(spacing: 2) {
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: 2) {
                            ForEach(0..<8, id: \.self) { col in
                                let i = row * 8 + col
                                let name = Pattern.slotNames[i]
                                Button(name) { engine.switchPattern(i) }
                                    .buttonStyle(VintagePatternButtonStyle(
                                        isActive: ts.currentPatternIndex == i,
                                        isQueued: ts.queuedPatternIndex == i,
                                        compact: true))
                                    .help(tip(ts.queuedPatternIndex == i
                                          ? s.patternQueuedTip(name)
                                          : (i < 9 ? s.patternSwitchTip(name, i + 1)
                                                   : s.patternSwitchTipNoKey(name))))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 6)

            sep

            // ── MIDI Learn ────────────────────────────────────────────────
            VStack(spacing: 3) {
                Text("LEARN")
                    .font(VintageTheme.monoSmall)
                    .foregroundColor(VintageTheme.textSecondary)
                    .fixedSize()
                Button(mls.learnMode ? "ON" : "OFF") {
                    mls.learnMode.toggle()
                    if !mls.learnMode { mls.learnTarget = nil }
                }
                .buttonStyle(VintageSmallButtonStyle(
                    isActive: mls.learnMode,
                    accent: Color(red: 1.0, green: 1.0, blue: 0.3)))
                .fixedSize()
                .help(tip(mls.learnMode ? s.learnActiveTooltip : s.learnInactiveTooltip))
            }
            .padding(.horizontal, 6)

            Spacer()

            // ── Step-Breite: dezenter Schieber rechts (v1.13.10) ─────────────
            // Gleiche Binding-Strecke wie zuvor: StepWidthState.size, 30…120.
            HStack(spacing: 4) {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 9))
                    .foregroundColor(VintageTheme.textDim)
                Slider(value: $stepWidthState.size, in: StepWidthState.range)
                    .controlSize(.mini)
                    .tint(VintageTheme.textDim)
                    .frame(width: 64)
                    .accessibilityLabel(s.stepWidthLabel)
            }
            .padding(.trailing, 10)
            .help(tip(s.stepWidthLabel))

            // ── Notes: Quick Capture ──────────────────────────────────────
            Button {
                showQuickCapture.toggle()
            } label: {
                Image(systemName: "pencil.circle")
                    .font(.system(size: 15))
                    .foregroundColor(showQuickCapture
                        ? VintageTheme.textAmber
                        : VintageTheme.textSecondary)
                    .frame(width: 28, height: 36)
            }
            .buttonStyle(.fullArea)
            .help(tip("Quick Note  (pencil)"))
            .popover(isPresented: $showQuickCapture, arrowEdge: .bottom) {
                QuickCaptureView(store: notesStore)
            }

            // ── Notes: Reader ─────────────────────────────────────────────
            Button {
                showNotesReader = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "note.text")
                        .font(.system(size: 15))
                        .foregroundColor(VintageTheme.textSecondary)
                        .frame(width: 28, height: 36)
                    if !notesStore.entries.isEmpty {
                        Text("\(min(notesStore.entries.count, 99))")
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                            .foregroundColor(.black)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(VintageTheme.amber)
                            .clipShape(Capsule())
                            .offset(x: 4, y: 2)
                    }
                }
            }
            .buttonStyle(.fullArea)
            .padding(.trailing, 4)
            .help(tip("All Notes"))
            .sheet(isPresented: $showNotesReader) {
                NotesReaderView(store: notesStore)
            }

            sep

            // ── Instrumenten-Rack (v1.13.0) ──────────────────────────────
            Button {
                showMixer.toggle()
            } label: {
                Image(systemName: "slider.vertical.3")
                    .font(.system(size: 15))
                    .foregroundColor(showMixer ? VintageTheme.textAmber : VintageTheme.textSecondary)
                    .frame(width: 32, height: 36)
            }
            .buttonStyle(.fullArea)
            .help(tip(s.rackTooltip))

            // ── Settings ──────────────────────────────────────────────────
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .foregroundColor(VintageTheme.textSecondary)
                    .frame(width: 32, height: 36)
            }
            .buttonStyle(.fullArea)
            .padding(.trailing, 8)
            .help(tip(s.settingsTooltip))
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(engine)
            }
            // App-Menü „Einstellungen …" (⌘,) öffnet dasselbe Blatt.
            .onReceive(NotificationCenter.default.publisher(for: .fofOpenSettings)) { _ in
                showSettings = true
            }
        }
        .frame(height: 100)
        .background(MetalSurface(tone: .darkMetal))
        .overlay(
            Rectangle()
                .fill(Color.black.opacity(0.7))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    // MARK: - Helpers

    private var sep: some View {
        // Gravur: dunkle Rille mit heller Kante rechts (Licht links oben)
        HStack(spacing: 0) {
            Rectangle().fill(Color.black.opacity(0.6)).frame(width: 1)
            Rectangle().fill(Color.white.opacity(0.10)).frame(width: 1)
        }
        .frame(height: 52)
        .padding(.horizontal, 1)
    }

    private func tapTempo() {
        let now = Date()
        tapTimes.append(now)
        tapTimes = tapTimes.filter { now.timeIntervalSince($0) < 3.0 }
        guard tapTimes.count >= 2 else { return }
        let intervals = zip(tapTimes, tapTimes.dropFirst())
            .map { $1.timeIntervalSince($0) }
        let avg = intervals.reduce(0, +) / Double(intervals.count)
        engine.setBPM((60.0 / avg).clamped(to: 20...300))
    }
}

extension Notification.Name {
    /// App-Menü → Einstellungen öffnen.
    static let fofOpenSettings = Notification.Name("fofOpenSettings")
}
