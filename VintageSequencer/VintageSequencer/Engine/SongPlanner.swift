import Foundation

// MARK: - SongPlanner (v1.16.0, Codex M6)
//
// Main-seitige Songplanung als eigener Werttyp: aus Song, laufender Szene und deren
// Startpuls die nächsten Wechsel (Pattern, Szene, absoluter Puls) bzw. das Songende. Kennt
// weder Engine noch Snapshot; die Engine übernimmt das erste geplante Pattern als
// Vormerkung und publiziert. Verhalten unverändert gegenüber v1.15.2.

struct SongPlanner {
    struct Step: Equatable { var pattern: Int; var scene: Int; var pulse: Int }

    /// Szene, deren Lauf gerade spielt; nil = kein Song-Lauf.
    private(set) var runStart: Int?
    /// Puls, auf dem dieser Lauf begann.
    private(set) var runStartPulse = 0
    /// Vorausgeplante Wechsel; das erste Element ist die aktuelle Vormerkung.
    private(set) var plan: [Step] = []
    /// Puls des Songendes (−1 = keins im Plan).
    private(set) var stopAtPulse = -1
    /// Puls, auf dem nach dem letzten geplanten Schritt der nächste Wechsel fällig wäre
    /// (Horizont abgeschnitten); −1 = Plan reicht bis zum Ende bzw. Loop ohne Wechsel.
    private(set) var planEndPulse = -1

    /// Höchstens so viele Wechsel plant ein Song mit Loop voraus (ohne Loop: bis zum Ende,
    /// begrenzt durch die Runtime-Slots).
    static let horizon = 16

    var isRunning: Bool { runStart != nil }
    var nextScene: Int? { plan.first?.scene }
    var switchAtPulse: Int { plan.first?.pulse ?? -1 }

    /// Neuer Lauf ab Szene `scene`, begonnen auf `pulse`.
    mutating func beginRun(scene: Int, pulse: Int) {
        runStart = scene
        runStartPulse = pulse
    }

    /// Lauf auf eine gültige Szene begrenzen (Song wurde geändert).
    mutating func clampRun(sceneCount: Int) {
        if let r = runStart { runStart = min(r, max(0, sceneCount - 1)) }
    }

    mutating func clear() {
        runStart = nil
        plan = []
        stopAtPulse = -1
        planEndPulse = -1
    }

    /// Plant ab dem laufenden Lauf voraus. `playing` = gerade aktives Pattern,
    /// `maxDistinct` = so viele verschiedene Patterns passen in die Runtime-Slots.
    /// `ppb` = Pulse je Takt eines Patterns (v1.18.24: Taktart je Pattern) — ein Lauf zählt
    /// seine Takte in der Taktart seines Patterns.
    /// Rückgabe: false, wenn kein gültiger Lauf besteht (Plan dann leer).
    @discardableResult
    mutating func schedule(song: Song, playing current: Int, patternCount: Int, maxDistinct: Int,
                           pulsesPerBar ppb: (Int) -> Int = { _ in Song.pulsesPerBar }) -> Bool {
        guard let start0 = runStart, song.isActive, song.scenes.indices.contains(start0) else {
            clear(); return false
        }
        var distinct: Set<Int> = [current]
        var out: [Step] = []
        var stopAt = -1, truncatedAt = -1
        var start = start0, playing = current, pulse = runStartPulse
        let limit = song.loops ? Self.horizon : Song.maxScenes
        planning: while true {
            guard out.count < limit else {
                truncatedAt = pulse + song.run(from: start, playing: playing).bars * ppb(playing)
                break planning
            }
            let run = song.run(from: start, playing: playing)
            let end = pulse + run.bars * ppb(playing)
            switch run.then {
            case .scene(let i) where (0..<patternCount).contains(song.scenes[i].pattern):
                let p = song.scenes[i].pattern
                if !distinct.contains(p) {
                    guard distinct.count < maxDistinct else { truncatedAt = end; break planning }
                    distinct.insert(p)
                }
                out.append(Step(pattern: p, scene: i, pulse: end))
                start = i; playing = p; pulse = end
            case .scene, .end:
                stopAt = end
                break planning
            case .never:
                break planning
            }
        }
        plan = out
        stopAtPulse = stopAt
        planEndPulse = truncatedAt
        return true
    }
}

// MARK: - PlanLedger (v1.16.0, Codex M6; Verträge R1/R6 aus v1.15.2)
//
// Sitzungen und Plan-Linien auf Main: welche Schritte unter welcher Linie geplant waren,
// nach absoluter Aktivierungsnummer. Die letzten vier Linien bleiben, damit ein Wechsel,
// den der Tick-Thread noch unter einer abgelösten Linie vollzogen hat, zuordenbar bleibt.

struct PlanLedger {
    typealias Entry = (pattern: Int, scene: Int?, pulse: Int)
    struct Line { var id: UInt32; var steps: [Int: Entry] }

    /// Wiedergabe-Sitzung (nie 0 im unteren Byte: 0 im Stempel = „keine Sitzung").
    private(set) var session: UInt32 = 0
    private(set) var currentID: UInt32 = 0
    private var idCounter: UInt32 = 0
    private(set) var lines: [Line] = []
    static let keptLines = 4

    mutating func beginSession() {
        session &+= 1
        if session & 0xFF == 0 { session &+= 1 }
        lines.removeAll()
        currentID = 0
    }

    /// Stimmt das Sitzungsbyte eines Stempels mit der laufenden Sitzung überein?
    func matchesSession(stampByte: UInt32) -> Bool { stampByte == session & 0xFF }

    /// Schritte der aktuellen Linie fortschreiben, solange jeder schon geplante künftige
    /// Schritt gleich bleibt; sonst neue Linie. Rückgabe: true = neue Linie begonnen.
    mutating func record(_ steps: [Int: Entry], serial: Int) -> Bool {
        if let i = lines.firstIndex(where: { $0.id == currentID }),
           lines[i].steps.allSatisfy({ known in
               known.key <= serial || steps[known.key].map { e in
                   e.pattern == known.value.pattern && e.scene == known.value.scene
                       && e.pulse == known.value.pulse } ?? false }) {
            lines[i].steps.merge(steps) { _, new in new }
            return false
        }
        idCounter &+= 1
        if idCounter & 0xFFF == 0 { idCounter &+= 1 }   // 0 im 12-Bit-Feld = keine Linie
        currentID = idCounter
        lines.append(Line(id: currentID, steps: steps))
        if lines.count > Self.keptLines { lines.removeFirst(lines.count - Self.keptLines) }
        return true
    }

    /// Linie zum 12-Bit-Planfeld eines Stempels.
    func line(stampPlan: UInt32) -> Line? { lines.first { $0.id & 0xFFF == stampPlan } }

    /// Patterns, die nach Aktivierung `serial` in irgendeiner bekannten Linie geplant sind.
    func plannedPatterns(after serial: Int) -> Set<Int> {
        var out: Set<Int> = []
        for l in lines { for (s, e) in l.steps where s > serial { out.insert(e.pattern) } }
        return out
    }
}
