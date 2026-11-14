import Foundation
import Combine

// MARK: - Song (v1.14.0)
//
// Eine Folge von Szenen über allen Patterns. Szene = Pattern + Länge in Takten (4/4,
// 96 Pulse je Takt). Wertetyp; Änderungen laufen über `SequencerEngine.setSongUndoable`.
// Persistiert als optionaler Preset-Schlüssel `song`.

struct SongScene: Codable, Equatable, Identifiable {
    /// Nur für die Anzeige (SwiftUI-Identität); nicht persistiert, nicht Teil der Gleichheit.
    var id = UUID()
    var pattern: Int
    var bars:    Int

    static func == (a: SongScene, b: SongScene) -> Bool { a.pattern == b.pattern && a.bars == b.bars }

    static let barOptions = [1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64]
    static let barRange   = 1...64
}

struct Song: Codable, Equatable {
    var scenes:  [SongScene] = []
    /// Song-Modus: beim Start spielt die Engine die Szenenfolge statt eines Patterns.
    var enabled: Bool = false
    /// Am Ende von vorn (true) oder anhalten (false).
    var loops:   Bool = true

    static let maxScenes = 64
    static let pulsesPerBar = 96

    /// Spielbar: eingeschaltet und mindestens eine Szene.
    var isActive: Bool { enabled && !scenes.isEmpty }

    /// Lauf ab Szene `start`, während Pattern `playing` klingt: die Startszene zählt immer,
    /// danach jede direkt folgende Szene mit demselben Pattern — dort ist kein Wechsel nötig.
    /// Mit `loops` läuft der Lauf über das Ende hinweg (höchstens einmal rundum). Liefert die
    /// Länge in Takten und die Szene, auf die gewechselt wird: `.scene(i)`, `.end` (Songende,
    /// anhalten) oder `.never` (Loop, alle Szenen spielen `playing`).
    enum RunEnd: Equatable { case scene(Int), end, never }
    func run(from start: Int, playing: Int) -> (bars: Int, then: RunEnd) {
        guard scenes.indices.contains(start) else { return (0, .end) }
        var bars = scenes[start].bars, count = 1, i = start
        while true {
            i += 1
            if i == scenes.count {
                guard loops else { return (bars, .end) }
                i = 0
            }
            if count == scenes.count {   // einmal rundum, zurück bei `start`
                return (bars, scenes[start].pattern == playing ? .never : .scene(start))
            }
            guard scenes[i].pattern == playing else { return (bars, .scene(i)) }
            bars += scenes[i].bars; count += 1
        }
    }

    mutating func clamp(patternCount: Int) {
        if scenes.count > Self.maxScenes { scenes.removeLast(scenes.count - Self.maxScenes) }
        for i in scenes.indices {
            scenes[i].pattern = max(0, min(patternCount - 1, scenes[i].pattern))
            scenes[i].bars    = max(SongScene.barRange.lowerBound,
                                    min(SongScene.barRange.upperBound, scenes[i].bars))
        }
    }
}

extension SongScene {
    enum CodingKeys: String, CodingKey { case pattern, bars }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(pattern: try c.decode(Int.self, forKey: .pattern),
                  bars:    try c.decode(Int.self, forKey: .bars))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pattern, forKey: .pattern)
        try c.encode(bars,    forKey: .bars)
    }
}

extension Song {
    enum CodingKeys: String, CodingKey { case scenes, enabled, loops }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scenes  = try c.decodeIfPresent([SongScene].self, forKey: .scenes) ?? []
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        loops   = try c.decodeIfPresent(Bool.self, forKey: .loops) ?? true
    }
}

// MARK: - SongState

/// Isolierter UI-Zustand des Songs (@Published-Disziplin): nur die Song-Lane beobachtet ihn.
final class SongState: ObservableObject {
    @Published var song = Song()
    /// Szene, deren Lauf gerade spielt (Start des Laufs); nil im Stop oder ohne Song-Modus.
    @Published var playingScene: Int? = nil
}
