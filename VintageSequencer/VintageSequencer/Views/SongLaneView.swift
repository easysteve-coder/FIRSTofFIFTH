import SwiftUI

// MARK: - SongLaneView (v1.14.0)
//
// Song-Lane über den Spuren: eine Szene je Zelle (Pattern + Länge in Takten). Beobachtet
// nur `SongState` — kein Playhead, kein Scroll, keine Engine-Veröffentlichung. Alle
// Änderungen laufen über `engine.setSongUndoable` (Undo).

struct SongLaneView: View {
    @ObservedObject var songState: SongState
    @EnvironmentObject private var engine: SequencerEngine
    @AppStorage("appLanguage") private var lang: String = "en"
    @AppStorage("showTooltips") private var showTooltips: Bool = true
    private var s: Str { Str(lang) }
    private func tip(_ t: String) -> String { showTooltips ? t : "" }

    @State private var editing: UUID? = nil

    private var song: Song { songState.song }
    static let cellWidth:  CGFloat = 58
    static let cellHeight: CGFloat = 44

    private func update(_ change: (inout Song) -> Void) {
        var new = song
        change(&new)
        engine.setSongUndoable(new, actionName: s.undoSong)
    }

    var body: some View {
        HStack(spacing: 0) {
            header
                .frame(width: VintageTheme.trackHeaderWidth, alignment: .leading)
            Rectangle().fill(VintageTheme.panelBorder.opacity(0.6)).frame(width: 1)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(song.scenes.enumerated()), id: \.element.id) { i, scene in
                        sceneCell(i, scene)
                    }
                    if song.scenes.isEmpty {
                        Text(s.songEmptyHint)
                            .font(VintageTheme.monoSmall)
                            .foregroundColor(VintageTheme.textSecondary)
                            .padding(.horizontal, 6)
                    }
                    Button {
                        update {
                            let last = $0.scenes.last
                            $0.scenes.append(SongScene(pattern: last?.pattern ?? engine.currentPatternIndex,
                                                       bars: last?.bars ?? 4))
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(VintageTheme.textSecondary)
                            .frame(width: 30, height: Self.cellHeight)
                    }
                    .buttonStyle(.fullArea)
                    .disabled(song.scenes.count >= Song.maxScenes)
                    .help(tip(s.songAddTip))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
        .background(VintageTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(song.enabled ? VintageTheme.amber.opacity(0.55) : VintageTheme.panelBorder.opacity(0.6),
                    lineWidth: 1))
    }

    // MARK: Kopf

    private var header: some View {
        HStack(spacing: 6) {
            Text(s.songHeader)
                .font(VintageTheme.monoBold)
                .foregroundColor(song.enabled ? VintageTheme.textAmber : VintageTheme.textSecondary)
            Spacer(minLength: 0)
            Button(song.enabled ? "ON" : "OFF") { update { $0.enabled.toggle() } }
                .buttonStyle(VintageSmallButtonStyle(isActive: song.enabled))
                .help(tip(song.enabled ? s.songDisableTip : s.songEnableTip))
            Button(song.loops ? s.songLoopLabel : s.songEndLabel) { update { $0.loops.toggle() } }
                .buttonStyle(VintageSmallButtonStyle(isActive: song.loops,
                                                     accent: Color(red: 0.3, green: 0.8, blue: 1.0)))
                .help(tip(song.loops ? s.songLoopTip : s.songEndTip))
        }
        .padding(.horizontal, 10)
    }

    // MARK: Szene

    private func sceneCell(_ i: Int, _ scene: SongScene) -> some View {
        let color   = VintageTheme.color(forTrack: scene.pattern)
        let playing = songState.playingScene == i
        let letter  = Pattern.slotNames.indices.contains(scene.pattern) ? Pattern.slotNames[scene.pattern] : "?"
        return Button { editing = scene.id } label: {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(colors: [color.opacity(playing ? 0.55 : 0.30),
                                                  color.opacity(playing ? 0.25 : 0.08)],
                                         startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: 6)
                    .stroke(playing ? VintageTheme.amberBright : color.opacity(0.6),
                            lineWidth: playing ? 2 : 1)
                VStack(spacing: 1) {
                    Text(letter)
                        .font(.system(size: 17, weight: .bold, design: .monospaced))
                        .foregroundColor(VintageTheme.textPrimary)
                    Text(s.songBars(scene.bars))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(VintageTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text("\(i + 1)")
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundColor(VintageTheme.textDim)
                    .padding(3)
            }
            .frame(width: Self.cellWidth, height: Self.cellHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tip(s.songSceneTip))
        .contextMenu {
            Button(s.songDuplicateScene) {
                update { $0.scenes.insert(SongScene(pattern: scene.pattern, bars: scene.bars), at: i + 1) }
            }
            .disabled(song.scenes.count >= Song.maxScenes)
            Button(s.songMoveLeft)  { update { $0.scenes.swapAt(i, i - 1) } }.disabled(i == 0)
            Button(s.songMoveRight) { update { $0.scenes.swapAt(i, i + 1) } }
                .disabled(i == song.scenes.count - 1)
            Divider()
            Button(s.songDeleteScene, role: .destructive) { update { $0.scenes.remove(at: i) } }
        }
        .popover(isPresented: Binding(get: { editing == scene.id },
                                      set: { if !$0 { editing = nil } }),
                 arrowEdge: .bottom) {
            SceneEditor(scene: scene, index: i, update: update)
        }
    }
}

// MARK: - SceneEditor

private struct SceneEditor: View {
    let scene: SongScene
    let index: Int
    let update: ((inout Song) -> Void) -> Void
    @AppStorage("appLanguage") private var lang: String = "en"
    private var s: Str { Str(lang) }

    private func set(_ change: @escaping (inout SongScene) -> Void) {
        update { song in
            guard let i = song.scenes.firstIndex(where: { $0.id == scene.id }) else { return }
            change(&song.scenes[i])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(s.songPatternHeader)
                .font(VintageTheme.monoBold)
                .foregroundColor(VintageTheme.textAmber)
            VStack(spacing: 4) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: 4) {
                        ForEach(0..<8, id: \.self) { col in
                            let p = row * 8 + col
                            Button(Pattern.slotNames[p]) { set { $0.pattern = p } }
                                .buttonStyle(VintagePatternButtonStyle(isActive: scene.pattern == p))
                        }
                    }
                }
            }
            Text(s.songBarsHeader)
                .font(VintageTheme.monoBold)
                .foregroundColor(VintageTheme.textAmber)
            HStack(spacing: 4) {
                ForEach(SongScene.barOptions, id: \.self) { b in
                    Button("\(b)") { set { $0.bars = b } }
                        .buttonStyle(VintageSmallButtonStyle(isActive: scene.bars == b))
                }
            }
            HStack {
                Button(s.songDeleteScene) {
                    update { song in song.scenes.removeAll { $0.id == scene.id } }
                }
                .buttonStyle(VintageSmallButtonStyle(isActive: false, accent: .red))
                Spacer()
            }
        }
        .padding(14)
        .background(VintageTheme.panelDark)
        .preferredColorScheme(.dark)
    }
}
