import SwiftUI

// MARK: - MixerDock

/// Mischpult am unteren Fensterrand, ein-/ausblendbar über die Transportleiste.
///
/// Kanalzüge nebeneinander (horizontal scrollbar), Summe fest ganz rechts. Aufbau und
/// Bedienung der Züge folgen Planarium (seit v1.13.5 Element für Element, vgl.
/// `MixerControls.swift`); die Flächen sind FoF-Materialbausteine (`VintageMaterials`).
///
/// **Beobachtung.** Das Dock beobachtet nur das `InstrumentRack`. Pegelanzeigen und
/// Regler im Zug sind Blatt-Views mit eigenem Zustand — sie invalidieren weder Züge noch Lanes.
struct MixerDock: View {
    // + Kanal-EQ-Bild (v1.18.11), damit der Fader nicht kürzer wird.
    static let minHeight: CGFloat = 340 + 34
    static let maxHeight: CGFloat = 420 + 34
    static let stripWidth: CGFloat = 72

    @EnvironmentObject private var engine: SequencerEngine
    @AppStorage("appLanguage") private var lang: String = "en"

    var body: some View {
        MixerContent(rack: engine.rack, s: Str(lang))
            .frame(minHeight: Self.minHeight, maxHeight: Self.maxHeight)
    }
}

private struct MixerContent: View {
    @ObservedObject var rack: InstrumentRack
    let s: Str
    @EnvironmentObject private var engine: SequencerEngine

    /// Einmal beim Einblenden gelesen — die Systemabfrage ist nicht billig.
    @State private var instruments: [InstrumentRack.ComponentInfo] = []
    @State private var effects:     [InstrumentRack.ComponentInfo] = []
    @State private var deleting: UUID?

    var body: some View {
        HStack(spacing: 0) {
            // ── Linke Leiste: Titel, Kanal hinzufügen ──────────────────────
            VStack(spacing: 8) {
                Button {
                    rack.addChannel(name: s.rackDefaultChannelName(rack.channels.count + 1))
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(VintageTheme.textAmber)
                        .frame(width: 24, height: 24)
                        .background(PlasticKeyBackground())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.fullArea)
                .disabled(!rack.canAddChannel)
                .help(s.rackAddChannelHelp)
                Text("MIXER")
                    .font(VintageTheme.monoSmall)
                    .foregroundColor(VintageTheme.textSecondary)
                    .rotationEffect(.degrees(-90))
                    .fixedSize()
                    .frame(width: 26, height: 52)
                Spacer()
            }
            .padding(.top, 10)
            .frame(width: 34)

            // ── Kanalzüge ──────────────────────────────────────────────────
            if rack.channels.isEmpty {
                Text(s.rackEmptyHint)
                    .font(VintageTheme.monoSmall)
                    .foregroundColor(VintageTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(Array(rack.channels.enumerated()), id: \.element.id) { i, ch in
                            ChannelStrip(rack: rack, channel: ch, number: i + 1, s: s,
                                         instruments: instruments, effects: effects,
                                         isHighlighted: rack.highlightedChannel == ch.id,
                                         onDelete: { requestDelete(ch.id) })
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // ── Summe ──────────────────────────────────────────────────────
            SumStrip(rack: rack, s: s)
        }
        .background(MetalSurface(tone: .darkMetal))
        .overlay(Rectangle().fill(Color.black.opacity(0.7)).frame(height: 1), alignment: .top)
        .onAppear {
            instruments = rack.availableInstruments()
            effects     = rack.availableEffects()
        }
        .alert(s.mixerDeleteTitle, isPresented: Binding(get: { deleting != nil },
                                                        set: { if !$0 { deleting = nil } })) {
            Button(s.cancel, role: .cancel) { deleting = nil }
            Button(s.rackRemoveChannel, role: .destructive) {
                if let id = deleting { rack.removeChannel(id) }
                deleting = nil
            }
        } message: {
            Text(s.mixerDeleteMessage(deleting.map(tracksPlaying) ?? 0))
        }
    }

    /// Spuren (über alle Patterns), die den Kanal spielen.
    private func tracksPlaying(_ id: UUID) -> Int {
        engine.patterns.reduce(0) { $0 + $1.tracks.filter { $0.instrumentID == id }.count }
    }

    /// Ohne Spuren auf dem Kanal wird sofort gelöscht, sonst erst nach Rückfrage.
    private func requestDelete(_ id: UUID) {
        if tracksPlaying(id) == 0 { rack.removeChannel(id) } else { deleting = id }
    }
}

// MARK: - Gemeinsames Raster

/// Eine senkrechte Schiene für alle Züge und die Summe: Platzbereich oben, darunter
/// Pan · dB · Fader/Meter · Taster · Nummer · Name. Nur der Fader gibt bei wenig Höhe nach.
private enum StripRail {
    static let spacing: CGFloat = 4
    static let slotSpacing: CGFloat = 3
    static let slotAreaHeight = MixerSlotRow.height * 5 + slotSpacing * 4
    static let eqHeight = ChannelEQThumbnail.height
    static let panHeight: CGFloat = 32
    static let levelHeight: CGFloat = 18
    static let faderMin: CGFloat = 80
    static let faderMax: CGFloat = 150
    static let actionsHeight: CGFloat = 22
    static let numberHeight: CGFloat = 10
    static let nameHeight: CGFloat = 22
}

// MARK: - ChannelStrip

private struct ChannelStrip: View {
    let rack: InstrumentRack
    let channel: InstrumentChannelData
    let number: Int
    let s: Str
    let instruments: [InstrumentRack.ComponentInfo]
    let effects:     [InstrumentRack.ComponentInfo]
    let isHighlighted: Bool
    let onDelete: () -> Void

    @EnvironmentObject private var engine: SequencerEngine
    @State private var isRenaming = false

    private var instrumentStatus: InstrumentRack.SlotStatus { rack.instrumentStatus[channel.id] ?? .empty }

    var body: some View {
        VStack(spacing: StripRail.spacing) {
            // ── Plätze: Instrument, vier Inserts in Signalfolge ────────────
            VStack(spacing: StripRail.slotSpacing) {
                if channel.audioLoop != nil {
                    // Audio-Loop-Kanal (v1.15.0): Quelle ist der Loop, keine Instrumentwahl.
                    MixerSlotRow(title: s.mixerAudioLoopSource, tint: .red, isOn: true,
                                 canToggle: false, canOpen: false, toggle: {}, open: {},
                                 choices: [], s: s)
                } else {
                MixerSlotRow(title: Self.title(channel.instrument?.name, instrumentStatus)
                                    + (channel.renderRate.map { " · " + s.kHz($0) } ?? ""),
                             tint: MixerChrome.purple,
                             isOn: instrumentStatus == .ready && channel.instrument?.bypassed == false,
                             canToggle: instrumentStatus == .ready,
                             canOpen: instrumentStatus == .ready,
                             toggle: { rack.setInstrumentEnabled(channel.instrument?.bypassed ?? false, for: channel.id) },
                             open: { rack.openInstrumentEditor(channel.id) },
                             choices: instrumentChoices, s: s)
                }
                ForEach(0..<InstrumentRack.maxEffectsPerChannel, id: \.self) { i in
                    let fx = channel.effects.indices.contains(i) ? channel.effects[i] : nil
                    let status = effectStatus(i)
                    MixerSlotRow(title: Self.title(fx?.name, status),
                                 tint: MixerChrome.blue,
                                 isOn: status == .ready && fx?.bypassed == false,
                                 canToggle: status == .ready,
                                 canOpen: status == .ready,
                                 toggle: { if let fx { rack.setEffectBypassed(!fx.bypassed, at: i, in: channel.id) } },
                                 open: { rack.openEffectEditor(channel.id, index: i) },
                                 choices: effectChoices(slot: i, current: fx, status: status), s: s)
                }
            }
            .frame(height: StripRail.slotAreaHeight, alignment: .top)

            // ── Kanal-EQ (v1.18.11) ────────────────────────────────────────
            ChannelEQThumbnail(rack: rack, channelID: channel.id, eq: channel.eq, s: s)
                .frame(height: StripRail.eqHeight)

            // ── Panorama ───────────────────────────────────────────────────
            MixerPanKnob(pan: Double(channel.pan), setPan: { rack.setPan(channel.id, Float($0)) },
                         diameter: StripRail.panHeight, s: s)
                .frame(height: StripRail.panHeight)

            // ── Pegel in dB ────────────────────────────────────────────────
            LevelLabel(position: level.wrappedValue)

            // ── Skala · Fader · Pegelanzeige ───────────────────────────────
            HStack(alignment: .bottom, spacing: 1) {
                MixerFaderScale().frame(width: 16)
                MixerFader(value: level, label: s.rackVolume, help: s.mixerFaderHelp).frame(width: 18)
                if let meter = rack.meter(for: channel.id) {
                    MixerStereoMeter(meter: meter, running: rack.isAudioRunning, s: s).frame(width: 26)
                }
            }
            .frame(minHeight: StripRail.faderMin, maxHeight: StripRail.faderMax)

            // ── Mute · Solo ────────────────────────────────────────────────
            HStack(spacing: 4) {
                MixerChannelButton(symbol: "speaker.slash", isOn: channel.isMuted, activeColor: .orange,
                                   label: "Mute", help: s.rackMuteHelp) {
                    rack.setMuted(channel.id, !channel.isMuted)
                }
                MixerChannelButton(symbol: "headphones", isOn: channel.isSoloed, activeColor: .yellow,
                                   label: "Solo", help: s.mixerSoloHelp) {
                    rack.setSoloed(channel.id, !channel.isSoloed)
                }
            }
            .frame(height: StripRail.actionsHeight)
            .padding(.top, 4)

            // ── Nummer · Name ──────────────────────────────────────────────
            Text(String(format: "%02d", number))
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundColor(Mat.inkOnLightSecondary)
                .frame(height: StripRail.numberHeight)
            nameField
        }
        .padding(.horizontal, 5)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(width: MixerDock.stripWidth)
        .background(MetalSurface(tone: .lightAluminium))
        .overlay(Rectangle().stroke(isHighlighted ? Color.orange : Color.black.opacity(0.35),
                                    lineWidth: isHighlighted ? 2 : 0.5))
        .contextMenu {
            if channel.audioLoop == nil {
                // Abtastrate des Instruments (v1.18.9): ein Sampler, der selbst grob umrechnet,
                // rendert so auf der Rate seiner Samples; die Engine rechnet sauber um.
                Menu(s.renderRateMenu) {
                    Button((channel.renderRate == nil ? "✓ " : "   ")
                           + s.renderRateDevice(rack.outputSampleRate)) { rack.setRenderRate(nil, for: channel.id) }
                    ForEach(InstrumentChannelData.renderRates, id: \.self) { r in
                        Button((channel.renderRate == r ? "✓ " : "   ") + s.kHz(r)) { rack.setRenderRate(r, for: channel.id) }
                    }
                }
            }
            if AppleSampler.isSampler(channel.instrument) {
                Button(s.samplerLoad) { SamplerPanels.chooseAndLoad(channel: channel.id, rack: rack, s: s) }
            }
            Button(s.samplerGrantFolders) { SamplerPanels.grantFolder(suggesting: nil, s: s) }
            Button(s.mixerRename) { isRenaming = true }
            Button(s.mixerDuplicateChannel) { rack.duplicateChannel(channel.id, name: channel.name + " 2") }
                .disabled(!rack.canAddChannel)
            Button(s.rackRemoveChannel) { onDelete() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(s.mixerChannel) \(number): \(channel.name)")
    }

    // Name auf Glas, darunter die Farben der Spuren, die den Kanal spielen.
    // Doppelklick benennt um; das Kontextmenü des Zugs ebenso.
    private var nameField: some View {
        Group {
            if isRenaming {
                RenameEntryField(initial: channel.name,
                                 commit: { rack.rename(channel.id, to: $0) },
                                 end: { isRenaming = false })
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
            } else {
                Text(channel.name).lineLimit(1).frame(maxWidth: .infinity)
            }
        }
        .font(.system(size: MixerChrome.labelSize, weight: .semibold))
        .foregroundColor(.white)
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity)
        .frame(height: StripRail.nameHeight)
        .background(GlassDisplayBackground(cornerRadius: 3))
        .overlay(alignment: .bottom) {
            HStack(spacing: 0) {
                ForEach(engine.currentPattern.tracks, id: \.id) { td in
                    RoutedTrackColor(track: engine.viewModel(for: td), channelID: channel.id)
                }
            }
            .frame(height: 2)
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { isRenaming = true }
        .help(s.mixerNameHelp)
    }

    private var level: Binding<Double> {
        Binding(get: { FaderLaw.position(forGain: Double(channel.volume)) },
                set: { rack.setVolume(channel.id, Float(FaderLaw.gain(forPosition: $0))) })
    }

    private func effectStatus(_ i: Int) -> InstrumentRack.SlotStatus {
        guard channel.effects.indices.contains(i) else { return .empty }
        return rack.effectStatus[channel.id].flatMap { $0.indices.contains(i) ? $0[i] : nil } ?? .loading
    }

    /// „—" leer, „Name …" lädt, „Name !" nicht ladbar.
    private static func title(_ name: String?, _ status: InstrumentRack.SlotStatus) -> String {
        guard let name else { return "—" }
        switch status {
        case .loading: return name + " …"
        case .missing: return name + " !"
        case .ready, .empty: return name
        }
    }

    private var instrumentChoices: [MixerSlotChoice] {
        let current = channel.instrument
        let installed = current.map { c in instruments.contains { $0.ref.isSameComponent(as: c) } } ?? true
        var out: [MixerSlotChoice] = []
        if let current, !installed {
            out.append(.init(id: "unavailable", title: s.mixerUnavailable(current.name), selected: true, action: {}))
        }
        out.append(.init(id: "empty", title: s.mixerEmpty, selected: current == nil) {
            rack.setInstrument(nil, for: channel.id)
        })
        // Apple Sampler mit Instrumentdatei (v1.18.16).
        out.append(.init(id: "apple-sampler-load", title: s.samplerLoad, selected: false) { [rack, channel, s] in
            SamplerPanels.chooseAndLoad(channel: channel.id, rack: rack, s: s)
        })
        out += instruments.map { info in
            .init(id: info.id, title: "\(info.manufacturer) · \(info.ref.name)",
                  selected: current.map { info.ref.isSameComponent(as: $0) } ?? false) {
                rack.setInstrument(info.ref, for: channel.id)
                rack.openInstrumentEditorWhenLoaded(channel.id)
            }
        }
        return out
    }

    private func effectChoices(slot: Int, current: PluginRef?, status: InstrumentRack.SlotStatus) -> [MixerSlotChoice] {
        let installed = current.map { c in effects.contains { $0.ref.isSameComponent(as: c) } } ?? true
        var out: [MixerSlotChoice] = []
        if let current, !installed {
            out.append(.init(id: "unavailable-\(slot)", title: s.mixerUnavailable(current.name), selected: true, action: {}))
        }
        out.append(.init(id: "empty-\(slot)", title: s.mixerEmpty, selected: current == nil) {
            rack.assignEffect(nil, at: slot, in: channel.id)
        })
        out += effects.map { info in
            .init(id: "\(slot)-\(info.id)", title: "\(info.manufacturer) · \(info.ref.name)",
                  selected: current.map { info.ref.isSameComponent(as: $0) } ?? false) {
                rack.assignEffect(info.ref, at: slot, in: channel.id)
            }
        }
        return out
    }
}

/// dB-Anzeige des Faders auf Glas.
private struct LevelLabel: View {
    let position: Double
    var body: some View {
        Text(FaderLaw.decibelLabel(forPosition: position))
            .font(.system(size: MixerChrome.labelSize, weight: .semibold).monospacedDigit())
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: StripRail.levelHeight)
            .background(GlassDisplayBackground(cornerRadius: 3))
    }
}

/// Farbsegment einer Spur unter dem Kanalnamen, wenn sie diesen Kanal spielt. Beobachtet das
/// TrackViewModel, damit die Anzeige einer Routing-Änderung (auch per Undo) folgt.
private struct RoutedTrackColor: View {
    @ObservedObject var track: TrackViewModel
    let channelID: UUID
    var body: some View {
        if track.instrumentID == channelID {
            VintageTheme.color(for: track.data)
        }
    }
}

// MARK: - SumStrip

private struct SumStrip: View {
    @ObservedObject var rack: InstrumentRack
    let s: Str
    @EnvironmentObject private var engine: SequencerEngine

    private var level: Binding<Double> {
        Binding(get: { FaderLaw.position(forGain: Double(rack.masterVolume)) },
                set: { rack.setMasterVolume(Float(FaderLaw.gain(forPosition: $0))) })
    }

    var body: some View {
        VStack(spacing: StripRail.spacing) {
            VStack(spacing: 6) {
                Text(s.mixerSum)
                    .font(.system(size: MixerChrome.labelSize, weight: .semibold))
                    .foregroundColor(Mat.inkOnLight)
                if rack.engineError != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                        .help(s.rackEngineError(rack.engineError ?? ""))
                }
            }
            .frame(height: StripRail.slotAreaHeight, alignment: .top)

            Color.clear.frame(height: StripRail.eqHeight)     // Höhe des Kanal-EQ der Züge
            Color.clear.frame(height: StripRail.panHeight)
            LevelLabel(position: level.wrappedValue)

            HStack(alignment: .bottom, spacing: 3) {
                MixerFader(value: level, label: s.mixerSum, help: s.mixerFaderHelp).frame(width: 27)
                MixerStereoMeter(meter: rack.masterMeter, running: rack.isAudioRunning, s: s).frame(width: 26)
            }
            .frame(minHeight: StripRail.faderMin, maxHeight: StripRail.faderMax)

            // PANIC an der Stelle von Mute/Solo: beendet alle Noten, intern und extern.
            Button { engine.panic() } label: {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: StripRail.actionsHeight)
                    .background(PlasticKeyBackground(tint: .red, tintStrength: 0.85, cornerRadius: 3))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.fullArea)
            .padding(.top, 4)
            .help(s.mixerPanicHelp)
            .accessibilityLabel("PANIC")

            Color.clear.frame(height: StripRail.numberHeight)
            Text("Master")
                .font(.system(size: MixerChrome.labelSize))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: StripRail.nameHeight)
                .background(GlassDisplayBackground(cornerRadius: 3))
        }
        .padding(.horizontal, 5)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(width: MixerDock.stripWidth)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .background(MetalSurface(tone: .lightAluminium))
        .overlay(Rectangle().stroke(Color.black.opacity(0.35), lineWidth: 0.5))
    }
}
