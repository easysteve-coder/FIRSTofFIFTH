import SwiftUI
import CoreMIDI

struct SettingsView: View {
    @EnvironmentObject var engine: SequencerEngine
    @EnvironmentObject private var midi: MIDIManager
    @EnvironmentObject private var mls: MIDILearnState
    @EnvironmentObject private var ts: TransportState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var lang: String = "en"
    private var s: Str { Str(lang) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ──────────────────────────────────────────────────
            HStack {
                Text(s.settingsTitle)
                    .font(VintageTheme.monoTitle)
                    .foregroundColor(VintageTheme.textAmber)
                Spacer()
                Button(s.close) { dismiss() }
                    .buttonStyle(VintageSmallButtonStyle(isActive: false, accent: VintageTheme.amber))
            }
            .padding(16)
            .background(VintageTheme.panelDark)

            Rectangle().fill(VintageTheme.panelBorder).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // ── Tracks ───────────────────────────────────────────
                    SectionLabel(s.settingsTracks)
                    Text(s.settingsTracksHint)
                        .font(VintageTheme.monoSmall)
                        .foregroundColor(VintageTheme.textSecondary)

                    settingsDivider

                    // ── MIDI Output ──────────────────────────────────────
                    SectionLabel(s.settingsMIDIOutput)
                    HStack {
                        SettingsLabel(s.settingsDevice)
                        Picker("", selection: $midi.selectedOutput) {
                            Text(s.settingsNone).tag(MIDIEndpointRef(0))
                            ForEach(midi.outputs, id: \.ref) { out in
                                Text(out.name).tag(out.ref)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 220)
                    }

                    settingsDivider

                    // ── Clock-Quelle (v1.13.10: aus der Transportleiste hierher) ──
                    SectionLabel(s.settingsClock)
                    HStack {
                        SettingsLabel(s.settingsClockSource)
                        ForEach(ClockMode.allCases, id: \.self) { mode in
                            Button(mode.rawValue) { engine.setClockMode(mode) }
                                .buttonStyle(VintageSmallButtonStyle(
                                    isActive: ts.clockMode == mode,
                                    accent: mode == .external
                                        ? Color(red: 0.2, green: 0.8, blue: 1.0)
                                        : VintageTheme.amber))
                                .help(mode == .external ? s.extClockTooltip : s.intClockTooltip)
                        }
                    }

                    settingsDivider

                    // ── MIDI Input (Clock) ───────────────────────────────
                    SectionLabel(s.settingsMIDIInput)
                    HStack {
                        SettingsLabel(s.settingsSource)
                        Picker("", selection: $midi.selectedInput) {
                            Text(s.settingsNone).tag(MIDIEndpointRef(0))
                            ForEach(midi.inputs, id: \.ref) { src in
                                Text(src.name).tag(src.ref)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 220)
                        .onValueChange(of: midi.selectedInput) { ep in
                            midi.connectInput(ep)
                        }
                    }

                    Button(s.settingsRefreshPorts) { midi.refreshPorts() }
                        .buttonStyle(VintageSmallButtonStyle(isActive: false,
                                                             accent: VintageTheme.amber))

                    settingsDivider

                    // ── CC Remote Control ────────────────────────────────
                    SectionLabel(s.settingsCCRemote)
                    HStack(spacing: 12) {
                        SettingsLabel(s.settingsPatternCC)
                        Stepper(mls.patternSwitchCC < 0 ? "Off" : "\(mls.patternSwitchCC)",
                                value: $mls.patternSwitchCC, in: -1...127)
                            .font(VintageTheme.monoMedium)
                            .foregroundColor(VintageTheme.textPrimary)
                    }
                    Text(s.settingsPatternCCHint)
                        .font(VintageTheme.monoSmall)
                        .foregroundColor(VintageTheme.textSecondary)

                    ForEach(engine.currentPattern.tracks.indices, id: \.self) { i in
                        HStack(spacing: 12) {
                            SettingsLabel(s.settingsMuteCC(i + 1))
                            Stepper(i < mls.trackMuteCCs.count && mls.trackMuteCCs[i] >= 0
                                        ? "\(mls.trackMuteCCs[i])" : s.settingsOff,
                                    value: Binding(
                                        get: { i < mls.trackMuteCCs.count ? mls.trackMuteCCs[i] : -1 },
                                        set: { v in if i < mls.trackMuteCCs.count { mls.trackMuteCCs[i] = v } }),
                                    in: -1...127)
                                .font(VintageTheme.monoMedium)
                                .foregroundColor(VintageTheme.textPrimary)
                        }
                    }

                }
                .padding(16)
            }
        }
        .background(VintageTheme.background)
        .frame(width: 500, height: 720)
        .preferredColorScheme(.dark)
    }

    // MARK: - Helpers

    private var settingsDivider: some View {
        Rectangle().fill(VintageTheme.panelBorder).frame(height: 1)
    }

}

// MARK: - Small helpers

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(VintageTheme.monoBold)
            .foregroundColor(VintageTheme.textAmber)
    }
}

private struct SettingsLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(VintageTheme.monoMedium)
            .foregroundColor(VintageTheme.textPrimary)
    }
}
