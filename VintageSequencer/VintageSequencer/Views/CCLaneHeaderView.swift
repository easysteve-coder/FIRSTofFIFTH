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
    var onDuplicate:  (() -> Void)?

    @Environment(\.undoManager) private var undoManager
    @EnvironmentObject private var engine: SequencerEngine
    @AppStorage("appLanguage") private var lang:        String = "en"
    @AppStorage("showCCCurve") private var showCCCurve: Bool   = true
    @AppStorage("showTooltips") private var showTooltips: Bool = true
    private var s: Str { Str(lang) }
    private func tip(_ t: String) -> String { showTooltips ? t : "" }

    @FocusState private var nameFocused: Bool
    @FocusState private var labelFocused: Bool
    @FocusState private var numberFocused: Bool
    @State private var nameEdit:   String = ""
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
                            nameEdit = track.name
                        } else {
                            let old = track.name
                            guard nameEdit != old else { return }
                            writer.apply(.setName(trackID: track.id, old: old, new: nameEdit),
                                         to: track.data, undoManager: undoManager)
                        }
                    }
                    .onChange(of: track.name) { _, ext in
                        if !nameFocused { nameEdit = ext }
                    }
                    .onAppear { nameEdit = track.name }
                    .onSubmit { nameFocused = false }

                Button(track.isMuted ? "M" : "m") {
                    writer.apply(.setMuted(trackID: track.id,
                                           old: track.isMuted,
                                           new: !track.isMuted),
                                 to: track.data, undoManager: nil)
                }
                .buttonStyle(VintageSmallButtonStyle(isActive: track.isMuted, accent: .orange))

                Button(track.isSolo ? "S" : "s") {
                    writer.apply(.setSolo(trackID: track.id,
                                          old: track.isSolo,
                                          new: !track.isSolo),
                                 to: track.data, undoManager: nil)
                }
                .buttonStyle(VintageSmallButtonStyle(isActive: track.isSolo,
                    accent: Color(red: 0.9, green: 0.9, blue: 0.1)))

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
                    .onChange(of: numberFocused) { _, focused in
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
                    .onChange(of: labelFocused) { _, focused in
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

/// Zielwahl einer CC-Lane, die auf einen Instrumentenkanal geht: MIDI-CC oder ein Parameter
/// des Instruments. Ohne Instrumentenkanal unsichtbar (dann gilt immer MIDI-CC).
///
/// Das Menü wird erst beim Klick aus dem Parameterbaum gebaut (AppKit-Menü): so ist es
/// aktuell, auch wenn das Instrument nach dem Zeichnen des Kopfs fertig geladen hat, und
/// der Kopf muss dafür das Rack nicht beobachten.
struct CCTargetButton: View {
    @ObservedObject var track: TrackViewModel
    @ObservedObject var directory: ChannelDirectory
    let accent: Color
    let s: Str
    @EnvironmentObject private var engine: SequencerEngine
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        if let channel = directory.entries.first(where: { $0.id == track.instrumentID }) {
            let target = track.lane.ccParameter
            // Aufgelöst = das gebundene Instrument ist geladen und hat den Parameter. Sonst
            // sendet die Lane nichts (v1.13.13); die Taste zeigt das mit „?" und ohne Füllung.
            let resolved = target.map { Self.isResolved($0, readyInstrument: channel.readyInstrument,
                                                        hasParameter: engine.rack.parameterRange($0.address, in: channel.id) != nil) } ?? true
            Button { showMenu(channelID: channel.id) } label: {
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
            .help(target.map { resolved ? s.ccTargetParameterHelp($0.name, channel.name)
                                        : s.ccTargetUnresolvedHelp($0.name) } ?? s.ccTargetChooseHelp)
        }
    }

    /// Ziel auflösbar? Gebundenes Plug-in (falls vermerkt) muss das geladene sein.
    static func isResolved(_ ref: ParameterRef, readyInstrument: String?, hasParameter: Bool) -> Bool {
        guard let ready = readyInstrument, hasParameter else { return false }
        return ref.component == nil || ref.component == ready
    }

    private func choose(_ new: ParameterRef?) {
        let old = track.lane.ccParameter
        guard old != new else { return }
        ModelWriter().apply(.setCCLaneParameter(trackID: track.id, old: old, new: new),
                            to: track.data, undoManager: undoManager)
    }

    private func showMenu(channelID: UUID) {
        let current = track.lane.ccParameter?.address
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem(title: s.ccTargetMIDI(track.lane.ccNumber),
                                     checked: current == nil) { choose(nil) })
        menu.addItem(.separator())
        let params = engine.rack.parameters(for: channelID)
        if params.isEmpty {
            let empty = NSMenuItem(title: s.ccTargetNoParameters, action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for section in CCTargetButton.sections(params) {
            let target: NSMenu
            if let title = section.title {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let sub = NSMenu(); sub.autoenablesItems = false
                item.submenu = sub
                if section.items.contains(where: { $0.address == current }) { item.state = .on }
                menu.addItem(item)
                target = sub
            } else { target = menu }
            for p in section.items {
                target.addItem(ClosureMenuItem(title: p.name, checked: p.address == current) {
                    choose(ParameterRef(address: p.address, name: p.name,
                                        component: engine.rack.readyInstrumentKey(channelID)))
                })
            }
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    struct Section: Equatable {
        let title: String?
        let items: [InstrumentRack.ParameterInfo]
    }

    /// Gliedert die Parameterliste für das Menü: nach den Gruppen des Plug-ins, wenn es welche
    /// hat; sonst bis 40 Einträge flach, darüber in Blöcken zu 40 („1–40", „41–80", …).
    static func sections(_ params: [InstrumentRack.ParameterInfo], chunk: Int = 40) -> [Section] {
        guard !params.isEmpty else { return [] }
        if params.contains(where: { !$0.group.isEmpty }) {
            var order: [String] = []; var byGroup: [String: [InstrumentRack.ParameterInfo]] = [:]
            for p in params {
                if byGroup[p.group] == nil { order.append(p.group) }
                byGroup[p.group, default: []].append(p)
            }
            return order.map { Section(title: $0.isEmpty ? nil : $0, items: byGroup[$0] ?? []) }
        }
        if params.count <= chunk { return [Section(title: nil, items: params)] }
        return stride(from: 0, to: params.count, by: chunk).map { start in
            let end = min(start + chunk, params.count)
            return Section(title: "\(start + 1)–\(end)", items: Array(params[start..<end]))
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
