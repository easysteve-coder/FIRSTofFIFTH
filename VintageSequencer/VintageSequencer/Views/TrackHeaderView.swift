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
    var onDuplicate:   (() -> Void)?

    @Environment(\.undoManager) private var undoManager
    /// Nur für die Ausgangsanzeige (Rack-Kanal der Spur). Die Engine publiziert nur bei
    /// Struktur-/Transport-Ereignissen — der Spurkopf wird dadurch nicht häufiger neu gebaut.
    @EnvironmentObject private var engine: SequencerEngine
    @FocusState private var nameFocused: Bool
    @State private var showScalePicker = false
    @State private var showFeelPopover = false
    // nameEdit: lokaler @State für den TextField. Wird bei Focus-In aus track.name
    // initialisiert; ModelWriter-Commit beim Focus-Out. Verhindert, dass jeder
    // Tastendruck direkt in track.name schreibt (Slice E). Undo bleibt erhalten.
    @State private var nameEdit: String = ""
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

                // TextField bindet an lokalen nameEdit-State, nicht direkt an track.name.
                // Commit (ModelWriter) erfolgt beim Verlassen des Fokus — Undo bleibt.
                TextField(s.namePlaceholder, text: $nameEdit)
                    .font(VintageTheme.monoBold)
                    .foregroundColor(accentColor)
                    .textFieldStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(GlassDisplayBackground(cornerRadius: 3))   // GUI-01: versenktes Namensfeld
                    .focused($nameFocused)
                    .onChange(of: nameFocused) { _, focused in
                        if focused {
                            nameEdit = track.name   // Snapshot beim Focus-In
                        } else {
                            let old = track.name
                            let new = nameEdit
                            guard new != old else { return }
                            writer.apply(.setName(trackID: track.id, old: old, new: new),
                                         to: track.data,
                                         undoManager: undoManager)
                        }
                    }
                    .onChange(of: track.name) { _, external in
                        // Sync wenn track.name extern geändert wird (z.B. Paste-Pattern, Undo).
                        if !nameFocused { nameEdit = external }
                    }
                    .onAppear { nameEdit = track.name }
                    .onSubmit   { nameFocused = false }
                    .onExitCommand { nameFocused = false }

                Button(track.isMuted ? "M" : "m") {
                    writer.apply(.setMuted(trackID: track.id,
                                           old: track.isMuted,
                                           new: !track.isMuted),
                                 to: track.data, undoManager: nil)
                }
                .buttonStyle(VintageSmallButtonStyle(isActive: track.isMuted, accent: .orange))
                .help(tip(track.isMuted ? s.mutedTooltip : s.muteTooltip))

                Button(track.isSolo ? "S" : "s") {
                    writer.apply(.setSolo(trackID: track.id,
                                          old: track.isSolo,
                                          new: !track.isSolo),
                                 to: track.data, undoManager: nil)
                }
                .buttonStyle(VintageSmallButtonStyle(isActive: track.isSolo,
                    accent: Color(red: 0.9, green: 0.9, blue: 0.1)))
                .help(tip(track.isSolo ? s.soloActiveTooltip : s.soloTooltip))

                if let onDuplicate {
                    Button { onDuplicate() } label: {
                        Text("⎘")
                            .font(.system(size: 15))
                            .foregroundColor(VintageTheme.textSecondary)
                    }
                    .buttonStyle(.fullArea)
                    .help(tip(s.duplicateTooltip))
                }
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

                // Ausgangswahl: „MIDI" = externes MIDI, „AU" = Instrumentenkanal (der MIDI-Kanal
                // gilt dann innerhalb des Instruments). Eigene Blatt-View: nur sie folgt der
                // Kanalliste des Racks.
                TrackOutputMenu(track: track, directory: engine.rack.directory,
                                accent: accentColor, s: s)
                    .padding(.trailing, 2)
                Picker("", selection: Binding(
                    get: { track.midiChannel },
                    set: { ch in
                        writer.apply(.setMIDIChannel(trackID: track.id,
                                                      old: track.midiChannel,
                                                      new: ch),
                                     to: track.data, undoManager: nil)
                    }
                )) {
                    ForEach(1...16, id: \.self) { ch in
                        Text(ch == 10 ? "10 ◆" : "\(ch)")
                            .font(VintageTheme.monoSmall)
                            .tag(ch)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .font(VintageTheme.monoSmall)
                .frame(width: 52)
                .help(tip(s.midiChannelTooltip))
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
                // RND; auf Pad-Spuren daneben die Wahl der Akkordquelle (▾).
                Button("RND") { onRandomize?() }
                .buttonStyle(VintageSmallButtonStyle(isActive: false, accent: accentColor))
                .help(tip(track.lane.isPad ? s.padRandomizeTooltip : s.randomizeTooltip))
                if track.lane.isPad {
                    Menu {
                        PadChordMenuItems(s: s, german: lang == "de") { onRandomize?() }
                    } label: {
                        Text("▾")
                            .font(VintageTheme.monoSmall)
                            .foregroundColor(VintageTheme.textPrimary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(PlasticKeyBackground(tint: nil, tintStrength: 0.3,
                                                             cornerRadius: 3, pressed: false))
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
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
                                                          new: max(-0.05, min(0.05, $0 / 1000))),
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
        item(nil, s.trackOutputMIDI, current)
        if !directory.entries.isEmpty { Divider() }
        ForEach(directory.entries) { item($0.id, $0.name, current) }
        Divider()
        // Legt einen Kanal an, weist ihn zu und zeigt den Mixer: dort wird das Instrument gewählt.
        Button {
            let name = s.rackDefaultChannelName(engine.rack.channels.count + 1)
            if engine.setOutputToNewChannel(of: track.data, name: name) != nil { showMixer = true }
        } label: {
            Label(s.trackOutputNewChannel, systemImage: "plus")
        }
        .disabled(!engine.rack.canAddChannel)
    }

    @ViewBuilder
    private func item(_ id: UUID?, _ title: String, _ current: UUID?) -> some View {
        Button { engine.setOutput(of: track.data, to: id) } label: {
            if current == id { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}

/// Taste „MIDI"/„AU" im Spurkopf mit der Ausgangswahl als Menü.
struct TrackOutputMenu: View {
    @ObservedObject var track: TrackViewModel
    @ObservedObject var directory: ChannelDirectory
    let accent: Color
    let s: Str

    var body: some View {
        let routed = directory.entries.first { $0.id == track.instrumentID }
        // Sichtbare Taste ist eine eigene Ebene; das Menü liegt unsichtbar darüber. Ein
        // borderless-Menü zeichnet sein Label nur abgeblendet und ohne Tastenfläche.
        HStack(spacing: 1) {
            Text(routed == nil ? "MIDI" : "AU")
                .font(VintageTheme.monoSmall)
            Image(systemName: "chevron.down")
                .font(.system(size: 6, weight: .bold))
        }
        .foregroundColor(routed == nil ? VintageTheme.textPrimary : .black)
        .frame(width: 38, height: 20)
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
        .overlay(
            Menu {
                TrackOutputItems(track: track, directory: directory, s: s)
            } label: {
                Color.clear.frame(width: 38, height: 20).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 38, height: 20)
            .contentShape(Rectangle())
        )
        .help(routed.map { s.trackOutputHelp($0.name) } ?? s.trackOutputChooseHelp)
    }
}

/// Menü der Pad-RND-Taste: Quelle (Bücher/leitereigen) und optional eine feste Folge.
/// Die Wahl bleibt für weitere Klicks auf RND gespeichert.
private struct PadChordMenuItems: View {
    let s: Str
    let german: Bool
    let roll: () -> Void
    @AppStorage(SequencerEngine.padChordSourceKey) private var source: String = PadChordSource.books.rawValue
    @AppStorage(SequencerEngine.padChordFamilyKey) private var family: String = ""

    var body: some View {
        Button(mark(source == PadChordSource.books.rawValue && family.isEmpty) + s.padChordsBooksAny) {
            source = PadChordSource.books.rawValue; family = ""; roll()
        }
        Button(mark(source == PadChordSource.free.rawValue) + s.padChordsFree) {
            source = PadChordSource.free.rawValue; family = ""; roll()
        }
        Divider()
        Section(s.padChordsBooksHeader) {
            ForEach(PadChords.families) { f in
                Button(mark(source == PadChordSource.books.rawValue && family == f.id) + f.name(german: german)) {
                    source = PadChordSource.books.rawValue; family = f.id; roll()
                }
                .help(f.source)
            }
        }
    }

    private func mark(_ on: Bool) -> String { on ? "✓ " : "    " }
}
