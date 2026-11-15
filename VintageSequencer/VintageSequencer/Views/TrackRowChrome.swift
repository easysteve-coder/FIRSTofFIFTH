import SwiftUI
import Combine

// MARK: - Zeilenrahmen der Spuren (v1.17.3)
//
// Gemeinsame Bausteine aller Spurarten (Step, Pad, CC, Audio-Loop): Namensfeld, rechter
// Zeilenrand mit Einklappen und Ziehgriff, eingeklappte Zeile, Ablegeziel beim Verschieben.
// Alle Änderungen laufen über ModelWriter bzw. die Undo-Befehle der Engine.

/// Namensfeld des Spurkopfs. Lokaler Text beim Tippen, Übernahme mit Undo beim
/// Verlassen des Fokus (Enter, Esc, Klick daneben).
struct TrackNameField: View {
    @ObservedObject var track: TrackViewModel
    var accentColor: Color
    let placeholder: String

    @Environment(\.undoManager) private var undoManager
    @FocusState private var focused: Bool
    @State private var edit = ""
    private let writer = ModelWriter()

    var body: some View {
        TextField(placeholder, text: $edit)
            .font(VintageTheme.monoBold)
            .foregroundColor(accentColor)
            .textFieldStyle(.plain)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(GlassDisplayBackground(cornerRadius: 3))   // GUI-01: versenktes Namensfeld
            .focused($focused)
            .onValueChange(of: focused) { isFocused in
                if isFocused {
                    edit = track.name                       // Stand beim Fokus-Eintritt
                } else {
                    let old = track.name
                    guard edit != old else { return }
                    writer.apply(.setName(trackID: track.id, old: old, new: edit),
                                 to: track.data, undoManager: undoManager)
                }
            }
            .onValueChange(of: track.name) { external in
                if !focused { edit = external }             // Undo, Laden, Einfügen
            }
            .onAppear { edit = track.name }
            .onSubmit { focused = false }
            .onExitCommand { focused = false }
    }
}

/// Rechter Rand jeder Spurzeile: Einklappen und Ziehgriff zum Verschieben. Eingeklappt
/// nebeneinander (die Leiste ist nur `collapsedTrackRowHeight` hoch), sonst übereinander.
struct TrackRowEdge: View {
    let trackID: UUID
    let trackIndex: Int
    let collapsed: Bool
    var accentColor: Color
    let s: Str
    let tip: (String) -> String
    @EnvironmentObject private var engine: SequencerEngine
    @EnvironmentObject private var drag: TrackDragState

    private var toggle: some View {
        Button {
            engine.setTrackCollapsedUndoable(at: trackIndex, !collapsed,
                actionName: collapsed ? s.expandTrack : s.collapseTrack)
        } label: {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(VintageTheme.textSecondary)
                .frame(width: collapsed ? 18 : 28, height: collapsed ? 24 : 26)
        }
        .buttonStyle(.fullArea)
        .help(tip(s.collapseTrackTip))
    }

    private var grip: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(VintageTheme.textSecondary)
            .frame(width: collapsed ? 18 : 28, height: collapsed ? 24 : 30)
            .contentShape(Rectangle())
            // Eigene Ziehgeste (v1.17.10): System-Drag-and-drop verhielt sich unter macOS 12
            // anders; die Geste läuft überall gleich und erlaubt die Animation.
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named(TrackDragState.space))
                .onChanged { v in
                    drag.update(id: trackID, order: engine.currentPattern.tracks.map(\.id),
                                y: v.location.y, translation: v.translation.height)
                }
                .onEnded { _ in
                    // Erst in die Lücke gleiten, dann das Modell ohne Animation umstellen
                    // (die Lage stimmt dann schon — nichts springt oder tauscht sichtbar).
                    drag.settle { from, to in
                        engine.moveTrackUndoable(from: from, to: to, actionName: s.undoMoveTrack)
                    }
                })
            .help(tip(s.dragTrackTip))
    }

    var body: some View {
        Group {
            if collapsed {
                HStack(spacing: 0) { toggle; grip }
            } else {
                VStack(spacing: 2) { toggle; Spacer(minLength: 0); grip }
                    .padding(.vertical, 6)
            }
        }
        .frame(width: 40)
        .frame(maxHeight: .infinity)
    }
}

/// Höhe einer eingeklappten Zeile.
let collapsedTrackRowHeight: CGFloat = 30

/// Eingeklappte Spur: Kennung, Name, m/s und der Zeilenrand. Die Spur spielt weiter.
struct CollapsedTrackRow<Menu: View>: View {
    @ObservedObject var track: TrackViewModel
    var accentColor: Color
    let trackIndex: Int
    @ViewBuilder var contextMenu: () -> Menu
    @AppStorage("appLanguage")  private var lang: String = "en"
    @AppStorage("showTooltips") private var showTooltips: Bool = true
    private var s: Str { Str(lang) }
    private func tip(_ t: String) -> String { showTooltips ? t : "" }

    private var badge: String? {
        if track.data.isAudioLoop { return s.loopBadge }
        if track.lane.kind == .cc { return "CC" }
        return nil
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                if let badge {
                    Text(badge)
                        .font(.system(size: 8, weight: .heavy, design: .monospaced))
                        .foregroundColor(.black)
                        .padding(.horizontal, 3).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 2)
                            .fill(track.data.isAudioLoop ? Color.red.opacity(0.8) : accentColor))
                } else {
                    Circle().fill(accentColor).frame(width: 6, height: 6)
                }
                TrackNameField(track: track, accentColor: accentColor, placeholder: s.namePlaceholder)
                TrackMuteSoloButtons(track: track, s: s, tip: tip)
            }
            .padding(.horizontal, 10)
            .frame(width: VintageTheme.trackHeaderWidth, height: collapsedTrackRowHeight)
            .contentShape(Rectangle())
            .contextMenu { contextMenu() }

            Rectangle()
                .fill(Color(red: 0.55, green: 0.42, blue: 0.20).opacity(0.55))
                .frame(width: 1)
            Group {
                if track.data.isAudioLoop { Color.clear }
                else {
                    // Overlay: die Leiste ist so breit wie die Lane und darf die Zeile nicht verbreitern.
                    Color.clear.overlay(alignment: .leading) {
                        CollapsedLaneStrip(track: track, accentColor: accentColor, trackIndex: trackIndex)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: collapsedTrackRowHeight)
            .background(GridWellSurface())
            .clipped()
            TrackRowEdge(trackID: track.id, trackIndex: trackIndex, collapsed: true,
                         accentColor: accentColor, s: s, tip: tip)
                .frame(height: collapsedTrackRowHeight)
        }
        .background(MetalSurface(tone: .darkMetal))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.black.opacity(0.65), lineWidth: 1))
    }
}

// MARK: - Spuren ziehen (v1.17.10)

/// Zustand einer laufenden Ziehbewegung in der Spurliste (nur Main, gehört der MainView).
/// Die gezogene Zeile folgt dem Zeiger; die Zeilen zwischen alter und neuer Position rücken
/// animiert um ihre Höhe zur Seite und öffnen die Lücke, in die sie kommt. Beobachtet wird
/// der Zustand nur vom Blatt-Modifier `TrackDragOffset` — die Zeilen selbst bauen beim Ziehen
/// nicht neu.
final class TrackDragState: ObservableObject {
    static let space = "fofTrackList"
    /// Zeilenabstand der Spurliste (MainView: `VStack(spacing: 8)`).
    static let rowSpacing: CGFloat = 8

    @Published private(set) var draggedID: UUID?
    @Published private(set) var translation: CGFloat = 0
    /// Versatz der übrigen Zeilen (öffnet die Lücke).
    @Published private(set) var shifts: [UUID: CGFloat] = [:]
    /// Zeilenlage im Raum `space` (aus der Preference der Zeilen; nicht veröffentlicht).
    var frames: [UUID: CGRect] = [:]
    private var order: [UUID] = []
    private var from = 0
    private var to = 0

    /// Gleitet gerade in die Lücke (neue Ziehvorgänge warten).
    private var settling = false
    static let settleDuration = 0.16

    func update(id: UUID, order current: [UUID], y: CGFloat, translation t: CGFloat) {
        guard !settling else { return }
        if draggedID != id {
            guard let f = current.firstIndex(of: id) else { return }
            order = current; from = f; to = f; draggedID = id
        }
        translation = t
        // Zielzeile = Zahl der übrigen Zeilen, deren Mitte über dem Zeiger liegt.
        let target = order.enumerated().filter { i, rid in
            i != from && (frames[rid]?.midY ?? .infinity) < y
        }.count
        guard target != to || shifts.isEmpty else { return }
        to = target
        let h = (frames[id]?.height ?? 0) + Self.rowSpacing
        var next: [UUID: CGFloat] = [:]
        for (i, rid) in order.enumerated() where i != from {
            if to > from, i > from, i <= to { next[rid] = -h }
            if to < from, i >= to, i < from { next[rid] = h }
        }
        withAnimation(.easeOut(duration: 0.18)) { shifts = next }
    }

    /// Versatz, bei dem die gezogene Zeile genau in der Lücke liegt.
    private func restingOffset() -> CGFloat {
        guard to != from else { return 0 }
        let range = to > from ? (from + 1)...to : to...(from - 1)
        let span = range.reduce(CGFloat(0)) { $0 + (frames[order[$1]]?.height ?? 0) + Self.rowSpacing }
        return to > from ? span : -span
    }

    /// Loslassen: die gezogene Zeile gleitet animiert in die Lücke; danach übernimmt `commit`
    /// die Bewegung, zusammen mit dem Zurücksetzen und ohne Animation — die übrigen Zeilen
    /// stehen schon an ihrem neuen Platz.
    func settle(commit: @escaping (_ from: Int, _ to: Int) -> Void) {
        guard draggedID != nil, !settling else { return }
        guard to != from else {
            withAnimation(.easeOut(duration: Self.settleDuration)) { _ = finish() }
            return
        }
        settling = true
        withAnimation(.easeOut(duration: Self.settleDuration)) { translation = restingOffset() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDuration) { [self] in
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                if let move = finish() { commit(move.from, move.to) }
            }
            settling = false
        }
    }

    /// Ende: Bewegung (falls eine) und Zurücksetzen.
    func finish() -> (from: Int, to: Int)? {
        let move = draggedID != nil && to != from ? (from: from, to: to) : nil
        draggedID = nil; translation = 0; shifts = [:]
        return move
    }
}

/// Lage der Spurzeilen für die Ziehgeste.
struct TrackRowFramesKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Blatt-Modifier: meldet die Lage der Zeile und versetzt sie beim Ziehen.
struct TrackDragOffset: ViewModifier {
    let trackID: UUID
    @EnvironmentObject private var drag: TrackDragState

    func body(content: Content) -> some View {
        let dragged = drag.draggedID == trackID
        content
            .background(GeometryReader { geo in
                Color.clear.preference(key: TrackRowFramesKey.self,
                                       value: [trackID: geo.frame(in: .named(TrackDragState.space))])
            })
            .offset(y: dragged ? drag.translation : (drag.shifts[trackID] ?? 0))
            .shadow(color: .black.opacity(dragged ? 0.55 : 0), radius: dragged ? 10 : 0, y: dragged ? 4 : 0)
            .zIndex(dragged ? 1 : 0)
    }
}

extension View {
    func trackDragOffset(_ trackID: UUID) -> some View { modifier(TrackDragOffset(trackID: trackID)) }
}

// MARK: - Step-Leiste der eingeklappten Spur

/// Steps der eingeklappten Spur in klein: an derselben Stelle wie im großen Raster (gleiche
/// Step-Breite, gleicher Scroll), nur mit dem Nötigsten — LED je Step wie im Raster (aktiv in
/// Spurfarbe, gespielter Step hell), Velocity als Streifen, bei CC-Spuren der Wert als Balken.
/// Nur Anzeige; Scroll und Playhead über Blatt-Views.
struct CollapsedLaneStrip: View {
    @ObservedObject var track: TrackViewModel
    var accentColor: Color
    let trackIndex: Int
    @EnvironmentObject private var stepWidthState: StepWidthState

    var body: some View {
        let lane = track.lane
        let layout = CollapsedStripLayout(stepCount: lane.stepCount, num: lane.displayNumerator,
                                          den: lane.displayDenominator, stepWidthSize: stepWidthState.size)
        let isCC = lane.kind == .cc
        let steps = lane.steps, cc = lane.ccValues
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                let h = size.height - 8
                for i in 0..<layout.count {
                    let x = layout.x(i), w = layout.width(i)
                    let cell = CGRect(x: x, y: 4, width: w, height: h)
                    if isCC {
                        ctx.fill(Path(roundedRect: cell, cornerRadius: 2), with: .color(Color.white.opacity(0.05)))
                        let v = i < cc.count ? CGFloat(cc[i]) / 127 : 0
                        let bar = CGRect(x: x, y: 4 + h * (1 - v), width: w, height: h * v)
                        ctx.fill(Path(roundedRect: bar, cornerRadius: 1), with: .color(accentColor.opacity(0.75)))
                        continue
                    }
                    let active = i < steps.count && steps[i].isActive
                    ctx.fill(Path(roundedRect: cell, cornerRadius: 2),
                             with: .color(active ? accentColor.opacity(0.10) : Color.white.opacity(0.05)))
                    // LED wie im Raster: Fassung, Licht, bei aktiven Steps Schein.
                    let c = layout.ledCenter(i)
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)),
                             with: .color(Color.black.opacity(0.6)))
                    if active {
                        var glow = ctx
                        glow.addFilter(.shadow(color: accentColor.opacity(0.5), radius: 3))
                        glow.fill(Path(ellipseIn: CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7)),
                                  with: .color(accentColor))
                        let vel = max(1, CGFloat(steps[i].velocity) / 127 * (w - 8))
                        ctx.fill(Path(CGRect(x: x + (w - vel) / 2, y: 4 + h - 3, width: vel, height: 2)),
                                 with: .color(accentColor.opacity(0.75)))
                    } else {
                        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7)),
                                 with: .color(VintageTheme.amberDim.opacity(0.4)))
                    }
                }
            }
            CollapsedPlayhead(trackIndex: trackIndex, layout: layout)
        }
        .frame(width: layout.extent, height: collapsedTrackRowHeight, alignment: .topLeading)
        .laneScrollShift()
        .allowsHitTesting(false)
    }
}

/// Zelllage wie im Step-Raster (`distributedStepWidth`, `stepGridLeadingPad`).
struct CollapsedStripLayout: Equatable {
    let count: Int
    let slot: CGFloat
    init(stepCount: Int, num: Int, den: Int, stepWidthSize: Double) {
        count = max(0, stepCount)
        slot = den > 0 ? (CGFloat(stepWidthSize) + VintageTheme.stepSpacing) * CGFloat(num) / CGFloat(den) : 0
    }
    func x(_ i: Int) -> CGFloat {
        VintageTheme.stepGridLeadingPad + (slot * CGFloat(i)).rounded(.toNearestOrEven)
    }
    func width(_ i: Int) -> CGFloat {
        (slot * CGFloat(i + 1)).rounded(.toNearestOrEven) - (slot * CGFloat(i)).rounded(.toNearestOrEven)
            - VintageTheme.stepSpacing
    }
    var extent: CGFloat { x(count) + VintageTheme.stepGridLeadingPad }
    /// Mitte der LED einer Zelle (Zeilenmitte, etwas über dem Velocity-Streifen).
    func ledCenter(_ i: Int) -> CGPoint {
        CGPoint(x: x(i) + width(i) / 2, y: collapsedTrackRowHeight / 2 - 1)
    }
}

/// LED des gerade gespielten Steps (hell mit Schein, wie im Raster) — einziger Beobachter
/// des Playheads in der Leiste.
private struct CollapsedPlayhead: View {
    let trackIndex: Int
    let layout: CollapsedStripLayout
    @EnvironmentObject private var playbackDisplay: PlaybackDisplayState

    var body: some View {
        let steps = playbackDisplay.steps
        if trackIndex >= 0, trackIndex < steps.count, steps[trackIndex] >= 0, steps[trackIndex] < layout.count {
            let c = layout.ledCenter(steps[trackIndex])
            Circle()
                .fill(VintageTheme.amberBright)
                .frame(width: 7, height: 7)
                .shadow(color: VintageTheme.amberBright, radius: 6)
                .offset(x: c.x - 3.5, y: c.y - 3.5)
        }
    }
}
