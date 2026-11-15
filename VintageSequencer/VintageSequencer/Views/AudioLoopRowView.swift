import SwiftUI

// MARK: - AudioLoopRowView (v1.15.0)
//
// Zeile einer Audio-Loop-Spur: Kopf mit Aufnahme, Undo, Löschen, Länge, Eingang, Mithören,
// Gate; daneben Wellenform mit Takten und Wiedergabeort. Seit v1.15.2 (Codex M5) beobachtet
// die Zeile nur den Anzeigezustand ihres Kanals (`AudioLoopDisplay`) und das Kanalverzeichnis
// (Anlegen/Entfernen) — nie das ganze Rack. Hochfrequente Blätter (Wiedergabeort, Pegel,
// Blinken) laufen nur, solange es etwas zu zeigen gibt.

struct AudioLoopRowView<Menu: View, Edge: View>: View {
    @ObservedObject var track: TrackViewModel
    let rack: InstrumentRack
    @ObservedObject var directory: ChannelDirectory
    var accentColor: Color
    var height: CGFloat
    let edge: () -> Edge
    @ViewBuilder var contextMenu: () -> Menu

    init(track: TrackViewModel, rack: InstrumentRack, accentColor: Color, height: CGFloat,
         edge: @escaping () -> Edge,
         @ViewBuilder contextMenu: @escaping () -> Menu) {
        self.track = track
        self.rack = rack
        self.directory = rack.directory
        self.accentColor = accentColor
        self.height = height
        self.edge = edge
        self.contextMenu = contextMenu
    }

    var body: some View {
        // Das Verzeichnis ändert sich beim Anlegen/Entfernen von Kanälen: dann neu nachschlagen.
        let display = directory.entries.contains { $0.id == track.instrumentID && $0.isAudioLoop }
            ? rack.loopDisplay(track.instrumentID) : nil
        HStack(spacing: 0) {
            AudioLoopHeader(track: track, rack: rack, display: display, accentColor: accentColor)
                .frame(width: VintageTheme.trackHeaderWidth, height: height)
                .contentShape(Rectangle())
                .contextMenu { contextMenu() }
            Rectangle()
                .fill(Color(red: 0.55, green: 0.42, blue: 0.20).opacity(0.55))
                .frame(width: 1)
            Group {
                if let display { AudioLoopBody(display: display, accentColor: accentColor) }
                else { Color.clear }
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(GridWellSurface())
            edge().frame(height: height)
        }
        .background(VintageTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.red.opacity(0.35), lineWidth: 1))
    }
}

// MARK: - Kopf

private struct AudioLoopHeader: View {
    @ObservedObject var track: TrackViewModel
    let rack: InstrumentRack
    let display: AudioLoopDisplay?
    var accentColor: Color
    @EnvironmentObject private var engine: SequencerEngine
    @AppStorage("appLanguage") private var lang: String = "en"
    @AppStorage("showTooltips") private var showTooltips: Bool = true
    private var s: Str { Str(lang) }
    private func tip(_ t: String) -> String { showTooltips ? t : "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // ── Zeile 1: Schild, Name, m/s ─────────────────────────────────
            HStack(spacing: 4) {
                Text(s.loopBadge)
                    .font(.system(size: 8, weight: .heavy, design: .monospaced))
                    .foregroundColor(.black)
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 2).fill(Color.red.opacity(0.8)))
                // Umbenennen wie bei allen Spuren (v1.17.3).
                TrackNameField(track: track, accentColor: accentColor, placeholder: s.namePlaceholder)
                TrackMuteSoloButtons(track: track, s: s, tip: tip)
            }

            if let display {
                AudioLoopControls(track: track, rack: rack, display: display)
            } else {
                Text(s.loopNoChannel)
                    .font(VintageTheme.monoSmall)
                    .foregroundColor(VintageTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .simultaneousGesture(TapGesture().onEnded { engine.lastAudioLoopTrack = track.id })
    }
}

/// Bedienzeilen 2 und 3 — beobachten nur den Anzeigezustand des Kanals.
private struct AudioLoopControls: View {
    @ObservedObject var track: TrackViewModel
    let rack: InstrumentRack
    @ObservedObject var display: AudioLoopDisplay
    @EnvironmentObject private var engine: SequencerEngine
    @AppStorage("appLanguage") private var lang: String = "en"
    @AppStorage("showTooltips") private var showTooltips: Bool = true
    private var s: Str { Str(lang) }
    private func tip(_ t: String) -> String { showTooltips ? t : "" }
    @State private var showInput = false
    @State private var showGate = false

    private func update(_ change: (inout AudioLoopSettings) -> Void) {
        var s = display.settings
        change(&s)
        rack.setAudioLoopSettings(s, for: display.channelID)
    }

    var body: some View {
        let settings = display.settings
        let st = display.status
        let id = display.channelID
        // ── Zeile 2: Aufnahme, Undo, Löschen, Länge ────────────────
        HStack(spacing: 4) {
            RecordButton(status: st, s: s) { engine.toggleAudioLoopRecording(track.data) }
                .help(tip(recordTip(st)))
            Button(s.loopUndoLabel) { engine.undoAudioLoopPassUndoable(id, actionName: s.undoLoopPass) }
                .buttonStyle(VintageSmallButtonStyle(isActive: false))
                .disabled(!st.canUndo)
                .help(tip(s.loopUndoTip))
            Button(s.loopClearLabel) { engine.clearAudioLoopUndoable(id, actionName: s.undoLoopClear) }
                .buttonStyle(VintageSmallButtonStyle(isActive: false, accent: .red))
                .disabled(!st.hasMaterial || !st.isQuiescent)
                .help(tip(s.loopClearTip))
            Spacer(minLength: 0)
            MenuKey(menu: {
                .of(AudioLoopSettings.barOptions.map { b in
                    ClosureMenuItem(title: s.songBars(b), checked: b == settings.bars) { update { $0.bars = b } }
                })
            }) {
                Text(s.songBars(settings.bars)).font(VintageTheme.monoSmall)
                    .foregroundColor(VintageTheme.textPrimary)
                    .padding(.horizontal, 4).padding(.vertical, 3)
            }
            .fixedSize()
            .disabled(st.hasMaterial)
            .help(tip(st.hasMaterial ? s.loopBarsLockedTip : s.loopBarsTip))
        }

        // ── Zeile 3: Eingang, Mithören, Gate ───────────────────────
        HStack(spacing: 4) {
            Button(s.loopInputChannel(settings.inputChannel, stereo: settings.stereo)) { showInput = true }
                .buttonStyle(VintageSmallButtonStyle(isActive: false))
                .help(tip(s.loopInputTip))
                .popover(isPresented: $showInput, arrowEdge: .bottom) {
                    LoopInputPopover(settings: settings, devices: rack.loops.devices,
                                     display: display, s: s, update: update,
                                     measure: { rack.measureLoopLatency(id) })
                }
            Button(s.loopMonLabel) { update { $0.monitor.toggle() } }
                .buttonStyle(VintageSmallButtonStyle(isActive: settings.monitor))
                .help(tip(s.loopMonitorTip))
            Button(settings.gate.position == .off ? s.loopGateLabel
                   : "\(s.loopGateLabel) \(s.gatePosition(settings.gate.position))") { showGate = true }
                .buttonStyle(VintageSmallButtonStyle(isActive: settings.gate.position != .off,
                                                     accent: Color(red: 0.3, green: 0.8, blue: 1.0)))
                .help(tip(s.loopGateTip))
                .popover(isPresented: $showGate, arrowEdge: .bottom) {
                    GatePopover(gate: settings.gate, s: s) { g in update { $0.gate = g } }
                }
            LoopDeviceLabel(devices: rack.loops.devices, s: s)
            Spacer(minLength: 0)
        }
    }

    private func recordTip(_ st: AudioLoopDisplay.Status) -> String {
        switch st.state {
        case .idle:      return st.requested ? s.loopArmedTip : s.loopRecTip
        case .armed:     return s.loopArmedTip
        case .recording: return s.loopRecordingTip
        case .finishing: return s.loopFinishingTip
        }
    }
}

/// Große Aufnahmetaste: grau (aus), orange blinkend (scharf), rot (nimmt auf), rot mit ENDE.
/// Blinkt nur, solange sie scharf ist oder endet — sonst ohne Zeitplan.
private struct RecordButton: View {
    let status: AudioLoopDisplay.Status
    let s: Str
    let action: () -> Void

    var body: some View {
        if status.armed || status.state == .finishing {
            TimelineView(.periodic(from: .now, by: 0.125)) { _ in
                face(blinkOn: Int(Date().timeIntervalSinceReferenceDate * 4) % 2 == 0)
            }
        } else {
            face(blinkOn: true)
        }
    }

    private func face(blinkOn: Bool) -> some View {
        let state = status.state
        let armed = status.armed
        let color: Color = state == .recording || state == .finishing ? .red
            : armed ? .orange : VintageTheme.textSecondary
        let lit = state == .recording || (state == .finishing && blinkOn) || (armed && blinkOn)
        return Button(action: action) {
            HStack(spacing: 4) {
                Circle().fill(lit ? color : color.opacity(0.35)).frame(width: 8, height: 8)
                Text(state == .finishing ? s.loopEndLabel : armed ? s.loopArmLabel : s.loopRecLabel)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(lit ? .white : VintageTheme.textPrimary)
            }
            .frame(width: 58, height: 22)
            .background(RoundedRectangle(cornerRadius: 4).fill(lit ? color.opacity(0.55) : Color.black.opacity(0.3)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.8), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Eingangspegel (v1.18.27, vorher nur LED): Balken −60…0 dBFS mit Abfall und Spitzenhalter,
/// grün, gelb ab −12 dB, rot ab −1 dB; Zahl = gehaltene Spitze. Fragt nur ab, solange der
/// Kanal den Eingang braucht (Mithören, scharf, Aufnahme) — sonst gedimmt.
private struct InputLevelMeter: View {
    let core: AudioLoopCore
    let active: Bool
    let s: Str
    @State private var ballistics = InputMeterBallistics()

    var body: some View {
        if active {
            TimelineView(.periodic(from: .now, by: 1.0 / 30)) { ctx in
                let r = ballistics.step(peak: core.takeInputPeak(), at: ctx.date.timeIntervalSinceReferenceDate)
                face(level: r.level, hold: r.hold)
            }
        } else {
            face(level: nil, hold: nil)
        }
    }

    private func face(level: Float?, hold: Float?) -> some View {
        HStack(spacing: 4) {
            Text("IN").font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(VintageTheme.textSecondary)
            Canvas { ctx, size in
                ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 2),
                         with: .color(Color.black.opacity(0.45)))
                guard let level else { return }
                let x = CGFloat(InputMeterBallistics.position(level)) * size.width
                let yellow = CGFloat(InputMeterBallistics.position(-12)) * size.width
                let red = CGFloat(InputMeterBallistics.position(-1)) * size.width
                func bar(_ from: CGFloat, _ to: CGFloat, _ c: Color) {
                    guard to > from else { return }
                    ctx.fill(Path(CGRect(x: from, y: 1, width: to - from, height: size.height - 2)), with: .color(c))
                }
                bar(0, min(x, yellow), .green)
                bar(yellow, min(x, red), .yellow)
                bar(red, x, .red)
                if let hold, hold > InputMeterBallistics.floor {
                    let hx = CGFloat(InputMeterBallistics.position(hold)) * size.width
                    ctx.fill(Path(CGRect(x: min(hx, size.width - 2), y: 0, width: 2, height: size.height)),
                             with: .color(hold > -1 ? .red : .white.opacity(0.85)))
                }
            }
            .frame(width: 120, height: 8)
            Text(hold.map { $0 > InputMeterBallistics.floor ? String(format: "%.0f", $0) : "-∞" } ?? "")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor((hold ?? -100) > -1 ? .red : VintageTheme.textSecondary)
                .frame(width: 22, alignment: .trailing)
        }
        .opacity(level == nil ? 0.4 : 1)
        .help(s.loopInputLevelTip)
    }
}

/// Anzeigeverhalten des Eingangspegels (Main, rein rechnerisch, testbar): sofortiger Anstieg,
/// Abfall 24 dB/s, Spitzenhalter 1,5 s.
final class InputMeterBallistics {
    static let floor: Float = -60
    private(set) var level: Float = floor
    private(set) var hold: Float = floor
    private var holdAt: Double = 0
    private var last: Double?

    static func db(_ peak: Float) -> Float { peak > 0 ? max(floor, 20 * log10(peak)) : floor }
    /// 0…1 auf der Skala −60…0 dBFS.
    static func position(_ db: Float) -> Float { max(0, min(1, (db - floor) / -floor)) }

    func step(peak: Float, at t: Double) -> (level: Float, hold: Float) {
        let dt = last.map { max(0, t - $0) } ?? 0
        last = t
        let d = Self.db(peak)
        level = max(d, level - Float(dt) * 24)
        if d >= hold || t - holdAt > 1.5 { hold = d; holdAt = t }
        return (level, hold)
    }
}

/// Gerät, von dem der Loop gerade aufnimmt (Spurkopf). Blatt: beobachtet nur die Geräte.
/// Läuft der Eingang nicht, steht dort „Eingang aus" statt des Systemstandards.
private struct LoopDeviceLabel: View {
    @ObservedObject var devices: AudioDeviceState
    let s: Str
    var body: some View {
        let i = devices.input
        let text = i.running ? (i.device ?? s.deviceUnknown) : s.deviceInputOffShort
        Text(text)
            .font(VintageTheme.monoSmall)
            .foregroundColor(i.differsFromDefault ? .orange : i.running ? VintageTheme.textPrimary : VintageTheme.textSecondary)
            .lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: 110, alignment: .leading)
            .help(s.deviceHeaderTip(input: text,
                                    output: devices.output.running ? (devices.output.device ?? s.deviceUnknown)
                                                                   : s.deviceOutputOff(defaultName: devices.output.systemDefault)))
    }
}

/// Ein- und Ausgang mit Gerät, Zustand und Format — klar getrennt (Eingangs-Popover).
private struct LoopDeviceSection: View {
    @ObservedObject var devices: AudioDeviceState
    let settings: AudioLoopSettings
    let s: Str

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            endpoint(devices.input, role: s.deviceInputRole, input: true)
            endpoint(devices.output, role: s.deviceOutputRole, input: false)
        }
    }

    private func endpoint(_ e: AudioDeviceState.Endpoint, role: String, input: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(role).font(VintageTheme.monoSmall).foregroundColor(VintageTheme.textSecondary)
            if e.running {
                HStack(spacing: 6) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text(e.device ?? s.deviceUnknown).font(VintageTheme.monoBold)
                        .foregroundColor(VintageTheme.textPrimary).lineLimit(1).truncationMode(.middle)
                }
                Text("\(s.deviceActive) · \(s.deviceFormat(channels: e.channels, sampleRate: e.sampleRate))")
                    .font(VintageTheme.monoSmall).foregroundColor(VintageTheme.textSecondary)
                if e.differsFromDefault {
                    Text(s.deviceDiffers(defaultName: e.systemDefault))
                        .font(VintageTheme.monoSmall).foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 6) {
                    Circle().stroke(VintageTheme.textSecondary, lineWidth: 1).frame(width: 7, height: 7)
                    Text(input ? s.deviceInputOff(defaultName: e.systemDefault)
                               : s.deviceOutputOff(defaultName: e.systemDefault))
                        .font(VintageTheme.monoSmall).foregroundColor(VintageTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let err = e.error {
                    Text(s.loopError(err)).font(VintageTheme.monoSmall).foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if input {
                Text(s.loopChannelSelection(settings.inputChannel, stereo: settings.stereo))
                    .font(VintageTheme.monoSmall).foregroundColor(VintageTheme.textAmber)
                let need = settings.inputChannel + (settings.stereo ? 2 : 1)
                if e.channels > 0, need > e.channels {
                    Text(s.loopChannelMissing(settings.inputChannel, stereo: settings.stereo, available: e.channels))
                        .font(VintageTheme.monoSmall).foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Popover

private struct LoopInputPopover: View {
    let settings: AudioLoopSettings
    @ObservedObject var devices: AudioDeviceState
    @ObservedObject var display: AudioLoopDisplay
    let s: Str
    let update: ((inout AudioLoopSettings) -> Void) -> Void
    let measure: () -> Void

    var body: some View {
        let count = max(devices.input.channels, 2)
        VStack(alignment: .leading, spacing: 10) {
            Text(s.loopInputHeader).font(VintageTheme.monoBold).foregroundColor(VintageTheme.textAmber)
            LoopDeviceSection(devices: devices, settings: settings, s: s)
            HStack(spacing: 4) {
                ForEach(0..<min(count, 16), id: \.self) { c in
                    Button("\(c + 1)") { update { $0.inputChannel = c } }
                        .buttonStyle(VintageSmallButtonStyle(isActive: settings.inputChannel == c))
                }
            }
            Toggle(s.loopStereo, isOn: Binding(get: { settings.stereo },
                                                set: { v in update { $0.stereo = v } }))
                .font(VintageTheme.monoSmall)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(s.loopLatency): \(Int(settings.latencyOffsetMs)) ms").font(VintageTheme.monoSmall)
                Slider(value: Binding(get: { Double(settings.latencyOffsetMs) },
                                      set: { v in update { $0.latencyOffsetMs = Float(v.rounded()) } }),
                       in: Double(AudioLoopSettings.latencyRange.lowerBound)...Double(AudioLoopSettings.latencyRange.upperBound))
                Text(s.loopLatencyHelp)
                    .font(VintageTheme.monoSmall).foregroundColor(VintageTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Loopback-Messung (T4/M1): Ausgang per Kabel auf den Eingang.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Button(s.loopMeasureLabel) { measure() }
                        .buttonStyle(VintageSmallButtonStyle(isActive: display.probe == .running))
                        .disabled(display.probe == .running)
                    switch display.probe {
                    case .idle: EmptyView()
                    case .running:
                        Text(s.loopMeasureRunning).font(VintageTheme.monoSmall).foregroundColor(VintageTheme.textAmber)
                    case .failed:
                        Text(s.loopMeasureFailed).font(VintageTheme.monoSmall).foregroundColor(.red)
                    case let .done(rt, off, clamped):
                        Text(s.loopMeasureResult(roundTripMs: rt, offsetMs: off, clamped: clamped))
                            .font(VintageTheme.monoSmall)
                            .foregroundColor(clamped ? .orange : VintageTheme.textPrimary)
                    }
                }
                Text(s.loopMeasureHelp)
                    .font(VintageTheme.monoSmall).foregroundColor(VintageTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { devices.refresh() }
        .background(VintageTheme.panelDark)
        .preferredColorScheme(.dark)
    }
}

private struct GatePopover: View {
    let gate: GateSettings
    let s: Str
    let set: (GateSettings) -> Void

    private func slider(_ title: String, _ value: Float, _ unit: String, _ range: ClosedRange<Float>,
                        _ apply: @escaping (inout GateSettings, Float) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title): \(Int(value)) \(unit)").font(VintageTheme.monoSmall)
            Slider(value: Binding(get: { Double(value) },
                                  set: { v in var g = gate; apply(&g, Float(v.rounded())); set(g) }),
                   in: Double(range.lowerBound)...Double(range.upperBound))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(s.gateHeader).font(VintageTheme.monoBold).foregroundColor(VintageTheme.textAmber)
            HStack(spacing: 4) {
                ForEach(GatePosition.allCases, id: \.self) { p in
                    Button(s.gatePosition(p)) { var g = gate; g.position = p; set(g) }
                        .buttonStyle(VintageSmallButtonStyle(isActive: gate.position == p,
                                                             accent: Color(red: 0.3, green: 0.8, blue: 1.0)))
                }
            }
            slider(s.gateThreshold, gate.thresholdDB, "dB", GateSettings.thresholdRange) { $0.thresholdDB = $1 }
            slider(s.gateRelease, gate.releaseMs, "ms", GateSettings.releaseRange) { $0.releaseMs = $1 }
            slider(s.gateHold, gate.holdMs, "ms", GateSettings.holdRange) { $0.holdMs = $1 }
            Text(s.gateHelp)
                .font(VintageTheme.monoSmall).foregroundColor(VintageTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320)
        .background(VintageTheme.panelDark)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Wellenform

private struct AudioLoopBody: View {
    @ObservedObject var display: AudioLoopDisplay
    var accentColor: Color
    @AppStorage("appLanguage") private var lang: String = "en"
    private var s: Str { Str(lang) }

    var body: some View {
        let st = display.status
        let bars = max(display.settings.bars, 1)
        let wave = display.wave
        ZStack {
            Canvas { ctx, size in
                // Taktlinien
                for b in 1..<max(bars, 2) where b < bars {
                    let x = size.width * CGFloat(b) / CGFloat(bars)
                    ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
                             with: .color(VintageTheme.textDim.opacity(0.4)))
                }
                // Wellenform, überhöht (v1.18.27): auf die Spitze normiert, leise Stellen angehoben
                if !wave.isEmpty {
                    let mid = size.height / 2
                    let w = size.width / CGFloat(wave.count)
                    let gain = WaveformScale.gain(for: wave)
                    var path = Path()
                    for (i, b) in wave.enumerated() {
                        let top = mid - WaveformScale.height(b.hi, gain: gain) * mid * 0.92
                        let bottom = mid - WaveformScale.height(b.lo, gain: gain) * mid * 0.92
                        path.addRect(CGRect(x: CGFloat(i) * w, y: top, width: max(1, w - 0.5),
                                            height: max(1, bottom - top)))
                    }
                    ctx.fill(path, with: .color(accentColor.opacity(0.75)))
                }
            }
            if st.playing, st.frames > 0 {
                LoopPlayhead(core: display.core, frames: st.frames)
            }
        }
        .overlay(alignment: .topTrailing) {
            InputLevelMeter(core: display.core, active: st.inputActive, s: s)
                .padding(.top, 2).padding(.trailing, 4)
        }
        .overlay(alignment: .leading) {
            if let err = display.error {
                Text(s.loopError(err)).font(VintageTheme.monoSmall).foregroundColor(.red).padding(8)
            } else if st.rateMismatch {
                Text(s.loopRateMismatch).font(VintageTheme.monoSmall).foregroundColor(.red).padding(8)
            } else if !st.hasMaterial {
                Text(s.loopEmptyHint).font(VintageTheme.monoSmall)
                    .foregroundColor(VintageTheme.textSecondary).padding(8)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }
}

/// Darstellung der Wellenform (nur Anzeige, Material unverändert): Normierung auf die lauteste
/// Stelle (höchstens +36 dB), danach Quadratwurzel — leise Anteile werden sichtbar, die Spitze
/// füllt die Höhe. Stille bleibt flach (unter −90 dBFS keine Anhebung).
enum WaveformScale {
    static let maxGain: Float = 64

    static func gain(for wave: [AudioLoopDisplay.WaveBucket]) -> Float {
        let peak = wave.reduce(Float(0)) { max($0, abs($1.hi), abs($1.lo)) }
        guard peak > 0.000_03 else { return 1 }
        return min(maxGain, 1 / peak)
    }

    /// Vorzeichenbehaftete Höhe −1…1.
    static func height(_ x: Float, gain: Float) -> CGFloat {
        let v = min(1, abs(x) * gain)
        return CGFloat((x < 0 ? -1 : 1) * v.squareRoot())
    }
}

/// Wiedergabeort — eigenes Blatt mit Bildtakt, nur solange der Kern spielt.
private struct LoopPlayhead: View {
    let core: AudioLoopCore
    let frames: Int
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            let play = core.playFrame
            Canvas { ctx, size in
                guard play >= 0 else { return }
                let x = size.width * CGFloat(play) / CGFloat(frames)
                ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)),
                         with: .color(VintageTheme.amberBright))
            }
        }
    }
}
