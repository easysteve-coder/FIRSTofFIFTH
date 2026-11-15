import SwiftUI
import AppKit
import Combine

// MARK: - Track header (left panel)

struct TrackHeaderView: View {
    @ObservedObject var track: TrackViewModel
    var accentColor:   Color
    var onRandomize:   (() -> Void)?
    var onClear:       (() -> Void)?
    var onDelete:      (() -> Void)?

    @Environment(\.undoManager) private var undoManager
    /// Nur für die Ausgangsanzeige (Rack-Kanal der Spur). Die Engine publiziert nur bei
    /// Struktur-/Transport-Ereignissen — der Spurkopf wird dadurch nicht häufiger neu gebaut.
    @EnvironmentObject private var engine: SequencerEngine
    @State private var showScalePicker = false
    @State private var showFeelPopover = false
    @State private var showPadWidth    = false
    // Namensfeld: `TrackNameField` (gemeinsam für alle Spurarten, v1.17.3).
    private let writer = ModelWriter()

    @AppStorage("showTooltips") private var showTooltips: Bool   = true
    @AppStorage("appLanguage")  private var lang:         String = "en"
    private var s: Str { Str(lang) }
    private func tip(_ text: String) -> String { showTooltips ? text : "" }

    private func directionTooltip(_ dir: PlayDirection) -> String {
        switch dir {
        case .forward:  return s.forwardDirTip
        case .reverse:  return s.reverseDirTip
        case .pingPong: return s.pingPongDirTip
        case .random:   return s.randomDirTip
        }
    }

    private func directionSymbol(_ dir: PlayDirection) -> String {
        switch dir {
        case .forward:  return "play.fill"
        case .reverse:  return "backward.end.fill"
        case .pingPong: return "arrow.left.arrow.right"
        case .random:   return "waveform"
        }
    }

    var body: some View {
        #if DEBUG
        let _ = BodyRunCounter.shared.count("TrackHeader")
        #endif
        VStack(alignment: .leading, spacing: 5) {

            // ── Row 1: ● Name  ·  m · s · ⎘ ─────────────────────────────
            HStack(spacing: 4) {
                if onDelete != nil {
                    Spacer().frame(width: 14)
                }

                // Anzeige-Only (v1.12.1): Der Farbpunkt ist rein visuell und
                // nicht mehr interaktiv. Farbwahl läuft über das
                // Track-Kontextmenü (siehe TrackRowView.trackContextMenu).
                Circle().fill(accentColor).frame(width: 6, height: 6)

                TrackNameField(track: track, accentColor: accentColor, placeholder: s.namePlaceholder)

                if track.lane.isLongStep {
                    // Breite langer Steps dieser Spur (v1.13.19 Pads, v1.18.29 jede Spur).
                    Button("↔\(track.lane.stepWidth == 0 ? "A" : "\(track.lane.stepWidth)")") { showPadWidth = true }
                        .buttonStyle(VintageSmallButtonStyle(isActive: false, accent: accentColor))
                        .popover(isPresented: $showPadWidth, arrowEdge: .bottom) {
                            PadWidthPopover(track: track, accentColor: accentColor)
                        }
                        .help(tip(s.padWidthHelp))
                }

                TrackMuteSoloButtons(track: track, s: s, tip: tip)
            }

            // ── Row 2: Direction buttons (symbols) · CH ───────────────────
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(PlayDirection.allCases, id: \.self) { dir in
                        let isActive = track.lane.direction == dir
                        Button {
                            writer.apply(.setDirection(trackID: track.id,
                                                        old: track.lane.direction,
                                                        new: dir),
                                         to: track.data, undoManager: nil)
                        } label: {
                            Image(systemName: directionSymbol(dir))
                                .font(.system(size: 10, weight: isActive ? .bold : .regular))
                                .frame(width: 28, height: 22)
                                .foregroundColor(isActive ? .black : VintageTheme.textPrimary)
                                .background(PlasticSegmentBackground(isActive: isActive, accent: accentColor))
                        }
                        .buttonStyle(.fullArea)
                        .help(tip(directionTooltip(dir)))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(accentColor.opacity(0.4), lineWidth: 1))

                Spacer()

                // Ausgangswahl (v1.18.33): ein Menü für externes MIDI mit Kanal und die
                // Instrumentenkanäle. Der MIDI-Kanal gilt nur für externes MIDI. Eigene
                // Blatt-View: nur sie folgt der Kanalliste des Racks.
                TrackOutputMenu(track: track, directory: engine.rack.directory,
                                accent: accentColor, s: s)
            }

            // ── Row 3: FEEL · SCL  ·  RND · CLR ──────────────────────────
            HStack(spacing: 4) {
                let ms = Int(track.timingOffset * 1000)
                Button {
                    showFeelPopover = true
                } label: {
                    Text(ms == 0 ? "FEEL" : (ms > 0 ? "+\(ms)ms" : "\(ms)ms"))
                        .font(VintageTheme.monoSmall)
                }
                .buttonStyle(VintageSmallButtonStyle(isActive: ms != 0, accent: accentColor))
                .popover(isPresented: $showFeelPopover, arrowEdge: .bottom) {
                    FeelPopover(track: track, accentColor: accentColor)
                }
                .help(tip(s.feelTooltip))

                let scaleActive = track.scaleIndex > 0
                Button(scaleActive
                    ? "\(TrackData.noteNames[track.scaleRoot]) \(TrackData.scales[track.scaleIndex].shortName)"
                    : "SCL") {
                    showScalePicker = true
                }
                .buttonStyle(VintageSmallButtonStyle(isActive: scaleActive, accent: accentColor))
                .popover(isPresented: $showScalePicker, arrowEdge: .bottom) {
                    ScalePickerPopover(track: track, accentColor: accentColor)
                }
                .help(tip(s.scaleTooltip))

                Spacer()

                // RND/CLR laufen über ModelWriter (engine.randomize bzw. onClear) und
                // registrieren ihr Undo dort — keine Direktmutation aus der View.
                // RND; daneben (außer Drum-Spuren) die RND-Wahl ▾: Einzeltöne/Akkorde/gemischt
                // und Akkordquelle (v1.16.2: auch normale Spuren).
                Button("RND") { onRandomize?() }
                .buttonStyle(VintageSmallButtonStyle(isActive: false, accent: accentColor))
                .help(tip(track.lane.isLongStep ? s.padRandomizeTooltip : s.randomizeTooltip))
                if !track.isDrum {
                    MenuKey(menu: { PadChordMenu.make(s: s, german: lang == "de", mode: track.lane.rndMode ?? .single,
                                                      setMode: { m in
                                                          writer.apply(.setRndMode(trackID: track.id, old: track.lane.rndMode,
                                                                                   new: m == .single ? nil : m),
                                                                       to: track.data, undoManager: undoManager)
                                                      }) { onRandomize?() } }) {
                        Text("▾")
                            .font(VintageTheme.monoSmall)
                            .foregroundColor(VintageTheme.textPrimary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(PlasticKeyBackground(tint: nil, tintStrength: 0.3,
                                                             cornerRadius: 3, pressed: false))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    .fixedSize()
                    .help(tip(s.padChordSourceTooltip))
                }

                Button("CLR") { onClear?() }
                .buttonStyle(VintageSmallButtonStyle(isActive: false, accent: .red))
                .help(tip(s.clearTooltip))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxHeight: .infinity)
        // Traffic-light delete button — overlay top-left
        .overlay(alignment: .topLeading) {
            if let onDelete {
                Button(action: onDelete) {
                    Text("×")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(VintageTheme.textSecondary)
                }
                .buttonStyle(.fullArea)
                .padding(.top, 9)
                .padding(.leading, 8)
                .help(tip(s.deleteTooltip))
            }
        }
    }
}

// MARK: - Feel popover

fileprivate struct FeelPopover: View {
    @ObservedObject var track: TrackViewModel
    var accentColor: Color
    @AppStorage("appLanguage") private var lang: String = "en"
    private var s: Str { Str(lang) }
    private let writer = ModelWriter()

    var body: some View {
        VStack(spacing: 10) {
            Text(s.feelHeader)
                .font(VintageTheme.monoBold)
                .foregroundColor(VintageTheme.textAmber)
            KnobView(
                label: "ms",
                value: Binding(
                    get: { track.timingOffset * 1000 },
                    set: { writer.apply(.setTimingOffset(trackID: track.id,
                                                          old: track.timingOffset,
                                                          new: max(-TrackData.maxTimingOffset, min(TrackData.maxTimingOffset, $0 / 1000))),
                                        to: track.data, undoManager: nil) }
                ),
                range: -50...50,
                size: 64,
                accentColor: accentColor
            )
            HStack(spacing: 6) {
                Text(s.pushed)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(VintageTheme.textSecondary)
                Spacer()
                Text(s.laidBack)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(VintageTheme.textSecondary)
            }
            Button(s.feelReset) {
                writer.apply(.setTimingOffset(trackID: track.id,
                                               old: track.timingOffset,
                                               new: 0),
                             to: track.data, undoManager: nil)
            }
            .buttonStyle(VintageSmallButtonStyle(isActive: false, accent: .gray))
        }
        .padding(14)
        .background(VintageTheme.panelDark)
        .frame(width: 140)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Scale picker popover

fileprivate struct ScalePickerPopover: View {
    @ObservedObject var track: TrackViewModel
    var accentColor: Color
    @AppStorage("appLanguage") private var lang: String = "en"
    private var s: Str { Str(lang) }
    private let rootNames = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
    private let writer = ModelWriter()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(s.scaleHeader)
                .font(VintageTheme.monoBold)
                .foregroundColor(VintageTheme.textAmber)

            VStack(alignment: .leading, spacing: 4) {
                Text(s.rootNote).font(VintageTheme.monoSmall).foregroundColor(VintageTheme.textSecondary)
                HStack(spacing: 3) {
                    ForEach(0..<12, id: \.self) { i in
                        Button(rootNames[i]) {
                            writer.apply(.setScaleRoot(trackID: track.id,
                                                        old: track.scaleRoot,
                                                        new: i),
                                         to: track.data, undoManager: nil)
                        }
                        .buttonStyle(VintageSmallButtonStyle(
                            isActive: track.scaleRoot == i, accent: accentColor))
                        .opacity(rootNames[i].contains("#") ? 0.75 : 1.0)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(s.modeLabel).font(VintageTheme.monoSmall).foregroundColor(VintageTheme.textSecondary)
                let cols = [GridItem(.adaptive(minimum: 90))]
                LazyVGrid(columns: cols, alignment: .leading, spacing: 4) {
                    ForEach(TrackData.scales.indices, id: \.self) { i in
                        Button(TrackData.scales[i].name) {
                            writer.apply(.setScaleIndex(trackID: track.id,
                                                         old: track.scaleIndex,
                                                         new: i),
                                         to: track.data, undoManager: nil)
                        }
                        .buttonStyle(VintageSmallButtonStyle(
                            isActive: track.scaleIndex == i, accent: accentColor))
                    }
                }
            }
        }
        .padding(14)
        .background(VintageTheme.panelDark)
        .frame(width: 300)
        .preferredColorScheme(.dark)
    }
}

// MARK: - TrackOutputMenu

/// Einträge der Ausgangswahl (Externes MIDI + Instrumentenkanäle), aktueller Ausgang mit
/// Häkchen. Gemeinsam für Spurkopf und Spur-Kontextmenü. Eine ID ohne vorhandenen Kanal
/// gilt als externe MIDI-Ausgabe.
struct TrackOutputItems: View {
    @ObservedObject var track: TrackViewModel
    @ObservedObject var directory: ChannelDirectory
    let s: Str
    @EnvironmentObject private var engine: SequencerEngine
    @AppStorage("showMixer") private var showMixer: Bool = false

    var body: some View {
        let current = directory.entries.first { $0.id == track.instrumentID }?.id
        // Audio-Loop-Spuren spielen nur Audio-Loop-Kanäle, alle anderen nur Instrumentenkanäle.
        let loop = track.data.isAudioLoop
        let entries = directory.entries.filter { $0.isAudioLoop == loop }
        if !loop {
            // Externes MIDI ▸ Kanal 01 … 16 (v1.18.33): Ausgang und Kanal in einem Schritt.
            Menu {
                ForEach(1...16, id: \.self) { ch in
                    Button { engine.setMIDIOutput(of: track.data, channel: ch) } label: {
                        if current == nil && track.midiChannel == ch {
                            Label(s.trackOutputChannel(ch), systemImage: "checkmark")
                        } else { Text(s.trackOutputChannel(ch)) }
                    }
                }
            } label: {
                if current == nil { Label(s.trackOutputMIDI, systemImage: "checkmark") } else { Text(s.trackOutputMIDI) }
            }
        }
        if !entries.isEmpty && !loop { Divider() }
        ForEach(entries) { item($0.id, $0.name, current) }
        if !loop { Divider() }
        if !loop {
        // Legt einen Kanal an, weist ihn zu und zeigt den Mixer: dort wird das Instrument gewählt.
        Button {
            let name = s.rackDefaultChannelName(engine.rack.channels.count + 1)
            if engine.setOutputToNewChannel(of: track.data, name: name) != nil { showMixer = true }
        } label: {
            Label(s.trackOutputNewChannel, systemImage: "plus")
        }
        .disabled(!engine.rack.canAddChannel)
        }
    }

    @ViewBuilder
    private func item(_ id: UUID?, _ title: String, _ current: UUID?) -> some View {
        Button { engine.setOutput(of: track.data, to: id) } label: {
            if current == id { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}

/// Ausgangstaste im Spurkopf: zeigt „MIDI 05“ bzw. den Namen des Instrumentenkanals und
/// öffnet die Ausgangswahl (v1.18.33: der MIDI-Kanal steckt im Untermenü „Externes MIDI“,
/// die eigene Kanalwahl daneben entfällt).
///
/// Klickfläche ist die ganze Taste (v1.16.2): ein Button mit `.fullArea` öffnet beim Klick ein
/// AppKit-Menü — wie `CCTargetButton`. Ein SwiftUI-`Menu` (borderless) reagiert nur auf die
/// Fläche seines Titels, auch mit größerem transparentem Label darüber.
struct TrackOutputMenu: View {
    @ObservedObject var track: TrackViewModel
    @ObservedObject var directory: ChannelDirectory
    let accent: Color
    let s: Str
    @EnvironmentObject private var engine: SequencerEngine
    @AppStorage("showMixer") private var showMixer: Bool = false

    var body: some View {
        let routed = directory.entries.first { $0.id == track.instrumentID }
        let ch = track.midiChannel
        Button { showMenu() } label: {
            HStack(spacing: 3) {
                Text(routed?.name ?? "MIDI \(String(format: "%02d", ch))\(ch == 10 ? " ◆" : "")")
                    .font(VintageTheme.monoSmall)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 6, weight: .bold))
            }
            .padding(.horizontal, 5)
            .foregroundColor(routed == nil ? VintageTheme.textPrimary : .black)
            .frame(width: 82, height: 20)
            .background(
                ZStack {
                    PlasticKeyBackground(cornerRadius: 3)
                    if routed != nil {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(LinearGradient(colors: [accent, accent.opacity(0.78)],
                                                 startPoint: .top, endPoint: .bottom))
                            .padding(1)
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(accent.opacity(0.55), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.fullArea)
        .help(routed.map { s.trackOutputHelp($0.name) } ?? s.trackOutputChooseHelp(ch))
    }

    /// Dieselben Einträge wie `TrackOutputItems` (Kontextmenü), beim Klick gebaut.
    private func showMenu() {
        let current = directory.entries.first { $0.id == track.instrumentID }?.id
        let loop = track.data.isAudioLoop
        let entries = directory.entries.filter { $0.isAudioLoop == loop }
        let td = track.data
        let menu = NSMenu()
        menu.autoenablesItems = false
        if !loop {
            let midi = NSMenuItem(title: s.trackOutputMIDI, action: nil, keyEquivalent: "")
            midi.state = current == nil ? .on : .off
            let sub = NSMenu()
            sub.autoenablesItems = false
            for ch in 1...16 {
                sub.addItem(ClosureMenuItem(title: s.trackOutputChannel(ch),
                                            checked: current == nil && td.midiChannel == ch) {
                    engine.setMIDIOutput(of: td, channel: ch)
                })
            }
            midi.submenu = sub
            menu.addItem(midi)
            if !entries.isEmpty { menu.addItem(.separator()) }
        }
        for e in entries {
            let id = e.id
            menu.addItem(ClosureMenuItem(title: e.name, checked: current == id) {
                engine.setOutput(of: td, to: id)
            })
        }
        if !loop {
            menu.addItem(.separator())
            let add = ClosureMenuItem(title: s.trackOutputNewChannel, checked: false) {
                let name = s.rackDefaultChannelName(engine.rack.channels.count + 1)
                if engine.setOutputToNewChannel(of: td, name: name) != nil { showMixer = true }
            }
            add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
            add.isEnabled = engine.rack.canAddChannel
            menu.addItem(add)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// Menü der Pad-RND-Taste: Quelle (Bücher/leitereigen) und optional eine feste Folge.
/// Die Wahl bleibt für weitere Klicks auf RND gespeichert.
/// AppKit-Menü (v1.16.2, `MenuKey`): RND-Töne je Spurart und Akkordquelle. Liest und
/// schreibt dieselben Schlüssel wie zuvor `@AppStorage`; jede Wahl würfelt sofort.
enum PadChordMenu {
    /// Töne je Spur (v1.18.29): `setMode` schreibt über den ModelWriter (mit Undo).
    static func make(s: Str, german: Bool, mode: RandomNoteMode, setMode: @escaping (RandomNoteMode) -> Void,
                     roll: @escaping () -> Void) -> NSMenu {
        let d = UserDefaults.standard
        func modeItem(_ m: RandomNoteMode, _ title: String) -> NSMenuItem {
            ClosureMenuItem(title: title, checked: mode == m) { setMode(m); roll() }
        }
        let source = d.string(forKey: SequencerEngine.padChordSourceKey) ?? PadChordSource.books.rawValue
        let family = d.string(forKey: SequencerEngine.padChordFamilyKey) ?? ""
        func choose(_ src: PadChordSource, _ fam: String) {
            d.set(src.rawValue, forKey: SequencerEngine.padChordSourceKey)
            d.set(fam, forKey: SequencerEngine.padChordFamilyKey)
            roll()
        }
        var items: [NSMenuItem] = [
            .note(s.rndNotesHeader),
            modeItem(.single, s.rndNotesSingle),
            modeItem(.chords, s.rndNotesChords),
            modeItem(.mixed, s.rndNotesMixed),
            .separator(),
            .note(s.rndChordSourceHeader),
            ClosureMenuItem(title: s.padChordsBooksAny,
                            checked: source == PadChordSource.books.rawValue && family.isEmpty) { choose(.books, "") },
            ClosureMenuItem(title: s.padChordsFree,
                            checked: source == PadChordSource.free.rawValue) { choose(.free, "") },
            .separator(),
            .note(s.padChordsBooksHeader),
        ]
        for f in PadChords.families {
            let id = f.id
            items.append(ClosureMenuItem(title: f.name(german: german),
                                         checked: source == PadChordSource.books.rawValue && family == id) {
                choose(.books, id)
            }.with(toolTip: f.source))
        }
        return .of(items)
    }
}

// MARK: - Pad width popover

/// Breite der Pad-Steps einer Spur in Normal-Stepbreiten. Jeder Klick ist ein Undo-Schritt.
fileprivate struct PadWidthPopover: View {
    @ObservedObject var track: TrackViewModel
    var accentColor: Color
    @Environment(\.undoManager) private var undoManager
    @AppStorage("appLanguage") private var lang: String = "en"
    private var s: Str { Str(lang) }
    private let writer = ModelWriter()

    private func set(_ w: Int) {
        let clamped = max(LaneData.stepWidthRange.lowerBound, min(LaneData.stepWidthRange.upperBound, w))
        guard clamped != track.lane.stepWidth else { return }
        writer.apply(.setStepWidth(trackID: track.id, old: track.lane.stepWidth, new: clamped),
                     to: track.data, undoManager: undoManager)
    }

    var body: some View {
        VStack(spacing: 10) {
            Text(s.padWidthHeader)
                .font(VintageTheme.monoBold)
                .foregroundColor(VintageTheme.textAmber)
            HStack(spacing: 4) {
                ForEach(Array(LaneData.stepWidthRange), id: \.self) { w in
                    Button(w == 0 ? s.stepWidthAuto : "\(w)") { set(w) }
                        .buttonStyle(VintageSmallButtonStyle(isActive: track.lane.stepWidth == w,
                                                             accent: accentColor))
                }
            }
            Text(s.padWidthHelp)
                .font(VintageTheme.monoSmall)
                .foregroundColor(VintageTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 240)
        }
        .padding(14)
        .background(VintageTheme.panelDark)
        .preferredColorScheme(.dark)
    }
}
