import SwiftUI
import AppKit

// MARK: - CCLaneHeaderView
//
// Linker Spurkopf für `.cc`-Lanes (CC-Lane Slice 1).
//
// Ersetzt für CC-Lanes die Kombination aus `TrackHeaderView` + `TrackCCSectionView`
// der Step-Lane. Inhalt:
//   - Name, Mute, Solo, Duplicate
//   - Playback-Richtung, Ausgang, MIDI-Channel
//   - CC-Nummer, Label, RND, NEU, Curve-Toggle, Draw-Toggle, CC-Mute
//
// Bewusst nicht enthalten: FEEL, SCL, Step-RND/CLR — Scale-Quantisierung und
// Note-Randomize sind step-spezifisch; FEEL kann ein späterer Slice nachrüsten.
struct CCLaneHeaderView: View {

    @ObservedObject var track: TrackViewModel
    var accentColor:  Color
    @Binding var drawMode: Bool
    var onDelete:     (() -> Void)?

    @Environment(\.undoManager) private var undoManager
    @EnvironmentObject private var engine: SequencerEngine
    @AppStorage("appLanguage") private var lang:        String = "en"
    @AppStorage("showCCCurve") private var showCCCurve: Bool   = true
    @AppStorage("showTooltips") private var showTooltips: Bool = true
    private var s: Str { Str(lang) }
    private func tip(_ t: String) -> String { showTooltips ? t : "" }

    @FocusState private var labelFocused: Bool
    @FocusState private var numberFocused: Bool
    @State private var labelEdit:  String = ""
    @State private var numberEdit: String = ""
    private let writer = ModelWriter()

    private func directionSymbol(_ dir: PlayDirection) -> String {
        switch dir {
        case .forward:  return "play.fill"
        case .reverse:  return "backward.end.fill"
        case .pingPong: return "arrow.left.arrow.right"
        case .random:   return "waveform"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {

            // Row 1: dot · name · m · s · ⎘
            HStack(spacing: 4) {
                if onDelete != nil { Spacer().frame(width: 14) }
                Circle().fill(accentColor).frame(width: 6, height: 6)
                TrackNameField(track: track, accentColor: accentColor, placeholder: s.namePlaceholder)

                TrackMuteSoloButtons(track: track, s: s, tip: tip)
            }

            // Row 2: direction · CH
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
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(accentColor.opacity(0.4), lineWidth: 1))

                Spacer()

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
                        Text(ch == 10 ? "10 ◆" : "\(ch)").font(VintageTheme.monoSmall).tag(ch)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 52)
            }

            // Row 3: CC# TextField · Label TextField · CC-Mute
            HStack(spacing: 4) {
                // Geht die Spur auf ein Instrument, wählt diese Taste das Ziel: MIDI-CC oder
                // einen Parameter des Instruments. Eigene Blatt-View (folgt der Kanalliste).
                CCTargetButton(track: track, directory: engine.rack.directory,
                               accent: accentColor, s: s)
                if track.lane.ccParameter == nil || track.instrumentID == nil {
                Text(s.ccNumberLabel)
                    .font(VintageTheme.monoSmall)
                    .foregroundColor(VintageTheme.textSecondary)
                TextField("", text: $numberEdit)
                    .font(VintageTheme.monoSmall)
                    .textFieldStyle(.plain)
                    .frame(width: 34)
                    .focused($numberFocused)
                    .onValueChange(of: numberFocused) { focused in
                        if focused {
                            numberEdit = "\(track.lane.ccNumber)"
                        } else {
                            let old = track.lane.ccNumber
                            let new = max(0, min(127, Int(numberEdit) ?? old))
                            numberEdit = "\(new)"
                            guard new != old else { return }
                            writer.apply(.setCCLaneNumber(trackID: track.id, old: old, new: new),
                                         to: track.data, undoManager: undoManager)
                        }
                    }
                    .onAppear { numberEdit = "\(track.lane.ccNumber)" }
                    .onSubmit { numberFocused = false }
                }

                TextField("", text: $labelEdit)
                    .font(VintageTheme.monoSmall)
                    .textFieldStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .focused($labelFocused)
                    .onValueChange(of: labelFocused) { focused in
                        if focused {
                            labelEdit = track.lane.ccLabel
                        } else {
                            let old = track.lane.ccLabel
                            guard labelEdit != old else { return }
                            writer.apply(.setCCLaneLabel(trackID: track.id, old: old, new: labelEdit),
                                         to: track.data, undoManager: undoManager)
                        }
                    }
                    .onAppear { labelEdit = track.lane.ccLabel }
                    .onSubmit { labelFocused = false }

                Button {
                    writer.apply(.setCCLaneMuted(trackID: track.id,
                                                  old: track.lane.ccIsMuted,
                                                  new: !track.lane.ccIsMuted),
                                 to: track.data, undoManager: nil)
                } label: {
                    Image(systemName: track.lane.ccIsMuted ? "speaker.slash.fill" : "speaker.wave.2")
                        .font(.system(size: 10))
                }
                .buttonStyle(VintageSmallButtonStyle(isActive: track.lane.ccIsMuted, accent: .orange))
            }

            // Row 4: RND · NEU · curve · draw
            HStack(spacing: 4) {
                Button(s.ccRandomizeLabel) {
                    let old = track.lane.ccValues
                    var v   = track.lane.ccValues
                    for i in 0..<track.lane.stepCount {
                        guard i < v.count else { continue }
                        v[i] = Int.random(in: 0...127)
                    }
                    writer.apply(.setCCLaneValues(trackID: track.id,
                                                   oldValues: old,
                                                   newValues: v,
                                                   actionName: s.undoCCLaneRandomize),
                                 to: track.data, undoManager: undoManager)
                }
                .buttonStyle(VintageSmallButtonStyle(isActive: false, accent: accentColor))
                .disabled(track.lane.ccIsMuted)

                Button(s.ccResetLabel) {
                    let old = track.lane.ccValues
                    var v   = track.lane.ccValues
                    for i in 0..<track.lane.stepCount {
                        guard i < v.count else { continue }
                        v[i] = 64
                    }
                    writer.apply(.setCCLaneValues(trackID: track.id,
                                                   oldValues: old,
                                                   newValues: v,
                                                   actionName: s.undoCCLaneReset),
                                 to: track.data, undoManager: undoManager)
                }
                .buttonStyle(VintageSmallButtonStyle(isActive: false, accent: .gray))
                .disabled(track.lane.ccIsMuted)

                Spacer()

                Button { showCCCurve.toggle() } label: {
                    Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 10))
                }
                .buttonStyle(VintageSmallButtonStyle(isActive: showCCCurve, accent: accentColor))

                Button { drawMode.toggle() } label: {
                    Image(systemName: "pencil.tip").font(.system(size: 10))
                }
                .buttonStyle(VintageSmallButtonStyle(isActive: drawMode, accent: accentColor))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxHeight: .infinity)
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
            }
        }
    }
}

// MARK: - CCTargetButton

/// Ziel einer CC-Lane (v1.13.9; Auswahlfenster v1.17.1): MIDI-CC oder ein Parameter des
/// Instruments oder eines Effekts im Kanal. Ohne Instrumentenkanal unsichtbar.
///
/// Die Wahl läuft in einem Fenster: erst das Plug-in, dann der Parameter — alphabetisch,
/// mit Suchfeld. Die Liste wird beim Öffnen aus dem Parameterbaum gelesen; der Kopf
/// beobachtet nur das Kanalverzeichnis (Laden von Instrument/Effekten), nicht das Rack.
struct CCTargetButton: View {
    @ObservedObject var track: TrackViewModel
    @ObservedObject var directory: ChannelDirectory
    let accent: Color
    let s: Str
    @EnvironmentObject private var engine: SequencerEngine
    @Environment(\.undoManager) private var undoManager
    @State private var showPicker = false

    var body: some View {
        if let channel = directory.entries.first(where: { $0.id == track.instrumentID }) {
            let target = track.lane.ccParameter
            // Aufgelöst = das gebundene Plug-in ist geladen und hat den Parameter. Sonst
            // sendet die Lane nichts (v1.13.13); die Taste zeigt das mit „?" und ohne Füllung.
            let resolved = target.map { engine.rack.resolveParameter($0, in: channel.id) != nil } ?? true
            let source = target.flatMap { engine.rack.parameterSource(of: $0, in: channel.id) }
            Button { showPicker = true } label: {
                HStack(spacing: 2) {
                    Text(target.map { resolved ? $0.name : $0.name + " ?" } ?? "CC")
                        .font(VintageTheme.monoSmall)
                        .lineLimit(1).truncationMode(.tail)
                    Image(systemName: "chevron.down").font(.system(size: 6, weight: .bold))
                }
                .foregroundColor(target == nil ? VintageTheme.textPrimary
                                 : (resolved ? .black : VintageTheme.textDim))
                .padding(.horizontal, 5)
                .frame(maxWidth: target == nil ? nil : 96, minHeight: 20, maxHeight: 20)
                .background(
                    ZStack {
                        PlasticKeyBackground(cornerRadius: 3)
                        if target != nil, resolved {
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
            .help(target.map { resolved ? s.ccTargetParameterHelp($0.name, "\(source?.name ?? "?") · \(channel.name)")
                                        : s.ccTargetUnresolvedHelp($0.name) } ?? s.ccTargetChooseHelp)
            .popover(isPresented: $showPicker, arrowEdge: .bottom) {
                CCTargetPicker(channelID: channel.id, current: target, ccNumber: track.lane.ccNumber,
                               initialSource: source?.id ?? engine.rack.parameterSources(for: channel.id).first?.id ?? "",
                               s: s) { new in
                    choose(new)
                    showPicker = false
                }
                .environmentObject(engine)
            }
        }
    }

    private func choose(_ new: ParameterRef?) {
        let old = track.lane.ccParameter
        guard old != new else { return }
        ModelWriter().apply(.setCCLaneParameter(trackID: track.id, old: old, new: new),
                            to: track.data, undoManager: undoManager)
    }
}

/// Auswahlfenster des CC-Ziels: MIDI-CC, Plug-in (Instrument / Effekt n), Suche, Liste.
struct CCTargetPicker: View {
    let channelID: UUID
    let current: ParameterRef?
    let ccNumber: Int
    let s: Str
    let choose: (ParameterRef?) -> Void
    @EnvironmentObject private var engine: SequencerEngine
    @State private var sourceID: String
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    init(channelID: UUID, current: ParameterRef?, ccNumber: Int, initialSource: String, s: Str,
         choose: @escaping (ParameterRef?) -> Void) {
        self.channelID = channelID; self.current = current; self.ccNumber = ccNumber
        self.s = s; self.choose = choose
        _sourceID = State(initialValue: initialSource)
    }

    var body: some View {
        let sources = engine.rack.parameterSources(for: channelID)
        let source = sources.first { $0.id == sourceID } ?? sources.first
        VStack(alignment: .leading, spacing: 8) {
            Button(s.ccTargetMIDI(ccNumber)) { choose(nil) }
                .buttonStyle(VintageSmallButtonStyle(isActive: current == nil))
            if let source {
                Picker(s.ccTargetPlugin, selection: $sourceID) {
                    ForEach(sources) { Text(title($0)).tag($0.id) }
                }
                .font(VintageTheme.monoSmall)
                TextField(s.ccTargetSearch, text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                list(for: source)
            } else {
                Text(s.ccTargetNoPlugins)
                    .font(VintageTheme.monoSmall).foregroundColor(VintageTheme.textSecondary)
            }
        }
        .padding(12)
        .frame(width: 340)
        .onAppear { searchFocused = true }
    }

    private func title(_ src: InstrumentRack.ParameterSource) -> String {
        let base = src.effectIndex.map { s.ccTargetEffect($0 + 1, src.name) } ?? s.ccTargetInstrument(src.name)
        return src.ready ? base : base + " — " + s.ccTargetNotLoaded
    }

    @ViewBuilder
    private func list(for source: InstrumentRack.ParameterSource) -> some View {
        let all = engine.rack.parameters(for: channelID, source: source)
        let shown = Self.filtered(all, query: query)
        if !source.ready {
            note(s.ccTargetNotLoaded)
        } else if all.isEmpty {
            note(s.ccTargetNoParameters)
        } else if shown.isEmpty {
            note(s.ccTargetNoMatch)
        } else {
            Text(s.ccTargetCount(shown.count, all.count))
                .font(.system(size: 9, design: .monospaced)).foregroundColor(VintageTheme.textDim)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { p in row(p, source: source) }
                }
            }
            .frame(height: 320)
        }
    }

    private func row(_ p: InstrumentRack.ParameterInfo, source: InstrumentRack.ParameterSource) -> some View {
        let ref = InstrumentRack.parameterRef(p, of: source)
        let selected = current.map { $0.address == ref.address && $0.component == ref.component && $0.effect == ref.effect } ?? false
        return Button { choose(ref) } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                    .opacity(selected ? 1 : 0)
                Text(p.name).font(VintageTheme.monoSmall).foregroundColor(VintageTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !p.group.isEmpty {
                    Text(p.group).font(.system(size: 9, design: .monospaced))
                        .foregroundColor(VintageTheme.textDim).lineLimit(1)
                }
            }
            .padding(.vertical, 3).padding(.horizontal, 4)
            .background(selected ? Color.white.opacity(0.08) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.fullArea)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(VintageTheme.monoSmall).foregroundColor(VintageTheme.textSecondary)
    }

    /// Alphabetisch (natürliche Zahlenfolge: „Osc 2" vor „Osc 10"), bei gleichem Namen nach
    /// Gruppe. Suche: jedes Wort muss in Name oder Gruppe vorkommen (ohne Groß-/Klein- und
    /// Akzentunterschied).
    static func filtered(_ params: [InstrumentRack.ParameterInfo], query: String) -> [InstrumentRack.ParameterInfo] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let hits = words.isEmpty ? params : params.filter { p in
            words.allSatisfy { p.name.range(of: $0, options: opts) != nil || p.group.range(of: $0, options: opts) != nil }
        }
        return hits.sorted {
            let c = $0.name.localizedStandardCompare($1.name)
            return c == .orderedSame ? $0.group.localizedStandardCompare($1.group) == .orderedAscending
                                     : c == .orderedAscending
        }
    }
}

/// Menüeintrag mit Closure als Aktion (für beim Klick gebaute AppKit-Menüs).
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, checked: Bool, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
    }
    required init(coder: NSCoder) { fatalError("init(coder:) wird nicht verwendet") }
    @objc private func fire() { handler() }
}
